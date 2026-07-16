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
    @Published var selectedHistoryPeriod: HistoryPeriod = .last7Days
    @Published var snapshots: [ProviderSnapshot] = []
    @Published var historySnapshots: [ProviderSnapshot] = []
    @Published var limitHistorySamples: [ProviderLimitSample] = []
    @Published var overviewUsage = AggregatedUsage(period: .today)
    @Published var historyUsage = AggregatedUsage(period: .today)
    @Published var isRefreshing = false
    @Published var dataSourceMode: DataSourceMode = .disconnected
    @Published var connectionStatus: [Provider: String] = [:]
    @Published var dataSources: [Provider: ProviderDataSource] = [:]
    @Published var exportFormat: UsageExportFormat = .json
    @Published var capacityAssessments: [CapacityAssessment] = []
    @Published var capacityPresentations: [CapacityPresentation] = []
    @Published var capacityRefreshErrors: [CapacityRefreshError] = []
    @Published var capacityRuntimeRecoveryRequired = false
    @Published private var capacityAlertRuntimeControl = CapacityRuntimeControl()
    @Published private var capacityAlertRuntimeRecoveryStatus: CapacityPersistenceStatus = .ready(source: .absentDefault, generation: nil)
    @Published private var capacityAlertRules: [CapacityAlertRule] = []
    @Published private var capacityAlertRulesRecoveryStatus: CapacityPersistenceStatus = .ready(source: .absentDefault, generation: nil)
    @Published private var capacityAlertDeliveryStates: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState] = [:]
    @Published private var capacityAlertDeliveryRecoveryStatus: CapacityPersistenceStatus = .ready(source: .absentDefault, generation: nil)
    @Published private var capacityAlertMigrationRecoveryStatus: CapacityPersistenceStatus?
    @Published var bannerMessage: String?
    @Published var telegramTokenInput = ""
    @Published var discordWebhookInput = ""
    @Published var deepSeekAPIKeyInput = ""
    @Published var hasSavedTelegramToken = false
    @Published var hasSavedDiscordWebhook = false
    @Published var hasSavedDeepSeekAPIKey = false
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
    private let localNotificationService = LocalNotificationService()
    private let telegramService = TelegramNotificationService()
    private let discordService = DiscordNotificationService()
    private let keychain = KeychainService()
    private let capacityEvidenceStore = CapacityEvidenceStore()
    private let capacityRuntimeStore = CapacityRuntimeStore()
    private let capacityAlertRuleStore = CapacityAlertRuleStore()
    private let capacityAlertDeliveryStore = CapacityAlertDeliveryStore()
    private let capacityAlertMigrationCoordinator = CapacityAlertLegacyMigrationCoordinator()
    private let capacityAssessmentService = CapacityAssessmentService()
    private let capacityPresentationMapper = CapacityPresentationMapper()
    private let capacityAlertTransitionEngine = CapacityAlertTransitionEngine()
    private let capacityAlertVisibilityBuilder = CapacityAlertVisibilityBuilder()
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
#if DEBUG
    private let debugFixtureMode: Bool
#endif


#if DEBUG
    init(debugFixture: TokenPilotDebugFixture? = TokenPilotDebugFixture.resolve()) {
        self.debugFixtureMode = debugFixture != nil
        self.settings = debugFixture?.settings ?? settingsStore.load()
        self.hasSavedTelegramToken = false
        self.hasSavedDiscordWebhook = false
        self.hasSavedDeepSeekAPIKey = false

        if let debugFixture {
            applyDebugFixture(debugFixture)
        } else {
            startProductionRuntime()
        }
    }
#else
    init() {
        self.settings = settingsStore.load()
        self.hasSavedTelegramToken = false
        self.hasSavedDiscordWebhook = false
        self.hasSavedDeepSeekAPIKey = false
        startProductionRuntime()
    }
#endif

    private func startProductionRuntime() {
        startAutoRefresh()
        Task {
            await updatePermissionStatus()
            await refresh(reason: .automaticTimer)
            refreshStoredCredentialPresence()
        }
    }

#if DEBUG
    private func applyDebugFixture(_ fixture: TokenPilotDebugFixture) {
        selectedScreen = fixture.selectedScreen
        selectedHistoryPeriod = .last7Days
        menuBarNow = fixture.referenceDate
        snapshots = fixture.snapshots
        historySnapshots = fixture.historySnapshots
        limitHistorySamples = fixture.limitHistorySamples
        overviewUsage = aggregationService.aggregate(snapshots: fixture.historySnapshots, period: .today)
        historyUsage = aggregationService.aggregate(snapshots: fixture.historySnapshots, period: selectedHistoryPeriod)
        isRefreshing = false
        dataSourceMode = fixture.dataSourceMode
        dataSources = fixture.dataSources
        connectionStatus = Dictionary(uniqueKeysWithValues: fixture.dataSources.values.map { ($0.provider, sourceStatusText($0)) })
        capacityAssessments = fixture.capacityAssessments
        capacityPresentations = fixture.capacityPresentations
        capacityRefreshErrors = fixture.capacityRefreshErrors
        capacityRuntimeRecoveryRequired = fixture.capacityRuntimeRecoveryRequired
        capacityAlertRuntimeControl = fixture.capacityAlertRuntimeControl
        capacityAlertRuntimeRecoveryStatus = fixture.capacityAlertRuntimeRecoveryStatus
        capacityAlertRules = fixture.capacityAlertRules
        capacityAlertRulesRecoveryStatus = fixture.capacityAlertRulesRecoveryStatus
        capacityAlertDeliveryStates = fixture.capacityAlertDeliveryStates
        capacityAlertDeliveryRecoveryStatus = fixture.capacityAlertDeliveryRecoveryStatus
        capacityAlertMigrationRecoveryStatus = fixture.capacityAlertMigrationRecoveryStatus
        bannerMessage = fixture.bannerMessage
        telegramTokenInput = ""
        discordWebhookInput = ""
        deepSeekAPIKeyInput = ""
        hasSavedTelegramToken = fixture.hasSavedTelegramToken
        hasSavedDiscordWebhook = fixture.hasSavedDiscordWebhook
        hasSavedDeepSeekAPIKey = fixture.hasSavedDeepSeekAPIKey
        refreshInProgress = false
        refreshQueued = false
        lastRefreshFinishedAt = fixture.referenceDate
        stopAutoRefresh()
    }
    private func blockDebugFixtureExternalAction() -> Bool {
        guard debugFixtureMode else { return false }
        bannerMessage = "DEBUG fixture mode disables external provider, file, keychain, and notification actions."
        return true
    }
#endif

    func refreshStoredCredentialPresence() {
#if DEBUG
        guard !debugFixtureMode else { return }
#endif
        Task {
            hasSavedTelegramToken = ((try? keychain.readSecret(account: Self.telegramTokenAccount)) ?? nil) != nil
            hasSavedDiscordWebhook = ((try? keychain.readSecret(account: Self.discordWebhookAccount)) ?? nil) != nil
            let hasDeepSeekKey = ((try? keychain.readSecret(account: Self.deepSeekAPIKeyAccount)) ?? nil) != nil
            hasSavedDeepSeekAPIKey = hasDeepSeekKey
            if settings.deepseekAPIKeyConfigured != hasDeepSeekKey {
                settings.deepseekAPIKeyConfigured = hasDeepSeekKey
            }
        }
    }

    static let telegramTokenAccount = "telegram.botToken"
    static let discordWebhookAccount = "discord.webhookURL"
    static let deepSeekAPIKeyAccount = "deepseek.apiKey"

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

    var menuBarSystemImage: String {
        guard let snapshot = menuBarStatusService.selectedSnapshot(from: snapshots, settings: settings) else {
            return "chart.bar.xaxis"
        }
        return snapshot.provider.iconName
    }

    var lowestRemainingSummary: MenuBarLowestRemainingSummary? {
        menuBarStatusService.lowestRemainingSummary(snapshots: snapshots, settings: settings)
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


    private var enabledSnapshots: [ProviderSnapshot] {
        menuBarStatusService.presentationSnapshots(from: snapshots, settings: settings)
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

    var capacityAlertSummary: CapacityAlertVisibilitySummary {
        capacityAlertVisibilityBuilder.make(
            runtime: capacityAlertRuntimeControl,
            runtimeStatus: capacityAlertRuntimeRecoveryStatus,
            rules: capacityAlertRules,
            rulesStatus: capacityAlertRulesRecoveryStatus,
            deliveryStates: capacityAlertDeliveryStates,
            deliveryStatus: capacityAlertDeliveryRecoveryStatus,
            migrationStatus: capacityAlertMigrationRecoveryStatus,
            channels: currentCapacityAlertChannels
        )
    }

    var capacityAlertRows: [CapacityAlertVisibilityRow] {
        capacityAlertSummary.rows
    }

    var alertStatusText: String {
        let summary = capacityAlertSummary
        var parts = [capacityAlertChannelPreferenceSummary()]

        if summary.recoveryRequired {
            let codes = summary.recoveryCodes.joined(separator: "/")
            parts.append(codes.isEmpty ? t("Recovery needed") : String(format: t("capacity.alert.recovery.codes.format"), t("Recovery needed"), codes))
        } else {
            switch summary.status {
            case .deliverable:
                parts.append(String(format: t("capacity.alert.rule.count.status"), summary.deliverableRuleCount, t("Alerts"), t("ON")))
            case .pendingBalanceBinding:
                parts.append(t("Pending balance"))
            case .unsupportedSource:
                parts.append(t("Unsupported source"))
            case .disabled:
                parts.append(t("Disabled"))
            case .noEffectiveChannel:
                parts.append(t("No effective notification channels."))
            case .recoveryRequired:
                parts.append(t("Recovery needed"))
            case .noRules:
                parts.append(t("No trusted capacity"))
            }
        }

        if summary.pendingDeliveryCount > 0 {
            parts.append(String(format: t("capacity.alert.delivery.pending.count"), summary.pendingDeliveryCount))
        }
        if summary.failedDeliveryCount > 0 {
            parts.append(String(format: t("capacity.alert.delivery.failed.count"), summary.failedDeliveryCount))
        }
        return String(format: t("capacity.alert.status.format"), t("Alerts"), parts.joined(separator: t("capacity.alert.segment.separator")))
    }

    private var currentCapacityAlertChannels: CapacityAlertChannelSettings {
        CapacityAlertChannelSettings(
            settings: settings,
            telegramCredentialPresent: hasSavedTelegramToken || !telegramTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            discordCredentialPresent: hasSavedDiscordWebhook || !discordWebhookInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private func capacityAlertChannelPreferenceSummary() -> String {
        let on = t("ON")
        let off = t("OFF")
        let global = settings.globalNotificationsEnabled ? on : off
        let mac = settings.macOSNotificationsEnabled ? on : off
        let telegram = settings.telegramNotificationsEnabled && settings.telegram.isEnabled ? on : off
        let discord = settings.discordNotificationsEnabled && settings.discord.isEnabled ? on : off
        return String(format: t("capacity.alert.channel.preference.format"), t("Global"), global, t("macOS"), mac, t("Telegram"), telegram, t("Discord"), discord)
    }

    private func capacityAlertJoinedText(_ leading: String, _ trailing: String) -> String {
        String(format: t("capacity.alert.segment.format"), leading, trailing)
    }

    func capacityAlertRowTitle(_ row: CapacityAlertVisibilityRow) -> String {
        if let provider = row.provider {
            return t(provider.displayName)
        }
        switch row.kind {
        case .recoveryRequired:
            return t("Recovery needed")
        case .empty:
            return t("No trusted capacity")
        case .capacityRule, .pendingBalanceBinding, .unsupportedNotice:
            return t("Alerts")
        }
    }

    func capacityAlertRowSubtitle(_ row: CapacityAlertVisibilityRow) -> String {
        switch row.kind {
        case .capacityRule, .pendingBalanceBinding:
            let window = row.seriesID.map { capacityWindowDisplayName(for: $0) } ?? t("Limit")
            let condition = capacityAlertConditionText(row)
            return condition.isEmpty ? window : capacityAlertJoinedText(window, condition)
        case .unsupportedNotice:
            return t("Unsupported source")
        case .recoveryRequired:
            return row.recoveryWriteBlocked ? capacityAlertJoinedText(t("Recovery needed"), t("write-blocked")) : t("Recovery needed")
        case .empty:
            return t("No trusted capacity")
        }
    }

    func capacityAlertRowDetail(_ row: CapacityAlertVisibilityRow) -> String {
        switch row.kind {
        case .capacityRule:
            if row.status == .noEffectiveChannel {
                return t("No effective notification channels.")
            }
            return capacityAlertConditionText(row)
        case .pendingBalanceBinding:
            return t("Save a DeepSeek API key to enable official balance checks.")
        case .unsupportedNotice:
            if row.provider == .codex {
                return t("Codex limit hints are experimental and may break if the Codex CLI changes. They are not guaranteed official quota.")
            }
            if row.provider == .gemini {
                return t("Unsupported source")
            }
            return t("Unsupported source")
        case .recoveryRequired:
            let code = row.recoveryCode.map { " \($0)" } ?? ""
            return "\(t("Capacity alerts use safe defaults until local runtime state is readable again."))\(code)"
        case .empty:
            return t("No trusted capacity")
        }
    }

    func capacityAlertRowStatusText(_ row: CapacityAlertVisibilityRow) -> String {
        switch row.status {
        case .deliverable:
            return t("Effective ON")
        case .disabled:
            return t("Disabled")
        case .noEffectiveChannel:
            return t("Effective OFF")
        case .pendingBalanceBinding:
            return t("Pending balance")
        case .unsupportedSource:
            return t("Unsupported source")
        case .recoveryRequired:
            return t("Recovery needed")
        case .noRules:
            return t("No trusted capacity")
        }
    }

    func capacityAlertRowStatusColor(_ row: CapacityAlertVisibilityRow) -> Color {
        switch row.status {
        case .deliverable:
            return TokenPilotDesign.calm
        case .disabled, .noRules:
            return TokenPilotDesign.textSecondary
        case .pendingBalanceBinding, .unsupportedSource, .noEffectiveChannel, .recoveryRequired:
            return TokenPilotDesign.warning
        }
    }

    func capacityAlertChannelPillText(_ channel: CapacityAlertVisibilityChannel) -> String {
        let label: String
        switch channel.channel {
        case .macOS:
            label = t("macOS")
        case .telegram:
            label = t("TG")
        case .discord:
            label = t("DC")
        }
        let state = channel.effective ? t("ON") : t("OFF")
        guard let deliveryStatus = channel.deliveryStatus else {
            return String(format: t("capacity.alert.channel.state.format"), label, state)
        }
        return String(format: t("capacity.alert.pill.status.format"), label, state, capacityAlertDeliveryStatusText(deliveryStatus))
    }

    private func capacityAlertDeliveryStatusText(_ status: CapacityAlertDeliveryStatus) -> String {
        switch status {
        case .idle:
            return t("Idle")
        case .pending:
            return t("Pending")
        case .delivered:
            return t("Delivered")
        case .failed:
            return t("Failed")
        }
    }

    func capacityAlertChannelPillColor(_ channel: CapacityAlertVisibilityChannel) -> Color {
        guard channel.routed else { return TokenPilotDesign.textSecondary.opacity(0.55) }
        if channel.deliveryStatus == .failed { return TokenPilotDesign.warning }
        return channel.effective ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
    }

    private func capacityAlertConditionText(_ row: CapacityAlertVisibilityRow) -> String {
        switch row.conditionKind {
        case .percentThresholds:
            return row.percentThresholds.map { threshold in
                switch threshold {
                case .reset: return t("Reset")
                case .fifty: return "50%"
                case .eighty: return "80%"
                case .hundred: return "100%"
                }
            }.joined(separator: "/")
        case .balanceBelow:
            guard let threshold = row.balanceThresholdCanonical, let currency = row.balanceCurrency else { return "" }
            return "< \(threshold) \(currency)"
        case .pendingBalanceCurrencyBinding:
            return t("Pending balance")
        case nil:
            return ""
        }
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
            case .itemNotFound:
                return t("No saved credential found in Keychain.")
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
#if DEBUG
        guard !debugFixtureMode else { return }
#endif
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
#if DEBUG
        guard !debugFixtureMode else { return }
#endif
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
#if DEBUG
        guard !debugFixtureMode else { return }
#endif
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
#if DEBUG
        guard !debugFixtureMode else { return }
#endif
        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task { [weak self, settingsRefreshDebounceNanoseconds] in
            try? await Task.sleep(nanoseconds: settingsRefreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.refresh(reason: .settings)
        }
    }

    func refresh(reason: RefreshReason = .manual) async {
#if DEBUG
        guard !debugFixtureMode else {
            isRefreshing = false
            return
        }
#endif
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
        await processCapacity(result: result, settingsAtStart: settingsAtStart)
        let usageSettingsChanged = TokenPilotRefreshPolicy.usageRefreshNeeded(from: settingsAtStart, to: settings)
        if usageSettingsChanged {
            scheduleSettingsDrivenRefresh()
        }
    }
    private func processCapacity(result: UsageStore.Result, settingsAtStart: AppSettings) async {
        capacityRefreshErrors = result.capacityErrors

        if !result.capacityObservations.isEmpty {
            _ = await capacityEvidenceStore.record(result.capacityObservations)
        }

        let runtimeLoad = await capacityRuntimeStore.load()
        capacityRuntimeRecoveryRequired = runtimeLoad.recoveryStatus.recoveryRequired
        capacityAlertRuntimeControl = runtimeLoad.control
        capacityAlertRuntimeRecoveryStatus = runtimeLoad.recoveryStatus

        let presentationEnabled = runtimeLoad.control.assessmentEnabled && !runtimeLoad.recoveryStatus.recoveryRequired
        let assessments = presentationEnabled
            ? result.capacityObservations.map { capacityAssessmentService.assess($0, now: result.observedAt) }
            : []
        capacityAssessments = assessments
        capacityPresentations = presentationEnabled ? assessments.map(capacityPresentationMapper.map) : []

        let officialDeepSeekBalance = result.snapshots.first {
            $0.provider == .deepseek && $0.dataSource == .officialTelemetry && !$0.isStale
        }?.balance
        let migration = await capacityAlertMigrationCoordinator.migrate(settings: settingsAtStart, deepSeekBalance: officialDeepSeekBalance)
        capacityAlertMigrationRecoveryStatus = migration.recoveryStatus.recoveryRequired ? migration.recoveryStatus : nil

        let rulesLoad = await capacityAlertRuleStore.load()
        let deliveryLoad = await capacityAlertDeliveryStore.load()
        capacityAlertRules = rulesLoad.rules
        capacityAlertRulesRecoveryStatus = rulesLoad.recoveryStatus
        capacityAlertDeliveryStates = deliveryLoad.states
        capacityAlertDeliveryRecoveryStatus = deliveryLoad.recoveryStatus
        let channels = CapacityAlertChannelSettings(
            settings: settingsAtStart,
            telegramCredentialPresent: hasSavedTelegramToken || !telegramTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            discordCredentialPresent: hasSavedDiscordWebhook || !discordWebhookInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        let transition = capacityAlertTransitionEngine.evaluate(
            rules: rulesLoad.rules,
            assessments: assessments,
            previousStates: deliveryLoad.states,
            channels: channels,
            runtime: runtimeLoad.control,
            rulesReadable: !runtimeLoad.recoveryStatus.recoveryRequired && rulesLoad.deliveryEnabled,
            deliveryReadable: !runtimeLoad.recoveryStatus.recoveryRequired && deliveryLoad.deliveryEnabled,
            now: result.observedAt
        )

        guard !transition.deliveryBlocked else { return }
        let outcomes = await deliverCapacity(transition.attempts)
        let updatedStates = capacityAlertTransitionEngine.applyingDeliveryOutcomes(outcomes, to: transition.states)
        let deliverySave = await capacityAlertDeliveryStore.save(updatedStates)
        capacityAlertDeliveryStates = updatedStates
        capacityAlertDeliveryRecoveryStatus = deliverySave.recoveryStatus
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
#if DEBUG
        guard !debugFixtureMode else {
            historyUsage = aggregationService.aggregate(snapshots: historySnapshots, period: period)
            return
        }
#endif
        historyUsage = aggregationService.aggregate(snapshots: historySnapshots, period: period)
        limitHistorySamples = limitHistoryStore.samples(period: period, enabledProviders: Set(settings.enabledProviders))
    }

    func updatePermissionStatus() async {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        settings.notificationPermissionStatus = await localNotificationService.permissionStatus()
    }

    func requestNotificationPermission() async {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        settings.notificationPermissionStatus = await localNotificationService.requestPermission()
        if settings.notificationPermissionStatus == .denied {
            bannerMessage = t("Permission denied. Enable notifications in macOS Settings > Notifications.")
        } else {
            bannerMessage = String(format: t("Notification permission: %@"), settings.notificationPermissionStatus.localizedLabel(language: settings.localization.language))
        }
    }

    func sendTestNotification() async {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        guard settings.globalNotificationsEnabled else {
            bannerMessage = t("No notification channel is enabled or configured.")
            return
        }

        do {
            let hasStoredTelegramToken = hasSavedTelegramToken || !telegramTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasStoredDiscordWebhook = hasSavedDiscordWebhook || !discordWebhookInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasTelegramChatID = !settings.telegram.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var sentChannelCount = 0

            if settings.globalNotificationsEnabled && settings.macOSNotificationsEnabled {
                try await localNotificationService.send(title: t("TokenPilot"), body: t("✅ TokenPilot test alert. macOS notifications are connected."))
                sentChannelCount += 1
            }
            if settings.globalNotificationsEnabled && settings.telegramNotificationsEnabled && settings.telegram.isEnabled && hasStoredTelegramToken && hasTelegramChatID {
                try await sendTelegram(text: t("✅ TokenPilot test alert. Telegram notifications are connected."))
                sentChannelCount += 1
            }
            if settings.globalNotificationsEnabled && settings.discordNotificationsEnabled && settings.discord.isEnabled && hasStoredDiscordWebhook {
                try await sendDiscord(text: t("✅ TokenPilot test alert. Discord notifications are connected."))
                sentChannelCount += 1
            }
            guard sentChannelCount > 0 else {
                bannerMessage = t("No notification channel is enabled or configured.")
                return
            }
            bannerMessage = t("Test notification sent.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func chooseClaudeStatusFile() {
        chooseLocalSource(
            provider: .claude,
            prompt: t("Choose Claude source"),
            message: t("Choose Claude statusline JSON or a .claude/projects folder."),
            canChooseDirectories: true
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
            prompt: t("Choose Antigravity source"),
            message: t("Choose antigravity-statusline.json, legacy telemetry.log, or a session folder."),
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
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
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
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        let source = await connectionService.check(settings: settings, provider: provider)
        dataSources[provider] = source
        connectionStatus[provider] = sourceStatusText(source)
        bannerMessage = "\(t(provider.displayName)): \(sourceStatusText(source))"
    }

    func checkAllConnections() async {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        let initialSources = await connectionService.checkAll(settings: settings)
        let adoption = connectionService.applyingPreferredDetectedSources(settings: settings, sources: initialSources)
        if adoption.settings != settings {
            settings = adoption.settings
            let adoptedNames = adoption.adoptedProviders.map { t($0.displayName) }.joined(separator: ", ")
            applyDataSources(await connectionService.checkAll(settings: adoption.settings))
            await refresh(reason: .settings)
            bannerMessage = adoptedNames.isEmpty
                ? t("Connection check complete.")
                : String(format: t("Auto-detected sources: %@"), adoptedNames)
        } else {
            applyDataSources(initialSources)
            bannerMessage = t("Connection check complete.")
        }
    }

    private func applyDataSources(_ sources: [ProviderDataSource]) {
        dataSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.provider, $0) })
        connectionStatus = Dictionary(uniqueKeysWithValues: sources.map { ($0.provider, sourceStatusText($0)) })
    }

    func sourceStatusText(_ provider: Provider) -> String {
        guard let source = dataSources[provider] else {
            if provider == .deepseek {
                return settings.deepseekAPIKeyConfigured ? t("API key saved") : t("API key required")
            }
            return t("Not checked")
        }
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
        if provider == .deepseek {
            return settings.deepseekAPIKeyConfigured
                ? t("DeepSeek API key saved in TokenPilot Keychain item.")
                : t("Save a DeepSeek API key to enable official balance checks.")
        }
        guard let source = dataSources[provider] else { return t("Run Check Connection to scan local paths.") }
        if provider == .codex {
            if settings.codexManual.webConnectorEnabled {
                return t("Asks the local Codex CLI app-server for account/rateLimits/read. TokenPilot does not read, store, display, or export Codex access tokens.")
            }
            if connectionService.preferredUsablePath(in: source) != nil {
                return "\(t("Detected")) · \(t("Local log")) · \(t("Not web quota"))"
            }
            return t("Run /status in Codex CLI and paste the result.")
        }
        if connectionService.preferredUsablePath(in: source) != nil {
            return "\(t("Detected")) · \(t("Local source"))"
        }
        let found = source.detectedPaths.filter(\.exists).count
        let total = source.detectedPaths.count
        return "\(t("Detected paths")): \(found)/\(total)"
    }

    var providerDiagnostics: [ProviderConnectionDiagnostic] {
        Provider.allCases.map { provider in
            if let source = dataSources[provider] {
                return source.connectionDiagnostic()
            }
            if provider == .deepseek {
                return ProviderDataSource(
                    provider: provider,
                    isEnabled: settings.isProviderEnabled(provider),
                    status: settings.isProviderEnabled(provider) ? (settings.deepseekAPIKeyConfigured ? .connected : .manual) : .disabled,
                    confidence: settings.deepseekAPIKeyConfigured ? .medium : .manual,
                    statusMessage: settings.deepseekAPIKeyConfigured ? "API key saved in Keychain" : "API key required"
                ).connectionDiagnostic()
            }
            return ProviderDataSource(
                provider: provider,
                isEnabled: settings.isProviderEnabled(provider),
                status: settings.isProviderEnabled(provider) ? .notFound : .disabled,
                confidence: .low
            ).connectionDiagnostic()
        }
    }

    func diagnosticStatusText(_ diagnostic: ProviderConnectionDiagnostic) -> String {
        if diagnostic.provider == .deepseek {
            switch diagnostic.status {
            case .connected:
                return t("Connected") + " · " + t("API key saved")
            case .manual:
                return t("Manual mode") + " · " + t("API key required")
            default:
                break
            }
        }
        return sourceStatusText(
            ProviderDataSource(
                provider: diagnostic.provider,
                isEnabled: diagnostic.status != .disabled,
                lastScanAt: diagnostic.lastCheckedAt,
                status: diagnostic.status,
                confidence: diagnostic.confidence
            )
        )
    }

    func diagnosticLastCheckedText(_ diagnostic: ProviderConnectionDiagnostic) -> String {
        guard let lastCheckedAt = diagnostic.lastCheckedAt else {
            return t("Never checked")
        }
        return TokenPilotFormatters.clock(lastCheckedAt)
    }

    func diagnosticNextActionText(_ diagnostic: ProviderConnectionDiagnostic) -> String {
        t(diagnostic.nextAction.localizationKey)
    }

    func diagnosticDetailText(_ diagnostic: ProviderConnectionDiagnostic) -> String {
        t(diagnostic.redactedDetail)
    }

    func diagnosticStatusColor(_ diagnostic: ProviderConnectionDiagnostic) -> Color {
        switch diagnostic.status {
        case .connected: return TokenPilotDesign.calm
        case .stale, .estimated, .manual, .noUsableData: return TokenPilotDesign.warning
        case .notFound, .permissionDenied, .invalidFormat: return TokenPilotDesign.danger
        case .disabled: return TokenPilotDesign.textSecondary
        }
    }

    func sourceStatusColor(_ provider: Provider) -> Color {
        guard let status = dataSources[provider]?.status else {
            if provider == .deepseek {
                return settings.deepseekAPIKeyConfigured ? TokenPilotDesign.calm : TokenPilotDesign.warning
            }
            return TokenPilotDesign.textSecondary
        }
        switch status {
        case .connected: return TokenPilotDesign.calm
        case .stale, .estimated, .manual, .noUsableData: return TokenPilotDesign.warning
        case .notFound, .permissionDenied, .invalidFormat: return TokenPilotDesign.danger
        case .disabled: return TokenPilotDesign.textSecondary
        }
    }

    func exportHistory() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        do {
            let data = try exportService.export(
                usage: historyUsage,
                snapshots: filteredSnapshots,
                dataMode: dataSourceMode.displayLabel,
                format: exportFormat,
                capacityAssessments: capacityAssessments
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
        var parsed = CodexStatusParser.safeParse(
            settings.codexManual.pastedStatusOutput,
            previous: settings.codexManual
        )
        parsed.pastedStatusOutput = ""
        settings.codexManual = parsed
        connectionStatus[.codex] = "\(t("Parsed /status")) · \(settings.codexManual.confidence.localizedLabel(language: settings.localization.language))"
    }

    func pasteCodexStatusFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            var parsed = CodexStatusParser.safeParse(string, previous: settings.codexManual)
            parsed.pastedStatusOutput = ""
            settings.codexManual = parsed
            connectionStatus[.codex] = "\(t("Parsed /status")) · \(settings.codexManual.confidence.localizedLabel(language: settings.localization.language))"
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


    private func updateDeepSeekDataSourceForCredentialState() {
        let source = ProviderDataSource(
            provider: .deepseek,
            isEnabled: settings.isProviderEnabled(.deepseek),
            mode: settings.deepseekAPIKeyConfigured ? .auto : .custom,
            lastScanAt: Date(),
            status: settings.deepseekAPIKeyConfigured ? .connected : .manual,
            confidence: settings.deepseekAPIKeyConfigured ? .medium : .manual,
            statusMessage: settings.deepseekAPIKeyConfigured ? "API key saved in Keychain" : "API key required"
        )
        dataSources[.deepseek] = source
        connectionStatus[.deepseek] = sourceStatusText(source)
    }

    func saveDeepSeekAPIKey() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        let key = deepSeekAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            bannerMessage = t("Enter a DeepSeek API key first.")
            return
        }
        do {
            try keychain.saveSecret(key, account: Self.deepSeekAPIKeyAccount)
            deepSeekAPIKeyInput = ""
            hasSavedDeepSeekAPIKey = true
            settings.deepseekAPIKeyConfigured = true
            updateDeepSeekDataSourceForCredentialState()
            bannerMessage = t("DeepSeek API key saved in TokenPilot Keychain item.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func deleteDeepSeekAPIKey() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        do {
            try keychain.deleteSecret(account: Self.deepSeekAPIKeyAccount)
            deepSeekAPIKeyInput = ""
            hasSavedDeepSeekAPIKey = false
            settings.deepseekAPIKeyConfigured = false
            updateDeepSeekDataSourceForCredentialState()
            bannerMessage = t("DeepSeek API key deleted.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func saveTelegramToken() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
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
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        do {
            try keychain.deleteSecret(account: Self.telegramTokenAccount)
            telegramTokenInput = ""
            hasSavedTelegramToken = false
            settings.telegram.isEnabled = false
            settings.telegramNotificationsEnabled = false
            settings.telegram.connectionStatus = "Not configured"
            bannerMessage = t("Telegram token deleted.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func sendTelegramTest() async {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
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
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
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
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
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
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
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
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
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

    private func deliverCapacity(_ attempts: [CapacityAlertDeliveryAttempt]) async -> [CapacityAlertDeliveryOutcome] {
        guard !attempts.isEmpty else { return [] }
        var outcomes: [CapacityAlertDeliveryOutcome] = []
        for attempt in attempts {
            guard attempt.provider != .codex, attempt.provider != .gemini else {
                outcomes.append(CapacityAlertDeliveryOutcome(attempt: attempt, succeeded: false, completedAt: Date()))
                continue
            }
            let message = capacityAlertMessage(for: attempt)
            let succeeded: Bool
            do {
                switch attempt.key.channel {
                case .macOS:
                    try await localNotificationService.send(title: message.title, body: message.body)
                case .telegram:
                    try await sendTelegram(text: message.body)
                case .discord:
                    try await sendDiscord(text: message.body)
                }
                succeeded = true
            } catch {
                succeeded = false
            }
            outcomes.append(CapacityAlertDeliveryOutcome(attempt: attempt, succeeded: succeeded, completedAt: Date()))
        }
        return outcomes
    }

    private func capacityAlertMessage(for attempt: CapacityAlertDeliveryAttempt) -> (title: String, body: String) {
        let provider = t(attempt.provider.displayName)
        let window = capacityWindowDisplayName(for: attempt.seriesID)

        if let currency = attempt.balanceCurrency, let threshold = attempt.balanceThresholdCanonical {
            return (
                title: String(format: t("capacity.notification.title"), provider),
                body: String(format: t("capacity.notification.balance.body"), provider, threshold, currency)
            )
        }

        if attempt.threshold == .reset {
            return (
                title: String(format: t("capacity.notification.reset.title"), provider),
                body: String(format: t("capacity.notification.reset.body"), provider, window)
            )
        }

        let used = attempt.usedPercent.map(String.init) ?? "--"
        return (
            title: String(format: t("capacity.notification.title"), provider),
            body: String(format: t("capacity.notification.percent.body"), provider, window, used)
        )
    }

    private func capacityWindowDisplayName(for seriesID: CapacitySeriesID) -> String {
        if let durationMinutes = seriesID.durationMinutes {
            switch durationMinutes {
            case 300: return t("5-hour window")
            case 1_440: return t("Daily requests")
            case 10_080: return t("Weekly window")
            default: break
            }
        }

        switch seriesID.providerWindowID {
        case "five-hour":
            return t("5-hour window")
        case "seven-day":
            return t("Weekly window")
        case "daily-requests":
            return t("Daily requests")
        case "rolling", "primary", "secondary":
            return t("Rolling window")
        case "balance":
            return t("Balance")
        case "context":
            return t("Context")
        default:
            return t("Limit")
        }
    }
}

// MARK: - DEBUG deterministic fixtures
#if DEBUG
enum TokenPilotDebugScenario: String, CaseIterable {
    case empty
    case claudeOfficialFresh
    case claudeOfficialStale
    case codexLocalOnly
    case codexConnectorExperimental
    case codexManual
    case deepseekOfficialBalance
    case deepseekManualBalance
    case antigravityBridge
    case runtimeRecoveryRequired
    case alertsUnsupportedCodexLegacy
    case alertsPendingDeepSeekCurrency
}

struct TokenPilotDebugFixture {
    static let privacyContract = "DEBUG fixture uses fixed dates. No network. No real provider accounts. No credentials. No local paths. No secrets."
    private static let fixedReferenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    let scenario: TokenPilotDebugScenario
    let referenceDate: Date
    let selectedScreen: TokenPilotViewModel.Screen
    let settings: AppSettings
    let snapshots: [ProviderSnapshot]
    let historySnapshots: [ProviderSnapshot]
    let limitHistorySamples: [ProviderLimitSample]
    let dataSourceMode: TokenPilotViewModel.DataSourceMode
    let dataSources: [Provider: ProviderDataSource]
    let capacityAssessments: [CapacityAssessment]
    let capacityPresentations: [CapacityPresentation]
    let capacityRefreshErrors: [CapacityRefreshError]
    let capacityRuntimeRecoveryRequired: Bool
    let capacityAlertRuntimeControl: CapacityRuntimeControl
    let capacityAlertRuntimeRecoveryStatus: CapacityPersistenceStatus
    let capacityAlertRules: [CapacityAlertRule]
    let capacityAlertRulesRecoveryStatus: CapacityPersistenceStatus
    let capacityAlertDeliveryStates: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState]
    let capacityAlertDeliveryRecoveryStatus: CapacityPersistenceStatus
    let capacityAlertMigrationRecoveryStatus: CapacityPersistenceStatus?
    let bannerMessage: String?
    let hasSavedTelegramToken: Bool
    let hasSavedDiscordWebhook: Bool
    let hasSavedDeepSeekAPIKey: Bool

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> TokenPilotDebugFixture? {
        guard environment["TOKENPILOT_UI_TESTING"] == "1" else { return nil }
        let rawScenario = environment["TOKENPILOT_DEBUG_SCENARIO"] ?? TokenPilotDebugScenario.empty.rawValue
        guard let scenario = TokenPilotDebugScenario(rawValue: rawScenario) else { return nil }
        return make(scenario)
    }

    private static func make(_ scenario: TokenPilotDebugScenario) -> TokenPilotDebugFixture {
        switch scenario {
        case .empty:
            return fixture(scenario: scenario, settings: baseSettings(), dataSourceMode: .disconnected)

        case .claudeOfficialFresh:
            let events = [
                usageEvent(1, provider: .claude, model: "claude-sonnet", minutesBeforeNow: 42, input: 1_200, output: 840, cacheRead: 220, cost: "0.82", dataSource: .officialStatusline),
                usageEvent(2, provider: .claude, model: "claude-opus", minutesBeforeNow: 18, input: 980, output: 520, cacheRead: 160, cost: "0.60", dataSource: .officialStatusline)
            ]
            let snapshots = [
                ProviderSnapshot(
                    provider: .claude,
                    updatedAt: fixedReferenceDate,
                    fiveHour: limitWindow(.fiveHour, used: 58, resetAfter: 3_420, confidence: .high, providerWindowID: "five-hour", durationMinutes: 300),
                    weekly: limitWindow(.weekly, used: 24, resetAfter: 172_800, confidence: .high, providerWindowID: "seven-day", durationMinutes: 10_080),
                    todayTokens: events.reduce(0) { $0 + $1.totalTokens },
                    todayCostUSD: decimal("1.42"),
                    confidence: .high,
                    dataSource: .officialStatusline,
                    events: events
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .claude),
                snapshots: snapshots,
                observations: [
                    percentObservation(seriesID: claudeFiveHourSeries(), used: 58, resetAfter: 3_420, authority: .providerReported, stability: .supported, comparability: .comparable),
                    percentObservation(seriesID: claudeWeeklySeries(), used: 24, resetAfter: 172_800, authority: .providerReported, stability: .supported, comparability: .comparable)
                ],
                capacityAlertRules: [
                    percentAlertRule(provider: .claude, seriesID: claudeFiveHourSeries())
                ]
            )

        case .claudeOfficialStale:
            let events = [
                usageEvent(3, provider: .claude, model: "claude-sonnet", minutesBeforeNow: 520, input: 1_480, output: 640, cacheRead: 0, cost: "0.94", dataSource: .officialStatusline)
            ]
            let staleAt = fixedReferenceDate.addingTimeInterval(-7_200)
            let snapshots = [
                ProviderSnapshot(
                    provider: .claude,
                    updatedAt: staleAt,
                    fiveHour: limitWindow(.fiveHour, used: 82, resetAfter: 1_800, confidence: .high, providerWindowID: "five-hour", durationMinutes: 300),
                    weekly: limitWindow(.weekly, used: 61, resetAfter: 86_400, confidence: .high, providerWindowID: "seven-day", durationMinutes: 10_080),
                    todayTokens: events.reduce(0) { $0 + $1.totalTokens },
                    todayCostUSD: decimal("0.94"),
                    confidence: .high,
                    dataSource: .officialStatusline,
                    isStale: true,
                    statusMessage: "Official statusline stale",
                    events: events
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .claude),
                snapshots: snapshots,
                observations: [
                    percentObservation(seriesID: claudeFiveHourSeries(), used: 82, observedOffset: -7_200, resetAfter: 1_800, authority: .providerReported, stability: .supported, comparability: .comparable, freshnessSeconds: 3_600),
                    percentObservation(seriesID: claudeWeeklySeries(), used: 61, observedOffset: -7_200, resetAfter: 86_400, authority: .providerReported, stability: .supported, comparability: .comparable, freshnessSeconds: 3_600)
                ],
                capacityAlertRules: [
                    percentAlertRule(provider: .claude, seriesID: claudeFiveHourSeries())
                ],
                dataSourceMode: .stale
            )

        case .codexLocalOnly:
            let events = [
                usageEvent(4, provider: .codex, model: "gpt-5-codex", minutesBeforeNow: 16, input: 2_800, output: 1_300, cacheRead: 420, dataSource: .localLog, isExperimental: true)
            ]
            let snapshots = [
                ProviderSnapshot(
                    provider: .codex,
                    updatedAt: fixedReferenceDate,
                    todayTokens: events.reduce(0) { $0 + $1.totalTokens },
                    confidence: .low,
                    dataSource: .localLog,
                    isExperimental: true,
                    statusMessage: "Local log activity only; not web quota",
                    events: events
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .codex),
                snapshots: snapshots
            )

        case .codexConnectorExperimental:
            let codexManual = CodexManualSettings(webConnectorEnabled: true, webTodayTokens: 4_100, webSnapshotCapturedAt: fixedReferenceDate)
            let snapshots = [
                ProviderSnapshot(
                    provider: .codex,
                    updatedAt: fixedReferenceDate,
                    fiveHour: limitWindow(.fiveHour, used: 64, resetAfter: 5_400, confidence: .medium, providerWindowID: "primary", durationMinutes: 300),
                    weekly: limitWindow(.weekly, used: 33, resetAfter: 259_200, confidence: .medium, providerWindowID: "secondary", durationMinutes: 10_080),
                    todayTokens: 4_100,
                    confidence: .medium,
                    dataSource: .webUsage,
                    isExperimental: true,
                    statusMessage: "UNOFFICIAL · Codex app-server limit hints"
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .codex, codexManual: codexManual),
                snapshots: snapshots,
                observations: [
                    percentObservation(seriesID: codexPrimarySeries(), used: 64, resetAfter: 5_400, authority: .providerReported, stability: .experimentalTransport, comparability: .comparable),
                    percentObservation(seriesID: codexSecondarySeries(), used: 33, resetAfter: 259_200, authority: .providerReported, stability: .experimentalTransport, comparability: .comparable)
                ]
            )

        case .codexManual:
            let codexManual = CodexManualSettings(
                planLabel: "Manual fixture",
                fiveHourUsagePercentage: 72,
                weeklyUsagePercentage: 18,
                resetTimeText: "fixed",
                confidence: .manual,
                webSnapshotEnabled: true,
                webTodayTokens: 2_500,
                webSnapshotCapturedAt: fixedReferenceDate
            )
            let snapshots = [
                ProviderSnapshot(
                    provider: .codex,
                    updatedAt: fixedReferenceDate,
                    fiveHour: limitWindow(.fiveHour, used: 72, resetAfter: 2_400, confidence: .manual, providerWindowID: "manual-five-hour", durationMinutes: 300),
                    weekly: limitWindow(.weekly, used: 18, resetAfter: 345_600, confidence: .manual, providerWindowID: "manual-weekly", durationMinutes: 10_080),
                    todayTokens: 2_500,
                    confidence: .manual,
                    dataSource: .manual,
                    statusMessage: "Manual estimate"
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .codex, codexManual: codexManual),
                snapshots: snapshots,
                observations: [
                    percentObservation(seriesID: codexPrimarySeries(), used: 72, resetAfter: 2_400, authority: .userEntered, stability: .manual, comparability: .incomparable),
                    percentObservation(seriesID: codexSecondarySeries(), used: 18, resetAfter: 345_600, authority: .userEntered, stability: .manual, comparability: .incomparable)
                ]
            )

        case .deepseekOfficialBalance:
            let balance = ProviderBalance(currency: "USD", totalBalance: decimal("18.00"), grantedBalance: decimal("5.66"), toppedUpBalance: decimal("12.34"), capturedAt: fixedReferenceDate)
            let snapshots = [
                ProviderSnapshot(
                    provider: .deepseek,
                    updatedAt: fixedReferenceDate,
                    confidence: .high,
                    dataSource: .officialTelemetry,
                    statusMessage: "Official balance endpoint",
                    balance: balance
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .deepseek, deepSeekAPIKeyConfigured: true),
                snapshots: snapshots,
                observations: [
                    moneyObservation(amount: "12.34", currency: "USD", authority: .providerReported, stability: .supported, comparability: .comparable)
                ],
                capacityAlertRules: [
                    balanceAlertRule(threshold: "5.00", currency: "USD")
                ],
                hasSavedDeepSeekAPIKey: true
            )

        case .deepseekManualBalance:
            let balance = ProviderBalance(currency: "USD", toppedUpBalance: decimal("8.75"), capturedAt: fixedReferenceDate)
            let balanceSettings = DeepSeekBalanceSettings(manualFallbackEnabled: true, manualBalanceText: "8.75", manualCurrency: "USD", manualCapturedAt: fixedReferenceDate, lowBalanceThreshold: decimal("5.00"))
            let snapshots = [
                ProviderSnapshot(
                    provider: .deepseek,
                    updatedAt: fixedReferenceDate,
                    confidence: .manual,
                    dataSource: .manual,
                    statusMessage: "Manual balance estimate",
                    balance: balance
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .deepseek, deepSeekBalance: balanceSettings),
                snapshots: snapshots,
                observations: [
                    moneyObservation(amount: "8.75", currency: "USD", authority: .userEntered, stability: .manual, comparability: .incomparable)
                ]
            )

        case .antigravityBridge:
            let events = [
                usageEvent(5, provider: .gemini, model: "antigravity", minutesBeforeNow: 9, input: 900, output: 600, cacheRead: 120, dataSource: .officialStatusline)
            ]
            let snapshots = [
                ProviderSnapshot(
                    provider: .gemini,
                    updatedAt: fixedReferenceDate,
                    dailyRequestsUsed: 210,
                    dailyRequestsLimit: 1_000,
                    todayTokens: events.reduce(0) { $0 + $1.totalTokens },
                    confidence: .high,
                    dataSource: .officialStatusline,
                    statusMessage: "Antigravity statusline bridge",
                    model: "antigravity",
                    contextWindowUsedPercent: 32,
                    events: events
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .gemini),
                snapshots: snapshots,
                observations: [
                    countObservation(count: 210, authority: .providerReported, stability: .compatibilityBridge, comparability: .incomparable),
                    tokensObservation(tokens: 32_000, authority: .providerReported, stability: .compatibilityBridge, comparability: .incomparable)
                ]
            )

        case .runtimeRecoveryRequired:
            return fixture(
                scenario: scenario,
                settings: baseSettings(),
                capacityRefreshErrors: [
                    CapacityRefreshError(provider: .claude, category: .sourceUnavailable, code: "debugRuntimeRecoveryRequired", redactedMessage: "Capacity runtime recovery required; safe defaults are active.")
                ],
                capacityRuntimeRecoveryRequired: true,
                capacityAlertRuntimeControl: CapacityRuntimeControl(assessmentEnabled: false),
                capacityAlertRuntimeRecoveryStatus: .recoveryRequired(writeBlocked: true, code: "runtimeRecoveryRequired"),
                dataSourceMode: .disconnected
            )

        case .alertsUnsupportedCodexLegacy:
            let snapshots = [
                ProviderSnapshot(
                    provider: .codex,
                    updatedAt: fixedReferenceDate,
                    todayTokens: 1_200,
                    confidence: .low,
                    dataSource: .localLog,
                    isExperimental: true,
                    statusMessage: "Legacy Codex local evidence is not alert-deliverable"
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .codex),
                snapshots: snapshots,
                capacityRefreshErrors: [
                    CapacityRefreshError(provider: .codex, category: .unsupportedSeries, code: "debugUnsupportedCodexLegacy", redactedMessage: "Codex legacy capacity alerts are unsupported for delivery.")
                ],
                capacityAlertRules: [
                    percentAlertRule(provider: .codex, seriesID: codexPrimarySeries())
                ]
            )

        case .alertsPendingDeepSeekCurrency:
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .deepseek),
                capacityAlertRules: [
                    pendingDeepSeekBalanceRule()
                ],
                dataSourceMode: .disconnected
            )
        }
    }

    private static func fixture(
        scenario: TokenPilotDebugScenario,
        settings: AppSettings,
        snapshots: [ProviderSnapshot] = [],
        historySnapshots: [ProviderSnapshot]? = nil,
        observations: [CapacityObservation] = [],
        limitHistorySamples explicitLimitHistorySamples: [ProviderLimitSample]? = nil,
        capacityRefreshErrors: [CapacityRefreshError] = [],
        capacityRuntimeRecoveryRequired: Bool = false,
        capacityAlertRuntimeControl: CapacityRuntimeControl = CapacityRuntimeControl(),
        capacityAlertRuntimeRecoveryStatus: CapacityPersistenceStatus = .ready(source: .absentDefault, generation: nil),
        capacityAlertRules: [CapacityAlertRule] = [],
        capacityAlertRulesRecoveryStatus: CapacityPersistenceStatus = .ready(source: .absentDefault, generation: nil),
        capacityAlertDeliveryStates: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState] = [:],
        capacityAlertDeliveryRecoveryStatus: CapacityPersistenceStatus = .ready(source: .absentDefault, generation: nil),
        capacityAlertMigrationRecoveryStatus: CapacityPersistenceStatus? = nil,
        dataSourceMode explicitDataSourceMode: TokenPilotViewModel.DataSourceMode? = nil,
        selectedScreen: TokenPilotViewModel.Screen = .overview,
        bannerMessage: String? = nil,
        hasSavedTelegramToken: Bool = false,
        hasSavedDiscordWebhook: Bool = false,
        hasSavedDeepSeekAPIKey: Bool = false
    ) -> TokenPilotDebugFixture {
        let historySnapshots = historySnapshots ?? snapshots
        let assessmentService = CapacityAssessmentService()
        let presentationMapper = CapacityPresentationMapper()
        let assessments = observations.map { assessmentService.assess($0, now: fixedReferenceDate) }
        let presentations = assessments.map { presentationMapper.map($0) }
        let dataSourceMode = explicitDataSourceMode ?? inferredDataSourceMode(from: snapshots)
        let limitHistorySamples = explicitLimitHistorySamples ?? makeLimitHistorySamples(from: snapshots)

        return TokenPilotDebugFixture(
            scenario: scenario,
            referenceDate: fixedReferenceDate,
            selectedScreen: selectedScreen,
            settings: settings,
            snapshots: snapshots,
            historySnapshots: historySnapshots,
            limitHistorySamples: limitHistorySamples,
            dataSourceMode: dataSourceMode,
            dataSources: makeDataSources(settings: settings, snapshots: snapshots, scenario: scenario),
            capacityAssessments: assessments,
            capacityPresentations: presentations,
            capacityRefreshErrors: capacityRefreshErrors,
            capacityRuntimeRecoveryRequired: capacityRuntimeRecoveryRequired,
            capacityAlertRuntimeControl: capacityAlertRuntimeControl,
            capacityAlertRuntimeRecoveryStatus: capacityAlertRuntimeRecoveryStatus,
            capacityAlertRules: capacityAlertRules,
            capacityAlertRulesRecoveryStatus: capacityAlertRulesRecoveryStatus,
            capacityAlertDeliveryStates: capacityAlertDeliveryStates,
            capacityAlertDeliveryRecoveryStatus: capacityAlertDeliveryRecoveryStatus,
            capacityAlertMigrationRecoveryStatus: capacityAlertMigrationRecoveryStatus,
            bannerMessage: bannerMessage,
            hasSavedTelegramToken: hasSavedTelegramToken,
            hasSavedDiscordWebhook: hasSavedDiscordWebhook,
            hasSavedDeepSeekAPIKey: hasSavedDeepSeekAPIKey
        )
    }

    private static func baseSettings(
        menuBarTarget: Provider? = nil,
        codexManual: CodexManualSettings = CodexManualSettings(),
        deepSeekBalance: DeepSeekBalanceSettings = DeepSeekBalanceSettings(),
        deepSeekAPIKeyConfigured: Bool = false
    ) -> AppSettings {
        AppSettings(
            deepseekAPIKeyConfigured: deepSeekAPIKeyConfigured,
            claudeStatusFilePath: "",
            geminiTelemetryLogPath: "",
            codexManual: codexManual,
            globalNotificationsEnabled: true,
            macOSNotificationsEnabled: true,
            telegramNotificationsEnabled: false,
            discordNotificationsEnabled: false,
            notificationPermissionStatus: .notRequested,
            telegram: TelegramSettings(),
            discord: DiscordSettings(),
            localization: LocalizationSettings(language: .en),
            alertRules: [],
            deepSeekBalance: deepSeekBalance,
            showMockDataWhenDisconnected: false,
            menuBarDisplayTarget: menuBarTarget
        )
    }

    private static func usageEvent(
        _ fixtureID: Int,
        provider: Provider,
        model: String?,
        minutesBeforeNow: Int,
        input: Int,
        output: Int,
        cacheRead: Int,
        cost: String? = nil,
        dataSource: UsageDataSource,
        isEstimated: Bool = false,
        isExperimental: Bool = false
    ) -> UsageEvent {
        UsageEvent(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", fixtureID))!,
            provider: provider,
            model: model,
            timestamp: fixedReferenceDate.addingTimeInterval(TimeInterval(-minutesBeforeNow * 60)),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            requestCount: 1,
            estimatedCostUSD: cost.map { decimal($0) },
            source: "debug-fixture",
            dataSource: dataSource,
            isEstimated: isEstimated,
            isExperimental: isExperimental
        )
    }

    private static func limitWindow(
        _ kind: LimitWindowKind,
        used: Int,
        resetAfter: TimeInterval?,
        confidence: DataConfidence,
        providerWindowID: String,
        durationMinutes: Int
    ) -> LimitWindow {
        LimitWindow(
            kind: kind,
            usedPercent: used,
            resetAt: resetAfter.map { fixedReferenceDate.addingTimeInterval($0) },
            confidence: confidence,
            providerWindowID: providerWindowID,
            durationMinutes: durationMinutes
        )
    }

    private static func percentObservation(
        seriesID: CapacitySeriesID,
        used: Int,
        observedOffset: TimeInterval = 0,
        resetAfter: TimeInterval?,
        authority: CapacityAuthority,
        stability: CapacityStability,
        comparability: CapacityComparability,
        freshnessSeconds: TimeInterval = 7_200
    ) -> CapacityObservation {
        try! CapacityObservation(
            seriesID: seriesID,
            observedAt: fixedReferenceDate.addingTimeInterval(observedOffset),
            resetAt: resetAfter.map { fixedReferenceDate.addingTimeInterval($0) },
            value: try! CapacityValue(usedPercent: used),
            authority: authority,
            stability: stability,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: freshnessSeconds),
            comparability: comparability,
            parserRevision: "debug-fixture-v1",
            now: fixedReferenceDate
        )
    }

    private static func moneyObservation(
        amount: String,
        currency: String,
        authority: CapacityAuthority,
        stability: CapacityStability,
        comparability: CapacityComparability
    ) -> CapacityObservation {
        try! CapacityObservation(
            seriesID: deepSeekBalanceSeries(),
            observedAt: fixedReferenceDate,
            value: try! CapacityValue(money: decimal(amount), currency: currency),
            authority: authority,
            stability: stability,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 7_200),
            comparability: comparability,
            parserRevision: "debug-fixture-v1",
            now: fixedReferenceDate
        )
    }

    private static func countObservation(
        count: Int,
        authority: CapacityAuthority,
        stability: CapacityStability,
        comparability: CapacityComparability
    ) -> CapacityObservation {
        try! CapacityObservation(
            seriesID: geminiDailyRequestSeries(),
            observedAt: fixedReferenceDate,
            resetAt: fixedReferenceDate.addingTimeInterval(43_200),
            value: try! CapacityValue(count: count),
            authority: authority,
            stability: stability,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 7_200),
            comparability: comparability,
            parserRevision: "debug-fixture-v1",
            now: fixedReferenceDate
        )
    }

    private static func tokensObservation(
        tokens: Int,
        authority: CapacityAuthority,
        stability: CapacityStability,
        comparability: CapacityComparability
    ) -> CapacityObservation {
        try! CapacityObservation(
            seriesID: geminiContextSeries(),
            observedAt: fixedReferenceDate,
            value: try! CapacityValue(tokens: tokens),
            authority: authority,
            stability: stability,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 7_200),
            comparability: comparability,
            parserRevision: "debug-fixture-v1",
            now: fixedReferenceDate
        )
    }

    private static func makeLimitHistorySamples(from snapshots: [ProviderSnapshot]) -> [ProviderLimitSample] {
        snapshots.flatMap { snapshot -> [ProviderLimitSample] in
            var samples: [ProviderLimitSample] = []
            if let fiveHour = snapshot.fiveHour, let used = fiveHour.usedPercent, let remaining = fiveHour.remainingPercent {
                samples.append(ProviderLimitSample(provider: snapshot.provider, timestamp: fixedReferenceDate.addingTimeInterval(-900), window: .fiveHour, usedPercent: used, remainingPercent: remaining, confidence: fiveHour.confidence, source: "debug-fixture", totalTokens: snapshot.todayTokens))
            }
            if let weekly = snapshot.weekly, let used = weekly.usedPercent, let remaining = weekly.remainingPercent {
                samples.append(ProviderLimitSample(provider: snapshot.provider, timestamp: fixedReferenceDate.addingTimeInterval(-1_800), window: .weekly, usedPercent: used, remainingPercent: remaining, confidence: weekly.confidence, source: "debug-fixture", totalTokens: snapshot.todayTokens))
            }
            if let dailyPercent = snapshot.dailyRequestsPercent {
                samples.append(ProviderLimitSample(provider: snapshot.provider, timestamp: fixedReferenceDate.addingTimeInterval(-1_200), window: .dailyRequests, usedPercent: dailyPercent, remainingPercent: 100 - dailyPercent, confidence: snapshot.confidence, source: "debug-fixture", totalTokens: snapshot.todayTokens))
            }
            return samples
        }
    }

    private static func makeDataSources(settings: AppSettings, snapshots: [ProviderSnapshot], scenario: TokenPilotDebugScenario) -> [Provider: ProviderDataSource] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            let snapshot = snapshots.first { $0.provider == provider }
            let status: ProviderDataSourceStatus
            let confidence: DataConfidence
            let mode: ProviderMode

            if let snapshot {
                confidence = snapshot.confidence
                mode = snapshot.dataSource == .manual ? .custom : .auto
                if snapshot.isStale {
                    status = .stale
                } else if snapshot.dataSource == .manual || snapshot.confidence == .manual {
                    status = .manual
                } else {
                    status = .connected
                }
            } else if !settings.isProviderEnabled(provider) {
                status = .disabled
                confidence = .low
                mode = .disabled
            } else if provider == .deepseek && settings.deepseekAPIKeyConfigured {
                status = .connected
                confidence = .medium
                mode = .auto
            } else if provider == .deepseek {
                status = .manual
                confidence = .manual
                mode = .custom
            } else {
                status = .notFound
                confidence = .low
                mode = .auto
            }

            return (
                provider,
                ProviderDataSource(
                    provider: provider,
                    isEnabled: settings.isProviderEnabled(provider),
                    mode: mode,
                    detectedPaths: [],
                    customPath: nil,
                    lastScanAt: fixedReferenceDate,
                    status: status,
                    confidence: confidence,
                    statusMessage: "DEBUG fixture \(scenario.rawValue)"
                )
            )
        })
    }

    private static func inferredDataSourceMode(from snapshots: [ProviderSnapshot]) -> TokenPilotViewModel.DataSourceMode {
        guard !snapshots.isEmpty else { return .disconnected }
        return snapshots.contains { $0.isStale } ? .stale : .live
    }

    private static func percentAlertRule(provider: Provider, seriesID: CapacitySeriesID) -> CapacityAlertRule {
        try! CapacityAlertRule(
            provider: provider,
            seriesID: seriesID,
            authority: .providerReported,
            stability: .supported,
            enabled: true,
            routing: CapacityAlertRouting(macOS: true),
            condition: .percentThresholds(reset: true, fifty: false, eighty: true, hundred: true)
        )
    }

    private static func balanceAlertRule(threshold: String, currency: String) -> CapacityAlertRule {
        try! CapacityAlertRule(
            provider: .deepseek,
            seriesID: deepSeekBalanceSeries(),
            authority: .providerReported,
            stability: .supported,
            enabled: true,
            routing: CapacityAlertRouting(macOS: true),
            condition: try! CapacityAlertCondition.balanceBelow(threshold: decimal(threshold), currency: currency, rearmAtOrAboveThreshold: true)
        )
    }

    private static func pendingDeepSeekBalanceRule() -> CapacityAlertRule {
        try! CapacityAlertRule(
            provider: .deepseek,
            seriesID: deepSeekBalanceSeries(),
            authority: .providerReported,
            stability: .supported,
            enabled: false,
            routing: CapacityAlertRouting(macOS: true),
            condition: .pendingBalanceCurrencyBinding
        )
    }

    private static func claudeFiveHourSeries() -> CapacitySeriesID {
        try! CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, durationMinutes: 300)
    }

    private static func claudeWeeklySeries() -> CapacitySeriesID {
        try! CapacitySeriesID(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, unit: .percent, durationMinutes: 10_080)
    }

    private static func codexPrimarySeries() -> CapacitySeriesID {
        try! CapacitySeriesID(provider: .codex, providerWindowID: "primary", kind: .rolling, unit: .percent, durationMinutes: 300)
    }

    private static func codexSecondarySeries() -> CapacitySeriesID {
        try! CapacitySeriesID(provider: .codex, providerWindowID: "secondary", kind: .rolling, unit: .percent, durationMinutes: 10_080)
    }

    private static func deepSeekBalanceSeries() -> CapacitySeriesID {
        try! CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency)
    }

    private static func geminiDailyRequestSeries() -> CapacitySeriesID {
        try! CapacitySeriesID(provider: .gemini, providerWindowID: "daily-requests", kind: .calendarCap, unit: .requestCount, durationMinutes: 1_440)
    }

    private static func geminiContextSeries() -> CapacitySeriesID {
        try! CapacitySeriesID(provider: .gemini, providerWindowID: "context", kind: .context, unit: .tokens)
    }

    private static func decimal(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!
    }
}
#endif
