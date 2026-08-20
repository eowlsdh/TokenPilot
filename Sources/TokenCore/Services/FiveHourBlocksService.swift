import Foundation

/// A fixed 5-hour usage bucket aligned to local midnight (00:00, 05:00, 10:00, 15:00, 20:00).
///
/// The 5-hour granularity mirrors the billing-window scale used by provider
/// quota dashboards (ccusage blocks), but these buckets are aggregates over
/// local activity only and must never be presented as provider quota.
public struct FiveHourUsageBlock: Equatable, Sendable {
    public let start: Date
    public let tokens: Int
    public let requestCount: Int
    public let estimatedCostUSD: Decimal?

    public init(start: Date, tokens: Int, requestCount: Int, estimatedCostUSD: Decimal?) {
        self.start = start
        self.tokens = max(tokens, 0)
        self.requestCount = max(requestCount, 0)
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var id: Date { start }
}

public enum FiveHourBlocksService {
    public static let blockDuration: TimeInterval = 5 * 60 * 60

    /// Groups events into fixed 5-hour blocks aligned to local midnight.
    ///
    /// Only blocks containing at least one event are returned, ordered by start
    /// time (oldest first). `calendar` drives the midnight alignment; pass a
    /// fixed calendar in tests so results are deterministic.
    public static func blocks(
        events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [FiveHourUsageBlock] {
        let grouped = Dictionary(grouping: events, by: { blockStart(of: $0.timestamp, calendar: calendar) })
        return grouped.keys.sorted().map { start in
            let bucketEvents = grouped[start] ?? []
            let tokens = bucketEvents.reduce(0) { $0 + $1.totalTokens }
            let requests = bucketEvents.reduce(0) { $0 + $1.requestCount }
            let costs = bucketEvents.compactMap(\.estimatedCostUSD)
            let cost = costs.isEmpty ? nil : costs.reduce(Decimal(0), +)
            return FiveHourUsageBlock(start: start, tokens: tokens, requestCount: requests, estimatedCostUSD: cost)
        }
    }

    /// The fixed 5-hour block containing `date`, aligned to local midnight.
    public static func blockStart(of date: Date, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let secondsSinceMidnight = date.timeIntervalSince(dayStart)
        let blockIndex = Int(secondsSinceMidnight / blockDuration)
        return dayStart.addingTimeInterval(Double(blockIndex) * blockDuration)
    }
}
