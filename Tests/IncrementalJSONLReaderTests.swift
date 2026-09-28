import SQLite3
import XCTest
@testable import TokenCore

/// Claude session files were read through a 4 MB tail; on a real machine the largest recent one was
/// 117 MB, so most of a long session never counted. These pin the replacement: whole files, read
/// once, then only what was appended.
final class IncrementalJSONLReaderTests: XCTestCase {
    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jsonl-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func read(_ reader: IncrementalJSONLReader<String>, _ url: URL) -> [String] {
        reader.parsed(url, keep: { _ in true }) { line in
            (jsonObject(fromLine: line)?["id"] as? String)
        }
    }

    func testAUsageLineBeforeManyMegabytesOfOtherOutputStillCounts() throws {
        let url = try tempFile()
        let filler = "{\"type\":\"tool_result\",\"content\":\"" + String(repeating: "x", count: 1_000) + "\"}\n"
        try append("{\"id\":\"first\",\"usage\":{}}\n", to: url)
        try append(String(repeating: filler, count: 6_000), to: url) // ~6 MB past the old tail
        try append("{\"id\":\"last\",\"usage\":{}}\n", to: url)

        XCTAssertEqual(read(IncrementalJSONLReader(requiredFragment: "\"usage\""), url), ["first", "last"])
    }

    func testLaterReadsPickUpOnlyAppendedLinesAndWaitForPartialOnes() throws {
        let url = try tempFile()
        let reader = IncrementalJSONLReader<String>(requiredFragment: "\"usage\"")
        try append("{\"id\":\"a\",\"usage\":{}}\n", to: url)
        XCTAssertEqual(read(reader, url), ["a"])

        try append("{\"id\":\"b\",\"usa", to: url) // still being written
        XCTAssertEqual(read(reader, url), ["a"], "a half-written line is not consumed")

        try append("ge\":{}}\n", to: url)
        XCTAssertEqual(read(reader, url), ["a", "b"], "and is read whole once finished, exactly once")
        XCTAssertEqual(read(reader, url), ["a", "b"])
    }

    func testAFileThatShrankIsReadAgainFromTheStart() throws {
        let url = try tempFile()
        let reader = IncrementalJSONLReader<String>(requiredFragment: "\"usage\"")
        try append("{\"id\":\"old-1\",\"usage\":{}}\n{\"id\":\"old-2\",\"usage\":{}}\n", to: url)
        XCTAssertEqual(read(reader, url), ["old-1", "old-2"])

        try Data("{\"id\":\"new\",\"usage\":{}}\n".utf8).write(to: url)
        XCTAssertEqual(read(reader, url), ["new"])
    }

    func testAFileReplacedByALargerOneIsReadAgainFromTheStart() throws {
        let url = try tempFile()
        let reader = IncrementalJSONLReader<String>(requiredFragment: "\"usage\"")
        try append("{\"id\":\"old\",\"usage\":{}}\n", to: url)
        XCTAssertEqual(read(reader, url), ["old"])

        let replacement = (1...5).map { "{\"id\":\"new-\($0)\",\"usage\":{}}\n" }.joined()
        try Data(replacement.utf8).write(to: url, options: .atomic) // new inode, larger file
        XCTAssertEqual(read(reader, url), (1...5).map { "new-\($0)" })
    }
}


/// opencode keeps its database in WAL mode. Read `immutable=1`, the WAL was ignored, so anything
/// written since the last checkpoint was invisible while the agent was busy.
final class WALDatabaseReadTests: XCTestCase {
    func testRowsStillInTheWALAreVisible() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wal-\(UUID().uuidString).db").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) } // closing would checkpoint; keep it open across the read
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0",
                    "CREATE TABLE message(id TEXT)", "INSERT INTO message VALUES ('in-the-wal')"] {
            XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"))

        let rows = TokenPilotSQLite.query(databasePath: path, sql: "SELECT id FROM message", maxRows: 10, columnCount: 1)
        XCTAssertEqual(rows, [["in-the-wal"]], "a row written since the last checkpoint must be read")
    }
}
