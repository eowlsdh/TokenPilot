import Foundation

/// Decides whether waking from sleep should trigger an immediate provider refresh.
///
/// Benchmarked against the wake-from-sleep auto refresh in Claude Usage Tracker.
/// A repeating `Timer` does not fire while the Mac sleeps, so after a lid open
/// the menu bar keeps showing a percentage and a reset countdown captured before
/// sleep until the next tick lands. Refreshing on wake closes that window, and
/// the debounce keeps a short sleep — or the several wake notifications macOS can
/// post for one wake — from stacking refreshes on top of a just-finished one.
public enum WakeRefreshGate {
    /// Minimum age of the last completed refresh before a wake refresh is worth running.
    public static let minimumInterval: TimeInterval = 30

    public static func shouldRefresh(
        lastRefreshFinishedAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = minimumInterval
    ) -> Bool {
        guard let lastRefreshFinishedAt else { return true }
        let elapsed = now.timeIntervalSince(lastRefreshFinishedAt)
        // A negative elapsed time means the clock moved backwards (sleep across a
        // time change); the stored data is not trustworthy as "recent", so refresh.
        guard elapsed >= 0 else { return true }
        return elapsed >= minimumInterval
    }
}
