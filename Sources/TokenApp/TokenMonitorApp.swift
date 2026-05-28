import SwiftUI
import AppKit
import Combine
import TokenCore
import UniformTypeIdentifiers
import UserNotifications

@main
struct TokenMonitorApp: App {
    @StateObject private var model = TokenPilotViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            TokenPilotRootView(model: model)
                .frame(width: 420, height: 620)
                .onAppear {
                    Task { await model.refreshAfterPopoverOpen() }
                }
        } label: {
            HStack(spacing: 5) {
                if model.menuBarStatusLevel != .normal {
                    Circle()
                        .fill(model.menuBarStatusColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                if let provider = model.menuBarSnapshot?.provider {
                    MenuBarProviderMark(provider: provider)
                } else {
                    TokenPilotMenuBarMark()
                }
                Text(model.menuBarTitle)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .help(model.menuBarAccessibilityLabel)
            .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}



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
    /// Not tied to any provider's actual quota limit; resets on app restart.
    @Published var challengeTargetTokens = 10_000
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

private enum TokenPilotDesign {
    // Quiet premium macOS utility palette — nearly monochrome with status accents only.
    static let background = Color(red: 0.039, green: 0.039, blue: 0.043)       // #0a0a0b
    static let card = Color(red: 0.067, green: 0.071, blue: 0.078)             // #111214
    static let cardElevated = Color(red: 0.082, green: 0.086, blue: 0.096)     // #151618
    static let cardMuted = Color(red: 0.090, green: 0.098, blue: 0.114)        // #17191d
    static let border = Color(red: 0.145, green: 0.153, blue: 0.173)           // #25272c

    // Liquid glass layers
    static let glassTint = Color.black.opacity(0.18)
    static let glassHighlight = Color.white.opacity(0.06)
    static let glassEdgeGlow = LinearGradient(
        colors: [Color.white.opacity(0.10), Color.white.opacity(0.03), Color.clear, Color.white.opacity(0.06)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let glassInnerGlow = LinearGradient(
        colors: [Color.white.opacity(0.04), Color.clear, Color.black.opacity(0.04)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let textPrimary = Color(red: 0.957, green: 0.957, blue: 0.961)      // #f4f4f5
    static let textSecondary = Color(red: 0.631, green: 0.631, blue: 0.667)    // #a1a1aa
    static let textTertiary = Color(red: 0.443, green: 0.443, blue: 0.478)     // #71717a
    static let danger = Color(red: 1.000, green: 0.271, blue: 0.227)           // #ff453a
    static let warning = Color(red: 0.961, green: 0.647, blue: 0.141)          // #f5a524
    static let calm = Color(red: 0.188, green: 0.820, blue: 0.345)             // #30d158

    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 13
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 10

    static func accent(for provider: Provider) -> Color {
        switch provider {
        case .claude: return Color(red: 1.0, green: 0.64, blue: 0.23)
        case .codex: return Color(red: 0.16, green: 0.74, blue: 0.37)
        case .gemini: return Color(red: 0.48, green: 0.48, blue: 0.95)
        }
    }

    static func riskColor(_ percent: Int?) -> Color {
        guard let percent else { return textSecondary }
        if percent >= 85 { return danger }
        if percent >= 70 { return warning }
        return calm
    }

    static func confidenceColor(_ confidence: DataConfidence) -> Color {
        switch confidence {
        case .high: return calm
        case .medium: return warning
        case .low, .manual: return textSecondary
        }
    }

    static func modeColor(_ mode: TokenPilotViewModel.DataSourceMode) -> Color {
        switch mode {
        case .live: return calm
        case .stale: return warning
        case .mock: return Color(red: 0.48, green: 0.48, blue: 0.95)
        case .disconnected: return textSecondary
        }
    }
}

private func localized(_ key: String, language: TokenPilotLanguage) -> String {
    TokenPilotLocalizer.localized(key, language: language)
}

private struct TokenPilotLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: TokenPilotLanguage = .system
}

private extension EnvironmentValues {
    var tokenPilotLanguage: TokenPilotLanguage {
        get { self[TokenPilotLanguageEnvironmentKey.self] }
        set { self[TokenPilotLanguageEnvironmentKey.self] = newValue }
    }
}


struct TokenPilotRootView: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        VStack(spacing: 8) {
            header
            Picker(model.t("Screen"), selection: $model.selectedScreen) {
                ForEach(TokenPilotViewModel.Screen.allCases) { screen in
                    Text(model.t(screen.rawValue)).tag(screen)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let message = model.bannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message)
                        .lineLimit(2)
                    Spacer()
                    Button(model.t("Dismiss")) { model.bannerMessage = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(9)
                .background(TokenPilotDesign.cardMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous)
                        .stroke(TokenPilotDesign.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous))
            }

            Group {
                switch model.selectedScreen {
                case .overview:
                    OverviewScreen(model: model)
                case .history:
                    HistoryScreen(model: model)
                case .settings:
                    SettingsScreen(model: model)
                }
            }
        }
        .environment(\.tokenPilotLanguage, model.settings.localization.language)
        .environment(\.locale, Locale(identifier: model.settings.localization.language.localeIdentifier ?? Locale.current.identifier))
        .padding(12)
        .frame(width: 420, height: 620)
        .foregroundStyle(TokenPilotDesign.textPrimary)
        .background(
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            TokenPilotBrandMark()

            Text(model.t("TokenPilot"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(TokenPilotDesign.textPrimary)

            StatusBadge(
                label: model.t(model.dataSourceMode.displayLabel),
                color: TokenPilotDesign.modeColor(model.dataSourceMode)
            )

            Spacer(minLength: 0)

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(TokenPilotDesign.cardMuted.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenPilotDesign.textSecondary)
            .help(model.t("Refresh"))
        }
        .frame(height: 26)
    }
}

struct OverviewScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.sectionSpacing) {
                ResetHeroCard(model: model)
                BestToolCard(snapshot: model.bestToolSnapshot)

                if model.overviewSnapshots.isEmpty {
                    EmptyStateCard(
                        icon: "tray",
                        title: model.t("No data"),
                        message: model.t("Connect a data source.")
                    )
                } else {
                    ProviderOverviewList(snapshots: model.overviewSnapshots)
                }

                ChallengeCard(target: model.challengeTargetTokens, today: model.overviewUsage.metrics.totalTokens)
                AlertsStatusRow(text: model.alertStatusText)
            }
            .padding(.bottom, 6)
        }
    }
}

struct ResetHeroCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 15) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(heroEyebrow)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                        Text(heroValue)
                            .font(.system(size: 32, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(TokenPilotDesign.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(nextResetText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        StatusBadge(label: riskLabel, color: riskColor)
                        Text(percentText)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(riskColor)
                    }
                }

                ProgressLine(percent: usedPercent, color: riskColor)

                HStack(spacing: 8) {
                    HeroStatPill(
                        label: localized("Today tokens", language: language),
                        value: "\(TokenPilotFormatters.compactNumber(model.overviewUsage.metrics.totalTokens)) \(localized("tok", language: language))"
                    )
                    HeroStatPill(
                        label: localized("Highest risk", language: language),
                        value: highestRiskText,
                        color: TokenPilotDesign.riskColor(model.highestRiskProvider?.percent)
                    )
                    HeroStatPill(
                        label: localized("Last updated", language: language),
                        value: updatedText
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
    }

    private var snapshot: ProviderSnapshot? { model.menuBarSnapshot }
    private var window: LimitWindow? { model.menuBarDisplayWindow }
    private var usedPercent: Int? { window?.usedPercent ?? snapshot?.primaryUsedPercent }

    private var heroEyebrow: String {
        let limit = localized("Limit", language: language)
        guard let window else { return localized("No data", language: language) }
        return "\(localized(window.kind.label, language: language)) \(limit)"
    }

    private var heroValue: String {
        guard let resetAt = window?.resetAt, resetAt > Date() else {
            if let usedPercent { return "\(usedPercent)%" }
            return "—"
        }
        return TokenPilotFormatters.remainingTime(until: resetAt)
    }

    private var nextResetText: String {
        let label = localized("Next reset", language: language)
        guard let resetAt = window?.resetAt else { return "\(label) · \(localized("No reset", language: language))" }
        return "\(label) · \(TokenPilotFormatters.clock(resetAt))"
    }

    private var percentText: String {
        guard let usedPercent else { return "—" }
        return "\(usedPercent)%"
    }

    private var riskLabel: String {
        guard let usedPercent else { return localized(model.dataSourceMode.displayLabel, language: language) }
        if usedPercent >= 85 { return localized("Critical", language: language) }
        if usedPercent >= 70 { return localized("Warning", language: language) }
        return localized("Stable", language: language)
    }

    private var riskColor: Color {
        TokenPilotDesign.riskColor(usedPercent)
    }

    private var highestRiskText: String {
        guard let highest = model.highestRiskProvider else { return "—" }
        return "\(highest.provider.shortName) \(highest.percent)%"
    }

    private var updatedText: String {
        guard let snapshot else { return "—" }
        return TokenPilotFormatters.clock(snapshot.updatedAt)
    }
}

struct HeroStatPill: View {
    let label: String
    let value: String
    var color: Color = TokenPilotDesign.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ProviderOverviewList: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshots: [ProviderSnapshot]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                Label(localized("Providers", language: language), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(TokenPilotDesign.textPrimary)

                VStack(spacing: 0) {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        ProviderOverviewRow(snapshot: snapshot)
                        if index < snapshots.count - 1 {
                            Divider()
                                .overlay(TokenPilotDesign.border.opacity(0.8))
                                .padding(.vertical, 9)
                        }
                    }
                }
            }
        }
    }
}

struct ProviderOverviewRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProviderSignatureMark(provider: snapshot.provider)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(snapshot.provider.displayName, language: language))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                    Text(detailText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)

                Text(valueText)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.riskColor(usedPercent))
                    .lineLimit(1)
            }

            ProgressLine(percent: usedPercent, color: TokenPilotDesign.riskColor(usedPercent))
        }
    }

    private var usedPercent: Int? {
        [
            snapshot.fiveHour?.usedPercent,
            snapshot.weekly?.usedPercent,
            snapshot.dailyRequestsPercent,
            snapshot.primaryUsedPercent
        ]
        .compactMap { $0 }
        .max()
    }

    private var valueText: String {
        guard let usedPercent else {
            if snapshot.todayTokens > 0 { return TokenPilotFormatters.compactNumber(snapshot.todayTokens) }
            return "—"
        }
        if snapshot.provider == .codex || snapshot.confidence == .manual {
            return "\(usedPercent)% \(localized("est.", language: language))"
        }
        return "\(usedPercent)%"
    }

    private var detailText: String {
        let limits = limitSegments
        if !limits.isEmpty {
            return limits.joined(separator: " · ")
        }
        if snapshot.todayTokens > 0 {
            return "\(localized("Today", language: language)) · \(TokenPilotFormatters.compactNumber(snapshot.todayTokens)) \(localized("tok", language: language))"
        }
        return localized("No limits", language: language)
    }

    private var limitSegments: [String] {
        var segments: [String] = []
        if let fiveHour = snapshot.fiveHour {
            segments.append(limitText(for: fiveHour))
        }
        if let weekly = snapshot.weekly {
            segments.append(limitText(for: weekly))
        }
        if let dailyRequestsPercent = snapshot.dailyRequestsPercent {
            segments.append("\(localized(LimitWindowKind.dailyRequests.label, language: language)) \(dailyRequestsPercent)%")
        }
        return segments
    }

    private func limitText(for window: LimitWindow) -> String {
        let label = localized(window.kind.label, language: language)
        guard let used = window.usedPercent else { return "\(label) —" }
        let suffix = (snapshot.provider == .codex || window.confidence == .manual) ? " \(localized("est.", language: language))" : ""
        return "\(label) \(used)%\(suffix)"
    }
}

struct BestToolCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshot: ProviderSnapshot?

    var body: some View {
        GlassCard {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(accent.opacity(0.18), lineWidth: 1)
                        )
                    Image(systemName: snapshot == nil ? "sparkle.magnifyingglass" : "checkmark.seal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Lowest current usage", language: language))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    if let snapshot {
                        Text(bestToolTitle(for: snapshot))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenPilotDesign.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text(localized("Connect providers in Settings", language: language))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let pct = snapshot?.primaryUsedPercent {
                    StatusBadge(label: "\(pct)%", color: TokenPilotDesign.riskColor(pct))
                }
            }
        }
    }

    private var accent: Color {
        if let snapshot {
            return TokenPilotDesign.accent(for: snapshot.provider)
        }
        return TokenPilotDesign.textSecondary
    }

    private func bestToolTitle(for snapshot: ProviderSnapshot) -> String {
        if snapshot.confidence == .manual {
            return "\(localized(snapshot.provider.displayName, language: language)) · \(localized("est.", language: language))"
        }
        return localized(snapshot.provider.displayName, language: language)
    }
}

struct ChallengeCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    let target: Int
    let today: Int

    var body: some View {
        let progress = target > 0 ? min(1, Double(today) / Double(target)) : 0
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(localized("Daily challenge", language: language), systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(TokenPilotDesign.riskColor(Int(progress * 100)))
                }
                HStack {
                    Text("\(TokenPilotFormatters.compactNumber(today)) / \(TokenPilotFormatters.compactNumber(target))")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                    Spacer()
                    Text(localized("Today tokens", language: language))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                ProgressLine(percent: Int(progress * 100), color: TokenPilotDesign.calm)
            }
        }
    }
}

struct AlertsStatusRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.badge")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TokenPilotDesign.textSecondary)
            Text(text)
                .font(.system(size: 10, design: .monospaced).weight(.medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous)
                .stroke(TokenPilotDesign.border.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous))
    }
}

struct HistoryScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.sectionSpacing) {
                Picker(model.t("Period"), selection: historyPeriodBinding) {
                    ForEach(HistoryPeriod.allCases) { period in
                        Text(period.localizedLabel(language: model.settings.localization.language)).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                GlassCard {
                    LazyVGrid(columns: [
                        GridItem(.flexible()), GridItem(.flexible()),
                        GridItem(.flexible()), GridItem(.flexible())
                    ], alignment: .leading, spacing: 10) {
                        historyStat(label: model.t("Total tokens"), value: TokenPilotFormatters.compactNumber(model.historyUsage.metrics.totalTokens))
                        historyStat(label: model.t("Input"), value: TokenPilotFormatters.compactNumber(model.historyUsage.metrics.inputTokens))
                        historyStat(label: model.t("Output"), value: TokenPilotFormatters.compactNumber(model.historyUsage.metrics.outputTokens))
                        historyStat(label: model.t("Cache tokens"), value: TokenPilotFormatters.compactNumber(model.historyUsage.metrics.cacheTokens))
                        historyStat(label: model.t("Est. cost"), value: TokenPilotFormatters.cost(model.historyUsage.metrics.estimatedCostUSD))
                        historyStat(label: model.t("Requests"), value: "\(model.historyUsage.metrics.requestCount)")
                        historyStat(label: model.t("Most used"), value: model.historyUsage.metrics.mostUsedProvider.map { model.t($0.displayName) } ?? "—")
                        historyStat(label: model.t("Busiest hour"), value: model.historyUsage.metrics.busiestHour.map { "\($0):00" } ?? "—")
                    }
                }

                if !model.limitHistorySamples.isEmpty {
                    HistoryLimitSignalCard(samples: model.limitHistorySamples, model: model)
                }

                if model.historyUsage.events.isEmpty {
                    HistoryEmptyState(hasLimitSignals: !model.limitHistorySamples.isEmpty, model: model)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label(model.t("Export"), systemImage: "square.and.arrow.down")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Picker(model.t("Format"), selection: $model.exportFormat) {
                                ForEach(UsageExportFormat.allCases) { format in
                                    Text(format.rawValue.uppercased()).tag(format)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 118)
                            Button(model.t("Save")) { model.exportHistory() }
                                .buttonStyle(.borderedProminent)
                        }
                        Text(model.t("Exports the selected History period only. Credentials, tokens, chat IDs, webhooks, and local file paths are not included."))
                            .font(.caption2)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                    }
                }

                SevenDayBarChart(bars: model.historyUsage.sevenDayBars)
                ProviderShareRow(shares: model.historyUsage.providerShare)
            }
            .padding(.bottom, 6)
        }
    }

    private var historyPeriodBinding: Binding<HistoryPeriod> {
        Binding(
            get: { model.selectedHistoryPeriod },
            set: { model.selectHistoryPeriod($0) }
        )
    }

    private func historyStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HistoryLimitSignalCard: View {
    let samples: [ProviderLimitSample]
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(model.t("Latest limit signals"), systemImage: "waveform.path.ecg.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                    Spacer()
                    StatusBadge(label: "\(samples.count)", color: TokenPilotDesign.textSecondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(samples.prefix(8).enumerated()), id: \.element.id) { index, sample in
                        HistoryLimitSignalRow(sample: sample, model: model)
                        if index < min(samples.count, 8) - 1 {
                            Divider()
                                .overlay(TokenPilotDesign.border.opacity(0.8))
                                .padding(.vertical, 8)
                        }
                    }
                }

                Text(model.t("Limit signals are recorded even when token event history is not available."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }
}

struct HistoryLimitSignalRow: View {
    let sample: ProviderLimitSample
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        HStack(spacing: 9) {
            ProviderSignatureMark(provider: sample.provider, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.t(sample.provider.displayName)) · \(sample.window.localizedLabel(language: model.settings.localization.language))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(TokenPilotDesign.textPrimary)
                Text("\(model.t("Last updated")) · \(TokenPilotFormatters.clock(sample.timestamp)) · \(model.t(sample.confidence.label))")
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: model.t("Remaining %d%%"), sample.remainingPercent))
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.riskColor(sample.usedPercent))
                Text("\(model.t("Risk")) \(sample.usedPercent)%")
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }
}

struct HistoryEmptyState: View {
    let hasLimitSignals: Bool
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: hasLimitSignals ? "chart.line.uptrend.xyaxis" : "tray")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(hasLimitSignals ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(TokenPilotDesign.cardMuted.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("No token event history yet"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                    Text(model.t(hasLimitSignals ? "Showing limit signals until token events arrive." : "Connect Claude JSONL or Gemini telemetry to fill token charts."))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SettingsScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 10) {
                dataSources
                notificationSettings
                telegramSettings
                discordSettings
                languageSettings
                setupGuide
                privacySettings
            }
            .padding(.bottom, 16)
        }
    }

    private var dataSources: some View {
        VStack(spacing: 10) {
            SettingsCard(title: model.t("1. Data Sources"), icon: "externaldrive") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        providerToggle(.claude)
                        providerToggle(.codex)
                        providerToggle(.gemini)
                    }
                    Text(model.t("Toggle providers shown on Overview. Disabled providers are hidden and not refreshed."))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    HStack(spacing: 8) {
                        Button(model.t("Auto-detect sources")) { Task { await model.checkAllConnections() } }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        Text(model.t("Scans only local default paths and user-selected files."))
                            .font(.caption2)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(model.t("Menu bar status"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TokenPilotDesign.textSecondary)
                            Spacer(minLength: 0)
                            Picker(model.t("Menu bar status"), selection: menuBarTargetBinding) {
                                Text(model.t("Highest risk")).tag(Optional<Provider>.none)
                                ForEach(Provider.allCases) { provider in
                                    Text(model.t(provider.displayName))
                                        .tag(Optional(provider))
                                        .disabled(!model.isProviderEnabled(provider))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 170)
                        }
                        Text(model.t("Show selected provider in the menu bar. Disabled providers are skipped."))
                            .font(.caption2)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                        Text("\(model.t("Current menu bar")): \(model.menuBarTitle)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            ProviderSetupCard(provider: .claude, title: "Claude Code", status: model.sourceStatusText(.claude), statusColor: model.sourceStatusColor(.claude), detail: model.sourceDetailText(.claude)) {
                Text(model.t("Status file path"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    TextField(model.t("Claude status path"), text: $model.settings.claudeStatusFilePath)
                        .textFieldStyle(.roundedBorder)
                    Button(model.t("Choose…")) { model.chooseClaudeStatusFile() }
                }
                Text(model.t("defaultClaudePath"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Button(model.t("Check Connection")) { Task { await model.checkConnection(.claude) } }
                    .buttonStyle(.bordered)
            }

            ProviderSetupCard(provider: .gemini, title: "Gemini CLI", status: model.sourceStatusText(.gemini), statusColor: model.sourceStatusColor(.gemini), detail: model.sourceDetailText(.gemini)) {
                Text(model.t("Telemetry source"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    TextField(model.t("defaultGeminiPath1"), text: $model.settings.geminiTelemetryLogPath)
                        .textFieldStyle(.roundedBorder)
                    Button(model.t("Choose…")) { model.chooseGeminiTelemetrySource() }
                }
                Text(model.t("You can select telemetry.log or a .gemini session folder."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("Default suggestions:"))
                    Text(model.t("defaultGeminiPath1"))
                    Text(model.t("defaultGeminiPath2"))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    ForEach([1000, 1500, 2000], id: \.self) { cap in
                        Button("\(cap)") { model.settings.geminiDailyRequestCap = cap }
                            .buttonStyle(.bordered)
                            .tint(model.settings.geminiDailyRequestCap == cap ? TokenPilotDesign.calm : .secondary)
                    }
                    Stepper(String(format: model.t("Custom: %d"), model.settings.geminiDailyRequestCap), value: $model.settings.geminiDailyRequestCap, in: 1...20_000, step: 100)
                }
                Button(model.t("Check Connection")) { Task { await model.checkConnection(.gemini) } }
                    .buttonStyle(.bordered)
            }

            ProviderSetupCard(provider: .codex, title: "Codex", status: model.sourceStatusText(.codex), statusColor: model.sourceStatusColor(.codex), detail: model.sourceDetailText(.codex)) {
                Text(model.t("Limit Hints Connector"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Toggle(model.t("Use Codex Limit Hints Connector"), isOn: $model.settings.codexManual.webConnectorEnabled)
                Text(model.t("Asks the local Codex CLI app-server for account/rateLimits/read. TokenPilot does not read, store, display, or export Codex access tokens."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Text(model.t("Codex app-server limit hints are unofficial and may break if the Codex CLI changes. Disable to fall back to local activity/manual values."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.warning)
                Divider()
                    .opacity(0.35)
                Text(model.t("Manual / personal calibration fallback"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Toggle(model.t("Use Codex Web Snapshot"), isOn: $model.settings.codexManual.webSnapshotEnabled)
                Text(model.t("Enter values you see on Codex web. TokenPilot stores only these numbers, not cookies or login tokens."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Stepper(String(format: model.t("Web today tokens: %d"), model.settings.codexManual.webTodayTokens), value: $model.settings.codexManual.webTodayTokens, in: 0...100_000_000, step: 1_000)
                HStack {
                    Button(model.t("Mark Web Snapshot Now")) { model.markCodexWebSnapshotNow() }
                    if let capturedAt = model.settings.codexManual.webSnapshotCapturedAt {
                        Text("\(model.t("Captured")): \(TokenPilotFormatters.clock(capturedAt))")
                            .font(.caption)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                    }
                }
                Divider()
                    .opacity(0.25)
                TextField(model.t("Plan label"), text: $model.settings.codexManual.planLabel)
                    .textFieldStyle(.roundedBorder)
                Stepper(String(format: model.t("5h usage: %d%%"), model.settings.codexManual.fiveHourUsagePercentage), value: $model.settings.codexManual.fiveHourUsagePercentage, in: 0...100)
                Stepper(String(format: model.t("Weekly usage: %d%%"), model.settings.codexManual.weeklyUsagePercentage), value: $model.settings.codexManual.weeklyUsagePercentage, in: 0...100)
                TextField(model.t("Reset time"), text: $model.settings.codexManual.resetTimeText)
                    .textFieldStyle(.roundedBorder)
                TextField(model.t("Notes"), text: $model.settings.codexManual.notes)
                    .textFieldStyle(.roundedBorder)
                Text(model.t("Pasted /status output"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                TextEditor(text: $model.settings.codexManual.pastedStatusOutput)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Button(model.t("Paste Status")) { model.pasteCodexStatusFromClipboard() }
                    Button(model.t("Parse Status")) { model.parseCodexStatus() }
                    Text("\(model.t("Confidence")): \(model.settings.codexManual.confidence.localizedLabel(language: model.settings.localization.language))")
                        .font(.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                Text(model.t("Parsed status is marked medium or low confidence unless clearly reliable."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Button(model.t("Check Connection")) { Task { await model.checkConnection(.codex) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var notificationSettings: some View {
        SettingsCard(title: model.t("2. Notifications"), icon: "bell") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(model.t("Global notifications"), isOn: $model.settings.globalNotificationsEnabled)
                Toggle(model.t("macOS notifications"), isOn: $model.settings.macOSNotificationsEnabled)
                Toggle(model.t("Telegram notifications"), isOn: $model.settings.telegramNotificationsEnabled)
                Toggle(model.t("Discord notifications"), isOn: $model.settings.discordNotificationsEnabled)
                HStack {
                    Button(model.t("Request Notification Permission")) { Task { await model.requestNotificationPermission() } }
                    Button(model.t("Send Test Notification")) { Task { await model.sendTestNotification() } }
                    Spacer()
                    Text("\(model.t("Status")): \(model.settings.notificationPermissionStatus.localizedLabel(language: model.settings.localization.language))")
                        .font(.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                if model.settings.notificationPermissionStatus == .denied {
                    Text(model.t("Permission denied. Enable notifications in macOS Settings > Notifications."))
                        .font(.caption)
                        .foregroundStyle(TokenPilotDesign.warning)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.t("Provider/window alert rules"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    ForEach($model.settings.alertRules) { $rule in
                        AlertRuleRow(rule: $rule)
                    }
                }
            }
        }
    }

    private var telegramSettings: some View {
        SettingsCard(title: model.t("3. Telegram"), icon: "paperplane") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Toggle(model.t("Enable Telegram Alerts"), isOn: $model.settings.telegram.isEnabled)
                    Spacer()
                    StatusBadge(
                        label: model.settings.telegram.isEnabled ? model.t("ON") : model.t("OFF"),
                        color: model.settings.telegram.isEnabled ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
                    )
                    StatusBadge(
                        label: model.hasSavedTelegramToken ? model.t("Token saved") : model.t("No token"),
                        color: model.hasSavedTelegramToken ? TokenPilotDesign.calm : TokenPilotDesign.warning
                    )
                }

                SecureField(model.hasSavedTelegramToken ? model.t("Saved token hidden") : model.t("Bot Token"), text: $model.telegramTokenInput)
                    .textFieldStyle(.roundedBorder)
                TextField(model.t("Chat ID"), text: $model.settings.telegram.chatID)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(model.hasSavedTelegramToken ? model.t("Replace Token") : model.t("Save Token")) { model.saveTelegramToken() }
                    Button(model.t("Delete Token"), role: .destructive) { model.deleteTelegramToken() }
                        .disabled(!model.hasSavedTelegramToken)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(model.t("Find Chat ID")) { Task { await model.findTelegramChatID() } }
                    Button(model.t("Send Test Message")) { Task { await model.sendTelegramTest() } }
                    Spacer()
                    StatusBadge(
                        label: model.settings.telegram.chatID.isEmpty ? model.t("No chat ID") : model.t("Chat ID set"),
                        color: model.settings.telegram.chatID.isEmpty ? TokenPilotDesign.warning : TokenPilotDesign.calm
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.t("Connection status")): \(model.localizedStatus(model.settings.telegram.connectionStatus))")
                    Text("\(model.t("Last test sent at")): \(TokenPilotFormatters.clock(model.settings.telegram.lastTestSentAt))")
                }
                .font(.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)

                Text(model.t("Telegram OFF by default. Enable only after saving TokenPilot's own bot token."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Text(model.t("Telegram alerts are optional. TokenPilot stores only its own bot token Keychain item and sends only alert messages when enabled."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }

    private var discordSettings: some View {
        SettingsCard(title: model.t("4. Discord"), icon: "bubble.left.and.bubble.right") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Toggle(model.t("Enable Discord Alerts"), isOn: $model.settings.discord.isEnabled)
                    Spacer()
                    StatusBadge(
                        label: model.settings.discord.isEnabled ? model.t("ON") : model.t("OFF"),
                        color: model.settings.discord.isEnabled ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
                    )
                    StatusBadge(
                        label: model.hasSavedDiscordWebhook ? model.t("Webhook saved") : model.t("No webhook"),
                        color: model.hasSavedDiscordWebhook ? TokenPilotDesign.calm : TokenPilotDesign.warning
                    )
                }

                SecureField(model.hasSavedDiscordWebhook ? model.t("Saved webhook hidden") : model.t("Discord Webhook URL"), text: $model.discordWebhookInput)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(model.hasSavedDiscordWebhook ? model.t("Replace Webhook") : model.t("Save Webhook")) { model.saveDiscordWebhook() }
                    Button(model.t("Delete Webhook"), role: .destructive) { model.deleteDiscordWebhook() }
                        .disabled(!model.hasSavedDiscordWebhook)
                    Button(model.t("Send Test Message")) { Task { await model.sendDiscordTest() } }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.t("Connection status")): \(model.localizedStatus(model.settings.discord.connectionStatus))")
                    Text("\(model.t("Last test sent at")): \(TokenPilotFormatters.clock(model.settings.discord.lastTestSentAt))")
                }
                .font(.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)

                Text(model.t("Discord OFF by default. Paste only a Discord channel webhook created for TokenPilot."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Text(model.t("Webhook URL is stored in TokenPilot's own Keychain item and is never shown in plain text after saving."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }

    private var languageSettings: some View {
        SettingsCard(title: model.t("5. Language"), icon: "globe") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(model.t("Language"), selection: $model.settings.localization.language) {
                    ForEach(TokenPilotLanguage.allCases) { language in
                        Text(model.t(language.displayName)).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.t("Language changes may require restarting TokenPilot."))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }

    private var setupGuide: some View {
        SettingsCard(title: model.t("6. Setup Guide"), icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                GuideCard(
                    title: model.t("Connect Claude Code"),
                    status: model.sourceStatusText(.claude),
                    statusColor: model.sourceStatusColor(.claude),
                    detail: model.sourceDetailText(.claude),
                    explanation: model.t("TokenPilot reads the Claude statusline snapshot below."),
                    primaryAction: model.t("Check Connection"),
                    copyText: claudeStatuslineScript,
                    onPrimary: { Task { await model.checkConnection(.claude) } },
                    onCopy: { model.copyToClipboard(claudeStatuslineScript) }
                )
                GuideCard(
                    title: model.t("Connect Gemini CLI"),
                    status: model.sourceStatusText(.gemini),
                    statusColor: model.sourceStatusColor(.gemini),
                    detail: model.sourceDetailText(.gemini),
                    explanation: model.t("Enable local telemetry and choose telemetry.log."),
                    primaryAction: model.t("Check Connection"),
                    copyText: geminiSettingsSnippet,
                    onPrimary: { Task { await model.checkConnection(.gemini) } },
                    onCopy: { model.copyToClipboard(geminiSettingsSnippet) }
                )
                GuideCard(
                    title: model.t("Add Codex status"),
                    status: model.sourceStatusText(.codex),
                    statusColor: model.sourceStatusColor(.codex),
                    detail: model.sourceDetailText(.codex),
                    explanation: model.t("Run /status in Codex CLI and paste the result."),
                    primaryAction: model.t("Paste Status"),
                    copyText: nil,
                    onPrimary: { model.pasteCodexStatusFromClipboard() },
                    onCopy: nil
                )
                GuideCard(
                    title: model.t("Enable Notifications"),
                    status: model.settings.notificationPermissionStatus.localizedLabel(language: model.settings.localization.language),
                    explanation: model.t("Request macOS permission, then send a test alert."),
                    primaryAction: model.t("Request Permission"),
                    copyText: nil,
                    onPrimary: { Task { await model.requestNotificationPermission() } },
                    onCopy: nil
                )
                GuideCard(
                    title: model.t("Optional Telegram Alerts"),
                    status: model.localizedStatus(model.settings.telegram.connectionStatus),
                    explanation: model.t("Create a bot with BotFather, send it a message, paste token and chat ID, then test."),
                    primaryAction: model.t("Send Test Message"),
                    copyText: nil,
                    onPrimary: { Task { await model.sendTelegramTest() } },
                    onCopy: nil
                )
                GuideCard(
                    title: model.t("Optional Discord Alerts"),
                    status: model.localizedStatus(model.settings.discord.connectionStatus),
                    explanation: model.t("Create a Discord channel webhook, paste it once, then send a test message."),
                    primaryAction: model.t("Send Test Message"),
                    copyText: nil,
                    onPrimary: { Task { await model.sendDiscordTest() } },
                    onCopy: nil
                )
            }
        }
    }

    private var privacySettings: some View {
        SettingsCard(title: model.t("7. Privacy"), icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(model.t("Preview sample data when no source is connected"), isOn: $model.settings.showMockDataWhenDisconnected)
                privacyLine(model.t("Sample preview is optional and off by default so release builds never look connected before setup."))
                privacyLine(model.t("Reads local usage metadata and selected files only."))
                privacyLine(model.t("Does not read browser cookies or other Keychain items."))
                privacyLine(model.t("Codex Limit Hints Connector is opt-in and asks the local Codex CLI app-server for account/rateLimits/read; TokenPilot never reads, displays, or stores Codex access tokens."))
                privacyLine(model.t("Telegram and Discord send only alert messages when enabled."))
            }
        }
    }

    private var menuBarTargetBinding: Binding<Provider?> {
        Binding(
            get: { model.settings.menuBarDisplayTarget },
            set: { model.setMenuBarDisplayTarget($0) }
        )
    }

    private func providerToggle(_ provider: Provider) -> some View {
        Toggle(
            model.t(provider.displayName),
            isOn: Binding(
                get: { model.isProviderEnabled(provider) },
                set: { model.setProvider(provider, isEnabled: $0) }
            )
        )
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .tint(model.isProviderEnabled(provider) ? TokenPilotDesign.accent(for: provider) : .secondary)
    }

    private func sourceBlock<Content: View>(title: String, icon: String, provider: Provider, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.sourceStatusText(provider))
                    .font(.caption)
                    .foregroundStyle(model.sourceStatusColor(provider))
            }
            content()
            Text(model.sourceDetailText(provider))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func privacyLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(TokenPilotDesign.calm)
            Text(text)
                .font(.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)
        }
    }

    private var claudeStatuslineScript: String {
        """
        #!/usr/bin/env bash
        mkdir -p "$HOME/Library/Application Support/TokenPilot"
        cat > "$HOME/Library/Application Support/TokenPilot/claude-statusline.json" <<'JSON'
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 0, "resets_at": null },
            "seven_day": { "used_percentage": 0, "resets_at": null }
          },
          "context_window": {
            "current_usage": {
              "input_tokens": 0,
              "output_tokens": 0,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0
            }
          },
          "cost": { "total_cost_usd": 0 },
          "model": { "display_name": "Claude Code" }
        }
        JSON
        """
    }

    private var geminiSettingsSnippet: String {
        """
        {
          "telemetry": {
            "enabled": true,
            "target": "local",
            "log_file": "~/.gemini/telemetry.log"
          }
        }
        """
    }
}

struct ProviderSetupCard<Content: View>: View {
    let provider: Provider
    let title: String
    let status: String
    let statusColor: Color
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    ProviderSignatureMark(provider: provider, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenPilotDesign.textPrimary)
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    StatusBadge(label: status, color: statusColor)
                }

                content
            }
        }
    }
}

struct ProviderSnapshotCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshot: ProviderSnapshot

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                header
                rows
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ProviderSignatureMark(provider: snapshot.provider)

            Text(localized(snapshot.provider.displayName, language: language))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if snapshot.isStale {
                StatusBadge(label: localized("STALE", language: language), color: TokenPilotDesign.warning)
            }

            StatusBadge(
                label: snapshot.confidence.localizedLabel(language: language),
                color: TokenPilotDesign.confidenceColor(snapshot.confidence)
            )
        }
    }

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let fiveHour = snapshot.fiveHour {
                progressMetric(window: fiveHour)
            }

            if let weekly = snapshot.weekly {
                progressMetric(window: weekly)
            }

            if snapshot.provider == .gemini,
               let used = snapshot.dailyRequestsUsed,
               let limit = snapshot.dailyRequestsLimit {
                requestMetric(used: used, limit: limit)
            }

            MetricRow(
                label: localized("Today", language: language),
                value: todayValue,
                detail: todayDetail
            )

            if snapshot.provider == .gemini, let avgTokensPerRequest {
                MetricRow(
                    label: localized("Avg/request", language: language),
                    value: "\(TokenPilotFormatters.compactNumber(avgTokensPerRequest)) \(localized("tok", language: language))",
                    detail: dailyCapText
                )
            }

            if snapshot.fiveHour == nil,
               snapshot.weekly == nil,
               snapshot.dailyRequestsUsed == nil,
               snapshot.todayTokens == 0 {
                EmptyInlineState(text: localized("No limits", language: language))
            }
        }
    }

    private func progressMetric(window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            MetricRow(
                label: localized(window.label, language: language),
                value: percentText(window.usedPercent),
                detail: limitDetail(window)
            )
            ProgressLine(percent: window.usedPercent, color: TokenPilotDesign.riskColor(window.usedPercent))
        }
    }

    private func requestMetric(used: Int, limit: Int) -> some View {
        let percent = snapshot.dailyRequestsPercent ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            MetricRow(
                label: localized("Daily", language: language),
                value: "\(TokenPilotFormatters.compactNumber(used)) / \(TokenPilotFormatters.compactNumber(limit))",
                detail: "\(percent)%"
            )
            ProgressLine(percent: percent, color: TokenPilotDesign.riskColor(percent))
        }
    }

    private var todayValue: String {
        if showsCodexLocalLogOnly {
            return localized("Local log", language: language)
        }
        return "\(TokenPilotFormatters.compactNumber(snapshot.todayTokens)) \(localized("tok", language: language))"
    }

    private var todayDetail: String? {
        if showsCodexLocalLogOnly {
            return localized("Not web quota", language: language)
        }
        var parts: [String] = []
        if let cost = snapshot.todayCostUSD {
            parts.append(TokenPilotFormatters.cost(cost))
        }
        if shouldShowEstimatedLabel {
            parts.append(localized("est.", language: language))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var dailyCapText: String? {
        guard let cap = snapshot.dailyRequestsLimit else { return nil }
        return "\(localized("Daily cap", language: language)) \(TokenPilotFormatters.compactNumber(cap))"
    }

    private func percentText(_ percent: Int?) -> String {
        guard let percent else { return "—" }
        if shouldShowEstimatedLabel {
            return "\(percent)% \(localized("est.", language: language))"
        }
        return "\(percent)%"
    }

    private var shouldShowEstimatedLabel: Bool {
        snapshot.provider == .codex || snapshot.confidence == .manual
    }

    private var showsCodexLocalLogOnly: Bool {
        snapshot.isCodexLocalLogOnly
    }

    private func limitDetail(_ window: LimitWindow) -> String? {
        var parts: [String] = []
        if let remaining = window.remainingPercent {
            parts.append(String(format: localized("Remaining %d%%", language: language), remaining))
        }
        if let reset = resetText(window.resetAt) {
            parts.append(reset)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resetText(_ resetAt: Date?) -> String? {
        guard let resetAt else { return nil }
        return "\(localized("Reset", language: language)) \(TokenPilotFormatters.remainingTime(until: resetAt))"
    }

    private var requestCount: Int {
        snapshot.events.reduce(0) { $0 + $1.requestCount }
    }

    private var avgTokensPerRequest: Int? {
        guard requestCount > 0 else { return nil }
        return max(0, snapshot.todayTokens / requestCount)
    }
}

struct ProviderSignatureMark: View {
    let provider: Provider
    var size: CGFloat = 28
    @State private var isVisible = false
    @Environment(\.tokenPilotLanguage) private var language

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            TokenPilotDesign.accent(for: provider).opacity(0.24),
                            TokenPilotDesign.cardElevated.opacity(0.96)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                        .stroke(TokenPilotDesign.accent(for: provider).opacity(isVisible ? 0.56 : 0.24), lineWidth: 1)
                )
                .shadow(color: TokenPilotDesign.accent(for: provider).opacity(isVisible ? 0.24 : 0), radius: 10, x: 0, y: 4)

            providerGlyph
                .scaleEffect(isVisible ? 1 : 0.78)
                .opacity(isVisible ? 1 : 0.35)
        }
        .frame(width: size, height: size)
        .scaleEffect(isVisible ? 1 : 0.92)
        .onAppear {
            withAnimation(.spring(response: 0.72, dampingFraction: 0.78).delay(provider.startupDelay)) {
                isVisible = true
            }
        }
        .accessibilityLabel(TokenPilotLocalizer.localized(provider.displayName, language: language))
    }

    @ViewBuilder
    private var providerGlyph: some View {
        switch provider {
        case .claude:
            ZStack {
                Circle()
                    .trim(from: 0.12, to: 0.88)
                    .stroke(TokenPilotDesign.accent(for: provider), style: StrokeStyle(lineWidth: size * 0.095, lineCap: .round))
                    .rotationEffect(.degrees(isVisible ? 20 : -70))
                Circle()
                    .fill(TokenPilotDesign.accent(for: provider).opacity(0.85))
                    .frame(width: size * 0.16, height: size * 0.16)
                    .offset(x: size * 0.13, y: -size * 0.10)
            }
            .padding(size * 0.24)
        case .codex:
            VStack(alignment: .leading, spacing: size * 0.10) {
                HStack(spacing: size * 0.07) {
                    Capsule()
                        .fill(TokenPilotDesign.accent(for: provider))
                        .frame(width: size * 0.24, height: size * 0.07)
                    Capsule()
                        .fill(TokenPilotDesign.accent(for: provider).opacity(0.62))
                        .frame(width: size * 0.13, height: size * 0.07)
                }
                Capsule()
                    .fill(TokenPilotDesign.accent(for: provider))
                    .frame(width: size * 0.40, height: size * 0.07)
                Capsule()
                    .fill(TokenPilotDesign.textPrimary.opacity(isVisible ? 0.86 : 0.25))
                    .frame(width: size * 0.16, height: size * 0.07)
                    .offset(x: isVisible ? size * 0.18 : 0)
            }
            .padding(size * 0.27)
        case .gemini:
            ZStack {
                Diamond()
                    .fill(TokenPilotDesign.accent(for: provider))
                    .frame(width: size * 0.36, height: size * 0.36)
                    .rotationEffect(.degrees(isVisible ? 45 : 10))
                Diamond()
                    .fill(TokenPilotDesign.textPrimary.opacity(0.86))
                    .frame(width: size * 0.14, height: size * 0.14)
                    .offset(x: size * 0.17, y: -size * 0.16)
                    .scaleEffect(isVisible ? 1 : 0.4)
            }
        }
    }
}

struct TokenPilotBrandMark: View {
    @State private var isVisible = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(TokenPilotDesign.cardElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(TokenPilotDesign.calm.opacity(0.35), lineWidth: 1)
                )
            Text("TP")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .tracking(-0.8)
            Circle()
                .fill(TokenPilotDesign.calm)
                .frame(width: 4, height: 4)
                .offset(x: isVisible ? 7 : -7, y: -7)
        }
        .frame(width: 24, height: 24)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.74)) {
                isVisible = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct MenuBarProviderMark: View {
    let provider: Provider

    var body: some View {
        Text(provider.shortName)
            .font(.system(size: 8, weight: .heavy, design: .monospaced))
            .foregroundStyle(TokenPilotDesign.accent(for: provider))
            .frame(width: 15, height: 15)
            .background(TokenPilotDesign.accent(for: provider).opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct TokenPilotMenuBarMark: View {
    var body: some View {
        Text("TP")
            .font(.system(size: 8, weight: .heavy, design: .monospaced))
            .foregroundStyle(TokenPilotDesign.textSecondary)
            .frame(width: 15, height: 15)
            .background(TokenPilotDesign.cardMuted.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private extension Provider {
    var startupDelay: Double {
        switch self {
        case .claude: return 0.04
        case .codex: return 0.10
        case .gemini: return 0.16
        }
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let detail, !detail.isEmpty {
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProgressLine: View {
    let percent: Int?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.07))
                Capsule()
                    .fill(color.opacity(0.86))
                    .frame(width: progressWidth(in: geo.size.width))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("\(percent ?? 0)%")
    }

    private func progressWidth(in width: CGFloat) -> CGFloat {
        guard let percent else { return 0 }
        return max(percent == 0 ? 0 : 4, width * CGFloat(Double(percent) / 100.0))
    }
}

struct EmptyInlineState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(TokenPilotDesign.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        GlassCard {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .overlay(
                Capsule().stroke(color.opacity(0.22), lineWidth: 1)
            )
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct SevenDayBarChart: View {
    @Environment(\.tokenPilotLanguage) private var language
    let bars: [DailyUsageBar]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                Label(localized("7-day usage", language: language), systemImage: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(bars) { bar in
                        VStack(spacing: 6) {
                            GeometryReader { geo in
                                VStack { Spacer(minLength: 0)
                                    if bar.tokens > 0 {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(barGradient(ratio: ratio(for: bar)))
                                        .frame(height: max(5, geo.size.height * ratio(for: bar)))
                                }
                                }
                            }
                            .frame(height: 74)
                            Text(bar.dayLabel)
                                .font(.caption2)
                                .foregroundStyle(TokenPilotDesign.textSecondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func barGradient(ratio: CGFloat) -> LinearGradient {
        LinearGradient(
            colors: [
                TokenPilotDesign.calm.opacity(0.70 + 0.30 * ratio),
                TokenPilotDesign.calm.opacity(0.45)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func ratio(for bar: DailyUsageBar) -> CGFloat {
        let maxValue = max(bars.map(\.tokens).max() ?? 1, 1)
        return CGFloat(Double(bar.tokens) / Double(maxValue))
    }
}

struct ProviderShareRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    let shares: [ProviderShare]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                Label(localized("Provider share", language: language), systemImage: "circle.grid.cross")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                ForEach(shares) { share in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(localized(share.provider.displayName, language: language))
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(share.percent)%")
                                .font(.system(.caption, design: .monospaced).weight(.bold))
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(TokenPilotDesign.accent(for: share.provider))
                                    .frame(width: max(5, geo.size.width * CGFloat(Double(share.percent) / 100.0)))
                            }
                        }
                        .frame(height: 7)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AlertRuleRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    @Binding var rule: AlertRule

    var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("\\(localized(rule.provider.displayName, language: language)) · \\(rule.window.localizedLabel(language: language))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    Spacer()
                    AlertTogglePill(label: localized("macOS", language: language), isOn: $rule.macOSEnabled)
                    AlertTogglePill(label: localized("TG", language: language), isOn: $rule.telegramEnabled)
                    AlertTogglePill(label: localized("DC", language: language), isOn: $rule.discordEnabled)
                }
            HStack(spacing: 6) {
                AlertTogglePill(label: localized("Reset", language: language), isOn: $rule.resetEnabled)
                AlertTogglePill(label: "50", isOn: $rule.fiftyEnabled)
                AlertTogglePill(label: "80", isOn: $rule.eightyEnabled)
                AlertTogglePill(label: "100", isOn: $rule.hundredEnabled)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct AlertTogglePill: View {
    @Environment(\.tokenPilotLanguage) private var language
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text("\(label) \(isOn ? localized("ON", language: language) : localized("OFF", language: language))")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isOn ? TokenPilotDesign.calm.opacity(0.16) : TokenPilotDesign.cardMuted)
                .overlay(
                    Capsule().stroke(isOn ? TokenPilotDesign.calm.opacity(0.22) : TokenPilotDesign.border, lineWidth: 1)
                )
                .foregroundStyle(isOn ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct GuideCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    let title: String
    let status: String
    var statusColor: Color = TokenPilotDesign.textSecondary
    var detail: String? = nil
    let explanation: String
    let primaryAction: String
    let copyText: String?
    let onPrimary: () -> Void
    let onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                Spacer()
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Text(explanation)
                .font(.caption2)
                .foregroundStyle(TokenPilotDesign.textSecondary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack {
                Button(primaryAction, action: onPrimary)
                    .buttonStyle(.bordered)
                if copyText != nil, let onCopy {
                    Button(localized("Copy", language: language), action: onCopy)
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                content
            }
        }
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = TokenPilotDesign.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LiquidGlassBackground(cornerRadius: TokenPilotDesign.cardRadius, intensity: 1.0)
            }
            .overlay(
                RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous)
                    .stroke(TokenPilotDesign.glassEdgeGlow, lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Liquid Glass Components

/// NSVisualEffectView-backed frosted glass for macOS
private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Frosted glass backdrop + liquid shimmer overlay
private struct LiquidGlassBackground: View {
    var cornerRadius: CGFloat = 14
    var intensity: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Glass material — samples frosted root behind for layered depth
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)

            // Dark tint for readability
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.18 * intensity))

            // Liquid inner glow — subtle top-left illumination
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(TokenPilotDesign.glassInnerGlow)

            // Edge highlight line (top/left)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08 * intensity),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.0
                )
                .padding(0.5)
        }
    }
}


