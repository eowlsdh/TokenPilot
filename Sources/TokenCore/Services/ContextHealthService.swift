import Foundation

/// Health classification for a context-window usage observation.
///
/// Benchmarked against budi's context-bloat detection: the level describes how
/// full the context window is, and a fast-filling flag marks windows that grew
/// quickly between the two most recent observations. All values are
/// local-activity signals, never provider quota.
public enum ContextHealthLevel: String, Equatable, Sendable {
    /// Below 50% used.
    case healthy
    /// 50...79% used.
    case elevated
    /// 80%+ used.
    case bloat
}

public struct ContextHealthAssessment: Equatable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue).\(seriesKey)" }
    public let provider: Provider
    public let seriesKey: String
    public let usedPercent: Int?
    public let level: ContextHealthLevel
    /// Percentage-point change between the two most recent observations (latest - previous).
    public let recentDelta: Int?
    public let observedAt: Date?

    public init(
        provider: Provider,
        seriesKey: String,
        usedPercent: Int?,
        level: ContextHealthLevel,
        recentDelta: Int?,
        observedAt: Date?
    ) {
        self.provider = provider
        self.seriesKey = seriesKey
        self.usedPercent = usedPercent
        self.level = level
        self.recentDelta = recentDelta
        self.observedAt = observedAt
    }

    /// True when the window grew by at least 10 points between the last two readings.
    public var isFillingFast: Bool {
        guard let recentDelta else { return false }
        return recentDelta >= 10
    }
}

public struct ContextHealthService: Sendable {
    public init() {}

    /// Assesses the latest context-percent observation per provider.
    ///
    /// Only `kind == .context` observations with a percent value are
    /// considered. The level uses the latest reading; `recentDelta` compares
    /// the two most recent readings for the same series.
    public func assess(
        records: [CapacityEvidenceRecord],
        now: Date = Date()
    ) -> [ContextHealthAssessment] {
        let contextRecords = records.filter { record in
            record.seriesID.kind == .context &&
            record.value.unit == .percent &&
            record.value.usedPercent != nil
        }
        let bySeries = Dictionary(grouping: contextRecords) { record in
            record.seriesID.providerWindowID.isEmpty
                ? "\(record.seriesID.provider.rawValue)"
                : "\(record.seriesID.provider.rawValue).\(record.seriesID.providerWindowID)"
        }

        return bySeries.keys.sorted().compactMap { key in
            let seriesRecords = bySeries[key] ?? []
            let sorted = seriesRecords.sorted { $0.observedAt < $1.observedAt }
            guard let latest = sorted.last else { return nil }
            let provider = latest.seriesID.provider
            let usedPercent = latest.value.usedPercent
            let level: ContextHealthLevel
            if let usedPercent {
                switch usedPercent {
                case ..<50: level = .healthy
                case ..<80: level = .elevated
                default: level = .bloat
                }
            } else {
                level = .healthy
            }

            var delta: Int?
            if sorted.count >= 2 {
                let previous = sorted[sorted.count - 2]
                if let current = usedPercent, let previousPercent = previous.value.usedPercent {
                    delta = current - previousPercent
                }
            }

            return ContextHealthAssessment(
                provider: provider,
                seriesKey: key,
                usedPercent: usedPercent,
                level: level,
                recentDelta: delta,
                observedAt: latest.observedAt
            )
        }
    }
}
