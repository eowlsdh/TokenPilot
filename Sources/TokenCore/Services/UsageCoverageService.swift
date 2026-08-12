import Foundation

/// Data-coverage summary over the stored local usage history.
///
/// Mirrors toktrack's `audit` idea: it answers how much of the trailing
/// retention window actually has recorded local activity, so a user can see
/// holes left by providers that prune their own logs (Claude Code deletes
/// sessions after 30 days by default). All values describe local activity
/// only and never claim provider quota.
public struct UsageCoverageSummary: Equatable, Sendable {
    /// Trailing window size in days that the coverage is measured against.
    public let windowDays: Int
    /// Number of distinct active days inside the window.
    public let activeDays: Int
    /// Date of the oldest stored event (start of its day), nil when empty.
    public let oldestEventDay: Date?
    /// Date of the newest stored event (start of its day), nil when empty.
    public let newestEventDay: Date?
    /// Count of gap runs (runs of >= 1 consecutive inactive days) inside the window.
    public let gapRunCount: Int
    /// Longest consecutive inactive-day run inside the window.
    public let longestGapDays: Int

    public init(
        windowDays: Int,
        activeDays: Int,
        oldestEventDay: Date?,
        newestEventDay: Date?,
        gapRunCount: Int,
        longestGapDays: Int
    ) {
        self.windowDays = max(windowDays, 1)
        self.activeDays = max(activeDays, 0)
        self.oldestEventDay = oldestEventDay
        self.newestEventDay = newestEventDay
        self.gapRunCount = max(gapRunCount, 0)
        self.longestGapDays = max(longestGapDays, 0)
    }

    /// Fraction of window days with recorded activity (0...1).
    public var coverageRatio: Double {
        Double(activeDays) / Double(windowDays)
    }
}

public enum UsageCoverageService {
    /// Computes coverage over the trailing `windowDays` ending today.
    ///
    /// A day is active when it has at least one stored event with tokens or
    /// requests. `calendar` drives day bucketing; pass a fixed calendar in
    /// tests so results are deterministic.
    public static func coverage(
        events: [UsageEvent],
        windowDays: Int = 45,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageCoverageSummary {
        let window = max(windowDays, 1)
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(window - 1), to: startOfToday) ?? startOfToday

        let activeDays = Set(
            events
                .filter { $0.totalTokens > 0 || $0.requestCount > 0 }
                .map { calendar.startOfDay(for: $0.timestamp) }
        )

        guard !activeDays.isEmpty else {
            return UsageCoverageSummary(
                windowDays: window,
                activeDays: 0,
                oldestEventDay: nil,
                newestEventDay: nil,
                gapRunCount: 0,
                longestGapDays: 0
            )
        }

        let orderedActive = activeDays.sorted()
        let oldest = orderedActive.first
        let newest = orderedActive.last

        var gapRunCount = 0
        var longestGap = 0
        var inGap = false
        var currentGap = 0
        for offset in 0..<window {
            let day = calendar.date(byAdding: .day, value: offset, to: windowStart) ?? startOfToday
            if activeDays.contains(day) {
                if inGap {
                    gapRunCount += 1
                    longestGap = max(longestGap, currentGap)
                    currentGap = 0
                    inGap = false
                }
            } else {
                inGap = true
                currentGap += 1
            }
        }
        if inGap {
            gapRunCount += 1
            longestGap = max(longestGap, currentGap)
        }

        return UsageCoverageSummary(
            windowDays: window,
            activeDays: activeDays.count,
            oldestEventDay: oldest,
            newestEventDay: newest,
            gapRunCount: gapRunCount,
            longestGapDays: longestGap
        )
    }
}
