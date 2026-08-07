import Foundation

/// A burn-rate projection for a percent-denominated capacity window.
///
/// Unlike provider-reported values, this is an estimate derived from how quickly the window
/// has been consumed so far. It is never presented as official quota and is always labeled
/// `est.` in UI copy.
public struct CapacityPaceProjection: Equatable, Sendable {
    public let usedPercent: Int
    public let remainingPercent: Int
    /// Consumed percent per full hour, computed from the observation's elapsed window time.
    public let percentPerHour: Double
    /// Hours until the window reaches 100% at the current burn rate.
    public let hoursUntilExhaustion: Double
    public let estimatedExhaustionAt: Date

    public init(
        usedPercent: Int,
        remainingPercent: Int,
        percentPerHour: Double,
        hoursUntilExhaustion: Double,
        estimatedExhaustionAt: Date
    ) {
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.percentPerHour = percentPerHour
        self.hoursUntilExhaustion = hoursUntilExhaustion
        self.estimatedExhaustionAt = estimatedExhaustionAt
    }
}

/// Computes a rough burn-rate projection for capacity observations that carry a reset window.
///
/// Only `percent`-unit observations with a positive `durationMinutes` and a future `resetAt`
/// are projected. The projection is based on the share of the rolling window that has already
/// elapsed, so it is only meaningful while the observation is fresh and the window is partially
/// consumed. All results are estimates and must be labeled as such in the UI.
public struct CapacityPaceService: Sendable {
    public init() {}

    /// Returns a projection when the observation supports burn-rate estimation, otherwise nil.
    ///
    /// Estimation is skipped when:
    /// - the observation is not percent-denominated or lacks a duration/reset,
    /// - the window has not started yet (resetAt in the past would mean the window elapsed),
    /// - the observed usage is zero or the window is already exhausted,
    /// - the elapsed time is too small to produce a stable rate (< 5 minutes).
    public func projection(
        observation: CapacityObservation,
        now: Date = Date()
    ) -> CapacityPaceProjection? {
        guard observation.value.kind == .percent,
              let usedPercent = observation.value.usedPercent,
              let resetAt = observation.resetAt,
              let durationMinutes = observation.seriesID.durationMinutes,
              durationMinutes > 0,
              observation.seriesID.supportsReset,
              usedPercent > 0,
              usedPercent < 100,
              resetAt > now else {
            return nil
        }

        let windowStart = resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
        let elapsedSeconds = now.timeIntervalSince(windowStart)
        // Require a minimum window elapsed time so the rate is not a wild extrapolation.
        guard elapsedSeconds >= 5 * 60 else { return nil }

        let elapsedHours = elapsedSeconds / 3600
        let percentPerHour = Double(usedPercent) / elapsedHours
        guard percentPerHour > 0, percentPerHour.isFinite else { return nil }

        let remaining = 100 - usedPercent
        let hoursUntilExhaustion = Double(remaining) / percentPerHour
        guard hoursUntilExhaustion > 0, hoursUntilExhaustion.isFinite else { return nil }

        return CapacityPaceProjection(
            usedPercent: usedPercent,
            remainingPercent: remaining,
            percentPerHour: percentPerHour,
            hoursUntilExhaustion: hoursUntilExhaustion,
            estimatedExhaustionAt: now.addingTimeInterval(hoursUntilExhaustion * 3600)
        )
    }
}
