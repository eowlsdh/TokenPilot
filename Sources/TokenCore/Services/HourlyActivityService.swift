import Foundation

/// One hour-of-day bucket over stored local activity.
///
/// Hours are 0...23 in the provided calendar. Aggregates are display-only
/// over local activity and must never be presented as provider quota.
public struct HourlyActivityBucket: Equatable, Sendable {
    public let hour: Int
    public let tokens: Int
    public let requestCount: Int

    public init(hour: Int, tokens: Int, requestCount: Int) {
        self.hour = min(max(hour, 0), 23)
        self.tokens = max(tokens, 0)
        self.requestCount = max(requestCount, 0)
    }
}

/// Hour-of-day usage summary over stored local activity.
public struct HourlyActivitySummary: Equatable, Sendable {
    public let buckets: [HourlyActivityBucket]
    /// Hour (0...23) with the most tokens, or nil when there is no activity.
    public let peakHour: Int?

    public init(buckets: [HourlyActivityBucket]) {
        self.buckets = buckets
        self.peakHour = buckets
            .filter { $0.tokens > 0 }
            .max(by: { $0.tokens < $1.tokens })?
            .hour
    }
}

public enum HourlyActivityService {
    /// Aggregates events into 24 hour-of-day buckets.
    ///
    /// Empty hours stay present with zero tokens so a 24-cell bar renders a
    /// full day and gaps are obvious. `calendar` drives hour extraction; pass
    /// a fixed calendar in tests so results are deterministic.
    public static func hourlyBuckets(
        events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HourlyActivityBucket] {
        let tokensByHour = Dictionary(grouping: events, by: { calendar.component(.hour, from: $0.timestamp) })
            .mapValues { events in
                (
                    tokens: events.reduce(0) { $0 + $1.totalTokens },
                    requests: events.reduce(0) { $0 + $1.requestCount }
                )
            }
        return (0..<24).map { hour in
            let value = tokensByHour[hour] ?? (tokens: 0, requests: 0)
            return HourlyActivityBucket(hour: hour, tokens: value.tokens, requestCount: value.requests)
        }
    }
}
