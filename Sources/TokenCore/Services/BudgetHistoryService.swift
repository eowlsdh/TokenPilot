import Foundation

/// One day's usage against the configured daily token budget.
public struct DailyBudgetUsage: Equatable, Sendable, Identifiable {
    public let dayLabel: String
    public let tokens: Int
    public let budgetTokens: Int
    /// 0...100 share of the budget used that day.
    public let percent: Int
    /// True when the day's usage reached or exceeded the budget.
    public let exceeded: Bool
    /// True when the day had any recorded activity.
    public let hasActivity: Bool

    public init(dayLabel: String, tokens: Int, budgetTokens: Int, percent: Int, exceeded: Bool, hasActivity: Bool) {
        self.dayLabel = dayLabel
        self.tokens = max(tokens, 0)
        self.budgetTokens = max(budgetTokens, 0)
        self.percent = min(max(percent, 0), 100)
        self.exceeded = exceeded
        self.hasActivity = hasActivity
    }

    public var id: String { dayLabel }
}

/// Daily budget usage over a trailing window.
///
/// Benchmarked against CodeBurn's and tokentop's budget visualization: the
/// trend shows which recent days came close to or exceeded the configured
/// daily local token budget. All values are local-activity aggregates, never
/// provider quota.
public struct BudgetHistoryTrend: Equatable, Sendable {
    public let days: [DailyBudgetUsage]
    /// Count of days that exceeded the daily budget inside the window.
    public let exceededCount: Int
    /// Count of active days inside the window.
    public let activeDayCount: Int

    public init(days: [DailyBudgetUsage], exceededCount: Int, activeDayCount: Int) {
        self.days = days
        self.exceededCount = max(exceededCount, 0)
        self.activeDayCount = max(activeDayCount, 0)
    }
}

public struct BudgetHistoryService: Sendable {
    public init() {}

    /// Builds a daily budget trend for the trailing `days` window ending today.
    ///
    /// Days without a configured budget render zero usage; days with no
    /// activity appear with `hasActivity == false` so gaps stay visible.
    /// `calendar` drives day bucketing; pass a fixed calendar in tests.
    public func trend(
        events: [UsageEvent],
        dailyBudgetTokens: Int,
        days: Int = 14,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BudgetHistoryTrend {
        let window = max(days, 1)
        let budget = max(dailyBudgetTokens, 0)
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(window - 1), to: startOfToday) ?? startOfToday

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "MM-dd"

        var daily: [DailyBudgetUsage] = []
        var exceededCount = 0
        var activeDayCount = 0

        for offset in 0..<window {
            let day = calendar.date(byAdding: .day, value: offset, to: windowStart) ?? windowStart
            let dayTokens = events
                .filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
                .reduce(0) { $0 + $1.totalTokens }
            let hasActivity = dayTokens > 0
            let percent = budget > 0 && dayTokens > 0
                ? min(Int((Double(dayTokens) / Double(budget) * 100).rounded()), 100)
                : 0
            let exceeded = budget > 0 && dayTokens >= budget
            daily.append(
                DailyBudgetUsage(
                    dayLabel: formatter.string(from: day),
                    tokens: dayTokens,
                    budgetTokens: budget,
                    percent: percent,
                    exceeded: exceeded,
                    hasActivity: hasActivity
                )
            )
            if exceeded { exceededCount += 1 }
            if hasActivity { activeDayCount += 1 }
        }

        return BudgetHistoryTrend(days: daily, exceededCount: exceededCount, activeDayCount: activeDayCount)
    }
}
