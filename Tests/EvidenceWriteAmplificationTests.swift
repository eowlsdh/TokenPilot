import XCTest
@testable import TokenCore

/// The evidence store already skips a commit when the record set is unchanged, on the stated premise
/// that "bucket compaction makes most refreshes produce the same records". Measured on a real
/// install, it never once fired: the file was rewritten every ninety seconds — four megabytes of
/// primary and four of backup — to move a timestamp on three records whose values had not changed.
/// These pin the premise so it stays true.
final class EvidenceWriteAmplificationTests: XCTestCase {
    private struct Clock: CapacityEvidenceClock {
        let now: Date
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenPilotEvidenceWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// `resetAt` is the window's own boundary, so it does not move between two readings of the same
    /// window — which is what makes those readings the same reading.
    private func observation(
        at date: Date,
        usedPercent: Int = 40,
        resetAt: Date? = nil
    ) throws -> CapacityObservation {
        try CapacityObservation(
            seriesID: try CapacitySeriesID(
                provider: .opencode,
                providerWindowID: "rate-limit",
                kind: .fixedReset,
                unit: .percent
            ),
            observedAt: date,
            resetAt: resetAt ?? start.addingTimeInterval(3_600),
            value: try CapacityValue(usedPercent: usedPercent),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: date
        )
    }

    private func generation(in directory: URL) throws -> Int {
        let files = CapacityEvidenceFileSet(directory: directory)
        let root = try JSONSerialization.jsonObject(with: try Data(contentsOf: files.primary)) as? [String: Any]
        return try XCTUnwrap(root?["generation"] as? Int)
    }

    /// A store per tick, because that is how the refresh reaches it — through a fresh read of the
    /// committed file, not a long-lived in-memory copy.
    private func record(_ observation: CapacityObservation, at now: Date, in directory: URL) async {
        let store = CapacityEvidenceStore(files: CapacityEvidenceFileSet(directory: directory), clock: Clock(now: now))
        _ = await store.record([observation])
    }

    func testRepeatedIdenticalReadingsDoNotRewriteTheFile() async throws {
        let directory = try directory()
        await record(try observation(at: start), at: start, in: directory)
        let committed = try generation(in: directory)

        // Four more refreshes inside the same five-minute bucket, the way the app actually polls.
        for seconds in stride(from: 60.0, through: 240.0, by: 60.0) {
            let at = start.addingTimeInterval(seconds)
            await record(try observation(at: at), at: at, in: directory)
        }

        XCTAssertEqual(
            try generation(in: directory),
            committed,
            "an unchanged quota re-read four times must not re-commit the envelope four times"
        )
    }

    /// The saving must not come at the cost of missing a real change.
    func testAChangedReadingStillCommits() async throws {
        let directory = try directory()
        await record(try observation(at: start, usedPercent: 40), at: start, in: directory)
        let committed = try generation(in: directory)

        let later = start.addingTimeInterval(60)
        await record(try observation(at: later, usedPercent: 41), at: later, in: directory)

        XCTAssertGreaterThan(try generation(in: directory), committed)

        let store = CapacityEvidenceStore(files: CapacityEvidenceFileSet(directory: directory), clock: Clock(now: later))
        let stored = await store.loadSnapshot().records
        XCTAssertEqual(stored.compactMap(\.value.usedPercent), [41], "the newer reading must be the one kept")
        XCTAssertEqual(stored.first?.observedAt, later)
    }

    /// A new bucket is a new sample, so the timestamp does advance — just once per bucket rather than
    /// once per refresh.
    func testTheNextBucketRecordsItsOwnSample() async throws {
        let directory = try directory()
        await record(try observation(at: start), at: start, in: directory)

        let nextBucket = start.addingTimeInterval(300)
        await record(try observation(at: nextBucket), at: nextBucket, in: directory)

        let store = CapacityEvidenceStore(files: CapacityEvidenceFileSet(directory: directory), clock: Clock(now: nextBucket))
        let stored = await store.loadSnapshot().records.map(\.observedAt).sorted()
        XCTAssertEqual(stored, [start, nextBucket])
    }

    /// The limit of what this fix reaches, recorded rather than glossed over. opencode's Zen/Go API
    /// answers `resetsAt` for the rolling window as request-time plus five hours, so every poll
    /// reports a reset instant ninety seconds later than the last one. That is a different reading by
    /// any definition available here, so the envelope is still re-committed — which is why the
    /// measured write rate on an install with the opencode probe enabled does not change.
    func testASlidingResetHorizonStillCommitsEveryTime() async throws {
        let directory = try directory()
        await record(
            try observation(at: start, resetAt: start.addingTimeInterval(18_000)),
            at: start,
            in: directory
        )
        let committed = try generation(in: directory)

        let later = start.addingTimeInterval(90)
        await record(
            try observation(at: later, resetAt: later.addingTimeInterval(18_000)),
            at: later,
            in: directory
        )

        XCTAssertGreaterThan(
            try generation(in: directory),
            committed,
            "documented, not desired — see docs/verification/evidence-write-amplification.md"
        )
    }

    /// Sameness is decided by comparing the whole record with the timestamp set aside, so a reading
    /// that differs in something other than its value is still a different reading.
    func testADifferentAuthorityIsNotTheSameReading() async throws {
        let directory = try directory()
        await record(try observation(at: start), at: start, in: directory)
        let committed = try generation(in: directory)

        let later = start.addingTimeInterval(60)
        let unofficial = try CapacityObservation(
            seriesID: try CapacitySeriesID(
                provider: .opencode,
                providerWindowID: "rate-limit",
                kind: .fixedReset,
                unit: .percent
            ),
            observedAt: later,
            resetAt: later.addingTimeInterval(3_600),
            value: try CapacityValue(usedPercent: 40),
            authority: .localDerived,
            stability: .supported,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: later
        )
        await record(unofficial, at: later, in: directory)

        XCTAssertGreaterThan(try generation(in: directory), committed)
    }
}
