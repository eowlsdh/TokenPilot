import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: return "Cl"
        case .codex: return "Co"
        case .gemini: return "Ge"
        }
    }

    public var iconName: String {
        switch self {
        case .claude: return "brain"
        case .codex: return "terminal"
        case .gemini: return "sparkles"
        }
    }
}

public enum DataConfidence: String, Codable, CaseIterable, Identifiable, Sendable {
    case high
    case medium
    case low
    case manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .manual: return "Manual"
        }
    }
}

public enum UsageDataSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case officialStatusline
    case officialTelemetry
    case webUsage
    case localLog
    case manual
    case estimated
    case mock
    case unknown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .officialStatusline: return "official statusline"
        case .officialTelemetry: return "official telemetry"
        case .webUsage: return "limit hints"
        case .localLog: return "local log"
        case .manual: return "manual"
        case .estimated: return "est."
        case .mock: return "mock"
        case .unknown: return "unknown"
        }
    }
}

public struct UsageEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var model: String?
    public var timestamp: Date
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var reasoningTokens: Int
    public var toolTokens: Int
    public var requestCount: Int
    public var estimatedCostUSD: Decimal?
    public var source: String
    public var dataSource: UsageDataSource
    public var isEstimated: Bool
    public var authType: String?
    public var durationMS: Int?
    public var totalTokensOverride: Int?

    public init(
        id: UUID = UUID(),
        provider: Provider,
        model: String? = nil,
        timestamp: Date = Date(),
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        reasoningTokens: Int = 0,
        toolTokens: Int = 0,
        requestCount: Int = 1,
        estimatedCostUSD: Decimal? = nil,
        source: String,
        dataSource: UsageDataSource = .unknown,
        isEstimated: Bool = false,
        authType: String? = nil,
        durationMS: Int? = nil,
        totalTokensOverride: Int? = nil
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.timestamp = timestamp
        self.inputTokens = max(inputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.cacheReadTokens = max(cacheReadTokens, 0)
        self.cacheCreationTokens = max(cacheCreationTokens, 0)
        self.reasoningTokens = max(reasoningTokens, 0)
        self.toolTokens = max(toolTokens, 0)
        self.requestCount = max(requestCount, 0)
        self.estimatedCostUSD = estimatedCostUSD
        self.source = source
        self.dataSource = dataSource
        self.isEstimated = isEstimated
        self.authType = authType
        self.durationMS = durationMS
        self.totalTokensOverride = totalTokensOverride.map { max($0, 0) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case model
        case timestamp
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case reasoningTokens
        case toolTokens
        case requestCount
        case estimatedCostUSD
        case source
        case dataSource
        case isEstimated
        case authType
        case durationMS
        case totalTokensOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            provider: try container.decode(Provider.self, forKey: .provider),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            timestamp: try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(),
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
            cacheReadTokens: try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0,
            cacheCreationTokens: try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0,
            reasoningTokens: try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0,
            toolTokens: try container.decodeIfPresent(Int.self, forKey: .toolTokens) ?? 0,
            requestCount: try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 1,
            estimatedCostUSD: try container.decodeIfPresent(Decimal.self, forKey: .estimatedCostUSD),
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown",
            dataSource: try container.decodeIfPresent(UsageDataSource.self, forKey: .dataSource) ?? .unknown,
            isEstimated: try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false,
            authType: try container.decodeIfPresent(String.self, forKey: .authType),
            durationMS: try container.decodeIfPresent(Int.self, forKey: .durationMS),
            totalTokensOverride: try container.decodeIfPresent(Int.self, forKey: .totalTokensOverride)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try container.encode(reasoningTokens, forKey: .reasoningTokens)
        try container.encode(toolTokens, forKey: .toolTokens)
        try container.encode(requestCount, forKey: .requestCount)
        try container.encodeIfPresent(estimatedCostUSD, forKey: .estimatedCostUSD)
        try container.encode(source, forKey: .source)
        try container.encode(dataSource, forKey: .dataSource)
        try container.encode(isEstimated, forKey: .isEstimated)
        try container.encodeIfPresent(authType, forKey: .authType)
        try container.encodeIfPresent(durationMS, forKey: .durationMS)
        try container.encodeIfPresent(totalTokensOverride, forKey: .totalTokensOverride)
    }

    private var componentTokenTotal: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens + reasoningTokens + toolTokens
    }

    public var totalTokens: Int {
        if let totalTokensOverride { return max(totalTokensOverride, 0) }
        return componentTokenTotal
    }

    public var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

    public var isWebQuotaComparable: Bool {
        true
    }
}

public enum LimitWindowKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case weekly
    case dailyRequests

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "Week"
        case .dailyRequests: return "Daily"
        }
    }

    public var displayName: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .weekly: return "Weekly window"
        case .dailyRequests: return "Daily requests"
        }
    }
}

public struct LimitWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: LimitWindowKind
    public var name: String
    public var usedPercent: Int?
    public var resetAt: Date?
    public var label: String
    public var confidence: DataConfidence

    public var remainingPercent: Int? {
        usedPercent.map { min(max(100 - $0, 0), 100) }
    }

    public init(
        kind: LimitWindowKind,
        name: String? = nil,
        usedPercent: Int? = nil,
        resetAt: Date? = nil,
        label: String? = nil,
        confidence: DataConfidence = .low
    ) {
        self.kind = kind
        self.id = kind.rawValue
        self.name = name ?? kind.displayName
        self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
        self.resetAt = resetAt
        self.label = label ?? kind.label
        self.confidence = confidence
    }
}

public struct ProviderSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: Provider { provider }
    public var provider: Provider
    public var updatedAt: Date
    public var fiveHour: LimitWindow?
    public var weekly: LimitWindow?
    public var dailyRequestsUsed: Int?
    public var dailyRequestsLimit: Int?
    public var todayTokens: Int
    public var todayCostUSD: Decimal?
    public var confidence: DataConfidence
    public var dataSource: UsageDataSource
    public var isExperimental: Bool
    public var isStale: Bool
    public var statusMessage: String?
    public var model: String?
    public var contextWindowUsedPercent: Int?
    public var events: [UsageEvent]

    public init(
        provider: Provider,
        updatedAt: Date = Date(),
        fiveHour: LimitWindow? = nil,
        weekly: LimitWindow? = nil,
        dailyRequestsUsed: Int? = nil,
        dailyRequestsLimit: Int? = nil,
        todayTokens: Int = 0,
        todayCostUSD: Decimal? = nil,
        confidence: DataConfidence = .low,
        dataSource: UsageDataSource = .unknown,
        isExperimental: Bool = false,
        isStale: Bool = false,
        statusMessage: String? = nil,
        model: String? = nil,
        contextWindowUsedPercent: Int? = nil,
        events: [UsageEvent] = []
    ) {
        self.provider = provider
        self.updatedAt = updatedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.dailyRequestsUsed = dailyRequestsUsed.map { max($0, 0) }
        self.dailyRequestsLimit = dailyRequestsLimit.map { max($0, 0) }
        self.todayTokens = max(todayTokens, 0)
        self.todayCostUSD = todayCostUSD
        self.confidence = confidence
        self.dataSource = dataSource
        self.isExperimental = isExperimental
        self.isStale = isStale
        self.statusMessage = statusMessage
        self.model = model
        self.contextWindowUsedPercent = contextWindowUsedPercent.map { min(max($0, 0), 100) }
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case updatedAt
        case fiveHour
        case weekly
        case dailyRequestsUsed
        case dailyRequestsLimit
        case todayTokens
        case todayCostUSD
        case confidence
        case dataSource
        case isExperimental
        case isStale
        case statusMessage
        case model
        case contextWindowUsedPercent
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try container.decode(Provider.self, forKey: .provider),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            fiveHour: try container.decodeIfPresent(LimitWindow.self, forKey: .fiveHour),
            weekly: try container.decodeIfPresent(LimitWindow.self, forKey: .weekly),
            dailyRequestsUsed: try container.decodeIfPresent(Int.self, forKey: .dailyRequestsUsed),
            dailyRequestsLimit: try container.decodeIfPresent(Int.self, forKey: .dailyRequestsLimit),
            todayTokens: try container.decodeIfPresent(Int.self, forKey: .todayTokens) ?? 0,
            todayCostUSD: try container.decodeIfPresent(Decimal.self, forKey: .todayCostUSD),
            confidence: try container.decodeIfPresent(DataConfidence.self, forKey: .confidence) ?? .low,
            dataSource: try container.decodeIfPresent(UsageDataSource.self, forKey: .dataSource) ?? .unknown,
            isExperimental: try container.decodeIfPresent(Bool.self, forKey: .isExperimental) ?? false,
            isStale: try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false,
            statusMessage: try container.decodeIfPresent(String.self, forKey: .statusMessage),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            contextWindowUsedPercent: try container.decodeIfPresent(Int.self, forKey: .contextWindowUsedPercent),
            events: try container.decodeIfPresent([UsageEvent].self, forKey: .events) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try container.encodeIfPresent(weekly, forKey: .weekly)
        try container.encodeIfPresent(dailyRequestsUsed, forKey: .dailyRequestsUsed)
        try container.encodeIfPresent(dailyRequestsLimit, forKey: .dailyRequestsLimit)
        try container.encode(todayTokens, forKey: .todayTokens)
        try container.encodeIfPresent(todayCostUSD, forKey: .todayCostUSD)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(dataSource, forKey: .dataSource)
        try container.encode(isExperimental, forKey: .isExperimental)
        try container.encode(isStale, forKey: .isStale)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(contextWindowUsedPercent, forKey: .contextWindowUsedPercent)
        try container.encode(events, forKey: .events)
    }

    public var dailyRequestsPercent: Int? {
        guard let used = dailyRequestsUsed, let limit = dailyRequestsLimit, limit > 0 else { return nil }
        return min(max(Int((Double(used) / Double(limit) * 100).rounded()), 0), 100)
    }

    public var primaryUsedPercent: Int? {
        if let fiveHour = fiveHour?.usedPercent { return fiveHour }
        if let dailyRequestsPercent { return dailyRequestsPercent }
        return weekly?.usedPercent
    }

    public var isCodexLocalLogOnly: Bool {
        provider == .codex && dataSource == .localLog && isExperimental
    }
}

public struct ProviderLimitSample: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: Provider
    public var timestamp: Date
    public var window: LimitWindowKind
    public var usedPercent: Int
    public var remainingPercent: Int
    public var confidence: DataConfidence
    public var source: String
    public var totalTokens: Int?

    public init(
        id: String? = nil,
        provider: Provider,
        timestamp: Date = Date(),
        window: LimitWindowKind,
        usedPercent: Int,
        remainingPercent: Int,
        confidence: DataConfidence = .low,
        source: String,
        totalTokens: Int? = nil
    ) {
        self.provider = provider
        self.timestamp = timestamp
        self.window = window
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.remainingPercent = min(max(remainingPercent, 0), 100)
        self.confidence = confidence
        self.source = source
        self.totalTokens = totalTokens.map { max($0, 0) }
        self.id = id ?? "\(provider.rawValue)-\(window.rawValue)-\(Int(timestamp.timeIntervalSince1970))-\(self.usedPercent)"
    }
}

public struct ChallengeGoal: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var provider: Provider?
    public var targetTokens: Int?
    public var targetCostUSD: Decimal?
    public var startsAt: Date
    public var endsAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        provider: Provider? = nil,
        targetTokens: Int? = nil,
        targetCostUSD: Decimal? = nil,
        startsAt: Date = Date(),
        endsAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.targetTokens = targetTokens
        self.targetCostUSD = targetCostUSD
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

public struct ChallengeProgress: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var goalID: UUID
    public var tokensUsed: Int
    public var costUSD: Decimal
    public var updatedAt: Date

    public init(id: UUID = UUID(), goalID: UUID, tokensUsed: Int = 0, costUSD: Decimal = 0, updatedAt: Date = Date()) {
        self.id = id
        self.goalID = goalID
        self.tokensUsed = tokensUsed
        self.costUSD = costUSD
        self.updatedAt = updatedAt
    }
}

public enum AlertThreshold: String, Codable, CaseIterable, Identifiable, Sendable {
    case reset
    case fifty
    case eighty
    case hundred

    public var id: String { rawValue }

    public var percent: Int? {
        switch self {
        case .reset: return nil
        case .fifty: return 50
        case .eighty: return 80
        case .hundred: return 100
        }
    }

    public var shortLabel: String {
        switch self {
        case .reset: return "Reset"
        case .fifty: return "50"
        case .eighty: return "80"
        case .hundred: return "100"
        }
    }
}

public enum NotificationChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case macOS
    case telegram
    case discord

    public var id: String { rawValue }
}

public struct AlertRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: Provider
    public var window: LimitWindowKind
    public var resetEnabled: Bool
    public var fiftyEnabled: Bool
    public var eightyEnabled: Bool
    public var hundredEnabled: Bool
    public var macOSEnabled: Bool
    public var telegramEnabled: Bool
    public var discordEnabled: Bool

    public init(
        provider: Provider,
        window: LimitWindowKind,
        resetEnabled: Bool = true,
        fiftyEnabled: Bool = false,
        eightyEnabled: Bool = true,
        hundredEnabled: Bool = true,
        macOSEnabled: Bool = true,
        telegramEnabled: Bool = false,
        discordEnabled: Bool = false
    ) {
        self.provider = provider
        self.window = window
        self.id = "\(provider.rawValue).\(window.rawValue)"
        self.resetEnabled = resetEnabled
        self.fiftyEnabled = fiftyEnabled
        self.eightyEnabled = eightyEnabled
        self.hundredEnabled = hundredEnabled
        self.macOSEnabled = macOSEnabled
        self.telegramEnabled = telegramEnabled
        self.discordEnabled = discordEnabled
    }

    public func isEnabled(_ threshold: AlertThreshold) -> Bool {
        switch threshold {
        case .reset: return resetEnabled
        case .fifty: return fiftyEnabled
        case .eighty: return eightyEnabled
        case .hundred: return hundredEnabled
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case window
        case resetEnabled
        case fiftyEnabled
        case eightyEnabled
        case hundredEnabled
        case macOSEnabled
        case telegramEnabled
        case discordEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(Provider.self, forKey: .provider)
        window = try container.decode(LimitWindowKind.self, forKey: .window)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "\(provider.rawValue).\(window.rawValue)"
        resetEnabled = try container.decodeIfPresent(Bool.self, forKey: .resetEnabled) ?? true
        fiftyEnabled = try container.decodeIfPresent(Bool.self, forKey: .fiftyEnabled) ?? false
        eightyEnabled = try container.decodeIfPresent(Bool.self, forKey: .eightyEnabled) ?? true
        hundredEnabled = try container.decodeIfPresent(Bool.self, forKey: .hundredEnabled) ?? true
        macOSEnabled = try container.decodeIfPresent(Bool.self, forKey: .macOSEnabled) ?? true
        telegramEnabled = try container.decodeIfPresent(Bool.self, forKey: .telegramEnabled) ?? false
        discordEnabled = try container.decodeIfPresent(Bool.self, forKey: .discordEnabled) ?? false
    }
}

public struct AlertEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var window: LimitWindowKind
    public var threshold: AlertThreshold
    public var usedPercent: Int?
    public var resetAt: Date?
    public var resetCycleId: String
    public var title: String
    public var body: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        provider: Provider,
        window: LimitWindowKind,
        threshold: AlertThreshold,
        usedPercent: Int? = nil,
        resetAt: Date? = nil,
        resetCycleId: String,
        title: String,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.window = window
        self.threshold = threshold
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.resetCycleId = resetCycleId
        self.title = title
        self.body = body
        self.createdAt = createdAt
    }
}

public struct AlertDeliveryState: Codable, Equatable, Sendable {
    public var provider: Provider
    public var window: LimitWindowKind
    public var resetCycleId: String
    public var sentReset: Bool
    public var sent50: Bool
    public var sent80: Bool
    public var sent100: Bool
    public var lastUsedPercent: Int?
    public var lastResetAt: Date?
    public var lastSentAt: Date?

    public init(
        provider: Provider,
        window: LimitWindowKind,
        resetCycleId: String,
        sentReset: Bool = false,
        sent50: Bool = false,
        sent80: Bool = false,
        sent100: Bool = false,
        lastUsedPercent: Int? = nil,
        lastResetAt: Date? = nil,
        lastSentAt: Date? = nil
    ) {
        self.provider = provider
        self.window = window
        self.resetCycleId = resetCycleId
        self.sentReset = sentReset
        self.sent50 = sent50
        self.sent80 = sent80
        self.sent100 = sent100
        self.lastUsedPercent = lastUsedPercent
        self.lastResetAt = lastResetAt
        self.lastSentAt = lastSentAt
    }
}

public struct TelegramSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var chatID: String
    public var connectionStatus: String
    public var lastTestSentAt: Date?

    public init(isEnabled: Bool = false, chatID: String = "", connectionStatus: String = "Not configured", lastTestSentAt: Date? = nil) {
        self.isEnabled = isEnabled
        self.chatID = chatID
        self.connectionStatus = connectionStatus
        self.lastTestSentAt = lastTestSentAt
    }
}

public struct DiscordSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var connectionStatus: String
    public var lastTestSentAt: Date?

    public var webhookSummary: String { "No webhook" }

    public init(isEnabled: Bool = false, connectionStatus: String = "Not configured", lastTestSentAt: Date? = nil) {
        self.isEnabled = isEnabled
        self.connectionStatus = connectionStatus
        self.lastTestSentAt = lastTestSentAt
    }
}

public enum TokenPilotLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case ko
    case en
    case zhHans = "zh-Hans"
    case ja

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System Default"
        case .ko: return "한국어"
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        }
    }

    public var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .ko: return "ko"
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        case .ja: return "ja"
        }
    }

    public var bundleCode: String? {
        localeIdentifier
    }
}

public struct LocalizationSettings: Codable, Equatable, Sendable {
    public var language: TokenPilotLanguage
    public var requiresRestartNoteShown: Bool

    public init(language: TokenPilotLanguage = .system, requiresRestartNoteShown: Bool = true) {
        self.language = language
        self.requiresRestartNoteShown = requiresRestartNoteShown
    }
}

public struct CodexManualSettings: Codable, Equatable, Sendable {
    public var planLabel: String
    public var fiveHourUsagePercentage: Int
    public var weeklyUsagePercentage: Int
    public var resetTimeText: String
    public var notes: String
    public var pastedStatusOutput: String
    public var confidence: DataConfidence
    public var webSnapshotEnabled: Bool
    public var webConnectorEnabled: Bool
    public var webTodayTokens: Int
    public var webSnapshotCapturedAt: Date?

    public init(
        planLabel: String = "Manual",
        fiveHourUsagePercentage: Int = 0,
        weeklyUsagePercentage: Int = 0,
        resetTimeText: String = "",
        notes: String = "",
        pastedStatusOutput: String = "",
        confidence: DataConfidence = .manual,
        webSnapshotEnabled: Bool = false,
        webConnectorEnabled: Bool = false,
        webTodayTokens: Int = 0,
        webSnapshotCapturedAt: Date? = nil
    ) {
        self.planLabel = planLabel
        self.fiveHourUsagePercentage = min(max(fiveHourUsagePercentage, 0), 100)
        self.weeklyUsagePercentage = min(max(weeklyUsagePercentage, 0), 100)
        self.resetTimeText = resetTimeText
        self.notes = notes
        self.pastedStatusOutput = pastedStatusOutput
        self.confidence = confidence
        self.webSnapshotEnabled = webSnapshotEnabled
        self.webConnectorEnabled = webConnectorEnabled
        self.webTodayTokens = max(webTodayTokens, 0)
        self.webSnapshotCapturedAt = webSnapshotCapturedAt
    }

    private enum CodingKeys: String, CodingKey {
        case planLabel
        case fiveHourUsagePercentage
        case weeklyUsagePercentage
        case resetTimeText
        case notes
        case pastedStatusOutput
        case confidence
        case webSnapshotEnabled
        case webConnectorEnabled
        case webTodayTokens
        case webSnapshotCapturedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            planLabel: try container.decodeIfPresent(String.self, forKey: .planLabel) ?? "Manual",
            fiveHourUsagePercentage: try container.decodeIfPresent(Int.self, forKey: .fiveHourUsagePercentage) ?? 0,
            weeklyUsagePercentage: try container.decodeIfPresent(Int.self, forKey: .weeklyUsagePercentage) ?? 0,
            resetTimeText: try container.decodeIfPresent(String.self, forKey: .resetTimeText) ?? "",
            notes: try container.decodeIfPresent(String.self, forKey: .notes) ?? "",
            pastedStatusOutput: try container.decodeIfPresent(String.self, forKey: .pastedStatusOutput) ?? "",
            confidence: try container.decodeIfPresent(DataConfidence.self, forKey: .confidence) ?? .manual,
            webSnapshotEnabled: try container.decodeIfPresent(Bool.self, forKey: .webSnapshotEnabled) ?? false,
            webConnectorEnabled: try container.decodeIfPresent(Bool.self, forKey: .webConnectorEnabled) ?? false,
            webTodayTokens: try container.decodeIfPresent(Int.self, forKey: .webTodayTokens) ?? 0,
            webSnapshotCapturedAt: try container.decodeIfPresent(Date.self, forKey: .webSnapshotCapturedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(planLabel, forKey: .planLabel)
        try container.encode(fiveHourUsagePercentage, forKey: .fiveHourUsagePercentage)
        try container.encode(weeklyUsagePercentage, forKey: .weeklyUsagePercentage)
        try container.encode(resetTimeText, forKey: .resetTimeText)
        try container.encode(notes, forKey: .notes)
        try container.encode(pastedStatusOutput, forKey: .pastedStatusOutput)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(webSnapshotEnabled, forKey: .webSnapshotEnabled)
        try container.encode(webConnectorEnabled, forKey: .webConnectorEnabled)
        try container.encode(webTodayTokens, forKey: .webTodayTokens)
        try container.encodeIfPresent(webSnapshotCapturedAt, forKey: .webSnapshotCapturedAt)
    }
}

public enum NotificationPermissionState: String, Codable, CaseIterable, Identifiable, Sendable {
    case notRequested = "Not requested"
    case granted = "Granted"
    case denied = "Denied"
    case unknown = "Unknown"

    public var id: String { rawValue }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var claudeEnabled: Bool
    public var codexEnabled: Bool
    public var geminiEnabled: Bool
    public var monitoredProviders: MonitoredProviderSettings
    public var menuBarDisplayTarget: Provider?
    public var claudeStatusFilePath: String
    public var claudeStatusFileBookmarkData: Data?
    public var geminiTelemetryLogPath: String
    public var geminiTelemetrySourceBookmarkData: Data?
    public var geminiDailyRequestCap: Int
    public var codexManual: CodexManualSettings
    public var globalNotificationsEnabled: Bool
    public var macOSNotificationsEnabled: Bool
    public var telegramNotificationsEnabled: Bool
    public var discordNotificationsEnabled: Bool
    public var notificationPermissionStatus: NotificationPermissionState
    public var telegram: TelegramSettings
    public var discord: DiscordSettings
    public var localization: LocalizationSettings
    public var alertRules: [AlertRule]
    public var showMockDataWhenDisconnected: Bool

    public init(
        claudeEnabled: Bool = true,
        codexEnabled: Bool = true,
        geminiEnabled: Bool = true,
        claudeStatusFilePath: String = "~/Library/Application Support/TokenPilot/claude-statusline.json",
        claudeStatusFileBookmarkData: Data? = nil,
        geminiTelemetryLogPath: String = "~/.gemini/telemetry.log",
        geminiTelemetrySourceBookmarkData: Data? = nil,
        geminiDailyRequestCap: Int = 1000,
        codexManual: CodexManualSettings = CodexManualSettings(),
        globalNotificationsEnabled: Bool = true,
        macOSNotificationsEnabled: Bool = true,
        telegramNotificationsEnabled: Bool = false,
        discordNotificationsEnabled: Bool = false,
        notificationPermissionStatus: NotificationPermissionState = .notRequested,
        telegram: TelegramSettings = TelegramSettings(),
        discord: DiscordSettings = DiscordSettings(),
        localization: LocalizationSettings = LocalizationSettings(),
        alertRules: [AlertRule] = AppSettings.defaultAlertRules,
        showMockDataWhenDisconnected: Bool = false,
        monitoredProviders: MonitoredProviderSettings = MonitoredProviderSettings(),
        menuBarDisplayTarget: Provider? = nil
    ) {
        self.claudeEnabled = claudeEnabled
        self.codexEnabled = codexEnabled
        self.geminiEnabled = geminiEnabled
        self.monitoredProviders = monitoredProviders
        self.menuBarDisplayTarget = menuBarDisplayTarget
        self.claudeStatusFilePath = claudeStatusFilePath
        self.claudeStatusFileBookmarkData = claudeStatusFileBookmarkData
        self.geminiTelemetryLogPath = geminiTelemetryLogPath
        self.geminiTelemetrySourceBookmarkData = geminiTelemetrySourceBookmarkData
        self.geminiDailyRequestCap = geminiDailyRequestCap
        self.codexManual = codexManual
        self.globalNotificationsEnabled = globalNotificationsEnabled
        self.macOSNotificationsEnabled = macOSNotificationsEnabled
        self.telegramNotificationsEnabled = telegramNotificationsEnabled
        self.discordNotificationsEnabled = discordNotificationsEnabled
        self.notificationPermissionStatus = notificationPermissionStatus
        self.telegram = telegram
        self.discord = discord
        self.localization = localization
        self.alertRules = alertRules
        self.showMockDataWhenDisconnected = showMockDataWhenDisconnected
    }

    private enum CodingKeys: String, CodingKey {
        case claudeEnabled
        case codexEnabled
        case geminiEnabled
        case monitoredProviders
        case menuBarDisplayTarget
        case claudeStatusFilePath
        case claudeStatusFileBookmarkData
        case geminiTelemetryLogPath
        case geminiTelemetrySourceBookmarkData
        case geminiDailyRequestCap
        case codexManual
        case globalNotificationsEnabled
        case macOSNotificationsEnabled
        case telegramNotificationsEnabled
        case discordNotificationsEnabled
        case notificationPermissionStatus
        case telegram
        case discord
        case localization
        case alertRules
        case showMockDataWhenDisconnected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            claudeEnabled: try container.decodeIfPresent(Bool.self, forKey: .claudeEnabled) ?? true,
            codexEnabled: try container.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? true,
            geminiEnabled: try container.decodeIfPresent(Bool.self, forKey: .geminiEnabled) ?? true,
            claudeStatusFilePath: try container.decodeIfPresent(String.self, forKey: .claudeStatusFilePath) ?? "~/Library/Application Support/TokenPilot/claude-statusline.json",
            claudeStatusFileBookmarkData: try container.decodeIfPresent(Data.self, forKey: .claudeStatusFileBookmarkData),
            geminiTelemetryLogPath: try container.decodeIfPresent(String.self, forKey: .geminiTelemetryLogPath) ?? "~/.gemini/telemetry.log",
            geminiTelemetrySourceBookmarkData: try container.decodeIfPresent(Data.self, forKey: .geminiTelemetrySourceBookmarkData),
            geminiDailyRequestCap: try container.decodeIfPresent(Int.self, forKey: .geminiDailyRequestCap) ?? 1000,
            codexManual: try container.decodeIfPresent(CodexManualSettings.self, forKey: .codexManual) ?? CodexManualSettings(),
            globalNotificationsEnabled: try container.decodeIfPresent(Bool.self, forKey: .globalNotificationsEnabled) ?? true,
            macOSNotificationsEnabled: try container.decodeIfPresent(Bool.self, forKey: .macOSNotificationsEnabled) ?? true,
            telegramNotificationsEnabled: try container.decodeIfPresent(Bool.self, forKey: .telegramNotificationsEnabled) ?? false,
            discordNotificationsEnabled: try container.decodeIfPresent(Bool.self, forKey: .discordNotificationsEnabled) ?? false,
            notificationPermissionStatus: try container.decodeIfPresent(NotificationPermissionState.self, forKey: .notificationPermissionStatus) ?? .notRequested,
            telegram: try container.decodeIfPresent(TelegramSettings.self, forKey: .telegram) ?? TelegramSettings(),
            discord: try container.decodeIfPresent(DiscordSettings.self, forKey: .discord) ?? DiscordSettings(),
            localization: try container.decodeIfPresent(LocalizationSettings.self, forKey: .localization) ?? LocalizationSettings(),
            alertRules: try container.decodeIfPresent([AlertRule].self, forKey: .alertRules) ?? AppSettings.defaultAlertRules,
            showMockDataWhenDisconnected: try container.decodeIfPresent(Bool.self, forKey: .showMockDataWhenDisconnected) ?? false,
            monitoredProviders: try container.decodeIfPresent(MonitoredProviderSettings.self, forKey: .monitoredProviders) ?? MonitoredProviderSettings(),
            menuBarDisplayTarget: try container.decodeIfPresent(Provider.self, forKey: .menuBarDisplayTarget)
        )
    }

    public var enabledProviders: [Provider] {
        let legacyEnabled = Set(Provider.allCases.filter { isLegacyProviderFlagEnabled($0) })
        let monitoredEnabled = monitoredProviders.enabledProviders
        let effective = monitoredEnabled.isEmpty ? legacyEnabled : legacyEnabled.intersection(monitoredEnabled)
        let fallback = !effective.isEmpty ? effective : (!legacyEnabled.isEmpty ? legacyEnabled : (!monitoredEnabled.isEmpty ? monitoredEnabled : Set(Provider.allCases)))
        return Provider.allCases.filter { fallback.contains($0) }
    }

    public func isProviderEnabled(_ provider: Provider) -> Bool {
        enabledProviders.contains(provider)
    }

    public func localSourceBookmarkData(for provider: Provider) -> Data? {
        switch provider {
        case .claude:
            return claudeStatusFileBookmarkData
        case .gemini:
            return geminiTelemetrySourceBookmarkData
        case .codex:
            return nil
        }
    }

    public mutating func setLocalSourceBookmarkData(_ data: Data?, for provider: Provider) {
        switch provider {
        case .claude:
            claudeStatusFileBookmarkData = data
        case .gemini:
            geminiTelemetrySourceBookmarkData = data
        case .codex:
            break
        }
    }

    @discardableResult
    public mutating func setProviderEnabled(_ provider: Provider, isEnabled: Bool) -> Bool {
        var next = Set(enabledProviders)
        if isEnabled {
            next.insert(provider)
        } else {
            guard next.count > 1 else { return false }
            next.remove(provider)
        }
        applyEnabledProviders(next)
        return true
    }

    public mutating func normalizeProviderEnablement() {
        applyEnabledProviders(Set(enabledProviders))
    }

    private func isLegacyProviderFlagEnabled(_ provider: Provider) -> Bool {
        switch provider {
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        case .gemini: return geminiEnabled
        }
    }

    private mutating func applyEnabledProviders(_ providers: Set<Provider>) {
        let safeProviders = providers.isEmpty ? Set(Provider.allCases) : providers
        claudeEnabled = safeProviders.contains(.claude)
        codexEnabled = safeProviders.contains(.codex)
        geminiEnabled = safeProviders.contains(.gemini)
        monitoredProviders.enabledProviders = safeProviders
    }

    public static var defaultAlertRules: [AlertRule] {
        [
            AlertRule(provider: .claude, window: .fiveHour),
            AlertRule(provider: .claude, window: .weekly),
            AlertRule(provider: .codex, window: .fiveHour),
            AlertRule(provider: .codex, window: .weekly),
            AlertRule(provider: .gemini, window: .dailyRequests)
        ]
    }
}

public struct UsageMetrics: Codable, Equatable, Sendable {
    public var totalTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheTokens: Int
    public var requestCount: Int
    public var estimatedCostUSD: Decimal
    public var mostUsedProvider: Provider?
    public var busiestHour: Int?

    public init(
        totalTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheTokens: Int = 0,
        requestCount: Int = 0,
        estimatedCostUSD: Decimal = 0,
        mostUsedProvider: Provider? = nil,
        busiestHour: Int? = nil
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.requestCount = requestCount
        self.estimatedCostUSD = estimatedCostUSD
        self.mostUsedProvider = mostUsedProvider
        self.busiestHour = busiestHour
    }
}

public enum HistoryPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case today
    case last7Days
    case thisMonth

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        case .thisMonth: return "This month"
        }
    }
}

public struct ProviderShare: Codable, Equatable, Identifiable, Sendable {
    public var id: Provider { provider }
    public var provider: Provider
    public var tokens: Int
    public var percent: Int

    public init(provider: Provider, tokens: Int, percent: Int) {
        self.provider = provider
        self.tokens = tokens
        self.percent = min(max(percent, 0), 100)
    }
}

public struct DailyUsageBar: Codable, Equatable, Identifiable, Sendable {
    public var id: String { dayLabel }
    public var dayLabel: String
    public var tokens: Int

    public init(dayLabel: String, tokens: Int) {
        self.dayLabel = dayLabel
        self.tokens = max(tokens, 0)
    }
}

public struct AggregatedUsage: Codable, Equatable, Sendable {
    public var period: HistoryPeriod
    public var metrics: UsageMetrics
    public var sevenDayBars: [DailyUsageBar]
    public var providerShare: [ProviderShare]
    public var events: [UsageEvent]

    public init(
        period: HistoryPeriod,
        metrics: UsageMetrics = UsageMetrics(),
        sevenDayBars: [DailyUsageBar] = [],
        providerShare: [ProviderShare] = [],
        events: [UsageEvent] = []
    ) {
        self.period = period
        self.metrics = metrics
        self.sevenDayBars = sevenDayBars
        self.providerShare = providerShare
        self.events = events
    }
}
