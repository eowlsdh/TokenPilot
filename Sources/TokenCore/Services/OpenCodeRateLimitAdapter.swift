import Foundation

/// Reason an opencode usage observation could not be produced.
public enum OpenCodeRateLimitUnavailableReason: String, Error, Sendable, Equatable {
    case consentMissing
    case tokenUnavailable
    case tokenExpired
    case usageUnavailable
    case transportFailed
    case unauthorized
    case cancelled
}

/// One provider-reported opencode usage window.
public struct OpenCodeRateLimitWindow: Sendable, Equatable {
    public let usedPercent: Int
    public let resetAt: Date?

    public init(usedPercent: Int, resetAt: Date?) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetAt = resetAt
    }
}

/// Provider-reported opencode quota from the official Zen/Go usage API
/// (`GET /zen/go/v1/usage`). Each plan window is optional because the API may report only the
/// windows the account actually tracks.
public struct OpenCodeRateLimit: Sendable, Equatable {
    public let rolling: OpenCodeRateLimitWindow?
    public let weekly: OpenCodeRateLimitWindow?
    public let monthly: OpenCodeRateLimitWindow?
    public let observedAt: Date

    public init(rolling: OpenCodeRateLimitWindow?, weekly: OpenCodeRateLimitWindow?, monthly: OpenCodeRateLimitWindow?, observedAt: Date) {
        self.rolling = rolling
        self.weekly = weekly
        self.monthly = monthly
        self.observedAt = observedAt
    }
}

/// An opencode access token held in memory for a single probe request.
public struct OpenCodeCredential: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// Loads the opencode access token. Production reads only the fixed `account` row and keeps the
/// value in memory; it is never logged, persisted, diagnosed, or exported.
public protocol OpenCodeCredentialLoading: Sendable {
    func loadCredential() -> OpenCodeCredential?
}

/// Performs the single probe request and surfaces the raw JSON response body.
public protocol OpenCodeRateLimitProbing: Sendable {
    func probeRateLimit(credential: OpenCodeCredential) async -> Result<Data, OpenCodeRateLimitUnavailableReason>
}

/// Reads opencode's stored access token from its local session database.
///
/// This is a consent-gated exception to TokenPilot's no-credential rule. Only `access_token` and
/// `token_expiry` are read from the fixed `account` table; `refresh_token` is deliberately ignored.
public struct OpenCodeLocalCredentialLoader: OpenCodeCredentialLoading, Sendable {
    private static let maximumTokenBytes = 8 * 1_024

    private let databaseURLs: [URL]
    private let authFileURLs: [URL]

    public init(databaseURLs: [URL]? = nil, authFileURLs: [URL]? = nil) {
        self.databaseURLs = databaseURLs ?? OpenCodeSessionAdapter.defaultDatabaseURLs()
        self.authFileURLs = authFileURLs ?? Self.defaultAuthFileURLs()
    }

    public func loadCredential() -> OpenCodeCredential? {
        // opencode Go stores a plan API key in auth.json; older/session installs keep an OAuth
        // access token in the database. The key file is preferred because it is purpose-issued for
        // API access and carries no refresh token.
        if let fromFile = loadFromAuthFile() { return fromFile }

        for url in databaseURLs where FileManager.default.fileExists(atPath: url.path) {
            guard TokenPilotSQLite.tableExists(databasePath: url.path, table: "account") else { continue }
            let rows = TokenPilotSQLite.query(
                databasePath: url.path,
                sql: "SELECT access_token, token_expiry FROM account ORDER BY time_updated DESC LIMIT 1",
                maxRows: 1,
                columnCount: 2
            )
            guard let row = rows.first,
                  let token = row.first ?? nil,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  token.utf8.count <= Self.maximumTokenBytes else {
                continue
            }
            let expiry = row.count > 1 ? openCodeExpiryDate(row[1]) : nil
            return OpenCodeCredential(
                accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines),
                expiresAt: expiry
            )
        }
        return nil
    }

    private func loadFromAuthFile() -> OpenCodeCredential? {
        for url in authFileURLs where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  data.count <= Self.maximumTokenBytes,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = Self.extractAPIKey(from: root) else {
                continue
            }
            // A plan API key has no expiry field, so freshness is decided by the response instead.
            return OpenCodeCredential(accessToken: key, expiresAt: nil)
        }
        return nil
    }

    /// Reads only an `api`-type key for the Go/Zen entry. Any other entry shape is ignored so an
    /// OAuth refresh token in the same file can never be picked up.
    public static func extractAPIKey(from root: [String: Any]) -> String? {
        for name in ["opencode-go", "opencode", "zen"] {
            guard let entry = root[name] as? [String: Any] else { continue }
            guard (entry["type"] as? String)?.lowercased() == "api" else { continue }
            guard let key = entry["key"] as? String else { continue }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func defaultAuthFileURLs() -> [URL] {
        var roots: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let xdgData = environment["XDG_DATA_HOME"], !xdgData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            roots.append(URL(fileURLWithPath: (xdgData as NSString).expandingTildeInPath).appendingPathComponent("opencode", isDirectory: true))
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode", isDirectory: true))
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode", isDirectory: true))
        return roots.map { $0.appendingPathComponent("auth.json") }
    }
}

/// Sends one minimal authenticated request to the official opencode usage API and returns the raw
/// JSON response body.
///
/// Verified against the live service on 2026-08-14: `zen/go/v1/usage` answers 401 without an
/// Authorization header (the endpoint exists) and returns usage windows when authenticated. The
/// response is parsed by `OpenCodeRateLimitObserver.parse(data:now:)`.
///
/// This transport stays consent-gated: the probe is disabled by default so no authenticated
/// request is spent for nothing, and only the usage percentages and reset timestamps are kept.
public struct OpenCodeRateLimitHTTPProbe: OpenCodeRateLimitProbing, Sendable {
    public static let endpoint = "https://opencode.ai/zen/go/v1/usage"
    public static let requestTimeout: TimeInterval = 10

    private let session: URLSession
    private let endpointOverride: String?

    public init(timeoutSeconds: TimeInterval = requestTimeout, endpointOverride: String? = nil) {
        session = TokenPilotNotificationTransport.makeSession(timeoutSeconds: timeoutSeconds)
        self.endpointOverride = endpointOverride
    }

    public func probeRateLimit(credential: OpenCodeCredential) async -> Result<Data, OpenCodeRateLimitUnavailableReason> {
        guard let url = URL(string: endpointOverride ?? Self.endpoint) else { return .failure(.transportFailed) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transportFailed) }
            if http.statusCode == 401 || http.statusCode == 403 { return .failure(.unauthorized) }
            guard (200..<300).contains(http.statusCode) else { return .failure(.usageUnavailable) }
            return .success(data)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.transportFailed)
        }
    }
}

/// Consent-gated observer for opencode provider-reported quota.
public struct OpenCodeRateLimitObserver: Sendable {
    private let makeCredentialLoader: @Sendable () -> any OpenCodeCredentialLoading
    private let makeProbe: @Sendable () -> any OpenCodeRateLimitProbing

    public init(
        makeCredentialLoader: @escaping @Sendable () -> any OpenCodeCredentialLoading = { OpenCodeLocalCredentialLoader() },
        makeProbe: @escaping @Sendable () -> any OpenCodeRateLimitProbing = { OpenCodeRateLimitHTTPProbe() }
    ) {
        self.makeCredentialLoader = makeCredentialLoader
        self.makeProbe = makeProbe
    }

    public func observe(settings: AppSettings, now: Date = Date()) async -> Result<OpenCodeRateLimit, OpenCodeRateLimitUnavailableReason> {
        guard settings.isProviderEnabled(.opencode), settings.openCode.rateLimitProbeEnabled else {
            return .failure(.consentMissing)
        }
        guard let credential = makeCredentialLoader().loadCredential() else {
            return .failure(.tokenUnavailable)
        }
        guard !credential.isExpired(now: now) else {
            return .failure(.tokenExpired)
        }

        switch await makeProbe().probeRateLimit(credential: credential) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let data):
            guard let limit = Self.parse(data: data, now: now) else { return .failure(.usageUnavailable) }
            return .success(limit)
        }
    }

    /// Parses the official `GET /zen/go/v1/usage` JSON response:
    /// `{"usage":{"rolling":{"status":"ok","percent":19.5,"resetsAt":"..."},"weekly":{...},"monthly":{...}}}`
    /// Each window is optional; the result keeps only recognized windows.
    public static func parse(data: Data, now: Date) -> OpenCodeRateLimit? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else {
            return nil
        }

        let rolling = parseWindow(usage["rolling"], now: now)
        let weekly = parseWindow(usage["weekly"], now: now)
        let monthly = parseWindow(usage["monthly"], now: now)
        guard rolling != nil || weekly != nil || monthly != nil else { return nil }

        return OpenCodeRateLimit(rolling: rolling, weekly: weekly, monthly: monthly, observedAt: now)
    }

    /// A window that carries a usable percentage is a reading, whatever `status` says.
    ///
    /// This used to require `status == "ok"` and drop the window otherwise, which meant the app went
    /// blind at the one moment a limit monitor exists for. Measured on a real account: the monthly
    /// window's records stop dead on 2026-08-19T02:58 with 1,171 samples while the rolling and weekly
    /// windows carry on to 1,665 — and opencode's own dashboard shows that monthly window at 100%.
    /// It reached its limit, its status stopped being `ok`, and TokenPilot quietly forgot it existed.
    ///
    /// The status vocabulary is not documented and was not observed here — reading the account's
    /// token to see it is not something this app does. What is observed is that requiring one exact
    /// value discards a real reading, so the gate is on the reading instead.
    private static func parseWindow(_ value: Any?, now: Date) -> OpenCodeRateLimitWindow? {
        guard let window = value as? [String: Any] else { return nil }
        let percent: Double?
        if let number = window["percent"] as? NSNumber {
            percent = number.doubleValue
        } else if let text = window["percent"] as? String {
            percent = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            percent = nil
        }
        guard let percent, percent.isFinite else { return nil }

        var resetAt: Date?
        if let text = window["resetsAt"] as? String {
            resetAt = openCodeUsageDate(text)
        }
        return OpenCodeRateLimitWindow(usedPercent: Int(percent.rounded()), resetAt: resetAt)
    }

    /// Accepts offset-qualified ISO timestamps (`2026-08-14T12:00:00+09:00`) and, as a fallback,
    /// unix seconds.
    private static func openCodeUsageDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        if let seconds = Double(trimmed), seconds > 1_000 {
            return Date(timeIntervalSince1970: seconds > 1_000_000_000_000 ? seconds / 1_000 : seconds)
        }
        return nil
    }
}

private func openCodeExpiryDate(_ value: String?) -> Date? {
    guard let value, let raw = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), raw > 0 else { return nil }
    return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1_000 : raw)
}
