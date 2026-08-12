import Foundation

/// One budget window's progress against its configured token budget.
public struct BudgetGuardrailProgress: Equatable, Sendable {
    public let tokens: Int
    public let budgetTokens: Int
    /// 0...100, clamped; 0 when no budget is configured.
    public let percent: Int
    /// True when `percent` reached the configured alert threshold.
    public let crossedThreshold: Bool

    public init(tokens: Int, budgetTokens: Int, percent: Int, crossedThreshold: Bool) {
        self.tokens = max(tokens, 0)
        self.budgetTokens = max(budgetTokens, 0)
        self.percent = min(max(percent, 0), 100)
        self.crossedThreshold = crossedThreshold
    }
}

/// Combined daily/weekly/monthly budget progress for the current local activity window.
public struct BudgetGuardrailSnapshot: Equatable, Sendable {
    public let daily: BudgetGuardrailProgress
    public let weekly: BudgetGuardrailProgress
    public let monthly: BudgetGuardrailProgress

    public init(
        daily: BudgetGuardrailProgress,
        weekly: BudgetGuardrailProgress,
        monthly: BudgetGuardrailProgress
    ) {
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
    }

    public var hasAnyBudget: Bool {
        daily.budgetTokens > 0 || weekly.budgetTokens > 0 || monthly.budgetTokens > 0
    }
}

/// Evaluates local token activity against optional daily/weekly/monthly budgets.
///
/// Budgets are local-activity guardrails, never provider quota: they only compare
/// stored `UsageEvent` totals with user-configured numbers. All results are
/// display-only and must stay labeled as local activity in the UI.
public struct BudgetGuardrailService: Sendable {
    public init() {}

    public func dailyProgress(
        events: [UsageEvent],
        settings: BudgetGuardrailSettings,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BudgetGuardrailProgress {
        progress(
            events: events,
            budgetTokens: settings.dailyTokens,
            thresholdPercent: settings.alertThresholdPercent,
            filter: { calendar.isDate($0.timestamp, inSameDayAs: now) }
        )
    }

    public func weeklyProgress(
        events: [UsageEvent],
        settings: BudgetGuardrailSettings,
        now: Date = Date(),
        calendar: Calendar = .current,
        weekStartDay: WeekStartDay = .monday
    ) -> BudgetGuardrailProgress {
        guard let weekStart = weeklyStart(of: now, calendar: calendar, weekStartDay: weekStartDay) else {
            return BudgetGuardrailProgress(tokens: 0, budgetTokens: settings.weeklyTokens, percent: 0, crossedThreshold: false)
        }
        return progress(
            events: events,
            budgetTokens: settings.weeklyTokens,
            thresholdPercent: settings.alertThresholdPercent,
            filter: { $0.timestamp >= weekStart && $0.timestamp <= now }
        )
    }

    public func monthlyProgress(
        events: [UsageEvent],
        settings: BudgetGuardrailSettings,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BudgetGuardrailProgress {
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else {
            return BudgetGuardrailProgress(tokens: 0, budgetTokens: settings.monthlyTokens, percent: 0, crossedThreshold: false)
        }
        return progress(
            events: events,
            budgetTokens: settings.monthlyTokens,
            thresholdPercent: settings.alertThresholdPercent,
            filter: { $0.timestamp >= monthStart && $0.timestamp <= now }
        )
    }

    private func progress(
        events: [UsageEvent],
        budgetTokens: Int,
        thresholdPercent: Int,
        filter: (UsageEvent) -> Bool
    ) -> BudgetGuardrailProgress {
        let budget = max(budgetTokens, 0)
        guard budget > 0 else {
            return BudgetGuardrailProgress(tokens: 0, budgetTokens: 0, percent: 0, crossedThreshold: false)
        }
        let tokens = events.filter(filter).reduce(0) { $0 + $1.totalTokens }
        let percent = tokens > 0 ? min(Int((Double(tokens) / Double(budget) * 100).rounded()), 100) : 0
        return BudgetGuardrailProgress(
            tokens: tokens,
            budgetTokens: budget,
            percent: percent,
            crossedThreshold: percent >= thresholdPercent
        )
    }

    private func weeklyStart(of date: Date, calendar: Calendar, weekStartDay: WeekStartDay) -> Date? {
        let weekday = calendar.component(.weekday, from: date)
        let daysBack = weekStartDay.daysBefore(weekday)
        return calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: date))
    }
}
