import Foundation

/// One day's request count over stored local activity.
public struct DailyRequestBar: Equatable, Sendable, Identifiable {
    public let dayLabel: String
    public let requestCount: Int

    public init(dayLabel: String, requestCount: Int) {
        self.dayLabel = dayLabel
        self.requestCount = max(requestCount, 0)
    }

    public var id: String { dayLabel }
}

/// Daily request counts over a trailing window.
///
/// Benchmarked against CodeBurn/tokentop request-level reporting: shows when
/// API calls were heaviest, complementing the token-based trends. All values
/// are local-activity aggregates, never provider quota.
public struct RequestHistoryTrend: Equatable, Sendable {
    public let days: [DailyRequestBar]
    /// Total requests across the window.
    public let totalRequests: Int
    /// Day with the most requests (nil when the window is empty).
    public let peakDayLabel: String?

    public init(days: [DailyRequestBar], totalRequests: Int, peakDayLabel: String?) {
        self.days = days
        self.totalRequests = max(totalRequests, 0)
        self.peakDayLabel = peakDayLabel
    }
}

public struct RequestHistoryService: Sendable {
    public init() {}

    /// Aggregates request counts into daily bars for the trailing `days` window ending today.
    ///
    /// Every day in the window appears (zero request days stay visible so gaps
    /// are obvious), oldest first. `calendar` drives day bucketing; pass a
    /// fixed calendar in tests so results are deterministic.
    public func trend(
        events: [UsageEvent],
        days: Int = 7,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RequestHistoryTrend {
        let window = max(days, 1)
        let startOfToday = calendar.startOfDay(for: now)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "E"

        var bars: [DailyRequestBar] = []
        var total = 0
        var peakLabel: String?
        var peakCount = 0

        for offset in stride(from: window - 1, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday
            let count = events
                .filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
                .reduce(0) { $0 + $1.requestCount }
            total += count
            if count > peakCount {
                peakCount = count
                peakLabel = formatter.string(from: date)
            }
            bars.append(DailyRequestBar(dayLabel: formatter.string(from: date), requestCount: count))
        }

        return RequestHistoryTrend(days: bars, totalRequests: total, peakDayLabel: peakLabel)
    }
}
