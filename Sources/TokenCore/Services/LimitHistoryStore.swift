import Foundation
import os

public protocol LimitHistoryLegacyWritePolicy: Sendable {
    func legacyLimitHistoryWritesAllowed() -> Bool
    func legacyLimitHistoryWriteStatus() -> CapacityPersistenceStatus
}

public extension LimitHistoryLegacyWritePolicy {
    func legacyLimitHistoryWriteStatus() -> CapacityPersistenceStatus {
        legacyLimitHistoryWritesAllowed()
            ? .ready(source: .absentDefault, generation: nil)
            : .ready(source: .primary, generation: nil)
    }
}

public struct CapacityLegacyLimitHistoryWritePolicy: LimitHistoryLegacyWritePolicy, Sendable {
    private let markerURL: URL
    private let fileSystem: any CapacityEvidenceFileSystem

    public init(directory: URL? = nil, fileName: String = "capacity-evidence-v2.json", fileSystem: any CapacityEvidenceFileSystem = LocalCapacityEvidenceFileSystem()) {
        let directory = directory ?? CapacityEvidenceStore.defaultDirectory()
        self.markerURL = directory.appendingPathComponent("\(fileName).legacy-migration-marker")
        self.fileSystem = fileSystem
    }

    public func committedMigrationMarker() -> CapacityLegacyMigrationMarker? {
        guard fileSystem.fileExists(at: markerURL),
              let data = try? fileSystem.readData(at: markerURL) else {
            return nil
        }
        return validCommittedMarker(from: data)
    }

    public func legacyLimitHistoryWriteStatus() -> CapacityPersistenceStatus {
        guard fileSystem.fileExists(at: markerURL) else {
            return .ready(source: .absentDefault, generation: nil)
        }
        guard let data = try? fileSystem.readData(at: markerURL),
              let marker = validCommittedMarker(from: data) else {
            return .recoveryRequired(writeBlocked: true, code: "legacyMigrationMarkerRecoveryRequired")
        }
        return .ready(source: .primary, generation: marker.committedGeneration)
    }

    public func legacyLimitHistoryWritesAllowed() -> Bool {
        guard case let .ready(source, _) = legacyLimitHistoryWriteStatus() else { return false }
        return source == .absentDefault
    }

    private func validCommittedMarker(from data: Data) -> CapacityLegacyMigrationMarker? {
        guard let marker = try? JSONDecoder().decode(CapacityLegacyMigrationMarker.self, from: data),
              marker.committedGeneration > 0,
              !marker.sourceDigest.isEmpty else {
            return nil
        }
        return marker
    }
}

public struct LimitHistorySamplesResult: Equatable, Sendable {
    public let samples: [ProviderLimitSample]
    public let recoveryStatus: CapacityPersistenceStatus

    public init(samples: [ProviderLimitSample], recoveryStatus: CapacityPersistenceStatus) {
        self.samples = samples
        self.recoveryStatus = recoveryStatus
    }
}

public final class LimitHistoryStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let defaults: UserDefaults
    private let key: String
    private let maxAge: TimeInterval
    private let maxSamples: Int
    private let bucketSeconds: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let legacyWritePolicy: any LimitHistoryLegacyWritePolicy

    public init(
        defaults: UserDefaults = .standard,
        key: String = "tokenPilot.limitSamples.v1",
        maxAgeDays: Int = 45,
        maxSamples: Int = 2_000,
        bucketSeconds: TimeInterval = 300,
        legacyWritePolicy: any LimitHistoryLegacyWritePolicy = CapacityLegacyLimitHistoryWritePolicy()
    ) {
        self.defaults = defaults
        self.key = key
        self.maxAge = TimeInterval(max(maxAgeDays, 1) * 24 * 60 * 60)
        self.maxSamples = max(maxSamples, 1)
        self.bucketSeconds = max(bucketSeconds, 60)
        encoder.outputFormatting = [.sortedKeys]
        self.legacyWritePolicy = legacyWritePolicy
    }

    @discardableResult
    public func record(
        snapshots: [ProviderSnapshot],
        enabledProviders: Set<Provider>,
        referenceDate: Date = Date()
    ) -> [ProviderLimitSample] {
        recordWithRecoveryStatus(snapshots: snapshots, enabledProviders: enabledProviders, referenceDate: referenceDate).samples
    }

    @discardableResult
    public func recordWithRecoveryStatus(
        snapshots: [ProviderSnapshot],
        enabledProviders: Set<Provider>,
        referenceDate: Date = Date()
    ) -> LimitHistorySamplesResult {
        lock.withLock {
            let policyStatus = legacyWritePolicy.legacyLimitHistoryWriteStatus()
            let loaded = loadSamplesWithRecoveryStatusUnlocked()
            guard legacyWritePolicy.legacyLimitHistoryWritesAllowed() else {
                return LimitHistorySamplesResult(samples: loaded.samples, recoveryStatus: policyStatus)
            }
            guard !loaded.recoveryStatus.writeBlocked else {
                return loaded
            }

            let incoming = snapshots
                .filter { enabledProviders.contains($0.provider) && $0.dataSource != .mock }
                .flatMap { samples(from: $0, referenceDate: referenceDate) }

            guard !incoming.isEmpty else {
                let retained = capped(pruned(loaded.samples, now: referenceDate).sorted { lhs, rhs in
                    if lhs.timestamp == rhs.timestamp {
                        return sortRank(lhs.window) < sortRank(rhs.window)
                    }
                    return lhs.timestamp < rhs.timestamp
                })
                guard retained != loaded.samples else {
                    return LimitHistorySamplesResult(samples: retained, recoveryStatus: loaded.recoveryStatus)
                }
                let status = saveUnlocked(retained)
                return LimitHistorySamplesResult(samples: retained, recoveryStatus: status)
            }

            let merged = deduplicated(loaded.samples + incoming)
            let retained = capped(pruned(merged, now: referenceDate).sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return sortRank(lhs.window) < sortRank(rhs.window)
                }
                return lhs.timestamp < rhs.timestamp
            })
            let status = saveUnlocked(retained)
            return LimitHistorySamplesResult(samples: retained, recoveryStatus: status)
        }
    }

    public func samples(
        period: HistoryPeriod,
        enabledProviders: Set<Provider>,
        referenceDate: Date = Date()
    ) -> [ProviderLimitSample] {
        samplesWithRecoveryStatus(period: period, enabledProviders: enabledProviders, referenceDate: referenceDate).samples
    }

    public func samplesWithRecoveryStatus(
        period: HistoryPeriod,
        enabledProviders: Set<Provider>,
        referenceDate: Date = Date()
    ) -> LimitHistorySamplesResult {
        lock.withLock {
            let loaded = loadSamplesWithRecoveryStatusUnlocked()
            return LimitHistorySamplesResult(
                samples: filter(loaded.samples, period: period, enabledProviders: enabledProviders, referenceDate: referenceDate),
                recoveryStatus: loaded.recoveryStatus
            )
        }
    }

    public func loadSamples() -> [ProviderLimitSample] {
        loadSamplesWithRecoveryStatus().samples
    }

    public func loadSamplesWithRecoveryStatus() -> LimitHistorySamplesResult {
        lock.withLock {
            loadSamplesWithRecoveryStatusUnlocked()
        }
    }

    @discardableResult
    public func clearWithRecoveryStatus() -> CapacityPersistenceStatus {
        lock.withLock {
            let policyStatus = legacyWritePolicy.legacyLimitHistoryWriteStatus()
            guard legacyWritePolicy.legacyLimitHistoryWritesAllowed() else { return policyStatus }
            let loaded = loadSamplesWithRecoveryStatusUnlocked()
            guard !loaded.recoveryStatus.writeBlocked else { return loaded.recoveryStatus }
            defaults.removeObject(forKey: key)
            return .ready(source: .empty, generation: nil)
        }
    }

    public func clear() {
        _ = clearWithRecoveryStatus()
    }

    // MARK: - Internal (callers must hold lock)

    private func loadSamplesUnlocked() -> [ProviderLimitSample] {
        loadSamplesWithRecoveryStatusUnlocked().samples
    }

    private func loadSamplesWithRecoveryStatusUnlocked() -> LimitHistorySamplesResult {
        guard let object = defaults.object(forKey: key) else {
            return LimitHistorySamplesResult(samples: [], recoveryStatus: .ready(source: .absentDefault, generation: nil))
        }
        guard let data = object as? Data,
              let decoded = try? decoder.decode([ProviderLimitSample].self, from: data) else {
            return LimitHistorySamplesResult(samples: [], recoveryStatus: .recoveryRequired(writeBlocked: true, code: "legacyLimitHistoryRecoveryRequired"))
        }
        return LimitHistorySamplesResult(samples: decoded, recoveryStatus: .ready(source: .primary, generation: nil))
    }

    private func saveUnlocked(_ samples: [ProviderLimitSample]) -> CapacityPersistenceStatus {
        guard let data = try? encoder.encode(samples) else {
            return .recoveryRequired(writeBlocked: true, code: "legacyLimitHistoryCommitFailed")
        }
        defaults.set(data, forKey: key)
        return .ready(source: .primary, generation: nil)
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
        case .monthly: return 0
        case .weekly: return 1
        case .fiveHour: return 2
        case .dailyRequests: return 3
        }
    }
}
