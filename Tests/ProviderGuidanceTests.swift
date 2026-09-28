import XCTest
@testable import TokenCore

/// A provider that is connected and reading but has nothing useful has to say what to do about it.
/// Both of these messages were true and useless, so they sent people looking for a fault instead of
/// at the Setup Guide that already holds the answer.
final class ProviderGuidanceTests: XCTestCase {
    private static let claudeGuidance = "Local JSONL · connect the statusline for limits"
    private static let antigravityGuidance = "Statusline connected · waiting for the first session"

    /// Claude Code does not write rate limits to its local JSONL — the statusline bridge supplies
    /// them — and "rate limits unavailable" never said so.
    func testClaudeLocalJSONLPointsAtTheStatuslineBridge() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenCore/Services/DataSourceAdapters.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(Self.claudeGuidance))
        XCTAssertFalse(
            source.contains("Local JSONL · rate limits unavailable"),
            "the message that stated a limitation without naming the fix is gone"
        )
        XCTAssertTrue(source.contains(Self.antigravityGuidance))
        XCTAssertFalse(
            source.contains("No Antigravity or Gemini token events yet"),
            "an installed-but-never-written bridge is not the same as no source"
        )
    }

    /// The guidance is what a new user acts on, so it is translated even though the rest of the
    /// adapter status vocabulary is still English.
    func testGuidanceIsTranslatedEverywhereTokenPilotShips() {
        for key in [Self.claudeGuidance, Self.antigravityGuidance] {
            for language in TokenPilotLanguage.allCases where language != .system {
                let localized = TokenPilotLocalizer.localized(key, language: language)
                XCTAssertFalse(localized.isEmpty, "\(key) in \(language)")
                if language != .en {
                    XCTAssertNotEqual(localized, key, "\(key) is untranslated in \(language)")
                }
            }
        }
    }
}

/// Kiro's CLI sessions are the only half of Kiro that records tokens at all; the IDE transcript
/// meters in credits and reports none.
final class KiroCLITurnTests: XCTestCase {
    private static let base = Date(timeIntervalSince1970: 1_785_420_706)

    private func sessionJSON(turns: [[String: Any]]) -> [String: Any] {
        ["session_state": ["conversation_metadata": ["user_turn_metadatas": turns]]]
    }

    private func turn(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        requests: Int = 1,
        model: String? = "auto",
        timestamp: Int? = 1_785_420_706
    ) -> [String: Any] {
        var value: [String: Any] = [
            "input_token_count": input,
            "output_token_count": output,
            "cache_read_input_token_count": cacheRead,
            "cache_write_input_token_count": cacheWrite,
            "total_request_count": requests
        ]
        if let model { value["model"] = model }
        if let timestamp {
            value["result"] = ["Ok": ["meta": ["timestamp": timestamp]]]
        }
        return value
    }

    func testEveryTokenFieldIsRead() throws {
        let events = KiroLocalSessionAdapter.parseCLITurns(
            sessionJSON: sessionJSON(turns: [
                turn(input: 120, output: 340, cacheRead: 9_000, cacheWrite: 45, requests: 2, model: "claude-sonnet-4")
            ]),
            fallbackTimestamp: nil
        )

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.provider, .kiro)
        XCTAssertEqual(event.inputTokens, 120)
        XCTAssertEqual(event.outputTokens, 340)
        XCTAssertEqual(event.cacheReadTokens, 9_000)
        XCTAssertEqual(event.cacheCreationTokens, 45)
        XCTAssertEqual(event.requestCount, 2)
        XCTAssertEqual(event.model, "claude-sonnet-4")
        XCTAssertEqual(event.source, "kiro-cli-turn")
        XCTAssertEqual(event.timestamp, Self.base)
        // The cache-read split has to survive, or Kiro would land back on an inflated headline.
        XCTAssertEqual(event.totalTokens, 9_505)
        XCTAssertEqual(event.workingTokens, 505)
    }

    /// Every turn on the development machine reports zero tokens, so this is the shape that had to
    /// keep working: a real turn that simply did not spend anything.
    func testAZeroTokenTurnStillCountsAsARequest() throws {
        let events = KiroLocalSessionAdapter.parseCLITurns(
            sessionJSON: sessionJSON(turns: [turn()]),
            fallbackTimestamp: nil
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].totalTokens, 0)
        XCTAssertEqual(events[0].requestCount, 1)
    }

    func testBookkeepingTurnsAreSkipped() {
        let events = KiroLocalSessionAdapter.parseCLITurns(
            sessionJSON: sessionJSON(turns: [turn(requests: 0)]),
            fallbackTimestamp: nil
        )

        XCTAssertTrue(events.isEmpty, "no tokens and no request is bookkeeping, not usage")
    }

    func testATimestamplessTurnFallsBackToTheFileDateAndIsDroppedWithoutOne() {
        let fallback = Date(timeIntervalSince1970: 1_800_000_000)
        let withFallback = KiroLocalSessionAdapter.parseCLITurns(
            sessionJSON: sessionJSON(turns: [turn(output: 10, timestamp: nil)]),
            fallbackTimestamp: fallback
        )
        XCTAssertEqual(withFallback.first?.timestamp, fallback)

        let withoutAnything = KiroLocalSessionAdapter.parseCLITurns(
            sessionJSON: sessionJSON(turns: [turn(output: 10, timestamp: nil)]),
            fallbackTimestamp: nil
        )
        XCTAssertTrue(withoutAnything.isEmpty, "an undateable turn is dropped rather than stamped now")
    }

    func testAFileWithoutConversationMetadataYieldsNothing() {
        XCTAssertTrue(
            KiroLocalSessionAdapter.parseCLITurns(sessionJSON: ["session_state": [:]], fallbackTimestamp: Self.base).isEmpty
        )
        XCTAssertTrue(
            KiroLocalSessionAdapter.parseCLITurns(sessionJSON: [:], fallbackTimestamp: Self.base).isEmpty
        )
    }

    /// Credit turns and CLI turns come from different files, so they add up rather than compete.
    func testCLITurnsJoinTheCreditEventsAndCarryTheTokenTotals() throws {
        let snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [
                KiroLocalSessionAdapter.CreditEntry(credits: 6, timestamp: Self.base, toolCalls: 2)
            ],
            contextPercent: nil,
            cliEvents: KiroLocalSessionAdapter.parseCLITurns(
                sessionJSON: sessionJSON(turns: [turn(input: 100, output: 200, cacheRead: 9_000)]),
                fallbackTimestamp: nil
            ),
            staleThreshold: 900,
            now: Self.base.addingTimeInterval(60)
        )

        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(Set(snapshot.events.map(\.source)), ["kiro-usage-summary", "kiro-cli-turn"])
        XCTAssertEqual(snapshot.todayTokens, 9_300)
        XCTAssertEqual(snapshot.todayCacheReadTokens, 9_000)
        XCTAssertEqual(snapshot.todayWorkingTokens, 300)
    }
}
