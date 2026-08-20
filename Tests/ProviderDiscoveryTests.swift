import XCTest
@testable import TokenCore

/// Covers the two reasons a configured provider reported nothing: the file walk never reached its
/// newest files, and Kiro's own quota percentage was read past.
final class NewestFileScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("newest-file-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relativePath: String, modified: Date) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func jsonl(_ url: URL) -> Bool { url.pathExtension == "jsonl" }

    /// The regression that started this: Codex partitions sessions as `YYYY/MM/DD`, so a walk that
    /// stops at a cap fills up on the oldest directories and the newest months are never examined.
    /// The adapter then discarded every file it had for being outside its retention window and
    /// reported no usage at all.
    func testNewestFilesAreFoundEvenWhenTheyAreWalkedLast() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<200 {
            try write("2026/04/\(String(format: "%02d", index % 28 + 1))/old-\(index).jsonl",
                      modified: now.addingTimeInterval(-120 * 86_400))
        }
        for index in 0..<5 {
            try write("2026/08/19/recent-\(index).jsonl", modified: now.addingTimeInterval(-Double(index) * 60))
        }

        let result = NewestFileScan.newestFiles(in: [root], limit: 5, isEligible: jsonl)

        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.files.count, 5)
        for file in result.files {
            XCTAssertTrue(file.lastPathComponent.hasPrefix("recent-"), file.lastPathComponent)
        }
    }

    func testFilesComeBackNewestFirst() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write("a.jsonl", modified: now.addingTimeInterval(-300))
        try write("b.jsonl", modified: now.addingTimeInterval(-100))
        try write("c.jsonl", modified: now.addingTimeInterval(-200))

        let result = NewestFileScan.newestFiles(in: [root], limit: 3, isEligible: jsonl)

        XCTAssertEqual(result.files.map(\.lastPathComponent), ["b.jsonl", "c.jsonl", "a.jsonl"])
    }

    func testIneligibleFilesAreNeverReturned() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write("auth.jsonl", modified: now)
        try write("session.jsonl", modified: now.addingTimeInterval(-600))
        try write("notes.txt", modified: now)

        let result = NewestFileScan.newestFiles(in: [root], limit: 10) { url in
            url.pathExtension == "jsonl" && !url.lastPathComponent.contains("auth")
        }

        XCTAssertEqual(result.files.map(\.lastPathComponent), ["session.jsonl"])
    }

    func testARootThatIsItselfAFileIsAccepted() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = try write("single.jsonl", modified: now)

        let result = NewestFileScan.newestFiles(in: [file], limit: 5, isEligible: jsonl)

        XCTAssertEqual(result.files, [file])
    }

    func testDirectoriesAndMissingRootsAreSkipped() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("looks-like-a-file.jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("real.jsonl", modified: now)
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)

        let result = NewestFileScan.newestFiles(in: [missing, root], limit: 10, isEligible: jsonl)

        XCTAssertEqual(result.files.map(\.lastPathComponent), ["real.jsonl"])
    }
}

final class KiroCreditUsageTests: XCTestCase {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func metadataLine(percent: Double, offset: TimeInterval) -> String {
        let timestamp = Int(Self.base.addingTimeInterval(offset).timeIntervalSince1970)
        return #"{"timestamp":\#(timestamp),"payload":{"type":"session_metadata","value":{"usagePercentage":\#(percent)}}}"#
    }

    /// The value climbs through a session, so "largest" and "newest" usually agree — but after a
    /// reset the largest sample is the stale one, and reporting it would overstate usage.
    func testNewestSampleWinsOverLargest() throws {
        let jsonl = [
            metadataLine(percent: 4.9258, offset: 0),
            metadataLine(percent: 96.5, offset: 60),
            metadataLine(percent: 3.25, offset: 120)
        ].joined(separator: "\n")

        let sample = try XCTUnwrap(KiroLocalSessionAdapter.parseCreditUsagePercent(jsonl: jsonl, fallbackTimestamp: nil))

        XCTAssertEqual(sample.usedPercent, 3)
        XCTAssertEqual(sample.timestamp, Self.base.addingTimeInterval(120))
    }

    func testPercentageIsRoundedAndRangeChecked() throws {
        let sample = try XCTUnwrap(
            KiroLocalSessionAdapter.parseCreditUsagePercent(jsonl: metadataLine(percent: 16.96, offset: 0), fallbackTimestamp: nil)
        )
        XCTAssertEqual(sample.usedPercent, 17)

        XCTAssertNil(KiroLocalSessionAdapter.parseCreditUsagePercent(
            jsonl: metadataLine(percent: 140, offset: 0),
            fallbackTimestamp: nil
        ))
        XCTAssertNil(KiroLocalSessionAdapter.parseCreditUsagePercent(
            jsonl: metadataLine(percent: -2, offset: 0),
            fallbackTimestamp: nil
        ))
    }

    func testUnrelatedAndMalformedLinesAreIgnored() {
        let jsonl = """
        not json at all
        {"payload":{"type":"usage_summary","promptTurnSummaries":[{"unit":"credit","usage":6.05}]}}
        {"payload":{"type":"session_metadata","value":{}}}
        """

        XCTAssertNil(KiroLocalSessionAdapter.parseCreditUsagePercent(jsonl: jsonl, fallbackTimestamp: Self.base))
    }

    func testATimestamplessRecordFallsBackToTheFileDate() throws {
        let jsonl = #"{"payload":{"type":"session_metadata","value":{"usagePercentage":42.0}}}"#

        let sample = try XCTUnwrap(
            KiroLocalSessionAdapter.parseCreditUsagePercent(jsonl: jsonl, fallbackTimestamp: Self.base)
        )

        XCTAssertEqual(sample.usedPercent, 42)
        XCTAssertEqual(sample.timestamp, Self.base)
    }

    /// The number is the provider's; the window it belongs to is not stated anywhere Kiro writes.
    /// So it carries no reset time and only medium confidence, and it is labelled as credits
    /// rather than being dressed up as a calendar month.
    func testCreditWindowIsLabelledHonestly() throws {
        let snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [],
            contextPercent: nil,
            creditUsage: KiroLocalSessionAdapter.CreditUsageSample(usedPercent: 17, timestamp: Self.base),
            staleThreshold: 900,
            now: Self.base.addingTimeInterval(60)
        )

        let window = try XCTUnwrap(snapshot.monthly)
        XCTAssertEqual(window.usedPercent, 17)
        XCTAssertEqual(window.remainingPercent, 83)
        XCTAssertEqual(window.label, "cr")
        XCTAssertEqual(window.confidence, .medium)
        XCTAssertEqual(window.providerWindowID, "credit-usage")
        XCTAssertNil(window.resetAt)
        XCTAssertEqual(snapshot.statusMessage, "Local sessions · Kiro-reported credit usage")
    }

    func testNoSampleKeepsTheHonestNoQuotaMessage() {
        let snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [
                KiroLocalSessionAdapter.CreditEntry(credits: 6, timestamp: Self.base, toolCalls: 1)
            ],
            contextPercent: nil,
            staleThreshold: 900,
            now: Self.base.addingTimeInterval(60)
        )

        XCTAssertNil(snapshot.monthly)
        XCTAssertEqual(snapshot.statusMessage, "Local sessions · credits metered, no quota window")
    }

    /// Kiro's opt-in usage API is the authoritative source, so it keeps the weekly slot and the
    /// local credit reading stays where it is instead of competing with it.
    func testTheUsageAPIStillOwnsTheWeeklySlot() throws {
        let local = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [],
            contextPercent: nil,
            creditUsage: KiroLocalSessionAdapter.CreditUsageSample(usedPercent: 17, timestamp: Self.base),
            staleThreshold: 900,
            now: Self.base.addingTimeInterval(60)
        )

        let merged = KiroLocalSessionAdapter.applyingUsageLimits(
            KiroUsageLimits(usedPercent: 40, resetAt: Self.base.addingTimeInterval(86_400), observedAt: Self.base),
            to: local
        )

        XCTAssertEqual(merged.weekly?.usedPercent, 40)
        XCTAssertEqual(merged.weekly?.providerWindowID, "usage-limits")
        XCTAssertEqual(merged.monthly?.usedPercent, 17)
    }

    /// A monthly-only window used to fall through to "no value", so the snapshot carried a
    /// perfectly good percentage that the menu bar refused to draw.
    func testAMonthlyOnlyWindowReachesTheMenuBar() throws {
        let snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [],
            contextPercent: nil,
            creditUsage: KiroLocalSessionAdapter.CreditUsageSample(usedPercent: 17, timestamp: Self.base),
            staleThreshold: 900,
            now: Self.base.addingTimeInterval(60)
        )

        let window = try XCTUnwrap(MenuBarStatusService().displayWindow(for: snapshot))

        XCTAssertEqual(window.usedPercent, 17)
        XCTAssertEqual(window.providerWindowID, "credit-usage")
    }
}
