import Foundation

/// Cache efficiency over stored local activity.
///
/// Aggregates input/output/cache token buckets and derives the share of
/// context reads served from cache. All values are display-only aggregates
/// over local activity and must never be presented as provider quota or
/// exact billing; pricing and discount ratios vary per provider, so only
/// token counts and a hit-rate ratio are reported.
public struct CacheEfficiencySummary: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    /// Share of context reads served from cache (0...1); 0 when no reads exist.
    public let cacheHitRate: Double

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        cacheHitRate: Double
    ) {
        self.inputTokens = max(inputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.cacheReadTokens = max(cacheReadTokens, 0)
        self.cacheCreationTokens = max(cacheCreationTokens, 0)
        self.cacheHitRate = min(max(cacheHitRate, 0), 1)
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    public var hasCacheActivity: Bool {
        cacheReadTokens > 0 || cacheCreationTokens > 0
    }

    public var hasAnyActivity: Bool {
        totalTokens > 0
    }
}

public enum CacheEfficiencyService {
    /// Computes a cache efficiency summary over the provided events.
    ///
    /// The hit rate is `cacheRead / (input + cacheRead)`: the share of context
    /// reads that were satisfied from cache. Cache writes are reported
    /// separately as priming work, not counted as hits.
    public static func summary(
        events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CacheEfficiencySummary {
        let input = events.reduce(0) { $0 + $1.inputTokens }
        let output = events.reduce(0) { $0 + $1.outputTokens }
        let cacheRead = events.reduce(0) { $0 + $1.cacheReadTokens }
        let cacheCreation = events.reduce(0) { $0 + $1.cacheCreationTokens }

        let denominator = input + cacheRead
        let hitRate = denominator > 0 ? Double(cacheRead) / Double(denominator) : 0

        return CacheEfficiencySummary(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            cacheHitRate: hitRate
        )
    }
}
