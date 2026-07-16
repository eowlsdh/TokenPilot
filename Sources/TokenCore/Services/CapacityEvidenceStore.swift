import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

public protocol CapacityEvidenceClock: Sendable {
    var now: Date { get }
}

public struct SystemCapacityEvidenceClock: CapacityEvidenceClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}

public protocol CapacityEvidenceFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeDataExclusively(_ data: Data, to url: URL) throws
    func replaceItem(at target: URL, withItemAt source: URL) throws
    func copyItem(at source: URL, to target: URL) throws
    func removeItemIfExists(at url: URL) throws
    func createDirectory(at url: URL) throws
    func synchronizeFile(at url: URL) throws
    func synchronizeDirectory(at url: URL) throws
}

public final class LocalCapacityEvidenceFileSystem: CapacityEvidenceFileSystem, @unchecked Sendable {
    private let manager: FileManager

    public init(manager: FileManager = .default) {
        self.manager = manager
    }

    public func fileExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func writeDataExclusively(_ data: Data, to url: URL) throws {
        guard manager.createFile(atPath: url.path, contents: data) else {
            throw CocoaError(.fileWriteFileExists)
        }
    }

    public func replaceItem(at target: URL, withItemAt source: URL) throws {
        if manager.fileExists(atPath: target.path) {
            _ = try manager.replaceItemAt(target, withItemAt: source, backupItemName: nil, options: [])
        } else {
            try manager.moveItem(at: source, to: target)
        }
    }

    public func copyItem(at source: URL, to target: URL) throws {
        try manager.copyItem(at: source, to: target)
    }

    public func removeItemIfExists(at url: URL) throws {
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }

    public func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func synchronizeFile(at url: URL) throws {
        guard manager.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    public func synchronizeDirectory(at url: URL) throws {
        #if canImport(Darwin)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        _ = close(descriptor)
        #endif
    }
}

public enum CapacityPersistenceSource: String, Codable, Equatable, Sendable {
    case primary
    case backup
    case temp
    case legacy
    case empty
    case absentDefault
}

public enum CapacityPersistenceStatus: Equatable, Sendable {
    case ready(source: CapacityPersistenceSource, generation: Int?)
    case recoveryRequired(writeBlocked: Bool, code: String)

    public var writeBlocked: Bool {
        guard case let .recoveryRequired(writeBlocked, _) = self else { return false }
        return writeBlocked
    }

    public var recoveryRequired: Bool {
        guard case .recoveryRequired = self else { return false }
        return true
    }
}

public enum CapacityEvidenceRetention: String, Codable, CaseIterable, Sendable {
    case raw
    case dailyClosing
}

public struct CapacityEvidenceValue: Codable, Equatable, Sendable {
    public let unit: CapacityUnit
    public let usedPercent: Int?
    public let moneyAmount: Decimal?
    public let currency: String?
    public let count: Int?
    public let tokens: Int?

    public init(value: CapacityValue) {
        self.unit = value.kind
        self.usedPercent = value.usedPercent
        self.moneyAmount = value.moneyAmount
        self.currency = value.currency
        self.count = value.count
        self.tokens = value.tokens
    }

    public func capacityValue() throws -> CapacityValue {
        switch unit {
        case .percent:
            guard let usedPercent else { throw CapacityContractError.invalidValue }
            return try CapacityValue(usedPercent: usedPercent)
        case .currency:
            guard let moneyAmount, let currency else { throw CapacityContractError.invalidValue }
            return try CapacityValue(money: moneyAmount, currency: currency)
        case .requestCount:
            guard let count else { throw CapacityContractError.invalidValue }
            return try CapacityValue(count: count)
        case .tokens:
            guard let tokens else { throw CapacityContractError.invalidValue }
            return try CapacityValue(tokens: tokens)
        }
    }

    fileprivate var canonicalObject: [String: Any] {
        var object: [String: Any] = ["unit": unit.rawValue]
        switch unit {
        case .percent:
            object["usedPercent"] = usedPercent ?? 0
        case .currency:
            object["amount"] = CapacityCanonical.decimalString(moneyAmount ?? 0)
            object["currency"] = currency ?? ""
        case .requestCount:
            object["count"] = count ?? 0
        case .tokens:
            object["tokens"] = tokens ?? 0
        }
        return object
    }

    private enum CodingKeys: String, CodingKey {
        case unit
        case usedPercent
        case amount
        case currency
        case count
        case tokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unit = try container.decode(CapacityUnit.self, forKey: .unit)
        switch unit {
        case .percent:
            let usedPercent = try container.decode(Int.self, forKey: .usedPercent)
            guard (0...100).contains(usedPercent) else { throw CapacityContractError.invalidValue }
            self.usedPercent = usedPercent
            moneyAmount = nil
            currency = nil
            count = nil
            tokens = nil
        case .currency:
            let rawAmount = try container.decode(String.self, forKey: .amount)
            guard let amount = Decimal(string: rawAmount, locale: Locale(identifier: "en_US_POSIX")) else {
                throw CapacityContractError.invalidValue
            }
            let currency = try container.decode(String.self, forKey: .currency)
            _ = try CapacityValue(money: amount, currency: currency)
            usedPercent = nil
            moneyAmount = amount
            self.currency = currency
            count = nil
            tokens = nil
        case .requestCount:
            let count = try container.decode(Int.self, forKey: .count)
            guard count >= 0 else { throw CapacityContractError.invalidValue }
            usedPercent = nil
            moneyAmount = nil
            currency = nil
            self.count = count
            tokens = nil
        case .tokens:
            let tokens = try container.decode(Int.self, forKey: .tokens)
            guard tokens >= 0 else { throw CapacityContractError.invalidValue }
            usedPercent = nil
            moneyAmount = nil
            currency = nil
            count = nil
            self.tokens = tokens
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unit, forKey: .unit)
        switch unit {
        case .percent:
            guard let usedPercent, (0...100).contains(usedPercent) else { throw CapacityContractError.invalidValue }
            try container.encode(usedPercent, forKey: .usedPercent)
        case .currency:
            guard let moneyAmount, let currency else { throw CapacityContractError.invalidValue }
            _ = try CapacityValue(money: moneyAmount, currency: currency)
            try container.encode(CapacityCanonical.decimalString(moneyAmount), forKey: .amount)
            try container.encode(currency, forKey: .currency)
        case .requestCount:
            guard let count, count >= 0 else { throw CapacityContractError.invalidValue }
            try container.encode(count, forKey: .count)
        case .tokens:
            guard let tokens, tokens >= 0 else { throw CapacityContractError.invalidValue }
            try container.encode(tokens, forKey: .tokens)
        }
    }
}

public struct CapacityEvidenceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { recordDigest }
    public let recordDigest: String
    public let seriesID: CapacitySeriesID
    public let observedAt: Date
    public let resetAt: Date?
    public let cycleID: String?
    public let value: CapacityEvidenceValue
    public let authority: CapacityAuthority
    public let stability: CapacityStability
    public let consent: CapacityConsent
    public let freshnessPolicy: CapacityFreshnessPolicy
    public let comparability: CapacityComparability
    public let parserRevision: String
    public let retention: CapacityEvidenceRetention
    public let dayStart: Date?

    public init(observation: CapacityObservation, retention: CapacityEvidenceRetention = .raw, dayStart: Date? = nil) throws {
        self.seriesID = observation.seriesID
        self.observedAt = observation.observedAt
        self.resetAt = observation.resetAt
        self.cycleID = observation.cycleID
        self.value = CapacityEvidenceValue(value: observation.value)
        self.authority = observation.authority
        self.stability = observation.stability
        self.consent = observation.consent
        self.freshnessPolicy = observation.freshnessPolicy
        self.comparability = observation.comparability
        self.parserRevision = observation.parserRevision
        self.retention = retention
        self.dayStart = dayStart
        self.recordDigest = try Self.digest(
            seriesID: observation.seriesID,
            observedAt: observation.observedAt,
            resetAt: observation.resetAt,
            cycleID: observation.cycleID,
            value: CapacityEvidenceValue(value: observation.value),
            authority: observation.authority,
            stability: observation.stability,
            consent: observation.consent,
            freshnessPolicy: observation.freshnessPolicy,
            comparability: observation.comparability,
            parserRevision: observation.parserRevision,
            retention: retention,
            dayStart: dayStart
        )
    }

    private init(
        recordDigest: String,
        seriesID: CapacitySeriesID,
        observedAt: Date,
        resetAt: Date?,
        cycleID: String?,
        value: CapacityEvidenceValue,
        authority: CapacityAuthority,
        stability: CapacityStability,
        consent: CapacityConsent,
        freshnessPolicy: CapacityFreshnessPolicy,
        comparability: CapacityComparability,
        parserRevision: String,
        retention: CapacityEvidenceRetention,
        dayStart: Date?
    ) throws {
        _ = try value.capacityValue()
        guard !recordDigest.isEmpty,
              parserRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CapacityContractError.invalidValue
        }
        self.recordDigest = recordDigest
        self.seriesID = seriesID
        self.observedAt = observedAt
        self.resetAt = resetAt
        self.cycleID = cycleID
        self.value = value
        self.authority = authority
        self.stability = stability
        self.consent = consent
        self.freshnessPolicy = freshnessPolicy
        self.comparability = comparability
        self.parserRevision = parserRevision
        self.retention = retention
        self.dayStart = dayStart
    }

    public func observationForAssessment(now: Date) throws -> CapacityObservation {
        try CapacityObservation(
            seriesID: seriesID,
            observedAt: observedAt,
            resetAt: resetAt,
            value: try value.capacityValue(),
            authority: authority,
            stability: stability,
            consent: consent,
            freshnessPolicy: freshnessPolicy,
            comparability: comparability,
            parserRevision: parserRevision,
            now: now
        )
    }

    fileprivate var winnerPriority: Int {
        switch (authority, stability) {
        case (.providerReported, .supported): return 5
        case (.providerReported, .compatibilityBridge): return 4
        case (.providerReported, .experimentalTransport): return 3
        case (.userEntered, _): return 2
        case (.localDerived, _): return 1
        case (.synthetic, _): return 0
        default: return -1
        }
    }

    fileprivate func asRetention(_ retention: CapacityEvidenceRetention, dayStart: Date? = nil) throws -> CapacityEvidenceRecord {
        let digest = try Self.digest(
            seriesID: seriesID,
            observedAt: observedAt,
            resetAt: resetAt,
            cycleID: cycleID,
            value: value,
            authority: authority,
            stability: stability,
            consent: consent,
            freshnessPolicy: freshnessPolicy,
            comparability: comparability,
            parserRevision: parserRevision,
            retention: retention,
            dayStart: dayStart
        )
        return try CapacityEvidenceRecord(
            recordDigest: digest,
            seriesID: seriesID,
            observedAt: observedAt,
            resetAt: resetAt,
            cycleID: cycleID,
            value: value,
            authority: authority,
            stability: stability,
            consent: consent,
            freshnessPolicy: freshnessPolicy,
            comparability: comparability,
            parserRevision: parserRevision,
            retention: retention,
            dayStart: dayStart
        )
    }

    fileprivate func canonicalObject(includeDigest: Bool = true) -> [String: Any] {
        var seriesObject: [String: Any] = [
            "provider": seriesID.provider.rawValue,
            "providerWindowID": seriesID.providerWindowID,
            "kind": seriesID.kind.rawValue,
            "unit": seriesID.unit.rawValue
        ]
        if let durationMinutes = seriesID.durationMinutes {
            seriesObject["durationMinutes"] = durationMinutes
        }

        var object: [String: Any] = [
            "seriesID": seriesObject,
            "observedAt": CapacityCanonical.dateString(observedAt),
            "value": value.canonicalObject,
            "authority": authority.rawValue,
            "stability": stability.rawValue,
            "consent": consent.rawValue,
            "freshnessPolicy": ["maximumAge": freshnessPolicy.maximumAge] as [String: Any],
            "comparability": comparability.rawValue,
            "parserRevision": parserRevision,
            "retention": retention.rawValue
        ]
        if includeDigest {
            object["recordDigest"] = recordDigest
        }
        if let resetAt {
            object["resetAt"] = CapacityCanonical.dateString(resetAt)
        }
        if let cycleID {
            object["cycleID"] = cycleID
        }
        if let dayStart {
            object["dayStart"] = CapacityCanonical.dateString(dayStart)
        }
        return object
    }

    private static func digest(
        seriesID: CapacitySeriesID,
        observedAt: Date,
        resetAt: Date?,
        cycleID: String?,
        value: CapacityEvidenceValue,
        authority: CapacityAuthority,
        stability: CapacityStability,
        consent: CapacityConsent,
        freshnessPolicy: CapacityFreshnessPolicy,
        comparability: CapacityComparability,
        parserRevision: String,
        retention: CapacityEvidenceRetention,
        dayStart: Date?
    ) throws -> String {
        let record = try CapacityEvidenceRecord(
            recordDigest: "pending",
            seriesID: seriesID,
            observedAt: observedAt,
            resetAt: resetAt,
            cycleID: cycleID,
            value: value,
            authority: authority,
            stability: stability,
            consent: consent,
            freshnessPolicy: freshnessPolicy,
            comparability: comparability,
            parserRevision: parserRevision,
            retention: retention,
            dayStart: dayStart
        )
        return CapacityCanonical.sha256Hex(try CapacityCanonical.jsonData(record.canonicalObject(includeDigest: false)))
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest
        case seriesID
        case observedAt
        case resetAt
        case cycleID
        case value
        case authority
        case stability
        case consent
        case freshnessPolicy
        case comparability
        case parserRevision
        case retention
        case dayStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordDigest: try container.decode(String.self, forKey: .recordDigest),
            seriesID: try container.decode(CapacitySeriesID.self, forKey: .seriesID),
            observedAt: try container.decode(Date.self, forKey: .observedAt),
            resetAt: try container.decodeIfPresent(Date.self, forKey: .resetAt),
            cycleID: try container.decodeIfPresent(String.self, forKey: .cycleID),
            value: try container.decode(CapacityEvidenceValue.self, forKey: .value),
            authority: try container.decode(CapacityAuthority.self, forKey: .authority),
            stability: try container.decode(CapacityStability.self, forKey: .stability),
            consent: try container.decodeIfPresent(CapacityConsent.self, forKey: .consent) ?? .notRequired,
            freshnessPolicy: try container.decode(CapacityFreshnessPolicy.self, forKey: .freshnessPolicy),
            comparability: try container.decode(CapacityComparability.self, forKey: .comparability),
            parserRevision: try container.decode(String.self, forKey: .parserRevision),
            retention: try container.decode(CapacityEvidenceRetention.self, forKey: .retention),
            dayStart: try container.decodeIfPresent(Date.self, forKey: .dayStart)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordDigest, forKey: .recordDigest)
        try container.encode(seriesID, forKey: .seriesID)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encodeIfPresent(cycleID, forKey: .cycleID)
        try container.encode(value, forKey: .value)
        try container.encode(authority, forKey: .authority)
        try container.encode(stability, forKey: .stability)
        try container.encode(consent, forKey: .consent)
        try container.encode(freshnessPolicy, forKey: .freshnessPolicy)
        try container.encode(comparability, forKey: .comparability)
        try container.encode(parserRevision, forKey: .parserRevision)
        try container.encode(retention, forKey: .retention)
        try container.encodeIfPresent(dayStart, forKey: .dayStart)
    }
}

public struct CapacityEvidenceQuarantineEntry: Codable, Equatable, Sendable {
    public var recordDigest: String
    public var code: String
    public var count: Int
    public var firstObservedAt: Date
    public var lastObservedAt: Date

    public init(recordDigest: String, code: String, count: Int = 1, firstObservedAt: Date, lastObservedAt: Date) {
        self.recordDigest = recordDigest
        self.code = code
        self.count = max(count, 1)
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }

    fileprivate var canonicalObject: [String: Any] {
        [
            "recordDigest": recordDigest,
            "code": code,
            "count": count,
            "firstObservedAt": CapacityCanonical.dateString(firstObservedAt),
            "lastObservedAt": CapacityCanonical.dateString(lastObservedAt)
        ]
    }
}

public struct CapacityEvidenceEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generation: Int
    public let records: [CapacityEvidenceRecord]
    public let quarantine: [CapacityEvidenceQuarantineEntry]
    public let checksum: String

    public init(schemaVersion: Int = 2, generation: Int, records: [CapacityEvidenceRecord], quarantine: [CapacityEvidenceQuarantineEntry], checksum: String) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.records = records
        self.quarantine = quarantine
        self.checksum = checksum
    }

    public static func make(generation: Int, records: [CapacityEvidenceRecord], quarantine: [CapacityEvidenceQuarantineEntry]) throws -> CapacityEvidenceEnvelope {
        let unsigned = CapacityEvidenceEnvelope(schemaVersion: 2, generation: generation, records: records, quarantine: quarantine, checksum: "")
        let checksum = CapacityCanonical.sha256Hex(try unsigned.canonicalPayloadData())
        return CapacityEvidenceEnvelope(schemaVersion: 2, generation: generation, records: records, quarantine: quarantine, checksum: checksum)
    }

    public func canonicalPayloadData() throws -> Data {
        try CapacityCanonical.jsonData(canonicalPayloadObject)
    }

    public func fileData() throws -> Data {
        var object = canonicalPayloadObject
        object["checksum"] = checksum
        return try CapacityCanonical.jsonData(object)
    }

    public func validatesChecksum() -> Bool {
        guard schemaVersion == 2,
              let payload = try? canonicalPayloadData() else { return false }
        return CapacityCanonical.sha256Hex(payload) == checksum
    }

    fileprivate var canonicalPayloadObject: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "generation": generation,
            "records": records.map { $0.canonicalObject() } as [Any],
            "quarantine": quarantine.map { $0.canonicalObject } as [Any]
        ]
    }
}

public struct CapacityEvidenceSnapshot: Equatable, Sendable {
    public let generation: Int
    public let records: [CapacityEvidenceRecord]
    public let quarantine: [CapacityEvidenceQuarantineEntry]
    public let recoveryStatus: CapacityPersistenceStatus

    public init(generation: Int, records: [CapacityEvidenceRecord], quarantine: [CapacityEvidenceQuarantineEntry], recoveryStatus: CapacityPersistenceStatus) {
        self.generation = generation
        self.records = records
        self.quarantine = quarantine
        self.recoveryStatus = recoveryStatus
    }
}

public struct CapacityEvidenceWriteResult: Equatable, Sendable {
    public let acceptedCount: Int
    public let quarantinedCount: Int
    public let snapshot: CapacityEvidenceSnapshot?
    public let recoveryStatus: CapacityPersistenceStatus

    public init(acceptedCount: Int, quarantinedCount: Int, snapshot: CapacityEvidenceSnapshot?, recoveryStatus: CapacityPersistenceStatus) {
        self.acceptedCount = acceptedCount
        self.quarantinedCount = quarantinedCount
        self.snapshot = snapshot
        self.recoveryStatus = recoveryStatus
    }
}

public struct CapacityEvidenceFileSet: Equatable, Sendable {
    public let directory: URL
    public let primary: URL
    public let backup: URL
    public let temp: URL
    public let backupTemp: URL
    public let txn: URL
    public let lock: URL
    public let legacyMigrationMarker: URL
    public let legacyMigrationMarkerTemp: URL

    public init(directory: URL, fileName: String = "capacity-evidence-v2.json") {
        self.directory = directory
        self.primary = directory.appendingPathComponent(fileName)
        self.backup = directory.appendingPathComponent("\(fileName).backup")
        self.temp = directory.appendingPathComponent("\(fileName).temp")
        self.backupTemp = directory.appendingPathComponent("\(fileName).backup-temp")
        self.txn = directory.appendingPathComponent("\(fileName).txn")
        self.lock = directory.appendingPathComponent("\(fileName).lock")
        self.legacyMigrationMarker = directory.appendingPathComponent("\(fileName).legacy-migration-marker")
        self.legacyMigrationMarkerTemp = directory.appendingPathComponent("\(fileName).legacy-migration-marker.temp")
    }
}

public actor CapacityEvidenceStore {
    public static let maxSeries = 32
    public static let maxSeriesPerProvider = 8
    public static let maxRecordsPerSeries = 2_054

    private let files: CapacityEvidenceFileSet
    private let fileSystem: any CapacityEvidenceFileSystem
    private let clock: any CapacityEvidenceClock
    private let decoder = CapacityEvidenceCoders.decoder()

    public init(directory: URL? = nil, fileSystem: any CapacityEvidenceFileSystem = LocalCapacityEvidenceFileSystem(), clock: any CapacityEvidenceClock = SystemCapacityEvidenceClock()) {
        self.files = CapacityEvidenceFileSet(directory: directory ?? Self.defaultDirectory())
        self.fileSystem = fileSystem
        self.clock = clock
    }

    public init(files: CapacityEvidenceFileSet, fileSystem: any CapacityEvidenceFileSystem = LocalCapacityEvidenceFileSystem(), clock: any CapacityEvidenceClock = SystemCapacityEvidenceClock()) {
        self.files = files
        self.fileSystem = fileSystem
        self.clock = clock
    }

    public nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("TokenPilot", isDirectory: true)
    }

    public func loadSnapshot() async -> CapacityEvidenceSnapshot {
        do {
            try fileSystem.createDirectory(at: files.directory)
            return try withAdvisoryLock {
                let recovery = try recoverBase(cleanupAllowed: true)
                switch recovery {
                case let .base(envelope, source):
                    return CapacityEvidenceSnapshot(generation: envelope.generation, records: envelope.records, quarantine: envelope.quarantine, recoveryStatus: .ready(source: source, generation: envelope.generation))
                case .empty:
                    return CapacityEvidenceSnapshot(generation: 0, records: [], quarantine: [], recoveryStatus: .ready(source: .empty, generation: 0))
                case let .blocked(code):
                    return CapacityEvidenceSnapshot(generation: 0, records: [], quarantine: [], recoveryStatus: .recoveryRequired(writeBlocked: true, code: code))
                }
            }
        } catch {
            return CapacityEvidenceSnapshot(generation: 0, records: [], quarantine: [], recoveryStatus: .recoveryRequired(writeBlocked: true, code: "evidenceRecoveryRequired"))
        }
    }

    public func record(_ observations: [CapacityObservation]) async -> CapacityEvidenceWriteResult {
        do {
            try fileSystem.createDirectory(at: files.directory)
            return try withAdvisoryLock {
                let recovery = try recoverBase(cleanupAllowed: true)
                guard case let .base(baseEnvelope, source) = recovery else {
                    if case .empty = recovery {
                        return try commitRecord(baseEnvelope: CapacityEvidenceEnvelope(schemaVersion: 2, generation: 0, records: [], quarantine: [], checksum: ""), source: .empty, observations: observations, additionalQuarantine: [])
                    }
                    return CapacityEvidenceWriteResult(acceptedCount: 0, quarantinedCount: observations.count, snapshot: nil, recoveryStatus: .recoveryRequired(writeBlocked: true, code: "evidenceRecoveryRequired"))
                }
                return try commitRecord(baseEnvelope: baseEnvelope, source: source, observations: observations, additionalQuarantine: [])
            }
        } catch {
            return CapacityEvidenceWriteResult(acceptedCount: 0, quarantinedCount: observations.count, snapshot: nil, recoveryStatus: .recoveryRequired(writeBlocked: true, code: "evidenceCommitFailed"))
        }
    }

    public func migrateLegacyLimitSamples(_ samples: [ProviderLimitSample]) async -> CapacityEvidenceWriteResult {
        guard !samples.isEmpty else {
            return legacyMigrationBlockedResult(quarantinedCount: 0, code: "legacySourceUnavailable")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(samples) else {
            return legacyMigrationBlockedResult(quarantinedCount: samples.count, code: "legacySourceUnavailable")
        }
        return await migrateLegacyLimitSamples(from: data)
    }

    public func migrateLegacyLimitSamples(from legacyData: Data) async -> CapacityEvidenceWriteResult {
        guard !legacyData.isEmpty,
              let samples = try? decoder.decode([ProviderLimitSample].self, from: legacyData),
              !samples.isEmpty else {
            return legacyMigrationBlockedResult(quarantinedCount: 0, code: "legacySourceUnavailable")
        }

        let sourceDigest = CapacityLegacyEvidenceConverter.sourceDigest(for: legacyData)
        let converted = CapacityLegacyEvidenceConverter.convert(samples: samples, now: clock.now)
        let convertedCount = converted.observations.count + converted.quarantine.count

        do {
            try fileSystem.createDirectory(at: files.directory)
            return try withAdvisoryLock {
                let recovery = try recoverBase(cleanupAllowed: true)
                if let marker = readLegacyMigrationMarker(), marker.sourceDigest == sourceDigest {
                    return legacyMigrationNoOpResult(from: recovery, fallbackGeneration: marker.committedGeneration)
                }

                switch recovery {
                case let .base(baseEnvelope, source):
                    if legacyConversionAlreadyCommitted(converted, in: baseEnvelope) {
                        try writeLegacyMigrationMarker(sourceDigest: sourceDigest, committedGeneration: baseEnvelope.generation)
                        return legacyMigrationNoOpResult(from: recovery, fallbackGeneration: baseEnvelope.generation)
                    }
                    let result = try commitRecord(baseEnvelope: baseEnvelope, source: source, observations: converted.observations, additionalQuarantine: converted.quarantine)
                    if let generation = result.snapshot?.generation {
                        try writeLegacyMigrationMarker(sourceDigest: sourceDigest, committedGeneration: generation)
                    }
                    return result
                case .empty:
                    let result = try commitRecord(baseEnvelope: CapacityEvidenceEnvelope(schemaVersion: 2, generation: 0, records: [], quarantine: [], checksum: ""), source: .empty, observations: converted.observations, additionalQuarantine: converted.quarantine)
                    if let generation = result.snapshot?.generation {
                        try writeLegacyMigrationMarker(sourceDigest: sourceDigest, committedGeneration: generation)
                    }
                    return result
                case let .blocked(code):
                    return CapacityEvidenceWriteResult(acceptedCount: 0, quarantinedCount: convertedCount, snapshot: nil, recoveryStatus: .recoveryRequired(writeBlocked: true, code: code))
                }
            }
        } catch {
            return CapacityEvidenceWriteResult(acceptedCount: 0, quarantinedCount: convertedCount, snapshot: nil, recoveryStatus: .recoveryRequired(writeBlocked: true, code: "evidenceCommitFailed"))
        }
    }

    private func legacyMigrationBlockedResult(quarantinedCount: Int, code: String) -> CapacityEvidenceWriteResult {
        CapacityEvidenceWriteResult(acceptedCount: 0, quarantinedCount: quarantinedCount, snapshot: nil, recoveryStatus: .recoveryRequired(writeBlocked: true, code: code))
    }

    private func legacyMigrationNoOpResult(from recovery: EvidenceRecovery, fallbackGeneration: Int) -> CapacityEvidenceWriteResult {
        switch recovery {
        case let .base(envelope, source):
            let snapshot = CapacityEvidenceSnapshot(generation: envelope.generation, records: envelope.records, quarantine: envelope.quarantine, recoveryStatus: .ready(source: source, generation: envelope.generation))
            return CapacityEvidenceWriteResult(acceptedCount: 0, quarantinedCount: 0, snapshot: snapshot, recoveryStatus: snapshot.recoveryStatus)
        case .empty:
            let snapshot = CapacityEvidenceSnapshot(generation: fallbackGeneration, records: [], quarantine: [], recoveryStatus: .ready(source: .empty, generation: fallbackGeneration))
            return CapacityEvidenceWriteResult(acceptedCount: 0, quarantinedCount: 0, snapshot: snapshot, recoveryStatus: snapshot.recoveryStatus)
        case let .blocked(code):
            return CapacityEvidenceWriteResult(acceptedCount: 0, quarantinedCount: 0, snapshot: nil, recoveryStatus: .recoveryRequired(writeBlocked: true, code: code))
        }
    }

    private func legacyConversionAlreadyCommitted(_ converted: CapacityLegacyEvidenceConverter.Result, in envelope: CapacityEvidenceEnvelope) -> Bool {
        let expectedRecordDigests = Set(converted.observations.compactMap { observation in
            try? CapacityEvidenceRecord(observation: observation, retention: .raw).recordDigest
        })
        let expectedQuarantineKeys = Set(converted.quarantine.map { "\($0.recordDigest)|\($0.code)" })
        guard !expectedRecordDigests.isEmpty || !expectedQuarantineKeys.isEmpty else { return false }

        let recordDigests = Set(envelope.records.map(\.recordDigest))
        let quarantineKeys = Set(envelope.quarantine.map { "\($0.recordDigest)|\($0.code)" })
        return expectedRecordDigests.isSubset(of: recordDigests) && expectedQuarantineKeys.isSubset(of: quarantineKeys)
    }

    private func readLegacyMigrationMarker() -> CapacityLegacyMigrationMarker? {
        guard fileSystem.fileExists(at: files.legacyMigrationMarker),
              let data = try? fileSystem.readData(at: files.legacyMigrationMarker) else { return nil }
        return try? CapacityEvidenceCoders.decoder().decode(CapacityLegacyMigrationMarker.self, from: data)
    }

    private func writeLegacyMigrationMarker(sourceDigest: String, committedGeneration: Int) throws {
        let marker = CapacityLegacyMigrationMarker(sourceDigest: sourceDigest, committedGeneration: committedGeneration)
        let data = try CapacityEvidenceCoders.encoder().encode(marker)
        try fileSystem.removeItemIfExists(at: files.legacyMigrationMarkerTemp)
        try fileSystem.writeDataExclusively(data, to: files.legacyMigrationMarkerTemp)
        try fileSystem.synchronizeFile(at: files.legacyMigrationMarkerTemp)
        try fileSystem.replaceItem(at: files.legacyMigrationMarker, withItemAt: files.legacyMigrationMarkerTemp)
        try fileSystem.synchronizeDirectory(at: files.directory)
    }

    private func commitRecord(baseEnvelope: CapacityEvidenceEnvelope, source: CapacityPersistenceSource, observations: [CapacityObservation], additionalQuarantine: [CapacityEvidenceQuarantineEntry]) throws -> CapacityEvidenceWriteResult {
        let now = clock.now
        var quarantine = baseEnvelope.quarantine
        var admitted: [CapacityEvidenceRecord] = []
        for observation in observations {
            do {
                try observation.validateAdmission(now: now)
                admitted.append(try CapacityEvidenceRecord(observation: observation, retention: .raw))
            } catch {
                quarantine = mergeQuarantine(quarantine, entry: quarantineEntry(for: observation, code: quarantineCode(for: error), now: now), now: now)
            }
        }

        for entry in additionalQuarantine {
            quarantine = mergeQuarantine(quarantine, entry: entry, now: now)
        }

        let cardinality = applyCardinality(to: admitted, existing: baseEnvelope.records, now: now)
        quarantine = cardinality.quarantine.reduce(quarantine) { mergeQuarantine($0, entry: $1, now: now) }
        let successorRecords = try compact(records: baseEnvelope.records + cardinality.accepted, now: now)
        try validateCardinality(successorRecords)
        let prunedQuarantine = pruneQuarantine(quarantine, now: now)
        let successor = try CapacityEvidenceEnvelope.make(generation: baseEnvelope.generation + 1, records: successorRecords, quarantine: prunedQuarantine)
        try commit(successor: successor, baseSource: source)
        let snapshot = CapacityEvidenceSnapshot(generation: successor.generation, records: successor.records, quarantine: successor.quarantine, recoveryStatus: .ready(source: .primary, generation: successor.generation))
        return CapacityEvidenceWriteResult(acceptedCount: cardinality.accepted.count, quarantinedCount: observations.count - cardinality.accepted.count + additionalQuarantine.count, snapshot: snapshot, recoveryStatus: snapshot.recoveryStatus)
    }

    private func commit(successor: CapacityEvidenceEnvelope, baseSource: CapacityPersistenceSource) throws {
        try cleanupOrphans()
        let data = try successor.fileData()
        try fileSystem.writeDataExclusively(data, to: files.temp)
        try fileSystem.synchronizeFile(at: files.temp)
        try fileSystem.synchronizeDirectory(at: files.directory)
        try writeTransaction(CapacityEvidenceTransaction(baseGeneration: successor.generation - 1, targetGeneration: successor.generation, targetChecksum: successor.checksum, phase: .prepared))
        if baseSource == .primary, fileSystem.fileExists(at: files.primary) {
            let primaryBytes = try fileSystem.readData(at: files.primary)
            try fileSystem.writeDataExclusively(primaryBytes, to: files.backupTemp)
            try fileSystem.synchronizeFile(at: files.backupTemp)
            try fileSystem.replaceItem(at: files.backup, withItemAt: files.backupTemp)
            try fileSystem.synchronizeDirectory(at: files.directory)
        }
        try fileSystem.replaceItem(at: files.primary, withItemAt: files.temp)
        try fileSystem.synchronizeDirectory(at: files.directory)
        try writeTransaction(CapacityEvidenceTransaction(baseGeneration: successor.generation - 1, targetGeneration: successor.generation, targetChecksum: successor.checksum, phase: .primaryReplaced))
        try fileSystem.removeItemIfExists(at: files.txn)
        try fileSystem.removeItemIfExists(at: files.temp)
        try fileSystem.removeItemIfExists(at: files.backupTemp)
        try fileSystem.synchronizeDirectory(at: files.directory)
    }

    private func recoverBase(cleanupAllowed: Bool) throws -> EvidenceRecovery {
        let primaryExists = fileSystem.fileExists(at: files.primary)
        let backupExists = fileSystem.fileExists(at: files.backup)
        let tempExists = fileSystem.fileExists(at: files.temp)
        let backupTempExists = fileSystem.fileExists(at: files.backupTemp)
        let txnExists = fileSystem.fileExists(at: files.txn)

        let primary = validEnvelope(at: files.primary)
        let backup = validEnvelope(at: files.backup)
        let txn = validTransaction()
        let matchingTemp = txn.flatMap { matchingTempEnvelope(for: $0) }

        if let primary {
            if let txn, txn.phase == .primaryReplaced, primary.generation == txn.targetGeneration, primary.checksum == txn.targetChecksum {
                if cleanupAllowed { try cleanupOrphans() }
                return .base(primary, .primary)
            }
            if cleanupAllowed { try cleanupOrphans() }
            return .base(primary, .primary)
        }

        if !primaryExists, let txn, txn.phase == .prepared, txn.baseGeneration == 0, let matchingTemp {
            if cleanupAllowed {
                try fileSystem.replaceItem(at: files.primary, withItemAt: files.temp)
                try fileSystem.removeItemIfExists(at: files.txn)
                try fileSystem.removeItemIfExists(at: files.backupTemp)
                try fileSystem.synchronizeDirectory(at: files.directory)
            }
            return .base(matchingTemp, .temp)
        }

        if let backup {
            if cleanupAllowed {
                try fileSystem.removeItemIfExists(at: files.temp)
                try fileSystem.removeItemIfExists(at: files.backupTemp)
                try fileSystem.removeItemIfExists(at: files.txn)
                try fileSystem.synchronizeDirectory(at: files.directory)
            }
            return .base(backup, .backup)
        }

        if !primaryExists && !backupExists && !tempExists && !backupTempExists && !txnExists {
            return .empty
        }

        return .blocked(code: "evidenceRecoveryRequired")
    }

    private func validEnvelope(at url: URL) -> CapacityEvidenceEnvelope? {
        guard fileSystem.fileExists(at: url),
              let data = try? fileSystem.readData(at: url),
              let envelope = try? decoder.decode(CapacityEvidenceEnvelope.self, from: data),
              envelope.validatesChecksum() else {
            return nil
        }
        return envelope
    }

    private func validTransaction() -> CapacityEvidenceTransaction? {
        guard fileSystem.fileExists(at: files.txn),
              let data = try? fileSystem.readData(at: files.txn) else { return nil }
        return try? CapacityEvidenceCoders.decoder().decode(CapacityEvidenceTransaction.self, from: data)
    }

    private func matchingTempEnvelope(for txn: CapacityEvidenceTransaction) -> CapacityEvidenceEnvelope? {
        guard let envelope = validEnvelope(at: files.temp),
              envelope.generation == txn.targetGeneration,
              envelope.checksum == txn.targetChecksum else {
            return nil
        }
        return envelope
    }

    private func writeTransaction(_ transaction: CapacityEvidenceTransaction) throws {
        try fileSystem.removeItemIfExists(at: files.txn)
        let encoder = CapacityEvidenceCoders.encoder()
        let data = try encoder.encode(transaction)
        try fileSystem.writeDataExclusively(data, to: files.txn)
        try fileSystem.synchronizeFile(at: files.txn)
    }

    private func cleanupOrphans() throws {
        try fileSystem.removeItemIfExists(at: files.temp)
        try fileSystem.removeItemIfExists(at: files.backupTemp)
        try fileSystem.removeItemIfExists(at: files.txn)
        try fileSystem.synchronizeDirectory(at: files.directory)
    }

    private func compact(records: [CapacityEvidenceRecord], now: Date) throws -> [CapacityEvidenceRecord] {
        let utcCalendar = CapacityEvidenceStore.utcCalendar
        let todayStart = utcCalendar.startOfDay(for: now)
        guard let rawLowerBound = utcCalendar.date(byAdding: .day, value: -6, to: todayStart),
              let rawUpperBound = utcCalendar.date(byAdding: .day, value: 1, to: todayStart),
              let oldestClosingBound = utcCalendar.date(byAdding: .day, value: -44, to: todayStart) else {
            throw CapacityContractError.invalidValue
        }
        let latest = min(rawUpperBound, now.addingTimeInterval(60))
        let candidates = records.filter { $0.observedAt >= oldestClosingBound && $0.observedAt < rawUpperBound && $0.observedAt <= latest }
        var rawByBucket: [String: CapacityEvidenceRecord] = [:]
        for record in candidates where record.observedAt >= rawLowerBound && record.observedAt < rawUpperBound {
            let raw = try record.asRetention(.raw)
            let key = bucketKey(for: raw)
            if let existing = rawByBucket[key] {
                rawByBucket[key] = winner(existing, raw)
            } else {
                rawByBucket[key] = raw
            }
        }

        var closings: [CapacityEvidenceRecord] = []
        for dayOffset in 7...44 {
            guard let dayStart = utcCalendar.date(byAdding: .day, value: -dayOffset, to: todayStart),
                  let dayEnd = utcCalendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            var latestBySeries: [String: CapacityEvidenceRecord] = [:]
            for record in candidates where record.observedAt >= dayStart && record.observedAt < dayEnd {
                let key = record.seriesID.canonicalID
                if let existing = latestBySeries[key] {
                    latestBySeries[key] = winner(existing, record)
                } else {
                    latestBySeries[key] = record
                }
            }
            for record in latestBySeries.values {
                closings.append(try record.asRetention(.dailyClosing, dayStart: dayStart))
            }
        }

        let merged = Array(rawByBucket.values) + closings
        let grouped = Dictionary(grouping: merged, by: { $0.seriesID.canonicalID })
        for (_, records) in grouped where records.count > Self.maxRecordsPerSeries {
            throw CapacityContractError.invalidValue
        }
        return merged.sorted(by: evidenceSort)
    }

    private func applyCardinality(to incoming: [CapacityEvidenceRecord], existing: [CapacityEvidenceRecord], now: Date) -> (accepted: [CapacityEvidenceRecord], quarantine: [CapacityEvidenceQuarantineEntry]) {
        var accepted: [CapacityEvidenceRecord] = []
        var quarantine: [CapacityEvidenceQuarantineEntry] = []
        var series = Set(existing.map { $0.seriesID.canonicalID })
        var seriesByProvider = Dictionary(grouping: existing.map(\.seriesID), by: { $0.provider })
            .mapValues { Set($0.map(\.canonicalID)) }

        for record in incoming.sorted(by: evidenceSort) {
            let canonicalID = record.seriesID.canonicalID
            let provider = record.seriesID.provider
            var providerSeries = seriesByProvider[provider, default: []]
            if !series.contains(canonicalID) {
                guard series.count < Self.maxSeries else {
                    quarantine.append(quarantineEntry(for: record, code: "seriesCardinalityExceeded", now: now))
                    continue
                }
                guard providerSeries.count < Self.maxSeriesPerProvider else {
                    quarantine.append(quarantineEntry(for: record, code: "providerCardinalityExceeded", now: now))
                    continue
                }
                series.insert(canonicalID)
                providerSeries.insert(canonicalID)
                seriesByProvider[provider] = providerSeries
            }
            accepted.append(record)
        }
        return (accepted, quarantine)
    }

    private func validateCardinality(_ records: [CapacityEvidenceRecord]) throws {
        let series = Set(records.map { $0.seriesID.canonicalID })
        guard series.count <= Self.maxSeries else { throw CapacityContractError.invalidValue }
        let byProvider = Dictionary(grouping: records.map(\.seriesID), by: { $0.provider })
        for (_, ids) in byProvider {
            guard Set(ids.map(\.canonicalID)).count <= Self.maxSeriesPerProvider else { throw CapacityContractError.invalidValue }
        }
    }

    private func bucketKey(for record: CapacityEvidenceRecord) -> String {
        let bucket = Int(floor(record.observedAt.timeIntervalSince1970 / 300))
        return "\(record.seriesID.canonicalID)|\(bucket)"
    }

    private func winner(_ lhs: CapacityEvidenceRecord, _ rhs: CapacityEvidenceRecord) -> CapacityEvidenceRecord {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt ? lhs : rhs }
        if lhs.winnerPriority != rhs.winnerPriority { return lhs.winnerPriority > rhs.winnerPriority ? lhs : rhs }
        return lhs.recordDigest <= rhs.recordDigest ? lhs : rhs
    }

    private func evidenceSort(_ lhs: CapacityEvidenceRecord, _ rhs: CapacityEvidenceRecord) -> Bool {
        if lhs.seriesID.canonicalID != rhs.seriesID.canonicalID { return lhs.seriesID.canonicalID < rhs.seriesID.canonicalID }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        if lhs.retention != rhs.retention { return lhs.retention.rawValue < rhs.retention.rawValue }
        return lhs.recordDigest < rhs.recordDigest
    }

    private func quarantineEntry(for observation: CapacityObservation, code: String, now: Date) -> CapacityEvidenceQuarantineEntry {
        let digest: String
        if let record = try? CapacityEvidenceRecord(observation: observation) {
            digest = record.recordDigest
        } else {
            digest = CapacityCanonical.sha256Hex(Data(observation.seriesID.canonicalID.utf8))
        }
        return CapacityEvidenceQuarantineEntry(recordDigest: digest, code: code, firstObservedAt: min(observation.observedAt, now), lastObservedAt: min(observation.observedAt, now))
    }

    private func quarantineEntry(for record: CapacityEvidenceRecord, code: String, now: Date) -> CapacityEvidenceQuarantineEntry {
        CapacityEvidenceQuarantineEntry(recordDigest: record.recordDigest, code: code, firstObservedAt: min(record.observedAt, now), lastObservedAt: min(record.observedAt, now))
    }

    private func mergeQuarantine(_ entries: [CapacityEvidenceQuarantineEntry], entry: CapacityEvidenceQuarantineEntry, now: Date) -> [CapacityEvidenceQuarantineEntry] {
        var byKey = Dictionary(uniqueKeysWithValues: entries.map { ("\($0.recordDigest)|\($0.code)", $0) })
        let key = "\(entry.recordDigest)|\(entry.code)"
        if var existing = byKey[key] {
            existing.count += entry.count
            existing.firstObservedAt = min(existing.firstObservedAt, entry.firstObservedAt)
            existing.lastObservedAt = max(existing.lastObservedAt, entry.lastObservedAt)
            byKey[key] = existing
        } else {
            byKey[key] = entry
        }
        return pruneQuarantine(Array(byKey.values), now: now)
    }

    private func pruneQuarantine(_ entries: [CapacityEvidenceQuarantineEntry], now: Date) -> [CapacityEvidenceQuarantineEntry] {
        let cutoff = now.addingTimeInterval(-45 * 86_400)
        return entries
            .filter { $0.lastObservedAt >= cutoff }
            .sorted {
                if $0.lastObservedAt != $1.lastObservedAt { return $0.lastObservedAt > $1.lastObservedAt }
                return $0.recordDigest < $1.recordDigest
            }
            .prefix(100)
            .map { $0 }
    }

    private func quarantineCode(for error: Error) -> String {
        switch error {
        case CapacityContractError.futureObservation: return "futureObservation"
        case CapacityContractError.expiredObservation: return "expiredObservation"
        case CapacityContractError.invalidSeriesID: return "invalidSeriesID"
        case CapacityContractError.unsupportedSeries: return "unsupportedSeries"
        case CapacityContractError.invalidValue: return "invalidValue"
        case CapacityContractError.invalidReset: return "invalidReset"
        default: return "invalidEvidence"
        }
    }

    private func withAdvisoryLock<T>(_ body: () throws -> T) throws -> T {
        try withCapacityAdvisoryLock(lockURL: files.lock, fileSystem: fileSystem, body: body)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private enum EvidenceRecovery {
    case base(CapacityEvidenceEnvelope, CapacityPersistenceSource)
    case empty
    case blocked(code: String)
}

private final class CapacityInProcessAdvisoryLocks: @unchecked Sendable {
    static let shared = CapacityInProcessAdvisoryLocks()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    private init() {}

    func withLock<T>(for url: URL, body: () throws -> T) throws -> T {
        let lock = lock(for: url.standardizedFileURL.path)
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func lock(for key: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[key] { return existing }
        let created = NSLock()
        locks[key] = created
        return created
    }
}

private func withCapacityAdvisoryLock<T>(lockURL: URL, fileSystem: any CapacityEvidenceFileSystem, body: () throws -> T) throws -> T {
    try CapacityInProcessAdvisoryLocks.shared.withLock(for: lockURL) {
        #if canImport(Darwin)
        if fileSystem is LocalCapacityEvidenceFileSystem {
            _ = FileManager.default.createFile(atPath: lockURL.path, contents: nil)
            let descriptor = open(lockURL.path, O_RDWR)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }

            var lockResult = flock(descriptor, LOCK_EX)
            while lockResult != 0 && errno == EINTR {
                lockResult = flock(descriptor, LOCK_EX)
            }
            guard lockResult == 0 else {
                close(descriptor)
                throw CocoaError(.fileWriteUnknown)
            }

            defer {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            return try body()
        }
        #endif
        return try body()
    }
}

private struct CapacityEvidenceTransaction: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, primaryReplaced }
    let baseGeneration: Int
    let targetGeneration: Int
    let targetChecksum: String
    let phase: Phase
}

private enum CapacityEvidenceCoders {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CapacityCanonical.dateString(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self), let date = CapacityCanonical.date(from: string) {
                return date
            }
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        return decoder
    }
}

public enum CapacityCanonical {
    public static func decimalString(_ decimal: Decimal) -> String {
        normalizeDecimalString(NSDecimalNumber(decimal: decimal).stringValue)
    }

    public static func thresholdCanonical(_ decimal: Decimal) -> String {
        decimalString(decimal)
    }

    public static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.timeZone = TimeZone(secondsFromGMT: 0)
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    public static func jsonData(_ object: Any) throws -> Data {
        var output = ""
        try appendJSON(object, to: &output)
        guard let data = output.data(using: .utf8) else { throw CapacityContractError.invalidValue }
        return data
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendJSON(_ value: Any, to output: inout String) throws {
        switch value {
        case let value as String:
            appendJSONString(value.precomposedStringWithCanonicalMapping, to: &output)
        case let value as Int:
            output += String(value)
        case let value as Double:
            guard value.isFinite else { throw CapacityContractError.invalidValue }
            output += normalizeDecimalString(String(value))
        case let value as Bool:
            output += value ? "true" : "false"
        case _ as NSNull:
            output += "null"
        case let value as [Any]:
            output += "["
            for index in value.indices {
                if index != value.startIndex { output += "," }
                try appendJSON(value[index], to: &output)
            }
            output += "]"
        case let value as [String: Any]:
            output += "{"
            let keys = value.keys.sorted()
            for index in keys.indices {
                if index != keys.startIndex { output += "," }
                appendJSONString(keys[index], to: &output)
                output += ":"
                try appendJSON(value[keys[index]] as Any, to: &output)
            }
            output += "}"
        default:
            throw CapacityContractError.invalidValue
        }
    }

    private static func appendJSONString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            case 0x08: output += "\\b"
            case 0x0C: output += "\\f"
            case 0x0A: output += "\\n"
            case 0x0D: output += "\\r"
            case 0x09: output += "\\t"
            case 0..<0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    private static func normalizeDecimalString(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("+") { value.removeFirst() }
        var negative = false
        if value.hasPrefix("-") {
            negative = true
            value.removeFirst()
        }

        let parts = value.split(separator: "e", omittingEmptySubsequences: false)
        let mantissa = String(parts.first ?? "0")
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissaParts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(mantissaParts.first ?? "0")
        let fraction = mantissaParts.count > 1 ? String(mantissaParts[1]) : ""
        let digits = (integer + fraction).filter { $0 >= "0" && $0 <= "9" }
        if digits.isEmpty || digits.allSatisfy({ $0 == "0" }) { return "0" }

        let decimalIndex = integer.count + exponent
        var normalized: String
        if decimalIndex <= 0 {
            normalized = "0." + String(repeating: "0", count: abs(decimalIndex)) + digits
        } else if decimalIndex >= digits.count {
            normalized = digits + String(repeating: "0", count: decimalIndex - digits.count)
        } else {
            let splitIndex = digits.index(digits.startIndex, offsetBy: decimalIndex)
            normalized = String(digits[..<splitIndex]) + "." + String(digits[splitIndex...])
        }

        if let dotIndex = normalized.firstIndex(of: ".") {
            var integerPart = String(normalized[..<dotIndex])
            var fractionPart = String(normalized[normalized.index(after: dotIndex)...])
            while integerPart.first == "0", integerPart.count > 1 { integerPart.removeFirst() }
            while fractionPart.last == "0" { fractionPart.removeLast() }
            normalized = fractionPart.isEmpty ? integerPart : "\(integerPart).\(fractionPart)"
        } else {
            while normalized.first == "0", normalized.count > 1 { normalized.removeFirst() }
        }
        return negative ? "-\(normalized)" : normalized
    }
}

public extension CapacityAlertCondition {
    var thresholdCanonical: String? {
        balanceThreshold.map { CapacityCanonical.thresholdCanonical($0) }
    }
}

public extension CapacityAlertRule {
    func replacingCondition(_ newCondition: CapacityAlertCondition, enabled newEnabled: Bool? = nil, routing newRouting: CapacityAlertRouting? = nil) throws -> CapacityAlertRule {
        try CapacityAlertRule(
            provider: provider,
            seriesID: seriesID,
            authority: authority,
            stability: stability,
            enabled: newEnabled ?? enabled,
            routing: newRouting ?? routing,
            conditionRevision: conditionRevision + 1,
            condition: newCondition
        )
    }
}

public struct CapacityRuntimeLoadResult: Equatable, Sendable {
    public let control: CapacityRuntimeControl
    public let recoveryStatus: CapacityPersistenceStatus
    public var deliveryEnabled: Bool { !recoveryStatus.recoveryRequired && control.assessmentEnabled }
}

public struct CapacityRuntimeWriteResult: Equatable, Sendable {
    public let recoveryStatus: CapacityPersistenceStatus
}

public struct CapacityAlertRulesFile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var rules: [CapacityAlertRule]

    public init(schemaVersion: Int = 1, rules: [CapacityAlertRule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules.sorted { $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, rules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw CapacityContractError.invalidRule }
        rules = try container.decode([CapacityAlertRule].self, forKey: .rules).sorted { $0.id < $1.id }
    }
}

public struct CapacityAlertDeliveryFile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var states: [CapacityAlertDeliveryState]

    public init(schemaVersion: Int = 1, states: [CapacityAlertDeliveryState]) {
        self.schemaVersion = schemaVersion
        self.states = states.sorted { $0.key.description < $1.key.description }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, states }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw CapacityContractError.invalidDeliveryState }
        states = try container.decode([CapacityAlertDeliveryState].self, forKey: .states).sorted { $0.key.description < $1.key.description }
    }
}

public struct CapacityAlertRulesLoadResult: Equatable, Sendable {
    public let rules: [CapacityAlertRule]
    public let recoveryStatus: CapacityPersistenceStatus
    public var deliveryEnabled: Bool { !recoveryStatus.recoveryRequired }
}

public struct CapacityAlertDeliveryLoadResult: Equatable, Sendable {
    public let states: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState]
    public let recoveryStatus: CapacityPersistenceStatus
    public var deliveryEnabled: Bool { !recoveryStatus.recoveryRequired }
}

public actor CapacityRuntimeStore {
    private let store: CapacityTransactionalJSONStore<CapacityRuntimeControl>

    public init(directory: URL? = nil, fileSystem: any CapacityEvidenceFileSystem = LocalCapacityEvidenceFileSystem()) {
        self.store = CapacityTransactionalJSONStore(directory: directory ?? CapacityEvidenceStore.defaultDirectory(), fileName: "capacity-runtime-v1.json", fileSystem: fileSystem) { control in
            guard control.schemaVersion == 1 else { throw CapacityContractError.invalidValue }
        }
    }

    public func load() async -> CapacityRuntimeLoadResult {
        let result = store.load()
        switch result {
        case let .value(control, source):
            return CapacityRuntimeLoadResult(control: control, recoveryStatus: .ready(source: source, generation: nil))
        case .absent:
            return CapacityRuntimeLoadResult(control: CapacityRuntimeControl(), recoveryStatus: .ready(source: .absentDefault, generation: nil))
        case .blocked:
            return CapacityRuntimeLoadResult(control: CapacityRuntimeControl(assessmentEnabled: false), recoveryStatus: .recoveryRequired(writeBlocked: true, code: "runtimeRecoveryRequired"))
        }
    }

    public func save(_ control: CapacityRuntimeControl) async -> CapacityRuntimeWriteResult {
        switch store.save(control) {
        case let .ready(source, generation): return CapacityRuntimeWriteResult(recoveryStatus: .ready(source: source, generation: generation))
        case let .recoveryRequired(writeBlocked, _): return CapacityRuntimeWriteResult(recoveryStatus: .recoveryRequired(writeBlocked: writeBlocked, code: "runtimeRecoveryRequired"))
        }
    }
}

public actor CapacityAlertRuleStore {
    private let store: CapacityTransactionalJSONStore<CapacityAlertRulesFile>

    public init(directory: URL? = nil, fileSystem: any CapacityEvidenceFileSystem = LocalCapacityEvidenceFileSystem()) {
        self.store = CapacityTransactionalJSONStore(directory: directory ?? CapacityEvidenceStore.defaultDirectory(), fileName: "capacity-alert-rules-v1.json", fileSystem: fileSystem) { file in
            guard file.schemaVersion == 1 else { throw CapacityContractError.invalidRule }
            let ids = file.rules.map(\.id)
            guard Set(ids).count == ids.count else { throw CapacityContractError.invalidRule }
        }
    }

    public func load() async -> CapacityAlertRulesLoadResult {
        switch store.load() {
        case let .value(file, source):
            return CapacityAlertRulesLoadResult(rules: file.rules, recoveryStatus: .ready(source: source, generation: nil))
        case .absent:
            return CapacityAlertRulesLoadResult(rules: [], recoveryStatus: .ready(source: .absentDefault, generation: nil))
        case .blocked:
            return CapacityAlertRulesLoadResult(rules: [], recoveryStatus: .recoveryRequired(writeBlocked: true, code: "rulesRecoveryRequired"))
        }
    }

    public func save(_ rules: [CapacityAlertRule]) async -> CapacityRuntimeWriteResult {
        switch store.save(CapacityAlertRulesFile(rules: rules)) {
        case let .ready(source, generation): return CapacityRuntimeWriteResult(recoveryStatus: .ready(source: source, generation: generation))
        case let .recoveryRequired(writeBlocked, _): return CapacityRuntimeWriteResult(recoveryStatus: .recoveryRequired(writeBlocked: writeBlocked, code: "rulesRecoveryRequired"))
        }
    }
}

public actor CapacityAlertDeliveryStore {
    private let store: CapacityTransactionalJSONStore<CapacityAlertDeliveryFile>

    public init(directory: URL? = nil, fileSystem: any CapacityEvidenceFileSystem = LocalCapacityEvidenceFileSystem()) {
        self.store = CapacityTransactionalJSONStore(directory: directory ?? CapacityEvidenceStore.defaultDirectory(), fileName: "capacity-alert-delivery-v1.json", fileSystem: fileSystem) { file in
            guard file.schemaVersion == 1 else { throw CapacityContractError.invalidDeliveryState }
        }
    }

    public func load() async -> CapacityAlertDeliveryLoadResult {
        switch store.load() {
        case let .value(file, source):
            return CapacityAlertDeliveryLoadResult(states: file.states.reduce(into: [:]) { $0[$1.key] = $1 }, recoveryStatus: .ready(source: source, generation: nil))
        case .absent:
            return CapacityAlertDeliveryLoadResult(states: [:], recoveryStatus: .ready(source: .absentDefault, generation: nil))
        case .blocked:
            return CapacityAlertDeliveryLoadResult(states: [:], recoveryStatus: .recoveryRequired(writeBlocked: true, code: "deliveryRecoveryRequired"))
        }
    }

    public func save(_ states: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState]) async -> CapacityRuntimeWriteResult {
        switch store.save(CapacityAlertDeliveryFile(states: Array(states.values))) {
        case let .ready(source, generation): return CapacityRuntimeWriteResult(recoveryStatus: .ready(source: source, generation: generation))
        case let .recoveryRequired(writeBlocked, _): return CapacityRuntimeWriteResult(recoveryStatus: .recoveryRequired(writeBlocked: writeBlocked, code: "deliveryRecoveryRequired"))
        }
    }
}

public struct CapacityAlertMigrationMarkerLoadResult: Equatable, Sendable {
    public let marker: CapacityAlertMigrationMarker?
    public let recoveryStatus: CapacityPersistenceStatus
    public var deliveryEnabled: Bool { !recoveryStatus.recoveryRequired }

    public init(marker: CapacityAlertMigrationMarker?, recoveryStatus: CapacityPersistenceStatus) {
        self.marker = marker
        self.recoveryStatus = recoveryStatus
    }
}

public struct CapacityAlertMigrationCommitResult: Equatable, Sendable {
    public let didMigrate: Bool
    public let marker: CapacityAlertMigrationMarker?
    public let rules: [CapacityAlertRule]
    public let deliveryStates: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState]
    public let recoveryStatus: CapacityPersistenceStatus

    public init(didMigrate: Bool, marker: CapacityAlertMigrationMarker?, rules: [CapacityAlertRule], deliveryStates: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState], recoveryStatus: CapacityPersistenceStatus) {
        self.didMigrate = didMigrate
        self.marker = marker
        self.rules = rules.sorted { $0.id < $1.id }
        self.deliveryStates = deliveryStates
        self.recoveryStatus = recoveryStatus
    }
}

public actor CapacityAlertMigrationMarkerStore {
    private let store: CapacityTransactionalJSONStore<CapacityAlertMigrationMarker>

    public init(directory: URL? = nil, fileSystem: any CapacityEvidenceFileSystem = LocalCapacityEvidenceFileSystem()) {
        self.store = CapacityTransactionalJSONStore(directory: directory ?? CapacityEvidenceStore.defaultDirectory(), fileName: "capacity-alert-migration-v1.json", fileSystem: fileSystem) { marker in
            guard !marker.sourceSettingsDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  marker.migratedRuleIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(marker.migratedRuleIDs).count == marker.migratedRuleIDs.count else {
                throw CapacityContractError.invalidRule
            }
        }
    }

    public func load() async -> CapacityAlertMigrationMarkerLoadResult {
        switch store.load() {
        case let .value(marker, source):
            return CapacityAlertMigrationMarkerLoadResult(marker: marker, recoveryStatus: .ready(source: source, generation: nil))
        case .absent:
            return CapacityAlertMigrationMarkerLoadResult(marker: nil, recoveryStatus: .ready(source: .absentDefault, generation: nil))
        case .blocked:
            return CapacityAlertMigrationMarkerLoadResult(marker: nil, recoveryStatus: .recoveryRequired(writeBlocked: true, code: "alertMigrationRecoveryRequired"))
        }
    }

    public func save(_ marker: CapacityAlertMigrationMarker) async -> CapacityRuntimeWriteResult {
        switch store.save(marker) {
        case let .ready(source, generation):
            return CapacityRuntimeWriteResult(recoveryStatus: .ready(source: source, generation: generation))
        case let .recoveryRequired(writeBlocked, _):
            return CapacityRuntimeWriteResult(recoveryStatus: .recoveryRequired(writeBlocked: writeBlocked, code: "alertMigrationRecoveryRequired"))
        }
    }
}

public actor CapacityAlertLegacyMigrationCoordinator {
    private let rulesStore: CapacityAlertRuleStore
    private let deliveryStore: CapacityAlertDeliveryStore
    private let markerStore: CapacityAlertMigrationMarkerStore

    public init(directory: URL? = nil, fileSystem: any CapacityEvidenceFileSystem = LocalCapacityEvidenceFileSystem()) {
        let directory = directory ?? CapacityEvidenceStore.defaultDirectory()
        self.rulesStore = CapacityAlertRuleStore(directory: directory, fileSystem: fileSystem)
        self.deliveryStore = CapacityAlertDeliveryStore(directory: directory, fileSystem: fileSystem)
        self.markerStore = CapacityAlertMigrationMarkerStore(directory: directory, fileSystem: fileSystem)
    }

    public init(rulesStore: CapacityAlertRuleStore, deliveryStore: CapacityAlertDeliveryStore, markerStore: CapacityAlertMigrationMarkerStore) {
        self.rulesStore = rulesStore
        self.deliveryStore = deliveryStore
        self.markerStore = markerStore
    }

    public func migrate(
        settings: AppSettings,
        deepSeekBalance: ProviderBalance?,
        initialDeliveryStates: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState] = [:]
    ) async -> CapacityAlertMigrationCommitResult {
        let markerLoad = await markerStore.load()
        guard !markerLoad.recoveryStatus.writeBlocked else {
            return blockedMigrationResult(status: markerLoad.recoveryStatus)
        }

        let migration: CapacityAlertLegacyMigrator.Result
        do {
            migration = try CapacityAlertLegacyMigrator.migrate(settings: settings, deepSeekBalance: deepSeekBalance, existingMarker: markerLoad.marker)
        } catch {
            return blockedMigrationResult(status: .recoveryRequired(writeBlocked: true, code: "alertMigrationInvalidSource"))
        }

        guard migration.didMigrate else {
            return CapacityAlertMigrationCommitResult(didMigrate: false, marker: migration.marker, rules: [], deliveryStates: [:], recoveryStatus: markerLoad.recoveryStatus)
        }

        let rulesLoad = await rulesStore.load()
        guard !rulesLoad.recoveryStatus.writeBlocked else {
            return blockedMigrationResult(status: rulesLoad.recoveryStatus)
        }
        let deliveryLoad = await deliveryStore.load()
        guard !deliveryLoad.recoveryStatus.writeBlocked else {
            return blockedMigrationResult(status: deliveryLoad.recoveryStatus)
        }

        let mergedRules = mergeRules(existing: rulesLoad.rules, migrated: migration.rules, previousMarker: markerLoad.marker, nextMarker: migration.marker)
        let rulesSave = await rulesStore.save(mergedRules)
        guard !rulesSave.recoveryStatus.writeBlocked else {
            return CapacityAlertMigrationCommitResult(didMigrate: false, marker: nil, rules: mergedRules, deliveryStates: deliveryLoad.states, recoveryStatus: rulesSave.recoveryStatus)
        }

        let mergedStates = mergeDeliveryStates(existing: deliveryLoad.states, initial: initialDeliveryStates, previousMarker: markerLoad.marker, nextMarker: migration.marker)
        let deliverySave = await deliveryStore.save(mergedStates)
        guard !deliverySave.recoveryStatus.writeBlocked else {
            return CapacityAlertMigrationCommitResult(didMigrate: false, marker: nil, rules: mergedRules, deliveryStates: mergedStates, recoveryStatus: deliverySave.recoveryStatus)
        }

        let markerSave = await markerStore.save(migration.marker)
        guard !markerSave.recoveryStatus.writeBlocked else {
            return CapacityAlertMigrationCommitResult(didMigrate: false, marker: nil, rules: mergedRules, deliveryStates: mergedStates, recoveryStatus: markerSave.recoveryStatus)
        }

        return CapacityAlertMigrationCommitResult(didMigrate: true, marker: migration.marker, rules: mergedRules, deliveryStates: mergedStates, recoveryStatus: markerSave.recoveryStatus)
    }

    private func mergeRules(existing: [CapacityAlertRule], migrated: [CapacityAlertRule], previousMarker: CapacityAlertMigrationMarker?, nextMarker: CapacityAlertMigrationMarker) -> [CapacityAlertRule] {
        let previousRuleIDs = Set(previousMarker?.migratedRuleIDs ?? [])
        let nextRuleIDs = Set(nextMarker.migratedRuleIDs)
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for removedID in previousRuleIDs.subtracting(nextRuleIDs) {
            byID.removeValue(forKey: removedID)
        }
        for rule in migrated {
            byID[rule.id] = rule
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private func mergeDeliveryStates(existing: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState], initial: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState], previousMarker: CapacityAlertMigrationMarker?, nextMarker: CapacityAlertMigrationMarker) -> [CapacityAlertDeliveryKey: CapacityAlertDeliveryState] {
        let previousRuleIDs = Set(previousMarker?.migratedRuleIDs ?? [])
        let nextRuleIDs = Set(nextMarker.migratedRuleIDs)
        let removedRuleIDs = previousRuleIDs.subtracting(nextRuleIDs)
        var merged = existing

        for key in Array(merged.keys) where removedRuleIDs.contains(key.ruleID) {
            merged.removeValue(forKey: key)
        }
        for (key, state) in initial where nextRuleIDs.contains(key.ruleID) && merged[key] == nil {
            merged[key] = state
        }
        return merged
    }

    private func blockedMigrationResult(status: CapacityPersistenceStatus) -> CapacityAlertMigrationCommitResult {
        CapacityAlertMigrationCommitResult(didMigrate: false, marker: nil, rules: [], deliveryStates: [:], recoveryStatus: status)
    }
}

public struct CapacityAlertChannelSettings: Equatable, Sendable {
    public var globalEnabled: Bool
    public var macOSEnabled: Bool
    public var telegramEnabled: Bool
    public var discordEnabled: Bool
    public var telegramServiceEnabled: Bool
    public var discordServiceEnabled: Bool
    public var telegramCredentialPresent: Bool
    public var discordCredentialPresent: Bool
    public var telegramChatIDPresent: Bool
    public var discordWebhookPresent: Bool

    public init(
        globalEnabled: Bool = true,
        macOSEnabled: Bool = true,
        telegramEnabled: Bool = false,
        discordEnabled: Bool = false,
        telegramServiceEnabled: Bool = true,
        discordServiceEnabled: Bool = true,
        telegramCredentialPresent: Bool = false,
        discordCredentialPresent: Bool = false,
        telegramChatIDPresent: Bool = true,
        discordWebhookPresent: Bool? = nil
    ) {
        self.globalEnabled = globalEnabled
        self.macOSEnabled = macOSEnabled
        self.telegramEnabled = telegramEnabled
        self.discordEnabled = discordEnabled
        self.telegramServiceEnabled = telegramServiceEnabled
        self.discordServiceEnabled = discordServiceEnabled
        self.telegramCredentialPresent = telegramCredentialPresent
        self.discordCredentialPresent = discordCredentialPresent
        self.telegramChatIDPresent = telegramChatIDPresent
        self.discordWebhookPresent = discordWebhookPresent ?? discordCredentialPresent
    }

    public init(settings: AppSettings, telegramCredentialPresent: Bool, discordCredentialPresent: Bool) {
        self.init(
            globalEnabled: settings.globalNotificationsEnabled,
            macOSEnabled: settings.macOSNotificationsEnabled,
            telegramEnabled: settings.telegramNotificationsEnabled,
            discordEnabled: settings.discordNotificationsEnabled,
            telegramServiceEnabled: settings.telegram.isEnabled,
            discordServiceEnabled: settings.discord.isEnabled,
            telegramCredentialPresent: telegramCredentialPresent,
            discordCredentialPresent: discordCredentialPresent,
            telegramChatIDPresent: !settings.telegram.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            discordWebhookPresent: discordCredentialPresent
        )
    }

    public func isEnabled(_ channel: CapacityAlertChannel, routing: CapacityAlertRouting) -> Bool {
        guard globalEnabled else { return false }
        switch channel {
        case .macOS:
            return routing.macOS && macOSEnabled
        case .telegram:
            return routing.telegram &&
                telegramEnabled &&
                telegramServiceEnabled &&
                telegramCredentialPresent &&
                telegramChatIDPresent
        case .discord:
            return routing.discord &&
                discordEnabled &&
                discordServiceEnabled &&
                discordCredentialPresent &&
                discordWebhookPresent
        }
    }
}
public enum CapacityAlertVisibilityStatus: String, Codable, Equatable, Sendable {
    case deliverable
    case disabled
    case noEffectiveChannel
    case pendingBalanceBinding
    case unsupportedSource
    case recoveryRequired
    case noRules
}

public enum CapacityAlertVisibilityRowKind: String, Codable, Equatable, Sendable {
    case capacityRule
    case pendingBalanceBinding
    case unsupportedNotice
    case recoveryRequired
    case empty
}

public struct CapacityAlertVisibilityChannel: Equatable, Identifiable, Sendable {
    public let channel: CapacityAlertChannel
    public let routed: Bool
    public let effective: Bool
    public let deliveryStatus: CapacityAlertDeliveryStatus?

    public var id: String { channel.rawValue }

    public init(channel: CapacityAlertChannel, routed: Bool, effective: Bool, deliveryStatus: CapacityAlertDeliveryStatus?) {
        self.channel = channel
        self.routed = routed
        self.effective = effective
        self.deliveryStatus = deliveryStatus
    }
}

public struct CapacityAlertVisibilityRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: CapacityAlertVisibilityRowKind
    public let provider: Provider?
    public let seriesID: CapacitySeriesID?
    public let conditionKind: CapacityAlertConditionKind?
    public let percentThresholds: [CapacityAlertPercentThreshold]
    public let balanceThresholdCanonical: String?
    public let balanceCurrency: String?
    public let enabled: Bool
    public let deliverable: Bool
    public let readOnly: Bool
    public let status: CapacityAlertVisibilityStatus
    public let recoveryCode: String?
    public let recoveryWriteBlocked: Bool
    public let channels: [CapacityAlertVisibilityChannel]

    public var conditionSummary: String {
        switch conditionKind {
        case .percentThresholds:
            return percentThresholds.map(Self.percentThresholdLabel).joined(separator: "/")
        case .balanceBelow:
            guard let balanceThresholdCanonical, let balanceCurrency else { return "" }
            return "< \(balanceThresholdCanonical) \(balanceCurrency)"
        case .pendingBalanceCurrencyBinding:
            return "Pending balance"
        case nil:
            return ""
        }
    }

    public init(
        id: String,
        kind: CapacityAlertVisibilityRowKind,
        provider: Provider? = nil,
        seriesID: CapacitySeriesID? = nil,
        conditionKind: CapacityAlertConditionKind? = nil,
        percentThresholds: [CapacityAlertPercentThreshold] = [],
        balanceThresholdCanonical: String? = nil,
        balanceCurrency: String? = nil,
        enabled: Bool = false,
        deliverable: Bool = false,
        readOnly: Bool = false,
        status: CapacityAlertVisibilityStatus,
        recoveryCode: String? = nil,
        recoveryWriteBlocked: Bool = false,
        channels: [CapacityAlertVisibilityChannel] = []
    ) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.seriesID = seriesID
        self.conditionKind = conditionKind
        self.percentThresholds = percentThresholds
        self.balanceThresholdCanonical = balanceThresholdCanonical
        self.balanceCurrency = balanceCurrency
        self.enabled = enabled
        self.deliverable = deliverable
        self.readOnly = readOnly
        self.status = status
        self.recoveryCode = recoveryCode
        self.recoveryWriteBlocked = recoveryWriteBlocked
        self.channels = channels
    }

    private static func percentThresholdLabel(_ threshold: CapacityAlertPercentThreshold) -> String {
        switch threshold {
        case .reset: return "Reset"
        case .fifty: return "50%"
        case .eighty: return "80%"
        case .hundred: return "100%"
        }
    }
}

public struct CapacityAlertVisibilitySummary: Equatable, Sendable {
    public let status: CapacityAlertVisibilityStatus
    public let rows: [CapacityAlertVisibilityRow]
    public let deliverableRuleCount: Int
    public let pendingRuleCount: Int
    public let unsupportedNoticeCount: Int
    public let recoveryCodes: [String]
    public let recoveryWriteBlocked: Bool
    public let effectiveChannelCount: Int
    public let pendingDeliveryCount: Int
    public let failedDeliveryCount: Int

    public var recoveryRequired: Bool { status == .recoveryRequired }

    public init(
        status: CapacityAlertVisibilityStatus,
        rows: [CapacityAlertVisibilityRow],
        deliverableRuleCount: Int,
        pendingRuleCount: Int,
        unsupportedNoticeCount: Int,
        recoveryCodes: [String],
        recoveryWriteBlocked: Bool,
        effectiveChannelCount: Int,
        pendingDeliveryCount: Int,
        failedDeliveryCount: Int
    ) {
        self.status = status
        self.rows = rows
        self.deliverableRuleCount = deliverableRuleCount
        self.pendingRuleCount = pendingRuleCount
        self.unsupportedNoticeCount = unsupportedNoticeCount
        self.recoveryCodes = recoveryCodes
        self.recoveryWriteBlocked = recoveryWriteBlocked
        self.effectiveChannelCount = effectiveChannelCount
        self.pendingDeliveryCount = pendingDeliveryCount
        self.failedDeliveryCount = failedDeliveryCount
    }
}

public struct CapacityAlertVisibilityBuilder: Sendable {
    public init() {}

    public func make(
        runtime: CapacityRuntimeControl,
        runtimeStatus: CapacityPersistenceStatus,
        rules: [CapacityAlertRule],
        rulesStatus: CapacityPersistenceStatus,
        deliveryStates: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState],
        deliveryStatus: CapacityPersistenceStatus,
        migrationStatus: CapacityPersistenceStatus? = nil,
        channels: CapacityAlertChannelSettings,
        includeUnsupportedNotices: Bool = true
    ) -> CapacityAlertVisibilitySummary {
        var rows: [CapacityAlertVisibilityRow] = []
        var recoveryCodes: [String] = []
        var recoveryWriteBlocked = false

        for (store, status) in recoveryStatuses(runtimeStatus: runtimeStatus, rulesStatus: rulesStatus, deliveryStatus: deliveryStatus, migrationStatus: migrationStatus) {
            guard case let .recoveryRequired(writeBlocked, code) = status else { continue }
            recoveryCodes.append(code)
            recoveryWriteBlocked = recoveryWriteBlocked || writeBlocked
            rows.append(CapacityAlertVisibilityRow(
                id: "recovery/\(store)/\(code)",
                kind: .recoveryRequired,
                readOnly: true,
                status: .recoveryRequired,
                recoveryCode: code,
                recoveryWriteBlocked: writeBlocked
            ))
        }

        var unsupportedProviders: [Provider] = []
        let deliveryReadable = !runtimeStatus.recoveryRequired && !rulesStatus.recoveryRequired && !deliveryStatus.recoveryRequired && runtime.assessmentEnabled

        for rule in rules.sorted(by: { $0.id < $1.id }) {
            if rule.provider == .codex || rule.provider == .gemini {
                appendUnsupported(rule.provider, to: &unsupportedProviders)
                continue
            }

            let rowChannels = CapacityAlertChannel.allCases.map { channel in
                let key = CapacityAlertDeliveryKey(rule: rule, channel: channel)
                return CapacityAlertVisibilityChannel(
                    channel: channel,
                    routed: routed(channel, by: rule.routing),
                    effective: deliveryReadable && channels.isEnabled(channel, routing: rule.routing),
                    deliveryStatus: deliveryStates[key]?.status
                )
            }
            let hasEffectiveChannel = rowChannels.contains { $0.effective }
            let status: CapacityAlertVisibilityStatus
            let readOnly: Bool
            let deliverable: Bool

            if rule.isPendingBalanceBinding {
                status = .pendingBalanceBinding
                readOnly = true
                deliverable = false
            } else if !runtime.assessmentEnabled || !rule.enabled {
                status = .disabled
                readOnly = false
                deliverable = false
            } else if !deliveryReadable || !hasEffectiveChannel {
                status = .noEffectiveChannel
                readOnly = false
                deliverable = false
            } else {
                status = .deliverable
                readOnly = false
                deliverable = true
            }

            rows.append(CapacityAlertVisibilityRow(
                id: rule.id,
                kind: rule.isPendingBalanceBinding ? .pendingBalanceBinding : .capacityRule,
                provider: rule.provider,
                seriesID: rule.seriesID,
                conditionKind: rule.condition.kind,
                percentThresholds: sortedPercentThresholds(rule.condition.enabledPercentThresholds),
                balanceThresholdCanonical: rule.condition.thresholdCanonical,
                balanceCurrency: rule.condition.balanceCurrency,
                enabled: rule.enabled,
                deliverable: deliverable,
                readOnly: readOnly,
                status: status,
                channels: rowChannels
            ))
        }

        if includeUnsupportedNotices {
            appendUnsupported(.codex, to: &unsupportedProviders)
            appendUnsupported(.gemini, to: &unsupportedProviders)
        }

        for provider in unsupportedProviders.sorted(by: { $0.rawValue < $1.rawValue }) {
            rows.append(CapacityAlertVisibilityRow(
                id: "unsupported/\(provider.rawValue)",
                kind: .unsupportedNotice,
                provider: provider,
                deliverable: false,
                readOnly: true,
                status: .unsupportedSource
            ))
        }

        if rows.isEmpty {
            rows.append(CapacityAlertVisibilityRow(id: "empty/no-rules", kind: .empty, readOnly: true, status: .noRules))
        }

        let deliverableRuleCount = rows.filter { $0.kind == .capacityRule && $0.deliverable }.count
        let pendingRuleCount = rows.filter { $0.status == .pendingBalanceBinding }.count
        let unsupportedNoticeCount = rows.filter { $0.kind == .unsupportedNotice }.count
        let effectiveChannelCount = rows.flatMap(\.channels).filter(\.effective).count
        let pendingDeliveryCount = rows.flatMap(\.channels).filter { $0.deliveryStatus == .pending }.count
        let failedDeliveryCount = rows.flatMap(\.channels).filter { $0.deliveryStatus == .failed }.count

        let status: CapacityAlertVisibilityStatus
        if !recoveryCodes.isEmpty {
            status = .recoveryRequired
        } else if deliverableRuleCount > 0 {
            status = .deliverable
        } else if pendingRuleCount > 0 {
            status = .pendingBalanceBinding
        } else if unsupportedNoticeCount > 0 {
            status = .unsupportedSource
        } else {
            status = .noRules
        }

        return CapacityAlertVisibilitySummary(
            status: status,
            rows: rows,
            deliverableRuleCount: deliverableRuleCount,
            pendingRuleCount: pendingRuleCount,
            unsupportedNoticeCount: unsupportedNoticeCount,
            recoveryCodes: recoveryCodes,
            recoveryWriteBlocked: recoveryWriteBlocked,
            effectiveChannelCount: effectiveChannelCount,
            pendingDeliveryCount: pendingDeliveryCount,
            failedDeliveryCount: failedDeliveryCount
        )
    }

    private func recoveryStatuses(
        runtimeStatus: CapacityPersistenceStatus,
        rulesStatus: CapacityPersistenceStatus,
        deliveryStatus: CapacityPersistenceStatus,
        migrationStatus: CapacityPersistenceStatus?
    ) -> [(String, CapacityPersistenceStatus)] {
        var statuses: [(String, CapacityPersistenceStatus)] = [
            ("runtime", runtimeStatus),
            ("rules", rulesStatus),
            ("delivery", deliveryStatus)
        ]
        if let migrationStatus {
            statuses.append(("migration", migrationStatus))
        }
        return statuses
    }

    private func sortedPercentThresholds(_ thresholds: Set<CapacityAlertPercentThreshold>) -> [CapacityAlertPercentThreshold] {
        [.reset, .fifty, .eighty, .hundred].filter { thresholds.contains($0) }
    }

    private func routed(_ channel: CapacityAlertChannel, by routing: CapacityAlertRouting) -> Bool {
        switch channel {
        case .macOS: return routing.macOS
        case .telegram: return routing.telegram
        case .discord: return routing.discord
        }
    }

    private func appendUnsupported(_ provider: Provider, to providers: inout [Provider]) {
        guard !providers.contains(provider) else { return }
        providers.append(provider)
    }
}

public struct CapacityAlertDeliveryAttempt: Equatable, Identifiable, Sendable {
    public let id: String
    public let key: CapacityAlertDeliveryKey
    public let provider: Provider
    public let seriesID: CapacitySeriesID
    public let threshold: CapacityAlertPercentThreshold?
    public let usedPercent: Int?
    public let cycleID: String?
    public let balanceCurrency: String?
    public let balanceThresholdCanonical: String?
    public let balanceCrossingGeneration: Int?
    public let createdAt: Date

    public init(key: CapacityAlertDeliveryKey, provider: Provider, seriesID: CapacitySeriesID, threshold: CapacityAlertPercentThreshold?, usedPercent: Int?, cycleID: String?, balanceCurrency: String?, balanceThresholdCanonical: String?, balanceCrossingGeneration: Int?, createdAt: Date) {
        self.key = key
        self.provider = provider
        self.seriesID = seriesID
        self.threshold = threshold
        self.usedPercent = usedPercent
        self.cycleID = cycleID
        self.balanceCurrency = balanceCurrency
        self.balanceThresholdCanonical = balanceThresholdCanonical
        self.balanceCrossingGeneration = balanceCrossingGeneration
        self.createdAt = createdAt
        if let balanceCurrency, let balanceThresholdCanonical, let balanceCrossingGeneration {
            self.id = "\(key.ruleID)/revision-\(key.conditionRevision)/\(balanceCurrency)/\(balanceThresholdCanonical)/\(balanceCrossingGeneration)/\(key.channel.rawValue)"
        } else if let threshold {
            self.id = "\(key.description)/\(threshold.rawValue)"
        } else {
            self.id = key.description
        }
    }
}

public struct CapacityAlertTransitionResult: Equatable, Sendable {
    public let attempts: [CapacityAlertDeliveryAttempt]
    public let states: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState]
    public let deliveryBlocked: Bool
}

public struct CapacityAlertDeliveryOutcome: Equatable, Sendable {
    public let attempt: CapacityAlertDeliveryAttempt
    public let succeeded: Bool
    public let completedAt: Date

    public init(attempt: CapacityAlertDeliveryAttempt, succeeded: Bool, completedAt: Date) {
        self.attempt = attempt
        self.succeeded = succeeded
        self.completedAt = completedAt
    }
}

public struct CapacityAlertTransitionEngine: Sendable {
    public init() {}

    public func evaluate(
        rules: [CapacityAlertRule],
        assessments: [CapacityAssessment],
        previousStates: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState],
        channels: CapacityAlertChannelSettings,
        runtime: CapacityRuntimeControl = CapacityRuntimeControl(),
        rulesReadable: Bool = true,
        deliveryReadable: Bool = true,
        now: Date
    ) -> CapacityAlertTransitionResult {
        guard runtime.schemaVersion == 1,
              runtime.assessmentEnabled,
              rulesReadable,
              deliveryReadable else {
            return CapacityAlertTransitionResult(attempts: [], states: previousStates, deliveryBlocked: true)
        }
        guard channels.globalEnabled else {
            return CapacityAlertTransitionResult(attempts: [], states: previousStates, deliveryBlocked: false)
        }

        let assessmentsBySeries = Dictionary(grouping: assessments) { $0.observation.seriesID.canonicalID }
        var states = previousStates
        var attempts: [CapacityAlertDeliveryAttempt] = []

        for rule in rules.sorted(by: { $0.id < $1.id }) {
            guard rule.enabled, !rule.isPendingBalanceBinding, rule.provider != .codex, rule.provider != .gemini else { continue }
            guard let assessment = assessmentsBySeries[rule.seriesID.canonicalID]?.first(where: { assessment in
                let observation = assessment.observation
                return observation.seriesID == rule.seriesID && observation.authority == rule.authority && observation.stability == rule.stability
            }) else { continue }
            guard assessment.freshness == .fresh, assessment.observation.parserRevision != "legacyV1" else { continue }

            switch rule.condition.kind {
            case .percentThresholds:
                guard assessment.alertEligibility == .percent else { continue }
                evaluatePercent(rule: rule, assessment: assessment, channels: channels, now: now, states: &states, attempts: &attempts)
            case .balanceBelow:
                guard assessment.alertEligibility == .balance else { continue }
                evaluateBalance(rule: rule, assessment: assessment, channels: channels, now: now, states: &states, attempts: &attempts)
            case .pendingBalanceCurrencyBinding:
                continue
            }
        }

        return CapacityAlertTransitionResult(attempts: attempts, states: states, deliveryBlocked: false)
    }

    public func applyingDeliveryOutcomes(_ outcomes: [CapacityAlertDeliveryOutcome], to states: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState]) -> [CapacityAlertDeliveryKey: CapacityAlertDeliveryState] {
        var updated = states
        for outcome in outcomes {
            guard var state = updated[outcome.attempt.key] else { continue }
            state.lastAttemptAt = outcome.completedAt
            if outcome.succeeded {
                state.status = .delivered
                state.lastSuccessAt = outcome.completedAt
                switch state.conditionState {
                case let .percent(activeCycleID, lastUsed, deliveredThresholds):
                    var delivered = deliveredThresholds
                    if let threshold = outcome.attempt.threshold { delivered.insert(threshold) }
                    state.conditionState = .percent(activeCycleID: outcome.attempt.cycleID ?? activeCycleID, lastUsed: outcome.attempt.usedPercent ?? lastUsed, deliveredThresholds: delivered)
                case let .balance(lastKnownBelow, crossingGeneration, _):
                    state.conditionState = .balance(lastKnownBelow: lastKnownBelow, crossingGeneration: crossingGeneration, deliveredCrossingGeneration: outcome.attempt.balanceCrossingGeneration ?? crossingGeneration)
                }
            } else {
                state.status = .failed
            }
            updated[outcome.attempt.key] = state
        }
        return updated
    }

    private func evaluatePercent(rule: CapacityAlertRule, assessment: CapacityAssessment, channels: CapacityAlertChannelSettings, now: Date, states: inout [CapacityAlertDeliveryKey: CapacityAlertDeliveryState], attempts: inout [CapacityAlertDeliveryAttempt]) {
        guard let used = assessment.observation.value.usedPercent else { return }
        let cycleID = assessment.observation.cycleID
        for channel in CapacityAlertChannel.allCases where channels.isEnabled(channel, routing: rule.routing) {
            let key = CapacityAlertDeliveryKey(rule: rule, channel: channel)
            let previous = states[key]
            let parts = previous?.percentParts
            if parts == nil {
                states[key] = try? CapacityAlertDeliveryState(key: key, status: .idle, conditionState: .percent(activeCycleID: cycleID, lastUsed: used, deliveredThresholds: []))
                continue
            }

            let previousCycle = parts?.activeCycleID
            let isNewCycle = previousCycle != cycleID
            let delivered = isNewCycle ? Set<CapacityAlertPercentThreshold>() : (parts?.deliveredThresholds ?? [])
            let previousLastUsed = parts?.lastUsed
            var attempted = false
            let attemptAllowed = canAttempt(previous, now: now)

            if isNewCycle {
                let resetEnabled = rule.condition.enabledPercentThresholds.contains(.reset)
                let hadPriorCycle = previousCycle != nil
                let hasNewCycle = cycleID != nil
                if resetEnabled, hadPriorCycle, hasNewCycle, used < 50, !delivered.contains(.reset), attemptAllowed {
                    attempts.append(percentAttempt(rule: rule, key: key, threshold: .reset, used: used, cycleID: cycleID, assessment: assessment, now: now))
                    attempted = true
                }
            } else {
                for threshold in [CapacityAlertPercentThreshold.fifty, .eighty, .hundred] where rule.condition.enabledPercentThresholds.contains(threshold) {
                    guard let percent = percentValue(threshold) else { continue }
                    let wasBelow = (previousLastUsed ?? used) < percent
                    if wasBelow, used >= percent, !delivered.contains(threshold), attemptAllowed {
                        attempts.append(percentAttempt(rule: rule, key: key, threshold: threshold, used: used, cycleID: cycleID, assessment: assessment, now: now))
                        attempted = true
                    }
                }
            }

            if !attempted, let previous, !attemptAllowed, (previous.status == .pending || previous.status == .failed) {
                states[key] = previous
                continue
            }

            let nextLastUsed = attempted ? previousLastUsed : used
            let status: CapacityAlertDeliveryStatus = attempted ? .pending : .idle
            states[key] = try? CapacityAlertDeliveryState(key: key, status: status, lastAttemptAt: attempted ? now : previous?.lastAttemptAt, lastSuccessAt: previous?.lastSuccessAt, conditionState: .percent(activeCycleID: cycleID, lastUsed: nextLastUsed, deliveredThresholds: delivered))
        }
    }

    private func evaluateBalance(rule: CapacityAlertRule, assessment: CapacityAssessment, channels: CapacityAlertChannelSettings, now: Date, states: inout [CapacityAlertDeliveryKey: CapacityAlertDeliveryState], attempts: inout [CapacityAlertDeliveryAttempt]) {
        guard let amount = assessment.observation.value.moneyAmount,
              let currency = assessment.observation.value.currency,
              let threshold = rule.condition.balanceThreshold,
              let ruleCurrency = rule.condition.balanceCurrency,
              currency == ruleCurrency else { return }
        let below = amount < threshold
        let thresholdCanonical = CapacityCanonical.thresholdCanonical(threshold)

        for channel in CapacityAlertChannel.allCases where channels.isEnabled(channel, routing: rule.routing) {
            let key = CapacityAlertDeliveryKey(rule: rule, channel: channel)
            let previous = states[key]
            guard let parts = previous?.balanceParts else {
                states[key] = try? CapacityAlertDeliveryState(key: key, status: .idle, conditionState: .balance(lastKnownBelow: below, crossingGeneration: 0, deliveredCrossingGeneration: nil))
                continue
            }

            var crossingGeneration = parts.crossingGeneration
            var deliveredCrossingGeneration = parts.deliveredCrossingGeneration
            var lastKnownBelow = parts.lastKnownBelow
            var shouldAttempt = false
            let attemptAllowed = canAttempt(previous, now: now)

            if below {
                if lastKnownBelow == false {
                    crossingGeneration += 1
                    deliveredCrossingGeneration = nil
                    shouldAttempt = true
                } else if lastKnownBelow == true,
                          deliveredCrossingGeneration != crossingGeneration {
                    shouldAttempt = true
                }
                lastKnownBelow = true
            } else {
                lastKnownBelow = false
            }

            if shouldAttempt, attemptAllowed {
                attempts.append(CapacityAlertDeliveryAttempt(key: key, provider: rule.provider, seriesID: rule.seriesID, threshold: nil, usedPercent: nil, cycleID: nil, balanceCurrency: currency, balanceThresholdCanonical: thresholdCanonical, balanceCrossingGeneration: crossingGeneration, createdAt: now))
                states[key] = try? CapacityAlertDeliveryState(key: key, status: .pending, lastAttemptAt: now, lastSuccessAt: previous?.lastSuccessAt, conditionState: .balance(lastKnownBelow: lastKnownBelow, crossingGeneration: crossingGeneration, deliveredCrossingGeneration: deliveredCrossingGeneration))
            } else if shouldAttempt, let previous, !attemptAllowed {
                states[key] = previous
            } else {
                states[key] = try? CapacityAlertDeliveryState(key: key, status: .idle, lastAttemptAt: previous?.lastAttemptAt, lastSuccessAt: previous?.lastSuccessAt, conditionState: .balance(lastKnownBelow: lastKnownBelow, crossingGeneration: crossingGeneration, deliveredCrossingGeneration: deliveredCrossingGeneration))
            }
        }
    }

    private func canAttempt(_ state: CapacityAlertDeliveryState?, now: Date) -> Bool {
        guard let state else { return true }
        switch state.status {
        case .pending, .failed:
            guard let lastAttemptAt = state.lastAttemptAt else { return true }
            return now.timeIntervalSince(lastAttemptAt) >= 300
        case .idle, .delivered:
            return true
        }
    }

    private func percentAttempt(rule: CapacityAlertRule, key: CapacityAlertDeliveryKey, threshold: CapacityAlertPercentThreshold, used: Int, cycleID: String?, assessment: CapacityAssessment, now: Date) -> CapacityAlertDeliveryAttempt {
        CapacityAlertDeliveryAttempt(key: key, provider: rule.provider, seriesID: rule.seriesID, threshold: threshold, usedPercent: used, cycleID: cycleID, balanceCurrency: nil, balanceThresholdCanonical: nil, balanceCrossingGeneration: nil, createdAt: now)
    }

    private func percentValue(_ threshold: CapacityAlertPercentThreshold) -> Int? {
        switch threshold {
        case .reset: return nil
        case .fifty: return 50
        case .eighty: return 80
        case .hundred: return 100
        }
    }
}

public enum CapacityLegacyEvidenceConverter {
    public struct Result: Equatable, Sendable {
        public let observations: [CapacityObservation]
        public let quarantine: [CapacityEvidenceQuarantineEntry]
    }

    public static func convert(samples: [ProviderLimitSample], now: Date) -> Result {
        var observations: [CapacityObservation] = []
        var quarantine: [CapacityEvidenceQuarantineEntry] = []
        for sample in samples {
            guard sample.remainingPercent == 100 - sample.usedPercent else {
                quarantine.append(Self.quarantine(for: sample, code: "invalidUsedRemainingPair", now: now))
                continue
            }
            do {
                observations.append(try observation(from: sample, now: now))
            } catch {
                quarantine.append(Self.quarantine(for: sample, code: "invalidLegacyMapping", now: now))
            }
        }
        return Result(observations: observations, quarantine: quarantine)
    }

    public static func sourceDigest(for data: Data) -> String {
        CapacityCanonical.sha256Hex(data)
    }

    public static func marker(for data: Data, committedGeneration: Int) -> CapacityLegacyMigrationMarker {
        CapacityLegacyMigrationMarker(sourceDigest: sourceDigest(for: data), committedGeneration: committedGeneration)
    }

    public static func shouldMigrate(data: Data, existingMarker: CapacityLegacyMigrationMarker?) -> Bool {
        existingMarker?.sourceDigest != sourceDigest(for: data)
    }

    private static func observation(from sample: ProviderLimitSample, now: Date) throws -> CapacityObservation {
        let series: CapacitySeriesID
        switch (sample.provider, sample.window) {
        case (.claude, .fiveHour):
            series = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        case (.claude, .weekly):
            series = try CapacitySeriesID(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, unit: .percent)
        default:
            throw CapacityContractError.unsupportedSeries
        }
        let mapped = sourceMapping(sample.source)
        return try CapacityObservation(
            seriesID: series,
            observedAt: sample.timestamp,
            resetAt: nil,
            value: try CapacityValue(usedPercent: sample.usedPercent),
            authority: mapped.authority,
            stability: mapped.stability,
            consent: .notRequired,
            freshnessPolicy: .init(maximumAge: 45 * 86_400),
            comparability: mapped.comparability,
            parserRevision: "legacyV1",
            now: now
        )
    }

    private static func sourceMapping(_ source: String) -> (authority: CapacityAuthority, stability: CapacityStability, comparability: CapacityComparability) {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == UsageDataSource.officialStatusline.rawValue.lowercased() || normalized == UsageDataSource.officialStatusline.label.lowercased() {
            return (.providerReported, .supported, .comparable)
        }
        if normalized == UsageDataSource.localLog.rawValue.lowercased() || normalized == UsageDataSource.localLog.label.lowercased() {
            return (.localDerived, .compatibilityBridge, .incomparable)
        }
        if normalized == UsageDataSource.manual.rawValue.lowercased() || normalized == UsageDataSource.manual.label.lowercased() || normalized == UsageDataSource.estimated.rawValue.lowercased() || normalized == UsageDataSource.estimated.label.lowercased() {
            return (.userEntered, .manual, .incomparable)
        }
        return (.synthetic, .unavailable, .unavailable)
    }

    private static func quarantine(for sample: ProviderLimitSample, code: String, now: Date) -> CapacityEvidenceQuarantineEntry {
        let object: [String: Any] = [
            "provider": sample.provider.rawValue,
            "window": sample.window.rawValue,
            "timestamp": CapacityCanonical.dateString(sample.timestamp),
            "usedPercent": sample.usedPercent,
            "remainingPercent": sample.remainingPercent
        ]
        let digest = (try? CapacityCanonical.jsonData(object)).map(CapacityCanonical.sha256Hex) ?? CapacityCanonical.sha256Hex(Data(sample.id.utf8))
        return CapacityEvidenceQuarantineEntry(recordDigest: digest, code: code, firstObservedAt: min(sample.timestamp, now), lastObservedAt: min(sample.timestamp, now))
    }
}

public struct CapacityLegacyMigrationMarker: Codable, Equatable, Sendable {
    public let sourceDigest: String
    public let committedGeneration: Int

    public init(sourceDigest: String, committedGeneration: Int) {
        self.sourceDigest = sourceDigest
        self.committedGeneration = committedGeneration
    }
}

public enum CapacityAlertLegacyMigrator {
    public struct Result: Equatable, Sendable {
        public let rules: [CapacityAlertRule]
        public let marker: CapacityAlertMigrationMarker
        public let didMigrate: Bool
    }

    public static func migrate(settings: AppSettings, deepSeekBalance: ProviderBalance?, existingMarker: CapacityAlertMigrationMarker? = nil) throws -> Result {
        let digest = settingsDigest(settings, deepSeekBalance: deepSeekBalance)
        if let existingMarker, existingMarker.sourceSettingsDigest == digest {
            return Result(rules: [], marker: existingMarker, didMigrate: false)
        }

        var rules: [CapacityAlertRule] = []
        for legacy in settings.alertRules where legacy.provider == .claude {
            guard let series = try? series(for: legacy) else { continue }
            rules.append(try CapacityAlertRule(
                provider: .claude,
                seriesID: series,
                authority: .providerReported,
                stability: .supported,
                enabled: true,
                routing: CapacityAlertRouting(macOS: legacy.macOSEnabled, telegram: legacy.telegramEnabled, discord: legacy.discordEnabled),
                condition: .percentThresholds(reset: legacy.resetEnabled, fifty: legacy.fiftyEnabled, eighty: legacy.eightyEnabled, hundred: legacy.hundredEnabled)
            ))
        }

        let balanceSeries = try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency)
        if let deepSeekBalance, CapacityValidationProxy.isValidCurrency(deepSeekBalance.currency) {
            rules.append(try CapacityAlertRule(
                provider: .deepseek,
                seriesID: balanceSeries,
                authority: .providerReported,
                stability: .supported,
                enabled: true,
                routing: CapacityAlertRouting(macOS: settings.macOSNotificationsEnabled, telegram: settings.telegramNotificationsEnabled, discord: settings.discordNotificationsEnabled),
                condition: try .balanceBelow(threshold: settings.deepSeekBalance.lowBalanceThreshold, currency: deepSeekBalance.currency, rearmAtOrAboveThreshold: true)
            ))
        } else {
            rules.append(try CapacityAlertRule(
                provider: .deepseek,
                seriesID: balanceSeries,
                authority: .providerReported,
                stability: .supported,
                enabled: false,
                routing: CapacityAlertRouting(macOS: settings.macOSNotificationsEnabled, telegram: settings.telegramNotificationsEnabled, discord: settings.discordNotificationsEnabled),
                condition: .pendingBalanceCurrencyBinding
            ))
        }

        let marker = CapacityAlertMigrationMarker(sourceSettingsDigest: digest, migratedRuleIDs: rules.map(\.id).sorted())
        return Result(rules: rules.sorted { $0.id < $1.id }, marker: marker, didMigrate: true)
    }

    public static func legacyDeepSeekDeliveryStates(rule: CapacityAlertRule, observation: CapacityObservation, channels: CapacityAlertChannelSettings, legacySentAt: Date) -> [CapacityAlertDeliveryKey: CapacityAlertDeliveryState] {
        guard rule.condition.kind == .balanceBelow,
              let amount = observation.value.moneyAmount,
              let threshold = rule.condition.balanceThreshold,
              amount < threshold else { return [:] }
        var states: [CapacityAlertDeliveryKey: CapacityAlertDeliveryState] = [:]
        for channel in CapacityAlertChannel.allCases where channels.isEnabled(channel, routing: rule.routing) {
            let key = CapacityAlertDeliveryKey(rule: rule, channel: channel)
            states[key] = try? CapacityAlertDeliveryState(key: key, status: .delivered, lastAttemptAt: legacySentAt, lastSuccessAt: legacySentAt, conditionState: .balance(lastKnownBelow: true, crossingGeneration: 0, deliveredCrossingGeneration: 0))
        }
        return states
    }

    private static func series(for rule: AlertRule) throws -> CapacitySeriesID {
        switch rule.window {
        case .fiveHour:
            return try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        case .weekly:
            return try CapacitySeriesID(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, unit: .percent)
        case .dailyRequests:
            throw CapacityContractError.unsupportedSeries
        }
    }

    private static func settingsDigest(_ settings: AppSettings, deepSeekBalance: ProviderBalance?) -> String {
        let migratedClaudeRules = settings.alertRules
            .filter { $0.provider == .claude }
            .sorted { $0.id < $1.id }
            .map { rule -> [String: Any] in
                [
                    "window": rule.window.rawValue,
                    "reset": rule.resetEnabled,
                    "fifty": rule.fiftyEnabled,
                    "eighty": rule.eightyEnabled,
                    "hundred": rule.hundredEnabled,
                    "macOS": rule.macOSEnabled,
                    "telegram": rule.telegramEnabled,
                    "discord": rule.discordEnabled
                ]
            }
        let officialCurrency = deepSeekBalance
            .map(\.currency)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .flatMap { CapacityValidationProxy.isValidCurrency($0) ? $0 : nil } ?? ""

        let object: [String: Any] = [
            "schema": 2,
            "claudeAlertRules": migratedClaudeRules,
            "deepSeekBalance": [
                "officialCurrency": officialCurrency,
                "lowBalanceThreshold": CapacityCanonical.thresholdCanonical(settings.deepSeekBalance.lowBalanceThreshold),
                "routing": [
                    "macOS": settings.macOSNotificationsEnabled,
                    "telegram": settings.telegramNotificationsEnabled,
                    "discord": settings.discordNotificationsEnabled
                ]
            ]
        ]
        let data = (try? CapacityCanonical.jsonData(object)) ?? Data()
        return CapacityCanonical.sha256Hex(data)
    }
}

public struct CapacityAlertMigrationMarker: Codable, Equatable, Sendable {
    public let sourceSettingsDigest: String
    public let migratedRuleIDs: [String]

    public init(sourceSettingsDigest: String, migratedRuleIDs: [String]) {
        self.sourceSettingsDigest = sourceSettingsDigest
        self.migratedRuleIDs = migratedRuleIDs.sorted()
    }
}

private struct CapacityValidationProxy {
    static func isValidCurrency(_ value: String) -> Bool {
        guard value.utf8.count == 3 else { return false }
        return value.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
    }
}

private extension CapacityAlertDeliveryState {
    var percentParts: (activeCycleID: String?, lastUsed: Int?, deliveredThresholds: Set<CapacityAlertPercentThreshold>)? {
        guard case let .percent(activeCycleID, lastUsed, deliveredThresholds) = conditionState else { return nil }
        return (activeCycleID, lastUsed, deliveredThresholds)
    }

    var balanceParts: (lastKnownBelow: Bool?, crossingGeneration: Int, deliveredCrossingGeneration: Int?)? {
        guard case let .balance(lastKnownBelow, crossingGeneration, deliveredCrossingGeneration) = conditionState else { return nil }
        return (lastKnownBelow, crossingGeneration, deliveredCrossingGeneration)
    }
}

private enum CapacityGenericLoadResult<Payload> {
    case value(Payload, CapacityPersistenceSource)
    case absent
    case blocked(code: String)
}

private final class CapacityTransactionalJSONStore<Payload: Codable & Sendable>: @unchecked Sendable {
    private struct GenericTransaction: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case prepared, primaryReplaced }
        let baseChecksum: String?
        let targetChecksum: String
        let phase: Phase
    }

    private let files: CapacityEvidenceFileSet
    private let fileSystem: any CapacityEvidenceFileSystem
    private let validate: @Sendable (Payload) throws -> Void
    private let encoder = CapacityEvidenceCoders.encoder()
    private let decoder = CapacityEvidenceCoders.decoder()

    init(directory: URL, fileName: String, fileSystem: any CapacityEvidenceFileSystem, validate: @escaping @Sendable (Payload) throws -> Void) {
        self.files = CapacityEvidenceFileSet(directory: directory, fileName: fileName)
        self.fileSystem = fileSystem
        self.validate = validate
    }

    func load() -> CapacityGenericLoadResult<Payload> {
        do {
            try fileSystem.createDirectory(at: files.directory)
            return try withAdvisoryLock {
                try recover(cleanupAllowed: true)
            }
        } catch {
            return .blocked(code: "transactionalRecoveryRequired")
        }
    }

    func save(_ payload: Payload) -> CapacityPersistenceStatus {
        do {
            try validate(payload)
            try fileSystem.createDirectory(at: files.directory)
            return try withAdvisoryLock {
                let recovery = try recover(cleanupAllowed: true)
                guard case let .value(_, source) = recovery else {
                    if case .absent = recovery {
                        try commit(payload, baseSource: .empty, baseChecksum: nil)
                        return .ready(source: .primary, generation: nil)
                    }
                    return .recoveryRequired(writeBlocked: true, code: "transactionalRecoveryRequired")
                }
                let baseChecksum = try currentPrimaryChecksum(source: source)
                try commit(payload, baseSource: source, baseChecksum: baseChecksum)
                return .ready(source: .primary, generation: nil)
            }
        } catch {
            return .recoveryRequired(writeBlocked: true, code: "transactionalCommitFailed")
        }
    }

    private func recover(cleanupAllowed: Bool) throws -> CapacityGenericLoadResult<Payload> {
        let primaryExists = fileSystem.fileExists(at: files.primary)
        let backupExists = fileSystem.fileExists(at: files.backup)
        let tempExists = fileSystem.fileExists(at: files.temp)
        let backupTempExists = fileSystem.fileExists(at: files.backupTemp)
        let txnExists = fileSystem.fileExists(at: files.txn)
        let primary = validPayload(at: files.primary)
        let backup = validPayload(at: files.backup)
        let txn = validTransaction()
        if let primary {
            if cleanupAllowed { try cleanupOrphans() }
            return .value(primary, .primary)
        }
        if !primaryExists,
           let txn,
           txn.phase == .prepared,
           let tempData = try? fileSystem.readData(at: files.temp),
           CapacityCanonical.sha256Hex(tempData) == txn.targetChecksum,
           let temp = validPayload(data: tempData) {
            if cleanupAllowed {
                try fileSystem.replaceItem(at: files.primary, withItemAt: files.temp)
                try cleanupOrphans()
            }
            return .value(temp, .temp)
        }
        if let backup {
            if cleanupAllowed { try cleanupOrphans() }
            return .value(backup, .backup)
        }
        if !primaryExists && !backupExists && !tempExists && !backupTempExists && !txnExists {
            return .absent
        }
        return .blocked(code: "transactionalRecoveryRequired")
    }

    private func commit(_ payload: Payload, baseSource: CapacityPersistenceSource, baseChecksum: String?) throws {
        try cleanupOrphans()
        let data = try encoder.encode(payload)
        let targetChecksum = CapacityCanonical.sha256Hex(data)
        try fileSystem.writeDataExclusively(data, to: files.temp)
        try fileSystem.synchronizeFile(at: files.temp)
        try fileSystem.synchronizeDirectory(at: files.directory)
        try writeTransaction(GenericTransaction(baseChecksum: baseChecksum, targetChecksum: targetChecksum, phase: .prepared))
        if baseSource == .primary, fileSystem.fileExists(at: files.primary) {
            let primaryBytes = try fileSystem.readData(at: files.primary)
            try fileSystem.writeDataExclusively(primaryBytes, to: files.backupTemp)
            try fileSystem.synchronizeFile(at: files.backupTemp)
            try fileSystem.replaceItem(at: files.backup, withItemAt: files.backupTemp)
            try fileSystem.synchronizeDirectory(at: files.directory)
        }
        try fileSystem.replaceItem(at: files.primary, withItemAt: files.temp)
        try fileSystem.synchronizeDirectory(at: files.directory)
        try writeTransaction(GenericTransaction(baseChecksum: baseChecksum, targetChecksum: targetChecksum, phase: .primaryReplaced))
        try cleanupOrphans()
    }

    private func validPayload(at url: URL) -> Payload? {
        guard fileSystem.fileExists(at: url), let data = try? fileSystem.readData(at: url) else { return nil }
        return validPayload(data: data)
    }

    private func validPayload(data: Data) -> Payload? {
        guard let payload = try? decoder.decode(Payload.self, from: data), (try? validate(payload)) != nil else { return nil }
        return payload
    }

    private func validTransaction() -> GenericTransaction? {
        guard fileSystem.fileExists(at: files.txn), let data = try? fileSystem.readData(at: files.txn) else { return nil }
        return try? decoder.decode(GenericTransaction.self, from: data)
    }

    private func writeTransaction(_ transaction: GenericTransaction) throws {
        try fileSystem.removeItemIfExists(at: files.txn)
        let data = try encoder.encode(transaction)
        try fileSystem.writeDataExclusively(data, to: files.txn)
        try fileSystem.synchronizeFile(at: files.txn)
    }

    private func cleanupOrphans() throws {
        try fileSystem.removeItemIfExists(at: files.temp)
        try fileSystem.removeItemIfExists(at: files.backupTemp)
        try fileSystem.removeItemIfExists(at: files.txn)
        try fileSystem.synchronizeDirectory(at: files.directory)
    }

    private func currentPrimaryChecksum(source: CapacityPersistenceSource) throws -> String? {
        guard source == .primary, fileSystem.fileExists(at: files.primary) else { return nil }
        return try CapacityCanonical.sha256Hex(fileSystem.readData(at: files.primary))
    }

    private func withAdvisoryLock<T>(_ body: () throws -> T) throws -> T {
        try withCapacityAdvisoryLock(lockURL: files.lock, fileSystem: fileSystem, body: body)
    }
}
