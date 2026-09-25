import Foundation

/// Consecutive-day usage streak over stored local activity.
///
/// A day counts as active when it has at least one `UsageEvent` with tokens or
/// requests in the stored local history. Streaks are display-only aggregates
/// over local activity and must never be presented as provider quota.
public struct UsageStreak: Equatable, Sendable {
    /// Consecutive active days ending today (or yesterday when today has no activity yet).
    public let currentDays: Int
    /// Longest consecutive active-day run found in the retained window.
    public let longestDays: Int
    /// First day of the current run, when it exists.
    public let currentStart: Date?
    /// First day of the longest run, when it exists.
    public let longestStart: Date?

    public init(
        currentDays: Int,
        longestDays: Int,
        currentStart: Date?,
        longestStart: Date?
    ) {
        self.currentDays = max(currentDays, 0)
        self.longestDays = max(longestDays, 0)
        self.currentStart = currentStart
        self.longestStart = longestStart
    }

    public var hasActivity: Bool { longestDays > 0 }
}

public enum UsageStreakService {
    /// Computes current and longest streaks over the provided events.
    ///
    /// `calendar` drives day bucketing; pass a fixed calendar in tests so the
    /// result is deterministic. Days are anchored to `startOfDay(for:)`.
    public static func streak(
        events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageStreak {
        let activeDays = Set(
            events
                .filter { $0.totalTokens > 0 || $0.requestCount > 0 }
                .map { calendar.startOfDay(for: $0.timestamp) }
        )
        guard !activeDays.isEmpty else {
            return UsageStreak(currentDays: 0, longestDays: 0, currentStart: nil, longestStart: nil)
        }

        let today = calendar.startOfDay(for: now)
        // A streak is "current" when it reaches today or, when today is still idle,
        // yesterday (so the run is not broken by a not-yet-started day).
        let currentAnchor = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)
        let ordered = activeDays.sorted()

        var currentDays = 0
        var currentStart: Date?
        if let anchor = currentAnchor, activeDays.contains(anchor) {
            var cursor = anchor
            var count = 0
            var start = anchor
            while activeDays.contains(cursor) {
                start = cursor
                count += 1
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }
            currentDays = count
            currentStart = start
        }

        var longestDays = 0
        var longestStart: Date?
        var runLength = 0
        var runStart = ordered[0]
        var previousDay = ordered[0]
        for day in ordered {
            if day == previousDay {
                runLength = 1
                runStart = day
            } else if let expected = calendar.date(byAdding: .day, value: 1, to: previousDay), day == expected {
                runLength += 1
            } else {
                if runLength > longestDays {
                    longestDays = runLength
                    longestStart = runStart
                }
                runLength = 1
                runStart = day
            }
            previousDay = day
        }
        if runLength > longestDays {
            longestDays = runLength
            longestStart = runStart
        }

        return UsageStreak(
            currentDays: currentDays,
            longestDays: longestDays,
            currentStart: currentStart,
            longestStart: longestStart
        )
    }
}
