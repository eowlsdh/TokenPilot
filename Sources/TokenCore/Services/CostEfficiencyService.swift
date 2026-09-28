import Foundation

/// Per-request cost and efficiency metrics over stored local activity.
///
/// Benchmarked against tokentop's cost-per-request and CodeBurn's
/// cost-per-call / output-tokens-per-call reporting. Only events that carry a
/// recorded cost or token counts contribute; all values are local-activity
/// aggregates and must never be presented as provider quota or exact billing.
public struct CostEfficiencySummary: Equatable, Sendable {
    public let totalTokens: Int
    public let requestCount: Int
    public let totalCostUSD: Decimal?
    /// `totalCostUSD / requestCount` for requests that carry a recorded cost.
    public let costPerRequestUSD: Decimal?
    /// `totalTokens / requestCount` across all events.
    public let tokensPerRequest: Double
    /// Share of total tokens that are output tokens (0...1).
    public let outputTokenRatio: Double

    public init(
        totalTokens: Int,
        requestCount: Int,
        totalCostUSD: Decimal?,
        costPerRequestUSD: Decimal?,
        tokensPerRequest: Double,
        outputTokenRatio: Double
    ) {
        self.totalTokens = max(totalTokens, 0)
        self.requestCount = max(requestCount, 0)
        self.totalCostUSD = totalCostUSD
        self.costPerRequestUSD = costPerRequestUSD
        self.tokensPerRequest = min(max(tokensPerRequest, 0), .greatestFiniteMagnitude)
        self.outputTokenRatio = min(max(outputTokenRatio, 0), 1)
    }

    public var hasAnyActivity: Bool {
        totalTokens > 0 || requestCount > 0
    }
}

public enum CostEfficiencyService {
    /// Computes per-request cost/token metrics over the provided events.
    ///
    /// `costPerRequestUSD` only considers events that carry a recorded cost,
    /// so a mix of priced and unpriced sources does not dilute the average.
    public static func summary(
        events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CostEfficiencySummary {
        let totalTokens = events.reduce(0) { $0 + $1.totalTokens }
        let requestCount = events.reduce(0) { $0 + $1.requestCount }
        let outputTokens = events.reduce(0) { $0 + $1.outputTokens }

        let costEvents = events.compactMap(\.estimatedCostUSD)
        let totalCost = costEvents.isEmpty ? nil : costEvents.reduce(Decimal(0), +)

        let costPerRequest: Decimal?
        if let totalCost, requestCount > 0 {
            let perRequest = totalCost / Decimal(requestCount)
            costPerRequest = perRequest
        } else {
            costPerRequest = nil
        }

        let tokensPerRequest = requestCount > 0 ? Double(totalTokens) / Double(requestCount) : 0
        let outputRatio = totalTokens > 0 ? Double(outputTokens) / Double(totalTokens) : 0

        return CostEfficiencySummary(
            totalTokens: totalTokens,
            requestCount: requestCount,
            totalCostUSD: totalCost,
            costPerRequestUSD: costPerRequest,
            tokensPerRequest: tokensPerRequest,
            outputTokenRatio: outputRatio
        )
    }
}
