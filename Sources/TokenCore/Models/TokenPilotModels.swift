import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case gemini
    case deepseek
    case xai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Antigravity CLI"
        case .deepseek: return "DeepSeek"
        case .xai: return "Grok / xAI API"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: return "Cl"
        case .codex: return "Co"
        case .gemini: return "AG"
        case .deepseek: return "DS"
        case .xai: return "xAI"
        }
    }

    public var iconName: String {
        switch self {
        case .claude: return "brain"
        case .codex: return "terminal"
        case .gemini: return "sparkles"
        case .deepseek: return "dollarsign.circle"
        case .xai: return "server.rack"
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
    case officialManagementAPI
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
        case .officialManagementAPI: return "official management API (future)"
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
    public var isExperimental: Bool
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
        isExperimental: Bool = false,
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
        self.isExperimental = isExperimental
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
        case isExperimental
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
            isExperimental: try container.decodeIfPresent(Bool.self, forKey: .isExperimental) ?? false,
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
        try container.encode(isExperimental, forKey: .isExperimental)
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
        !(provider == .codex && dataSource == .localLog && isExperimental)
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
    public var providerWindowID: String?
    public var durationMinutes: Int?

    public var remainingPercent: Int? {
        usedPercent.map { min(max(100 - $0, 0), 100) }
    }

    public init(
        kind: LimitWindowKind,
        name: String? = nil,
        usedPercent: Int? = nil,
        resetAt: Date? = nil,
        label: String? = nil,
        confidence: DataConfidence = .low,
        providerWindowID: String? = nil,
        durationMinutes: Int? = nil
    ) {
        let normalizedProviderWindowID = Self.normalizedProviderWindowID(providerWindowID)
        let normalizedDuration = durationMinutes.flatMap { $0 > 0 ? $0 : nil }
        self.kind = kind
        self.id = Self.makeID(kind: kind, providerWindowID: normalizedProviderWindowID, durationMinutes: normalizedDuration)
        self.name = name ?? Self.displayName(kind: kind, durationMinutes: normalizedDuration)
        self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
        self.resetAt = resetAt
        self.label = label ?? Self.label(kind: kind, durationMinutes: normalizedDuration)
        self.confidence = confidence
        self.providerWindowID = normalizedProviderWindowID
        self.durationMinutes = normalizedDuration
    }

    private static func makeID(kind: LimitWindowKind, providerWindowID: String?, durationMinutes: Int?) -> String {
        [providerWindowID ?? kind.rawValue, durationMinutes.map(String.init)].compactMap { $0 }.joined(separator: "-")
    }

    private static func label(kind: LimitWindowKind, durationMinutes: Int?) -> String {
        guard let durationMinutes else { return kind.label }
        if durationMinutes < 60 { return "\(durationMinutes)m" }
        if durationMinutes < 1_440, durationMinutes % 60 == 0 { return "\(durationMinutes / 60)h" }
        if durationMinutes % 1_440 == 0 { return "\(durationMinutes / 1_440)d" }
        return "\(durationMinutes)min"
    }

    private static func displayName(kind: LimitWindowKind, durationMinutes: Int?) -> String {
        guard let durationMinutes else { return kind.displayName }
        return "\(label(kind: kind, durationMinutes: durationMinutes)) rolling window"
    }

    private static func normalizedProviderWindowID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalizedCharacters = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 48...57, 97...122:
                return String(scalar)
            case 45, 46, 95:
                return String(scalar)
            default:
                return "-"
            }
        }
        let normalized = normalizedCharacters.joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        guard (1...64).contains(normalized.utf8.count) else { return nil }
        return normalized
    }
}

public struct ProviderBalance: Codable, Equatable, Sendable {
    public var currency: String
    public var totalBalance: Decimal?
    public var grantedBalance: Decimal?
    public var toppedUpBalance: Decimal
    public var capturedAt: Date

    public init(currency: String, totalBalance: Decimal? = nil, grantedBalance: Decimal? = nil, toppedUpBalance: Decimal, capturedAt: Date = Date()) {
        self.currency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = max(toppedUpBalance, 0)
        self.capturedAt = capturedAt
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
    public var balance: ProviderBalance?

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
        events: [UsageEvent] = [],
        balance: ProviderBalance? = nil
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
        self.balance = balance
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
        case balance
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
            events: try container.decodeIfPresent([UsageEvent].self, forKey: .events) ?? [],
            balance: try container.decodeIfPresent(ProviderBalance.self, forKey: .balance)
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
        try container.encodeIfPresent(balance, forKey: .balance)
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

    public var isWebQuotaComparable: Bool {
        !(provider == .codex && dataSource == .localLog && isExperimental)
    }
}

public struct DeepSeekBalanceSettings: Codable, Equatable, Sendable {
    public var manualFallbackEnabled: Bool
    public var manualBalanceText: String
    public var manualCurrency: String
    public var manualCapturedAt: Date?
    public var lowBalanceThreshold: Decimal

    public init(
        manualFallbackEnabled: Bool = false,
        manualBalanceText: String = "",
        manualCurrency: String = "USD",
        manualCapturedAt: Date? = nil,
        lowBalanceThreshold: Decimal = 5
    ) {
        self.manualFallbackEnabled = manualFallbackEnabled
        self.manualBalanceText = manualBalanceText
        self.manualCurrency = manualCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.manualCapturedAt = manualCapturedAt
        self.lowBalanceThreshold = max(lowBalanceThreshold, 0)
    }
}

public struct XAISettings: Codable, Equatable, Sendable {
    public var teamID: String
    public var managementAPIKeyConfigured: Bool
    public var managementAPILookbackDays: Int
    public var prepaidBalanceAlertsEnabled: Bool
    public var prepaidBalanceAlertThresholdUSD: Decimal

    public init(
        teamID: String = "",
        managementAPIKeyConfigured: Bool = false,
        managementAPILookbackDays: Int = 30,
        prepaidBalanceAlertsEnabled: Bool = false,
        prepaidBalanceAlertThresholdUSD: Decimal = 5
    ) {
        self.teamID = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.managementAPIKeyConfigured = managementAPIKeyConfigured
        self.managementAPILookbackDays = min(max(managementAPILookbackDays, 1), 366)
        self.prepaidBalanceAlertsEnabled = prepaidBalanceAlertsEnabled
        self.prepaidBalanceAlertThresholdUSD = max(prepaidBalanceAlertThresholdUSD, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case teamID
        case managementAPIKeyConfigured
        case managementAPILookbackDays
        case prepaidBalanceAlertsEnabled
        case prepaidBalanceAlertThresholdUSD
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            teamID: try container.decodeIfPresent(String.self, forKey: .teamID) ?? "",
            managementAPIKeyConfigured: try container.decodeIfPresent(Bool.self, forKey: .managementAPIKeyConfigured) ?? false,
            managementAPILookbackDays: try container.decodeIfPresent(Int.self, forKey: .managementAPILookbackDays) ?? 30,
            prepaidBalanceAlertsEnabled: try container.decodeIfPresent(Bool.self, forKey: .prepaidBalanceAlertsEnabled) ?? false,
            prepaidBalanceAlertThresholdUSD: try container.decodeIfPresent(Decimal.self, forKey: .prepaidBalanceAlertThresholdUSD) ?? 5
        )
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

    public var webhookSummary: String {
        guard isEnabled else { return "No webhook" }
        let normalizedStatus = connectionStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedStatus.isEmpty || normalizedStatus == "not configured" {
            return "Not connected"
        }
        if normalizedStatus.contains("connected") || normalizedStatus == "webhook saved securely" {
            return "Configured"
        }
        if normalizedStatus.contains("failed") {
            return "Invalid"
        }
        if normalizedStatus.contains("saved") {
            return "Saved"
        }
        return "Configured"
    }

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
    public var deepseekEnabled: Bool
    public var xaiEnabled: Bool
    public var deepseekAPIKeyConfigured: Bool
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
    public var deepSeekBalance: DeepSeekBalanceSettings
    public var xAI: XAISettings
    public var showMockDataWhenDisconnected: Bool
    public var challengeTargetTokens: Int

    public static let defaultAntigravityStatuslinePath = "~/Library/Application Support/TokenPilot/antigravity-statusline.json"
    public static let legacyGeminiTelemetryPath = "~/.gemini/telemetry.log"

    public init(
        claudeEnabled: Bool = true,
        codexEnabled: Bool = true,
        geminiEnabled: Bool = true,
        deepseekEnabled: Bool = true,
        xaiEnabled: Bool = false,
        deepseekAPIKeyConfigured: Bool = false,
        claudeStatusFilePath: String = "~/Library/Application Support/TokenPilot/claude-statusline.json",
        claudeStatusFileBookmarkData: Data? = nil,
        geminiTelemetryLogPath: String = AppSettings.defaultAntigravityStatuslinePath,
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
        deepSeekBalance: DeepSeekBalanceSettings = DeepSeekBalanceSettings(),
        xAI: XAISettings = XAISettings(),
        showMockDataWhenDisconnected: Bool = false,
        monitoredProviders: MonitoredProviderSettings = MonitoredProviderSettings(),
        menuBarDisplayTarget: Provider? = nil,
        challengeTargetTokens: Int = 10_000
    ) {
        self.claudeEnabled = claudeEnabled
        self.codexEnabled = codexEnabled
        self.geminiEnabled = geminiEnabled
        self.deepseekEnabled = deepseekEnabled
        self.xaiEnabled = xaiEnabled
        self.deepseekAPIKeyConfigured = deepseekAPIKeyConfigured
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
        self.deepSeekBalance = deepSeekBalance
        self.xAI = xAI
        self.showMockDataWhenDisconnected = showMockDataWhenDisconnected
        self.challengeTargetTokens = challengeTargetTokens
    }

    private enum CodingKeys: String, CodingKey {
        case claudeEnabled
        case codexEnabled
        case geminiEnabled
        case deepseekEnabled
        case xaiEnabled
        case deepseekAPIKeyConfigured
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
        case deepSeekBalance
        case xAI
        case showMockDataWhenDisconnected
        case challengeTargetTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            claudeEnabled: try container.decodeIfPresent(Bool.self, forKey: .claudeEnabled) ?? true,
            codexEnabled: try container.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? true,
            geminiEnabled: try container.decodeIfPresent(Bool.self, forKey: .geminiEnabled) ?? true,
            deepseekEnabled: try container.decodeIfPresent(Bool.self, forKey: .deepseekEnabled) ?? true,
            xaiEnabled: try container.decodeIfPresent(Bool.self, forKey: .xaiEnabled) ?? false,
            deepseekAPIKeyConfigured: try container.decodeIfPresent(Bool.self, forKey: .deepseekAPIKeyConfigured) ?? false,
            claudeStatusFilePath: try container.decodeIfPresent(String.self, forKey: .claudeStatusFilePath) ?? "~/Library/Application Support/TokenPilot/claude-statusline.json",
            claudeStatusFileBookmarkData: try container.decodeIfPresent(Data.self, forKey: .claudeStatusFileBookmarkData),
            geminiTelemetryLogPath: try container.decodeIfPresent(String.self, forKey: .geminiTelemetryLogPath) ?? AppSettings.defaultAntigravityStatuslinePath,
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
            deepSeekBalance: try container.decodeIfPresent(DeepSeekBalanceSettings.self, forKey: .deepSeekBalance) ?? DeepSeekBalanceSettings(),
            xAI: try container.decodeIfPresent(XAISettings.self, forKey: .xAI) ?? XAISettings(),
            showMockDataWhenDisconnected: try container.decodeIfPresent(Bool.self, forKey: .showMockDataWhenDisconnected) ?? false,
            monitoredProviders: try container.decodeIfPresent(MonitoredProviderSettings.self, forKey: .monitoredProviders) ?? MonitoredProviderSettings(),
            menuBarDisplayTarget: Self.decodeProviderIfPresent(from: container, forKey: .menuBarDisplayTarget),
            challengeTargetTokens: try container.decodeIfPresent(Int.self, forKey: .challengeTargetTokens) ?? 10_000
        )
    }

    private static func decodeProviderIfPresent(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Provider? {
        guard let rawValue = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return Provider(rawValue: rawValue)
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

// Provider helpers extracted to AppSettings+Providers.swift

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
public enum CapacitySeriesKind: String, Codable, CaseIterable, Sendable {
    case fixedReset
    case rolling
    case calendarCap
    case balance
    case context
}

public enum CapacityUnit: String, Codable, CaseIterable, Sendable {
    case percent
    case currency
    case requestCount
    case tokens
}

public enum CapacityContractError: Error, Equatable, Sendable {
    case invalidSeriesID
    case unsupportedSeries
    case invalidValue
    case invalidReset
    case futureObservation
    case expiredObservation
    case invalidCondition
    case invalidRule
    case invalidDeliveryKey
    case invalidDeliveryState
}

private enum CapacityValidation {
    static func isValidWindowID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...122:
                return true
            case 45, 46, 95:
                return true
            default:
                return false
            }
        }
    }

    static func isValidCurrencyCode(_ value: String) -> Bool {
        guard value.utf8.count == 3 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value)
        }
    }
}

public struct CapacitySeriesID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let provider: Provider
    public let providerWindowID: String
    public let kind: CapacitySeriesKind
    public let unit: CapacityUnit
    public let durationMinutes: Int?

    private enum DurationSemantics: Sendable {
        case none
        case optionalExact(Int)
        case requiredPositive

        func supports(_ durationMinutes: Int?) -> Bool {
            switch self {
            case .none:
                return durationMinutes == nil
            case .optionalExact(let exact):
                return durationMinutes == nil || durationMinutes == exact
            case .requiredPositive:
                guard let durationMinutes else { return false }
                return durationMinutes > 0
            }
        }
    }

    private struct SeriesSemantics: Sendable {
        var providers: Set<Provider>
        var providerWindowID: String
        var kind: CapacitySeriesKind
        var unit: CapacityUnit
        var duration: DurationSemantics
        var resetCapable: Bool

        func matches(provider: Provider, providerWindowID: String, kind: CapacitySeriesKind, unit: CapacityUnit, durationMinutes: Int?) -> Bool {
            providers.contains(provider) &&
                self.providerWindowID == providerWindowID &&
                self.kind == kind &&
                self.unit == unit &&
                duration.supports(durationMinutes)
        }
    }

    private static let supportedSemantics: [SeriesSemantics] = [
        SeriesSemantics(providers: [.claude], providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, duration: .optionalExact(300), resetCapable: true),
        SeriesSemantics(providers: [.claude], providerWindowID: "seven-day", kind: .fixedReset, unit: .percent, duration: .optionalExact(10_080), resetCapable: true),
        SeriesSemantics(providers: [.codex], providerWindowID: "rolling", kind: .rolling, unit: .percent, duration: .requiredPositive, resetCapable: true),
        SeriesSemantics(providers: [.gemini], providerWindowID: "daily-requests", kind: .calendarCap, unit: .requestCount, duration: .optionalExact(1_440), resetCapable: true),
        SeriesSemantics(providers: [.deepseek], providerWindowID: "balance", kind: .balance, unit: .currency, duration: .none, resetCapable: false),
        SeriesSemantics(providers: Set(Provider.allCases), providerWindowID: "context", kind: .context, unit: .tokens, duration: .none, resetCapable: false)
    ]

    public init(provider: Provider, providerWindowID: String, kind: CapacitySeriesKind, unit: CapacityUnit, durationMinutes: Int? = nil) throws {
        guard CapacityValidation.isValidWindowID(providerWindowID),
              durationMinutes == nil || durationMinutes! > 0 else {
            throw CapacityContractError.invalidSeriesID
        }
        guard Self.semantics(provider: provider, providerWindowID: providerWindowID, kind: kind, unit: unit, durationMinutes: durationMinutes) != nil else {
            throw CapacityContractError.unsupportedSeries
        }
        self.provider = provider
        self.providerWindowID = providerWindowID
        self.kind = kind
        self.unit = unit
        self.durationMinutes = durationMinutes
    }

    public var canonicalID: String {
        [provider.rawValue, providerWindowID, kind.rawValue, unit.rawValue, durationMinutes.map(String.init)].compactMap { $0 }.joined(separator: "/")
    }

    public var description: String { canonicalID }

    public var supportsReset: Bool {
        Self.semantics(provider: provider, providerWindowID: providerWindowID, kind: kind, unit: unit, durationMinutes: durationMinutes)?.resetCapable ?? false
    }

    private static func semantics(provider: Provider, providerWindowID: String, kind: CapacitySeriesKind, unit: CapacityUnit, durationMinutes: Int?) -> SeriesSemantics? {
        if provider == .codex,
           ["primary", "secondary", "rolling"].contains(providerWindowID),
           kind == .rolling,
           unit == .percent,
           durationMinutes.map({ $0 > 0 }) == true {
            return SeriesSemantics(providers: [.codex], providerWindowID: providerWindowID, kind: kind, unit: unit, duration: .requiredPositive, resetCapable: true)
        }
        return supportedSemantics.first {
            $0.matches(provider: provider, providerWindowID: providerWindowID, kind: kind, unit: unit, durationMinutes: durationMinutes)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case providerWindowID
        case kind
        case unit
        case durationMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: try container.decode(Provider.self, forKey: .provider),
            providerWindowID: try container.decode(String.self, forKey: .providerWindowID),
            kind: try container.decode(CapacitySeriesKind.self, forKey: .kind),
            unit: try container.decode(CapacityUnit.self, forKey: .unit),
            durationMinutes: try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(providerWindowID, forKey: .providerWindowID)
        try container.encode(kind, forKey: .kind)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
    }
}

public struct CapacityValue: Codable, Equatable, Sendable {
    private enum Storage: Equatable, Sendable {
        case usedPercent(Int)
        case money(Decimal, currency: String)
        case count(Int)
        case tokens(Int)
    }

    private let storage: Storage

    public init(usedPercent: Int) throws {
        guard (0...100).contains(usedPercent) else { throw CapacityContractError.invalidValue }
        self.storage = .usedPercent(usedPercent)
    }

    public init(money: Decimal, currency: String) throws {
        guard money >= 0, CapacityValidation.isValidCurrencyCode(currency) else {
            throw CapacityContractError.invalidValue
        }
        self.storage = .money(money, currency: currency)
    }

    public init(count: Int) throws {
        guard count >= 0 else { throw CapacityContractError.invalidValue }
        self.storage = .count(count)
    }

    public init(tokens: Int) throws {
        guard tokens >= 0 else { throw CapacityContractError.invalidValue }
        self.storage = .tokens(tokens)
    }

    public var kind: CapacityUnit {
        switch storage {
        case .usedPercent: .percent
        case .money: .currency
        case .count: .requestCount
        case .tokens: .tokens
        }
    }

    public var usedPercent: Int? {
        guard case let .usedPercent(value) = storage else { return nil }
        return value
    }

    public var moneyAmount: Decimal? {
        guard case let .money(amount, _) = storage else { return nil }
        return amount
    }

    public var currency: String? {
        guard case let .money(_, currency) = storage else { return nil }
        return currency
    }

    public var count: Int? {
        guard case let .count(value) = storage else { return nil }
        return value
    }

    public var tokens: Int? {
        guard case let .tokens(value) = storage else { return nil }
        return value
    }

    public func validate() throws {
        switch storage {
        case let .usedPercent(value):
            guard (0...100).contains(value) else { throw CapacityContractError.invalidValue }
        case let .money(amount, currency):
            guard amount >= 0, CapacityValidation.isValidCurrencyCode(currency) else { throw CapacityContractError.invalidValue }
        case let .count(value), let .tokens(value):
            guard value >= 0 else { throw CapacityContractError.invalidValue }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case money
        case count
        case tokens
    }

    private enum AssociatedValueKeys: String, CodingKey {
        case value = "_0"
        case currency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw CapacityContractError.invalidValue
        }

        switch key {
        case .usedPercent:
            let value = try Self.decodeAssociatedInt(from: container, forKey: .usedPercent)
            try self.init(usedPercent: value)
        case .money:
            let nested = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .money)
            try self.init(
                money: try nested.decode(Decimal.self, forKey: .value),
                currency: try nested.decode(String.self, forKey: .currency)
            )
        case .count:
            let value = try Self.decodeAssociatedInt(from: container, forKey: .count)
            try self.init(count: value)
        case .tokens:
            let value = try Self.decodeAssociatedInt(from: container, forKey: .tokens)
            try self.init(tokens: value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch storage {
        case let .usedPercent(value):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .usedPercent)
            try nested.encode(value, forKey: .value)
        case let .money(amount, currency):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .money)
            try nested.encode(amount, forKey: .value)
            try nested.encode(currency, forKey: .currency)
        case let .count(value):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .count)
            try nested.encode(value, forKey: .value)
        case let .tokens(value):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .tokens)
            try nested.encode(value, forKey: .value)
        }
    }

    private static func decodeAssociatedInt(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Int {
        if let direct = try? container.decode(Int.self, forKey: key) {
            return direct
        }
        let nested = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: key)
        return try nested.decode(Int.self, forKey: .value)
    }
}

public enum CapacityAuthority: String, Codable, CaseIterable, Sendable {
    case providerReported
    case localDerived
    case userEntered
    case synthetic
    case unavailable
}

public enum CapacityStability: String, Codable, CaseIterable, Sendable {
    case supported
    case compatibilityBridge
    case experimentalTransport
    case manual
    case unavailable
}

public enum CapacityConsent: String, Codable, CaseIterable, Sendable {
    case notRequired
    case granted
    case denied
    case unavailable
}

public enum CapacityComparability: String, Codable, CaseIterable, Sendable {
    case comparable
    case incomparable
    case unavailable
}

public struct CapacityFreshnessPolicy: Codable, Equatable, Sendable {
    public let maximumAge: TimeInterval

    public init(maximumAge: TimeInterval) {
        self.maximumAge = max(0, maximumAge)
    }

    private enum CodingKeys: String, CodingKey {
        case maximumAge
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let maximumAge = try container.decode(TimeInterval.self, forKey: .maximumAge)
        guard maximumAge.isFinite, maximumAge >= 0 else { throw CapacityContractError.invalidValue }
        self.maximumAge = maximumAge
    }

    public func encode(to encoder: Encoder) throws {
        guard maximumAge.isFinite, maximumAge >= 0 else { throw CapacityContractError.invalidValue }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumAge, forKey: .maximumAge)
    }
}

public struct CapacityObservation: Codable, Equatable, Sendable {
    public let seriesID: CapacitySeriesID
    public let observedAt: Date
    public let resetAt: Date?
    public let cycleID: String?
    public let value: CapacityValue
    public let authority: CapacityAuthority
    public let stability: CapacityStability
    public let consent: CapacityConsent
    public let freshnessPolicy: CapacityFreshnessPolicy
    public let comparability: CapacityComparability
    public let parserRevision: String

    public init(seriesID: CapacitySeriesID, observedAt: Date, resetAt: Date? = nil, value: CapacityValue, authority: CapacityAuthority, stability: CapacityStability, consent: CapacityConsent = .notRequired, freshnessPolicy: CapacityFreshnessPolicy, comparability: CapacityComparability, parserRevision: String, now: Date) throws {
        try self.init(seriesID: seriesID, observedAt: observedAt, resetAt: resetAt, cycleID: nil, value: value, authority: authority, stability: stability, consent: consent, freshnessPolicy: freshnessPolicy, comparability: comparability, parserRevision: parserRevision)
        try validateAdmission(now: now)
    }

    private init(seriesID: CapacitySeriesID, observedAt: Date, resetAt: Date?, cycleID decodedCycleID: String?, value: CapacityValue, authority: CapacityAuthority, stability: CapacityStability, consent: CapacityConsent, freshnessPolicy: CapacityFreshnessPolicy, comparability: CapacityComparability, parserRevision: String) throws {
        try value.validate()
        guard value.kind == seriesID.unit else { throw CapacityContractError.invalidValue }
        guard resetAt == nil || seriesID.supportsReset else { throw CapacityContractError.invalidReset }

        let derivedCycleID = Self.cycleID(seriesID: seriesID, resetAt: resetAt)
        if let decodedCycleID {
            guard !decodedCycleID.isEmpty, decodedCycleID == derivedCycleID else { throw CapacityContractError.invalidReset }
        }
        guard !parserRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CapacityContractError.invalidValue
        }

        self.seriesID = seriesID
        self.observedAt = observedAt
        self.resetAt = resetAt
        self.cycleID = derivedCycleID
        self.value = value
        self.authority = authority
        self.stability = stability
        self.consent = consent
        self.freshnessPolicy = freshnessPolicy
        self.comparability = comparability
        self.parserRevision = parserRevision
    }

    public func validateAdmission(now: Date) throws {
        guard observedAt <= now.addingTimeInterval(60) else { throw CapacityContractError.futureObservation }
        guard observedAt >= now.addingTimeInterval(-45 * 24 * 60 * 60) else { throw CapacityContractError.expiredObservation }
    }

    private static func cycleID(seriesID: CapacitySeriesID, resetAt: Date?) -> String? {
        resetAt.map { "\(seriesID.canonicalID)/\(Int($0.timeIntervalSince1970))" }
    }

    private enum CodingKeys: String, CodingKey {
        case seriesID
        case observedAt
        case resetAt
        case cycleID
        case value
        case authority
        case stability
        case consent
        case freshnessPolicy
        case comparability
        case parserRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            seriesID: try container.decode(CapacitySeriesID.self, forKey: .seriesID),
            observedAt: try container.decode(Date.self, forKey: .observedAt),
            resetAt: try container.decodeIfPresent(Date.self, forKey: .resetAt),
            cycleID: try container.decodeIfPresent(String.self, forKey: .cycleID),
            value: try container.decode(CapacityValue.self, forKey: .value),
            authority: try container.decode(CapacityAuthority.self, forKey: .authority),
            stability: try container.decode(CapacityStability.self, forKey: .stability),
            consent: try container.decodeIfPresent(CapacityConsent.self, forKey: .consent) ?? .notRequired,
            freshnessPolicy: try container.decode(CapacityFreshnessPolicy.self, forKey: .freshnessPolicy),
            comparability: try container.decode(CapacityComparability.self, forKey: .comparability),
            parserRevision: try container.decode(String.self, forKey: .parserRevision)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try value.validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seriesID, forKey: .seriesID)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encodeIfPresent(cycleID, forKey: .cycleID)
        try container.encode(value, forKey: .value)
        try container.encode(authority, forKey: .authority)
        try container.encode(stability, forKey: .stability)
        try container.encode(consent, forKey: .consent)
        try container.encode(freshnessPolicy, forKey: .freshnessPolicy)
        try container.encode(comparability, forKey: .comparability)
        try container.encode(parserRevision, forKey: .parserRevision)
    }
}

public enum CapacityFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

public enum CapacityEligibilityReason: String, Codable, Equatable, Sendable {
    case eligible
    case unsupportedSource
    case manualSource
    case staleEvidence
    case activityOnly
    case invalidEvidence
    case pendingBalanceBinding
}

public enum CapacityRisk: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
    case informational
    case stale
    case unavailable
}

public enum CapacityAlertEligibility: String, Codable, Equatable, Sendable {
    case percent
    case balance
    case ineligible
}

public enum CapacityForecastAvailability: String, Codable, Equatable, Sendable {
    case unavailableUnsupportedSource
    case unavailableEvidence
    case unavailableSource
    case unavailableUnit
    case cohortOnly
}

public enum CapacityActionKey: String, Codable, Equatable, Sendable {
    case waitForReset
    case refreshProvider
    case reviewSource
    case reviewExperimentalConnector
    case enterManualValue
    case reviewBalance
    case openProviderDiagnostics
}

public struct CapacityAssessment: Codable, Equatable, Sendable {
    public let observation: CapacityObservation
    public let freshness: CapacityFreshness
    public let eligibilityReason: CapacityEligibilityReason
    public let risk: CapacityRisk
    public let alertEligibility: CapacityAlertEligibility
    public let forecast: CapacityForecastAvailability
    public let actionKey: CapacityActionKey
    public let transitionKey: String
    public init(observation: CapacityObservation, freshness: CapacityFreshness, eligibilityReason: CapacityEligibilityReason, risk: CapacityRisk, alertEligibility: CapacityAlertEligibility, forecast: CapacityForecastAvailability, actionKey: CapacityActionKey, transitionKey: String) {
        self.observation = observation
        self.freshness = freshness
        self.eligibilityReason = eligibilityReason
        self.risk = risk
        self.alertEligibility = alertEligibility
        self.forecast = forecast
        self.actionKey = actionKey
        self.transitionKey = transitionKey
    }
}

public struct CapacityRuntimeControl: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let assessmentEnabled: Bool
    public init(schemaVersion: Int = 1, assessmentEnabled: Bool = true) {
        self.schemaVersion = schemaVersion
        self.assessmentEnabled = assessmentEnabled
    }
}

public enum CapacityAlertPercentThreshold: String, Codable, CaseIterable, Sendable {
    case reset
    case fifty
    case eighty
    case hundred
}

public enum CapacityAlertConditionKind: String, Codable, CaseIterable, Sendable {
    case percentThresholds
    case balanceBelow
    case pendingBalanceCurrencyBinding
}

public struct CapacityAlertCondition: Codable, Equatable, Sendable {
    private enum Storage: Equatable, Sendable {
        case percentThresholds(reset: Bool, fifty: Bool, eighty: Bool, hundred: Bool)
        case balanceBelow(threshold: Decimal, currency: String, rearmAtOrAboveThreshold: Bool)
        case pendingBalanceCurrencyBinding
    }

    private let storage: Storage

    public var kind: CapacityAlertConditionKind {
        switch storage {
        case .percentThresholds: .percentThresholds
        case .balanceBelow: .balanceBelow
        case .pendingBalanceCurrencyBinding: .pendingBalanceCurrencyBinding
        }
    }

    public var enabledPercentThresholds: Set<CapacityAlertPercentThreshold> {
        guard case let .percentThresholds(reset, fifty, eighty, hundred) = storage else { return [] }
        var thresholds: Set<CapacityAlertPercentThreshold> = []
        if reset { thresholds.insert(.reset) }
        if fifty { thresholds.insert(.fifty) }
        if eighty { thresholds.insert(.eighty) }
        if hundred { thresholds.insert(.hundred) }
        return thresholds
    }

    public var balanceThreshold: Decimal? {
        guard case let .balanceBelow(threshold, _, _) = storage else { return nil }
        return threshold
    }

    public var balanceCurrency: String? {
        guard case let .balanceBelow(_, currency, _) = storage else { return nil }
        return currency
    }

    public var rearmAtOrAboveThreshold: Bool? {
        guard case let .balanceBelow(_, _, rearmAtOrAboveThreshold) = storage else { return nil }
        return rearmAtOrAboveThreshold
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    public static func percentThresholds(reset: Bool, fifty: Bool, eighty: Bool, hundred: Bool) -> CapacityAlertCondition {
        CapacityAlertCondition(storage: .percentThresholds(reset: reset, fifty: fifty, eighty: eighty, hundred: hundred))
    }

    public static func balanceBelow(threshold: Decimal, currency: String, rearmAtOrAboveThreshold: Bool) throws -> CapacityAlertCondition {
        guard threshold >= 0, CapacityValidation.isValidCurrencyCode(currency) else {
            throw CapacityContractError.invalidCondition
        }
        return CapacityAlertCondition(storage: .balanceBelow(threshold: threshold, currency: currency, rearmAtOrAboveThreshold: rearmAtOrAboveThreshold))
    }

    public static var pendingBalanceCurrencyBinding: CapacityAlertCondition {
        CapacityAlertCondition(storage: .pendingBalanceCurrencyBinding)
    }

    private static func decodeCanonicalDecimal(from container: KeyedDecodingContainer<AssociatedValueKeys>, forKey key: AssociatedValueKeys) throws -> Decimal {
        if let string = try? container.decode(String.self, forKey: key),
           let decimal = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) {
            return decimal
        }
        return try container.decode(Decimal.self, forKey: key)
    }

    private enum CodingKeys: String, CodingKey {
        case percentThresholds
        case balanceBelow
        case pendingBalanceCurrencyBinding
    }

    private enum AssociatedValueKeys: String, CodingKey {
        case reset
        case fifty
        case eighty
        case hundred
        case threshold
        case currency
        case rearmAtOrAboveThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw CapacityContractError.invalidCondition
        }

        switch key {
        case .percentThresholds:
            let nested = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .percentThresholds)
            self = .percentThresholds(
                reset: try nested.decodeIfPresent(Bool.self, forKey: .reset) ?? false,
                fifty: try nested.decodeIfPresent(Bool.self, forKey: .fifty) ?? false,
                eighty: try nested.decodeIfPresent(Bool.self, forKey: .eighty) ?? false,
                hundred: try nested.decodeIfPresent(Bool.self, forKey: .hundred) ?? false
            )
        case .balanceBelow:
            let nested = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .balanceBelow)
            self = try .balanceBelow(
                threshold: try Self.decodeCanonicalDecimal(from: nested, forKey: .threshold),
                currency: try nested.decode(String.self, forKey: .currency),
                rearmAtOrAboveThreshold: try nested.decodeIfPresent(Bool.self, forKey: .rearmAtOrAboveThreshold) ?? true
            )
        case .pendingBalanceCurrencyBinding:
            let nested = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .pendingBalanceCurrencyBinding)
            guard nested.allKeys.isEmpty else { throw CapacityContractError.invalidCondition }
            self = .pendingBalanceCurrencyBinding
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch storage {
        case let .percentThresholds(reset, fifty, eighty, hundred):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .percentThresholds)
            try nested.encode(reset, forKey: .reset)
            try nested.encode(fifty, forKey: .fifty)
            try nested.encode(eighty, forKey: .eighty)
            try nested.encode(hundred, forKey: .hundred)
        case let .balanceBelow(threshold, currency, rearmAtOrAboveThreshold):
            guard threshold >= 0, CapacityValidation.isValidCurrencyCode(currency) else {
                throw CapacityContractError.invalidCondition
            }
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .balanceBelow)
            try nested.encode(CapacityCanonical.thresholdCanonical(threshold), forKey: .threshold)
            try nested.encode(currency, forKey: .currency)
            try nested.encode(rearmAtOrAboveThreshold, forKey: .rearmAtOrAboveThreshold)
        case .pendingBalanceCurrencyBinding:
            _ = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .pendingBalanceCurrencyBinding)
        }
    }
}

public struct CapacityAlertRouting: Codable, Equatable, Sendable {
    public var macOS: Bool
    public var telegram: Bool
    public var discord: Bool
    public init(macOS: Bool = true, telegram: Bool = false, discord: Bool = false) {
        self.macOS = macOS; self.telegram = telegram; self.discord = discord
    }
}

public enum CapacityAlertChannel: String, Codable, CaseIterable, Sendable { case macOS, telegram, discord }
public enum CapacityAlertDeliveryStatus: String, Codable, Equatable, Sendable { case idle, pending, delivered, failed }

public struct CapacityAlertDeliveryKey: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let ruleID: String
    public let conditionRevision: Int
    public let channel: CapacityAlertChannel

    public var description: String {
        "\(ruleID)/revision-\(conditionRevision)/\(channel.rawValue)"
    }

    public init(ruleID: String, conditionRevision: Int, channel: CapacityAlertChannel) throws {
        guard ruleID == ruleID.trimmingCharacters(in: .whitespacesAndNewlines),
              !ruleID.isEmpty,
              conditionRevision > 0 else {
            throw CapacityContractError.invalidDeliveryKey
        }
        self.ruleID = ruleID
        self.conditionRevision = conditionRevision
        self.channel = channel
    }

    private enum CodingKeys: String, CodingKey {
        case ruleID
        case conditionRevision
        case channel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ruleID: try container.decode(String.self, forKey: .ruleID),
            conditionRevision: try container.decode(Int.self, forKey: .conditionRevision),
            channel: try container.decode(CapacityAlertChannel.self, forKey: .channel)
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard conditionRevision > 0, !ruleID.isEmpty else { throw CapacityContractError.invalidDeliveryKey }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ruleID, forKey: .ruleID)
        try container.encode(conditionRevision, forKey: .conditionRevision)
        try container.encode(channel, forKey: .channel)
    }
}

public enum CapacityAlertConditionState: Codable, Equatable, Sendable {
    case percent(activeCycleID: String?, lastUsed: Int?, deliveredThresholds: Set<CapacityAlertPercentThreshold>)
    case balance(lastKnownBelow: Bool?, crossingGeneration: Int, deliveredCrossingGeneration: Int?)

    public var kind: CapacityAlertConditionKind {
        switch self {
        case .percent: .percentThresholds
        case .balance: .balanceBelow
        }
    }

    fileprivate func validate() throws {
        switch self {
        case let .percent(activeCycleID, lastUsed, _):
            guard activeCycleID?.isEmpty != true else { throw CapacityContractError.invalidDeliveryState }
            if let lastUsed {
                guard (0...100).contains(lastUsed) else { throw CapacityContractError.invalidDeliveryState }
            }
        case let .balance(_, crossingGeneration, deliveredCrossingGeneration):
            guard crossingGeneration >= 0 else { throw CapacityContractError.invalidDeliveryState }
            if let deliveredCrossingGeneration {
                guard deliveredCrossingGeneration >= 0,
                      deliveredCrossingGeneration <= crossingGeneration else {
                    throw CapacityContractError.invalidDeliveryState
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case percent
        case balance
    }

    private enum AssociatedValueKeys: String, CodingKey {
        case activeCycleID
        case lastUsed
        case deliveredThresholds
        case lastKnownBelow
        case crossingGeneration
        case deliveredCrossingGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw CapacityContractError.invalidDeliveryState
        }

        switch key {
        case .percent:
            let nested = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .percent)
            self = .percent(
                activeCycleID: try nested.decodeIfPresent(String.self, forKey: .activeCycleID),
                lastUsed: try nested.decodeIfPresent(Int.self, forKey: .lastUsed),
                deliveredThresholds: try nested.decodeIfPresent(Set<CapacityAlertPercentThreshold>.self, forKey: .deliveredThresholds) ?? []
            )
        case .balance:
            let nested = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .balance)
            self = .balance(
                lastKnownBelow: try nested.decodeIfPresent(Bool.self, forKey: .lastKnownBelow),
                crossingGeneration: try nested.decode(Int.self, forKey: .crossingGeneration),
                deliveredCrossingGeneration: try nested.decodeIfPresent(Int.self, forKey: .deliveredCrossingGeneration)
            )
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .percent(activeCycleID, lastUsed, deliveredThresholds):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .percent)
            try nested.encodeIfPresent(activeCycleID, forKey: .activeCycleID)
            try nested.encodeIfPresent(lastUsed, forKey: .lastUsed)
            try nested.encode(deliveredThresholds.sorted { $0.rawValue < $1.rawValue }, forKey: .deliveredThresholds)
        case let .balance(lastKnownBelow, crossingGeneration, deliveredCrossingGeneration):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .balance)
            try nested.encodeIfPresent(lastKnownBelow, forKey: .lastKnownBelow)
            try nested.encode(crossingGeneration, forKey: .crossingGeneration)
            try nested.encodeIfPresent(deliveredCrossingGeneration, forKey: .deliveredCrossingGeneration)
        }
    }
}

public struct CapacityAlertDeliveryState: Codable, Equatable, Sendable {
    public var key: CapacityAlertDeliveryKey
    public var status: CapacityAlertDeliveryStatus
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var conditionState: CapacityAlertConditionState

    public init(key: CapacityAlertDeliveryKey, status: CapacityAlertDeliveryStatus = .idle, lastAttemptAt: Date? = nil, lastSuccessAt: Date? = nil, conditionState: CapacityAlertConditionState) throws {
        try conditionState.validate()
        self.key = key
        self.status = status
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.conditionState = conditionState
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case status
        case lastAttemptAt
        case lastSuccessAt
        case conditionState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: try container.decode(CapacityAlertDeliveryKey.self, forKey: .key),
            status: try container.decodeIfPresent(CapacityAlertDeliveryStatus.self, forKey: .status) ?? .idle,
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            lastSuccessAt: try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt),
            conditionState: try container.decode(CapacityAlertConditionState.self, forKey: .conditionState)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try conditionState.validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lastAttemptAt, forKey: .lastAttemptAt)
        try container.encodeIfPresent(lastSuccessAt, forKey: .lastSuccessAt)
        try container.encode(conditionState, forKey: .conditionState)
    }
}

public struct CapacityAlertRule: Codable, Equatable, Sendable, Identifiable {
    public let provider: Provider
    public let seriesID: CapacitySeriesID
    public let authority: CapacityAuthority
    public let stability: CapacityStability
    public var enabled: Bool
    public var routing: CapacityAlertRouting
    public var conditionRevision: Int
    public var condition: CapacityAlertCondition
    public var id: String { [provider.rawValue, seriesID.canonicalID, condition.kind.rawValue, authority.rawValue, stability.rawValue].joined(separator: "/") }

    public init(provider: Provider, seriesID: CapacitySeriesID, authority: CapacityAuthority, stability: CapacityStability, enabled: Bool, routing: CapacityAlertRouting, conditionRevision: Int = 1, condition: CapacityAlertCondition) throws {
        guard conditionRevision > 0 else { throw CapacityContractError.invalidRule }
        try Self.validate(provider: provider, seriesID: seriesID, authority: authority, stability: stability, condition: condition)

        self.provider = provider
        self.seriesID = seriesID
        self.authority = authority
        self.stability = stability
        self.enabled = condition.kind == .pendingBalanceCurrencyBinding ? false : enabled
        self.routing = routing
        self.conditionRevision = conditionRevision
        self.condition = condition
    }

    public var isPendingBalanceBinding: Bool {
        condition.kind == .pendingBalanceCurrencyBinding
    }

    private static func validate(provider: Provider, seriesID: CapacitySeriesID, authority: CapacityAuthority, stability: CapacityStability, condition: CapacityAlertCondition) throws {
        guard provider == seriesID.provider else { throw CapacityContractError.invalidRule }
        guard authority == .providerReported, stability == .supported else { throw CapacityContractError.invalidRule }

        switch condition.kind {
        case .percentThresholds:
            guard seriesID.unit == .percent else { throw CapacityContractError.invalidRule }
            if condition.enabledPercentThresholds.contains(.reset) {
                guard seriesID.supportsReset else { throw CapacityContractError.invalidRule }
            }
        case .balanceBelow, .pendingBalanceCurrencyBinding:
            guard seriesID.kind == .balance, seriesID.unit == .currency else { throw CapacityContractError.invalidRule }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case seriesID
        case authority
        case stability
        case enabled
        case routing
        case conditionRevision
        case condition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: try container.decode(Provider.self, forKey: .provider),
            seriesID: try container.decode(CapacitySeriesID.self, forKey: .seriesID),
            authority: try container.decode(CapacityAuthority.self, forKey: .authority),
            stability: try container.decode(CapacityStability.self, forKey: .stability),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            routing: try container.decodeIfPresent(CapacityAlertRouting.self, forKey: .routing) ?? CapacityAlertRouting(),
            conditionRevision: try container.decode(Int.self, forKey: .conditionRevision),
            condition: try container.decode(CapacityAlertCondition.self, forKey: .condition)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validate(provider: provider, seriesID: seriesID, authority: authority, stability: stability, condition: condition)
        guard conditionRevision > 0 else { throw CapacityContractError.invalidRule }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(seriesID, forKey: .seriesID)
        try container.encode(authority, forKey: .authority)
        try container.encode(stability, forKey: .stability)
        try container.encode(condition.kind == .pendingBalanceCurrencyBinding ? false : enabled, forKey: .enabled)
        try container.encode(routing, forKey: .routing)
        try container.encode(conditionRevision, forKey: .conditionRevision)
        try container.encode(condition, forKey: .condition)
    }
}

public extension CapacityAlertDeliveryKey {
    init(rule: CapacityAlertRule, channel: CapacityAlertChannel) {
        self.ruleID = rule.id
        self.conditionRevision = rule.conditionRevision
        self.channel = channel
    }
}
