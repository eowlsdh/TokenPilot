import Foundation

/// One provider's cache efficiency over stored local activity.
public struct ProviderCacheEfficiency: Equatable, Sendable, Identifiable {
    public let provider: Provider
    public let cacheReadTokens: Int
    public let inputTokens: Int
    /// Share of context reads served from cache (0...1); 0 when no reads exist.
    public let hitRate: Double
    /// True when the provider has any context reads (input + cacheRead).
    public let hasCacheActivity: Bool

    public init(provider: Provider, cacheReadTokens: Int, inputTokens: Int, hitRate: Double, hasCacheActivity: Bool) {
        self.provider = provider
        self.cacheReadTokens = max(cacheReadTokens, 0)
        self.inputTokens = max(inputTokens, 0)
        self.hitRate = min(max(hitRate, 0), 1)
        self.hasCacheActivity = hasCacheActivity
    }

    public var id: String { provider.rawValue }
}

/// Per-provider cache hit rates over stored local activity.
///
/// Benchmarked against budi's per-provider cache hit rate reporting: it shows
/// which providers lean on cache reads vs fresh input. All values are
/// local-activity aggregates, never provider quota.
public struct ProviderCacheEfficiencySummary: Equatable, Sendable {
    public let providers: [ProviderCacheEfficiency]

    public init(providers: [ProviderCacheEfficiency]) {
        self.providers = providers
    }

    public var hasAnyActivity: Bool {
        providers.contains(where: \.hasCacheActivity)
    }
}

public struct ProviderCacheEfficiencyService: Sendable {
    public init() {}

    /// Computes per-provider cache hit rates, ranked by total context reads.
    ///
    /// Providers without any context reads are excluded. `hitRate` is
    /// `cacheRead / (input + cacheRead)` like the aggregate cache service.
    public func summary(
        events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProviderCacheEfficiencySummary {
        let grouped = Dictionary(grouping: events, by: \.provider)
        let rows = grouped.compactMap { provider, providerEvents -> ProviderCacheEfficiency? in
            let input = providerEvents.reduce(0) { $0 + $1.inputTokens }
            let cacheRead = providerEvents.reduce(0) { $0 + $1.cacheReadTokens }
            let denominator = input + cacheRead
            guard denominator > 0 else { return nil }
            return ProviderCacheEfficiency(
                provider: provider,
                cacheReadTokens: cacheRead,
                inputTokens: input,
                hitRate: Double(cacheRead) / Double(denominator),
                hasCacheActivity: true
            )
        }
        let ranked = rows.sorted { lhs, rhs in
            let lhsTotal = lhs.cacheReadTokens + lhs.inputTokens
            let rhsTotal = rhs.cacheReadTokens + rhs.inputTokens
            return lhsTotal > rhsTotal
        }
        return ProviderCacheEfficiencySummary(providers: ranked)
    }
}
