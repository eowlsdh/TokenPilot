import XCTest
@testable import TokenCore

final class CommandCodeTranscriptParsingTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    func testParsesSnakeCaseUsageAndCost() throws {
        let jsonl = """
        {"type":"header","session_id":"s1","cwd":"/Users/someone/dev/myapp","timestamp":"2026-08-19T10:00:00Z"}
        {"type":"assistant","timestamp":"2026-08-19T10:01:00Z","model":"claude-opus-5","usage":{"input_tokens":1200,"output_tokens":340,"cache_read_input_tokens":800,"cache_creation_input_tokens":120,"reasoning_tokens":60},"cost_usd":0.0421}
        """
        let events = CommandCodeLocalSessionAdapter.parseTranscript(jsonl: jsonl, projectLabel: "myapp")
        XCTAssertEqual(events.count, 1, "the header line carries no usage and must not become an event")

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.provider, .commandcode)
        XCTAssertEqual(event.model, "claude-opus-5")
        XCTAssertEqual(event.inputTokens, 1200)
        XCTAssertEqual(event.outputTokens, 340)
        XCTAssertEqual(event.cacheReadTokens, 800)
        XCTAssertEqual(event.cacheCreationTokens, 120)
        XCTAssertEqual(event.reasoningTokens, 60)
        XCTAssertEqual(event.totalTokens, 2520)
        XCTAssertEqual(event.estimatedCostUSD, Decimal(string: "0.0421"))
        XCTAssertEqual(event.requestCount, 1)
        XCTAssertEqual(event.source, "commandcode-session")
        XCTAssertEqual(event.dataSource, .localLog)
        XCTAssertFalse(event.isEstimated)
        XCTAssertFalse(event.isExperimental)
        XCTAssertEqual(event.projectLabel, "myapp")
        XCTAssertEqual(event.timestamp, iso.date(from: "2026-08-19T10:01:00Z"))
    }

    /// The transcript schema is not published, so the common spellings all have to land.
    func testParsesCamelCaseAndNestedCostShapes() throws {
        let jsonl = """
        {"role":"assistant","createdAt":"2026-08-19T11:00:00Z","model":{"id":"gemini-3.7-flash"},"tokenUsage":{"inputTokens":10,"outputTokens":20},"cost":{"total_usd":0.5}}
        {"role":"assistant","ts":"2026-08-19T11:05:00Z","model_id":"minimax-m3","usage":{"prompt_tokens":5,"completion_tokens":7},"cost":0.25}
        """
        let events = CommandCodeLocalSessionAdapter.parseTranscript(jsonl: jsonl, projectLabel: nil)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].model, "gemini-3.7-flash")
        XCTAssertEqual(events[0].totalTokens, 30)
        XCTAssertEqual(events[0].estimatedCostUSD, Decimal(string: "0.5"))
        XCTAssertEqual(events[1].model, "minimax-m3")
        XCTAssertEqual(events[1].totalTokens, 12)
        XCTAssertEqual(events[1].estimatedCostUSD, Decimal(string: "0.25"))
    }

    func testBookkeepingEntriesAreSkipped() {
        let jsonl = """
        {"type":"model_change","timestamp":"2026-08-19T10:02:00Z","model":"claude-opus-5"}
        {"type":"user","timestamp":"2026-08-19T10:03:00Z","text":"do the thing"}
        {"type":"compaction","timestamp":"2026-08-19T10:04:00Z","summary":"...","usage":{"input_tokens":0,"output_tokens":0}}
        """
        XCTAssertTrue(CommandCodeLocalSessionAdapter.parseTranscript(jsonl: jsonl, projectLabel: nil).isEmpty)
    }

    func testEntryWithoutTimestampIsSkipped() {
        let jsonl = #"{"role":"assistant","usage":{"input_tokens":10,"output_tokens":10},"cost_usd":0.01}"#
        XCTAssertTrue(CommandCodeLocalSessionAdapter.parseTranscript(jsonl: jsonl, projectLabel: nil).isEmpty)
    }

    func testCostOnlyEntryStillCounts() throws {
        let jsonl = #"{"role":"assistant","timestamp":"2026-08-19T12:00:00Z","cost_usd":0.02}"#
        let events = CommandCodeLocalSessionAdapter.parseTranscript(jsonl: jsonl, projectLabel: nil)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.totalTokens, 0)
        XCTAssertEqual(event.estimatedCostUSD, Decimal(string: "0.02"))
    }

    func testMalformedLinesDoNotAbortTheFile() {
        let jsonl = """
        not json at all
        {"role":"assistant","timestamp":"2026-08-19T12:00:00Z","usage":{"input_tokens":4,"output_tokens":6}}
        {"broken":
        """
        XCTAssertEqual(CommandCodeLocalSessionAdapter.parseTranscript(jsonl: jsonl, projectLabel: nil).count, 1)
    }

    func testTranscriptTextIsNeverCarriedIntoEvents() throws {
        let jsonl = #"{"role":"assistant","timestamp":"2026-08-19T12:00:00Z","text":"SECRET PROMPT BODY","content":[{"type":"text","text":"SECRET REPLY"}],"usage":{"input_tokens":4,"output_tokens":6},"cwd":"/Users/someone/private"}"#
        let events = CommandCodeLocalSessionAdapter.parseTranscript(jsonl: jsonl, projectLabel: "myapp")
        let encoded = try JSONEncoder().encode(events)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.contains("/Users/"))
    }
}

final class CommandCodeProjectLabelTests: XCTestCase {
    /// Slugs encode the working directory; only the folder name may survive.
    func testSlugKeepsOnlyTheTrailingFolderName() {
        XCTAssertEqual(CommandCodeLocalSessionAdapter.projectLabel(fromSlug: "-Users-someone-dev-myapp"), "myapp")
        XCTAssertEqual(CommandCodeLocalSessionAdapter.projectLabel(fromSlug: "Users-someone-work-tokenpilot"), "tokenpilot")
        XCTAssertEqual(CommandCodeLocalSessionAdapter.projectLabel(fromSlug: "myapp"), "myapp")
    }

    func testEmptyOrSeparatorOnlySlugsYieldNoLabel() {
        XCTAssertNil(CommandCodeLocalSessionAdapter.projectLabel(fromSlug: ""))
        XCTAssertNil(CommandCodeLocalSessionAdapter.projectLabel(fromSlug: "---"))
        XCTAssertNil(CommandCodeLocalSessionAdapter.projectLabel(fromSlug: "  "))
    }

    func testLabelIsLengthCapped() throws {
        let slug = "-Users-someone-" + String(repeating: "a", count: 200)
        let label = try XCTUnwrap(CommandCodeLocalSessionAdapter.projectLabel(fromSlug: slug))
        XCTAssertEqual(label.count, 64)
    }

    func testLabelComesFromTheSessionFolderNotTheFile() {
        let url = URL(fileURLWithPath: "/tmp/projects/-Users-someone-dev-myapp/abc123.jsonl")
        XCTAssertEqual(CommandCodeLocalSessionAdapter.projectLabel(forTranscript: url), "myapp")
    }
}

final class CommandCodeFileSelectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commandcode-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testOnlyTranscriptsAreSelected() {
        XCTAssertTrue(CommandCodeLocalSessionAdapter.isTranscript(URL(fileURLWithPath: "/p/abc.jsonl")))
        XCTAssertFalse(CommandCodeLocalSessionAdapter.isTranscript(URL(fileURLWithPath: "/p/abc.prompts.jsonl")))
        XCTAssertFalse(CommandCodeLocalSessionAdapter.isTranscript(URL(fileURLWithPath: "/p/abc.checkpoints.jsonl")))
        XCTAssertFalse(CommandCodeLocalSessionAdapter.isTranscript(URL(fileURLWithPath: "/p/abc.meta.json")))
        XCTAssertFalse(CommandCodeLocalSessionAdapter.isTranscript(URL(fileURLWithPath: "/p/abc.share.json")))
    }

    /// `~/.commandcode` also stores the API key; transcript discovery must never pick it up.
    func testCredentialFilesAreNeverSelected() throws {
        let project = root.appendingPathComponent("-Users-someone-dev-myapp", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("auth.jsonl"))
        try Data("{}".utf8).write(to: project.appendingPathComponent("oauth-session.jsonl"))
        try Data("{}".utf8).write(to: project.appendingPathComponent("token.json"))
        try Data("{}".utf8).write(to: project.appendingPathComponent("session.jsonl"))

        let found = CommandCodeLocalSessionAdapter.transcriptURLs(in: [root], maxFiles: 50)
        XCTAssertEqual(found.map(\.lastPathComponent), ["session.jsonl"])
    }

    func testFileCountIsCapped() throws {
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for index in 0..<12 {
            try Data("{}".utf8).write(to: project.appendingPathComponent("s\(index).jsonl"))
        }
        XCTAssertEqual(CommandCodeLocalSessionAdapter.transcriptURLs(in: [root], maxFiles: 5).count, 5)
    }
}

final class CommandCodeSnapshotTests: XCTestCase {
    private func event(at date: Date, tokens: Int, cost: Decimal?) -> UsageEvent {
        UsageEvent(
            provider: .commandcode,
            model: "claude-opus-5",
            timestamp: date,
            inputTokens: tokens,
            outputTokens: 0,
            estimatedCostUSD: cost,
            source: "commandcode-session",
            dataSource: .localLog,
            projectLabel: "myapp"
        )
    }

    func testTodayTotalsAndBalanceComeFromTodaysEvents() {
        let now = Date()
        let snapshot = CommandCodeLocalSessionAdapter.makeSnapshot(
            from: [
                event(at: now.addingTimeInterval(-60), tokens: 1_000, cost: Decimal(string: "0.30")),
                event(at: now.addingTimeInterval(-120), tokens: 500, cost: Decimal(string: "0.20")),
                event(at: now.addingTimeInterval(-3 * 86_400), tokens: 9_999, cost: Decimal(string: "9.99"))
            ],
            staleThreshold: 900,
            now: now
        )
        XCTAssertEqual(snapshot.todayTokens, 1_500)
        XCTAssertEqual(snapshot.todayCostUSD, Decimal(string: "0.50"))
        XCTAssertEqual(snapshot.balance?.toppedUpBalance, Decimal(string: "0.50"))
        XCTAssertEqual(snapshot.balance?.currency, "USD")
        XCTAssertEqual(snapshot.dataSource, .localLog)
        XCTAssertFalse(snapshot.isStale)
    }

    func testStalenessIsHonest() throws {
        // Fixed at midday so "an hour ago" cannot fall into yesterday.
        let now = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12)))
        let snapshot = CommandCodeLocalSessionAdapter.makeSnapshot(
            from: [event(at: now.addingTimeInterval(-3_600), tokens: 100, cost: nil)],
            staleThreshold: 900,
            now: now
        )
        XCTAssertTrue(snapshot.isStale)
        XCTAssertEqual(snapshot.confidence, .medium)
        XCTAssertEqual(snapshot.todayTokens, 100)
        XCTAssertNil(snapshot.balance, "no cost recorded means no spend to report")
    }

    func testOlderEventsAreDroppedFromTheRetainedWindow() {
        let now = Date()
        let snapshot = CommandCodeLocalSessionAdapter.makeSnapshot(
            from: [
                event(at: now.addingTimeInterval(-60 * 86_400), tokens: 10, cost: nil),
                event(at: now, tokens: 20, cost: nil)
            ],
            staleThreshold: 900,
            now: now
        )
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.inputTokens, 20)
    }

    /// Local dollars spent are not a subscription window, and must never render as one.
    func testLocalSpendNeverBecomesAQuotaWindow() {
        let now = Date()
        let snapshot = CommandCodeLocalSessionAdapter.makeSnapshot(
            from: [event(at: now, tokens: 1_000, cost: Decimal(string: "12.00"))],
            staleThreshold: 900,
            now: now
        )
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertNil(snapshot.monthly)
        XCTAssertNil(snapshot.contextWindowUsedPercent)
        XCTAssertNil(snapshot.primaryUsedPercent)
        XCTAssertNil(snapshot.dailyRequestsPercent)
    }

    func testDisabledProviderYieldsNoLocalRead() async {
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.commandcode, isEnabled: false)
        let snapshot = await CommandCodeLocalSessionAdapter().snapshot(settings: settings)
        XCTAssertEqual(snapshot.statusMessage, "Disabled")
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testEndToEndReadFromATemporaryProjectTree() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commandcode-e2e-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-someone-dev-tokenpilot", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let jsonl = """
        {"type":"header","session_id":"s1","cwd":"/Users/someone/dev/tokenpilot"}
        {"role":"assistant","timestamp":"\(stamp)","model":"claude-opus-5","usage":{"input_tokens":800,"output_tokens":200},"cost_usd":0.11}
        """
        try Data(jsonl.utf8).write(to: project.appendingPathComponent("s1.jsonl"))

        var settings = AppSettings()
        _ = settings.setProviderEnabled(.commandcode, isEnabled: true)
        let snapshot = await CommandCodeLocalSessionAdapter(projectRoots: [root]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .commandcode)
        XCTAssertEqual(snapshot.todayTokens, 1_000)
        XCTAssertEqual(snapshot.events.first?.projectLabel, "tokenpilot")
        XCTAssertEqual(snapshot.dataSource, .localLog)
    }

    func testMissingFolderIsReportedRatherThanFakedAsIdle() async {
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.commandcode, isEnabled: true)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commandcode-missing-\(UUID().uuidString)", isDirectory: true)
        let snapshot = await CommandCodeLocalSessionAdapter(projectRoots: [missing]).snapshot(settings: settings)
        XCTAssertEqual(snapshot.statusMessage, "Command Code session folder not found")
        XCTAssertEqual(snapshot.dataSource, .unknown)
    }
}

final class CommandCodeProviderRegistrationTests: XCTestCase {
    func testProviderIdentity() {
        XCTAssertEqual(Provider.commandcode.displayName, "Command Code")
        XCTAssertEqual(Provider.commandcode.shortName, "CC")
        XCTAssertFalse(Provider.commandcode.iconName.isEmpty)
        XCTAssertTrue(Provider.allCases.contains(.commandcode))
    }

    func testProviderIsOffUntilChosen() {
        XCTAssertFalse(AppSettings().isProviderEnabled(.commandcode))
    }

    func testLegacyPayloadWithoutTheFlagDecodesToOff() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.commandcodeEnabled)
    }

    /// Regression: enabling any provider must survive a save/load cycle.
    ///
    /// JetBrains, MiniMax, Z.ai, and OpenRouter were added without decode entries, so turning one
    /// on lasted until the next launch and then reverted with no message.
    func testEveryProviderSurvivesASettingsRoundTrip() throws {
        for provider in Provider.allCases {
            var settings = AppSettings()
            guard settings.setProviderEnabled(provider, isEnabled: true) else { continue }
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertTrue(
                decoded.isProviderEnabled(provider),
                "\(provider.rawValue) turned itself off across a settings round trip"
            )
        }
    }

    func testEnablingRoundTripsThroughCodable() throws {
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.commandcode, isEnabled: true)
        XCTAssertTrue(settings.isProviderEnabled(.commandcode))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.isProviderEnabled(.commandcode))
    }

    /// Activity evidence only: a currency balance and token activity, both incomparable.
    func testCapacityObservationsStayActivityOnly() {
        let now = Date()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.commandcode, isEnabled: true)
        let snapshot = CommandCodeLocalSessionAdapter.makeSnapshot(
            from: [
                UsageEvent(
                    provider: .commandcode,
                    model: "claude-opus-5",
                    timestamp: now,
                    inputTokens: 1_000,
                    outputTokens: 0,
                    estimatedCostUSD: Decimal(string: "1.25"),
                    source: "commandcode-session",
                    dataSource: .localLog
                )
            ],
            staleThreshold: 900,
            now: now
        )

        let observations = CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now)
        XCTAssertFalse(observations.isEmpty)
        for observation in observations {
            XCTAssertEqual(observation.seriesID.provider, .commandcode)
            XCTAssertEqual(observation.comparability, .incomparable, "local activity must never be comparable to quota")
            XCTAssertEqual(observation.authority, .localDerived)
            XCTAssertNil(observation.value.usedPercent, "no percentage may be derived from local spend")
        }
        XCTAssertTrue(observations.contains { $0.seriesID.providerWindowID == "session-cost" })
        XCTAssertTrue(observations.contains { $0.seriesID.providerWindowID == "context" })
    }

    func testAssessmentsAreNotAlertEligible() {
        let now = Date()
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.commandcode, isEnabled: true)
        let snapshot = CommandCodeLocalSessionAdapter.makeSnapshot(
            from: [
                UsageEvent(
                    provider: .commandcode,
                    timestamp: now,
                    inputTokens: 10,
                    outputTokens: 10,
                    estimatedCostUSD: Decimal(string: "0.5"),
                    source: "commandcode-session",
                    dataSource: .localLog
                )
            ],
            staleThreshold: 900,
            now: now
        )
        let observations = CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now)
        for observation in observations {
            let assessment = CapacityAssessmentService().assess(observation, now: now)
            XCTAssertEqual(assessment.alertEligibility, .ineligible)
            XCTAssertNotEqual(assessment.eligibilityReason, .eligible)
        }
    }

    func testLocalizedStringsExistForEveryShippedLocale() {
        // "Command Code" is a product name and stays identical everywhere; the rest must translate.
        let translatedKeys = [
            "Command Code session folder not found",
            "No Command Code usage recorded yet",
            "STALE · no Command Code activity in 15 minutes",
            "Local sessions · rolling dollar limits are not published locally",
            "Reads local session transcripts only. Local spend is activity, not remaining quota."
        ]
        for language in [TokenPilotLanguage.en, .ko, .ja, .zhHans, .zhHant] {
            XCTAssertEqual(TokenPilotLocalizer.localized("Command Code", language: language), "Command Code")
        }
        for key in translatedKeys {
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: .en), key)
            for language in [TokenPilotLanguage.ko, .ja, .zhHans, .zhHant] {
                let value = TokenPilotLocalizer.localized(key, language: language)
                XCTAssertFalse(value.isEmpty, "empty localization for \(language): \(key)")
                XCTAssertNotEqual(value, key, "missing \(language) translation for: \(key)")
            }
        }
    }
}
