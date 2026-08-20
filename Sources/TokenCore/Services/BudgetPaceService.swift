import Foundation

/// Projection of when today's local token budget runs out at the current burn rate.
///
/// Benchmarked against tokentop's budget guardrails and CodeBurn's spend
/// prediction. The estimate uses how many tokens were burned so far today and
/// how much of the day has elapsed, so it is only meaningful once a stable
/// burn rate has been observed. Always an estimate; must be labeled `est.`
/// in UI copy and never presented as provider quota.
public struct BudgetPaceProjection: Equatable, Sendable {
    public let usedTokens: Int
    public let budgetTokens: Int
    /// Tokens burned per full hour, from the elapsed share of today.
    public let tokensPerHour: Double
    /// Hours until the daily budget reaches 100% at the current burn rate.
    public let hoursUntilExhaustion: Double
    public let estimatedExhaustionAt: Date

    public init(
        usedTokens: Int,
        budgetTokens: Int,
        tokensPerHour: Double,
        hoursUntilExhaustion: Double,
        estimatedExhaustionAt: Date
    ) {
        self.usedTokens = max(usedTokens, 0)
        self.budgetTokens = max(budgetTokens, 0)
        self.tokensPerHour = tokensPerHour
        self.hoursUntilExhaustion = hoursUntilExhaustion
        self.estimatedExhaustionAt = estimatedExhaustionAt
    }
}

public struct BudgetPaceService: Sendable {
    public init() {}

    /// Projects daily-budget exhaustion from today's usage so far.
    ///
    /// Returns nil when the daily budget is disabled, no tokens have been used
    /// yet, the budget is already exhausted, or less than 30 minutes of the day
    /// has elapsed (too little signal for a stable rate).
    public func projection(
        progress: BudgetGuardrailProgress,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BudgetPaceProjection? {
        guard progress.budgetTokens > 0, progress.tokens > 0 else { return nil }
        let dayStart = calendar.startOfDay(for: now)
        let elapsedSeconds = max(now.timeIntervalSince(dayStart), 0)
        guard elapsedSeconds >= 30 * 60 else { return nil }

        let elapsedHours = elapsedSeconds / 3600
        let tokensPerHour = Double(progress.tokens) / elapsedHours
        guard tokensPerHour > 0, tokensPerHour.isFinite else { return nil }

        let remainingTokens = max(progress.budgetTokens - progress.tokens, 0)
        guard remainingTokens > 0 else { return nil }

        let hoursUntilExhaustion = Double(remainingTokens) / tokensPerHour
        guard hoursUntilExhaustion > 0, hoursUntilExhaustion.isFinite else { return nil }

        return BudgetPaceProjection(
            usedTokens: progress.tokens,
            budgetTokens: progress.budgetTokens,
            tokensPerHour: tokensPerHour,
            hoursUntilExhaustion: hoursUntilExhaustion,
            estimatedExhaustionAt: now.addingTimeInterval(hoursUntilExhaustion * 3600)
        )
    }
}
