import Foundation

/// One day's cache hit rate over stored local activity.
public struct DailyCacheRate: Equatable, Sendable {
    public let dayLabel: String
    public let hitRate: Double
    public let hasActivity: Bool

    public init(dayLabel: String, hitRate: Double, hasActivity: Bool) {
        self.dayLabel = dayLabel
        self.hitRate = min(max(hitRate, 0), 1)
        self.hasActivity = hasActivity
    }
}

/// Cache efficiency trend over a trailing window, with a degradation signal.
///
/// Benchmarked against budi's cache degradation detection: besides the daily
/// rates, the trend compares the most recent rate with the window average and
/// flags degradation when the latest reading drops meaningfully below it.
/// All values are local-activity aggregates, never provider quota.
public struct CacheTrend: Equatable, Sendable {
    public let days: [DailyCacheRate]
    /// Latest daily hit rate (nil when the latest day has no activity).
    public let latestHitRate: Double?
    /// Mean hit rate over days with activity.
    public let averageHitRate: Double?
    /// True when the latest rate fell at least 10 points below the average.
    public let isDegrading: Bool

    public init(days: [DailyCacheRate], latestHitRate: Double?, averageHitRate: Double?, isDegrading: Bool) {
        self.days = days
        self.latestHitRate = latestHitRate
        self.averageHitRate = averageHitRate
        self.isDegrading = isDegrading
    }
}

public enum CacheTrendService {
    /// Computes daily cache hit rates for the trailing `days` window ending today.
    ///
    /// A day is included only when it has context reads (`input + cacheRead`);
    /// other days appear with `hasActivity == false` and a zero rate so the
    /// chart stays contiguous. `calendar` drives day bucketing; pass a fixed
    /// calendar in tests so results are deterministic.
    public static func trend(
        events: [UsageEvent],
        days: Int = 7,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CacheTrend {
        let window = max(days, 1)
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(window - 1), to: startOfToday) ?? startOfToday

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "MM-dd"

        var dailyRates: [DailyCacheRate] = []
        var activeRates: [Double] = []
        var latestActiveRate: Double?

        for offset in 0..<window {
            let day = calendar.date(byAdding: .day, value: offset, to: windowStart) ?? windowStart
            let dayEvents = events.filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
            let input = dayEvents.reduce(0) { $0 + $1.inputTokens }
            let cacheRead = dayEvents.reduce(0) { $0 + $1.cacheReadTokens }
            let denominator = input + cacheRead
            let rate = denominator > 0 ? Double(cacheRead) / Double(denominator) : 0
            let hasActivity = denominator > 0
            dailyRates.append(DailyCacheRate(dayLabel: formatter.string(from: day), hitRate: rate, hasActivity: hasActivity))
            if hasActivity {
                activeRates.append(rate)
                latestActiveRate = rate
            }
        }

        let average = activeRates.isEmpty ? nil : activeRates.reduce(0, +) / Double(activeRates.count)
        let degrading: Bool
        if let latest = latestActiveRate, let average, activeRates.count >= 2 {
            degrading = latest <= average - 0.10
        } else {
            degrading = false
        }

        return CacheTrend(
            days: dailyRates,
            latestHitRate: latestActiveRate,
            averageHitRate: average,
            isDegrading: degrading
        )
    }
}
