import Foundation
import os
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(Security)
import Security
#endif

public protocol ProviderAdapter: Sendable {
    var provider: Provider { get }
    func snapshot(settings: AppSettings) async -> ProviderSnapshot
}
public enum CapacityRefreshErrorCategory: String, Codable, Equatable, Sendable {
    case disabled
    case sourceUnavailable
    case authenticationRequired
    case processFailure
    case timeout
    case cancelled
    case malformedResponse
    case unsupportedSeries
    case outputLimitExceeded
}

public struct CapacityRefreshError: Codable, Equatable, Identifiable, Sendable {
    public var id: String { [provider.rawValue, category.rawValue, code].joined(separator: ":") }
    public let provider: Provider
    public let category: CapacityRefreshErrorCategory
    public let code: String
    public let redactedMessage: String

    public init(provider: Provider, category: CapacityRefreshErrorCategory, code: String, redactedMessage: String) {
        self.provider = provider
        self.category = category
        self.code = code
        self.redactedMessage = redactedMessage
    }
}

public struct ProviderRefreshResult: Sendable {
    public var snapshot: ProviderSnapshot
    public var capacityObservations: [CapacityObservation]
    public var typedErrors: [CapacityRefreshError]
    public var observedAt: Date

    public init(
        snapshot: ProviderSnapshot,
        capacityObservations: [CapacityObservation] = [],
        typedErrors: [CapacityRefreshError] = [],
        observedAt: Date
    ) {
        self.snapshot = snapshot
        self.capacityObservations = capacityObservations
        self.typedErrors = typedErrors
        self.observedAt = observedAt
    }
}
public enum TokenPilotPrivacyRedactor {
    private static let replacements: [(pattern: String, template: String)] = [
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "[REDACTED]"),
        (#"(?i)\b(?:authorization|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|password)\s*[:=]\s*["']?[^"',;\s]+"#, "[REDACTED]"),
        (#"(?i)\b(?:prompt|response|completion|messages?|content)\s*[:=]\s*["']?[^"\n\r;]+"#, "[REDACTED]"),
        (#"\b[A-Za-z0-9_-]{32,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"#, "[REDACTED]"),
        (#"(?i)\b(?:sk|pk|api|key|token)[-_][A-Za-z0-9]{16,}\b"#, "[REDACTED]"),
        (#"\b[A-Za-z0-9_~+/=-]{48,}\b"#, "[REDACTED]"),
        (#"(?i)(?:~|/(?:Users|home|private/var|private/tmp|var/folders|tmp|Volumes|opt/homebrew|usr/local|etc))/[^\s"',;)]+["']?"#, "[REDACTED_PATH]"),
        (#"(?i)(?:^|[\s/])(?:auth\.json|credentials(?:\.json)?|\.env(?:\.[A-Za-z0-9_-]+)?|id_rsa|id_ed25519|token(?:s)?\.json|key(?:s)?\.json)(?=$|[\s"',;:)])"#, "[REDACTED_FILE]")
    ]

    public static func redact(_ text: String) -> String {
        replacements.reduce(text) { current, replacement in
            guard let regex = try? NSRegularExpression(pattern: replacement.pattern, options: []) else { return current }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(in: current, options: [], range: range, withTemplate: replacement.template)
        }
    }

    public static func redactExportField(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let redacted = redact(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? nil : redacted
    }
}

public protocol ProviderRefreshAdapter: Sendable {
    var provider: Provider { get }
    func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult
}
public extension ProviderRefreshAdapter where Self: ProviderAdapter {
    func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        let snapshot = await snapshot(settings: settings)
        let observedAt = snapshot.updatedAt
        return ProviderRefreshResult(
            snapshot: snapshot,
            capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: observedAt),
            typedErrors: CapacityObservationFactory.errors(from: snapshot, provider: provider),
            observedAt: observedAt
        )
    }
}

public struct LegacyProviderRefreshAdapter: ProviderRefreshAdapter {
    private let adapter: any ProviderAdapter

    public var provider: Provider { adapter.provider }

    public init(_ adapter: any ProviderAdapter) {
        self.adapter = adapter
    }

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        let snapshot = await adapter.snapshot(settings: settings)
        let observedAt = snapshot.updatedAt
        return ProviderRefreshResult(
            snapshot: snapshot,
            capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: observedAt),
            typedErrors: CapacityObservationFactory.errors(from: snapshot, provider: provider),
            observedAt: observedAt
        )
    }
}

public enum CapacityObservationFactory {
    public static func observations(from snapshot: ProviderSnapshot, settings: AppSettings, observedAt: Date) -> [CapacityObservation] {
        guard snapshot.dataSource != .mock else { return [] }
        var observations: [CapacityObservation] = []

        func appendPercent(
            provider: Provider,
            providerWindowID: String,
            kind: CapacitySeriesKind,
            durationMinutes: Int?,
            window: LimitWindow?,
            authority: CapacityAuthority,
            stability: CapacityStability,
            consent: CapacityConsent,
            maximumAge: TimeInterval,
            comparability: CapacityComparability,
            parserRevision: String
        ) {
            guard let window,
                  let used = window.usedPercent,
                  let series = try? CapacitySeriesID(provider: provider, providerWindowID: providerWindowID, kind: kind, unit: .percent, durationMinutes: durationMinutes),
                  let value = try? CapacityValue(usedPercent: used),
                  let observation = try? CapacityObservation(
                    seriesID: series,
                    observedAt: observedAt,
                    resetAt: window.resetAt,
                    value: value,
                    authority: authority,
                    stability: stability,
                    consent: consent,
                    freshnessPolicy: CapacityFreshnessPolicy(maximumAge: maximumAge),
                    comparability: comparability,
                    parserRevision: parserRevision,
                    now: observedAt
                  ) else {
                return
            }
            observations.append(observation)
        }

        func codexProviderWindowID(_ window: LimitWindow?, defaultID: String) -> String {
            window?.providerWindowID ?? defaultID
        }

        func codexDurationMinutes(_ window: LimitWindow?, defaultMinutes: Int) -> Int {
            window?.durationMinutes ?? defaultMinutes
        }

        switch snapshot.provider {
        case .claude:
            if snapshot.dataSource == .officialStatusline {
                appendPercent(
                    provider: .claude,
                    providerWindowID: "five-hour",
                    kind: .fixedReset,
                    durationMinutes: nil,
                    window: snapshot.fiveHour,
                    authority: .providerReported,
                    stability: .supported,
                    consent: .notRequired,
                    maximumAge: 15 * 60,
                    comparability: .comparable,
                    parserRevision: "claudeStatuslineV1"
                )
                appendPercent(
                    provider: .claude,
                    providerWindowID: "seven-day",
                    kind: .fixedReset,
                    durationMinutes: nil,
                    window: snapshot.weekly,
                    authority: .providerReported,
                    stability: .supported,
                    consent: .notRequired,
                    maximumAge: 15 * 60,
                    comparability: .comparable,
                    parserRevision: "claudeStatuslineV1"
                )
            }
        case .codex:
            if snapshot.dataSource == .webUsage, settings.codexManual.webConnectorEnabled {
                appendPercent(
                    provider: .codex,
                    providerWindowID: "primary",
                    kind: .rolling,
                    durationMinutes: codexDurationMinutes(snapshot.fiveHour, defaultMinutes: 300),
                    window: snapshot.fiveHour,
                    authority: .providerReported,
                    stability: .experimentalTransport,
                    consent: .granted,
                    maximumAge: 15 * 60,
                    comparability: .comparable,
                    parserRevision: "codexAppServerV1"
                )
                appendPercent(
                    provider: .codex,
                    providerWindowID: "secondary",
                    kind: .rolling,
                    durationMinutes: codexDurationMinutes(snapshot.weekly, defaultMinutes: 10_080),
                    window: snapshot.weekly,
                    authority: .providerReported,
                    stability: .experimentalTransport,
                    consent: .granted,
                    maximumAge: 15 * 60,
                    comparability: .comparable,
                    parserRevision: "codexAppServerV1"
                )
            } else if snapshot.dataSource == .manual || snapshot.dataSource == .estimated {
                appendPercent(
                    provider: .codex,
                    providerWindowID: "primary",
                    kind: .rolling,
                    durationMinutes: codexDurationMinutes(snapshot.fiveHour, defaultMinutes: 300),
                    window: snapshot.fiveHour,
                    authority: .userEntered,
                    stability: .manual,
                    consent: .granted,
                    maximumAge: 24 * 60 * 60,
                    comparability: .incomparable,
                    parserRevision: "codexManualV1"
                )
                appendPercent(
                    provider: .codex,
                    providerWindowID: "secondary",
                    kind: .rolling,
                    durationMinutes: codexDurationMinutes(snapshot.weekly, defaultMinutes: 10_080),
                    window: snapshot.weekly,
                    authority: .userEntered,
                    stability: .manual,
                    consent: .granted,
                    maximumAge: 24 * 60 * 60,
                    comparability: .incomparable,
                    parserRevision: "codexManualV1"
                )
            }
        case .gemini:
            if snapshot.dataSource == .officialStatusline,
               let used = snapshot.dailyRequestsUsed,
               let series = try? CapacitySeriesID(provider: .gemini, providerWindowID: "daily-requests", kind: .calendarCap, unit: .requestCount, durationMinutes: 1_440),
               let value = try? CapacityValue(count: used),
               let observation = try? CapacityObservation(
                seriesID: series,
                observedAt: observedAt,
                resetAt: nil,
                value: value,
                authority: .providerReported,
                stability: .compatibilityBridge,
                consent: .notRequired,
                freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 15 * 60),
                comparability: .incomparable,
                parserRevision: "antigravityStatuslineV1",
                now: observedAt
               ) {
                observations.append(observation)
            }
        case .deepseek:
            guard let balance = snapshot.balance else { break }
            let authority: CapacityAuthority = snapshot.dataSource == .officialTelemetry ? .providerReported : .userEntered
            let stability: CapacityStability = snapshot.dataSource == .officialTelemetry ? .supported : .manual
            let comparability: CapacityComparability = snapshot.dataSource == .officialTelemetry ? .comparable : .incomparable
            if let series = try? CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency),
               let value = try? CapacityValue(money: balance.toppedUpBalance, currency: balance.currency),
               let observation = try? CapacityObservation(
                seriesID: series,
                observedAt: observedAt,
                value: value,
                authority: authority,
                stability: stability,
                consent: snapshot.dataSource == .officialTelemetry ? .granted : .notRequired,
                freshnessPolicy: CapacityFreshnessPolicy(maximumAge: snapshot.dataSource == .officialTelemetry ? 60 * 60 : 24 * 60 * 60),
                comparability: comparability,
                parserRevision: snapshot.dataSource == .officialTelemetry ? "deepseekBalanceV1" : "deepseekManualBalanceV1",
                now: observedAt
               ) {
                observations.append(observation)
            }
        }

        return observations
    }

    public static func errors(from snapshot: ProviderSnapshot, provider: Provider) -> [CapacityRefreshError] {
        guard snapshot.confidence == .low,
              snapshot.events.isEmpty,
              snapshot.primaryUsedPercent == nil,
              snapshot.dailyRequestsUsed == nil,
              snapshot.balance == nil else {
            return []
        }
        let message = snapshot.statusMessage ?? "Provider capacity unavailable"
        return [
            CapacityRefreshError(
                provider: provider,
                category: .sourceUnavailable,
                code: "capacityUnavailable",
                redactedMessage: redacted(message)
            )
        ]
    }

    public static func redacted(_ message: String) -> String {
        TokenPilotPrivacyRedactor.redact(message)
    }
}


public enum TokenPilotRefreshPolicy {
    public static func usageRefreshNeeded(from previous: AppSettings, to next: AppSettings) -> Bool {
        previous.enabledProviders != next.enabledProviders ||
        previous.claudeStatusFilePath != next.claudeStatusFilePath ||
        previous.claudeStatusFileBookmarkData != next.claudeStatusFileBookmarkData ||
        previous.geminiTelemetryLogPath != next.geminiTelemetryLogPath ||
        previous.geminiTelemetrySourceBookmarkData != next.geminiTelemetrySourceBookmarkData ||
        previous.geminiDailyRequestCap != next.geminiDailyRequestCap ||
        previous.codexManual != next.codexManual ||
        previous.deepseekAPIKeyConfigured != next.deepseekAPIKeyConfigured ||
        previous.deepSeekBalance != next.deepSeekBalance ||
        previous.showMockDataWhenDisconnected != next.showMockDataWhenDisconnected
    }
}

public final class TokenPilotSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = OSAllocatedUnfairLock()

    public init(defaults: UserDefaults = .standard, key: String = "tokenPilot.appSettings.v1") {
        self.defaults = defaults
        self.key = key
        encoder.outputFormatting = [.sortedKeys]
    }

    public func load() -> AppSettings {
        lock.withLock {
            guard let data = defaults.data(forKey: key), let decoded = try? decoder.decode(AppSettings.self, from: data) else {
                return AppSettings()
            }
            return normalize(decoded)
        }
    }

    public func save(_ settings: AppSettings) {
        lock.withLock {
            guard let data = try? encoder.encode(normalize(settings)) else { return }
            defaults.set(data, forKey: key)
        }
    }

    private func normalize(_ settings: AppSettings) -> AppSettings {
        var copy = settings
        let existingIDs = Set(copy.alertRules.map(\.id))
        for rule in AppSettings.defaultAlertRules where !existingIDs.contains(rule.id) {
            copy.alertRules.append(rule)
        }
        copy.geminiDailyRequestCap = max(copy.geminiDailyRequestCap, 1)
        copy.codexManual.fiveHourUsagePercentage = min(max(copy.codexManual.fiveHourUsagePercentage, 0), 100)
        copy.codexManual.weeklyUsagePercentage = min(max(copy.codexManual.weeklyUsagePercentage, 0), 100)
        copy.codexManual.webTodayTokens = max(copy.codexManual.webTodayTokens, 0)
        if !copy.codexManual.pastedStatusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.codexManual = CodexStatusParser.safeParse(copy.codexManual.pastedStatusOutput, previous: copy.codexManual)
            copy.codexManual.pastedStatusOutput = ""
        }
        copy.normalizeProviderEnablement()
        return copy
    }
}


public final class MockDataService: Sendable {
    public init() {}

    public func snapshots(referenceDate: Date = Date()) -> [ProviderSnapshot] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: referenceDate)

        func timestamp(dayOffset: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) ?? startOfToday
            return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
        }

        func event(
            provider: Provider,
            model: String,
            dayOffset: Int,
            hour: Int,
            input: Int,
            output: Int,
            cacheRead: Int = 0,
            cacheCreation: Int = 0,
            reasoning: Int = 0,
            requests: Int = 1
        ) -> UsageEvent {
            UsageEvent(
                provider: provider,
                model: model,
                timestamp: timestamp(dayOffset: dayOffset, hour: hour),
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation,
                reasoningTokens: reasoning,
                requestCount: requests,
                source: "mock",
                dataSource: .mock,
                isEstimated: true
            )
        }

        let claudeEvents = [
            event(provider: .claude, model: "Sample Sonnet", dayOffset: 0, hour: 10, input: 6_200, output: 3_100, cacheRead: 1_900, cacheCreation: 600),
            event(provider: .claude, model: "Sample Sonnet", dayOffset: -2, hour: 15, input: 4_300, output: 2_000, cacheRead: 1_200),
            event(provider: .claude, model: "Sample Sonnet", dayOffset: -8, hour: 11, input: 2_400, output: 1_100, cacheRead: 700),
            event(provider: .claude, model: "Sample Sonnet", dayOffset: -18, hour: 17, input: 3_100, output: 1_350, cacheCreation: 450)
        ]
        let codexEvents = [
            event(provider: .codex, model: "Sample Codex", dayOffset: 0, hour: 9, input: 3_300, output: 1_450, requests: 4),
            event(provider: .codex, model: "Sample Codex", dayOffset: -1, hour: 18, input: 2_200, output: 900, requests: 3),
            event(provider: .codex, model: "Sample Codex", dayOffset: -10, hour: 14, input: 1_700, output: 640, requests: 2),
            event(provider: .codex, model: "Sample Codex", dayOffset: -21, hour: 16, input: 2_900, output: 1_120, requests: 3)
        ]
        let geminiEvents = [
            event(provider: .gemini, model: "Sample Gemini", dayOffset: 0, hour: 13, input: 7_800, output: 2_700, cacheRead: 1_100, reasoning: 900, requests: 12),
            event(provider: .gemini, model: "Sample Gemini", dayOffset: -3, hour: 12, input: 4_600, output: 1_900, cacheRead: 800, reasoning: 400, requests: 8),
            event(provider: .gemini, model: "Sample Gemini", dayOffset: -6, hour: 20, input: 3_200, output: 1_200, cacheRead: 300, reasoning: 250, requests: 5),
            event(provider: .gemini, model: "Sample Gemini", dayOffset: -16, hour: 10, input: 5_400, output: 1_600, cacheRead: 600, reasoning: 300, requests: 7)
        ]

        func todayTotal(_ events: [UsageEvent]) -> Int {
            events
                .filter { calendar.isDate($0.timestamp, inSameDayAs: referenceDate) }
                .reduce(0) { $0 + $1.totalTokens }
        }

        return [
            ProviderSnapshot(
                provider: .claude,
                updatedAt: referenceDate,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 42, resetAt: referenceDate.addingTimeInterval(5_400), confidence: .manual),
                weekly: LimitWindow(kind: .weekly, usedPercent: 58, resetAt: referenceDate.addingTimeInterval(172_800), confidence: .manual),
                todayTokens: todayTotal(claudeEvents),
                confidence: .manual,
                dataSource: .mock,
                statusMessage: "MOCK · sample data",
                model: "Sample Sonnet",
                events: claudeEvents
            ),
            ProviderSnapshot(
                provider: .codex,
                updatedAt: referenceDate,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 36, confidence: .manual),
                weekly: LimitWindow(kind: .weekly, usedPercent: 44, confidence: .manual),
                todayTokens: todayTotal(codexEvents),
                confidence: .manual,
                dataSource: .mock,
                statusMessage: "MOCK · manual estimate",
                model: "Sample Codex",
                events: codexEvents
            ),
            ProviderSnapshot(
                provider: .gemini,
                updatedAt: referenceDate,
                dailyRequestsUsed: 210,
                dailyRequestsLimit: 1_000,
                todayTokens: todayTotal(geminiEvents),
                confidence: .manual,
                dataSource: .mock,
                statusMessage: "MOCK · sample telemetry",
                model: "Sample Gemini",
                events: geminiEvents
            )
        ]
    }
}

public final class UsageStore: @unchecked Sendable {
    public struct Result: Sendable {
        public var snapshots: [ProviderSnapshot]
        public var hasConnectedData: Bool
        public var capacityObservations: [CapacityObservation]
        public var capacityErrors: [CapacityRefreshError]
        public var observedAt: Date

        public init(
            snapshots: [ProviderSnapshot],
            hasConnectedData: Bool,
            capacityObservations: [CapacityObservation] = [],
            capacityErrors: [CapacityRefreshError] = [],
            observedAt: Date = Date()
        ) {
            self.snapshots = snapshots
            self.hasConnectedData = hasConnectedData
            self.capacityObservations = capacityObservations
            self.capacityErrors = capacityErrors
            self.observedAt = observedAt
        }
    }

    private let refreshAdapters: [any ProviderRefreshAdapter]
    private let mockDataService = MockDataService()

    public init(
        adapters: [any ProviderAdapter]? = nil,
        refreshAdapters: [any ProviderRefreshAdapter]? = nil,
        pathResolver: DefaultPathResolver = DefaultPathResolver()
    ) {
        if let refreshAdapters {
            self.refreshAdapters = refreshAdapters
        } else if let adapters {
            self.refreshAdapters = adapters.map(LegacyProviderRefreshAdapter.init)
        } else {
            self.refreshAdapters = Self.defaultAdapters(pathResolver: pathResolver)
        }
    }

    private static func defaultAdapters(pathResolver: DefaultPathResolver) -> [any ProviderRefreshAdapter] {
        let claudeProjectRoots = pathResolver.resolveDefaultPaths(for: .claude)
            .filter { ["projects", "config_projects"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let codexSessionRoots = pathResolver.resolveDefaultPaths(for: .codex)
            .filter { ["sessions", "archived_sessions"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let geminiSourceURLs = pathResolver.resolveDefaultPaths(for: .gemini)
            .filter { ["antigravity_statusline", "telemetry", "tmp", "history"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: ["tmp", "history"].contains($0.kind)) }

        return [
            ClaudeStatuslineAdapter(fallbackProjectRoots: claudeProjectRoots.isEmpty ? nil : claudeProjectRoots),
            GeminiTelemetryAdapter(logURLs: geminiSourceURLs),
            CodexLocalSessionAdapter(sessionRoots: codexSessionRoots.isEmpty ? nil : codexSessionRoots),
            DeepSeekBalanceAdapter()
        ]
    }

    public func refresh(settings: AppSettings) async -> Result {
        let observedAt = Date()
        let enabledProviders = Set(settings.enabledProviders)
        var snapshots: [ProviderSnapshot] = []
        var capacityObservations: [CapacityObservation] = []
        var capacityErrors: [CapacityRefreshError] = []

        for adapter in refreshAdapters where enabledProviders.contains(adapter.provider) {
            if Task.isCancelled {
                capacityErrors.append(CapacityRefreshError(provider: adapter.provider, category: .cancelled, code: "refreshCancelled", redactedMessage: "Provider refresh cancelled."))
                continue
            }
            let result = await adapter.refresh(settings: settings, now: observedAt)
            var snapshot = result.snapshot
            snapshot.updatedAt = result.observedAt
            snapshots.append(snapshot)
            capacityObservations.append(contentsOf: result.capacityObservations)
            capacityErrors.append(contentsOf: result.typedErrors)
            if Task.isCancelled {
                capacityErrors.append(CapacityRefreshError(provider: adapter.provider, category: .cancelled, code: "refreshCancelled", redactedMessage: "Provider refresh cancelled."))
            }
        }

        let hasConnectedData = snapshots.contains { !$0.events.isEmpty || $0.primaryUsedPercent != nil || $0.dailyRequestsUsed != nil || $0.balance != nil }
        let ordered = snapshots.sorted { $0.provider.rawValue < $1.provider.rawValue }

        if settings.showMockDataWhenDisconnected && !hasConnectedData {
            let mock = mockDataService.snapshots(referenceDate: observedAt)
                .filter { enabledProviders.contains($0.provider) }
                .sorted { $0.provider.rawValue < $1.provider.rawValue }
            return Result(
                snapshots: mock,
                hasConnectedData: false,
                capacityObservations: [],
                capacityErrors: capacityErrors,
                observedAt: observedAt
            )
        }

        return Result(
            snapshots: ordered,
            hasConnectedData: hasConnectedData,
            capacityObservations: capacityObservations,
            capacityErrors: capacityErrors,
            observedAt: observedAt
        )
    }
}


public final class AlertDeduplicationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = OSAllocatedUnfairLock()

    public init(defaults: UserDefaults = .standard, key: String = "tokenPilot.alertDeliveryState.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: AlertDeliveryState] {
        lock.withLock {
            guard let data = defaults.data(forKey: key), let decoded = try? decoder.decode([String: AlertDeliveryState].self, from: data) else { return [:] }
            return decoded
        }
    }

    public func save(_ states: [String: AlertDeliveryState]) {
        lock.withLock {
            guard let data = try? encoder.encode(states) else { return }
            defaults.set(data, forKey: key)
        }
    }

    public func clear() {
        lock.withLock {
            defaults.removeObject(forKey: key)
        }
    }
}

public final class NotificationRuleService: @unchecked Sendable {
    private let store: AlertDeduplicationStore

    public init(store: AlertDeduplicationStore = AlertDeduplicationStore()) {
        self.store = store
    }

    public func evaluate(snapshots: [ProviderSnapshot], settings: AppSettings, language: TokenPilotLanguage = .en) -> [AlertEvent] {
        guard settings.globalNotificationsEnabled else { return [] }
        var states = store.load()
        var events: [AlertEvent] = []
        let snapshotsByProvider = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })

        for rule in settings.alertRules {
            guard let snapshot = snapshotsByProvider[rule.provider], let current = windowValue(snapshot: snapshot, window: rule.window) else { continue }
            let resetAt = windowReset(snapshot: snapshot, window: rule.window)
            let cycleID = resetCycleId(provider: rule.provider, window: rule.window, resetAt: resetAt)
            let key = rule.id
            let previousState = states[key] ?? AlertDeliveryState(provider: rule.provider, window: rule.window, resetCycleId: cycleID)
            let isNewCycle = previousState.resetCycleId != cycleID
            var state = previousState
            if isNewCycle {
                state = AlertDeliveryState(
                    provider: rule.provider,
                    window: rule.window,
                    resetCycleId: cycleID,
                    lastUsedPercent: previousState.lastUsedPercent,
                    lastResetAt: resetAt
                )
            }

            if rule.resetEnabled, shouldSendReset(previous: previousState, current: current, resetAt: resetAt, isNewCycle: isNewCycle) {
                let event = makeEvent(provider: rule.provider, window: rule.window, threshold: .reset, usedPercent: current, resetAt: resetAt, cycleID: cycleID, language: language)
                events.append(event)
                state.sentReset = true
                state.lastSentAt = Date()
            }

            for threshold in [AlertThreshold.fifty, .eighty, .hundred] where rule.isEnabled(threshold) {
                guard let percent = threshold.percent else { continue }
                let wasBelow = (state.lastUsedPercent ?? current) < percent
                let isNowAtOrAbove = current >= percent
                let alreadySent: Bool
                switch threshold {
                case .fifty: alreadySent = state.sent50
                case .eighty: alreadySent = state.sent80
                case .hundred: alreadySent = state.sent100
                case .reset: alreadySent = true
                }
                if wasBelow && isNowAtOrAbove && !alreadySent {
                    let event = makeEvent(provider: rule.provider, window: rule.window, threshold: threshold, usedPercent: current, resetAt: resetAt, cycleID: cycleID, language: language)
                    events.append(event)
                    switch threshold {
                    case .fifty: state.sent50 = true
                    case .eighty: state.sent80 = true
                    case .hundred: state.sent100 = true
                    case .reset: break
                    }
                    state.lastSentAt = Date()
                }
            }
            state.lastUsedPercent = current
            state.lastResetAt = resetAt
            states[key] = state
        }
        appendDeepSeekLowBalanceEvents(snapshotsByProvider: snapshotsByProvider, settings: settings, language: language, states: &states, events: &events)
        store.save(states)
        return events
    }

    private func appendDeepSeekLowBalanceEvents(
        snapshotsByProvider: [Provider: ProviderSnapshot],
        settings: AppSettings,
        language: TokenPilotLanguage,
        states: inout [String: AlertDeliveryState],
        events: inout [AlertEvent]
    ) {
        guard settings.globalNotificationsEnabled,
              settings.deepseekEnabled,
              let snapshot = snapshotsByProvider[.deepseek],
              snapshot.dataSource == .officialTelemetry,
              let balance = snapshot.balance,
              balance.toppedUpBalance <= settings.deepSeekBalance.lowBalanceThreshold else {
            return
        }
        let cycleID = "deepseek-balance-\(Int(balance.capturedAt.timeIntervalSince1970 / 86_400))"
        let key = "deepseek.balance.low"
        var state = states[key] ?? AlertDeliveryState(provider: .deepseek, window: .dailyRequests, resetCycleId: cycleID)
        if state.resetCycleId != cycleID {
            state = AlertDeliveryState(provider: .deepseek, window: .dailyRequests, resetCycleId: cycleID)
        }
        guard !state.sent50 else { return }
        let display = DeepSeekBalanceFormatter.display(balance)
        let threshold = DeepSeekBalanceFormatter.display(ProviderBalance(currency: balance.currency, toppedUpBalance: settings.deepSeekBalance.lowBalanceThreshold))
        events.append(AlertEvent(
            provider: .deepseek,
            window: .dailyRequests,
            threshold: .fifty,
            resetCycleId: cycleID,
            title: TokenPilotLocalizer.localized("DeepSeek low balance", language: language),
            body: String(format: TokenPilotLocalizer.localized("DeepSeek topped-up balance is %@ (threshold %@).", language: language), display, threshold)
        ))
        state.sent50 = true
        state.lastSentAt = Date()
        states[key] = state
    }

    private func windowValue(snapshot: ProviderSnapshot, window: LimitWindowKind) -> Int? {
        switch window {
        case .fiveHour: return snapshot.fiveHour?.usedPercent
        case .weekly: return snapshot.weekly?.usedPercent
        case .dailyRequests: return snapshot.dailyRequestsPercent
        }
    }

    private func windowReset(snapshot: ProviderSnapshot, window: LimitWindowKind) -> Date? {
        switch window {
        case .fiveHour: return snapshot.fiveHour?.resetAt
        case .weekly: return snapshot.weekly?.resetAt
        case .dailyRequests: return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        }
    }

    private func shouldSendReset(previous: AlertDeliveryState, current: Int, resetAt: Date?, isNewCycle: Bool) -> Bool {
        if previous.sentReset && !isNewCycle { return false }
        if let last = previous.lastUsedPercent, last > 10, current <= 3 { return true }
        if isNewCycle, current <= 3 { return true }
        if let resetAt, resetAt < Date(), current <= 3 { return true }
        return false
    }

    private func resetCycleId(provider: Provider, window: LimitWindowKind, resetAt: Date?) -> String {
        if let resetAt {
            return "\(provider.rawValue)-\(window.rawValue)-\(Int(resetAt.timeIntervalSince1970 / 60))"
        }
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return "\(provider.rawValue)-\(window.rawValue)-\(Int(day))"
    }

    private func makeEvent(provider: Provider, window: LimitWindowKind, threshold: AlertThreshold, usedPercent: Int?, resetAt: Date?, cycleID: String, language: TokenPilotLanguage) -> AlertEvent {
        let title = titleFor(threshold: threshold, language: language)
        let resetText = resetAt.map { TokenPilotFormatters.remainingTime(until: $0) } ?? "—"
        let providerWindowText = "\(TokenPilotLocalizer.localized(provider.displayName, language: language)) · \(TokenPilotLocalizer.localized(window.label, language: language))"
        let body: String
        switch threshold {
        case .reset:
            body = String(format: TokenPilotLocalizer.localized("alert.reset.body", language: language), providerWindowText)
        case .fifty:
            body = String(format: TokenPilotLocalizer.localized("alert.fifty.body", language: language), providerWindowText, resetText)
        case .eighty:
            body = String(format: TokenPilotLocalizer.localized("alert.eighty.body", language: language), providerWindowText, usedPercent ?? 0, resetText)
        case .hundred:
            body = String(format: TokenPilotLocalizer.localized("alert.hundred.body", language: language), providerWindowText, resetText)
        }
        return AlertEvent(provider: provider, window: window, threshold: threshold, usedPercent: usedPercent, resetAt: resetAt, resetCycleId: cycleID, title: title, body: body)
    }

    private func titleFor(threshold: AlertThreshold, language: TokenPilotLanguage) -> String {
        let key: String
        switch threshold {
        case .reset: key = "alert.reset.title"
        case .fifty: key = "alert.fifty.title"
        case .eighty: key = "alert.eighty.title"
        case .hundred: key = "alert.hundred.title"
        }
        return TokenPilotLocalizer.localized(key, language: language)
    }
}

public final class LocalNotificationService: @unchecked Sendable {
    public init() {}

    public func permissionStatus() async -> NotificationPermissionState {
        #if canImport(UserNotifications)
        guard canUseUserNotifications else { return .unknown }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notRequested
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        @unknown default: return .unknown
        }
        #else
        return .unknown
        #endif
    }

    public func requestPermission() async -> NotificationPermissionState {
        #if canImport(UserNotifications)
        guard canUseUserNotifications else { return .unknown }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .granted : .denied
        } catch {
            return .unknown
        }
        #else
        return .unknown
        #endif
    }

    public func send(title: String, body: String) async throws {
        #if canImport(UserNotifications)
        guard canUseUserNotifications else {
            try sendWithAppleScript(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
        #else
        try sendWithAppleScript(title: title, body: body)
        #endif
    }

    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func sendWithAppleScript(title: String, body: String) throws {
        let escapedTitle = title.appleScriptEscaped
        let escapedBody = body.appleScriptEscaped
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"Ping\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
    }
}

private extension String {
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

public final class TelegramNotificationService: @unchecked Sendable {
    public init() {}

    public func sendMessage(token: String, chatID: String, text: String, parseMode: String? = nil) async throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TelegramError.notConfigured }
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TelegramError.notConfigured }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { throw TelegramError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["chat_id": chatID, "text": text]
        if let parseMode { payload["parse_mode"] = parseMode }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TelegramError.requestFailed
        }
    }

    public func findChatID(token: String) async throws -> String {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TelegramError.notConfigured }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getUpdates") else { throw TelegramError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TelegramError.requestFailed
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [[String: Any]] else {
            throw TelegramError.noChatFound
        }
        for update in result.reversed() {
            if let message = update["message"] as? [String: Any],
               let chat = message["chat"] as? [String: Any],
               let id = chat["id"] {
                if let number = id as? NSNumber { return number.stringValue }
                if let string = id as? String { return string }
            }
        }
        throw TelegramError.noChatFound
    }
}

public enum TelegramError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case requestFailed
    case noChatFound

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Telegram is not configured."
        case .invalidURL: return "Telegram URL is invalid."
        case .requestFailed: return "Telegram request failed."
        case .noChatFound: return "No chat ID found. Send a message to the bot first."
        }
    }
}

public final class DiscordNotificationService: @unchecked Sendable {
    public init() {}

    public static func makeRequest(webhookURL: String, content: String) throws -> URLRequest {
        let trimmedURL = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw DiscordError.notConfigured }
        guard let url = URL(string: trimmedURL), isAllowedDiscordWebhookURL(url) else { throw DiscordError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let safeContent = content.count > 1900 ? String(content.prefix(1900)) + "…" : content
        let payload: [String: Any] = [
            "content": safeContent,
            "username": "TokenPilot"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    public func sendMessage(webhookURL: String, content: String) async throws {
        let request = try Self.makeRequest(webhookURL: webhookURL, content: content)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DiscordError.requestFailed
        }
    }

    private static func isAllowedDiscordWebhookURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["discord.com", "www.discord.com", "discordapp.com", "www.discordapp.com"].contains(host) else {
            return false
        }
        return url.path.contains("/api/webhooks/")
    }
}

public enum DiscordError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Discord webhook is not configured."
        case .invalidURL: return "Discord webhook URL is invalid."
        case .requestFailed: return "Discord request failed."
        }
    }
}

protocol KeychainBackend: Sendable {
    func saveSecret(_ secret: String, service: String, account: String) throws
    func readSecret(service: String, account: String) throws -> String?
    func deleteSecret(service: String, account: String, ignoreMissing: Bool) throws
}

private struct SecurityKeychainBackend: KeychainBackend {
    func saveSecret(_ secret: String, service: String, account: String) throws {
        let data = Data(secret.utf8)
        try deleteSecret(service: service, account: account, ignoreMissing: true)
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        #endif
    }

    func readSecret(service: String, account: String) throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return secret
        #else
        return nil
        #endif
    }

    func deleteSecret(service: String, account: String, ignoreMissing: Bool) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            if ignoreMissing { return }
            throw KeychainError.itemNotFound
        }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        #endif
    }
}

public final class KeychainService: @unchecked Sendable {
    private let service: String
    private let backend: any KeychainBackend

    public convenience init(service: String = "com.tokenpilot.macos") {
        self.init(service: service, backend: SecurityKeychainBackend())
    }

    init(service: String, backend: any KeychainBackend) {
        self.service = service
        self.backend = backend
    }

    public func saveSecret(_ secret: String, account: String) throws {
        try backend.saveSecret(secret, service: service, account: account)
    }

    public func readSecret(account: String) throws -> String? {
        try backend.readSecret(service: service, account: account)
    }

    public func deleteSecret(account: String) throws {
        try backend.deleteSecret(service: service, account: account, ignoreMissing: false)
    }
}

public enum KeychainError: Error, Equatable, LocalizedError {
    case itemNotFound
    case unhandledStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "Requested keychain item was not found."
        case .unhandledStatus(let status): return "Keychain returned status \(status)."
        case .invalidData: return "Keychain item contained invalid data."
        }
    }
}

public enum TokenPilotFormatters {
    public static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K") }
        return "\(value)"
    }

    public static func cost(_ value: Decimal) -> String {
        String(format: "$%.4f", NSDecimalNumber(decimal: value).doubleValue)
    }

    public static func remainingTime(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(Date())))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public static func compactRemainingTime(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        if days > 0 { return "\(days)d" }
        let hours = seconds / 3_600
        if hours > 0 { return "\(hours)h" }
        let minutes = (seconds % 3_600) / 60
        return "\(minutes)m"
    }

    private static let clockFormatter = OSAllocatedUnfairLock(initialState: {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }())

    public static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        return clockFormatter.withLock { $0.string(from: date) }
    }
}

