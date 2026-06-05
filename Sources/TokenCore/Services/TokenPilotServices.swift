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

public enum TokenPilotRefreshPolicy {
    public static func usageRefreshNeeded(from previous: AppSettings, to next: AppSettings) -> Bool {
        previous.enabledProviders != next.enabledProviders ||
        previous.claudeStatusFilePath != next.claudeStatusFilePath ||
        previous.claudeStatusFileBookmarkData != next.claudeStatusFileBookmarkData ||
        previous.geminiTelemetryLogPath != next.geminiTelemetryLogPath ||
        previous.geminiTelemetrySourceBookmarkData != next.geminiTelemetrySourceBookmarkData ||
        previous.geminiDailyRequestCap != next.geminiDailyRequestCap ||
        previous.codexManual != next.codexManual ||
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
    }

    private let adapters: [any ProviderAdapter]
    private let mockDataService = MockDataService()

    public init(adapters: [any ProviderAdapter]? = nil, pathResolver: DefaultPathResolver = DefaultPathResolver()) {
        self.adapters = adapters ?? Self.defaultAdapters(pathResolver: pathResolver)
    }

    private static func defaultAdapters(pathResolver: DefaultPathResolver) -> [any ProviderAdapter] {
        let claudeProjectRoots = pathResolver.resolveDefaultPaths(for: .claude)
            .filter { ["projects", "config_projects"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let codexSessionRoots = pathResolver.resolveDefaultPaths(for: .codex)
            .filter { ["sessions", "archived_sessions"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }

        return [
            ClaudeStatuslineAdapter(fallbackProjectRoots: claudeProjectRoots.isEmpty ? nil : claudeProjectRoots),
            GeminiTelemetryAdapter(),
            CodexLocalSessionAdapter(sessionRoots: codexSessionRoots.isEmpty ? nil : codexSessionRoots)
        ]
    }

    public func refresh(settings: AppSettings) async -> Result {
        let enabledProviders = Set(settings.enabledProviders)
        var snapshots: [ProviderSnapshot] = []
        for adapter in adapters where enabledProviders.contains(adapter.provider) {
            let snapshot = await adapter.snapshot(settings: settings)
            snapshots.append(snapshot)
        }

        let hasConnectedData = snapshots.contains { !$0.events.isEmpty || $0.primaryUsedPercent != nil || $0.dailyRequestsUsed != nil }
        let ordered = snapshots.sorted { $0.provider.rawValue < $1.provider.rawValue }

        if settings.showMockDataWhenDisconnected && !hasConnectedData {
            let mock = mockDataService.snapshots()
                .filter { enabledProviders.contains($0.provider) }
                .sorted { $0.provider.rawValue < $1.provider.rawValue }
            return Result(snapshots: mock, hasConnectedData: false)
        }

        return Result(snapshots: ordered, hasConnectedData: hasConnectedData)
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
        store.save(states)
        return events
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
            body = String(format: TokenPilotLocalizer.localized("alert.eighty.body", language: language), providerWindowText, usedPercent ?? 0, resetText, suggestedSwitch(excluding: provider, language: language))
        case .hundred:
            body = String(format: TokenPilotLocalizer.localized("alert.hundred.body", language: language), providerWindowText, resetText, suggestedSwitch(excluding: provider, language: language))
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

    private func suggestedSwitch(excluding provider: Provider, language: TokenPilotLanguage) -> String {
        let names = Provider.allCases.filter { $0 != provider }.map {
            TokenPilotLocalizer.localized($0.displayName, language: language)
        }
        let separator = TokenPilotLocalizer.localized("alert.or", language: language)
        return names.joined(separator: separator)
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

