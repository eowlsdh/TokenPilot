import Foundation

public struct DailyGoalProgress: Equatable, Sendable {
    public let tokens: Int
    public let targetTokens: Int
    public let percent: Int

    public init(tokens: Int, targetTokens: Int, percent: Int) {
        self.tokens = max(tokens, 0)
        self.targetTokens = max(targetTokens, 1)
        self.percent = min(max(percent, 0), 100)
    }
}

public enum DailyGoalService {
    public static func progress(tokens: Int, targetTokens: Int) -> DailyGoalProgress {
        let target = max(targetTokens, 1)
        let percent = tokens > 0
            ? min(Int((Double(tokens) / Double(target) * 100).rounded()), 100)
            : 0
        return DailyGoalProgress(tokens: tokens, targetTokens: target, percent: percent)
    }
}
