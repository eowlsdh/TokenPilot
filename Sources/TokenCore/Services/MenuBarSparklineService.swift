import Foundation

public enum MenuBarSparklineService {
    private static let retentionDays: TimeInterval = 45 * 24 * 60 * 60

    /// Normalized remaining-percent trend (0...1, oldest first) for a provider's menu bar segment.
    ///
    /// Returns an empty array unless at least two samples exist, so callers never render a
    /// degenerate one-point sparkline. `window` narrows samples to one limit window kind; nil
    /// accepts every window for the provider.
    public static func normalizedValues(
        samples: [ProviderLimitSample],
        provider: Provider,
        window: LimitWindowKind? = nil,
        maxCount: Int = 24,
        now: Date = Date()
    ) -> [Double] {
        let cutoff = now.addingTimeInterval(-retentionDays)
        let filtered = samples
            .filter { $0.provider == provider && $0.timestamp >= cutoff }
            .filter { window == nil || $0.window == window }
            .sorted { $0.timestamp < $1.timestamp }
        let recent = filtered.suffix(max(maxCount, 2))
        let values = recent.map {
            Double(min(max($0.remainingPercent, 0), 100)) / 100.0
        }
        return values.count >= 2 ? Array(values) : []
    }

    /// Maps a menu bar candidate seriesID (for example "claude/five-hour") to the limit window
    /// kind used by stored samples, so the trend and the displayed value describe the same window.
    public static func windowKind(forSeriesID seriesID: String) -> LimitWindowKind? {
        guard let windowID = seriesID.split(separator: "/").last else { return nil }
        switch windowID {
        case "five-hour":
            return .fiveHour
        case "seven-day":
            return .weekly
        case "monthly":
            return .monthly
        case "daily-requests":
            return .dailyRequests
        default:
            return nil
        }
    }
}
