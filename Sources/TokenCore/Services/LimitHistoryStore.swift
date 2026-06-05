import Foundation
import os

public final class LimitHistoryStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let defaults: UserDefaults
    private let key: String
    private let maxAge: TimeInterval
    private let maxSamples: Int
    private let bucketSeconds: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "tokenPilot.limitSamples.v1",
        maxAgeDays: Int = 45,
        maxSamples: Int = 2_000,
        bucketSeconds: TimeInterval = 300
    ) {
        self.defaults = defaults
        self.key = key
        self.maxAge = TimeInterval(max(maxAgeDays, 1) * 24 * 60 * 60)
        self.maxSamples = max(maxSamples, 1)
        self.bucketSeconds = max(bucketSeconds, 60)
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    public func record(
        snapshots: [ProviderSnapshot],
        enabledProviders: Set<Provider>,
        referenceDate: Date = Date()
    ) -> [ProviderLimitSample] {
        lock.withLock {
            let incoming = snapshots
                .filter { enabledProviders.contains($0.provider) && $0.dataSource != .mock }
                .flatMap { samples(from: $0, referenceDate: referenceDate) }

            guard !incoming.isEmpty else {
                let retained = capped(pruned(loadSamplesUnlocked(), now: referenceDate).sorted { lhs, rhs in
                    if lhs.timestamp == rhs.timestamp {
                        return sortRank(lhs.window) < sortRank(rhs.window)
                    }
                    return lhs.timestamp < rhs.timestamp
                })
                saveUnlocked(retained)
                return retained
            }

            let merged = deduplicated(loadSamplesUnlocked() + incoming)
            let retained = capped(pruned(merged, now: referenceDate).sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return sortRank(lhs.window) < sortRank(rhs.window)
                }
                return lhs.timestamp < rhs.timestamp
            })
            saveUnlocked(retained)
            return retained
        }
    }

    public func samples(
        period: HistoryPeriod,
        enabledProviders: Set<Provider>,
        referenceDate: Date = Date()
    ) -> [ProviderLimitSample] {
        lock.withLock {
            filter(loadSamplesUnlocked(), period: period, enabledProviders: enabledProviders, referenceDate: referenceDate)
        }
    }

    public func loadSamples() -> [ProviderLimitSample] {
        lock.withLock {
            loadSamplesUnlocked()
        }
    }

    public func clear() {
        lock.withLock {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Internal (callers must hold lock)

    private func loadSamplesUnlocked() -> [ProviderLimitSample] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode([ProviderLimitSample].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveUnlocked(_ samples: [ProviderLimitSample]) {
        guard let data = try? encoder.encode(samples) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: - Private helpers (pure computation, no I/O)

    private func samples(from snapshot: ProviderSnapshot, referenceDate: Date) -> [ProviderLimitSample] {
        let timestamp = min(snapshot.updatedAt, referenceDate.addingTimeInterval(60))
        var samples: [ProviderLimitSample] = []
        if let fiveHour = snapshot.fiveHour,
           let usedPercent = fiveHour.usedPercent,
           let remainingPercent = fiveHour.remainingPercent {
            samples.append(sample(from: snapshot, window: .fiveHour, usedPercent: usedPercent, remainingPercent: remainingPercent, confidence: fiveHour.confidence, timestamp: timestamp))
        }
        if let weekly = snapshot.weekly,
           let usedPercent = weekly.usedPercent,
           let remainingPercent = weekly.remainingPercent {
            samples.append(sample(from: snapshot, window: .weekly, usedPercent: usedPercent, remainingPercent: remainingPercent, confidence: weekly.confidence, timestamp: timestamp))
        }
        if let dailyRequestsPercent = snapshot.dailyRequestsPercent {
            samples.append(sample(from: snapshot, window: .dailyRequests, usedPercent: dailyRequestsPercent, remainingPercent: min(max(100 - dailyRequestsPercent, 0), 100), confidence: snapshot.confidence, timestamp: timestamp))
        }
        return samples
    }

    private func sample(
        from snapshot: ProviderSnapshot,
        window: LimitWindowKind,
        usedPercent: Int,
        remainingPercent: Int,
        confidence: DataConfidence,
        timestamp: Date
    ) -> ProviderLimitSample {
        ProviderLimitSample(
            provider: snapshot.provider,
            timestamp: timestamp,
            window: window,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            confidence: confidence,
            source: snapshot.dataSource.rawValue,
            totalTokens: nil
        )
    }

    private func filter(
        _ samples: [ProviderLimitSample],
        period: HistoryPeriod,
        enabledProviders: Set<Provider>,
        referenceDate: Date
    ) -> [ProviderLimitSample] {
        let start = startDate(for: period, referenceDate: referenceDate)
        return samples
            .filter { enabledProviders.contains($0.provider) && $0.timestamp >= start && $0.timestamp <= referenceDate.addingTimeInterval(60) }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return sortRank(lhs.window) < sortRank(rhs.window)
                }
                return lhs.timestamp > rhs.timestamp
            }
    }

    private func startDate(for period: HistoryPeriod, referenceDate: Date) -> Date {
        let calendar = Calendar.current
        switch period {
        case .today:
            return calendar.startOfDay(for: referenceDate)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: referenceDate)) ?? referenceDate
        case .thisMonth:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) ?? calendar.startOfDay(for: referenceDate)
        }
    }

    private func pruned(_ samples: [ProviderLimitSample], now: Date) -> [ProviderLimitSample] {
        let cutoff = now.addingTimeInterval(-maxAge)
        return samples.filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(60) }
    }

    private func deduplicated(_ samples: [ProviderLimitSample]) -> [ProviderLimitSample] {
        var latestByKey: [String: ProviderLimitSample] = [:]
        for sample in samples {
            latestByKey[sampleKey(sample)] = sample
        }
        return Array(latestByKey.values)
    }

    private func capped(_ samples: [ProviderLimitSample]) -> [ProviderLimitSample] {
        guard samples.count > maxSamples else { return samples }
        return Array(samples.suffix(maxSamples))
    }

    private func sampleKey(_ sample: ProviderLimitSample) -> String {
        let bucket = Int(sample.timestamp.timeIntervalSince1970 / bucketSeconds)
        return [
            sample.provider.rawValue,
            sample.window.rawValue,
            String(bucket)
        ].joined(separator: "|")
    }

    private func sortRank(_ window: LimitWindowKind) -> Int {
        switch window {
        case .weekly: return 0
        case .fiveHour: return 1
        case .dailyRequests: return 2
        }
    }
}
