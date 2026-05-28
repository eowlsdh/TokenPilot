import SwiftUI
import AppKit
import Combine
import TokenCore

@MainActor
final class TokenPilotViewModel: ObservableObject {
    enum DataSourceMode: String, CaseIterable {
        case live = "LIVE"
        case stale = "STALE"
        case mock = "MOCK"
        case disconnected = "--"

        var displayLabel: String { rawValue }
    }

    enum RefreshReason {
        case manual
        case automaticTimer
        case settings
    }

    enum Screen: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case history = "History"
        case settings = "Settings"
        var id: String { rawValue }
    }

    @Published var selectedScreen: Screen = .overview
    @Published var selectedHistoryPeriod: HistoryPeriod = .today
    @Published var snapshots: [ProviderSnapshot] = []
    @Published var historySnapshots: [ProviderSnapshot] = []
    @Published var limitHistorySamples: [ProviderLimitSample] = []
    @Published var overviewUsage = AggregatedUsage(period: .today)
    @Published var historyUsage = AggregatedUsage(period: .today)
    @Published var isRefreshing = false
    @Published var dataSourceMode: DataSourceMode = .disconnected
    /// Daily token challenge target for the ChallengeCard gamification UI.
    /// Reads from AppSettings (persisted across restarts).
    @Published var challengeTargetTokens: Int = 10_000
    @Published var connectionStatus: [Provider: String] = [:]
    @Published var dataSources: [Provider: ProviderDataSource] = [:]
    @Published var exportFormat: UsageExportFormat = .json
    @Published var bannerMessage: String?
    @Published var telegramTokenInput = ""
    @Published var discordWebhookInput = ""
    @Published var hasSavedTelegramToken = false
    @Published var hasSavedDiscordWebhook = false
    @Published private var menuBarNow = Date()
    @Published var settings: AppSettings {
        didSet {
            persistSettingsDebounced(settings)
            if TokenPilotRefreshPolicy.usageRefreshNeeded(from: oldValue, to: settings) {
                scheduleSettingsDrivenRefresh()
            }
            if settings.challengeTargetTokens != oldValue.challengeTargetTokens {
                challengeTargetTokens = settings.challengeTargetTokens
            }
        }
    }

    private let settingsStore = TokenPilotSettingsStore()
    private let usageStore = UsageStore()
    private let usageHistoryStore = UsageHistoryStore()
    private let limitHistoryStore = LimitHistoryStore()
    private let aggregationService = AggregationService()
    private let menuBarStatusService = MenuBarStatusService()
    private let connectionService = DataSourceConnectionService()
    private let exportService = UsageExportService()
    private let notificationRuleService = NotificationRuleService()
    private let localNotificationService = LocalNotificationService()
    private let telegramService = TelegramNotificationService()
    private let discordService = DiscordNotificationService()
    private let keychain = KeychainService()
    private let menuBarTickInterval: TimeInterval = 1
    private let dataRefreshInterval: TimeInterval = 5
    private let settingsSaveDebounceNanoseconds: UInt64 = 350_000_000
    private let settingsRefreshDebounceNanoseconds: UInt64 = 450_000_000
    private var timer: Timer?
    private var refreshInProgress = false
    private var refreshQueued = false
    private var lastRefreshFinishedAt: Date?
    private var settingsSaveTask: Task<Void, Never>?
    private var settingsRefreshTask: Task<Void, Never>?

    init() {
        let loaded = settingsStore.load()
        self.settings = loaded
        self.challengeTargetTokens = loaded.challengeTargetTokens
        self.hasSavedTelegramToken = ((try? keychain.readSecret(account: Self.telegramTokenAccount)) ?? nil) != nil
        self.hasSavedDiscordWebhook = ((try? keychain.readSecret(account: Self.discordWebhookAccount)) ?? nil) != nil
        startAutoRefresh()
        Task {
            await updatePermissionStatus()
            await refresh(reason: .automaticTimer)
        }
    }

    static let telegramTokenAccount = "telegram.botToken"
    static let discordWebhookAccount = "discord.webhookURL"

    var menuBarTitle: String {
        menuBarStatusService.title(
            snapshots: snapshots,
            settings: settings,
            modeLabel: dataSourceMode.displayLabel,
            now: menuBarNow
        )
    }

    var menuBarStatusLevel: MenuBarStatusLevel {
        menuBarStatusService.statusLevel(snapshots: snapshots, settings: settings)
    }

    var menuBarStatusColor: Color {
        switch menuBarStatusLevel {
        case .normal: return TokenPilotDesign.textSecondary
        case .warning: return TokenPilotDesign.warning
        case .critical: return TokenPilotDesign.danger
        }
    }

    var menuBarAccessibilityLabel: String {
        menuBarStatusService.accessibilityLabel(
            snapshots: snapshots,
            settings: settings,
            modeLabel: dataSourceMode.displayLabel,
            now: menuBarNow
        )
    }

    var menuBarSnapshot: ProviderSnapshot? {
        menuBarStatusService.selectedSnapshot(from: snapshots, settings: settings)
    }

    var menuBarDisplayWindow: LimitWindow? {
        menuBarSnapshot.flatMap { menuBarStatusService.displayWindow(for: $0) }
    }

    var menuBarRemainingBadges: [MenuBarRemainingStatusBadge] {
        menuBarStatusService.remainingBadges(snapshots: snapshots, settings: settings)
    }

    var menuBarSystemImage: String {
        guard let snapshot = menuBarStatusService.selectedSnapshot(from: snapshots, settings: settings) else {
            return "chart.bar.xaxis"
        }
        return snapshot.provider.iconName
    }

    var highestRiskProvider: (provider: Provider, percent: Int)? {
        let candidates = enabledSnapshots.compactMap { snapshot -> (provider: Provider, percent: Int)? in
            guard let percent = snapshot.primaryUsedPercent else { return nil }
            return (provider: snapshot.provider, percent: percent)
        }
        return candidates.max(by: { $0.percent < $1.percent })
    }

    var nearestReset: Date? {
        enabledSnapshots
            .flatMap { snapshot in
                [snapshot.fiveHour?.resetAt, snapshot.weekly?.resetAt]
            }
            .compactMap { $0 }
            .filter { $0.timeIntervalSinceNow > 0 }
            .sorted()
            .first
    }

    var nearestResetText: String {
        nearestReset.map { TokenPilotFormatters.remainingTime(until: $0) } ?? localized("—", language: settings.localization.language)
    }

    var bestToolSnapshot: ProviderSnapshot? {
        let candidates = enabledSnapshots.compactMap { snapshot -> (ProviderSnapshot, Int)? in
            guard let value = snapshot.primaryUsedPercent else { return nil }
            return (snapshot, value)
        }
        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    private var enabledSnapshots: [ProviderSnapshot] {
        snapshots.filter { settings.isProviderEnabled($0.provider) }
    }

    var filteredSnapshots: [ProviderSnapshot] {
        historySnapshots.isEmpty ? enabledSnapshots : historySnapshots
    }

    var overviewSnapshots: [ProviderSnapshot] {
        enabledSnapshots.map { snapshot in
            var displaySnapshot = snapshot
            displaySnapshot.events = []
            return displaySnapshot
        }
    }

    var alertStatusText: String {
        let on = t("ON")
        let off = t("OFF")
        let mac = settings.macOSNotificationsEnabled ? "macOS \(on)" : "macOS \(off)"
        let tg = settings.telegramNotificationsEnabled && settings.telegram.isEnabled ? "Telegram \(on)" : "Telegram \(off)"
        let discord = settings.discordNotificationsEnabled && settings.discord.isEnabled ? "Discord \(on)" : "Discord \(off)"
        let enabled = [
            settings.alertRules.contains { $0.resetEnabled } ? t("Reset") : nil,
            settings.alertRules.contains { $0.fiftyEnabled } ? "50" : nil,
            settings.alertRules.contains { $0.eightyEnabled } ? "80" : nil,
            settings.alertRules.contains { $0.hundredEnabled } ? "100" : nil
        ].compactMap { $0 }.joined(separator: "/")
        return "\(t("Alerts")): \(mac) · \(tg) · \(discord) · \(enabled.isEmpty ? off : enabled)"
    }

    func t(_ key: String) -> String {
        TokenPilotLocalizer.localized(key, language: settings.localization.language)
    }

    func localizedStatus(_ status: String) -> String {
        TokenPilotLocalizer.localized(status, language: settings.localization.language)
    }

    func localizedErrorMessage(_ error: Error) -> String {
        if let telegramError = error as? TelegramError {
            return t(telegramError.errorDescription ?? "Telegram error")
        }
        if let discordError = error as? DiscordError {
            return t(discordError.errorDescription ?? "Discord error")
        }
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .invalidData:
                return t("Keychain item contained invalid data.")
            case .unhandledStatus(let status):
                return String(format: t("Keychain.status.error"), status)
            }
        }
        return error.localizedDescription
    }

    func isProviderEnabled(_ provider: Provider) -> Bool {
        settings.isProviderEnabled(provider)
    }

    func setProvider(_ provider: Provider, isEnabled: Bool) {
        var next = settings
        if next.setProviderEnabled(provider, isEnabled: isEnabled) {
            settings = next
        } else {
            bannerMessage = t("At least one provider must stay enabled.")
        }
    }

    func setMenuBarDisplayTarget(_ provider: Provider?) {
        settings.menuBarDisplayTarget = provider
    }

    func updateChallengeTarget(_ target: Int) {
        let clamped = min(max(target, 1_000), 100_000)
        var next = settings
        next.challengeTargetTokens = clamped
        settings = next
    }

    func menuBarDisplayTargetLabel(for provider: Provider?) -> String {
        guard let provider else { return t("Highest risk") }
        return t(provider.displayName)
    }

    func startAutoRefresh() {
        guard timer == nil else { return }
        menuBarNow = Date()
        let timer = Timer(timeInterval: menuBarTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAutoRefreshTick()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func refreshAfterPopoverOpen() async {
        // MenuBarExtra can rebuild content during Settings ↔ Overview navigation.
        // Keep this lifecycle hook lightweight; app-level timer/init/manual actions own provider refreshes.
        menuBarNow = Date()
    }

    private func handleAutoRefreshTick() async {
        menuBarNow = Date()
        guard shouldRunDataRefresh(at: menuBarNow) else { return }
        await refresh(reason: .automaticTimer)
    }

    private func shouldRunDataRefresh(at now: Date) -> Bool {
        guard !refreshInProgress else { return false }
        guard let lastRefreshFinishedAt else { return true }
        return now.timeIntervalSince(lastRefreshFinishedAt) >= dataRefreshInterval
    }

    private func persistSettingsDebounced(_ settingsToSave: AppSettings) {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [settingsStore, settingsSaveDebounceNanoseconds] in
            try? await Task.sleep(nanoseconds: settingsSaveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                settingsStore.save(settingsToSave)
            }.value
        }
    }

    private func scheduleSettingsDrivenRefresh() {
        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task { [weak self, settingsRefreshDebounceNanoseconds] in
            try? await Task.sleep(nanoseconds: settingsRefreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.refresh(reason: .settings)
        }
    }

    func refresh(reason: RefreshReason = .manual) async {
        if reason == .manual {
            menuBarNow = Date()
        }
        if refreshInProgress {
            refreshQueued = true
            return
        }

        refreshInProgress = true
        isRefreshing = true
        defer {
            refreshInProgress = false
            isRefreshing = false
            let now = Date()
            menuBarNow = now
            lastRefreshFinishedAt = now
        }

        repeat {
            refreshQueued = false
            await performRefreshPass()
        } while refreshQueued
    }

    private func performRefreshPass() async {
        let settingsAtStart = settings
        let result = await usageStore.refresh(settings: settingsAtStart)
        snapshots = result.snapshots
        dataSourceMode = determineDataMode(hasConnectedData: result.hasConnectedData)
        rebuildUsageFromHistory(using: result.snapshots)
        let sources = await connectionService.checkAll(settings: settingsAtStart)
        let usageSettingsChanged = TokenPilotRefreshPolicy.usageRefreshNeeded(from: settingsAtStart, to: settings)
        if usageSettingsChanged {
            scheduleSettingsDrivenRefresh()
        } else {
            applyDataSources(sources)
        }
        let events = notificationRuleService.evaluate(snapshots: result.snapshots, settings: settingsAtStart, language: settings.localization.language)
        await deliver(events)
    }

    private func rebuildUsageFromHistory(using currentSnapshots: [ProviderSnapshot]) {
        let enabledProviders = Set(settings.enabledProviders)
        let retainedEvents = usageHistoryStore.record(snapshots: currentSnapshots, enabledProviders: enabledProviders)
        historySnapshots = usageHistoryStore.snapshotsForHistory(
            currentSnapshots: currentSnapshots,
            events: retainedEvents,
            enabledProviders: enabledProviders
        )
        limitHistoryStore.record(snapshots: currentSnapshots, enabledProviders: enabledProviders)
        overviewUsage = aggregationService.aggregate(snapshots: historySnapshots, period: .today)
        rebuildHistoryUsage(for: selectedHistoryPeriod)
    }

    private func determineDataMode(hasConnectedData: Bool) -> DataSourceMode {
        if settings.showMockDataWhenDisconnected && !hasConnectedData {
            return .mock
        }
        if snapshots.contains(where: { $0.isStale }) {
            return .stale
        }
        return hasConnectedData ? .live : .disconnected
    }

    func selectHistoryPeriod(_ period: HistoryPeriod) {
        if selectedHistoryPeriod != period {
            selectedHistoryPeriod = period
        }
        rebuildHistoryUsage(for: period)
    }

    private func rebuildHistoryUsage(for period: HistoryPeriod) {
        historyUsage = aggregationService.aggregate(snapshots: historySnapshots, period: period)
        limitHistorySamples = limitHistoryStore.samples(period: period, enabledProviders: Set(settings.enabledProviders))
    }

    func updatePermissionStatus() async {
        settings.notificationPermissionStatus = await localNotificationService.permissionStatus()
    }

    func requestNotificationPermission() async {
        settings.notificationPermissionStatus = await localNotificationService.requestPermission()
        if settings.notificationPermissionStatus == .denied {
            bannerMessage = t("Permission denied. Enable notifications in macOS Settings > Notifications.")
        } else {
            bannerMessage = String(format: t("Notification permission: %@"), settings.notificationPermissionStatus.localizedLabel(language: settings.localization.language))
        }
    }

    func sendTestNotification() async {
        do {
            if settings.macOSNotificationsEnabled {
                try await localNotificationService.send(title: t("TokenPilot"), body: t("✅ TokenPilot test alert. macOS notifications are connected."))
            }
            if settings.telegramNotificationsEnabled || settings.telegram.isEnabled {
                try await sendTelegram(text: t("✅ TokenPilot test alert. Telegram notifications are connected."))
            }
            if settings.discordNotificationsEnabled || settings.discord.isEnabled {
                try await sendDiscord(text: t("✅ TokenPilot test alert. Discord notifications are connected."))
            }
            bannerMessage = t("Test notification sent.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func chooseClaudeStatusFile() {
        chooseLocalSource(
            provider: .claude,
            prompt: t("Choose Claude status JSON"),
            message: t("Choose the Claude statusline JSON file TokenPilot should read."),
            canChooseDirectories: false
        ) { [weak self] url, bookmarkData in
            guard let self else { return }
            var nextSettings = self.settings
            nextSettings.claudeStatusFilePath = url.path
            nextSettings.claudeStatusFileBookmarkData = bookmarkData
            self.settings = nextSettings
        }
    }

    func chooseGeminiTelemetrySource() {
        chooseLocalSource(
            provider: .gemini,
            prompt: t("Choose Gemini source"),
            message: t("Choose telemetry.log or a Gemini session folder."),
            canChooseDirectories: true
        ) { [weak self] url, bookmarkData in
            guard let self else { return }
            var nextSettings = self.settings
            nextSettings.geminiTelemetryLogPath = url.path
            nextSettings.geminiTelemetrySourceBookmarkData = bookmarkData
            self.settings = nextSettings
        }
    }

    func chooseGeminiLogFile() {
        chooseGeminiTelemetrySource()
    }

    private func chooseLocalSource(
        provider: Provider,
        prompt: String,
        message: String,
        canChooseDirectories: Bool,
        apply: (URL, Data?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = canChooseDirectories
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = prompt
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url {
            let bookmarkData = try? TokenPilotSecurityScopedBookmarks.makeReadOnlyBookmarkData(for: url)
            apply(url, bookmarkData)
            if bookmarkData == nil {
                bannerMessage = t("Selected source path saved, but sandbox bookmark was not created. Choose it again if the sandbox cannot read it.")
            }
            Task {
                await checkConnection(provider)
            }
        }
    }

    func checkConnection(_ provider: Provider) async {
        let source = await connectionService.check(settings: settings, provider: provider)
        dataSources[provider] = source
        connectionStatus[provider] = sourceStatusText(source)
        bannerMessage = "\(t(provider.displayName)): \(sourceStatusText(source))"
    }

    func checkAllConnections() async {
        applyDataSources(await connectionService.checkAll(settings: settings))
        bannerMessage = t("Connection check complete.")
    }

    private func applyDataSources(_ sources: [ProviderDataSource]) {
        dataSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.provider, $0) })
        connectionStatus = Dictionary(uniqueKeysWithValues: sources.map { ($0.provider, sourceStatusText($0)) })
    }

    func sourceStatusText(_ provider: Provider) -> String {
        guard let source = dataSources[provider] else { return t("Not checked") }
        return sourceStatusText(source)
    }

    func sourceStatusText(_ source: ProviderDataSource) -> String {
        let base: String
        switch source.status {
        case .connected: base = t("Connected")
        case .notFound: base = t("Not found")
        case .permissionDenied: base = t("Permission denied")
        case .noUsableData: base = t("No usable data")
        case .stale: base = t("STALE")
        case .invalidFormat: base = t("Invalid format")
        case .disabled: base = t("Disabled")
        case .manual: base = t("Manual mode")
        case .estimated: base = "\(t("Estimated")) (\(t("est.")))"
        }

        if let message = source.statusMessage, !message.isEmpty, message != base {
            return "\(base) · \(localizedStatus(message))"
        }
        return base
    }

    func sourceDetailText(_ provider: Provider) -> String {
        guard let source = dataSources[provider] else { return t("Run Check Connection to scan local paths.") }
        if provider == .codex {
            if settings.codexManual.webConnectorEnabled {
                return t("Asks the local Codex CLI app-server for account/rateLimits/read. TokenPilot does not read, store, display, or export Codex access tokens.")
            }
            if let path = connectionService.preferredUsablePath(in: source) {
                return "\(t("Detected")): \(path) · \(t("Local log")) · \(t("Not web quota"))"
            }
            return t("Run /status in Codex CLI and paste the result.")
        }
        if let path = connectionService.preferredUsablePath(in: source) {
            return "\(t("Detected")): \(path)"
        }
        let found = source.detectedPaths.filter(\.exists).count
        let total = source.detectedPaths.count
        return "\(t("Detected paths")): \(found)/\(total)"
    }

    func sourceStatusColor(_ provider: Provider) -> Color {
        guard let status = dataSources[provider]?.status else { return TokenPilotDesign.textSecondary }
        switch status {
        case .connected: return TokenPilotDesign.calm
        case .stale, .estimated, .manual, .noUsableData: return TokenPilotDesign.warning
        case .notFound, .permissionDenied, .invalidFormat: return TokenPilotDesign.danger
        case .disabled: return TokenPilotDesign.textSecondary
        }
    }

    func exportHistory() {
        do {
            let data = try exportService.export(
                usage: historyUsage,
                snapshots: filteredSnapshots,
                dataMode: dataSourceMode.displayLabel,
                format: exportFormat
            )
            let panel = NSSavePanel()
            panel.allowedContentTypes = [exportFormat == .json ? .json : .commaSeparatedText]
            panel.nameFieldStringValue = exportFormat.defaultFilename
            panel.canCreateDirectories = true
            panel.title = t("Export Usage")
            panel.message = t("Exports the selected History period only. Credentials, tokens, chat IDs, webhooks, and local file paths are not included.")
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                bannerMessage = "\(t("Exported")): \(url.lastPathComponent)"
            }
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func parseCodexStatus() {
        settings.codexManual = CodexStatusParser.safeParse(
            settings.codexManual.pastedStatusOutput,
            previous: settings.codexManual
        )
        connectionStatus[.codex] = "\(t("Parsed /status")) · \(settings.codexManual.confidence.localizedLabel(language: settings.localization.language))"
    }

    func pasteCodexStatusFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            let manual = settings.codexManual
            settings.codexManual = CodexManualSettings(
                planLabel: manual.planLabel,
                fiveHourUsagePercentage: manual.fiveHourUsagePercentage,
                weeklyUsagePercentage: manual.weeklyUsagePercentage,
                resetTimeText: manual.resetTimeText,
                notes: manual.notes,
                pastedStatusOutput: string,
                confidence: manual.confidence,
                webSnapshotEnabled: manual.webSnapshotEnabled,
                webConnectorEnabled: manual.webConnectorEnabled,
                webTodayTokens: manual.webTodayTokens,
                webSnapshotCapturedAt: manual.webSnapshotCapturedAt
            )
            parseCodexStatus()
        }
    }

    func markCodexWebSnapshotNow() {
        var next = settings
        next.codexManual.webSnapshotEnabled = true
        next.codexManual.webSnapshotCapturedAt = Date()
        settings = next
        bannerMessage = t("Codex web snapshot marked as current.")
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        bannerMessage = t("Copied.")
    }

    func saveTelegramToken() {
        let token = telegramTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            bannerMessage = t("Enter a bot token first.")
            return
        }
        do {
            try keychain.saveSecret(token, account: Self.telegramTokenAccount)
            telegramTokenInput = ""
            hasSavedTelegramToken = true
            settings.telegram.connectionStatus = "Token saved securely"
            bannerMessage = t("Telegram token saved in TokenPilot Keychain item.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func deleteTelegramToken() {
        do {
            try keychain.deleteSecret(account: Self.telegramTokenAccount)
            telegramTokenInput = ""
            hasSavedTelegramToken = false
            settings.telegram.connectionStatus = "Not configured"
            bannerMessage = t("Telegram token deleted.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func sendTelegramTest() async {
        do {
            try await sendTelegram(text: t("✅ TokenPilot test alert. Telegram notifications are connected."))
            settings.telegram.connectionStatus = "Connected"
            settings.telegram.lastTestSentAt = Date()
            bannerMessage = t("Telegram test message sent.")
        } catch {
            settings.telegram.connectionStatus = "Failed"
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func findTelegramChatID() async {
        do {
            let token = try telegramTokenForUse()
            let chatID = try await telegramService.findChatID(token: token)
            settings.telegram.chatID = chatID
            settings.telegram.connectionStatus = "Connected"
            bannerMessage = t("Chat ID found.")
        } catch {
            settings.telegram.connectionStatus = "Failed"
            bannerMessage = localizedErrorMessage(error)
        }
    }

    private func telegramTokenForUse() throws -> String {
        if !telegramTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return telegramTokenInput
        }
        if let saved = try keychain.readSecret(account: Self.telegramTokenAccount) {
            return saved
        }
        throw TelegramError.notConfigured
    }

    private func sendTelegram(text: String) async throws {
        let token = try telegramTokenForUse()
        try await telegramService.sendMessage(token: token, chatID: settings.telegram.chatID, text: text)
    }

    func saveDiscordWebhook() {
        let webhookURL = discordWebhookInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !webhookURL.isEmpty else {
            bannerMessage = t("Enter a Discord webhook URL first.")
            return
        }
        do {
            _ = try DiscordNotificationService.makeRequest(webhookURL: webhookURL, content: "TokenPilot validation")
            try keychain.saveSecret(webhookURL, account: Self.discordWebhookAccount)
            discordWebhookInput = ""
            hasSavedDiscordWebhook = true
            settings.discord.connectionStatus = "Webhook saved securely"
            bannerMessage = t("Discord webhook saved in TokenPilot Keychain item.")
        } catch {
            settings.discord.connectionStatus = "Failed"
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func deleteDiscordWebhook() {
        do {
            try keychain.deleteSecret(account: Self.discordWebhookAccount)
            discordWebhookInput = ""
            hasSavedDiscordWebhook = false
            settings.discord.isEnabled = false
            settings.discordNotificationsEnabled = false
            settings.discord.connectionStatus = "Not configured"
            bannerMessage = t("Discord webhook deleted.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func sendDiscordTest() async {
        do {
            try await sendDiscord(text: t("✅ TokenPilot test alert. Discord notifications are connected."))
            settings.discord.connectionStatus = "Connected"
            settings.discord.lastTestSentAt = Date()
            bannerMessage = t("Discord test message sent.")
        } catch {
            settings.discord.connectionStatus = "Failed"
            bannerMessage = localizedErrorMessage(error)
        }
    }

    private func discordWebhookForUse() throws -> String {
        if !discordWebhookInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return discordWebhookInput
        }
        if let saved = try keychain.readSecret(account: Self.discordWebhookAccount) {
            return saved
        }
        throw DiscordError.notConfigured
    }

    private func sendDiscord(text: String) async throws {
        let webhookURL = try discordWebhookForUse()
        try await discordService.sendMessage(webhookURL: webhookURL, content: text)
    }

    private func deliver(_ events: [AlertEvent]) async {
        guard !events.isEmpty else { return }
        for event in events {
            guard let rule = settings.alertRules.first(where: { $0.provider == event.provider && $0.window == event.window }) else { continue }
            if settings.macOSNotificationsEnabled && rule.macOSEnabled {
                try? await localNotificationService.send(title: event.title, body: event.body)
            }
            if settings.telegramNotificationsEnabled && settings.telegram.isEnabled && rule.telegramEnabled {
                try? await sendTelegram(text: event.body)
            }
            if settings.discordNotificationsEnabled && settings.discord.isEnabled && rule.discordEnabled {
                try? await sendDiscord(text: event.body)
            }
        }
    }
}
