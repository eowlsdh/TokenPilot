import Foundation

/// A milestone dimension tracked over stored local activity.
public enum MilestoneDimension: String, Codable, CaseIterable, Sendable {
    case lifetimeTokens
    case activeDays
    case totalRequests
    case longestStreak
}

/// One achieved milestone.
public struct ActivityMilestone: Equatable, Sendable, Identifiable {
    public let dimension: MilestoneDimension
    /// The threshold that was reached (tokens, days, requests, or streak days).
    public let threshold: Int

    public init(dimension: MilestoneDimension, threshold: Int) {
        self.dimension = dimension
        self.threshold = max(threshold, 0)
    }

    public var id: String { "\(dimension.rawValue).\(threshold)" }
}

/// Computes achieved usage milestones over stored local activity.
///
/// Benchmarked against TokenTracker's achievement tracks. Milestones are
/// display-only aggregates over local activity and must never be presented as
/// provider quota. Because the store retains only recent events, lifetime
/// numbers reflect the retained window, not the full provider history.
public struct ActivityMilestoneService: Sendable {
    public let lifetimeTokenThresholds: [Int]
    public let activeDayThresholds: [Int]
    public let requestThresholds: [Int]
    public let streakThresholds: [Int]

    public init(
        lifetimeTokenThresholds: [Int] = [100_000, 500_000, 1_000_000, 5_000_000, 10_000_000],
        activeDayThresholds: [Int] = [10, 30, 90, 180],
        requestThresholds: [Int] = [100, 1_000, 5_000, 10_000],
        streakThresholds: [Int] = [3, 7, 14, 30]
    ) {
        self.lifetimeTokenThresholds = lifetimeTokenThresholds
        self.activeDayThresholds = activeDayThresholds
        self.requestThresholds = requestThresholds
        self.streakThresholds = streakThresholds
    }

    public func achievedMilestones(
        events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ActivityMilestone] {
        // A milestone celebrates work done, and cache reads are context being re-sent: counting
        // them handed out every token milestone on day one.
        let totalTokens = events.reduce(0) { $0 + $1.workingTokens }
        let totalRequests = events.reduce(0) { $0 + $1.requestCount }
        let streak = UsageStreakService.streak(events: events, now: now, calendar: calendar)
        let activeDays = Set(
            events
                .filter { $0.totalTokens > 0 || $0.requestCount > 0 }
                .map { calendar.startOfDay(for: $0.timestamp) }
        ).count

        var milestones: [ActivityMilestone] = []
        for threshold in lifetimeTokenThresholds where totalTokens >= threshold {
            milestones.append(ActivityMilestone(dimension: .lifetimeTokens, threshold: threshold))
        }
        for threshold in activeDayThresholds where activeDays >= threshold {
            milestones.append(ActivityMilestone(dimension: .activeDays, threshold: threshold))
        }
        for threshold in requestThresholds where totalRequests >= threshold {
            milestones.append(ActivityMilestone(dimension: .totalRequests, threshold: threshold))
        }
        for threshold in streakThresholds where streak.longestDays >= threshold {
            milestones.append(ActivityMilestone(dimension: .longestStreak, threshold: threshold))
        }
        return milestones.sorted { $0.dimension.rawValue < $1.dimension.rawValue || ($0.dimension == $1.dimension && $0.threshold < $1.threshold) }
    }
}
