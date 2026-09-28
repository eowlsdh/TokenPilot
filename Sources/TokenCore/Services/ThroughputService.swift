import Foundation

/// Token burn-rate over a trailing window of stored local activity.
///
/// Benchmarked against TokenBar's live tokens-per-minute throughput. The rate
/// is computed from how many tokens were burned in the recent window and how
/// much of that window has elapsed, so it is only meaningful once the window
/// has accumulated enough activity. Always an estimate over local activity and
/// must never be presented as provider quota.
public struct ThroughputReading: Equatable, Sendable {
    /// Tokens burned per minute over the window (0 when no window elapsed).
    public let tokensPerMinute: Double
    /// Tokens burned in the window.
    public let windowTokens: Int
    /// Window length in minutes.
    public let windowMinutes: Int
    /// True when at least one token was burned in the window.
    public let hasActivity: Bool

    public init(tokensPerMinute: Double, windowTokens: Int, windowMinutes: Int, hasActivity: Bool) {
        self.tokensPerMinute = max(tokensPerMinute, 0)
        self.windowTokens = max(windowTokens, 0)
        self.windowMinutes = max(windowMinutes, 0)
        self.hasActivity = hasActivity
    }
}

public struct ThroughputService: Sendable {
    public init() {}

    /// Computes the burn rate over the trailing `windowMinutes` ending now.
    ///
    /// Only events with a non-zero total token count contribute. The rate uses
    /// the actual elapsed window time clamped to the window length, so a short
    /// history yields a proportionally higher per-minute rate rather than a
    /// misleading zero.
    public func reading(
        events: [UsageEvent],
        windowMinutes: Int = 60,
        now: Date = Date()
    ) -> ThroughputReading {
        let window = max(windowMinutes, 1)
        let cutoff = now.addingTimeInterval(-Double(window) * 60)
        let windowEvents = events.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
        let windowTokens = windowEvents.reduce(0) { $0 + $1.totalTokens }
        guard windowTokens > 0 else {
            return ThroughputReading(tokensPerMinute: 0, windowTokens: 0, windowMinutes: window, hasActivity: false)
        }

        // Use the oldest event as the actual window start so the rate reflects
        // real burn history, clamped to the configured window length.
        let oldest = windowEvents.map(\.timestamp).min() ?? cutoff
        let elapsedMinutes = min(max(now.timeIntervalSince(oldest) / 60, 1), Double(window))
        let perMinute = Double(windowTokens) / elapsedMinutes

        return ThroughputReading(
            tokensPerMinute: perMinute,
            windowTokens: windowTokens,
            windowMinutes: window,
            hasActivity: true
        )
    }
}
