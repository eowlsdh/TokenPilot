import Foundation

/// Reason a Kiro usage-limits lookup could not produce provider-reported quota.
public enum KiroUsageUnavailableReason: String, Error, Sendable, Equatable {
    case consentMissing
    case tokenUnavailable
    case tokenExpired
    case transportFailed
    case unauthorized
    case malformedResponse
    case cancelled
}

/// Provider-reported Kiro quota from the official `GetUsageLimits` surface.
public struct KiroUsageLimits: Sendable, Equatable {
    public let usedPercent: Int
    public let resetAt: Date?
    public let observedAt: Date

    public init(usedPercent: Int, resetAt: Date?, observedAt: Date) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetAt = resetAt
        self.observedAt = observedAt
    }
}

/// A Kiro bearer credential held in memory for a single request.
///
/// `profileArn` is required by the usage-limits operation. `expiresAt` lets the observer fail with
/// an actionable reason instead of a bare `unauthorized` when the stored token has lapsed.
public struct KiroBearerCredential: Sendable, Equatable {
    public let accessToken: String
    public let profileArn: String?
    public let expiresAt: Date?

    public init(accessToken: String, profileArn: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.profileArn = profileArn
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// Loads the Kiro bearer credential. Production reads only the fixed `auth_kv` row and keeps the
/// value in memory; it is never logged, persisted, diagnosed, or exported.
public protocol KiroBearerTokenLoading: Sendable {
    func loadBearerCredential() -> KiroBearerCredential?
}

/// Performs the single official usage-limits request with an ephemeral bearer token.
public protocol KiroUsageLimitsTransporting: Sendable {
    func fetchUsageLimits(credential: KiroBearerCredential) async -> Result<Data, KiroUsageUnavailableReason>
}

/// Reads Kiro's stored bearer token from its local CLI database.
///
/// This is the one place TokenPilot touches a credential store, and it is gated on explicit
/// consent. Only the fixed `kirocli:social:token` row is read, the value stays in memory for a
/// single request, and it is never written to logs, diagnostics, snapshots, or exports.
public struct KiroLocalBearerTokenLoader: KiroBearerTokenLoading, Sendable {
    public static let tokenKey = "kirocli:social:token"
    private static let maximumTokenBytes = 8 * 1_024

    private let databaseURL: URL

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
    }

    public func loadBearerCredential() -> KiroBearerCredential? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        let escaped = Self.tokenKey.replacingOccurrences(of: "'", with: "''")
        let rows = TokenPilotSQLite.query(
            databasePath: databaseURL.path,
            sql: "SELECT value FROM auth_kv WHERE key='\(escaped)' LIMIT 1",
            maxRows: 1,
            columnCount: 1
        )
        guard let raw = rows.first?.first ?? nil,
              raw.utf8.count <= Self.maximumTokenBytes else {
            return nil
        }
        return Self.extractCredential(from: raw)
    }

    /// The stored row may be a bare token or a JSON envelope. Only the token, profile ARN, and
    /// expiry are read; refresh tokens and any other field are deliberately ignored.
    public static func extractCredential(from raw: String) -> KiroBearerCredential? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return KiroBearerCredential(accessToken: trimmed)
        }

        var token: String?
        for key in ["access_token", "accessToken", "token", "bearerToken"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = value.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard let token else { return nil }

        let arn = (object["profile_arn"] as? String) ?? (object["profileArn"] as? String)
        let expiry = kiroUsageDate(object["expires_at"]) ?? kiroUsageDate(object["expiresAt"])
        return KiroBearerCredential(
            accessToken: token,
            profileArn: arn?.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: expiry
        )
    }
}

/// Calls the official Kiro usage-limits endpoint with a bounded, cookie-free session.
public struct KiroUsageLimitsHTTPTransport: KiroUsageLimitsTransporting, Sendable {
    public static let endpoint = "https://codewhisperer.us-east-1.amazonaws.com/"
    /// Coral services dispatch on `X-Amz-Target` rather than a REST path; without it the service
    /// replies `UnknownOperationException`.
    public static let amzTarget = "AmazonCodeWhispererService.GetUsageLimits"
    public static let maximumBodyBytes = 256 * 1_024
    public static let requestTimeout: TimeInterval = 10

    private let session: URLSession

    public init(timeoutSeconds: TimeInterval = requestTimeout) {
        session = TokenPilotNotificationTransport.makeSession(timeoutSeconds: timeoutSeconds)
    }

    public func fetchUsageLimits(credential: KiroBearerCredential) async -> Result<Data, KiroUsageUnavailableReason> {
        guard let url = URL(string: Self.endpoint) else { return .failure(.transportFailed) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.amzTarget, forHTTPHeaderField: "X-Amz-Target")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [:]
        if let arn = credential.profileArn, !arn.isEmpty {
            body["profileArn"] = arn
        }
        request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transportFailed) }
            if http.statusCode == 401 || http.statusCode == 403 { return .failure(.unauthorized) }
            guard (200..<300).contains(http.statusCode) else { return .failure(.transportFailed) }
            guard data.count <= Self.maximumBodyBytes else { return .failure(.malformedResponse) }
            return .success(data)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.transportFailed)
        }
    }
}

/// Consent-gated observer for Kiro provider-reported quota.
///
/// Eligibility (provider enabled + consent v1) is checked before the token loader or transport is
/// constructed, so a default configuration performs no credential read and no network call.
public struct KiroUsageLimitsObserver: Sendable {
    private let makeTokenLoader: @Sendable () -> any KiroBearerTokenLoading
    private let makeTransport: @Sendable () -> any KiroUsageLimitsTransporting

    public init(
        makeTokenLoader: @escaping @Sendable () -> any KiroBearerTokenLoading = { KiroLocalBearerTokenLoader() },
        makeTransport: @escaping @Sendable () -> any KiroUsageLimitsTransporting = { KiroUsageLimitsHTTPTransport() }
    ) {
        self.makeTokenLoader = makeTokenLoader
        self.makeTransport = makeTransport
    }

    public func observe(settings: AppSettings, now: Date = Date()) async -> Result<KiroUsageLimits, KiroUsageUnavailableReason> {
        guard settings.isProviderEnabled(.kiro), settings.kiro.usageLimitsEnabled else {
            return .failure(.consentMissing)
        }
        guard let credential = makeTokenLoader().loadBearerCredential() else {
            return .failure(.tokenUnavailable)
        }
        guard !credential.isExpired(now: now) else {
            return .failure(.tokenExpired)
        }

        switch await makeTransport().fetchUsageLimits(credential: credential) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let data):
            guard let limits = Self.parse(data, now: now) else { return .failure(.malformedResponse) }
            return .success(limits)
        }
    }

    /// Reads only the numeric quota fields the API documents. Any other field is ignored so a
    /// response change cannot pull unexpected content into TokenPilot.
    public static func parse(_ data: Data, now: Date) -> KiroUsageLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let candidates: [[String: Any]] = {
            var found: [[String: Any]] = [root]
            if let limits = root["limits"] as? [[String: Any]] { found.append(contentsOf: limits) }
            if let limits = root["limits"] as? [String: Any] { found.append(limits) }
            if let breakdown = root["usage_breakdown_list"] as? [[String: Any]] { found.append(contentsOf: breakdown) }
            if let breakdown = root["usage_breakdown"] as? [[String: Any]] { found.append(contentsOf: breakdown) }
            // The live service answers in camelCase and leaves `limits` empty, putting the real
            // numbers in `usageBreakdownList`. Both spellings are accepted so a naming change on
            // either side keeps working.
            if let breakdown = root["usageBreakdownList"] as? [[String: Any]] { found.append(contentsOf: breakdown) }
            if let breakdown = root["usageBreakdown"] as? [[String: Any]] { found.append(contentsOf: breakdown) }
            return found
        }()

        for candidate in candidates {
            if let percent = percentUsed(in: candidate) {
                return KiroUsageLimits(usedPercent: percent, resetAt: resetDate(in: candidate) ?? resetDate(in: root), observedAt: now)
            }
        }
        return nil
    }

    private static func percentUsed(in object: [String: Any]) -> Int? {
        if let direct = doubleValue(object["percent_used"]) ?? doubleValue(object["percentUsed"]) {
            // `percent_used` is normally an integer percentage, but a deployment may report a
            // fraction (0..1) instead. Normalize like the codex session parser so 0.5 means 50%.
            let normalized = direct > 0 && direct < 1 ? direct * 100 : direct
            return Int(normalized.rounded())
        }
        // Derive from raw counts when the API reports usage and limit instead of a percentage.
        let used = doubleValue(object["currentUsageWithPrecision"])
            ?? doubleValue(object["current_usage"])
            ?? doubleValue(object["currentUsage"])
        let total = doubleValue(object["total_usage_limit"])
            ?? doubleValue(object["totalUsageLimit"])
            ?? doubleValue(object["usageLimitWithPrecision"])
            ?? doubleValue(object["usage_limit"])
            ?? doubleValue(object["usageLimit"])
        guard let used, let total, total > 0 else { return nil }
        return Int(((used / total) * 100).rounded())
    }

    private static func resetDate(in object: [String: Any]) -> Date? {
        for key in ["next_date_reset", "nextDateReset", "resets_at", "resetAt"] {
            if let date = kiroUsageDate(object[key]) { return date }
        }
        if let days = doubleValue(object["days_until_reset"]) ?? doubleValue(object["daysUntilReset"]), days >= 0 {
            return Calendar.current.date(byAdding: .day, value: Int(days.rounded()), to: Date())
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private nonisolated(unsafe) let kiroUsageISOFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private nonisolated(unsafe) let kiroUsageISOPlain = ISO8601DateFormatter()

private func kiroUsageDate(_ value: Any?) -> Date? {
    if let number = value as? NSNumber {
        let raw = number.doubleValue
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1_000 : raw)
    }
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = Double(trimmed), seconds > 1_000_000 {
        return Date(timeIntervalSince1970: seconds > 1_000_000_000_000 ? seconds / 1_000 : seconds)
    }
    if let date = kiroUsageISOFractional.date(from: trimmed) { return date }
    return kiroUsageISOPlain.date(from: trimmed)
}
