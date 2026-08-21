import SwiftUI
import AppKit
import Combine
import TokenCore

@MainActor
final class TokenPilotViewModel: ObservableObject {
    enum DataSourceMode: String, CaseIterable {
        case live = "LIVE"
        case stale = "STALE"
        case local = "LOCAL"
        case manual = "MANUAL"
        case experimental = "EXPERIMENTAL"
        case compatibilityBridge = "BRIDGE"
        case mock = "MOCK"
        case disconnected = "--"

        var displayLabel: String { rawValue }
    }

    enum RefreshReason {
        case manual
        case automaticTimer
        case settings
        /// The Mac woke from sleep, where timers were suspended and stored values went stale.
        case systemWake
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
    @Published var providerStatusReports: [Provider: ProviderStatusReport] = [:]
    @Published var exportFormat: UsageExportFormat = .json
    @Published var capacityAssessments: [CapacityAssessment] = []
    @Published var capacityPresentations: [CapacityPresentation] = []
    @Published var capacityEvidenceRecords: [CapacityEvidenceRecord] = []
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
    @Published var minimaxAPIKeyInput = ""
    @Published var zaiAPIKeyInput = ""
    @Published var openrouterAPIKeyInput = ""
    @Published var hasSavedTelegramToken = false
    @Published var hasSavedDiscordWebhook = false
    @Published var hasSavedDeepSeekAPIKey = false
    @Published var hasSavedMinimaxAPIKey = false
    @Published var hasSavedZAIAPIKey = false
    @Published var hasSavedOpenRouterAPIKey = false
    /// Transient presentation-only experimental OAuth weekly result. Never persisted or sunk.
    @Published private(set) var xaiOAuthResult: XAIRefreshResult?
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
    private let usageStore = UsageStore(
        makeExperimentalWeeklyService: { GrokOAuthWeeklyUsageAdapter() }
    )
    private let usageHistoryStore = UsageHistoryStore()
    private let limitHistoryStore = LimitHistoryStore()
    private let aggregationService = AggregationService()
    private let menuBarStatusService = MenuBarStatusService()
    private let connectionService = DataSourceConnectionService()
    private let providerStatusService = ProviderStatusService()
    private let exportService = UsageExportService()
    private let localNotificationService = LocalNotificationService()
    private let weeklyDigestStore = WeeklyDigestStore()
    private let dailyDigestStore = DailyDigestStore()
    private let budgetAlertService = BudgetAlertService()
    private let milestoneNotificationService = MilestoneNotificationService()
    private let telegramService = TelegramNotificationService()
    private let discordService = DiscordNotificationService()
    private let keychain = KeychainService()
    private let capacityEvidenceStore = CapacityEvidenceStore()
    private let statuslineSnapshotStore = StatuslineSnapshotStore()
    private let capacityRuntimeStore = CapacityRuntimeStore()
    private let capacityAlertRuleStore = CapacityAlertRuleStore()
    private let capacityAlertDeliveryStore = CapacityAlertDeliveryStore()
    private let capacityAlertMigrationCoordinator = CapacityAlertLegacyMigrationCoordinator()
    private let capacityAssessmentService = CapacityAssessmentService()
    private let capacityPresentationMapper = CapacityPresentationMapper()
    private let capacityAlertTransitionEngine = CapacityAlertTransitionEngine()
    private let capacityAlertVisibilityBuilder = CapacityAlertVisibilityBuilder()
    private let menuBarTickInterval: TimeInterval = 30
    private var dataRefreshInterval: TimeInterval {
        TimeInterval(max(settings.refreshIntervalSeconds, 5))
    }
    private let settingsSaveDebounceNanoseconds: UInt64 = 350_000_000
    private let settingsRefreshDebounceNanoseconds: UInt64 = 450_000_000
    private var timer: Timer?
    private var refreshInProgress = false
    private var refreshQueued = false
    private var lastRefreshFinishedAt: Date?
    private var settingsSaveTask: Task<Void, Never>?
    private var settingsRefreshTask: Task<Void, Never>?
    private var experimentalShutdownTask: Task<Void, Never>?
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
        syncLaunchAtLoginFromSystem()
        Task {
            await updatePermissionStatus()
            await refresh(reason: .automaticTimer)
            refreshStoredCredentialPresence()
            await refreshConnectionDiagnostics()
        }
    }

    /// Populates provider diagnostics (statuses only — no path adoption, no banner) once at
    /// startup so Settings reflects connected/stale states without a manual Check Connection.
    private func refreshConnectionDiagnostics() async {
        let sources = await connectionService.checkAll(settings: settings)
        applyDataSources(sources)
    }

    /// The login item is the system truth; fold its state into settings once at startup.
    private func syncLaunchAtLoginFromSystem() {
        let registered = LaunchAtLoginService.isEnabled
        guard settings.launchAtLogin != registered else { return }
        var next = settings
        next.launchAtLogin = registered
        settings = next
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
        bannerMessage = nil
        return true
    }
#endif

    /// Whether each stored secret exists — never the secret itself.
    ///
    /// Settings calls this on every appear. It used to run six `SecItemCopyMatching` queries on the
    /// main actor and then publish six times whether or not anything had changed, and every publish
    /// rebuilds the popover — on the screen that is already the most expensive to lay out. The
    /// queries now run off the main actor together, and an unchanged answer publishes nothing.
    func refreshStoredCredentialPresence() {
#if DEBUG
        guard !debugFixtureMode else { return }
#endif
        let keychain = self.keychain
        let accounts = [
            Self.telegramTokenAccount,
            Self.discordWebhookAccount,
            Self.deepSeekAPIKeyAccount,
            Self.minimaxAPIKeyAccount,
            Self.zaiAPIKeyAccount,
            Self.openRouterAPIKeyAccount
        ]

        Task {
            let present = await Task.detached(priority: .utility) {
                accounts.map { ((try? keychain.readSecret(account: $0)) ?? nil) != nil }
            }.value

            publishIfChanged(present[0], to: \.hasSavedTelegramToken)
            publishIfChanged(present[1], to: \.hasSavedDiscordWebhook)
            publishIfChanged(present[2], to: \.hasSavedDeepSeekAPIKey)
            publishIfChanged(present[3], to: \.hasSavedMinimaxAPIKey)
            publishIfChanged(present[4], to: \.hasSavedZAIAPIKey)
            publishIfChanged(present[5], to: \.hasSavedOpenRouterAPIKey)

            if settings.deepseekAPIKeyConfigured != present[2] {
                settings.deepseekAPIKeyConfigured = present[2]
            }
        }
    }

    /// `@Published` fires on every write, not on every change. Assigning the same value again costs
    /// a full popover rebuild for nothing.
    private func publishIfChanged<Value: Equatable>(
        _ value: Value,
        to keyPath: ReferenceWritableKeyPath<TokenPilotViewModel, Value>
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    static let telegramTokenAccount = "telegram.botToken"
    static let discordWebhookAccount = "discord.webhookURL"
    static let deepSeekAPIKeyAccount = "deepseek.apiKey"
    static let minimaxAPIKeyAccount = "minimax.apiKey"
    static let zaiAPIKeyAccount = "zai.apiKey"
    static let openRouterAPIKeyAccount = "openrouter.apiKey"

    static func apiKeyAccount(for provider: Provider) -> String {
        switch provider {
        case .minimax: return minimaxAPIKeyAccount
        case .zai: return zaiAPIKeyAccount
        case .openrouter: return openRouterAPIKeyAccount
        default: return deepSeekAPIKeyAccount
        }
    }
    private var menuBarOAuthResult: XAIRefreshResult? {
        guard let result = xaiOAuthResult,
              result.selectedOutcome == .oauthWeekly,
              result.completion == .completed,
              result.oauthFailure == nil else {
            return nil
        }
        return result
    }


    var menuBarTitle: String {
        menuBarStatusService.title(
            snapshots: snapshots,
            settings: settings,
            modeLabel: dataSourceMode.displayLabel,
            now: menuBarNow,
            xaiOAuthResult: menuBarOAuthResult
        )
    }
    /// The text layouts split per provider, for `Separate items` grouping.
    var menuBarTitleSegments: [MenuBarTitleSegment] {
        menuBarStatusService.titleSegments(
            snapshots: snapshots,
            settings: settings,
            modeLabel: dataSourceMode.displayLabel,
            now: menuBarNow,
            xaiOAuthResult: menuBarOAuthResult
        )
    }

    /// What Settings shows under "Current menu bar". With separate items the bar draws each
    /// segment as its own status item, so the preview spaces them out instead of joining them
    /// with the separator only the combined item uses.
    var menuBarPreviewText: String {
        guard settings.menuBarProviderGrouping == .separate,
              settings.menuBarDisplayStyle == .detailed || settings.menuBarDisplayStyle == .compact
        else { return menuBarTitle }
        let segments = menuBarTitleSegments
        guard segments.count > 1 else { return menuBarTitle }
        return segments.map(\.text).joined(separator: "   ")
    }

    var menuBarMetricSegments: [MenuBarProviderMetricSegment] {
        menuBarStatusService.providerMetricsSegments(
            snapshots: snapshots,
            settings: settings,
            now: menuBarNow,
            xaiOAuthResult: menuBarOAuthResult,
            limitSamples: limitHistorySamples
        )
    }

    var menuBarStatusLevel: MenuBarStatusLevel {
        menuBarStatusService.statusLevel(
            snapshots: snapshots,
            settings: settings,
            xaiOAuthResult: menuBarOAuthResult
        )
    }

    var menuBarStatusColor: Color {
        switch menuBarStatusLevel {
        case .normal: return TokenPilotDesign.textSecondary
        case .warning: return TokenPilotDesign.warning
        case .critical: return TokenPilotDesign.danger
        }
    }

    func copyUsageSummaryToPasteboard() {
        let events = historySnapshots.flatMap(\.events)
        let text = TokenPilotCLIService.summaryText(
            events: events,
            snapshots: snapshots,
            enabledProviders: settings.enabledProviders,
            language: settings.localization.language,
            period: .today,
            now: menuBarNow
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var menuBarAccessibilityLabel: String {
        menuBarStatusService.accessibilityLabel(
            snapshots: snapshots,
            settings: settings,
            modeLabel: dataSourceMode.displayLabel,
            now: menuBarNow,
            xaiOAuthResult: menuBarOAuthResult
        )
    }

    var menuBarSnapshot: ProviderSnapshot? {
        menuBarStatusService.selectedSnapshot(
            from: snapshots,
            settings: settings,
            xaiOAuthResult: menuBarOAuthResult
        )
    }

    var menuBarDisplayWindow: LimitWindow? {
        menuBarSnapshot.flatMap { menuBarStatusService.displayWindow(for: $0) }
    }

    var menuBarSystemImage: String {
        guard let snapshot = menuBarStatusService.selectedSnapshot(
            from: snapshots,
            settings: settings,
            xaiOAuthResult: menuBarOAuthResult
        ) else {
            return "chart.bar.xaxis"
        }
        return snapshot.provider.iconName
    }

    var lowestRemainingSummary: MenuBarLowestRemainingSummary? {
        menuBarStatusService.lowestRemainingSummary(
            snapshots: snapshots,
            settings: settings,
            xaiOAuthResult: menuBarOAuthResult
        )
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
        nearestReset.map { TokenPilotFormatters.remainingTime(until: $0, language: settings.localization.language) } ?? localized("—", language: settings.localization.language)
    }


    private var enabledSnapshots: [ProviderSnapshot] {
        menuBarStatusService.presentationSnapshots(from: snapshots, settings: settings)
    }

    var filteredSnapshots: [ProviderSnapshot] {
        historySnapshots.isEmpty ? enabledSnapshots : historySnapshots
    }

    /// GitHub-style contribution grid derived from stored usage events.
    /// The trailing window is selectable (4 / 8 / 12 weeks) and defaults to 12 weeks.
    @Published var heatmapWeeks: Int = 12

    var historyHeatmapCells: [UsageHeatCell] {
        aggregationService.heatmapCells(from: historyUsage.events, days: max(heatmapWeeks, 1) * 7)
    }


    var budgetGuardrails: BudgetGuardrailSnapshot {
        let service = BudgetGuardrailService()
        let events = overviewUsage.events
        return BudgetGuardrailSnapshot(
            daily: service.dailyProgress(events: events, settings: settings.budget),
            weekly: service.weeklyProgress(events: events, settings: settings.budget, weekStartDay: settings.weekStartDay),
            monthly: service.monthlyProgress(events: events, settings: settings.budget)
        )
    }

    var budgetPaceProjection: BudgetPaceProjection? {
        BudgetPaceService().projection(progress: budgetGuardrails.daily)
    }

    var activityMilestones: [ActivityMilestone] {
        ActivityMilestoneService().achievedMilestones(events: overviewUsage.events)
    }

    var usageStreak: UsageStreak {
        UsageStreakService.streak(events: overviewUsage.events)
    }

    var cacheEfficiency: CacheEfficiencySummary {
        CacheEfficiencyService.summary(events: overviewUsage.events)
    }

    var cacheTrend: CacheTrend {
        CacheTrendService.trend(events: historyUsage.events)
    }

    var providerCacheEfficiency: ProviderCacheEfficiencySummary {
        ProviderCacheEfficiencyService().summary(events: historyUsage.events)
    }

    var requestHistoryTrend: RequestHistoryTrend {
        RequestHistoryService().trend(events: historyUsage.events)
    }

    var throughputReading: ThroughputReading {
        ThroughputService().reading(events: overviewUsage.events)
    }

    var budgetHistoryTrend: BudgetHistoryTrend {
        BudgetHistoryService().trend(
            events: historyUsage.events,
            dailyBudgetTokens: settings.budget.dailyTokens
        )
    }

    var contextHealthAssessments: [ContextHealthAssessment] {
        ContextHealthService().assess(records: capacityEvidenceRecords)
    }

    var fiveHourBlocks: [FiveHourUsageBlock] {
        FiveHourBlocksService.blocks(events: historyUsage.events)
    }

    var hourlyActivity: HourlyActivitySummary {
        let buckets = HourlyActivityService.hourlyBuckets(events: historyUsage.events)
        return HourlyActivitySummary(buckets: buckets)
    }

    var monthlyTrend: [MonthlyUsageBar] {
        MonthlyTrendService.monthlyBars(events: historyUsage.events)
    }

    var costEfficiency: CostEfficiencySummary {
        CostEfficiencyService.summary(events: historyUsage.events)
    }

    var overviewSnapshots: [ProviderSnapshot] {
        enabledSnapshots
            .filter { !Self.isNeutralXAISetupSnapshot($0) }
            .map { snapshot in
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

    /// The percentages Settings offers as one-tap choices. Any value in 1...100 is valid; these are
    /// the ones worth a chip, and they cover what the benchmarked trackers default to (75/90/95).
    static let offeredAlertThresholds = [50, 75, 80, 90, 95, 100]

    /// Chips to show for a rule: the offered set, plus any percentage the rule already carries, so
    /// a threshold set elsewhere is never silently dropped by editing something next to it.
    func alertThresholdChoices(for row: CapacityAlertVisibilityRow) -> [Int] {
        Set(Self.offeredAlertThresholds + row.percentThresholds.compactMap(\.percent)).sorted()
    }

    /// Replaces a rule's thresholds.
    ///
    /// `replacingCondition` bumps the condition revision, which is part of the delivery key, so the
    /// edited rule starts with no delivery history. That is what should happen: the transition
    /// engine records a first sighting without firing, so a newly added threshold arrives at the
    /// next crossing rather than immediately for a window the user is already inside.
    func setCapacityAlertThresholds(ruleID: String, reset: Bool, percents: Set<Int>) async {
        let load = await capacityAlertRuleStore.load()
        guard !load.recoveryStatus.recoveryRequired else {
            bannerMessage = t("Alert settings are recovering; try again in a moment.")
            return
        }
        guard let existing = load.rules.first(where: { $0.id == ruleID }) else { return }

        // Every alert off would leave a rule that watches nothing while still looking configured.
        guard reset || !percents.isEmpty else {
            bannerMessage = t("Keep at least one alert threshold.")
            return
        }

        guard let updated = try? existing.replacingCondition(
            .percentThresholds(reset: reset, percents: percents)
        ) else {
            bannerMessage = t("That alert threshold is not supported for this window.")
            return
        }

        let next = load.rules.filter { $0.id != ruleID } + [updated]
        let save = await capacityAlertRuleStore.save(next.sorted { $0.id < $1.id })
        guard !save.recoveryStatus.writeBlocked else {
            bannerMessage = t("Could not save alert settings.")
            return
        }
        capacityAlertRules = next.sorted { $0.id < $1.id }
    }

    func toggleCapacityAlertThreshold(row: CapacityAlertVisibilityRow, percent: Int) async {
        var percents = Set(row.percentThresholds.compactMap(\.percent))
        if percents.contains(percent) {
            percents.remove(percent)
        } else {
            percents.insert(percent)
        }
        await setCapacityAlertThresholds(
            ruleID: row.id,
            reset: row.percentThresholds.contains(where: \.isReset),
            percents: percents
        )
    }

    func toggleCapacityAlertReset(row: CapacityAlertVisibilityRow) async {
        await setCapacityAlertThresholds(
            ruleID: row.id,
            reset: !row.percentThresholds.contains(where: \.isReset),
            percents: Set(row.percentThresholds.compactMap(\.percent))
        )
    }

    var alertStatusText: String {
        let summary = capacityAlertSummary
        var parts = [capacityAlertChannelPreferenceSummary()]

        if summary.recoveryRequired {
            parts.append(t("Recovery needed"))
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
            // Saved only: automatic delivery reads the Keychain, so an unsaved field must not
            // make a channel look available that would then fail every send.
            telegramCredentialPresent: hasSavedTelegramToken,
            discordCredentialPresent: hasSavedDiscordWebhook
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
            return t("Capacity alerts use safe defaults until local runtime state is readable again.")
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
                guard let percent = threshold.percent else { return t("Reset") }
                return "\(percent)%"
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

    var appVersionText: String {
        TokenPilotVersion.current()
    }

    /// Localized relative freshness label (e.g. "Updated 3 min ago"), or nil when the
    /// app has never completed a refresh yet.
    var lastUpdatedText: String? {
        guard let format = TokenPilotRelativeTimestamp.format(from: lastRefreshFinishedAt, now: menuBarNow) else {
            return nil
        }
        if let arg = format.arg {
            return String(format: t(format.key), arg)
        }
        return t(format.key)
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
        if provider == .xai, !isEnabled, isExperimentalOAuthWeeklyConsentEnabled {
            Task { await setExperimentalOAuthWeeklyConsent(false) }
        }
        var next = settings
        if next.setProviderEnabled(provider, isEnabled: isEnabled) {
            if isEnabled {
                // Switching a provider on is the user asking to watch it, so it belongs in the
                // menu bar too. Without this the provider stayed invisible there until the user
                // found the separate menu bar provider list and switched it on a second time.
                next.menuBarMetricProviders.insert(provider)
            }
            next.normalizeMenuBarComposition()
            settings = next
        } else {
            bannerMessage = t("At least one provider must stay enabled.")
        }
    }

    var isExperimentalOAuthWeeklyConsentEnabled: Bool {
        settings.xAI.experimentalOAuthWeeklyConsentVersion
            == XAISettings.experimentalOAuthWeeklyConsentVersionCurrent
    }

    func setExperimentalOAuthWeeklyConsent(_ enabled: Bool) async {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        if enabled {
            guard !isExperimentalOAuthWeeklyConsentEnabled else { return }
            var next = settings
            next.xAI.experimentalOAuthWeeklyConsentVersion =
                XAISettings.experimentalOAuthWeeklyConsentVersionCurrent
            settings = next
            await refresh(reason: .settings)
            return
        }

        await usageStore.revokeXAIExperimentalWeekly()
        xaiOAuthResult = nil
        guard isExperimentalOAuthWeeklyConsentEnabled else { return }
        var next = settings
        next.xAI.experimentalOAuthWeeklyConsentVersion = nil
        settings = next
    }

    var experimentalOAuthWeeklyStatusText: String {
        guard isExperimentalOAuthWeeklyConsentEnabled else {
            return t("xai.oauth.status.consent_off")
        }
        if let result = xaiOAuthResult {
            return t(result.statusKey)
        }
        return t("xai.oauth.status.unavailable")
    }

    var experimentalOAuthWeeklyActionText: String {
        guard isExperimentalOAuthWeeklyConsentEnabled else {
            return t("xai.oauth.action.enable_consent")
        }
        if let result = xaiOAuthResult {
            return t(result.actionKey)
        }
        return t("xai.oauth.action.refresh")
    }

    func shutdownExperimentalOAuthWeekly() {
        experimentalShutdownTask?.cancel()
        experimentalShutdownTask = Task { [usageStore] in
            await usageStore.shutdownXAIExperimentalWeekly()
        }
        // Keep the termination path lifecycle-safe: cancel/start the shutdown task and
        // give it a short bounded window before process exit continues.
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline, experimentalShutdownTask?.isCancelled == false {
            if experimentalShutdownTask == nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if experimentalShutdownTask?.isCancelled == true { break }
        }
        xaiOAuthResult = nil
    }

    func setMenuBarDisplayTarget(_ provider: Provider?) {
        var next = settings
        if let provider, !next.isProviderEnabled(provider) { return }
        next.menuBarDisplayTarget = provider
        next.normalizeMenuBarComposition()
        settings = next
    }
    func setMenuBarDisplayStyle(_ style: MenuBarDisplayStyle) {
        settings.menuBarDisplayStyle = style
    }

    func setMenuBarPrimaryMetric(_ metric: MenuBarPrimaryMetric) {
        settings.menuBarPrimaryMetric = metric
    }

    func setLaunchAtLogin(_ enabled: Bool) {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        guard settings.launchAtLogin != enabled else { return }
        do {
            try LaunchAtLoginService.apply(enabled)
            var next = settings
            next.launchAtLogin = enabled
            settings = next
            bannerMessage = nil
        } catch {
            bannerMessage = enabled ? t("Could not enable launch at login") : t("Could not disable launch at login")
        }
    }
    func setMenuBarProviderGrouping(_ grouping: MenuBarProviderGrouping) {
        settings.menuBarProviderGrouping = grouping
    }

    func setMenuBarTrendStyle(_ style: MenuBarTrendStyle) {
        settings.menuBarTrendStyle = style
    }

    func setMenuBarWidthLimit(_ limit: MenuBarWidthLimit) {
        settings.menuBarWidthLimit = limit
    }

    func setMenuBarMetricProvider(_ provider: Provider, isVisible: Bool) {
        var next = settings
        guard !isVisible || next.isProviderEnabled(provider) else { return }

        if isVisible {
            next.menuBarMetricProviders.insert(provider)
        } else {
            let remainingVisibleProviders = next.menuBarMetricProviders
                .subtracting([provider])
                .filter { next.isProviderEnabled($0) }
            guard !remainingVisibleProviders.isEmpty else {
                bannerMessage = t("At least one provider must stay visible in the menu bar.")
                return
            }
            next.menuBarMetricProviders.remove(provider)
        }
        settings = next
    }

    func setMenuBarShowsSecondaryProvider(_ showsSecondary: Bool) {
        var next = settings
        guard showsSecondary else {
            next.menuBarShowsSecondaryProvider = false
            next.normalizeMenuBarComposition()
            settings = next
            return
        }

        guard let secondary = firstAvailableSecondaryProvider(in: next) else {
            next.menuBarShowsSecondaryProvider = false
            next.menuBarSecondaryDisplayTarget = nil
            settings = next
            return
        }

        next.menuBarShowsSecondaryProvider = true
        if next.menuBarSecondaryDisplayTarget == nil ||
            next.menuBarSecondaryDisplayTarget == next.menuBarDisplayTarget ||
            !next.isProviderEnabled(next.menuBarSecondaryDisplayTarget!) {
            next.menuBarSecondaryDisplayTarget = secondary
        }
        next.normalizeMenuBarComposition()
        settings = next
    }

    func setMenuBarSecondaryDisplayTarget(_ provider: Provider?) {
        var next = settings
        guard let provider else {
            next.menuBarSecondaryDisplayTarget = nil
            next.normalizeMenuBarComposition()
            settings = next
            return
        }
        guard provider != next.menuBarDisplayTarget, next.isProviderEnabled(provider) else { return }
        next.menuBarSecondaryDisplayTarget = provider
        next.normalizeMenuBarComposition()
        settings = next
    }

    private func firstAvailableSecondaryProvider(in settings: AppSettings) -> Provider? {
        Provider.allCases.first {
            settings.isProviderEnabled($0) && $0 != settings.menuBarDisplayTarget
        }
    }

    func providerDisplayName(_ provider: Provider) -> String {
        provider == .xai ? t("Grok Build") : t(provider.displayName)
    }

    func menuBarDisplayTargetLabel(for provider: Provider?) -> String {
        guard let provider else { return t("Highest risk") }
        return providerDisplayName(provider)
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

    /// Publishes the capacity windows the `statusline` CLI reads on every editor prompt.
    ///
    /// Off the main actor and best effort: the status line is a convenience, and
    /// a failed write only means the CLI falls back to the full evidence store.
    private func writeStatuslineSnapshot(assessments: [CapacityAssessment], observedAt: Date) {
        let windows = StatuslineService.windows(from: assessments)
        guard !windows.isEmpty else { return }
        let snapshot = StatuslineSnapshot(generatedAt: observedAt, windows: windows)
        let store = statuslineSnapshotStore
        Task.detached(priority: .utility) {
            store.save(snapshot)
        }
    }

    /// Refreshes right after the Mac wakes, unless a refresh just finished.
    ///
    /// Timers do not fire during sleep, so without this the menu bar keeps a
    /// pre-sleep percentage and a stale reset countdown until the next tick.
    func refreshAfterSystemWake(now: Date = Date()) async {
#if DEBUG
        guard !debugFixtureMode else { return }
#endif
        menuBarNow = now
        guard WakeRefreshGate.shouldRefresh(lastRefreshFinishedAt: lastRefreshFinishedAt, now: now) else { return }
        await refresh(reason: .systemWake)
    }

    private func handleAutoRefreshTick() async {
        menuBarNow = Date()
        await checkWeeklyDigest(now: menuBarNow)
        await checkDailyDigest(now: menuBarNow)
        guard shouldRunDataRefresh(at: menuBarNow) else { return }
        await refresh(reason: .automaticTimer)
    }

    /// A once-per-day attempt tracker used to sit in front of the fire window, and it burned the
    /// day's only attempt on the first tick after midnight — outside every schedule anyone would
    /// pick, so the digest never sent. `DailyDigestGate` already dedupes on `lastSentAt`, which is
    /// the check that belongs here.
    private func checkDailyDigest(now: Date) async {
        guard settings.dailyDigestEnabled,
              settings.globalNotificationsEnabled,
              settings.macOSNotificationsEnabled else {
            return
        }
        let lastSent = dailyDigestStore.loadLastSent()
        let schedule = DailyDigestSchedule(hour: settings.dailyDigestHour, minute: settings.dailyDigestMinute)
        guard DailyDigestGate.isInFireWindow(now: now, lastSentAt: lastSent, schedule: schedule) else { return }
        let events = usageHistoryStore.loadEvents()
        let text = DailyDigestService.digestText(
            events: events,
            enabledProviders: settings.enabledProviders,
            language: settings.localization.language,
            now: now,
            budget: settings.budget
        )
        do {
            try await localNotificationService.send(title: t("Daily digest"), body: text)
            dailyDigestStore.saveLastSent(now)
        } catch {}
    }

    /// Same defect as the daily digest, worse: the tracker was per-day while the schedule is
    /// per-week, so the one attempt on digest day happened just after midnight and the weekly
    /// digest never sent at all.
    private func checkWeeklyDigest(now: Date) async {
        guard settings.weeklyDigestEnabled,
              settings.globalNotificationsEnabled,
              settings.macOSNotificationsEnabled else {
            return
        }
        let lastSent = weeklyDigestStore.loadLastSent()
        let schedule = WeeklyDigestSchedule(hour: settings.weeklyDigestHour, minute: settings.weeklyDigestMinute)
        guard WeeklyDigestGate.isInFireWindow(now: now, lastSentAt: lastSent, schedule: schedule, weekStartDay: settings.weekStartDay) else { return }
        let events = usageHistoryStore.loadEvents()
        let text = WeeklyDigestService.digestText(
            events: events,
            enabledProviders: settings.enabledProviders,
            language: settings.localization.language,
            now: now,
            weekStartDay: settings.weekStartDay,
            budget: settings.budget
        )
        do {
            try await localNotificationService.send(title: t("Weekly digest"), body: text)
            weeklyDigestStore.saveLastSent(now)
        } catch {}
    }

    private func checkBudgetAlerts() async {
        guard settings.globalNotificationsEnabled,
              settings.macOSNotificationsEnabled,
              settings.budget.hasAnyBudget else {
            return
        }
        let candidates = budgetAlertService.crossingCandidates(
            events: overviewUsage.events,
            settings: settings.budget,
            now: Date()
        )
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            let windowLabel: String
            switch candidate.window {
            case .daily: windowLabel = t("Today")
            case .weekly: windowLabel = t("This week")
            case .monthly: windowLabel = t("This month")
            }
            let body = String(
                format: t("Budget %@: %@ / %@ tok reached %d%% (est.)"),
                windowLabel,
                TokenPilotFormatters.compactNumber(candidate.tokens),
                TokenPilotFormatters.compactNumber(candidate.budgetTokens),
                candidate.percent
            )
            do {
                try await localNotificationService.send(title: t("Budget guardrails"), body: body)
            } catch {}
        }
        budgetAlertService.markDelivered(candidates)
    }

    private func checkMilestoneNotifications() async {
        guard settings.globalNotificationsEnabled,
              settings.macOSNotificationsEnabled else {
            return
        }
        let newly = milestoneNotificationService.newlyAchieved(milestones: activityMilestones)
        guard !newly.isEmpty else { return }
        for milestone in newly {
            do {
                try await localNotificationService.send(
                    title: t("Milestones"),
                    body: milestoneBody(milestone)
                )
            } catch {}
        }
        milestoneNotificationService.markNotified(newly)
    }

    private func milestoneBody(_ milestone: ActivityMilestone) -> String {
        switch milestone.dimension {
        case .lifetimeTokens:
            return String(format: t("Reached %@ lifetime local tokens (est.)"), TokenPilotFormatters.compactNumber(milestone.threshold))
        case .activeDays:
            return String(format: t("Reached %d active local days (est.)"), milestone.threshold)
        case .totalRequests:
            return String(format: t("Reached %@ total local requests (est.)"), TokenPilotFormatters.compactNumber(milestone.threshold))
        case .longestStreak:
            return String(format: t("Reached a %d-day longest local streak (est.)"), milestone.threshold)
        }
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
            await performRefreshPass(reason: reason)
        } while refreshQueued
    }

    private func performRefreshPass(reason: RefreshReason) async {
        let settingsAtStart = settings
        let intent = usageRefreshIntent(for: reason)
        let result = await usageStore.refresh(settings: settingsAtStart, intent: intent)

        snapshots = result.snapshots
        // Presentation-only: never merge into snapshots/capacity/history/export/alerts.
        // Drop late OAuth publication when consent/provider eligibility was revoked mid-flight.
        xaiOAuthResult = Self.publishableOAuthResult(
            result.xaiOAuthResult,
            settings: settings
        )
        dataSourceMode = determineDataMode(hasConnectedData: result.hasConnectedData, snapshots: result.snapshots, capacityObservations: result.capacityObservations, observedAt: result.observedAt)
        rebuildUsageFromHistory(using: result.snapshots)
        await checkBudgetAlerts()
        await checkMilestoneNotifications()
        await processCapacity(result: result, settingsAtStart: settingsAtStart)
        let usageSettingsChanged = TokenPilotRefreshPolicy.usageRefreshNeeded(from: settingsAtStart, to: settings)
        if usageSettingsChanged {
            scheduleSettingsDrivenRefresh()
        }
    }

    /// Consent/provider-off/termination must not surface a late OAuth weekly success.
    private static func publishableOAuthResult(
        _ result: XAIRefreshResult?,
        settings: AppSettings
    ) -> XAIRefreshResult? {
        guard let result else { return nil }
        guard settings.xaiEnabled, settings.isProviderEnabled(.xai) else { return nil }
        guard settings.xAI.experimentalOAuthWeeklyConsentVersion
            == XAISettings.experimentalOAuthWeeklyConsentVersionCurrent else {
            return nil
        }
        if result.completion == .cancelledOrdinarily || result.oauthFailure == .staleResult {
            return nil
        }
        return result
    }

    private func usageRefreshIntent(for reason: RefreshReason) -> UsageRefreshIntent {
        switch reason {
        case .manual:
            return .manual
        case .automaticTimer:
            return .automaticTimer
        case .settings:
            return .settingsChanged
        case .systemWake:
            return .automaticTimer
        }
    }
    private func processCapacity(result: UsageStore.Result, settingsAtStart: AppSettings) async {
        capacityRefreshErrors = result.capacityErrors

        if !result.capacityObservations.isEmpty {
            _ = await capacityEvidenceStore.record(result.capacityObservations)
        }
        capacityEvidenceRecords = (await capacityEvidenceStore.loadSnapshot()).records

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
        writeStatuslineSnapshot(assessments: assessments, observedAt: result.observedAt)

        let officialDeepSeekBalance = result.snapshots.first {
            $0.provider == .deepseek && $0.dataSource == .officialTelemetry && !$0.isStale
        }?.balance
        let migration = await capacityAlertMigrationCoordinator.migrate(settings: settingsAtStart, deepSeekBalance: officialDeepSeekBalance)
        capacityAlertMigrationRecoveryStatus = migration.recoveryStatus.recoveryRequired ? migration.recoveryStatus : nil

        let rulesLoad = await capacityAlertRuleStore.load()
        let deliveryLoad = await capacityAlertDeliveryStore.load()

        // Give every watched provider the alerts it should have had. This only ever adds a rule
        // whose identity is absent, so a rule the user edited is never touched, and it is skipped
        // entirely while the store is in recovery rather than writing into a file we could not
        // fully read.
        var activeRules = rulesLoad.rules
        if !rulesLoad.recoveryStatus.recoveryRequired {
            let reconciliation = CapacityAlertReconciler.reconcile(
                existing: rulesLoad.rules,
                enabledProviders: Set(settingsAtStart.enabledProviders),
                routing: CapacityAlertRouting(
                    macOS: settingsAtStart.macOSNotificationsEnabled,
                    telegram: settingsAtStart.telegramNotificationsEnabled,
                    discord: settingsAtStart.discordNotificationsEnabled
                ),
                observed: assessments
            )
            if reconciliation.didChange {
                let save = await capacityAlertRuleStore.save(reconciliation.rules)
                if !save.recoveryStatus.writeBlocked {
                    activeRules = reconciliation.rules
                }
            }
        }

        capacityAlertRules = activeRules
        capacityAlertRulesRecoveryStatus = rulesLoad.recoveryStatus
        capacityAlertDeliveryStates = deliveryLoad.states
        capacityAlertDeliveryRecoveryStatus = deliveryLoad.recoveryStatus
        let channels = CapacityAlertChannelSettings(
            settings: settingsAtStart,
            // Saved only: automatic delivery reads the Keychain, so an unsaved field must not
            // make a channel look available that would then fail every send.
            telegramCredentialPresent: hasSavedTelegramToken,
            discordCredentialPresent: hasSavedDiscordWebhook
        )
        let transition = capacityAlertTransitionEngine.evaluate(
            rules: activeRules,
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

    private func determineDataMode(
        hasConnectedData: Bool,
        snapshots: [ProviderSnapshot],
        capacityObservations: [CapacityObservation],
        observedAt: Date
    ) -> DataSourceMode {
        let assessments = capacityObservations.map { capacityAssessmentService.assess($0, now: observedAt) }
        return Self.derivedDataSourceMode(
            hasConnectedData: hasConnectedData,
            showMockDataWhenDisconnected: settings.showMockDataWhenDisconnected,
            snapshots: snapshots,
            assessments: assessments
        )
    }

    fileprivate nonisolated static func derivedDataSourceMode(
        hasConnectedData: Bool,
        showMockDataWhenDisconnected: Bool,
        snapshots: [ProviderSnapshot],
        assessments: [CapacityAssessment]
    ) -> DataSourceMode {
        if snapshots.contains(where: { $0.dataSource == .mock }) || (showMockDataWhenDisconnected && !hasConnectedData) {
            return .mock
        }
        if snapshots.contains(where: { $0.isStale }) || assessments.contains(where: { $0.freshness == .stale }) {
            return .stale
        }

        let evidenceSnapshots = snapshots.filter(Self.snapshotHasDataModeEvidence)
        let freshAssessments = assessments.filter { $0.freshness == .fresh }

        if evidenceSnapshots.contains(where: Self.isOfficialSupportedSnapshot) ||
            freshAssessments.contains(where: Self.isOfficialSupportedAssessment) {
            return .live
        }
        if evidenceSnapshots.contains(where: Self.isExperimentalSnapshot) ||
            freshAssessments.contains(where: Self.isExperimentalAssessment) {
            return .experimental
        }
        if evidenceSnapshots.contains(where: Self.isCompatibilityBridgeSnapshot) ||
            freshAssessments.contains(where: Self.isCompatibilityBridgeAssessment) {
            return .compatibilityBridge
        }
        if evidenceSnapshots.contains(where: Self.isManualSnapshot) ||
            freshAssessments.contains(where: Self.isManualAssessment) {
            return .manual
        }
        if evidenceSnapshots.contains(where: Self.isLocalSnapshot) ||
            freshAssessments.contains(where: Self.isLocalAssessment) {
            return .local
        }
        if hasConnectedData || !evidenceSnapshots.isEmpty || !freshAssessments.isEmpty {
            return .local
        }
        return .disconnected
    }

    fileprivate nonisolated static func snapshotHasDataModeEvidence(_ snapshot: ProviderSnapshot) -> Bool {
        !snapshot.events.isEmpty ||
            snapshot.primaryUsedPercent != nil ||
            snapshot.dailyRequestsUsed != nil ||
            snapshot.balance != nil ||
            snapshot.contextWindowUsedPercent != nil ||
            snapshot.todayTokens > 0 ||
            snapshot.dataSource == .mock
    }

    private nonisolated static func isNeutralXAISetupSnapshot(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.provider == .xai && !snapshotHasDataModeEvidence(snapshot)
    }

    private nonisolated static func isOfficialSupportedSnapshot(_ snapshot: ProviderSnapshot) -> Bool {
        guard !snapshot.isStale, !snapshot.isExperimental, snapshot.confidence != .manual else { return false }
        switch (snapshot.provider, snapshot.dataSource) {
        case (.claude, .officialStatusline), (.deepseek, .officialTelemetry):
            return true
        default:
            return false
        }
    }

    private nonisolated static func isOfficialSupportedAssessment(_ assessment: CapacityAssessment) -> Bool {
        assessment.observation.authority == .providerReported &&
            assessment.observation.stability == .supported
    }

    private nonisolated static func isExperimentalSnapshot(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.dataSource == .webUsage || (snapshot.isExperimental && snapshot.dataSource != .localLog)
    }

    private nonisolated static func isExperimentalAssessment(_ assessment: CapacityAssessment) -> Bool {
        assessment.observation.stability == .experimentalTransport
    }

    private nonisolated static func isCompatibilityBridgeSnapshot(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.provider == .gemini && snapshot.dataSource == .officialStatusline
    }

    private nonisolated static func isCompatibilityBridgeAssessment(_ assessment: CapacityAssessment) -> Bool {
        assessment.observation.stability == .compatibilityBridge
    }

    private nonisolated static func isManualSnapshot(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.dataSource == .manual ||
            snapshot.dataSource == .estimated ||
            snapshot.confidence == .manual
    }

    private nonisolated static func isManualAssessment(_ assessment: CapacityAssessment) -> Bool {
        assessment.observation.authority == .userEntered ||
            assessment.observation.stability == .manual
    }

    private nonisolated static func isLocalSnapshot(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.dataSource == .localLog || snapshot.isCodexLocalLogOnly
    }

    private nonisolated static func isLocalAssessment(_ assessment: CapacityAssessment) -> Bool {
        assessment.observation.authority == .localDerived
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


    /// Grants one provider's source folder.
    ///
    /// The Developer ID build reads the default home paths directly, so this is for a non-standard
    /// install location. A sandboxed build cannot read those paths at all, and this is the only way
    /// the provider ever gets data — the grant is stored as a read-only security-scoped bookmark.
    func chooseProviderSourceFolder(_ provider: Provider) {
        chooseLocalSource(
            provider: provider,
            prompt: t("Grant access"),
            message: t("Choose this provider's local data folder. TokenPilot keeps read-only access to it."),
            canChooseDirectories: true
        ) { [weak self] url, bookmarkData in
            guard let self else { return }
            var next = self.settings
            next.monitoredProviders.customPaths[provider] = url.path
            next.monitoredProviders.customBookmarks[provider] = bookmarkData
            self.settings = next
        }
    }

    /// Drops a previously granted folder so the provider falls back to its default paths.
    func clearProviderSourceFolder(_ provider: Provider) {
        var next = settings
        next.monitoredProviders.customPaths.removeValue(forKey: provider)
        next.monitoredProviders.customBookmarks.removeValue(forKey: provider)
        settings = next
        Task { await checkConnection(provider) }
    }

    /// Folder name of the granted source, for display. Never the full path.
    func grantedSourceFolderName(_ provider: Provider) -> String? {
        guard let path = settings.monitoredProviders.customPaths[provider], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// True when this build runs sandboxed, where providers only read folders the user granted.
    var requiresSourceGrants: Bool {
        ProviderSourceAccess.isSandboxed
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
        if provider == .xai {
            await refresh(reason: .manual)
            let source = await connectionService.check(settings: settings, provider: provider)
            dataSources[provider] = source
            connectionStatus[provider] = sourceStatusText(source)
            bannerMessage = "\(t("Grok Build")): \(sourceStatusText(provider))"
            return
        }
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
        await refreshProviderStatuses()
    }

    /// Fetches official status-page readings for enabled providers that publish one.
    /// Reads use a TTL cache and never block a refresh pass; failures keep the
    /// previous cached reading or report unknown.
    func refreshProviderStatuses() async {
        let enabled = Set(settings.enabledProviders)
        let providers = ProviderStatusService.statuspageEndpoints.keys.filter { enabled.contains($0) }
        var reports: [Provider: ProviderStatusReport] = providerStatusReports
        for provider in providers {
            let report = await providerStatusService.refreshStatus(for: provider)
            reports[provider] = report
        }
        providerStatusReports = reports
    }

    func providerStatusText(_ provider: Provider) -> String {
        guard let report = providerStatusReports[provider] else { return t("Not checked") }
        switch report.health {
        case .operational: return t("Operational")
        case .degraded: return t("Degraded")
        case .outage: return t("Outage")
        case .unknown: return t("Unknown")
        }
    }

    func providerStatusDetailText(_ provider: Provider) -> String {
        guard let report = providerStatusReports[provider] else { return t("Run a check to read the official status page") }
        var parts: [String] = []
        if !report.description.isEmpty {
            parts.append(report.description)
        }
        if let format = TokenPilotRelativeTimestamp.format(from: report.checkedAt, now: Date()) {
            let updated = format.arg.map { String(format: t(format.key), $0) } ?? t(format.key)
            parts.append(updated)
        }
        return parts.joined(separator: " · ")
    }

    private func applyDataSources(_ sources: [ProviderDataSource]) {
        let keyedSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.provider, $0) })
        dataSources = keyedSources
        connectionStatus = Dictionary(uniqueKeysWithValues: keyedSources.map { ($0.key, sourceStatusText($0.value)) })
    }

    func sourceStatusText(_ provider: Provider) -> String {
        if provider == .xai {
            if grokBuildSnapshot != nil {
                return t("LOCAL · Grok Build context window")
            }
            guard let source = dataSources[provider] else {
                return settings.isProviderEnabled(.xai) ? t("Grok Build signals not found") : t("Disabled")
            }
            return sourceStatusText(source)
        }
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
        if source.provider == .xai {
            return xAIStatusText(source)
        }
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
        if provider == .xai {
            return xAISourceDetailText()
        }
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
        if diagnostic.provider == .xai {
            return sourceStatusText(.xai)
        }
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
        return TokenPilotFormatters.clock(lastCheckedAt, language: settings.localization.language)
    }

    func diagnosticNextActionText(_ diagnostic: ProviderConnectionDiagnostic) -> String {
        if diagnostic.provider == .xai {
            return xAINextActionText()
        }
        return t(diagnostic.nextAction.localizationKey)
    }

    func diagnosticDetailText(_ diagnostic: ProviderConnectionDiagnostic) -> String {
        if diagnostic.provider == .xai {
            return xAISourceDetailText()
        }
        return t(diagnostic.redactedDetail)
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
        if provider == .xai,
           grokBuildSnapshot != nil {
            return TokenPilotDesign.calm
        }
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

    /// Exports app settings as a JSON backup. Credentials (bot tokens, webhooks,
    /// DeepSeek/xAI API keys) live in the Keychain and are never part of the
    /// payload; the Telegram chat ID is scrubbed on export.
    func exportSettings() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        do {
            let data = try SettingsBackupService().exportData(settings: settings)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "TokenPilot-settings.json"
            panel.canCreateDirectories = true
            panel.title = t("Export Settings")
            panel.message = t("Exports settings without credentials, chat IDs, webhooks, or API keys. Saved secrets stay in the Keychain.")
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                bannerMessage = "\(t("Exported")): \(url.lastPathComponent)"
            }
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    /// Imports app settings from a JSON backup created by `exportSettings`.
    /// Keychain-stored credentials are never part of the backup, so any
    /// configured integrations must be re-entered after importing.
    func importSettings() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = t("Import Settings")
        panel.message = t("Imports settings from a TokenPilot backup. Keychain-stored credentials must be re-entered.")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else {
            return
        }
        do {
            let imported = try SettingsBackupService().importSettings(from: data)
            settings = imported
            bannerMessage = t("Settings imported")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    /// A modal yes/no for something the app cannot undo.
    ///
    /// Reset Settings — which keeps the credentials — asked, and the five deletions that destroy a
    /// Keychain item did not. Delete sits beside Replace in the same row with the same metrics, and
    /// a Discord webhook cannot be shown again after saving: a mis-click meant a trip back to
    /// Discord to mint a new one.
    private func confirmDestructive(title: String, body: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: t("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Resets all preferences to factory defaults. Keychain-stored credentials
    /// are left untouched; only in-app settings reset.
    func resetSettings() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        let alert = NSAlert()
        alert.messageText = t("Reset settings?")
        alert.informativeText = t("All preferences return to factory defaults. Keychain-stored credentials are kept.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("Reset"))
        alert.addButton(withTitle: t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings = settingsStore.resetToDefaults()
        bannerMessage = t("Settings reset")
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
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        if let string = NSPasteboard.general.string(forType: .string) {
            var parsed = CodexStatusParser.safeParse(string, previous: settings.codexManual)
            parsed.pastedStatusOutput = ""
            settings.codexManual = parsed
            connectionStatus[.codex] = "\(t("Parsed /status")) · \(settings.codexManual.confidence.localizedLabel(language: settings.localization.language))"
        }
    }

    func markCodexWebSnapshotNow() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        var next = settings
        next.codexManual.webSnapshotEnabled = true
        next.codexManual.webSnapshotCapturedAt = Date()
        settings = next
        bannerMessage = t("Codex web snapshot marked as current.")
    }
    func markGrokWeeklySnapshotNow() {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        var next = settings
        next.xAI.weeklySnapshotEnabled = true
        next.xAI.weeklySnapshotCapturedAt = Date()
        next.xAI.weeklyRemainingPercent = min(max(next.xAI.weeklyRemainingPercent, 0), 100)
        next.xAI.weeklyResetText = next.xAI.weeklyResetText.trimmingCharacters(in: .whitespacesAndNewlines)
        settings = next
        bannerMessage = t("Grok weekly limit snapshot marked as current.")
    }

    func copyToClipboard(_ text: String) {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        bannerMessage = t("Copied.")
    }


    private var grokBuildSnapshot: ProviderSnapshot? {
        snapshots.first {
            $0.provider == .xai &&
                $0.dataSource == .localLog &&
                $0.model == "Grok Build" &&
                $0.contextWindowUsedPercent != nil
        }
    }

    private func xAIStatusText(_ source: ProviderDataSource) -> String {
        guard source.status != .disabled else { return t("Disabled") }
        guard let snapshot = grokBuildSnapshot else {
            return t("Grok Build signals not found")
        }
        if snapshot.isStale {
            return t("STALE · LOCAL · Grok Build context window")
        }
        return t("LOCAL · Grok Build context window")
    }

    private func xAISourceDetailText() -> String {
        guard settings.isProviderEnabled(.xai) else {
            return t("Enable Grok Build to read local context metadata.")
        }
        guard let snapshot = grokBuildSnapshot else {
            if snapshots.contains(where: {
                $0.provider == .xai &&
                    $0.dataSource == .localLog &&
                    $0.statusMessage?.contains("newer session has no signals") == true
            }) {
                return t("A newer Grok Build session has no signals.json yet. Local remaining percent is hidden until context metadata appears.")
            }
            return t("No Grok Build signals found. Start a Grok Build session, then run Check Connection.")
        }
        if snapshot.isStale {
            return t("Local Grok Build context metadata is stale. Start or continue a Grok Build session so signals.json updates. This is not subscription quota.")
        }
        return t("Reads only local context metadata from ~/.grok/sessions/**/signals.json. It never reads auth.json, OAuth tokens, prompts, or responses.")
    }

    private func xAINextActionText() -> String {
        guard settings.isProviderEnabled(.xai) else {
            return t("Enable Grok Build to read local context metadata.")
        }
        if grokBuildSnapshot?.isStale == true {
            return t("Continue a Grok Build session to refresh local context metadata.")
        }
        return t("Run Check Connection to refresh local Grok Build context metadata.")
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
        guard confirmDestructive(title: t("Delete the DeepSeek API key?"), body: t("TokenPilot forgets the key and stops reading your official balance. The key itself stays valid — you would paste it again to reconnect."), confirmTitle: t("Delete")) else { return }
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

    func apiKeyInput(for provider: Provider) -> String {
        switch provider {
        case .minimax: return minimaxAPIKeyInput
        case .zai: return zaiAPIKeyInput
        case .openrouter: return openrouterAPIKeyInput
        default: return deepSeekAPIKeyInput
        }
    }

    func setAPIKeyInput(_ value: String, for provider: Provider) {
        switch provider {
        case .minimax: minimaxAPIKeyInput = value
        case .zai: zaiAPIKeyInput = value
        case .openrouter: openrouterAPIKeyInput = value
        default: deepSeekAPIKeyInput = value
        }
    }

    func hasSavedAPIKey(for provider: Provider) -> Bool {
        switch provider {
        case .minimax: return hasSavedMinimaxAPIKey
        case .zai: return hasSavedZAIAPIKey
        case .openrouter: return hasSavedOpenRouterAPIKey
        default: return hasSavedDeepSeekAPIKey
        }
    }

    func saveAPIKey(for provider: Provider) {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        let key = apiKeyInput(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            bannerMessage = t("Enter an API key first.")
            return
        }
        do {
            try keychain.saveSecret(key, account: Self.apiKeyAccount(for: provider))
            setAPIKeyInput("", for: provider)
            switch provider {
            case .minimax: hasSavedMinimaxAPIKey = true
            case .zai: hasSavedZAIAPIKey = true
            case .openrouter: hasSavedOpenRouterAPIKey = true
            default: break
            }
            bannerMessage = t("API key saved in TokenPilot Keychain item.")
        } catch {
            bannerMessage = localizedErrorMessage(error)
        }
    }

    func deleteAPIKey(for provider: Provider) {
#if DEBUG
        guard !blockDebugFixtureExternalAction() else { return }
#endif
        guard confirmDestructive(title: t("Delete this API key?"), body: t("TokenPilot forgets the key and stops reading this provider's official usage. The key itself stays valid — you would paste it again to reconnect."), confirmTitle: t("Delete")) else { return }
        do {
            try keychain.deleteSecret(account: Self.apiKeyAccount(for: provider))
            setAPIKeyInput("", for: provider)
            switch provider {
            case .minimax: hasSavedMinimaxAPIKey = false
            case .zai: hasSavedZAIAPIKey = false
            case .openrouter: hasSavedOpenRouterAPIKey = false
            default: break
            }
            bannerMessage = t("API key deleted.")
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
        guard confirmDestructive(title: t("Delete the Telegram bot token?"), body: t("TokenPilot forgets the token and turns Telegram alerts off. The bot itself is untouched — you would paste its token again to reconnect."), confirmTitle: t("Delete")) else { return }
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
            let token = try telegramTokenForUse(preferringInput: true)
            let chatID = try await telegramService.findChatID(token: token)
            settings.telegram.chatID = chatID
            settings.telegram.connectionStatus = "Connected"
            bannerMessage = t("Chat ID found.")
        } catch {
            settings.telegram.connectionStatus = "Failed"
            bannerMessage = localizedErrorMessage(error)
        }
    }

    /// The typed-but-unsaved field wins only for something the user just pressed.
    ///
    /// It used to win everywhere. Half a pasted token sitting in Settings silently replaced the
    /// working saved one for automatic alerts, so alerts stopped arriving and only a rising
    /// failed-delivery count said so.
    private func telegramTokenForUse(preferringInput: Bool = false) throws -> String {
        if preferringInput, !telegramTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return telegramTokenInput
        }
        if let saved = try keychain.readSecret(account: Self.telegramTokenAccount) {
            return saved
        }
        throw TelegramError.notConfigured
    }

    /// Only the Send Test action reaches this, so it tests what the user is looking at.
    private func sendTelegram(text: String) async throws {
        let token = try telegramTokenForUse(preferringInput: true)
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
        guard confirmDestructive(title: t("Delete the Discord webhook?"), body: t("TokenPilot forgets the webhook and turns Discord alerts off. Discord cannot show a webhook URL again, so reconnecting means creating a new one."), confirmTitle: t("Delete")) else { return }
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

    /// See `telegramTokenForUse`: an unsaved field is for the button the user just pressed, not
    /// for the alerts that fire while nobody is looking.
    private func discordWebhookForUse(preferringInput: Bool = false) throws -> String {
        if preferringInput, !discordWebhookInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return discordWebhookInput
        }
        if let saved = try keychain.readSecret(account: Self.discordWebhookAccount) {
            return saved
        }
        throw DiscordError.notConfigured
    }

    private func sendDiscord(text: String) async throws {
        let webhookURL = try discordWebhookForUse(preferringInput: true)
        try await discordService.sendMessage(webhookURL: webhookURL, content: text)
    }

    private func deliverCapacity(_ attempts: [CapacityAlertDeliveryAttempt]) async -> [CapacityAlertDeliveryOutcome] {
        guard !attempts.isEmpty else { return [] }

        var outcomes = [CapacityAlertDeliveryOutcome?](repeating: nil, count: attempts.count)
        var pending: [(offset: Int, attempt: CapacityAlertDeliveryAttempt, send: @Sendable () async throws -> Void)] = []

        for (offset, attempt) in attempts.enumerated() {
            guard attempt.provider != .codex, attempt.provider != .gemini else {
                outcomes[offset] = CapacityAlertDeliveryOutcome(attempt: attempt, succeeded: false, completedAt: Date())
                continue
            }
            let message = capacityAlertMessage(for: attempt)
            switch attempt.key.channel {
            case .macOS:
                let service = localNotificationService
                pending.append((offset, attempt, { try await service.send(title: message.title, body: message.body) }))
            case .telegram:
                guard let token = try? telegramTokenForUse() else {
                    outcomes[offset] = CapacityAlertDeliveryOutcome(attempt: attempt, succeeded: false, completedAt: Date())
                    continue
                }
                let service = telegramService
                let chatID = settings.telegram.chatID
                pending.append((offset, attempt, { try await service.sendMessage(token: token, chatID: chatID, text: message.body) }))
            case .discord:
                guard let webhookURL = try? discordWebhookForUse() else {
                    outcomes[offset] = CapacityAlertDeliveryOutcome(attempt: attempt, succeeded: false, completedAt: Date())
                    continue
                }
                let service = discordService
                pending.append((offset, attempt, { try await service.sendMessage(webhookURL: webhookURL, content: message.body) }))
            }
        }

        // Channels are independent bounded-timeout network/system sends, so a stalled channel
        // must not delay the others or the refresh pass awaiting this call.
        await withTaskGroup(of: (offset: Int, succeeded: Bool, completedAt: Date).self) { group in
            for item in pending {
                group.addTask {
                    do {
                        try await item.send()
                        return (item.offset, true, Date())
                    } catch {
                        return (item.offset, false, Date())
                    }
                }
            }
            for await finished in group {
                let attempt = attempts[finished.offset]
                outcomes[finished.offset] = CapacityAlertDeliveryOutcome(
                    attempt: attempt,
                    succeeded: finished.succeeded,
                    completedAt: finished.completedAt
                )
            }
        }

        return outcomes.compactMap { $0 }
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
    case opencodeLocalSessions
    case kiroCreditMetered
    case runtimeRecoveryRequired
    case alertsUnsupportedCodexLegacy
    case alertsPendingDeepSeekCurrency
}

struct TokenPilotDebugFixture {
    static let privacyContract = "DEBUG fixture uses fixed dates. No network. No real provider accounts. No credentials. No local paths. No secrets."
    // Fixture events sit at offsets from this anchor while AggregationService filters against
    // wall-clock now, dropping anything in the future or older than the period. A hard-coded epoch
    // ages out and leaves every usage screen empty, and a fixed hour-of-day is still in the future
    // before that hour. Anchoring just behind now keeps offsets inside the today/last-7-days windows
    // at any launch time.
    private static let fixedReferenceDate = Date().addingTimeInterval(-300)

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
        let scenario = TokenPilotDebugScenario(rawValue: rawScenario) ?? .empty
        let selectedScreen = debugScreen(from: environment["TOKENPILOT_DEBUG_SCREEN"])
        let language = debugLanguage(from: environment["TOKENPILOT_DEBUG_LANGUAGE"])

        return make(scenario).applying(selectedScreen: selectedScreen, language: language)
    }

    private func applying(selectedScreen: TokenPilotViewModel.Screen, language: TokenPilotLanguage) -> TokenPilotDebugFixture {
        var localizedSettings = settings
        localizedSettings.localization.language = language

        return TokenPilotDebugFixture(
            scenario: scenario,
            referenceDate: referenceDate,
            selectedScreen: selectedScreen,
            settings: localizedSettings,
            snapshots: snapshots,
            historySnapshots: historySnapshots,
            limitHistorySamples: limitHistorySamples,
            dataSourceMode: dataSourceMode,
            dataSources: dataSources,
            capacityAssessments: capacityAssessments,
            capacityPresentations: capacityPresentations,
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

    private static func debugScreen(from rawValue: String?) -> TokenPilotViewModel.Screen {
        switch rawValue {
        case .some("history"):
            return .history
        case .some("settings"):
            return .settings
        case .some("overview"), .none:
            return .overview
        default:
            return .overview
        }
    }

    private static func debugLanguage(from rawValue: String?) -> TokenPilotLanguage {
        switch rawValue {
        case .some("ko"):
            return .ko
        case .some("ja"):
            return .ja
        case .some("zh-Hans"):
            return .zhHans
        case .some("en"), .none:
            return .en
        default:
            return .en
        }
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
                    isExperimental: true
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
                planLabel: "",
                fiveHourUsagePercentage: 72,
                weeklyUsagePercentage: 18,
                resetTimeText: "",
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
                    dataSource: .manual
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
            let balance = ProviderBalance(currency: "USD", totalBalance: decimal("3.34"), grantedBalance: decimal("0.00"), toppedUpBalance: decimal("3.34"), capturedAt: fixedReferenceDate)
            let snapshots = [
                ProviderSnapshot(
                    provider: .deepseek,
                    updatedAt: fixedReferenceDate,
                    confidence: .high,
                    dataSource: .officialTelemetry,
                    balance: balance
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .deepseek, deepSeekAPIKeyConfigured: true),
                snapshots: snapshots,
                observations: [
                    moneyObservation(amount: "3.34", currency: "USD", authority: .providerReported, stability: .supported, comparability: .comparable)
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

        case .opencodeLocalSessions:
            // Spread across days so the 7-day trend and per-model cards both have content.
            let events = [
                usageEvent(30, provider: .opencode, model: "anthropic/claude-sonnet", minutesBeforeNow: 12, input: 1_400, output: 320, cacheRead: 260, cost: "0.0180", dataSource: .localLog),
                usageEvent(31, provider: .opencode, model: "anthropic/claude-sonnet", minutesBeforeNow: 1_500, input: 900, output: 180, cacheRead: 140, cost: "0.0110", dataSource: .localLog),
                usageEvent(32, provider: .opencode, model: "opencode/hy3-free", minutesBeforeNow: 3_000, input: 2_600, output: 140, cacheRead: 0, dataSource: .localLog)
            ]
            let todayTokens = events
                .filter { Calendar.current.isDate($0.timestamp, inSameDayAs: fixedReferenceDate) }
                .reduce(0) { $0 + $1.totalTokens }
            let snapshots = [
                ProviderSnapshot(
                    provider: .opencode,
                    updatedAt: fixedReferenceDate,
                    todayTokens: todayTokens,
                    todayCostUSD: decimal("0.0180"),
                    confidence: .high,
                    dataSource: .localLog,
                    statusMessage: "Local session store · no quota window",
                    model: "anthropic/claude-sonnet",
                    events: events,
                    balance: ProviderBalance(currency: "USD", toppedUpBalance: decimal("0.0180"), capturedAt: fixedReferenceDate)
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .opencode),
                snapshots: snapshots,
                observations: [
                    openCodeTokensObservation(tokens: todayTokens, authority: .localDerived, stability: .supported, comparability: .incomparable)
                ]
            )

        case .kiroCreditMetered:
            // Kiro meters credits, so this fixture must keep token counts at zero.
            let events = [
                usageEvent(40, provider: .kiro, model: nil, minutesBeforeNow: 20, input: 0, output: 0, cacheRead: 0, dataSource: .localLog),
                usageEvent(41, provider: .kiro, model: nil, minutesBeforeNow: 1_600, input: 0, output: 0, cacheRead: 0, dataSource: .localLog)
            ]
            let snapshots = [
                ProviderSnapshot(
                    provider: .kiro,
                    updatedAt: fixedReferenceDate,
                    confidence: .high,
                    dataSource: .localLog,
                    statusMessage: "Local sessions · credits metered, no quota window",
                    contextWindowUsedPercent: 41,
                    events: events,
                    creditsUsed: decimal("56.84")
                )
            ]
            return fixture(
                scenario: scenario,
                settings: baseSettings(menuBarTarget: .kiro),
                snapshots: snapshots,
                observations: [
                    creditsObservation(credits: "56.84", authority: .localDerived, stability: .supported, comparability: .incomparable)
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
                    isExperimental: true
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
        let hasConnectedData = snapshots.contains(where: TokenPilotViewModel.snapshotHasDataModeEvidence)
        let dataSourceMode = explicitDataSourceMode ?? TokenPilotViewModel.derivedDataSourceMode(
            hasConnectedData: hasConnectedData,
            showMockDataWhenDisconnected: settings.showMockDataWhenDisconnected,
            snapshots: snapshots,
            assessments: assessments
        )
        assert(dataSourceMode == expectedDataSourceMode(for: scenario), "DEBUG fixture \(scenario.rawValue) inferred \(dataSourceMode.rawValue), expected \(expectedDataSourceMode(for: scenario).rawValue)")
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

    private static func creditsObservation(
        credits: String,
        authority: CapacityAuthority,
        stability: CapacityStability,
        comparability: CapacityComparability
    ) -> CapacityObservation {
        try! CapacityObservation(
            seriesID: kiroCreditsSeries(),
            observedAt: fixedReferenceDate,
            value: try! CapacityValue(credits: decimal(credits)),
            authority: authority,
            stability: stability,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 86_400),
            comparability: comparability,
            parserRevision: "debug-fixture-v1",
            now: fixedReferenceDate
        )
    }

    private static func kiroCreditsSeries() -> CapacitySeriesID {
        try! CapacitySeriesID(provider: .kiro, providerWindowID: "credits-used", kind: .balance, unit: .credits)
    }

    private static func openCodeTokensObservation(
        tokens: Int,
        authority: CapacityAuthority,
        stability: CapacityStability,
        comparability: CapacityComparability
    ) -> CapacityObservation {
        try! CapacityObservation(
            seriesID: try! CapacitySeriesID(provider: .opencode, providerWindowID: "context", kind: .context, unit: .tokens),
            observedAt: fixedReferenceDate,
            value: try! CapacityValue(tokens: tokens),
            authority: authority,
            stability: stability,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 86_400),
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
                    confidence: confidence
                )
            )
        })
    }

    private static func expectedDataSourceMode(for scenario: TokenPilotDebugScenario) -> TokenPilotViewModel.DataSourceMode {
        switch scenario {
        case .claudeOfficialFresh, .deepseekOfficialBalance:
            return .live
        case .claudeOfficialStale:
            return .stale
        case .codexLocalOnly, .alertsUnsupportedCodexLegacy, .opencodeLocalSessions, .kiroCreditMetered:
            return .local
        case .codexConnectorExperimental:
            return .experimental
        case .codexManual, .deepseekManualBalance:
            return .manual
        case .antigravityBridge:
            return .compatibilityBridge
        case .empty, .runtimeRecoveryRequired, .alertsPendingDeepSeekCurrency:
            return .disconnected
        }
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
