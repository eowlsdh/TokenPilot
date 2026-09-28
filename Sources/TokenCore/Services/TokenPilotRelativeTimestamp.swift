import Foundation

/// Formats a "last updated" relative timestamp for display.
///
/// Pure and dependency-free (no UI, no bundle) so it is unit-testable in `TokenCore`.
/// Returns a localization key plus an optional integer argument; the caller maps the key
/// through its localizer and substitutes the integer with `String(format:)`.
public enum TokenPilotRelativeTimestamp {
    public struct Format: Equatable, Sendable {
        /// Localization key, e.g. `"Updated %d min ago"` or `"Updated just now"`.
        public let key: String
        /// Integer substitution for `%d`; nil for keys that have no placeholder.
        public let arg: Int?

        public init(key: String, arg: Int?) {
            self.key = key
            self.arg = arg
        }
    }

    /// Describes how long ago `lastUpdated` occurred relative to `now`.
    ///
    /// Returns nil when there is no recorded timestamp yet (nothing has ever been refreshed).
    /// Future timestamps (clock skew) are normalized to "just now" rather than a negative value.
    public static func format(from lastUpdated: Date?, now: Date) -> Format? {
        guard let lastUpdated else { return nil }
        let elapsed = max(now.timeIntervalSince(lastUpdated), 0)
        let minutes = Int(elapsed) / 60
        if minutes < 1 {
            return Format(key: "Updated just now", arg: nil)
        }
        if minutes < 60 {
            return Format(key: "Updated %d min ago", arg: minutes)
        }
        let hours = minutes / 60
        if hours < 24 {
            return Format(key: "Updated %d hr ago", arg: hours)
        }
        let days = hours / 24
        return Format(key: "Updated %d days ago", arg: days)
    }
}
