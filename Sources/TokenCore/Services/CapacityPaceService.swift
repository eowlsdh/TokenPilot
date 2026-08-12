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

/// A human-readable burn-rate zone for a capacity window, benchmarked against the
/// sustainable rate that would exactly exhaust the window at its reset moment.
///
/// Mirrors the pacing vocabulary used by desktop quota monitors (safe / steady / hot):
/// the actual burn rate is compared with the rate needed to hit 0% exactly at `resetAt`.
public enum CapacityPacingZone: String, Equatable, Sendable, CaseIterable {
    /// Actual burn is well under the sustainable rate; exhaustion is projected far past reset.
    case safe
    /// Actual burn is between half and the full sustainable rate; on track to reset with headroom.
    case steady
    /// Actual burn is at or above the sustainable rate; exhaustion is projected before reset.
    case hot
}

/// Result of comparing a capacity window's actual burn rate with its sustainable rate.
public struct CapacityPacingZoneAssessment: Equatable, Sendable {
    public let zone: CapacityPacingZone
    /// `percentPerHour / sustainablePercentPerHour`; >= 1 means exhaustion before reset.
    public let burnRatio: Double
    /// Hours remaining until the window resets.
    public let hoursUntilReset: Double

    public init(zone: CapacityPacingZone, burnRatio: Double, hoursUntilReset: Double) {
        self.zone = zone
        self.burnRatio = burnRatio
        self.hoursUntilReset = hoursUntilReset
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

    /// Compares the actual burn rate against the sustainable rate for the remaining window.
    ///
    /// The sustainable rate is the percent-per-hour pace that would reach 0% exactly at
    /// `resetAt`. A burn ratio >= 1 means the window is projected to exhaust before it
    /// resets. Returns nil whenever `projection(observation:now:)` returns nil.
    public func pacingZone(
        observation: CapacityObservation,
        now: Date = Date()
    ) -> CapacityPacingZoneAssessment? {
        guard let projection = projection(observation: observation, now: now),
              let resetAt = observation.resetAt else {
            return nil
        }
        let hoursUntilReset = resetAt.timeIntervalSince(now) / 3600
        guard hoursUntilReset > 0 else { return nil }
        let sustainableRate = Double(projection.remainingPercent) / hoursUntilReset
        guard sustainableRate > 0, sustainableRate.isFinite else { return nil }
        let burnRatio = projection.percentPerHour / sustainableRate

        let zone: CapacityPacingZone
        switch burnRatio {
        case 1.0...:
            zone = .hot
        case 0.5..<1.0:
            zone = .steady
        default:
            zone = .safe
        }
        return CapacityPacingZoneAssessment(
            zone: zone,
            burnRatio: burnRatio,
            hoursUntilReset: hoursUntilReset
        )
    }
}
