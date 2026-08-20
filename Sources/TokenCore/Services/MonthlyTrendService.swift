import Foundation

/// One calendar-month bucket over stored local activity.
///
/// `monthLabel` is a short "yyyy-MM" key for stable identity; the UI formats
/// display copy itself. Aggregates are display-only over local activity and
/// must never be presented as provider quota.
public struct MonthlyUsageBar: Equatable, Sendable, Identifiable {
    public let monthLabel: String
    public let tokens: Int
    public let requestCount: Int

    public init(monthLabel: String, tokens: Int, requestCount: Int) {
        self.monthLabel = monthLabel
        self.tokens = max(tokens, 0)
        self.requestCount = max(requestCount, 0)
    }

    public var id: String { monthLabel }
}

public enum MonthlyTrendService {
    /// Aggregates events into calendar-month buckets for the trailing `months` window.
    ///
    /// The current (possibly partial) month is always included last; earlier
    /// months are filled with zero buckets so gaps stay visible. `calendar`
    /// drives month boundaries; pass a fixed calendar in tests so results are
    /// deterministic.
    public static func monthlyBars(
        events: [UsageEvent],
        months: Int = 12,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MonthlyUsageBar] {
        let window = max(months, 1)
        guard let anchorStart = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.calendar = calendar
        monthFormatter.dateFormat = "yyyy-MM"

        var buckets: [(start: Date, tokens: Int, requests: Int)] = []
        for offset in stride(from: window - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .month, value: -offset, to: anchorStart) else { continue }
            buckets.append((start, 0, 0))
        }

        for event in events where event.totalTokens > 0 || event.requestCount > 0 {
            guard let monthStart = calendar.dateInterval(of: .month, for: event.timestamp)?.start else { continue }
            if let index = buckets.firstIndex(where: { $0.start == monthStart }) {
                buckets[index].tokens += event.totalTokens
                buckets[index].requests += event.requestCount
            }
        }

        return buckets.map { bucket in
            MonthlyUsageBar(
                monthLabel: monthFormatter.string(from: bucket.start),
                tokens: bucket.tokens,
                requestCount: bucket.requests
            )
        }
    }
}
