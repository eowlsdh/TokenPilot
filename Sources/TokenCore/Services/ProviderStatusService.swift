import Foundation

/// Aggregate health of a provider's official status page.
public enum ProviderHealth: String, Codable, Equatable, Sendable {
    case operational
    case degraded
    case outage
    case unknown
}

/// A provider's latest status-page reading.
public struct ProviderStatusReport: Equatable, Sendable {
    public let provider: Provider
    public let health: ProviderHealth
    /// Verbatim status-page description (for example "All Systems Operational").
    public let description: String
    public let checkedAt: Date

    public init(provider: Provider, health: ProviderHealth, description: String, checkedAt: Date) {
        self.provider = provider
        self.health = health
        self.description = description
        self.checkedAt = checkedAt
    }
}

public protocol ProviderStatusHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionProviderStatusHTTPClient: ProviderStatusHTTPClient {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderStatusError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

public enum ProviderStatusError: Error, Equatable, Sendable {
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidPayload
}

/// Parses a statuspage.io v2 `status.json` payload into a `ProviderHealth`.
///
/// The page indicator drives the health mapping: `none` -> operational,
/// `minor`/`major` -> degraded, `critical` -> outage. Anything else (or a
/// non-statuspage payload) is `unknown`.
public struct ProviderStatusParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> (health: ProviderHealth, description: String) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any] else {
            throw ProviderStatusError.invalidPayload
        }
        let description = (status["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let indicator = status["indicator"] as? String ?? ""
        switch indicator {
        case "none":
            return (.operational, description.isEmpty ? "All Systems Operational" : description)
        case "minor", "major":
            return (.degraded, description)
        case "critical":
            return (.outage, description)
        default:
            return (.unknown, description)
        }
    }
}

/// Fetches and caches official provider status-page readings.
///
/// Only providers with an official statuspage.io endpoint are queried; the
/// rest report `.unknown`. Readings are cached per provider with a TTL so the
/// app never hammers status pages on every refresh.
public final class ProviderStatusService: @unchecked Sendable {
    private struct CachedReading: Codable, Sendable {
        var providerRaw: String
        var healthRaw: String
        var description: String
        var checkedAt: Date
    }

    private let httpClient: any ProviderStatusHTTPClient
    private let parser: ProviderStatusParser
    private let session: URLSession
    private let defaults: UserDefaults
    private let cacheKeyPrefix: String
    private let ttl: TimeInterval
    private let lock = NSLock()

    public init(
        httpClient: any ProviderStatusHTTPClient = URLSessionProviderStatusHTTPClient(),
        parser: ProviderStatusParser = ProviderStatusParser(),
        session: URLSession = TokenPilotNotificationTransport.makeSession(timeoutSeconds: 15),
        defaults: UserDefaults = .standard,
        cacheKeyPrefix: String = "tokenPilot.providerStatus.v1",
        ttl: TimeInterval = 15 * 60
    ) {
        self.httpClient = httpClient
        self.parser = parser
        self.session = session
        self.defaults = defaults
        self.cacheKeyPrefix = cacheKeyPrefix
        self.ttl = ttl
    }

    public static let statuspageEndpoints: [Provider: URL] = [
        .claude: URL(string: "https://status.anthropic.com/api/v2/status.json")!,
        .codex: URL(string: "https://status.openai.com/api/v2/status.json")!,
        .xai: URL(string: "https://status.x.ai/api/v2/status.json")!,
    ]

    /// Latest cached reading for the provider, or nil when never fetched/expired.
    public func cachedReport(for provider: Provider, now: Date = Date()) -> ProviderStatusReport? {
        guard let cached = storedReading(for: provider),
              now.timeIntervalSince(cached.checkedAt) < ttl else {
            return nil
        }
        return report(from: cached)
    }

    /// Last known reading regardless of TTL, used as a fallback when a refresh fails.
    public func lastKnownReport(for provider: Provider) -> ProviderStatusReport? {
        guard let cached = storedReading(for: provider) else { return nil }
        return report(from: cached)
    }

    /// Fetches a fresh reading, falling back to the last known value on failure.
    public func refreshStatus(for provider: Provider, now: Date = Date()) async -> ProviderStatusReport {
        if let cached = cachedReport(for: provider, now: now) {
            return cached
        }
        guard let endpoint = Self.statuspageEndpoints[provider] else {
            return ProviderStatusReport(provider: provider, health: .unknown, description: "", checkedAt: now)
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await httpClient.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw ProviderStatusError.httpStatus(response.statusCode)
            }
            let parsed = try parser.parse(data)
            let report = ProviderStatusReport(
                provider: provider,
                health: parsed.health,
                description: parsed.description,
                checkedAt: now
            )
            cache(report)
            return report
        } catch {
            if let lastKnown = lastKnownReport(for: provider) {
                return lastKnown
            }
            return ProviderStatusReport(provider: provider, health: .unknown, description: "", checkedAt: now)
        }
    }

    private func storedReading(for provider: Provider) -> CachedReading? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: cacheKey(for: provider)),
              let cached = try? JSONDecoder().decode(CachedReading.self, from: data) else {
            return nil
        }
        return cached
    }

    private func report(from cached: CachedReading) -> ProviderStatusReport? {
        guard let health = ProviderHealth(rawValue: cached.healthRaw),
              let provider = Provider(rawValue: cached.providerRaw) else {
            return nil
        }
        return ProviderStatusReport(
            provider: provider,
            health: health,
            description: cached.description,
            checkedAt: cached.checkedAt
        )
    }

    private func cache(_ report: ProviderStatusReport) {
        lock.lock()
        defer { lock.unlock() }
        let cached = CachedReading(
            providerRaw: report.provider.rawValue,
            healthRaw: report.health.rawValue,
            description: report.description,
            checkedAt: report.checkedAt
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        defaults.setIfChanged(data, forKey: cacheKey(for: report.provider))
    }

    private func cacheKey(for provider: Provider) -> String {
        "\(cacheKeyPrefix).\(provider.rawValue)"
    }
}
