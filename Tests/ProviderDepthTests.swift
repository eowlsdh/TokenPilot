import XCTest
@testable import TokenCore

/// Provider *depth* — twelve providers is worth nothing if one of them cannot tell the user its data
/// has gone cold. Found by driving every local adapter against this machine's real sources and
/// comparing what came back: Claude, Kiro, opencode and Grok all reported staleness; Codex reported
/// `stale=false` on a session log 130 minutes old, because the flag was hardcoded.
final class ProviderDepthTests: XCTestCase {
    /// A snapshot built from a local log has to be able to say its data went cold. The other
    /// hardcodes in this file are legitimate — a freshly fetched balance, a value the user typed, a
    /// file that parsed but carried nothing — so the check is scoped to the source that ages.
    func testNoLocalLogSnapshotHardcodesFreshness() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenCore/Services/DataSourceAdapters.swift"),
            encoding: .utf8
        )
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        var offenders: [Int] = []
        for (index, line) in lines.enumerated() where line.contains("dataSource: .localLog") {
            let window = lines[max(0, index - 8)...min(lines.count - 1, index + 8)]
            if window.contains(where: { $0.contains("isStale: false") }) {
                offenders.append(index + 1)
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "a local-log snapshot that cannot go stale cannot warn anyone; lines: \(offenders)"
        )
    }

    /// Codex's threshold has to agree with the freshness the capacity pipeline already applies to its
    /// windows, or the provider row and the capacity card would disagree about the same reading.
    func testCodexStalenessMatchesTheCapacityFreshnessItAlreadyUses() throws {
        let services = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenCore/Services/TokenPilotServices.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(CodexLocalSessionAdapter.sessionStaleThreshold, 15 * 60)
        XCTAssertTrue(
            services.contains("maximumAge: 15 * 60"),
            "the capacity pipeline no longer uses a 15-minute window; the adapter has to follow"
        )
    }

    /// A session log older than the threshold has to say so, and a fresh one must not.
    func testACodexSessionOlderThanTheThresholdIsMarkedStale() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexDepth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        func snapshot(minutesAgo: Int) async throws -> ProviderSnapshot {
            let at = Date().addingTimeInterval(-Double(minutesAgo) * 60)
            let stamp = ISO8601DateFormatter().string(from: at)
            let line = "{\"timestamp\":\"\(stamp)\",\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":12,\"output_tokens\":3,\"cached_input_tokens\":2,\"reasoning_output_tokens\":1}}}\n"
            let file = directory.appendingPathComponent("session-\(minutesAgo).jsonl")
            try line.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: file.path)
            defer { try? FileManager.default.removeItem(at: file) }

            var settings = AppSettings()
            settings.codexEnabled = true
            let adapter = CodexLocalSessionAdapter(sessionRoots: [directory])
            return await adapter.snapshot(settings: settings)
        }

        let fresh = try await snapshot(minutesAgo: 2)
        let cold = try await snapshot(minutesAgo: 130)

        XCTAssertFalse(fresh.isStale, "a session written two minutes ago is not stale")
        XCTAssertTrue(cold.isStale, "a session written 130 minutes ago is")
        XCTAssertTrue(cold.statusMessage?.contains("STALE") == true, cold.statusMessage ?? "no status message")
    }
}
