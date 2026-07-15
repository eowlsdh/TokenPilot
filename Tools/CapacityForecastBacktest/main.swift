import Foundation
import TokenCore

#if os(Windows)
import ucrt
#elseif os(Linux)
import Glibc
#else
import Darwin
#endif

private let algorithmID = "claude-fixed-reset-observed-only-v1"
private let freshnessWindowSeconds: TimeInterval = 15 * 60
private let maxFeatureClockSkewSeconds: TimeInterval = 60
private let minimumResetLeadSeconds: TimeInterval = 30 * 60
private let minimumSpanSeconds: TimeInterval = 60 * 60
private let maximumGapSeconds: TimeInterval = 30 * 60
private let minimumBucketedObservations = 12
private let maximumBucketedObservations = 144
private let minimumObservedCycles = 30
private let minimumObservedProfiles = 5
private let minimumPrecision = 0.80
private let minimumRecall = 0.60
private let maximumFalsePositiveRate = 0.10
private let minimumClassificationRate = 0.70


enum BacktestError: Error, CustomStringConvertible {
    case usage(String)
    case help
    case missingDirectory(String)
    case observedPathNotIgnored
    case tooManyFixtureFiles
    case noFixtureCases
    case decodingFailed(kind: String, hashPrefix: String, detail: String)
    case invalidDate(String)
    case invalidFixture(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message + "\n\n" + Arguments.usage
        case .help:
            return Arguments.usage
        case .missingDirectory(let label):
            return "Required \(label) directory is missing or is not a directory."
        case .observedPathNotIgnored:
            return "Observed cohort input must be the ignored .gjc/evidence/forecast/local directory."
        case .tooManyFixtureFiles:
            return "Capacity forecast conformance accepts at most two JSON fixture files."
        case .noFixtureCases:
            return "Capacity forecast conformance fixtures did not contain any cases."
        case .decodingFailed(let kind, let hashPrefix, let detail):
            return "Could not decode \(kind) JSON with SHA-256 prefix \(hashPrefix): \(detail)"
        case .invalidDate(let label):
            return "Invalid ISO-8601 date in \(label)."
        case .invalidFixture(let message):
            return message
        }
    }
}

struct Arguments {
    let fixturesDirectory: URL
    let observedDirectory: URL
    let outputFile: URL

    static let usage = """
    Usage:
      swift run CapacityForecastBacktest --fixtures Tests/Fixtures/CapacityForecast --observed .gjc/evidence/forecast/local --output .gjc/evidence/forecast/backtest-<date>.json

    The observed directory is required as an argument, must be the ignored .gjc/evidence/forecast/local path, and may be absent or empty. Absent/empty observed input reports no-go while still running synthetic conformance.
    """

    static func parse(_ rawArguments: [String]) throws -> Arguments {
        var fixtures: String?
        var observed: String?
        var output: String?
        var index = 0

        while index < rawArguments.count {
            let argument = rawArguments[index]
            switch argument {
            case "--help", "-h":
                throw BacktestError.help
            case "--fixtures":
                index += 1
                guard index < rawArguments.count else { throw BacktestError.usage("Missing value for --fixtures.") }
                fixtures = rawArguments[index]
            case "--observed":
                index += 1
                guard index < rawArguments.count else { throw BacktestError.usage("Missing value for --observed.") }
                observed = rawArguments[index]
            case "--output":
                index += 1
                guard index < rawArguments.count else { throw BacktestError.usage("Missing value for --output.") }
                output = rawArguments[index]
            default:
                throw BacktestError.usage("Unknown argument.")
            }
            index += 1
        }

        guard let fixtures else { throw BacktestError.usage("Missing required --fixtures argument.") }
        guard let observed else { throw BacktestError.usage("Missing required --observed argument.") }
        guard let output else { throw BacktestError.usage("Missing required --output argument.") }

        let observedURL = URL(fileURLWithPath: expandTilde(observed)).standardizedFileURL
        guard isIgnoredObservedDirectory(observedURL) else {
            throw BacktestError.observedPathNotIgnored
        }

        return Arguments(
            fixturesDirectory: URL(fileURLWithPath: expandTilde(fixtures)).standardizedFileURL,
            observedDirectory: observedURL,
            outputFile: URL(fileURLWithPath: expandTilde(output)).standardizedFileURL
        )
    }
}

struct FixtureFile: Decodable {
    let schema: String?
    let cases: [ForecastCaseInput]
}

struct ObservedCohortFile: Decodable {
    let schema: String?
    let cycles: [ForecastCaseInput]
}

struct ForecastCaseInput: Decodable {
    let id: String
    let profileHash: String?
    let provider: String?
    let source: String?
    let stability: String?
    let resetKind: String?
    let resetAt: String
    let evaluationTime: String?
    let features: [ObservationInput]
    let outcomes: [ObservationInput]?
    let hasNextCycle: Bool?
    let expected: ExpectedConformance?
}

struct ObservationInput: Decodable {
    let observedAt: String
    let usedPercent: Double?
    let used: Double?
    let rateLimitReached: Bool?

    var resolvedUsedPercent: Double? {
        usedPercent ?? used
    }
}

struct ExpectedConformance: Decodable {
    let outcome: String
    let freshnessPass: Bool?
    let currentUsed: Double?
    let lowerSlopePerHour: Double?
    let medianSlopePerHour: Double?
    let upperSlopePerHour: Double?
    let causalExcludedFeatureCount: Int?
}

struct ForecastObservation {
    let observedAt: Date
    let usedPercent: Double
    let rateLimitReached: Bool
}

struct EvaluationResult {
    let outcome: ForecastOutcome
    let reason: String
    let freshnessPass: Bool
    let currentUsed: Double?
    let lowerSlopePerHour: Double?
    let medianSlopePerHour: Double?
    let upperSlopePerHour: Double?
    let causalExcludedFeatureCount: Int
}

enum ForecastOutcome: String {
    case unavailableWindow = "unavailableWindow"
    case unavailableEvidence = "unavailableEvidence"
    case discontinuity = "discontinuity"
    case saturation = "saturation"
    case stable = "stable"
    case atRisk = "at-risk"
    case uncertain = "uncertain"

    var isClassified: Bool {
        self == .stable || self == .atRisk
    }
}

struct FileHash: Encodable {
    let file: String
    let sha256: String
}

struct ConfusionMatrix: Encodable {
    var truePositive: Int = 0
    var falsePositive: Int = 0
    var trueNegative: Int = 0
    var falseNegative: Int = 0
}

struct Counts: Encodable {
    let syntheticConformanceCases: Int
    let syntheticConformancePassed: Int
    let observedFiles: Int
    let observedLabeledCycles: Int
    let observedProfiles: Int
    let classifiedObservedCycles: Int
    let excludedObservedCycles: Int
    let positiveObservedCycles: Int
    let negativeObservedCycles: Int
}

struct Metrics: Encodable {
    let precision: Double?
    let recall: Double?
    let falsePositiveRate: Double?
    let eligibleClassificationRate: Double?

    enum CodingKeys: String, CodingKey {
        case precision
        case recall
        case falsePositiveRate
        case eligibleClassificationRate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeMetric(precision, forKey: .precision, into: &container)
        try encodeMetric(recall, forKey: .recall, into: &container)
        try encodeMetric(falsePositiveRate, forKey: .falsePositiveRate, into: &container)
        try encodeMetric(eligibleClassificationRate, forKey: .eligibleClassificationRate, into: &container)
    }

    private func encodeMetric(_ value: Double?, forKey key: CodingKeys, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        guard let value else {
            try container.encodeNil(forKey: key)
            return
        }
        try container.encode(roundMetric(value), forKey: key)
    }
}

struct Thresholds: Encodable {
    let minimumObservedCycles: Int
    let minimumObservedProfiles: Int
    let minimumPrecision: Double
    let minimumRecall: Double
    let maximumFalsePositiveRate: Double
    let minimumEligibleClassificationRate: Double
}

struct GateReport: Encodable {
    let status: String
    let reasons: [String]
    let thresholds: Thresholds
}

struct SyntheticConformanceResult: Encodable {
    let id: String
    let passed: Bool
    let expectedOutcome: String
    let actualOutcome: String
    let expectedFreshnessPass: Bool?
    let actualFreshnessPass: Bool
    let expectedCurrentUsed: Double?
    let actualCurrentUsed: Double?
    let expectedLowerSlopePerHour: Double?
    let actualLowerSlopePerHour: Double?
    let expectedMedianSlopePerHour: Double?
    let actualMedianSlopePerHour: Double?
    let expectedUpperSlopePerHour: Double?
    let actualUpperSlopePerHour: Double?
    let expectedCausalExcludedFeatureCount: Int?
    let actualCausalExcludedFeatureCount: Int
    let failureReasons: [String]
}

struct BacktestReport: Encodable {
    let algorithmID: String
    let fixtureHashes: [FileHash]
    let observedCohortHashes: [String]
    let counts: Counts
    let confusionMatrix: ConfusionMatrix
    let metrics: Metrics
    let syntheticConformance: [SyntheticConformanceResult]
    let gate: GateReport
}

func main() throws {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    let fileManager = FileManager.default
    try requireDirectory(arguments.fixturesDirectory, label: "fixtures")

    let fixtureLoad = try loadFixtures(from: arguments.fixturesDirectory)
    let observedLoad = try loadObserved(from: arguments.observedDirectory)

    let syntheticResults = try fixtureLoad.cases.map { input in
        try evaluateSyntheticConformance(input)
    }
    let syntheticPassed = syntheticResults.filter(\.passed).count

    let observedEvaluation = try evaluateObservedCycles(observedLoad.cycles)
    let metrics = makeMetrics(confusion: observedEvaluation.confusionMatrix, labeledCycles: observedEvaluation.labeledCycles, classifiedCycles: observedEvaluation.classifiedCycles)
    let gate = makeGate(
        syntheticPassed: syntheticPassed,
        syntheticTotal: syntheticResults.count,
        observedDirectoryPresent: observedLoad.directoryPresent,
        observedFileCount: observedLoad.hashes.count,
        observedProfiles: observedEvaluation.profileCount,
        observedLabeledCycles: observedEvaluation.labeledCycles,
        metrics: metrics
    )

    let report = BacktestReport(
        algorithmID: algorithmID,
        fixtureHashes: fixtureLoad.hashes,
        observedCohortHashes: observedLoad.hashes,
        counts: Counts(
            syntheticConformanceCases: syntheticResults.count,
            syntheticConformancePassed: syntheticPassed,
            observedFiles: observedLoad.hashes.count,
            observedLabeledCycles: observedEvaluation.labeledCycles,
            observedProfiles: observedEvaluation.profileCount,
            classifiedObservedCycles: observedEvaluation.classifiedCycles,
            excludedObservedCycles: observedEvaluation.excludedCycles,
            positiveObservedCycles: observedEvaluation.positiveCycles,
            negativeObservedCycles: observedEvaluation.negativeCycles
        ),
        confusionMatrix: observedEvaluation.confusionMatrix,
        metrics: metrics,
        syntheticConformance: syntheticResults,
        gate: gate
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let outputData = try encoder.encode(report)
    let outputDirectory = arguments.outputFile.deletingLastPathComponent()
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try outputData.write(to: arguments.outputFile, options: .atomic)
    let sidecar = arguments.outputFile.appendingPathExtension("sha256")
    let sidecarData = Data((SHA256.hexDigest(outputData) + "\n").utf8)
    try sidecarData.write(to: sidecar, options: .atomic)
    FileHandle.standardOutput.write(outputData)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func requireDirectory(_ url: URL, label: String) throws {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw BacktestError.missingDirectory(label)
    }
}

func loadFixtures(from directory: URL) throws -> (hashes: [FileHash], cases: [ForecastCaseInput]) {
    let files = try jsonFiles(in: directory)
    guard files.count <= 2 else { throw BacktestError.tooManyFixtureFiles }

    let decoder = JSONDecoder()
    var hashes: [FileHash] = []
    var cases: [ForecastCaseInput] = []

    for file in files {
        let data = try Data(contentsOf: file)
        let hash = SHA256.hexDigest(data)
        hashes.append(FileHash(file: file.lastPathComponent, sha256: hash))
        do {
            let fixtureFile = try decoder.decode(FixtureFile.self, from: data)
            cases.append(contentsOf: fixtureFile.cases)
        } catch {
            throw BacktestError.decodingFailed(kind: "fixture", hashPrefix: String(hash.prefix(12)), detail: sanitizedError(error))
        }
    }

    guard !cases.isEmpty else { throw BacktestError.noFixtureCases }
    return (hashes.sorted { $0.file < $1.file }, cases.sorted { $0.id < $1.id })
}

func loadObserved(from directory: URL) throws -> (directoryPresent: Bool, hashes: [String], cycles: [ForecastCaseInput]) {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
        return (false, [], [])
    }
    guard isDirectory.boolValue else {
        throw BacktestError.missingDirectory("observed")
    }

    let files = try jsonFiles(in: directory)
    let decoder = JSONDecoder()
    var hashes: [String] = []
    var cycles: [ForecastCaseInput] = []

    for file in files {
        let data = try Data(contentsOf: file)
        let hash = SHA256.hexDigest(data)
        hashes.append(hash)
        do {
            let observedFile = try decoder.decode(ObservedCohortFile.self, from: data)
            cycles.append(contentsOf: observedFile.cycles)
        } catch {
            throw BacktestError.decodingFailed(kind: "observed cohort", hashPrefix: String(hash.prefix(12)), detail: sanitizedError(error))
        }
    }

    return (true, hashes.sorted(), cycles.sorted { $0.id < $1.id })
}

func jsonFiles(in directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var files: [URL] = []
    for case let url as URL in enumerator {
        guard url.pathExtension.lowercased() == "json" else { continue }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true {
            files.append(url)
        }
    }
    return files.sorted { $0.path < $1.path }
}

func evaluateSyntheticConformance(_ input: ForecastCaseInput) throws -> SyntheticConformanceResult {
    guard let expected = input.expected else {
        throw BacktestError.invalidFixture("Synthetic fixture \(input.id) is missing expected conformance.")
    }
    guard let evaluationTimeString = input.evaluationTime else {
        throw BacktestError.invalidFixture("Synthetic fixture \(input.id) is missing evaluationTime.")
    }

    let resetAt = try parseDate(input.resetAt, label: "fixture resetAt")
    let evaluationTime = try parseDate(evaluationTimeString, label: "fixture evaluationTime")
    let features = try input.features.map { try makeObservation($0, label: "fixture feature") }
    let result = evaluateAlgorithm(resetAt: resetAt, evaluationTime: evaluationTime, features: features)

    var failures: [String] = []
    if result.outcome.rawValue != expected.outcome {
        failures.append("outcome")
    }
    if let expectedFreshness = expected.freshnessPass, result.freshnessPass != expectedFreshness {
        failures.append("freshness")
    }
    compareOptionalDouble(actual: result.currentUsed, expected: expected.currentUsed, label: "currentUsed", failures: &failures)
    compareOptionalDouble(actual: result.lowerSlopePerHour, expected: expected.lowerSlopePerHour, label: "lowerSlopePerHour", failures: &failures)
    compareOptionalDouble(actual: result.medianSlopePerHour, expected: expected.medianSlopePerHour, label: "medianSlopePerHour", failures: &failures)
    compareOptionalDouble(actual: result.upperSlopePerHour, expected: expected.upperSlopePerHour, label: "upperSlopePerHour", failures: &failures)
    if let expectedExcluded = expected.causalExcludedFeatureCount, result.causalExcludedFeatureCount != expectedExcluded {
        failures.append("causalExcludedFeatureCount")
    }

    return SyntheticConformanceResult(
        id: input.id,
        passed: failures.isEmpty,
        expectedOutcome: expected.outcome,
        actualOutcome: result.outcome.rawValue,
        expectedFreshnessPass: expected.freshnessPass,
        actualFreshnessPass: result.freshnessPass,
        expectedCurrentUsed: roundedOptional(expected.currentUsed),
        actualCurrentUsed: roundedOptional(result.currentUsed),
        expectedLowerSlopePerHour: roundedOptional(expected.lowerSlopePerHour),
        actualLowerSlopePerHour: roundedOptional(result.lowerSlopePerHour),
        expectedMedianSlopePerHour: roundedOptional(expected.medianSlopePerHour),
        actualMedianSlopePerHour: roundedOptional(result.medianSlopePerHour),
        expectedUpperSlopePerHour: roundedOptional(expected.upperSlopePerHour),
        actualUpperSlopePerHour: roundedOptional(result.upperSlopePerHour),
        expectedCausalExcludedFeatureCount: expected.causalExcludedFeatureCount,
        actualCausalExcludedFeatureCount: result.causalExcludedFeatureCount,
        failureReasons: failures
    )
}

struct ObservedEvaluationSummary {
    let confusionMatrix: ConfusionMatrix
    let labeledCycles: Int
    let classifiedCycles: Int
    let excludedCycles: Int
    let positiveCycles: Int
    let negativeCycles: Int
    let profileCount: Int
}

func evaluateObservedCycles(_ inputs: [ForecastCaseInput]) throws -> ObservedEvaluationSummary {
    var confusion = ConfusionMatrix()
    var labeledCycles = 0
    var classifiedCycles = 0
    var excludedCycles = 0
    var positiveCycles = 0
    var negativeCycles = 0
    var profileHashes = Set<String>()

    for input in inputs {
        guard isEligibleObservedClaudeCycle(input), let profileHash = input.profileHash, !profileHash.isEmpty else {
            excludedCycles += 1
            continue
        }

        let resetAt = try parseDate(input.resetAt, label: "observed resetAt")
        let features = try input.features.map { try makeObservation($0, label: "observed feature") }
        let outcomes = try (input.outcomes ?? []).map { try makeObservation($0, label: "observed outcome") }
        guard let evaluationTime = lastEligibleEvaluationTime(resetAt: resetAt, features: features) else {
            excludedCycles += 1
            continue
        }
        if features.contains(where: { $0.observedAt.timeIntervalSince(evaluationTime) > maxFeatureClockSkewSeconds }) {
            excludedCycles += 1
            continue
        }
        guard let observedOutcome = observedTruth(resetAt: resetAt, evaluationTime: evaluationTime, outcomes: outcomes, hasNextCycle: input.hasNextCycle == true) else {
            excludedCycles += 1
            continue
        }

        labeledCycles += 1
        profileHashes.insert(profileHash)
        if observedOutcome {
            positiveCycles += 1
        } else {
            negativeCycles += 1
        }

        let result = evaluateAlgorithm(resetAt: resetAt, evaluationTime: evaluationTime, features: features)
        guard result.outcome.isClassified else {
            continue
        }
        classifiedCycles += 1

        switch (result.outcome, observedOutcome) {
        case (.atRisk, true):
            confusion.truePositive += 1
        case (.atRisk, false):
            confusion.falsePositive += 1
        case (.stable, false):
            confusion.trueNegative += 1
        case (.stable, true):
            confusion.falseNegative += 1
        default:
            break
        }
    }

    return ObservedEvaluationSummary(
        confusionMatrix: confusion,
        labeledCycles: labeledCycles,
        classifiedCycles: classifiedCycles,
        excludedCycles: excludedCycles,
        positiveCycles: positiveCycles,
        negativeCycles: negativeCycles,
        profileCount: profileHashes.count
    )
}

func evaluateAlgorithm(resetAt: Date, evaluationTime: Date, features rawFeatures: [ForecastObservation]) -> EvaluationResult {
    guard resetAt > evaluationTime else {
        return EvaluationResult(outcome: .unavailableWindow, reason: "resetNotFuture", freshnessPass: false, currentUsed: nil, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: 0)
    }

    if rawFeatures.contains(where: { $0.observedAt.timeIntervalSince(evaluationTime) > maxFeatureClockSkewSeconds }) {
        return EvaluationResult(outcome: .unavailableEvidence, reason: "futureFeatureClockSkew", freshnessPass: false, currentUsed: nil, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: rawFeatures.filter { $0.observedAt > evaluationTime }.count)
    }

    let futureExcludedCount = rawFeatures.filter { $0.observedAt > evaluationTime }.count
    let features = rawFeatures
        .filter { $0.observedAt <= evaluationTime }
        .sorted { $0.observedAt < $1.observedAt }

    guard let newest = features.last else {
        return EvaluationResult(outcome: .unavailableEvidence, reason: "noCausalFeature", freshnessPass: false, currentUsed: nil, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
    }

    let freshnessAge = evaluationTime.timeIntervalSince(newest.observedAt)
    let freshnessPass = freshnessAge >= 0 && freshnessAge <= freshnessWindowSeconds
    guard freshnessPass else {
        return EvaluationResult(outcome: .unavailableEvidence, reason: "staleFeature", freshnessPass: false, currentUsed: newest.usedPercent, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
    }

    guard features.count >= minimumBucketedObservations, features.count <= maximumBucketedObservations else {
        return EvaluationResult(outcome: .unavailableEvidence, reason: "bucketCount", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
    }

    guard let first = features.first, newest.observedAt.timeIntervalSince(first.observedAt) >= minimumSpanSeconds else {
        return EvaluationResult(outcome: .unavailableEvidence, reason: "span", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
    }

    for index in 1..<features.count {
        let gap = features[index].observedAt.timeIntervalSince(features[index - 1].observedAt)
        guard gap > 0, gap <= maximumGapSeconds else {
            return EvaluationResult(outcome: .unavailableEvidence, reason: "gap", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
        }
    }

    for feature in features where feature.usedPercent < 0 {
        return EvaluationResult(outcome: .unavailableEvidence, reason: "negativeUsed", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
    }

    for index in 1..<features.count where features[index - 1].usedPercent - features[index].usedPercent > 2 {
        return EvaluationResult(outcome: .discontinuity, reason: "fallGreaterThanTwo", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
    }

    if newest.usedPercent > 100 {
        return EvaluationResult(outcome: .saturation, reason: "currentAbove100", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
    }

    let slopes = pairSlopesPerHour(features)
    guard let lower = nearestRank(slopes, percentile: 0.10),
          let median = nearestRank(slopes, percentile: 0.50),
          let upper = nearestRank(slopes, percentile: 0.90) else {
        return EvaluationResult(outcome: .unavailableEvidence, reason: "slope", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: nil, medianSlopePerHour: nil, upperSlopePerHour: nil, causalExcludedFeatureCount: futureExcludedCount)
    }

    let timeToResetHours = resetAt.timeIntervalSince(evaluationTime) / 3_600
    if newest.usedPercent == 100 {
        return EvaluationResult(outcome: timeToResetHours >= 0.5 ? .atRisk : .uncertain, reason: "current100", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: lower, medianSlopePerHour: median, upperSlopePerHour: upper, causalExcludedFeatureCount: futureExcludedCount)
    }

    if distanceToFullHours(currentUsed: newest.usedPercent, slopePerHour: upper) >= timeToResetHours {
        return EvaluationResult(outcome: .stable, reason: "upperStable", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: lower, medianSlopePerHour: median, upperSlopePerHour: upper, causalExcludedFeatureCount: futureExcludedCount)
    }

    if timeToResetHours >= 0.5 && distanceToFullHours(currentUsed: newest.usedPercent, slopePerHour: lower) <= timeToResetHours - 0.5 {
        return EvaluationResult(outcome: .atRisk, reason: "lowerAtRisk", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: lower, medianSlopePerHour: median, upperSlopePerHour: upper, causalExcludedFeatureCount: futureExcludedCount)
    }

    return EvaluationResult(outcome: .uncertain, reason: "betweenBounds", freshnessPass: freshnessPass, currentUsed: newest.usedPercent, lowerSlopePerHour: lower, medianSlopePerHour: median, upperSlopePerHour: upper, causalExcludedFeatureCount: futureExcludedCount)
}

func pairSlopesPerHour(_ observations: [ForecastObservation]) -> [Double] {
    var slopes: [Double] = []
    slopes.reserveCapacity(observations.count * (observations.count - 1) / 2)

    for start in 0..<(observations.count - 1) {
        for end in (start + 1)..<observations.count {
            let hours = observations[end].observedAt.timeIntervalSince(observations[start].observedAt) / 3_600
            guard hours > 0 else { continue }
            let slope = (observations[end].usedPercent - observations[start].usedPercent) / hours
            slopes.append(min(100, max(0, slope)))
        }
    }

    return slopes.sorted()
}

func nearestRank(_ sortedValues: [Double], percentile: Double) -> Double? {
    guard !sortedValues.isEmpty else { return nil }
    let oneBasedRank = Int(ceil(percentile * Double(sortedValues.count)))
    let index = min(max(oneBasedRank - 1, 0), sortedValues.count - 1)
    return sortedValues[index]
}

func distanceToFullHours(currentUsed: Double, slopePerHour: Double) -> Double {
    guard slopePerHour > 0 else { return .infinity }
    return max(0, (100 - currentUsed) / slopePerHour)
}

func lastEligibleEvaluationTime(resetAt: Date, features: [ForecastObservation]) -> Date? {
    features
        .filter { resetAt.timeIntervalSince($0.observedAt) >= minimumResetLeadSeconds }
        .map(\.observedAt)
        .max()
}

func observedTruth(resetAt: Date, evaluationTime: Date, outcomes: [ForecastObservation], hasNextCycle: Bool) -> Bool? {
    let laterSameCycle = outcomes.filter { $0.observedAt > evaluationTime && $0.observedAt <= resetAt }
    if laterSameCycle.contains(where: { $0.usedPercent >= 100 || $0.rateLimitReached }) {
        return true
    }

    let finalWindowStart = resetAt.addingTimeInterval(-freshnessWindowSeconds)
    if hasNextCycle && laterSameCycle.contains(where: { $0.observedAt >= finalWindowStart && $0.usedPercent < 100 }) {
        return false
    }

    return nil
}

func makeMetrics(confusion: ConfusionMatrix, labeledCycles: Int, classifiedCycles: Int) -> Metrics {
    let predictedPositive = confusion.truePositive + confusion.falsePositive
    let actualPositive = confusion.truePositive + confusion.falseNegative
    let actualNegative = confusion.trueNegative + confusion.falsePositive

    return Metrics(
        precision: predictedPositive > 0 ? Double(confusion.truePositive) / Double(predictedPositive) : nil,
        recall: actualPositive > 0 ? Double(confusion.truePositive) / Double(actualPositive) : nil,
        falsePositiveRate: actualNegative > 0 ? Double(confusion.falsePositive) / Double(actualNegative) : nil,
        eligibleClassificationRate: labeledCycles > 0 ? Double(classifiedCycles) / Double(labeledCycles) : nil
    )
}

func makeGate(syntheticPassed: Int, syntheticTotal: Int, observedDirectoryPresent: Bool, observedFileCount: Int, observedProfiles: Int, observedLabeledCycles: Int, metrics: Metrics) -> GateReport {
    var reasons: [String] = []
    if syntheticPassed != syntheticTotal {
        reasons.append("synthetic conformance failed")
    }
    if !observedDirectoryPresent || observedFileCount == 0 {
        reasons.append("observed cohort absent")
    }
    if observedLabeledCycles < minimumObservedCycles {
        reasons.append("requires at least 30 observed labeled cycles; found \(observedLabeledCycles)")
    }
    if observedProfiles < minimumObservedProfiles {
        reasons.append("requires at least 5 independently configured observed profiles; found \(observedProfiles)")
    }
    if (metrics.precision ?? -Double.infinity) < minimumPrecision {
        reasons.append("precision below 0.80 or unavailable")
    }
    if (metrics.recall ?? -Double.infinity) < minimumRecall {
        reasons.append("recall below 0.60 or unavailable")
    }
    if (metrics.falsePositiveRate ?? Double.infinity) > maximumFalsePositiveRate {
        reasons.append("false-positive rate above 0.10 or unavailable")
    }
    if (metrics.eligibleClassificationRate ?? -Double.infinity) < minimumClassificationRate {
        reasons.append("stable/at-risk classification rate below 0.70 or unavailable")
    }

    return GateReport(
        status: reasons.isEmpty ? "thresholds-passed-review-required" : "no-go",
        reasons: reasons,
        thresholds: Thresholds(
            minimumObservedCycles: minimumObservedCycles,
            minimumObservedProfiles: minimumObservedProfiles,
            minimumPrecision: minimumPrecision,
            minimumRecall: minimumRecall,
            maximumFalsePositiveRate: maximumFalsePositiveRate,
            minimumEligibleClassificationRate: minimumClassificationRate
        )
    )
}

func isEligibleObservedClaudeCycle(_ input: ForecastCaseInput) -> Bool {
    normalize(input.provider) == "claude" &&
        normalize(input.source) == "providerreported" &&
        normalize(input.stability) == "supported" &&
        ["fixed", "fixedreset", "claudefixedreset"].contains(normalize(input.resetKind))
}

func normalize(_ value: String?) -> String {
    (value ?? "")
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
}

func makeObservation(_ input: ObservationInput, label: String) throws -> ForecastObservation {
    guard let usedPercent = input.resolvedUsedPercent else {
        throw BacktestError.invalidFixture("Observation is missing usedPercent.")
    }
    return ForecastObservation(
        observedAt: try parseDate(input.observedAt, label: label),
        usedPercent: usedPercent,
        rateLimitReached: input.rateLimitReached == true
    )
}

func parseDate(_ value: String, label: String) throws -> Date {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }

    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    if let date = basic.date(from: value) {
        return date
    }

    throw BacktestError.invalidDate(label)
}

func isIgnoredObservedDirectory(_ url: URL) -> Bool {
    let components = url.standardizedFileURL.pathComponents
    guard components.count >= 4 else { return false }
    return Array(components.suffix(4)) == [".gjc", "evidence", "forecast", "local"]
}

func expandTilde(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

func sanitizedError(_ error: Error) -> String {
    String(describing: error).replacingOccurrences(of: "\n", with: " ")
}

func compareOptionalDouble(actual: Double?, expected: Double?, label: String, failures: inout [String]) {
    guard let expected else { return }
    guard let actual, abs(actual - expected) <= 0.000_001 else {
        failures.append(label)
        return
    }
}

func roundMetric(_ value: Double) -> Double {
    (value * 1_000_000).rounded() / 1_000_000
}

func roundedOptional(_ value: Double?) -> Double? {
    value.map(roundMetric)
}

struct SHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hexDigest(_ data: Data) -> String {
        var bytes = [UInt8](data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> shift) & 0xff))
        }

        var hash: [UInt32] = [
            0x6a09e667,
            0xbb67ae85,
            0x3c6ef372,
            0xa54ff53a,
            0x510e527f,
            0x9b05688c,
            0x1f83d9ab,
            0x5be0cd19
        ]

        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var words = Array(repeating: UInt32(0), count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = (UInt32(bytes[offset]) << 24) |
                    (UInt32(bytes[offset + 1]) << 16) |
                    (UInt32(bytes[offset + 2]) << 8) |
                    UInt32(bytes[offset + 3])
            }
            for index in 16..<64 {
                words[index] = smallSigma1(words[index - 2]) &+ words[index - 7] &+ smallSigma0(words[index - 15]) &+ words[index - 16]
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let temp1 = h &+ bigSigma1(e) &+ choice(e, f, g) &+ constants[index] &+ words[index]
                let temp2 = bigSigma0(a) &+ majority(a, b, c)
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        var digestBytes: [UInt8] = []
        digestBytes.reserveCapacity(32)
        for word in hash {
            digestBytes.append(UInt8((word >> 24) & 0xff))
            digestBytes.append(UInt8((word >> 16) & 0xff))
            digestBytes.append(UInt8((word >> 8) & 0xff))
            digestBytes.append(UInt8(word & 0xff))
        }
        return digestBytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, by bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }

    private static func choice(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) ^ (~x & z)
    }

    private static func majority(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) ^ (x & z) ^ (y & z)
    }

    private static func bigSigma0(_ value: UInt32) -> UInt32 {
        rotateRight(value, by: 2) ^ rotateRight(value, by: 13) ^ rotateRight(value, by: 22)
    }

    private static func bigSigma1(_ value: UInt32) -> UInt32 {
        rotateRight(value, by: 6) ^ rotateRight(value, by: 11) ^ rotateRight(value, by: 25)
    }

    private static func smallSigma0(_ value: UInt32) -> UInt32 {
        rotateRight(value, by: 7) ^ rotateRight(value, by: 18) ^ (value >> 3)
    }

    private static func smallSigma1(_ value: UInt32) -> UInt32 {
        rotateRight(value, by: 17) ^ rotateRight(value, by: 19) ^ (value >> 10)
    }
}

do {
    try main()
} catch BacktestError.help {
    FileHandle.standardOutput.write(Data((Arguments.usage + "\n").utf8))
} catch let error as BacktestError {
    FileHandle.standardError.write(Data((error.description + "\n").utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data(("CapacityForecastBacktest failed without writing observed payload data.\n").utf8))
    exit(2)
}
