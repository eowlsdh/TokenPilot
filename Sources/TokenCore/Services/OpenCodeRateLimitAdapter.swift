import Foundation

/// Reason an opencode rate-limit observation could not be produced.
public enum OpenCodeRateLimitUnavailableReason: String, Error, Sendable, Equatable {
    case consentMissing
    case tokenUnavailable
    case tokenExpired
    case headersMissing
    case transportFailed
    case unauthorized
    case cancelled
}

/// Provider-reported opencode quota derived from `ratelimit-*` response headers.
public struct OpenCodeRateLimit: Sendable, Equatable {
    public let usedPercent: Int
    public let resetAt: Date?
    public let observedAt: Date

    public init(usedPercent: Int, resetAt: Date?, observedAt: Date) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetAt = resetAt
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

/// Performs the single probe request and surfaces only the rate-limit headers.
public protocol OpenCodeRateLimitProbing: Sendable {
    func probeRateLimit(credential: OpenCodeCredential) async -> Result<[String: String], OpenCodeRateLimitUnavailableReason>
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

/// Sends one minimal authenticated request and returns only `ratelimit-*` headers.
///
/// Verified against the live service on 2026-07-29: `zen/go/v1/models` answers 200 but sends no
/// `ratelimit-*` headers, and every usage/limits/me/billing path under `zen` returns 404. The
/// `ratelimit-*` strings in the opencode binary belong to a bundled server-side rate-limit library,
/// not to its Zen API client, so there is currently no quota surface to read.
///
/// This transport is kept because the header contract is the standard one and costs nothing to
/// support if opencode adds it later. Until then `observe` fails with `headersMissing` rather than
/// inventing a percentage, and the probe stays disabled by default so no request is spent for
/// nothing.
public struct OpenCodeRateLimitHTTPProbe: OpenCodeRateLimitProbing, Sendable {
    public static let endpoint = "https://opencode.ai/zen/go/v1/models"
    public static let requestTimeout: TimeInterval = 10

    private let session: URLSession
    private let endpointOverride: String?

    public init(timeoutSeconds: TimeInterval = requestTimeout, endpointOverride: String? = nil) {
        session = TokenPilotNotificationTransport.makeSession(timeoutSeconds: timeoutSeconds)
        self.endpointOverride = endpointOverride
    }

    public func probeRateLimit(credential: OpenCodeCredential) async -> Result<[String: String], OpenCodeRateLimitUnavailableReason> {
        guard let url = URL(string: endpointOverride ?? Self.endpoint) else { return .failure(.transportFailed) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transportFailed) }
            if http.statusCode == 401 || http.statusCode == 403 { return .failure(.unauthorized) }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let name = (key as? String)?.lowercased(), let text = value as? String else { continue }
                if name.hasPrefix("ratelimit-") || name.hasPrefix("x-ratelimit-") {
                    headers[name] = text
                }
            }
            return headers.isEmpty ? .failure(.headersMissing) : .success(headers)
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
        case .success(let headers):
            guard let limit = Self.parse(headers: headers, now: now) else { return .failure(.headersMissing) }
            return .success(limit)
        }
    }

    /// Reads the standard `ratelimit-*` fields. `reset` is seconds-until-reset per RFC draft, but a
    /// unix timestamp is also accepted because deployments differ.
    public static func parse(headers: [String: String], now: Date) -> OpenCodeRateLimit? {
        let normalized = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })

        func value(_ names: [String]) -> Double? {
            for name in names {
                if let raw = normalized[name], let parsed = Double(raw.trimmingCharacters(in: .whitespaces)) {
                    return parsed
                }
            }
            return nil
        }

        guard let limit = value(["ratelimit-limit", "x-ratelimit-limit"]), limit > 0,
              let remaining = value(["ratelimit-remaining", "x-ratelimit-remaining"]) else {
            return nil
        }

        let used = max(0, min(limit, limit - remaining))
        let usedPercent = Int(((used / limit) * 100).rounded())

        var resetAt: Date?
        if let reset = value(["ratelimit-reset", "x-ratelimit-reset", "ratelimit-reset-after", "x-ratelimit-reset-after"]) {
            resetAt = reset > 1_000_000_000
                ? Date(timeIntervalSince1970: reset > 1_000_000_000_000 ? reset / 1_000 : reset)
                : now.addingTimeInterval(reset)
        }
        return OpenCodeRateLimit(usedPercent: usedPercent, resetAt: resetAt, observedAt: now)
    }
}

private func openCodeExpiryDate(_ value: String?) -> Date? {
    guard let value, let raw = Double(value.trimmingCharacters(in: .whitespaces)), raw > 0 else { return nil }
    return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1_000 : raw)
}
