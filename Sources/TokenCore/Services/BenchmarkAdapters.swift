import Foundation

// MARK: - JetBrains AI Assistant (local quota cache, no credentials)

/// Parses JetBrains `AIAssistantQuotaManager2.xml` quota state.
///
/// JetBrains stores AI Assistant quota in 1e-5 credit units; `quotaInfo` carries
/// `maximum`/`current`/`available`/`until` attributes and `nextRefill` carries
/// the reset time. This adapter reads only local IDE config, never credentials.
public struct JetBrainsQuotaParser: Sendable {
    public struct Quota: Equatable, Sendable {
        public let usedPercent: Int
        public let resetAt: Date?
    }

    public init() {}

    public func parse(xml: Data) -> Quota? {
        guard let text = String(data: xml, encoding: .utf8) else { return nil }
        guard let quotaInfo = Self.optionJSON(text, name: "quotaInfo"),
              let maximum = Self.number(quotaInfo["maximum"]), maximum > 0,
              let used = Self.number(quotaInfo["current"]) ?? Self.number(quotaInfo["used"]) else {
            return nil
        }
        let clamped = min(max(used, 0), maximum)
        let percent = Int((clamped / maximum * 100).rounded())
        var resetAt: Date?
        if let until = Self.isoDate(quotaInfo["until"] ?? "") {
            resetAt = until
        } else if let refill = Self.optionJSON(text, name: "nextRefill") {
            resetAt = Self.isoDate(refill["refillDate"] ?? refill["date"] ?? "")
        }
        return Quota(usedPercent: percent, resetAt: resetAt)
    }

    /// Finds `<option ... name="NAME" ... />`, extracts the `value` attribute, decodes XML
    /// entities, and parses the payload as JSON (the shape JetBrains writes).
    private static func optionJSON(_ text: String, name: String) -> [String: String]? {
        let pattern = #"<option\b[^>]*\bname="\#(name)"[^>]*/>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let elementRange = Range(match.range, in: text) else {
            return nil
        }
        let element = String(text[elementRange])
        guard let valueRegex = try? NSRegularExpression(pattern: #"\bvalue="([^"]*)""#),
              let valueMatch = valueRegex.firstMatch(in: element, range: NSRange(element.startIndex..<element.endIndex, in: element)),
              valueMatch.numberOfRanges == 2,
              let valueRange = Range(valueMatch.range(at: 1), in: element) else {
            return nil
        }
        let encoded = String(element[valueRange])
        let decoded = decodeXMLEntities(encoded)
        guard let data = decoded.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return root.mapValues { "\($0)" }
    }

    private static func decodeXMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "\r")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func number(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private static func isoDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: trimmed)
    }
}

public final class JetBrainsAIAssistantAdapter: ProviderRefreshAdapter, @unchecked Sendable {
    public let provider: Provider = .jetbrains
    private let parser: JetBrainsQuotaParser
    private let quotaFileURLs: [URL]

    public init(parser: JetBrainsQuotaParser = JetBrainsQuotaParser(), quotaFileURLs: [URL]? = nil) {
        self.parser = parser
        self.quotaFileURLs = quotaFileURLs ?? Self.defaultQuotaFileURLs()
    }

    /// JetBrains keeps one IDE directory per product; the quota cache sits at a fixed path inside.
    static func quotaFileURLs(under root: URL) -> [URL] {
        let manager = FileManager.default
        let direct = root.appendingPathComponent("options/AIAssistantQuotaManager2.xml")
        if manager.fileExists(atPath: direct.path) { return [direct] }
        guard let entries = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.compactMap { entry in
            let candidate = root.appendingPathComponent(entry).appendingPathComponent("options/AIAssistantQuotaManager2.xml")
            return manager.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    public static func defaultQuotaFileURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Application Support/JetBrains", isDirectory: true)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: base.path) else { return [] }
        var results: [URL] = []
        for name in entries where name.hasPrefix("IntelliJIdea") || name.hasPrefix("PyCharm") || name.hasPrefix("WebStorm") || name.hasPrefix("CLion") || name.hasPrefix("GoLand") || name.hasPrefix("RubyMine") || name.hasPrefix("DataGrip") || name.hasPrefix("Rider") || name.hasPrefix("PhpStorm") {
            let candidate = base.appendingPathComponent(name).appendingPathComponent("options/AIAssistantQuotaManager2.xml")
            if manager.fileExists(atPath: candidate.path) {
                results.append(candidate)
            }
        }
        return results
    }

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        guard settings.isProviderEnabled(.jetbrains) else {
            let snapshot = ProviderSnapshot(provider: .jetbrains, updatedAt: now, confidence: .low, statusMessage: "Disabled")
            return ProviderRefreshResult(
                snapshot: snapshot,
                typedErrors: [CapacityRefreshError(provider: .jetbrains, category: .disabled, code: "providerDisabled", redactedMessage: "JetBrains AI Assistant is disabled.")],
                observedAt: now
            )
        }

        // A sandboxed build cannot walk ~/Library/Application Support/JetBrains on its own; when the
        // user grants that folder the quota files are discovered underneath it instead.
        let resolution = ProviderSourceAccess.resolve(provider: .jetbrains, settings: settings, defaults: [])
        defer { resolution.release() }
        let grantedFiles = resolution.roots.flatMap { Self.quotaFileURLs(under: $0) }
        if resolution.needsUserGrant && grantedFiles.isEmpty {
            let snapshot = ProviderSnapshot(
                provider: .jetbrains,
                updatedAt: now,
                confidence: .low,
                dataSource: .unknown,
                statusMessage: "Choose the JetBrains folder to grant access"
            )
            return ProviderRefreshResult(snapshot: snapshot, typedErrors: [], observedAt: now)
        }
        let searchURLs = grantedFiles.isEmpty ? quotaFileURLs : grantedFiles

        let manager = FileManager.default
        var latest: (url: URL, quota: JetBrainsQuotaParser.Quota)?
        for url in searchURLs where manager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let quota = parser.parse(xml: data) else { continue }
            if latest == nil || url.lastPathComponent > latest!.url.lastPathComponent {
                latest = (url, quota)
            }
        }

        guard let (_, quota) = latest else {
            let snapshot = ProviderSnapshot(provider: .jetbrains, updatedAt: now, confidence: .low, dataSource: .localLog, statusMessage: "JetBrains AI quota file not found")
            return ProviderRefreshResult(
                snapshot: snapshot,
                typedErrors: [CapacityRefreshError(provider: .jetbrains, category: .sourceUnavailable, code: "quotaFileNotFound", redactedMessage: "JetBrains AI Assistant quota cache not found.")],
                observedAt: now
            )
        }

        let snapshot = ProviderSnapshot(
            provider: .jetbrains,
            updatedAt: now,
            weekly: LimitWindow(kind: .weekly, usedPercent: quota.usedPercent, resetAt: quota.resetAt, confidence: .high, providerWindowID: "jetbrains-quota"),
            confidence: .high,
            dataSource: .localLog,
            isStale: false,
            statusMessage: "Local IDE quota cache"
        )
        return ProviderRefreshResult(
            snapshot: snapshot,
            capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now),
            observedAt: now
        )
    }
}

// MARK: - MiniMax Token Plan (official API, opt-in key)

public enum MiniMaxUsageError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidHTTPResponse
    case httpStatus(Int)
    case malformedResponse
    case transportFailed
}

public protocol MiniMaxUsageHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionMiniMaxUsageHTTPClient: MiniMaxUsageHTTPClient {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MiniMaxUsageError.invalidHTTPResponse }
        return (data, http)
    }
}

public struct MiniMaxTokenPlanParser: Sendable {
    public init() {}

    public struct Reading: Equatable, Sendable {
        public let usedPercent: Int
        public let resetAt: Date?
    }

    public func parse(_ data: Data) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let models = root["model_remains"] as? [[String: Any]] ?? []
        let candidates = models.compactMap { item -> Double? in
            if let percent = item["current_interval_remaining_percent"] as? NSNumber {
                return percent.doubleValue
            }
            if let text = item["current_interval_remaining_percent"] as? String {
                return Double(text)
            }
            return nil
        }
        guard let lowestRemaining = candidates.min() else { return nil }
        let usedPercent = Int((100 - lowestRemaining).rounded())
        var resetAt: Date?
        if let item = models.first, let endText = item["interval_end_time"] as? String {
            resetAt = Self.isoDate(endText)
        }
        return Reading(usedPercent: min(max(usedPercent, 0), 100), resetAt: resetAt)
    }

    private static func isoDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

public final class MiniMaxTokenPlanAdapter: ProviderRefreshAdapter, @unchecked Sendable {
    public let provider: Provider = .minimax
    private let httpClient: any MiniMaxUsageHTTPClient
    private let keychain: KeychainService
    private let parser: MiniMaxTokenPlanParser
    private let endpoint: URL

    public init(
        httpClient: any MiniMaxUsageHTTPClient = URLSessionMiniMaxUsageHTTPClient(),
        keychain: KeychainService = KeychainService(),
        parser: MiniMaxTokenPlanParser = MiniMaxTokenPlanParser(),
        endpoint: URL = URL(string: "https://www.minimax.io/v1/token_plan/remains")!
    ) {
        self.httpClient = httpClient
        self.keychain = keychain
        self.parser = parser
        self.endpoint = endpoint
    }

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        guard settings.isProviderEnabled(.minimax) else {
            let snapshot = ProviderSnapshot(provider: .minimax, updatedAt: now, confidence: .low, statusMessage: "Disabled")
            return ProviderRefreshResult(
                snapshot: snapshot,
                typedErrors: [CapacityRefreshError(provider: .minimax, category: .disabled, code: "providerDisabled", redactedMessage: "MiniMax is disabled.")],
                observedAt: now
            )
        }

        guard let apiKey = try? keychain.readSecret(account: "minimax.apiKey"),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let snapshot = ProviderSnapshot(provider: .minimax, updatedAt: now, confidence: .manual, dataSource: .manual, statusMessage: "API key required")
            return ProviderRefreshResult(snapshot: snapshot, observedAt: now)
        }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await httpClient.data(for: request)
            guard (200..<300).contains(response.statusCode) else { throw MiniMaxUsageError.httpStatus(response.statusCode) }
            guard let reading = parser.parse(data) else { throw MiniMaxUsageError.malformedResponse }
            let snapshot = ProviderSnapshot(
                provider: .minimax,
                updatedAt: now,
                weekly: LimitWindow(kind: .weekly, usedPercent: reading.usedPercent, resetAt: reading.resetAt, confidence: .high, providerWindowID: "minimax-token-plan"),
                confidence: .high,
                dataSource: .officialUsageAPI,
                isStale: false,
                statusMessage: "MiniMax Token Plan"
            )
            return ProviderRefreshResult(
                snapshot: snapshot,
                capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now),
                observedAt: now
            )
        } catch {
            let snapshot = ProviderSnapshot(provider: .minimax, updatedAt: now, confidence: .low, dataSource: .officialUsageAPI, statusMessage: "MiniMax usage unavailable")
            return ProviderRefreshResult(
                snapshot: snapshot,
                typedErrors: [CapacityRefreshError(provider: .minimax, category: .sourceUnavailable, code: "minimaxUsageError", redactedMessage: "MiniMax usage request failed.")],
                observedAt: now
            )
        }
    }
}

// MARK: - Z.ai GLM coding plans (official API, opt-in key)

public protocol ZAIUsageHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionZAIUsageHTTPClient: ZAIUsageHTTPClient {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MiniMaxUsageError.invalidHTTPResponse }
        return (data, http)
    }
}

public struct ZAIQuotaParser: Sendable {
    public init() {}

    public struct Reading: Equatable, Sendable {
        public let usedPercent: Int
        public let resetAt: Date?
    }

    public func parse(_ data: Data) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let limits = root["limits"] as? [[String: Any]] ?? []
        guard let tokenLimit = limits.first(where: { ($0["type"] as? String) == "TOKENS_LIMIT" }) else { return nil }
        let percent: Double?
        if let number = tokenLimit["percentage"] as? NSNumber {
            percent = number.doubleValue
        } else if let text = tokenLimit["percentage"] as? String {
            percent = Double(text)
        } else {
            percent = nil
        }
        guard let percent, percent.isFinite else { return nil }
        var resetAt: Date?
        if let text = tokenLimit["nextResetTime"] as? String {
            let iso = ISO8601DateFormatter()
            resetAt = iso.date(from: text)
        }
        return Reading(usedPercent: min(max(Int(percent.rounded()), 0), 100), resetAt: resetAt)
    }
}

public final class ZAIUsageAdapter: ProviderRefreshAdapter, @unchecked Sendable {
    public let provider: Provider = .zai
    private let httpClient: any ZAIUsageHTTPClient
    private let keychain: KeychainService
    private let parser: ZAIQuotaParser
    private let quotaURL: URL

    public init(
        httpClient: any ZAIUsageHTTPClient = URLSessionZAIUsageHTTPClient(),
        keychain: KeychainService = KeychainService(),
        parser: ZAIQuotaParser = ZAIQuotaParser(),
        quotaURL: URL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    ) {
        self.httpClient = httpClient
        self.keychain = keychain
        self.parser = parser
        self.quotaURL = quotaURL
    }

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        guard settings.isProviderEnabled(.zai) else {
            let snapshot = ProviderSnapshot(provider: .zai, updatedAt: now, confidence: .low, statusMessage: "Disabled")
            return ProviderRefreshResult(
                snapshot: snapshot,
                typedErrors: [CapacityRefreshError(provider: .zai, category: .disabled, code: "providerDisabled", redactedMessage: "Z.ai is disabled.")],
                observedAt: now
            )
        }

        guard let apiKey = try? keychain.readSecret(account: "zai.apiKey"),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let snapshot = ProviderSnapshot(provider: .zai, updatedAt: now, confidence: .manual, dataSource: .manual, statusMessage: "API key required")
            return ProviderRefreshResult(snapshot: snapshot, observedAt: now)
        }

        do {
            var request = URLRequest(url: quotaURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await httpClient.data(for: request)
            guard (200..<300).contains(response.statusCode) else { throw MiniMaxUsageError.httpStatus(response.statusCode) }
            guard let reading = parser.parse(data) else { throw MiniMaxUsageError.malformedResponse }
            let snapshot = ProviderSnapshot(
                provider: .zai,
                updatedAt: now,
                weekly: LimitWindow(kind: .weekly, usedPercent: reading.usedPercent, resetAt: reading.resetAt, confidence: .high, providerWindowID: "zai-tokens-limit"),
                confidence: .high,
                dataSource: .officialUsageAPI,
                isStale: false,
                statusMessage: "Z.ai GLM plan"
            )
            return ProviderRefreshResult(
                snapshot: snapshot,
                capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now),
                observedAt: now
            )
        } catch {
            let snapshot = ProviderSnapshot(provider: .zai, updatedAt: now, confidence: .low, dataSource: .officialUsageAPI, statusMessage: "Z.ai usage unavailable")
            return ProviderRefreshResult(
                snapshot: snapshot,
                typedErrors: [CapacityRefreshError(provider: .zai, category: .sourceUnavailable, code: "zaiUsageError", redactedMessage: "Z.ai usage request failed.")],
                observedAt: now
            )
        }
    }
}

// MARK: - OpenRouter (official API, opt-in key)

public protocol OpenRouterHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionOpenRouterHTTPClient: OpenRouterHTTPClient {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MiniMaxUsageError.invalidHTTPResponse }
        return (data, http)
    }
}

public struct OpenRouterUsageParser: Sendable {
    public init() {}

    public struct Reading: Equatable, Sendable {
        public let usedPercent: Int
        public let resetAt: Date?
    }

    /// `/api/v1/credits` returns `total_usage` (lifetime spend) and `total_credits` (lifetime
    /// purchased ceiling). The spend meter is the percent of purchased credits used.
    public func parseCredits(_ data: Data) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let totalCredits = (root["total_credits"] as? NSNumber)?.doubleValue, totalCredits > 0,
              let totalUsage = (root["total_usage"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let used = min(max(totalUsage, 0), totalCredits)
        return Reading(usedPercent: Int((used / totalCredits * 100).rounded()), resetAt: nil)
    }
}

public final class OpenRouterAdapter: ProviderRefreshAdapter, @unchecked Sendable {
    public let provider: Provider = .openrouter
    private let httpClient: any OpenRouterHTTPClient
    private let keychain: KeychainService
    private let parser: OpenRouterUsageParser
    private let creditsURL: URL

    public init(
        httpClient: any OpenRouterHTTPClient = URLSessionOpenRouterHTTPClient(),
        keychain: KeychainService = KeychainService(),
        parser: OpenRouterUsageParser = OpenRouterUsageParser(),
        creditsURL: URL = URL(string: "https://openrouter.ai/api/v1/credits")!
    ) {
        self.httpClient = httpClient
        self.keychain = keychain
        self.parser = parser
        self.creditsURL = creditsURL
    }

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        guard settings.isProviderEnabled(.openrouter) else {
            let snapshot = ProviderSnapshot(provider: .openrouter, updatedAt: now, confidence: .low, statusMessage: "Disabled")
            return ProviderRefreshResult(
                snapshot: snapshot,
                typedErrors: [CapacityRefreshError(provider: .openrouter, category: .disabled, code: "providerDisabled", redactedMessage: "OpenRouter is disabled.")],
                observedAt: now
            )
        }

        guard let apiKey = try? keychain.readSecret(account: "openrouter.apiKey"),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let snapshot = ProviderSnapshot(provider: .openrouter, updatedAt: now, confidence: .manual, dataSource: .manual, statusMessage: "API key required")
            return ProviderRefreshResult(snapshot: snapshot, observedAt: now)
        }

        do {
            var request = URLRequest(url: creditsURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await httpClient.data(for: request)
            guard (200..<300).contains(response.statusCode) else { throw MiniMaxUsageError.httpStatus(response.statusCode) }
            guard let reading = parser.parseCredits(data) else { throw MiniMaxUsageError.malformedResponse }
            let snapshot = ProviderSnapshot(
                provider: .openrouter,
                updatedAt: now,
                weekly: LimitWindow(kind: .weekly, usedPercent: reading.usedPercent, resetAt: reading.resetAt, confidence: .high, providerWindowID: "openrouter-credits"),
                confidence: .high,
                dataSource: .officialUsageAPI,
                isStale: false,
                statusMessage: "OpenRouter credits"
            )
            return ProviderRefreshResult(
                snapshot: snapshot,
                capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now),
                observedAt: now
            )
        } catch {
            let snapshot = ProviderSnapshot(provider: .openrouter, updatedAt: now, confidence: .low, dataSource: .officialUsageAPI, statusMessage: "OpenRouter usage unavailable")
            return ProviderRefreshResult(
                snapshot: snapshot,
                typedErrors: [CapacityRefreshError(provider: .openrouter, category: .sourceUnavailable, code: "openrouterUsageError", redactedMessage: "OpenRouter usage request failed.")],
                observedAt: now
            )
        }
    }
}
