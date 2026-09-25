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
    ///
    /// By wall-clock hour, not seconds since midnight: on a spring-forward day 05:30 is only 4.5
    /// elapsed hours in, and the blocks ran 00/06/11/16/21 instead of 00/05/10/15/20.
    public static func blockStart(of date: Date, calendar: Calendar = .current) -> Date {
        let startHour = calendar.component(.hour, from: date) / 5 * 5
        if let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: date) {
            return start
        }
        let dayStart = calendar.startOfDay(for: date)
        return dayStart.addingTimeInterval(Double(Int(date.timeIntervalSince(dayStart) / blockDuration)) * blockDuration)
    }

    /// When that block actually ends.
    ///
    /// Not simply `start + 5h`. The buckets restart at local midnight, so the last one of the day
    /// (20:00) runs four hours, not five — anything after midnight belongs to the next day's first
    /// block. A countdown built on the raw duration told the user at 23:30 that they had an hour
    /// and a half left, and the total reset thirty minutes later. Every evening, on every install.
    public static func blockEnd(of start: Date, calendar: Calendar = .current) -> Date {
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
            ?? start.addingTimeInterval(blockDuration)
        let endHour = calendar.component(.hour, from: start) + 5
        guard endHour < 24,
              let end = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: start) else { return nextMidnight }
        return min(end, nextMidnight)
    }
}
