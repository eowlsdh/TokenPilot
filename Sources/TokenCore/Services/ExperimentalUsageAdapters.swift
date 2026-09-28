import Foundation

// MARK: - Shared credential loading for experimental server usage probes
//
// These adapters read ONLY an access token from the provider's own CLI credential file, keep it
// in memory for one request, and never read refresh tokens, API keys, cookies, or other secrets.
// They are consent-gated (default off) and every result is labeled EXPERIMENTAL/UNOFFICIAL.

public enum ExperimentalUsageUnavailableReason: String, Error, Sendable, Equatable {
    case consentMissing
    case credentialNotFound
    case credentialMalformed
    case credentialExpired
    case http401
    case http403
    case http429
    case httpOther
    case timeout
    case network
    case malformedResponse
    case cancelled
}

// MARK: - Claude Code OAuth usage probe

/// Loads only the `accessToken` member of `~/.claude/.credentials.json` (`claudeAiOauth` entry).
/// `refreshToken`, `expiresAt` beyond the read, and every other field are ignored.
public protocol ClaudeCredentialLoading: Sendable {
    func loadAccessToken() -> Result<String, ExperimentalUsageUnavailableReason>
}

public struct LocalClaudeCredentialLoader: ClaudeCredentialLoading, Sendable {
    private static let maximumFileBytes = 512 * 1_024

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.fileURL = fileURL ?? home.appendingPathComponent(".claude/.credentials.json")
    }

    public func loadAccessToken() -> Result<String, ExperimentalUsageUnavailableReason> {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty, data.count <= Self.maximumFileBytes else {
            return .failure(.credentialNotFound)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return .failure(.credentialMalformed)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...8_192).contains(trimmed.utf8.count) else { return .failure(.credentialMalformed) }
        return .success(trimmed)
    }
}

public protocol ClaudeUsageTransporting: Sendable {
    func fetchUsage(accessToken: String) async -> Result<(statusCode: Int, body: Data), ExperimentalUsageUnavailableReason>
}

public struct URLSessionClaudeUsageTransport: ClaudeUsageTransporting, Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"
    public static let timeout: TimeInterval = 12

    public init() {}

    public func fetchUsage(accessToken: String) async -> Result<(statusCode: Int, body: Data), ExperimentalUsageUnavailableReason> {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.network) }
            return .success((http.statusCode, data))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network)
        }
    }
}

/// Parses `five_hour`/`seven_day` utilization from the Claude OAuth usage payload.
public struct ClaudeOAuthUsageParser: Sendable {
    public init() {}

    public struct Reading: Equatable, Sendable {
        public let fiveHourUsedPercent: Int?
        public let sevenDayUsedPercent: Int?
        public let fiveHourResetAt: Date?
        public let sevenDayResetAt: Date?
    }

    public func parse(_ data: Data) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let fiveHour = Self.window(root["five_hour"])
        let sevenDay = Self.window(root["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return Reading(
            fiveHourUsedPercent: fiveHour?.used,
            sevenDayUsedPercent: sevenDay?.used,
            fiveHourResetAt: fiveHour?.resetAt,
            sevenDayResetAt: sevenDay?.resetAt
        )
    }

    private static func window(_ value: Any?) -> (used: Int, resetAt: Date?)? {
        guard let dict = value as? [String: Any],
              let utilization = (dict["utilization"] as? NSNumber)?.intValue else {
            return nil
        }
        let clamped = min(max(utilization, 0), 100)
        var resetAt: Date?
        if let text = dict["resets_at"] as? String {
            let iso = ISO8601DateFormatter()
            resetAt = iso.date(from: text)
        }
        return (clamped, resetAt)
    }
}

/// Consent-gated Claude Code server usage probe. Reads only the access token from the local
/// Claude credentials file, calls the official OAuth usage endpoint once, and labels the result
/// EXPERIMENTAL/UNOFFICIAL because the endpoint is not a documented public API.
public struct ClaudeOAuthUsageProbe: Sendable {
    private let makeCredentialLoader: @Sendable () -> any ClaudeCredentialLoading
    private let makeTransport: @Sendable () -> any ClaudeUsageTransporting
    private let parser: ClaudeOAuthUsageParser

    public init(
        makeCredentialLoader: @escaping @Sendable () -> any ClaudeCredentialLoading = { LocalClaudeCredentialLoader() },
        makeTransport: @escaping @Sendable () -> any ClaudeUsageTransporting = { URLSessionClaudeUsageTransport() },
        parser: ClaudeOAuthUsageParser = ClaudeOAuthUsageParser()
    ) {
        self.makeCredentialLoader = makeCredentialLoader
        self.makeTransport = makeTransport
        self.parser = parser
    }

    public func probe(settings: AppSettings) async -> Result<ClaudeOAuthUsageParser.Reading, ExperimentalUsageUnavailableReason> {
        guard settings.claudeUsageProbeEnabled else { return .failure(.consentMissing) }
        let token: String
        switch makeCredentialLoader().loadAccessToken() {
        case .success(let loaded): token = loaded
        case .failure(let reason): return .failure(reason)
        }
        switch await makeTransport().fetchUsage(accessToken: token) {
        case .failure(let reason): return .failure(reason)
        case .success(let response):
            switch response.statusCode {
            case 200:
                guard let reading = parser.parse(response.body) else { return .failure(.malformedResponse) }
                return .success(reading)
            case 401: return .failure(.http401)
            case 403: return .failure(.http403)
            case 429: return .failure(.http429)
            default: return .failure(.httpOther)
            }
        }
    }
}

// MARK: - Codex OAuth usage probe

/// Loads only the `tokens.access_token` member of `~/.codex/auth.json` (or `CODEX_HOME`).
/// `refresh_token`, `id_token`, `account_id`, and `OPENAI_API_KEY` are never read.
public protocol CodexCredentialLoading: Sendable {
    func loadAccessToken() -> Result<String, ExperimentalUsageUnavailableReason>
}

public struct LocalCodexCredentialLoader: CodexCredentialLoading, Sendable {
    private static let maximumFileBytes = 512 * 1_024

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
                  !codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.fileURL = URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath).appendingPathComponent("auth.json")
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = home.appendingPathComponent(".codex/auth.json")
        }
    }

    public func loadAccessToken() -> Result<String, ExperimentalUsageUnavailableReason> {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty, data.count <= Self.maximumFileBytes else {
            return .failure(.credentialNotFound)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else {
            return .failure(.credentialMalformed)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...8_192).contains(trimmed.utf8.count) else { return .failure(.credentialMalformed) }
        return .success(trimmed)
    }
}

public protocol CodexUsageTransporting: Sendable {
    func fetchUsage(accessToken: String) async -> Result<(statusCode: Int, body: Data), ExperimentalUsageUnavailableReason>
}

public struct URLSessionCodexUsageTransport: CodexUsageTransporting, Sendable {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let timeout: TimeInterval = 12

    public init() {}

    public func fetchUsage(accessToken: String) async -> Result<(statusCode: Int, body: Data), ExperimentalUsageUnavailableReason> {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.network) }
            return .success((http.statusCode, data))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network)
        }
    }
}

/// Parses `primary_window`/`secondary_window` from the Codex wham usage payload.
public struct CodexOAuthUsageParser: Sendable {
    public init() {}

    public struct Reading: Equatable, Sendable {
        public let fiveHourUsedPercent: Int?
        public let sevenDayUsedPercent: Int?
        public let fiveHourResetAt: Date?
        public let sevenDayResetAt: Date?
    }

    public func parse(_ data: Data) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            return nil
        }
        let primary = Self.window(rateLimit["primary_window"])
        let secondary = Self.window(rateLimit["secondary_window"])
        guard primary != nil || secondary != nil else { return nil }
        return Reading(
            fiveHourUsedPercent: primary?.used,
            sevenDayUsedPercent: secondary?.used,
            fiveHourResetAt: primary?.resetAt,
            sevenDayResetAt: secondary?.resetAt
        )
    }

    private static func window(_ value: Any?) -> (used: Int, resetAt: Date?)? {
        guard let dict = value as? [String: Any],
              let usedPercent = (dict["used_percent"] as? NSNumber)?.intValue else {
            return nil
        }
        let clamped = min(max(usedPercent, 0), 100)
        var resetAt: Date?
        if let seconds = (dict["reset_at"] as? NSNumber)?.doubleValue, seconds > 1_000 {
            resetAt = Date(timeIntervalSince1970: seconds)
        }
        return (clamped, resetAt)
    }
}

/// Consent-gated Codex server usage probe. Reads only the access token from the local Codex auth
/// file, calls the ChatGPT backend usage endpoint once, and labels the result EXPERIMENTAL/
/// UNOFFICIAL because the endpoint is not a documented public API.
public struct CodexOAuthUsageProbe: Sendable {
    private let makeCredentialLoader: @Sendable () -> any CodexCredentialLoading
    private let makeTransport: @Sendable () -> any CodexUsageTransporting
    private let parser: CodexOAuthUsageParser

    public init(
        makeCredentialLoader: @escaping @Sendable () -> any CodexCredentialLoading = { LocalCodexCredentialLoader() },
        makeTransport: @escaping @Sendable () -> any CodexUsageTransporting = { URLSessionCodexUsageTransport() },
        parser: CodexOAuthUsageParser = CodexOAuthUsageParser()
    ) {
        self.makeCredentialLoader = makeCredentialLoader
        self.makeTransport = makeTransport
        self.parser = parser
    }

    public func probe(settings: AppSettings) async -> Result<CodexOAuthUsageParser.Reading, ExperimentalUsageUnavailableReason> {
        guard settings.codexUsageProbeEnabled else { return .failure(.consentMissing) }
        let token: String
        switch makeCredentialLoader().loadAccessToken() {
        case .success(let loaded): token = loaded
        case .failure(let reason): return .failure(reason)
        }
        switch await makeTransport().fetchUsage(accessToken: token) {
        case .failure(let reason): return .failure(reason)
        case .success(let response):
            switch response.statusCode {
            case 200:
                guard let reading = parser.parse(response.body) else { return .failure(.malformedResponse) }
                return .success(reading)
            case 401: return .failure(.http401)
            case 403: return .failure(.http403)
            case 429: return .failure(.http429)
            default: return .failure(.httpOther)
            }
        }
    }
}

// MARK: - Grok subscription tier probe (billing adapter enhancement)

/// Loads only the `access_token` member of `~/.grok/auth.json`. Refresh token is never read.
public protocol GrokTierCredentialLoading: Sendable {
    func loadAccessToken() -> Result<String, ExperimentalUsageUnavailableReason>
}

public struct LocalGrokTierCredentialLoader: GrokTierCredentialLoading, Sendable {
    private static let maximumFileBytes = 512 * 1_024

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.fileURL = fileURL ?? home.appendingPathComponent(".grok/auth.json")
    }

    public func loadAccessToken() -> Result<String, ExperimentalUsageUnavailableReason> {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty, data.count <= Self.maximumFileBytes else {
            return .failure(.credentialNotFound)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = root["access_token"] as? String else {
            return .failure(.credentialMalformed)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...8_192).contains(trimmed.utf8.count) else { return .failure(.credentialMalformed) }
        return .success(trimmed)
    }
}

public protocol GrokTierTransporting: Sendable {
    func fetchSettings(accessToken: String) async -> Result<(statusCode: Int, body: Data), ExperimentalUsageUnavailableReason>
}

public struct URLSessionGrokTierTransport: GrokTierTransporting, Sendable {
    public static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    public static let timeout: TimeInterval = 12

    public init() {}

    public func fetchSettings(accessToken: String) async -> Result<(statusCode: Int, body: Data), ExperimentalUsageUnavailableReason> {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.network) }
            return .success((http.statusCode, data))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network)
        }
    }
}

/// Extracts `subscription_tier_display` (e.g. "SuperGrok") from the Grok settings payload.
public struct GrokTierParser: Sendable {
    public init() {}

    public func parse(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tier = root["subscription_tier_display"] as? String else {
            return nil
        }
        let trimmed = tier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Consent-gated Grok plan-name probe. Reads only the access token from `~/.grok/auth.json`,
/// calls the settings endpoint once, and returns the plan label (EXPERIMENTAL/UNOFFICIAL).
public struct GrokTierProbe: Sendable {
    private let makeCredentialLoader: @Sendable () -> any GrokTierCredentialLoading
    private let makeTransport: @Sendable () -> any GrokTierTransporting
    private let parser: GrokTierParser

    public init(
        makeCredentialLoader: @escaping @Sendable () -> any GrokTierCredentialLoading = { LocalGrokTierCredentialLoader() },
        makeTransport: @escaping @Sendable () -> any GrokTierTransporting = { URLSessionGrokTierTransport() },
        parser: GrokTierParser = GrokTierParser()
    ) {
        self.makeCredentialLoader = makeCredentialLoader
        self.makeTransport = makeTransport
        self.parser = parser
    }

    public func probe(settings: AppSettings) async -> Result<String, ExperimentalUsageUnavailableReason> {
        guard settings.grokTierProbeEnabled else { return .failure(.consentMissing) }
        let token: String
        switch makeCredentialLoader().loadAccessToken() {
        case .success(let loaded): token = loaded
        case .failure(let reason): return .failure(reason)
        }
        switch await makeTransport().fetchSettings(accessToken: token) {
        case .failure(let reason): return .failure(reason)
        case .success(let response):
            switch response.statusCode {
            case 200:
                guard let tier = parser.parse(response.body) else { return .failure(.malformedResponse) }
                return .success(tier)
            case 401: return .failure(.http401)
            case 403: return .failure(.http403)
            case 429: return .failure(.http429)
            default: return .failure(.httpOther)
            }
        }
    }
}
