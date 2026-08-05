import XCTest
import SQLite3
@testable import TokenCore

/// SQLite keeps the caller's pointer for SQLITE_STATIC. A Swift String bridged to a C string only
/// lives for the duration of the call, so fixtures must bind with SQLITE_TRANSIENT to force a copy.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class OpenCodeAdapterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenpilot-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    func testReadsExactTokenCountsFromV1MessageTable() async throws {
        let database = directory.appendingPathComponent("opencode.db")
        try makeDatabase(at: database, table: "message", payloads: [Self.assistantPayload(at: Date())])

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        let event = try XCTUnwrap(snapshot.events.first)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(event.inputTokens, 1_000)
        XCTAssertEqual(event.outputTokens, 250)
        XCTAssertEqual(event.reasoningTokens, 40)
        XCTAssertEqual(event.cacheReadTokens, 300)
        XCTAssertEqual(event.cacheCreationTokens, 10)
        XCTAssertEqual(event.totalTokens, 1_600)
        XCTAssertEqual(event.model, "anthropic/claude-sonnet")
        XCTAssertEqual(snapshot.todayTokens, 1_600)
        XCTAssertEqual(snapshot.dataSource, .localLog)
    }

    func testReadsV2SessionMessageTable() async throws {
        let database = directory.appendingPathComponent("opencode-next.db")
        try makeDatabase(at: database, table: "session_message", payloads: [Self.assistantPayload(at: Date())])

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testAttachesWorkspaceFolderLabelFromSessionTable() async throws {
        let database = directory.appendingPathComponent("opencode.db")
        let now = Date()
        try makeSessionAwareDatabase(at: database, messages: [
            (sessionID: "ses_a", payload: Self.assistantPayload(at: now)),
            (sessionID: "ses_b", payload: Self.assistantPayload(at: now.addingTimeInterval(-60)))
        ])

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        XCTAssertEqual(snapshot.events.count, 2)
        let labels = Set(snapshot.events.compactMap(\.projectLabel))
        XCTAssertEqual(labels, ["TokenPilot", "OtherProject"])
        XCTAssertTrue(snapshot.events.allSatisfy { $0.projectLabel != nil })
        XCTAssertTrue(snapshot.events.allSatisfy { !($0.projectLabel?.contains("/") ?? false) },
                      "Labels must be workspace folder names, never full paths.")
    }

    func testMissingSessionTableLeavesProjectLabelNil() async throws {
        let database = directory.appendingPathComponent("opencode.db")
        try makeDatabase(at: database, table: "message", payloads: [Self.assistantPayload(at: Date())])

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertNil(snapshot.events.first?.projectLabel)
    }

    func testDatabaseReadKeepsDistinctParallelMessagesRoundedToTheSameSecond() async throws {
        let now = Date()
        let second = floor(now.timeIntervalSince1970)
        let database = directory.appendingPathComponent("opencode.db")
        // 0.2s and the previous second's 0.9s both round to `second`; a content-based dedup key
        // merged them and dropped one real usage event. The read path dedups by message id, so
        // both must survive.
        let stamp1 = Int64((second + 0.2) * 1000)
        let stamp2 = Int64((second - 0.1) * 1000)
        let payload = Self.assistantPayload(at: Date(timeIntervalSince1970: second))
        try makeDatabase(at: database, table: "message", payloads: [payload, payload], timestamps: [stamp1, stamp2])

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        XCTAssertEqual(snapshot.events.count, 2, "Distinct parallel messages must not be merged by second-rounding.")
        XCTAssertEqual(snapshot.todayTokens, 3_200)
    }

    func testCrossDatabaseReadsDeduplicateByRealMessageID() async throws {
        let first = directory.appendingPathComponent("opencode.db")
        let second = directory.appendingPathComponent("opencode-next.db")
        let payload = Self.assistantPayload(at: Date())
        // Both rows are inserted with the same id ("row-0") — the same message observed through
        // overlapping databases must be read exactly once.
        try makeDatabase(at: first, table: "message", payloads: [payload])
        try makeDatabase(at: second, table: "session_message", payloads: [payload])

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [first, second], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        XCTAssertEqual(snapshot.events.count, 1, "Same message id across databases must be read once.")
        XCTAssertEqual(snapshot.todayTokens, 1_600)
    }

    func testDatabaseReadIgnoresMessagesOutsideRetentionWindow() async throws {
        let now = Date()
        let database = directory.appendingPathComponent("opencode.db")
        let old = Int64((now.timeIntervalSince1970 - 46 * 24 * 3_600) * 1000)
        let recent = Int64(now.timeIntervalSince1970 * 1000)
        try makeDatabase(
            at: database,
            table: "message",
            payloads: [Self.assistantPayload(at: now), Self.assistantPayload(at: now)],
            timestamps: [old, recent]
        )

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        XCTAssertEqual(snapshot.events.count, 1, "Rows older than the 44-day retention window must not be read.")
    }

    func testOpenCodeUsageIsMeasuredNotEstimated() async throws {
        let database = directory.appendingPathComponent("opencode.db")
        try makeDatabase(at: database, table: "message", payloads: [Self.assistantPayload(at: Date())])

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        XCTAssertTrue(snapshot.events.allSatisfy { !$0.isEstimated })
        XCTAssertTrue(snapshot.events.allSatisfy { !$0.isExperimental })
    }

    func testReadingDoesNotMutateTheDatabaseOrCreateSidecars() async throws {
        let database = directory.appendingPathComponent("opencode.db")
        try makeDatabase(at: database, table: "message", payloads: [Self.assistantPayload(at: Date())])
        let before = try Data(contentsOf: database)

        _ = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: Self.enabledSettings())

        let after = try Data(contentsOf: database)
        XCTAssertEqual(after, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-shm"))
    }

    func testRejectsMessagesWithoutUsableTokenCounts() {
        let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
        XCTAssertNil(OpenCodeSessionAdapter.parseMessage(
            json: "{\"role\":\"user\",\"time\":{\"created\":\(stamp)}}",
            fallbackTimestamp: Date()
        ))
        XCTAssertNil(OpenCodeSessionAdapter.parseMessage(
            json: "{\"tokens\":{\"input\":0,\"output\":0,\"cache\":{\"read\":0,\"write\":0}},\"time\":{\"created\":\(stamp)}}",
            fallbackTimestamp: Date()
        ))
        XCTAssertNil(OpenCodeSessionAdapter.parseMessage(json: "not json", fallbackTimestamp: Date()))
    }

    func testLegacyJSONStoreIsReadWithoutTouchingCredentialFiles() async throws {
        let messages = directory.appendingPathComponent("storage/message", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let payload = Self.assistantPayload(at: Date())
        try XCTUnwrap(payload.data(using: .utf8)).write(to: messages.appendingPathComponent("msg1.json"))
        try XCTUnwrap(payload.data(using: .utf8)).write(to: messages.appendingPathComponent("auth.json"))

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [], legacyMessageRoots: [messages])
            .snapshot(settings: Self.enabledSettings())

        XCTAssertEqual(snapshot.events.count, 1, "auth.json must be skipped and the duplicate deduplicated")
    }

    func testDisabledProviderProducesNoUsage() async throws {
        let database = directory.appendingPathComponent("opencode.db")
        try makeDatabase(at: database, table: "message", payloads: [Self.assistantPayload(at: Date())])
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.opencode, isEnabled: false)

        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: settings)

        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.statusMessage, "Disabled")
    }

    func testMissingStoreDoesNotClaimConnectedData() async {
        let snapshot = await OpenCodeSessionAdapter(
            databaseURLs: [directory.appendingPathComponent("absent.db")],
            legacyMessageRoots: []
        ).snapshot(settings: Self.enabledSettings())

        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.dataSource, .unknown)
        XCTAssertEqual(snapshot.confidence, .low)
    }

    func testOpenCodeActivityIsNeverPresentedAsProviderQuota() async throws {
        let now = Date()
        let database = directory.appendingPathComponent("opencode.db")
        try makeDatabase(at: database, table: "message", payloads: [Self.assistantPayload(at: now)])
        let settings = Self.enabledSettings()
        let snapshot = await OpenCodeSessionAdapter(databaseURLs: [database], legacyMessageRoots: [])
            .snapshot(settings: settings)

        let observations = CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now)
        XCTAssertFalse(observations.isEmpty)
        XCTAssertTrue(observations.allSatisfy { $0.comparability == .incomparable })
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)

        let assessments = observations.map { CapacityAssessmentService().assess($0, now: now) }
        XCTAssertTrue(assessments.allSatisfy { $0.alertEligibility == .ineligible })
    }

    // MARK: - Fixture helpers

    private static func enabledSettings() -> AppSettings {
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.opencode, isEnabled: true)
        _ = settings.setProviderEnabled(.kiro, isEnabled: true)
        return settings
    }

    private static func assistantPayload(at date: Date) -> String {
        let stamp = Int64(date.timeIntervalSince1970 * 1_000)
        return """
        {"role":"assistant","cost":0.0125,"modelID":"claude-sonnet","providerID":"anthropic",\
        "tokens":{"input":1000,"output":250,"reasoning":40,"cache":{"read":300,"write":10}},\
        "time":{"created":\(stamp),"completed":\(stamp)}}
        """
    }

    /// Builds a DB matching opencode's session-aware schema: a `session` table with
    /// `directory`, plus a `message` table whose rows reference `session_id`.
    private func makeSessionAwareDatabase(
        at url: URL,
        messages: [(sessionID: String, payload: String)]
    ) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw XCTSkip("Unable to create SQLite fixture")
        }
        defer { sqlite3_close_v2(handle) }

        let sessionDDL = "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL, title TEXT NOT NULL);"
        XCTAssertEqual(sqlite3_exec(handle, sessionDDL, nil, nil, nil), SQLITE_OK)
        let messageDDL = "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL, time_created INTEGER NOT NULL);"
        XCTAssertEqual(sqlite3_exec(handle, messageDDL, nil, nil, nil), SQLITE_OK)

        let sessionSQL = "INSERT INTO session (id, directory, title) VALUES (?, ?, ?);"
        for (id, directory, title) in [
            ("ses_a", "/Users/test/TokenPilot", "A"),
            ("ses_b", "/Users/test/OtherProject", "B")
        ] {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, sessionSQL, -1, &statement, nil), SQLITE_OK)
            let bound = try XCTUnwrap(statement)
            sqlite3_bind_text(bound, 1, id, -1, sqliteTransient)
            sqlite3_bind_text(bound, 2, directory, -1, sqliteTransient)
            sqlite3_bind_text(bound, 3, title, -1, sqliteTransient)
            XCTAssertEqual(sqlite3_step(bound), SQLITE_DONE)
            sqlite3_finalize(bound)
        }

        let messageSQL = "INSERT INTO message (id, session_id, data, time_created) VALUES (?, ?, ?, ?);"
        for (index, message) in messages.enumerated() {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, messageSQL, -1, &statement, nil), SQLITE_OK)
            let bound = try XCTUnwrap(statement)
            sqlite3_bind_text(bound, 1, "msg-\(index)", -1, sqliteTransient)
            sqlite3_bind_text(bound, 2, message.sessionID, -1, sqliteTransient)
            sqlite3_bind_text(bound, 3, message.payload, -1, sqliteTransient)
            sqlite3_bind_int64(bound, 4, Int64(Date().timeIntervalSince1970 * 1_000))
            XCTAssertEqual(sqlite3_step(bound), SQLITE_DONE)
            sqlite3_finalize(bound)
        }
    }

    private func makeDatabase(
        at url: URL,
        table: String,
        payloads: [String],
        timestamps: [Int64]? = nil
    ) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw XCTSkip("Unable to create SQLite fixture")
        }
        defer { sqlite3_close_v2(handle) }

        let ddl = "CREATE TABLE \(table) (id TEXT PRIMARY KEY, data TEXT NOT NULL, time_created INTEGER NOT NULL);"
        XCTAssertEqual(sqlite3_exec(handle, ddl, nil, nil, nil), SQLITE_OK)

        for (index, payload) in payloads.enumerated() {
            var statement: OpaquePointer?
            let sql = "INSERT INTO \(table) (id, data, time_created) VALUES (?, ?, ?);"
            XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
            let bound = try XCTUnwrap(statement)
            sqlite3_bind_text(bound, 1, "row-\(index)", -1, sqliteTransient)
            sqlite3_bind_text(bound, 2, payload, -1, sqliteTransient)
            let stamp = timestamps?[index] ?? Int64(Date().timeIntervalSince1970 * 1_000)
            sqlite3_bind_int64(bound, 3, stamp)
            XCTAssertEqual(sqlite3_step(bound), SQLITE_DONE)
            sqlite3_finalize(bound)
        }
    }
}

final class KiroAdapterTests: XCTestCase {
    func testParsesCreditMeteredUsageSummary() throws {
        let now = Date()
        let entries = KiroLocalSessionAdapter.parseUsageSummaries(
            jsonl: Self.usageSummaryLine(at: now, usage: 6.0503928492205645, tools: ["read_file", "execute_bash"]),
            fallbackTimestamp: now
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        // JSON numbers decode as Double, so compare within display-relevant tolerance.
        XCTAssertEqual(NSDecimalNumber(decimal: entry.credits).doubleValue, 6.0503928492205645, accuracy: 0.000001)
        XCTAssertEqual(TokenPilotFormatters.creditAmount(entry.credits), "6.05")
        XCTAssertEqual(entry.toolCalls, 2)
    }

    func testIgnoresSummariesThatAreNotCreditDenominated() {
        let line = """
        {"id":"m","timestamp":"\(Self.stamp(Date()))","payload":{"type":"usage_summary",\
        "promptTurnSummaries":[{"unit":"widget","usage":99.0,"usedTools":[]}]}}
        """
        XCTAssertTrue(KiroLocalSessionAdapter.parseUsageSummaries(jsonl: line, fallbackTimestamp: Date()).isEmpty)
    }

    func testIgnoresUnrelatedTranscriptPayloads() {
        let stamp = Self.stamp(Date())
        let jsonl = """
        {"id":"a","timestamp":"\(stamp)","payload":{"type":"tool_call","name":"read_file"}}
        {"id":"b","timestamp":"\(stamp)","payload":{"type":"assistant"}}
        not json
        {}
        """
        XCTAssertTrue(KiroLocalSessionAdapter.parseUsageSummaries(jsonl: jsonl, fallbackTimestamp: Date()).isEmpty)
    }

    func testParsesContextWindowPercentageFromCLISession() throws {
        let now = Date()
        let session: [String: Any] = [
            "session_id": "s1",
            "updated_at": Self.stamp(now),
            "session_state": ["rts_model_state": [
                "context_usage_percentage": 41.7,
                "model_info": ["context_window_tokens": 1_000_000]
            ]]
        ]

        let parsed = try XCTUnwrap(KiroLocalSessionAdapter.parseContextPercent(sessionJSON: session, fallbackTimestamp: now))
        XCTAssertEqual(parsed.percent, 42)
    }

    func testRejectsMissingOrOutOfRangeContextPercentage() {
        XCTAssertNil(KiroLocalSessionAdapter.parseContextPercent(
            sessionJSON: ["session_state": ["rts_model_state": ["context_usage_percentage": NSNull()]]],
            fallbackTimestamp: Date()
        ))
        XCTAssertNil(KiroLocalSessionAdapter.parseContextPercent(
            sessionJSON: ["updated_at": Self.stamp(Date()), "session_state": ["rts_model_state": ["context_usage_percentage": 150.0]]],
            fallbackTimestamp: Date()
        ))
    }

    func testAcceptsBothSecondAndMillisecondEpochTimestamps() {
        let now = Date()
        let millisecond: [String: Any] = [
            "updated_at": NSNumber(value: now.timeIntervalSince1970 * 1_000),
            "session_state": ["rts_model_state": ["context_usage_percentage": 10.0]]
        ]
        let second: [String: Any] = [
            "updated_at": NSNumber(value: now.timeIntervalSince1970),
            "session_state": ["rts_model_state": ["context_usage_percentage": 10.0]]
        ]

        XCTAssertNotNil(KiroLocalSessionAdapter.parseContextPercent(sessionJSON: millisecond, fallbackTimestamp: nil))
        XCTAssertNotNil(KiroLocalSessionAdapter.parseContextPercent(sessionJSON: second, fallbackTimestamp: nil))
    }

    func testKiroNeverInventsTokenCountsFromCredits() {
        let now = Date()
        let snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [
                .init(credits: Decimal(string: "6.05")!, timestamp: now, toolCalls: 3),
                .init(credits: Decimal(string: "44.679")!, timestamp: now, toolCalls: 21)
            ],
            contextPercent: (percent: 41, timestamp: now),
            staleThreshold: 900,
            now: now
        )

        XCTAssertEqual(snapshot.creditsUsed, Decimal(string: "50.729"))
        XCTAssertEqual(snapshot.todayTokens, 0)
        XCTAssertTrue(snapshot.events.allSatisfy { $0.totalTokens == 0 })
        XCTAssertTrue(snapshot.events.allSatisfy { !$0.isEstimated })
        XCTAssertEqual(snapshot.contextWindowUsedPercent, 41)
        XCTAssertEqual(snapshot.events.map(\.requestCount).sorted(), [3, 21])
        XCTAssertNil(snapshot.todayCostUSD, "credits must never be reported as currency")
    }

    func testCreditsAreScopedToTodayAndStalenessIsHonest() {
        let now = Date()
        let snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [.init(credits: Decimal(string: "9.5")!, timestamp: now.addingTimeInterval(-3 * 86_400), toolCalls: 1)],
            contextPercent: nil,
            staleThreshold: 900,
            now: now
        )

        XCTAssertNil(snapshot.creditsUsed)
        XCTAssertTrue(snapshot.isStale)
    }

    func testEmptySessionsDoNotClaimUsage() {
        let snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [],
            contextPercent: nil,
            staleThreshold: 900,
            now: Date()
        )

        XCTAssertNil(snapshot.creditsUsed)
        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testDisabledProviderProducesNoUsage() async {
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.kiro, isEnabled: false)

        let snapshot = await KiroLocalSessionAdapter().snapshot(settings: settings)

        XCTAssertNil(snapshot.creditsUsed)
        XCTAssertEqual(snapshot.statusMessage, "Disabled")
    }

    func testKiroCreditsAreNeverPresentedAsProviderQuota() {
        let now = Date()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.kiro, isEnabled: true)
        var snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [.init(credits: Decimal(string: "12.5")!, timestamp: now, toolCalls: 2)],
            contextPercent: (percent: 33, timestamp: now),
            staleThreshold: 900,
            now: now
        )
        snapshot.updatedAt = now

        let observations = CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now)
        XCTAssertFalse(observations.isEmpty)
        XCTAssertTrue(observations.allSatisfy { $0.comparability == .incomparable })
        XCTAssertTrue(observations.contains { $0.value.kind == .credits })

        let assessments = observations.map { CapacityAssessmentService().assess($0, now: now) }
        XCTAssertTrue(assessments.allSatisfy { $0.alertEligibility == .ineligible })
    }

    func testIdleConnectedProviderIsNotLabelledAsNeedingSetup() {
        let now = Date()
        var settings = AppSettings()
        settings.localization.language = .en
        _ = settings.setProviderEnabled(.opencode, isEnabled: true)
        settings.menuBarDisplayStyle = .providerMetrics
        settings.menuBarMetricProviders = [.opencode]

        // Connected yesterday, so there is real evidence but nothing billed today.
        var idle = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        idle.updatedAt = now.addingTimeInterval(-3 * 86_400)
        idle.events = [UsageEvent(
            provider: .opencode,
            model: "opencode/test",
            timestamp: now.addingTimeInterval(-3 * 86_400),
            inputTokens: 500,
            outputTokens: 100,
            requestCount: 1,
            source: "opencode-session",
            dataSource: .localLog,
            isEstimated: false,
            isExperimental: false
        )]

        let idleSegment = MenuBarStatusService()
            .providerMetricsSegments(snapshots: [idle], settings: settings, now: now)
            .first { $0.provider == .opencode }
        XCTAssertEqual(idleSegment?.displayValue, "\u{2014}")
        XCTAssertTrue(idleSegment?.accessibilityLabel.contains("No usage today") ?? false, idleSegment?.accessibilityLabel ?? "nil")

        // Nothing detected at all must still ask the user to finish setup.
        let unconfigured = ProviderSnapshot(provider: .opencode, dataSource: .unknown)
        let setupSegment = MenuBarStatusService()
            .providerMetricsSegments(snapshots: [unconfigured], settings: settings, now: now)
            .first { $0.provider == .opencode }
        XCTAssertTrue(setupSegment?.accessibilityLabel.contains("Setup") ?? false, setupSegment?.accessibilityLabel ?? "nil")
    }

    // MARK: - Fixture helpers

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func usageSummaryLine(at date: Date, usage: Double, tools: [String]) -> String {
        let toolList = tools.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"m1","timestamp":"\(stamp(date))","payload":{"type":"usage_summary","status":"completed",\
        "elapsedTime":434880,"promptTurnSummaries":[{"unit":"credit","unitPlural":"credits",\
        "usage":\(usage),"usedTools":[\(toolList)]}]}}
        """
    }
}

final class CreditCapacityUnitTests: XCTestCase {
    func testCreditsRoundTripThroughEvidencePersistence() throws {
        let value = try CapacityValue(credits: Decimal(string: "56.841215918739643")!)
        let evidence = CapacityEvidenceValue(value: value)

        let encoded = try JSONEncoder().encode(evidence)
        let decoded = try JSONDecoder().decode(CapacityEvidenceValue.self, from: encoded)
        let restored = try decoded.capacityValue()

        XCTAssertEqual(decoded.unit, .credits)
        XCTAssertEqual(restored.credits, Decimal(string: "56.841215918739643"))
        XCTAssertNil(restored.moneyAmount, "credits must not decode as currency")
        XCTAssertNil(restored.tokens, "credits must not decode as tokens")
    }

    func testNegativeCreditsAreRejected() {
        XCTAssertThrowsError(try CapacityValue(credits: Decimal(-1)))
    }

    func testCreditFormattingNeverAddsACurrencySymbol() {
        XCTAssertFalse(TokenPilotFormatters.creditAmount(Decimal(string: "56.84")!).contains("$"))
        XCTAssertEqual(TokenPilotFormatters.creditAmount(Decimal(string: "56.84")!), "56.84")
        XCTAssertEqual(TokenPilotFormatters.creditAmount(Decimal(150)), "150")
        XCTAssertEqual(TokenPilotFormatters.creditAmount(Decimal(2_500)), "2.5K")
    }

    func testCreditSeriesIsAcceptedOnlyForKiro() {
        XCTAssertNoThrow(try CapacitySeriesID(provider: .kiro, providerWindowID: "credits-used", kind: .balance, unit: .credits))
        XCTAssertThrowsError(try CapacitySeriesID(provider: .claude, providerWindowID: "credits-used", kind: .balance, unit: .credits))
    }
}

final class ModelBreakdownTests: XCTestCase {
    func testModelBreakdownRanksHeaviestConsumerFirst() {
        let now = Date()
        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.events = [
            Self.event(model: "anthropic/sonnet", input: 1_000, at: now, cost: "0.02"),
            Self.event(model: "anthropic/sonnet", input: 500, at: now, cost: "0.01"),
            Self.event(model: "openai/gpt", input: 4_000, at: now, cost: nil)
        ]

        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .today)

        XCTAssertEqual(usage.modelBreakdown.count, 2)
        XCTAssertEqual(usage.modelBreakdown.first?.model, "openai/gpt")
        XCTAssertEqual(usage.modelBreakdown.first?.tokens, 4_000)
        XCTAssertNil(usage.modelBreakdown.first?.estimatedCostUSD, "cost stays nil when the provider reports none")
        let sonnet = usage.modelBreakdown.first { $0.model == "anthropic/sonnet" }
        XCTAssertEqual(sonnet?.tokens, 1_500)
        XCTAssertEqual(sonnet?.requestCount, 2)
        XCTAssertEqual(sonnet?.estimatedCostUSD, Decimal(string: "0.03"))
    }

    func testModelBreakdownPercentagesStayWithinRange() {
        let now = Date()
        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.events = [
            Self.event(model: "a", input: 750, at: now, cost: nil),
            Self.event(model: "b", input: 250, at: now, cost: nil)
        ]

        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .today)

        XCTAssertEqual(usage.modelBreakdown.map(\.tokenPercent), [75, 25])
        XCTAssertTrue(usage.modelBreakdown.allSatisfy { (0...100).contains($0.tokenPercent) })
    }

    func testUnlabeledModelIsGroupedExplicitly() {
        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.events = [Self.event(model: nil, input: 120, at: Date(), cost: nil)]

        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .today)

        XCTAssertEqual(usage.modelBreakdown.first?.model, "unknown")
    }

    func testExportIncludesModelBreakdownWithoutLeakingLocalPaths() throws {
        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.events = [Self.event(model: "anthropic/sonnet", input: 900, at: Date(), cost: "0.05")]
        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .today)

        let data = try UsageExportService().makeJSONData(usage: usage, snapshots: [snapshot], dataMode: "local")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let localActivity = try XCTUnwrap(root["localActivity"] as? [String: Any])
        let breakdown = try XCTUnwrap(localActivity["modelBreakdown"] as? [[String: Any]])

        XCTAssertFalse(breakdown.isEmpty)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(raw.contains("/Users/"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("access_token"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("refresh_token"))
    }

    private static func event(model: String?, input: Int, at date: Date, cost: String?) -> UsageEvent {
        UsageEvent(
            provider: .opencode,
            model: model,
            timestamp: date,
            inputTokens: input,
            outputTokens: 0,
            requestCount: 1,
            estimatedCostUSD: cost.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) },
            source: "opencode-session",
            dataSource: .localLog,
            isEstimated: false,
            isExperimental: false
        )
    }
}

final class SevenDayTrendTests: XCTestCase {
    func testSevenDayBarsAlwaysCoverSevenDaysEndingToday() {
        let now = Date()
        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.events = [Self.event(daysAgo: 0, tokens: 500, relativeTo: now), Self.event(daysAgo: 3, tokens: 200, relativeTo: now)]

        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .last7Days, now: now)

        XCTAssertEqual(usage.sevenDayBars.count, 7)
        XCTAssertEqual(usage.sevenDayBars.map(\.dayLabel).count, Set(usage.sevenDayBars.map(\.dayLabel)).count,
                       "labels must be unique so SwiftUI ForEach identity is stable")
        XCTAssertEqual(usage.sevenDayBars.reduce(0) { $0 + $1.tokens }, 700)
    }

    func testDaysWithoutActivityStayZeroRatherThanMissing() {
        let now = Date()
        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.events = [Self.event(daysAgo: 0, tokens: 100, relativeTo: now)]

        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .last7Days, now: now)

        XCTAssertEqual(usage.sevenDayBars.filter { $0.tokens == 0 }.count, 6)
        XCTAssertEqual(usage.sevenDayBars.last?.tokens, 100, "today is the trailing bar")
    }

    func testTrendIgnoresEventsOutsideTheSevenDayWindow() {
        let now = Date()
        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.events = [Self.event(daysAgo: 0, tokens: 50, relativeTo: now), Self.event(daysAgo: 30, tokens: 9_000, relativeTo: now)]

        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .last7Days, now: now)

        XCTAssertEqual(usage.sevenDayBars.reduce(0) { $0 + $1.tokens }, 50)
    }

    func testDailyBarNeverStoresNegativeTokens() {
        XCTAssertEqual(DailyUsageBar(dayLabel: "Mon", tokens: -5).tokens, 0)
    }

    private static func event(daysAgo: Int, tokens: Int, relativeTo now: Date) -> UsageEvent {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return UsageEvent(
            provider: .opencode,
            model: "opencode/test",
            timestamp: day,
            inputTokens: tokens,
            outputTokens: 0,
            requestCount: 1,
            source: "opencode-session",
            dataSource: .localLog,
            isEstimated: false,
            isExperimental: false
        )
    }
}

final class DebugFixtureFreshnessTests: XCTestCase {
    /// The DEBUG fixture anchors its events relative to `fixedReferenceDate` while AggregationService
    /// filters on wall-clock now. A hard-coded epoch silently emptied every usage screen, so the QA
    /// harness documented in docs/verification could not validate History at all.
    func testFixtureReferenceDateTracksNowInsteadOfAHardCodedEpoch() throws {
        let source = try Self.viewModelSource()

        XCTAssertFalse(
            source.contains("fixedReferenceDate = Date(timeIntervalSince1970:"),
            "a hard-coded epoch ages out of the today/last-7-days windows and empties fixture QA"
        )
        XCTAssertTrue(
            source.contains("private static let fixedReferenceDate = Date().addingTimeInterval(-300)"),
            "fixture anchor must sit just behind now so offsets stay inside aggregation windows"
        )
    }

    func testEventsAnchoredLikeTheFixturePopulateEveryHistoryPeriod() {
        let now = Date()
        let anchor = now.addingTimeInterval(-300)
        var snapshot = ProviderSnapshot(provider: .claude, dataSource: .officialStatusline)
        snapshot.events = [
            Self.event(at: anchor, tokens: 5_000, model: "claude-sonnet"),
            Self.event(at: anchor.addingTimeInterval(-86_400), tokens: 3_000, model: "claude-sonnet"),
            Self.event(at: anchor.addingTimeInterval(-2 * 86_400), tokens: 2_000, model: "claude-haiku")
        ]
        let aggregator = AggregationService()

        let today = aggregator.aggregate(snapshots: [snapshot], period: .today, now: now)
        XCTAssertEqual(today.events.count, 1, "fixture QA must not show an empty Today screen")

        let week = aggregator.aggregate(snapshots: [snapshot], period: .last7Days, now: now)
        XCTAssertEqual(week.events.count, 3)
        XCTAssertEqual(week.metrics.totalTokens, 10_000)
        XCTAssertTrue(week.sevenDayBars.contains { $0.tokens > 0 }, "trend card needs at least one non-zero bar")
        XCTAssertEqual(week.modelBreakdown.count, 2, "model card needs per-model rows")
        XCTAssertNotNil(week.metrics.busiestHour)
    }

    func testFutureDatedFixtureAnchorWouldBeFilteredOut() {
        // Guards the second failure mode found while fixing this: a fixed hour-of-day anchor is in the
        // future before that hour, and future events are dropped by the aggregator.
        let future = Date().addingTimeInterval(3_600)
        var snapshot = ProviderSnapshot(provider: .claude, dataSource: .officialStatusline)
        snapshot.events = [Self.event(at: future, tokens: 4_000, model: "claude-sonnet")]

        let today = AggregationService().aggregate(snapshots: [snapshot], period: .today)

        XCTAssertTrue(today.events.isEmpty, "future-dated fixture events must not be presented as usage")
    }

    func testHistoryScreenRendersTheTrendCardItAlreadyComputes() throws {
        let source = try Self.historyScreenSource()

        XCTAssertTrue(source.contains("HistorySevenDayTrendCard(bars: model.historyUsage.sevenDayBars"))
        XCTAssertTrue(source.contains("model.historyUsage.sevenDayBars.contains(where: { $0.tokens > 0 })"),
                      "the card should stay hidden when every day is zero")
        XCTAssertTrue(source.contains("HistoryModelBreakdownCard(shares: model.historyUsage.modelBreakdown"))
    }

    private static func event(at date: Date, tokens: Int, model: String) -> UsageEvent {
        UsageEvent(
            provider: .claude,
            model: model,
            timestamp: date,
            inputTokens: tokens,
            outputTokens: 0,
            requestCount: 1,
            estimatedCostUSD: Decimal(string: "0.01"),
            source: "claude-statusline",
            dataSource: .officialStatusline,
            isEstimated: false,
            isExperimental: false
        )
    }

    private static func projectRootURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func viewModelSource() throws -> String {
        try String(contentsOf: projectRootURL().appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))
    }

    private static func historyScreenSource() throws -> String {
        try String(contentsOf: projectRootURL().appendingPathComponent("Sources/TokenApp/Views/HistoryScreen.swift"))
    }
}

final class NewProviderFixtureScenarioTests: XCTestCase {
    func testFixtureScenariosCoverOpenCodeAndKiro() throws {
        let source = try Self.viewModelSource()

        XCTAssertTrue(source.contains("case opencodeLocalSessions"))
        XCTAssertTrue(source.contains("case kiroCreditMetered"))
        XCTAssertTrue(source.contains("case .opencodeLocalSessions:"))
        XCTAssertTrue(source.contains("case .kiroCreditMetered:"))
    }

    func testKiroFixtureDoesNotFabricateTokenCounts() throws {
        let source = try Self.viewModelSource()
        let marker = "case .kiroCreditMetered:"
        let start = try XCTUnwrap(source.range(of: marker))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "case .runtimeRecoveryRequired:"))
        let block = String(tail[..<end.lowerBound])

        XCTAssertTrue(block.contains("creditsUsed: decimal(\"56.84\")"))
        XCTAssertTrue(block.contains("input: 0, output: 0, cacheRead: 0"),
                      "Kiro fixture events must stay token-free to match the adapter contract")
        XCTAssertFalse(block.contains("todayTokens:"),
                       "a credit-metered fixture must not claim token totals")
    }

    func testLocalSessionObservationsUseLocalDerivedAuthorityNotBridgeStability() throws {
        // `.compatibilityBridge` stability made the app classify these providers as BRIDGE mode, which
        // the DEBUG fixture assertion caught. They read each provider's own store directly, so the
        // honest classification is local-derived.
        let now = Date()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.opencode, isEnabled: true)
        _ = settings.setProviderEnabled(.kiro, isEnabled: true)

        var kiro = ProviderSnapshot(
            provider: .kiro,
            dataSource: .localLog,
            contextWindowUsedPercent: 33,
            creditsUsed: Decimal(string: "12.5")
        )
        kiro.updatedAt = now

        var opencode = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        opencode.updatedAt = now
        opencode.todayTokens = 1_600

        let observations = CapacityObservationFactory.observations(from: kiro, settings: settings, observedAt: now)
            + CapacityObservationFactory.observations(from: opencode, settings: settings, observedAt: now)

        XCTAssertFalse(observations.isEmpty)
        XCTAssertTrue(observations.allSatisfy { $0.authority == .localDerived },
                      "local session reads must be local-derived, not provider-reported")
        XCTAssertFalse(observations.contains { $0.stability == .compatibilityBridge },
                       "these providers are not compatibility bridges; that stability forces BRIDGE mode")
        XCTAssertTrue(observations.allSatisfy { $0.comparability == .incomparable })
    }

    func testBothNewScenariosReportLocalActivityMode() throws {
        let source = try Self.viewModelSource()

        XCTAssertTrue(
            source.contains("case .codexLocalOnly, .alertsUnsupportedCodexLegacy, .opencodeLocalSessions, .kiroCreditMetered:"),
            "local session sources must map to the local data mode, never live or bridge"
        )
    }

    func testOpenCodeFixtureSpreadsEventsSoTrendAndModelCardsRender() throws {
        let source = try Self.viewModelSource()
        let marker = "case .opencodeLocalSessions:"
        let start = try XCTUnwrap(source.range(of: marker))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "case .kiroCreditMetered:"))
        let block = String(tail[..<end.lowerBound])

        // More than one distinct model and more than one day, otherwise both new cards render empty.
        XCTAssertTrue(block.contains("anthropic/claude-sonnet"))
        XCTAssertTrue(block.contains("opencode/hy3-free"))
        XCTAssertTrue(block.contains("minutesBeforeNow: 1_500"))
        XCTAssertTrue(block.contains("minutesBeforeNow: 3_000"))
    }

    private static func projectRootURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func viewModelSource() throws -> String {
        try String(contentsOf: projectRootURL().appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))
    }
}

final class AllProviderSurfaceParityTests: XCTestCase {
    /// Every provider must survive aggregation, export, and menu-bar rendering. opencode/Kiro were
    /// wired provider-by-provider, so this guards the whole set instead of the two new cases.
    func testEveryProviderSurvivesAggregationAndExport() throws {
        let now = Date()
        let snapshots = Provider.allCases.enumerated().map { index, provider -> ProviderSnapshot in
            var snapshot = ProviderSnapshot(provider: provider, dataSource: .localLog)
            snapshot.updatedAt = now
            snapshot.events = [UsageEvent(
                provider: provider,
                model: "\(provider.rawValue)/model",
                timestamp: now.addingTimeInterval(-Double(index) * 60),
                inputTokens: 100 * (index + 1),
                outputTokens: 10,
                requestCount: 1,
                estimatedCostUSD: Decimal(string: "0.001"),
                source: "parity-test",
                dataSource: .localLog,
                isEstimated: false,
                isExperimental: false
            )]
            return snapshot
        }

        let usage = AggregationService().aggregate(snapshots: snapshots, period: .today)
        XCTAssertEqual(usage.providerShare.count, Provider.allCases.count)
        XCTAssertEqual(usage.modelBreakdown.count, Provider.allCases.count)

        let exporter = UsageExportService()
        let json = try exporter.makeJSONData(usage: usage, snapshots: snapshots, dataMode: "local")
        let raw = try XCTUnwrap(String(data: json, encoding: .utf8))
        let csv = exporter.makeCSVString(usage: usage)
        for provider in Provider.allCases {
            XCTAssertTrue(raw.contains(provider.rawValue), "\(provider.rawValue) missing from JSON export")
            XCTAssertTrue(csv.contains(provider.rawValue), "\(provider.rawValue) missing from CSV export")
        }
        XCTAssertFalse(raw.contains("/Users/"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("access_token"))
    }

    func testMenuBarRendersAMeasuredValueForEveryLocalProvider() {
        let now = Date()
        var settings = AppSettings()
        for provider in Provider.allCases {
            _ = settings.setProviderEnabled(provider, isEnabled: true)
        }
        settings.menuBarDisplayStyle = .providerMetrics
        settings.menuBarMetricProviders = Set(Provider.allCases)

        let snapshots = Provider.allCases.map { provider -> ProviderSnapshot in
            var snapshot = ProviderSnapshot(
                provider: provider,
                confidence: .high,
                dataSource: .localLog,
                creditsUsed: provider == .kiro ? Decimal(string: "56.84") : nil
            )
            snapshot.updatedAt = now
            snapshot.todayTokens = provider == .kiro ? 0 : 1_600
            snapshot.events = [UsageEvent(
                provider: provider, model: "m", timestamp: now,
                inputTokens: snapshot.todayTokens, outputTokens: 0, requestCount: 1,
                source: "parity-test", dataSource: .localLog, isEstimated: false, isExperimental: false
            )]
            return snapshot
        }

        let segments = MenuBarStatusService().providerMetricsSegments(snapshots: snapshots, settings: settings, now: now)
        XCTAssertEqual(segments.count, Provider.allCases.count)

        // xAI intentionally requires explicit experimental setup, so it is the only allowed placeholder.
        let placeholders = segments.filter { $0.displayValue == "\u{2014}" }.compactMap(\.provider)
        XCTAssertEqual(placeholders, [.xai], "only xAI may show a placeholder: \(placeholders)")
        XCTAssertTrue(segments.contains { $0.provider == .kiro && $0.displayValue.hasSuffix("cr") })
        XCTAssertTrue(segments.contains { $0.provider == .opencode && $0.displayValue.hasSuffix("tok") })
        XCTAssertFalse(segments.contains { ($0.provider == .opencode || $0.provider == .kiro) && $0.displayValue.contains("%") })
    }
}

private struct StubKiroTokenLoader: KiroBearerTokenLoading {
    let credential: KiroBearerCredential?
    func loadBearerCredential() -> KiroBearerCredential? { credential }
}

private final class SpyKiroTokenLoader: KiroBearerTokenLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var loadedValue = false
    var loaded: Bool { lock.lock(); defer { lock.unlock() }; return loadedValue }
    func loadBearerCredential() -> KiroBearerCredential? {
        lock.lock(); loadedValue = true; lock.unlock()
        return KiroBearerCredential(accessToken: "token", profileArn: "arn", expiresAt: Date().addingTimeInterval(3_600))
    }
}

private struct StubKiroTransport: KiroUsageLimitsTransporting {
    let body: String
    func fetchUsageLimits(credential: KiroBearerCredential) async -> Result<Data, KiroUsageUnavailableReason> {
        .success(Data(body.utf8))
    }
}

final class KiroUsageLimitsTests: XCTestCase {
    /// Reading a stored credential is the one exception to TokenPilot's no-credential rule, so it
    /// must stay gated: without consent nothing reads the token store and nothing hits the network.
    func testConsentGateBlocksTheCredentialReadEntirely() async {
        let spy = SpyKiroTokenLoader()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.kiro, isEnabled: true)
        settings.kiro = KiroSettings(usageLimitsConsentVersion: nil)

        let result = await KiroUsageLimitsObserver(
            makeTokenLoader: { spy },
            makeTransport: { StubKiroTransport(body: "{}") }
        ).observe(settings: settings)

        XCTAssertFalse(spy.loaded, "no consent must mean no credential read at all")
        guard case .failure(let reason) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(reason, .consentMissing)
    }

    func testOnlyTheCurrentConsentVersionIsHonoured() {
        XCTAssertTrue(KiroSettings(usageLimitsConsentVersion: 1).usageLimitsEnabled)
        XCTAssertFalse(KiroSettings(usageLimitsConsentVersion: 2).usageLimitsEnabled,
                       "an unknown consent version must not inherit consent")
        XCTAssertFalse(KiroSettings(usageLimitsConsentVersion: nil).usageLimitsEnabled)
        XCTAssertFalse(AppSettings().kiro.usageLimitsEnabled, "default must be off")
    }

    func testExpiredTokenReportsAnActionableReason() async {
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.kiro, isEnabled: true)
        settings.kiro = KiroSettings(usageLimitsConsentVersion: 1)
        let expired = KiroBearerCredential(accessToken: "t", expiresAt: Date().addingTimeInterval(-60))

        let result = await KiroUsageLimitsObserver(
            makeTokenLoader: { StubKiroTokenLoader(credential: expired) },
            makeTransport: { StubKiroTransport(body: "{}") }
        ).observe(settings: settings)

        guard case .failure(let reason) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(reason, .tokenExpired, "a lapsed token must not be reported as a generic auth failure")
    }

    /// The shape actually returned by the live service: camelCase, an empty `limits` array, and the
    /// real numbers under `usageBreakdownList`. Captured from a real response so a future parser
    /// change cannot silently stop reading production data.
    func testParsesTheLiveServiceResponseShape() throws {
        let live = """
        {"daysUntilReset":0,"limits":[],"nextDateReset":1.7855424E9,
         "overageConfiguration":{"overageStatus":"DISABLED"},
         "subscriptionInfo":{"subscriptionTitle":"KIRO PRO MAX","type":"Q_DEVELOPER_STANDALONE_PRO_MAX"},
         "usageBreakdownList":[{"currency":"USD","currentUsage":2834,"currentUsageWithPrecision":2834.91,
           "displayName":"Credit","nextDateReset":1.7855424E9,"overageCap":10000,
           "resourceType":"CREDIT","unit":"INVOCATIONS","usageLimit":5000,"usageLimitWithPrecision":5000.0}],
         "userInfo":{"userId":"redacted"}}
        """
        let parsed = try XCTUnwrap(
            KiroUsageLimitsObserver.parse(try XCTUnwrap(live.data(using: .utf8)), now: Date())
        )

        XCTAssertEqual(parsed.usedPercent, 57, "2834.91 of 5000 is 57%")
        XCTAssertNotNil(parsed.resetAt, "nextDateReset is an epoch value and must parse")
    }

    func testEmptyLimitsArrayDoesNotMaskTheBreakdownNumbers() throws {
        let body = #"{"limits":[],"usageBreakdownList":[{"currentUsage":100,"usageLimit":400}]}"#
        let parsed = try XCTUnwrap(
            KiroUsageLimitsObserver.parse(try XCTUnwrap(body.data(using: .utf8)), now: Date())
        )
        XCTAssertEqual(parsed.usedPercent, 25)
    }

    func testParsesEveryDocumentedUsageLimitsShape() throws {
        let now = Date()
        let cases: [(String, Int?)] = [
            (#"{"limits":[{"percent_used":37}],"days_until_reset":7}"#, 37),
            (#"{"usage_breakdown_list":[{"current_usage":150,"usage_limit":600}]}"#, 25),
            (#"{"current_usage":800,"total_usage_limit":1000}"#, 80),
            (#"{"limits":[{"percent_used":0,"current_usage":0,"total_usage_limit":500}]}"#, 0),
            (#"{"current_usage":10,"total_usage_limit":0}"#, nil),
            (#"{"user_info":{"id":"x"},"overage_configuration":{}}"#, nil)
        ]

        for (body, expected) in cases {
            let parsed = KiroUsageLimitsObserver.parse(try XCTUnwrap(body.data(using: .utf8)), now: now)
            XCTAssertEqual(parsed?.usedPercent, expected, "shape: \(body)")
        }
    }

    /// A `percent_used`/`percentUsed` reported as a fraction (0..1) must be treated as a percentage
    /// rather than collapsing to 0%, matching how the codex session parser interprets fractions.
    func testParsesPercentUsedAsFractionWithoutCollapsingToZero() throws {
        let now = Date()

        let snake = try XCTUnwrap(#"{"limits":[{"percent_used":0.5}]}"#.data(using: .utf8))
        XCTAssertEqual(KiroUsageLimitsObserver.parse(snake, now: now)?.usedPercent, 50)

        let camel = try XCTUnwrap(#"{"limits":[{"percentUsed":0.37}]}"#.data(using: .utf8))
        XCTAssertEqual(KiroUsageLimitsObserver.parse(camel, now: now)?.usedPercent, 37)

        // Integer percentages stay untouched.
        let integer = try XCTUnwrap(#"{"limits":[{"percent_used":0}]}"#.data(using: .utf8))
        XCTAssertEqual(KiroUsageLimitsObserver.parse(integer, now: now)?.usedPercent, 0)
    }

    func testCredentialExtractionIgnoresRefreshTokenAndOtherFields() throws {
        let envelope = #"{"access_token":"AT","refresh_token":"RT","expires_at":"2030-01-01T00:00:00Z","provider":"google","profile_arn":"arn:aws:codewhisperer:us-east-1:1:profile/X"}"#
        let credential = try XCTUnwrap(KiroLocalBearerTokenLoader.extractCredential(from: envelope))

        XCTAssertEqual(credential.accessToken, "AT")
        XCTAssertEqual(credential.profileArn, "arn:aws:codewhisperer:us-east-1:1:profile/X")
        XCTAssertNotNil(credential.expiresAt)
        XCTAssertFalse("\(credential)".contains("RT"), "the refresh token must never reach a value TokenPilot holds")
    }

    func testUsageLimitsBecomeComparableProviderQuota() {
        let now = Date()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.kiro, isEnabled: true)
        settings.kiro = KiroSettings(usageLimitsConsentVersion: 1)

        var snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [.init(credits: Decimal(string: "12.5")!, timestamp: now, toolCalls: 2)],
            contextPercent: (percent: 30, timestamp: now),
            staleThreshold: 900,
            now: now
        )
        snapshot = KiroLocalSessionAdapter.applyingUsageLimits(
            KiroUsageLimits(usedPercent: 63, resetAt: now.addingTimeInterval(86_400), observedAt: now),
            to: snapshot
        )

        XCTAssertEqual(snapshot.weekly?.usedPercent, 63)
        XCTAssertEqual(snapshot.primaryUsedPercent.map { 100 - $0 }, 37)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.todayTokens, 0, "quota must not fabricate token counts")

        let observations = CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now)
        let quota = observations.filter { $0.seriesID.providerWindowID == "usage-limits" }
        XCTAssertEqual(quota.count, 1)
        XCTAssertTrue(quota.allSatisfy { $0.comparability == .comparable })
        XCTAssertTrue(quota.map { CapacityAssessmentService().assess($0, now: now) }
            .allSatisfy { $0.alertEligibility == .percent })

        let others = observations.filter { $0.seriesID.providerWindowID != "usage-limits" }
        XCTAssertTrue(others.allSatisfy { $0.comparability == .incomparable },
                      "credits and context stay local activity")
    }

    func testMenuBarShowsRemainingPercentOnceQuotaIsKnown() {
        let now = Date()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.kiro, isEnabled: true)
        settings.menuBarDisplayStyle = .providerMetrics
        settings.menuBarMetricProviders = [.kiro]

        var snapshot = KiroLocalSessionAdapter.makeSnapshot(
            creditEntries: [.init(credits: Decimal(string: "12.5")!, timestamp: now, toolCalls: 1)],
            contextPercent: nil,
            staleThreshold: 900,
            now: now
        )
        snapshot = KiroLocalSessionAdapter.applyingUsageLimits(
            KiroUsageLimits(usedPercent: 63, resetAt: nil, observedAt: now),
            to: snapshot
        )

        let segments = MenuBarStatusService().providerMetricsSegments(snapshots: [snapshot], settings: settings, now: now)
        XCTAssertTrue(segments.contains { $0.provider == .kiro && $0.displayValue.contains("37%") },
                      "quota must outrank the credit display: \(segments.map(\.displayValue))")
    }
}

private final class SpyOpenCodeCredentialLoader: OpenCodeCredentialLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var loadedValue = false
    var loaded: Bool { lock.lock(); defer { lock.unlock() }; return loadedValue }
    func loadCredential() -> OpenCodeCredential? {
        lock.lock(); loadedValue = true; lock.unlock()
        return OpenCodeCredential(accessToken: "token")
    }
}

private struct StubOpenCodeProbe: OpenCodeRateLimitProbing {
    let headers: [String: String]
    func probeRateLimit(credential: OpenCodeCredential) async -> Result<[String: String], OpenCodeRateLimitUnavailableReason> {
        .success(headers)
    }
}

final class OpenCodeRateLimitTests: XCTestCase {
    /// opencode exposes quota only through response headers, so the probe is opt-in: without consent
    /// nothing reads the token store and no request is sent.
    func testConsentGateBlocksTheCredentialReadAndProbe() async {
        let spy = SpyOpenCodeCredentialLoader()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.opencode, isEnabled: true)
        settings.openCode = OpenCodeSettings(rateLimitConsentVersion: nil)

        let result = await OpenCodeRateLimitObserver(
            makeCredentialLoader: { spy },
            makeProbe: { StubOpenCodeProbe(headers: [:]) }
        ).observe(settings: settings)

        XCTAssertFalse(spy.loaded, "no consent must mean no credential read and no probe request")
        guard case .failure(let reason) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(reason, .consentMissing)
    }

    func testOnlyTheCurrentConsentVersionIsHonoured() {
        XCTAssertTrue(OpenCodeSettings(rateLimitConsentVersion: 1).rateLimitProbeEnabled)
        XCTAssertFalse(OpenCodeSettings(rateLimitConsentVersion: 2).rateLimitProbeEnabled)
        XCTAssertFalse(AppSettings().openCode.rateLimitProbeEnabled, "default must be off")
    }

    func testParsesStandardAndPrefixedRateLimitHeaders() {
        let now = Date()

        XCTAssertEqual(
            OpenCodeRateLimitObserver.parse(headers: ["ratelimit-limit": "1000", "ratelimit-remaining": "250"], now: now)?.usedPercent,
            75
        )
        XCTAssertEqual(
            OpenCodeRateLimitObserver.parse(headers: ["x-ratelimit-limit": "10", "x-ratelimit-remaining": "3"], now: now)?.usedPercent,
            70
        )
        XCTAssertNil(OpenCodeRateLimitObserver.parse(headers: [:], now: now))
        XCTAssertNil(
            OpenCodeRateLimitObserver.parse(headers: ["ratelimit-limit": "0", "ratelimit-remaining": "0"], now: now),
            "a zero limit cannot yield a percentage"
        )
    }

    func testResetAcceptsBothSecondsRemainingAndUnixTimestamps() throws {
        let now = Date()

        let relative = try XCTUnwrap(OpenCodeRateLimitObserver.parse(
            headers: ["ratelimit-limit": "10", "ratelimit-remaining": "5", "ratelimit-reset": "3600"],
            now: now
        ))
        XCTAssertNotNil(relative.resetAt)
        XCTAssertGreaterThan(try XCTUnwrap(relative.resetAt), now)

        let absolute = try XCTUnwrap(OpenCodeRateLimitObserver.parse(
            headers: ["ratelimit-limit": "10", "ratelimit-remaining": "5", "ratelimit-reset": "\(Int(now.timeIntervalSince1970) + 7_200)"],
            now: now
        ))
        XCTAssertNotNil(absolute.resetAt)
    }

    func testExpiredTokenReportsAnActionableReason() async {
        struct ExpiredLoader: OpenCodeCredentialLoading {
            func loadCredential() -> OpenCodeCredential? {
                OpenCodeCredential(accessToken: "t", expiresAt: Date().addingTimeInterval(-60))
            }
        }
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.opencode, isEnabled: true)
        settings.openCode = OpenCodeSettings(rateLimitConsentVersion: 1)

        let result = await OpenCodeRateLimitObserver(
            makeCredentialLoader: { ExpiredLoader() },
            makeProbe: { StubOpenCodeProbe(headers: [:]) }
        ).observe(settings: settings)

        guard case .failure(let reason) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(reason, .tokenExpired)
    }

    func testRateLimitBecomesComparableProviderQuota() {
        let now = Date()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.opencode, isEnabled: true)
        settings.openCode = OpenCodeSettings(rateLimitConsentVersion: 1)

        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.updatedAt = now
        snapshot.todayTokens = 5_000
        snapshot = OpenCodeSessionAdapter.applyingRateLimit(
            OpenCodeRateLimit(usedPercent: 75, resetAt: now.addingTimeInterval(3_600), observedAt: now),
            to: snapshot
        )

        XCTAssertEqual(snapshot.weekly?.usedPercent, 75)
        XCTAssertEqual(snapshot.primaryUsedPercent.map { 100 - $0 }, 25)
        XCTAssertEqual(snapshot.confidence, .high)

        let observations = CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now)
        let quota = observations.filter { $0.seriesID.providerWindowID == "rate-limit" }
        XCTAssertEqual(quota.count, 1)
        XCTAssertTrue(quota.allSatisfy { $0.comparability == .comparable })
        XCTAssertTrue(quota.map { CapacityAssessmentService().assess($0, now: now) }
            .allSatisfy { $0.alertEligibility == .percent })
    }

    func testMenuBarShowsRemainingPercentOnceQuotaIsKnown() {
        let now = Date()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.opencode, isEnabled: true)
        settings.menuBarDisplayStyle = .providerMetrics
        settings.menuBarMetricProviders = [.opencode]

        var snapshot = ProviderSnapshot(provider: .opencode, dataSource: .localLog)
        snapshot.updatedAt = now
        snapshot.todayTokens = 5_000
        snapshot = OpenCodeSessionAdapter.applyingRateLimit(
            OpenCodeRateLimit(usedPercent: 75, resetAt: nil, observedAt: now),
            to: snapshot
        )

        let segments = MenuBarStatusService().providerMetricsSegments(snapshots: [snapshot], settings: settings, now: now)
        XCTAssertTrue(segments.contains { $0.provider == .opencode && $0.displayValue.contains("25%") },
                      "quota must outrank the token display: \(segments.map(\.displayValue))")
    }

    /// Live checks on 2026-07-29 showed opencode Zen has no usage endpoint and sends no rate-limit
    /// headers, so the UI must say the quota is unavailable instead of implying it can be fetched.
    func testSettingsUIStatesQuotaIsNotAvailableYet() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TokenApp/Views/SettingsScreen.swift"))

        XCTAssertTrue(
            source.contains("no rate-limit headers, so remaining quota cannot be read yet"),
            "the UI must state plainly that opencode quota cannot be read today"
        )
        XCTAssertTrue(
            source.contains("spends one authenticated request per refresh and today returns nothing"),
            "the cost of enabling the probe must stay disclosed"
        )
        XCTAssertTrue(source.contains("openCodeRateLimitBinding"))
    }

    func testProbeReturnsNoQuotaRatherThanAFabricatedPercentage() async {
        struct EmptyHeaderProbe: OpenCodeRateLimitProbing {
            func probeRateLimit(credential: OpenCodeCredential) async -> Result<[String: String], OpenCodeRateLimitUnavailableReason> {
                .success(["content-type": "application/json"])
            }
        }
        struct KeyLoader: OpenCodeCredentialLoading {
            func loadCredential() -> OpenCodeCredential? { OpenCodeCredential(accessToken: "sk-test") }
        }
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.opencode, isEnabled: true)
        settings.openCode = OpenCodeSettings(rateLimitConsentVersion: 1)

        let result = await OpenCodeRateLimitObserver(
            makeCredentialLoader: { KeyLoader() },
            makeProbe: { EmptyHeaderProbe() }
        ).observe(settings: settings)

        guard case .failure(let reason) = result else {
            return XCTFail("a response without rate-limit headers must not yield a percentage")
        }
        XCTAssertEqual(reason, .headersMissing)
    }

    func testReadsThePlanAPIKeyAndIgnoresNonAPIEntries() throws {
        // Live shape: opencode Go stores an `api` type key under `opencode-go` in auth.json.
        let apiEntry: [String: Any] = ["opencode-go": ["type": "api", "key": "sk-live-value"]]
        XCTAssertEqual(OpenCodeLocalCredentialLoader.extractAPIKey(from: apiEntry), "sk-live-value")

        let oauthEntry: [String: Any] = ["opencode-go": ["type": "oauth", "refresh": "RT", "access": "AT"]]
        XCTAssertNil(
            OpenCodeLocalCredentialLoader.extractAPIKey(from: oauthEntry),
            "an OAuth entry must never be treated as a plan API key"
        )

        let emptyKey: [String: Any] = ["opencode-go": ["type": "api", "key": "   "]]
        XCTAssertNil(OpenCodeLocalCredentialLoader.extractAPIKey(from: emptyKey))
        XCTAssertNil(OpenCodeLocalCredentialLoader.extractAPIKey(from: ["other": ["type": "api", "key": "x"]]))
    }
}

final class CredentialRedactionTests: XCTestCase {
    /// Found during a security review: the key pattern required an unbroken alphanumeric tail, so
    /// segmented keys such as `sk-live-...` (the shape opencode actually issues) passed through
    /// unredacted.
    func testHyphenatedProviderKeysAreRedacted() {
        for key in ["sk-live-abcdef1234567890ABCDEF",
                    "sk-proj-abcdef1234567890ABCDEF",
                    "api_key=sk-live-abc123def456ghi789",
                    "key=sk-Y7B-abcdefghijklmnop1234"] {
            let redacted = TokenPilotPrivacyRedactor.redact(key)
            XCTAssertTrue(redacted.contains("[REDACTED"), "unredacted key shape: \(key)")
            XCTAssertFalse(redacted.contains("abcdef1234567890"), "key body must not survive")
        }
    }

    func testCloudResourceIdentifiersAndUserIDsAreRedacted() {
        let arn = "arn:aws:codewhisperer:us-east-1:123456789012:profile/SECRET"
        XCTAssertFalse(TokenPilotPrivacyRedactor.redact(arn).contains("123456789012"),
                       "an ARN embeds the account number and must not be surfaced")
        XCTAssertFalse(
            TokenPilotPrivacyRedactor.redact("profile_arn=\(arn)").contains("123456789012")
        )
        XCTAssertFalse(
            TokenPilotPrivacyRedactor.redact("userId=d-9067c98495.54f85488-c0d1").contains("9067c98495"),
            "provider user identifiers are personal data"
        )
    }

    /// Redaction must stay narrow: status copy the UI depends on has to survive untouched.
    func testBenignStatusCopyIsNotOverRedacted() {
        for text in ["Connected",
                     "Local session store · no quota window",
                     "Provider-reported usage limits",
                     "5h usage: 82% resets in 1h 24m"] {
            XCTAssertEqual(TokenPilotPrivacyRedactor.redact(text), text, "over-redacted: \(text)")
        }
    }

    func testCredentialBearingTextStaysRedacted() {
        for text in ["Bearer abc.def.ghi", "access_token=xyz123456789", "refresh_token=abcdef"] {
            XCTAssertTrue(TokenPilotPrivacyRedactor.redact(text).contains("[REDACTED"), text)
        }
    }
}

final class BuildSigningTests: XCTestCase {
    /// ad-hoc signing leaves no Authority and no Team ID, so macOS Keychain cannot keep trusting the
    /// app across builds and re-prompts for every stored secret. build.sh must prefer a real identity.
    func testBuildScriptPrefersARealSigningIdentityOverAdHoc() throws {
        let script = try Self.buildScript()

        XCTAssertTrue(script.contains("TOKENPILOT_SIGN_IDENTITY"),
                      "an explicit identity override must stay available for release runs")
        XCTAssertTrue(script.contains("Developer ID Application"),
                      "Developer ID must be preferred when present")
        XCTAssertTrue(script.contains("Apple Development"),
                      "Apple Development is the local fallback that still fixes the Team ID")

        // Compare the order inside the `for pattern in ...` loop, not prose mentions in comments.
        let loop = try XCTUnwrap(script.range(of: "for pattern in "))
        let loopLine = String(script[loop.lowerBound...].prefix(while: { $0 != "\n" }))
        let devIDIndex = try XCTUnwrap(loopLine.range(of: "Developer ID Application")).lowerBound
        let appleDevIndex = try XCTUnwrap(loopLine.range(of: "Apple Development")).lowerBound
        XCTAssertLessThan(devIDIndex, appleDevIndex, "Developer ID must be tried first: \(loopLine)")
    }

    func testBuildScriptStillFallsBackToAdHocWhenNoIdentityExists() throws {
        let script = try Self.buildScript()

        XCTAssertTrue(script.contains("--sign -"),
                      "CI machines without a signing identity must still produce a runnable bundle")
    }

    func testIdentityLookupToleratesAMissingCertificatePattern() throws {
        let script = try Self.buildScript()
        let lookupStart = try XCTUnwrap(script.range(of: "AVAILABLE_IDENTITIES=")).lowerBound
        let lookupEnd = try XCTUnwrap(script.range(of: "if [ -n \"$SIGN_IDENTITY\" ] && codesign")).lowerBound
        let lookup = String(script[lookupStart..<lookupEnd])

        // grep exits 1 when a pattern is absent, which aborts the script under `set -o pipefail`.
        XCTAssertTrue(lookup.contains("|| true"),
                      "the identity search must absorb grep's no-match exit so the loop can continue")
    }

    private static func buildScript() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("build.sh"))
    }
}

final class ClaudeStatuslineBridgeTests: XCTestCase {
    /// Claude only reports 5-hour/weekly limits through a statusLine command, so without this bridge
    /// the app can show token activity but never a remaining percentage.
    func testStatuslineFileYieldsComparableQuotaWindows() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenpilot-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("claude-statusline.json")
        let payload = """
        {"model":{"id":"claude-sonnet-4","display_name":"Claude Sonnet 4"},
         "context_window":{"used_percentage":37.5,"current_usage":{"input_tokens":12000,"output_tokens":800,"cache_read_input_tokens":4000,"cache_creation_input_tokens":100}},
         "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":"2026-07-29T15:00:00Z"},
                        "seven_day":{"used_percentage":18,"resets_at":"2026-08-03T00:00:00Z"}},
         "cost":{"total_cost_usd":1.2345}}
        """
        try XCTUnwrap(payload.data(using: .utf8)).write(to: file)

        var settings = AppSettings()
        _ = settings.setProviderEnabled(.claude, isEnabled: true)
        let snapshot = await ClaudeStatuslineAdapter(fileURL: file).snapshot(settings: settings)

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 18)
        XCTAssertEqual(snapshot.primaryUsedPercent.map { 100 - $0 }, 58, "remaining percent must be derivable")
        XCTAssertEqual(snapshot.dataSource, .officialStatusline)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertNotNil(snapshot.fiveHour?.resetAt)

        // Unlike the local-activity providers, Claude statusline data is real provider quota.
        let observations = CapacityObservationFactory.observations(
            from: snapshot,
            settings: settings,
            observedAt: snapshot.updatedAt
        )
        XCTAssertFalse(observations.isEmpty)
        XCTAssertTrue(observations.allSatisfy { $0.comparability == .comparable })
        let assessments = observations.map { CapacityAssessmentService().assess($0, now: snapshot.updatedAt) }
        XCTAssertTrue(assessments.allSatisfy { $0.alertEligibility == .percent })
    }

    func testMissingRateLimitsStillDoesNotFabricateAPercentage() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenpilot-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("claude-statusline.json")
        let payload = """
        {"model":{"display_name":"Claude"},
         "context_window":{"current_usage":{"input_tokens":500,"output_tokens":100}}}
        """
        try XCTUnwrap(payload.data(using: .utf8)).write(to: file)

        var settings = AppSettings()
        _ = settings.setProviderEnabled(.claude, isEnabled: true)
        let snapshot = await ClaudeStatuslineAdapter(fileURL: file).snapshot(settings: settings)

        XCTAssertNil(snapshot.fiveHour, "no rate_limits means no window may be invented")
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.todayTokens, 600, "token activity is still reported")
    }

    func testInstallerSnippetChainsRatherThanReplacesAnExistingStatusLine() throws {
        let source = try Self.settingsSource()
        let start = try XCTUnwrap(source.range(of: "private var claudeStatuslineSnippet: String {"))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "private var geminiSettingsSnippet"))
        let snippet = String(tail[..<end.lowerBound])

        XCTAssertTrue(snippet.contains("TOKENPILOT_CLAUDE_PREVIOUS_STATUSLINE"),
                      "the wrapper must carry the previous command so an existing prompt keeps working")
        XCTAssertTrue(snippet.contains("claude-statusline.json"))
        XCTAssertTrue(snippet.contains("rate_limits"))
        // Check the fields the writer actually reads, not prose: the payload contains workspace paths
        // and transcript references that must never reach the recorded JSON.
        for forbiddenField in ["\"workspace\"", "current_dir", "transcript", "\"messages\"", "\"prompt\""] {
            XCTAssertFalse(
                snippet.contains(forbiddenField),
                "the writer must not read \(forbiddenField) from the statusLine payload"
            )
        }
    }

    private static func settingsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/TokenApp/Views/SettingsScreen.swift"))
    }
}

final class SettingsProviderCoverageTests: XCTestCase {
    /// The Settings provider picker was a hardcoded five-entry grid, so opencode and Kiro were
    /// enabled internally but had no on/off control and no setup section. Anything provider-scoped in
    /// Settings must be driven by `Provider.allCases` or listed explicitly for every provider.
    func testProviderPickerIsDrivenByAllCases() throws {
        let source = try Self.settingsSource()

        XCTAssertTrue(
            source.contains("ForEach(Provider.allCases) { provider in\n                            providerToggle(provider)"),
            "the provider picker must iterate Provider.allCases"
        )
        for provider in Provider.allCases {
            XCTAssertFalse(
                source.contains("providerToggle(.\(provider.rawValue))"),
                "hardcoded providerToggle(.\(provider.rawValue)) reintroduces provider drift"
            )
        }
    }

    func testEverySetupSectionAndOrderEntryExistsForEveryProvider() throws {
        let source = try Self.settingsSource()

        for provider in Provider.allCases {
            XCTAssertTrue(
                source.contains("providerSetupDisclosure(provider: .\(provider.rawValue),"),
                "\(provider.rawValue) needs a Settings setup section"
            )
        }

        let order = try XCTUnwrap(Self.setupOrderEntries(in: source))
        XCTAssertEqual(
            Set(order),
            Set(Provider.allCases.map(\.rawValue)),
            "providerSetupOrder must cover every provider so attention states can surface"
        )
    }

    func testSetupGuideCoversEveryProviderThatHasASetupSection() throws {
        let source = try Self.settingsSource()

        // The Setup Guide is a hand-written GuideCard list, so a new provider is easy to forget.
        for provider in Provider.allCases {
            XCTAssertTrue(
                source.contains("model.sourceStatusText(.\(provider.rawValue))"),
                "\(provider.rawValue) is missing from the Setup Guide"
            )
        }
    }

    func testNewProvidersAreSelectableInTheMenuBarPicker() throws {
        let source = try Self.settingsSource()
        let occurrences = source.components(separatedBy: "ForEach(Provider.allCases)").count - 1

        XCTAssertGreaterThanOrEqual(occurrences, 4,
            "provider chips, menu-bar toggles, primary picker, and secondary picker all iterate every provider")
    }

    private static func setupOrderEntries(in source: String) -> [String]? {
        guard let range = source.range(of: "private var providerSetupOrder: [Provider] {") else { return nil }
        let tail = source[range.upperBound...]
        guard let close = tail.range(of: "]") else { return nil }
        return String(tail[..<close.lowerBound])
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n[.")) }
            .filter { !$0.isEmpty }
    }

    private static func settingsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/TokenApp/Views/SettingsScreen.swift"))
    }
}

final class NewProviderSettingsTests: XCTestCase {
    func testLegacySettingsMigrateOpenCodeAndKiroOn() throws {
        let legacy = """
        {"claudeEnabled":true,"codexEnabled":true,"geminiEnabled":true,"deepseekEnabled":true,
         "xaiEnabled":false,"monitoredProviders":{"enabledProviders":["claude","codex","gemini","deepseek"]}}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: try XCTUnwrap(legacy.data(using: .utf8)))

        XCTAssertTrue(settings.isProviderEnabled(.opencode))
        XCTAssertTrue(settings.isProviderEnabled(.kiro))
        XCTAssertTrue(settings.isProviderEnabled(.claude), "existing providers must stay enabled")
        XCTAssertFalse(settings.isProviderEnabled(.xai), "xAI must still require explicit opt-in")
    }

    func testMigrationReachesUsersWhoHadDisabledAClassicProvider() throws {
        // The first version of this migration required monitoredProviders to be a superset of
        // claude/codex/gemini, copied from the DeepSeek block. Anyone who had turned one of those off
        // never received opencode/Kiro, which is most real installs.
        let shapes = [
            ("gemini disabled", """
            {"claudeEnabled":true,"codexEnabled":true,"geminiEnabled":false,"deepseekEnabled":true,
             "monitoredProviders":{"enabledProviders":["claude","codex","deepseek"]}}
            """),
            ("claude only", """
            {"claudeEnabled":true,"codexEnabled":false,"geminiEnabled":false,"deepseekEnabled":false,
             "monitoredProviders":{"enabledProviders":["claude"]}}
            """),
            ("codex only", """
            {"claudeEnabled":false,"codexEnabled":true,"geminiEnabled":false,"deepseekEnabled":false,
             "monitoredProviders":{"enabledProviders":["codex"]}}
            """)
        ]

        for (label, json) in shapes {
            let settings = try JSONDecoder().decode(AppSettings.self, from: try XCTUnwrap(json.data(using: .utf8)))
            XCTAssertTrue(settings.isProviderEnabled(.opencode), "\(label) should receive opencode")
            XCTAssertTrue(settings.isProviderEnabled(.kiro), "\(label) should receive Kiro")
        }
    }

    func testExplicitOptOutIsNotOverriddenByMigration() throws {
        let json = """
        {"claudeEnabled":true,"codexEnabled":true,"geminiEnabled":true,"deepseekEnabled":true,
         "opencodeEnabled":false,"kiroEnabled":false,
         "monitoredProviders":{"enabledProviders":["claude","codex","gemini","deepseek"]}}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertFalse(settings.isProviderEnabled(.opencode), "a stored opt-out must win over default-on migration")
        XCTAssertFalse(settings.isProviderEnabled(.kiro))
    }

    func testFreshInstallEnablesLocalSessionProvidersButNotXAI() {
        let fresh = AppSettings()

        XCTAssertTrue(fresh.isProviderEnabled(.opencode))
        XCTAssertTrue(fresh.isProviderEnabled(.kiro))
        XCTAssertFalse(fresh.isProviderEnabled(.xai), "xAI must stay opt-in")
    }

    func testNormalizationDoesNotDropNewProviders() {
        var settings = AppSettings()
        settings.normalizeProviderEnablement()

        XCTAssertTrue(settings.isProviderEnabled(.opencode))
        XCTAssertTrue(settings.isProviderEnabled(.kiro))
    }

    func testNewProvidersCanBeDisabledIndividually() {
        var settings = AppSettings()
        XCTAssertTrue(settings.setProviderEnabled(.opencode, isEnabled: false))
        XCTAssertFalse(settings.isProviderEnabled(.opencode))
        XCTAssertTrue(settings.isProviderEnabled(.kiro))
    }

    func testDefaultPathResolutionCoversDocumentedLocations() {
        let home = URL(fileURLWithPath: "/tmp/tokenpilot-home", isDirectory: true)
        let resolver = DefaultPathResolver(environment: [:], currentHomeDirectory: home, additionalHomeDirectories: [])

        let openCodeKinds = Set(resolver.resolveDefaultPaths(for: .opencode).map(\.kind))
        XCTAssertTrue(openCodeKinds.isSuperset(of: ["database", "database_next", "legacy_messages"]))
        let kiroKinds = Set(resolver.resolveDefaultPaths(for: .kiro).map(\.kind))
        XCTAssertTrue(kiroKinds.isSuperset(of: ["cli_sessions", "ide_sessions"]))
    }

    func testOpenCodeHonorsXDGDataHome() {
        let home = URL(fileURLWithPath: "/tmp/tokenpilot-home", isDirectory: true)
        let resolver = DefaultPathResolver(
            environment: ["XDG_DATA_HOME": "/tmp/xdg-data"],
            currentHomeDirectory: home,
            additionalHomeDirectories: []
        )

        let paths = resolver.resolveDefaultPaths(for: .opencode).map(\.path)
        XCTAssertTrue(paths.contains { $0.hasPrefix("/tmp/xdg-data/opencode/") }, "\(paths)")
    }
}
