import XCTest
@testable import TokenCore

// MARK: - Fixtures

private enum StatuslineFixtures {
    static let calendar = Calendar(identifier: .gregorian)

    static func now() -> Date {
        calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
    }

    static func assessment(
        provider: Provider = .claude,
        windowID: String = "five-hour",
        kind: CapacitySeriesKind = .fixedReset,
        durationMinutes: Int? = 300,
        usedPercent: Int,
        resetAt: Date? = nil,
        authority: CapacityAuthority = .providerReported,
        comparability: CapacityComparability = .comparable,
        observedAt: Date? = nil,
        maximumAge: TimeInterval = 3_600,
        now: Date = StatuslineFixtures.now()
    ) throws -> CapacityAssessment {
        let series = try CapacitySeriesID(
            provider: provider,
            providerWindowID: windowID,
            kind: kind,
            unit: .percent,
            durationMinutes: durationMinutes
        )
        let observation = try CapacityObservation(
            seriesID: series,
            observedAt: observedAt ?? now,
            resetAt: resetAt,
            value: try CapacityValue(usedPercent: usedPercent),
            authority: authority,
            stability: .supported,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: maximumAge),
            comparability: comparability,
            parserRevision: "statuslineV1",
            now: now
        )
        let record = try CapacityEvidenceRecord(observation: observation)
        return CapacityAssessmentService().assess(try record.observationForAssessment(now: now), now: now)
    }

    static func event(
        provider: Provider = .claude,
        at date: Date,
        input: Int = 1_000,
        output: Int = 200,
        cost: Decimal? = nil
    ) -> UsageEvent {
        UsageEvent(
            provider: provider,
            model: "fixture-model",
            timestamp: date,
            inputTokens: input,
            outputTokens: output,
            estimatedCostUSD: cost,
            source: "statusline-test",
            dataSource: .localLog,
            projectLabel: "SecretProject"
        )
    }
}

// MARK: - Input parsing

final class StatuslineInputTests: XCTestCase {
    func testParsesClaudeCodeStatusLinePayload() {
        let json = """
        {"model":{"display_name":"Opus 5","id":"claude-opus-5"},
         "cost":{"total_cost_usd":0.42,"total_duration_ms":1200},
         "exceeds_200k_tokens":true,
         "session_id":"abc-123",
         "workspace":{"current_dir":"/Users/someone/private"}}
        """
        let input = StatuslineService.parseInput(Data(json.utf8))
        XCTAssertEqual(input.modelName, "Opus 5")
        XCTAssertEqual(input.sessionCostUSD, Decimal(0.42))
        XCTAssertTrue(input.exceedsLargeContext)
    }

    func testFallsBackToModelIDWhenDisplayNameIsMissing() {
        let input = StatuslineService.parseInput(Data(#"{"model":{"id":"gpt-x"}}"#.utf8))
        XCTAssertEqual(input.modelName, "gpt-x")
    }

    func testEmptyAndMalformedPayloadsDegradeToEmptyInput() {
        XCTAssertEqual(StatuslineService.parseInput(Data()), .empty)
        XCTAssertEqual(StatuslineService.parseInput(Data("not json".utf8)), .empty)
        XCTAssertEqual(StatuslineService.parseInput(Data("[1,2,3]".utf8)), .empty)
    }

    func testModelNameIsCollapsedAndLengthCapped() {
        let long = String(repeating: "A", count: 80)
        let input = StatuslineService.parseInput(Data(#"{"model":{"display_name":"\#(long)"}}"#.utf8))
        XCTAssertEqual(input.modelName?.count, 28)
        XCTAssertTrue(input.modelName?.hasSuffix("…") == true)

        let multiline = StatuslineService.parseInput(Data(#"{"model":{"display_name":"Opus\n5"}}"#.utf8))
        XCTAssertEqual(multiline.modelName, "Opus 5")
    }

    func testNegativeSessionCostIsIgnored() {
        let input = StatuslineService.parseInput(Data(#"{"cost":{"total_cost_usd":-1}}"#.utf8))
        XCTAssertNil(input.sessionCostUSD)
    }
}

// MARK: - Component parsing

final class StatuslineComponentTests: XCTestCase {
    func testParsesOrderedComponentList() {
        XCTAssertEqual(
            StatuslineService.parseComponents("capacity, model ,today"),
            [.capacity, .model, .today]
        )
    }

    func testDropsDuplicatesKeepingFirstPosition() {
        XCTAssertEqual(StatuslineService.parseComponents("model,today,model"), [.model, .today])
    }

    func testRejectsUnknownAndEmptyLists() {
        XCTAssertNil(StatuslineService.parseComponents("model,nope"))
        XCTAssertNil(StatuslineService.parseComponents(""))
        XCTAssertNil(StatuslineService.parseComponents(" , "))
    }

    func testDefaultComponentsAreModelCapacityTodayCost() {
        XCTAssertEqual(StatuslineComponent.defaultComponents, [.model, .capacity, .today, .cost])
    }
}

// MARK: - Rendering

final class StatuslineRenderTests: XCTestCase {
    func testRendersModelCapacityTodayAndCost() throws {
        let now = StatuslineFixtures.now()
        let assessment = try StatuslineFixtures.assessment(
            usedPercent: 37,
            resetAt: now.addingTimeInterval(2 * 3_600 + 10 * 60)
        )
        let line = StatuslineService.render(
            input: StatuslineInput(modelName: "Opus 5"),
            events: [StatuslineFixtures.event(at: now.addingTimeInterval(-600), input: 900_000, output: 300_000, cost: Decimal(string: "1.25"))],
            windows: StatuslineService.windows(from: [assessment]),
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertEqual(line, "Opus 5 | Cl 5h 63% 2h10m | 1.2M tok | $1.25")
    }

    func testPicksTheTightestEligibleWindow() throws {
        let now = StatuslineFixtures.now()
        let roomy = try StatuslineFixtures.assessment(provider: .claude, usedPercent: 10)
        let tight = try StatuslineFixtures.assessment(
            provider: .opencode,
            windowID: "opencode-go-monthly",
            kind: .fixedReset,
            durationMinutes: nil,
            usedPercent: 88
        )
        let line = StatuslineService.render(
            events: [],
            windows: StatuslineService.windows(from: [roomy, tight]),
            components: [.capacity],
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertEqual(line, "OC mo 12%")
    }

    func testProviderFlagScopesCapacityAndLocalTotals() throws {
        let now = StatuslineFixtures.now()
        let claude = try StatuslineFixtures.assessment(provider: .claude, usedPercent: 80)
        let opencode = try StatuslineFixtures.assessment(
            provider: .opencode,
            windowID: "opencode-go-monthly",
            kind: .fixedReset,
            durationMinutes: nil,
            usedPercent: 90
        )
        let line = StatuslineService.render(
            events: [
                StatuslineFixtures.event(provider: .claude, at: now.addingTimeInterval(-60), input: 1_000, output: 0),
                StatuslineFixtures.event(provider: .opencode, at: now.addingTimeInterval(-60), input: 500_000, output: 0)
            ],
            windows: StatuslineService.windows(from: [claude, opencode]),
            components: [.capacity, .today],
            provider: .claude,
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertEqual(line, "Cl 5h 20% | 1K tok")
    }

    func testStaleEvidenceIsMarkedRatherThanShownAsCurrent() throws {
        let now = StatuslineFixtures.now()
        let stale = try StatuslineFixtures.assessment(
            usedPercent: 40,
            observedAt: now.addingTimeInterval(-7_200),
            maximumAge: 900
        )
        XCTAssertEqual(stale.freshness, .stale)
        let line = StatuslineService.render(
            events: [],
            windows: StatuslineService.windows(from: [stale]),
            components: [.capacity],
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertEqual(line, "Cl 5h 60%·S")
    }

    func testFreshEvidenceWinsOverStaleEvidence() throws {
        let now = StatuslineFixtures.now()
        let stale = try StatuslineFixtures.assessment(
            provider: .opencode,
            windowID: "opencode-go-monthly",
            kind: .fixedReset,
            durationMinutes: nil,
            usedPercent: 95,
            observedAt: now.addingTimeInterval(-7_200),
            maximumAge: 900
        )
        let fresh = try StatuslineFixtures.assessment(usedPercent: 20)
        let line = StatuslineService.render(
            events: [],
            windows: StatuslineService.windows(from: [stale, fresh]),
            components: [.capacity],
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertEqual(line, "Cl 5h 80%")
    }

    func testActivityOnlyEvidenceIsNeverRenderedAsQuota() throws {
        let now = StatuslineFixtures.now()
        let manual = try StatuslineFixtures.assessment(usedPercent: 50, authority: .userEntered)
        let line = StatuslineService.render(
            events: [],
            windows: StatuslineService.windows(from: [manual]),
            components: [.capacity],
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertEqual(line, "TokenPilot: no local usage yet")
    }

    func testBlockBurnAndSessionSegments() throws {
        let now = StatuslineFixtures.now()
        let line = StatuslineService.render(
            input: StatuslineInput(sessionCostUSD: Decimal(string: "0.4")),
            events: [StatuslineFixtures.event(at: now.addingTimeInterval(-30 * 60), input: 60_000, output: 0)],
            windows: StatuslineService.windows(from: []),
            components: [.block, .burn, .session],
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        // 12:00 sits in the 10:00-15:00 block, so three hours remain in it.
        XCTAssertEqual(line, "blk 60K 3h0m | 2K/min | ses $0.40")
    }

    func testEventsOutsideTodayAreExcluded() throws {
        let now = StatuslineFixtures.now()
        let line = StatuslineService.render(
            events: [StatuslineFixtures.event(at: now.addingTimeInterval(-48 * 3_600), input: 5_000, output: 0)],
            windows: StatuslineService.windows(from: []),
            components: [.today, .cost],
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertEqual(line, "TokenPilot: no local usage yet")
    }

    func testLargeContextFlagMarksTheModelSegment() {
        let now = StatuslineFixtures.now()
        let line = StatuslineService.render(
            input: StatuslineInput(modelName: "Opus 5", exceedsLargeContext: true),
            events: [],
            windows: StatuslineService.windows(from: []),
            components: [.model],
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertEqual(line, "Opus 5 ⚠")
    }

    func testColorTiersFollowRemainingPercent() throws {
        let now = StatuslineFixtures.now()
        func colored(usedPercent: Int) throws -> String {
            StatuslineService.render(
                events: [],
                windows: StatuslineService.windows(from: [try StatuslineFixtures.assessment(usedPercent: usedPercent)]),
                components: [.capacity],
                colorized: true,
                now: now,
                calendar: StatuslineFixtures.calendar
            )
        }
        // Tiers come from the app-wide risk thresholds (85% used critical, 70% warning),
        // so the line agrees with the menu bar block and the popover.
        XCTAssertTrue(try colored(usedPercent: 85).hasPrefix("\u{001B}[31m"))
        XCTAssertTrue(try colored(usedPercent: 75).hasPrefix("\u{001B}[33m"))
        XCTAssertTrue(try colored(usedPercent: 60).hasPrefix("\u{001B}[32m"))
        XCTAssertTrue(try colored(usedPercent: 10).hasPrefix("\u{001B}[32m"))
        XCTAssertTrue(try colored(usedPercent: 10).hasSuffix("\u{001B}[0m"))
    }

    func testUncolorizedOutputCarriesNoEscapeCodes() throws {
        let now = StatuslineFixtures.now()
        let line = StatuslineService.render(
            events: [],
            windows: StatuslineService.windows(from: [try StatuslineFixtures.assessment(usedPercent: 95)]),
            components: [.capacity],
            colorized: false,
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertFalse(line.contains("\u{001B}"))
    }

    func testRenderNeverLeaksPathsProjectLabelsOrSessionIdentifiers() throws {
        let now = StatuslineFixtures.now()
        let payload = """
        {"model":{"display_name":"Opus 5"},"session_id":"sess-secret",
         "workspace":{"current_dir":"/Users/someone/private","project_dir":"/Users/someone/private"},
         "transcript_path":"/Users/someone/.claude/transcript.jsonl","cost":{"total_cost_usd":0.4}}
        """
        let line = StatuslineService.render(
            input: StatuslineService.parseInput(Data(payload.utf8)),
            events: [StatuslineFixtures.event(at: now.addingTimeInterval(-60), input: 10, output: 10, cost: Decimal(string: "0.01"))],
            windows: StatuslineService.windows(from: [try StatuslineFixtures.assessment(usedPercent: 10)]),
            components: StatuslineComponent.allCases,
            now: now,
            calendar: StatuslineFixtures.calendar
        )
        XCTAssertFalse(line.contains("sess-secret"))
        XCTAssertFalse(line.contains("/Users/"))
        XCTAssertFalse(line.contains("SecretProject"))
        XCTAssertFalse(line.contains("statusline-test"))
        XCTAssertFalse(line.contains("transcript"))
    }

    func testCountdownSwitchesToDaysBeyondTwoDays() {
        let now = StatuslineFixtures.now()
        XCTAssertEqual(StatuslineService.countdownText(until: now.addingTimeInterval(90), now: now), "1m")
        XCTAssertEqual(StatuslineService.countdownText(until: now.addingTimeInterval(3 * 3_600 + 5 * 60), now: now), "3h5m")
        XCTAssertEqual(StatuslineService.countdownText(until: now.addingTimeInterval(5 * 86_400), now: now), "5d")
        XCTAssertEqual(StatuslineService.countdownText(until: now.addingTimeInterval(-60), now: now), "0m")
    }

    func testWindowLabelPrefersDurationThenWindowID() {
        func label(_ windowID: String, _ durationMinutes: Int?, provider: Provider = .claude) -> String {
            StatuslineService.windowLabel(
                for: StatuslineCapacityWindow(
                    provider: provider,
                    windowID: windowID,
                    durationMinutes: durationMinutes,
                    usedPercent: 0,
                    resetAt: nil,
                    observedAt: StatuslineFixtures.now(),
                    maximumAgeSeconds: 3_600
                )
            )
        }
        XCTAssertEqual(label("five-hour", 300), "5h")
        XCTAssertEqual(label("seven-day", 10_080), "7d")
        XCTAssertEqual(label("opencode-go-monthly", nil), "mo")
        XCTAssertEqual(label("daily-requests", nil), "req")
        XCTAssertEqual(label("something-new", nil), "quota")
        XCTAssertEqual(label("opencode-go-rolling", 300), "5h")
        XCTAssertEqual(label("rolling", nil), "roll")
    }

    /// opencode's weekly quota carries the `rate-limit` id for historical reasons and was reading
    /// "roll" in the statusline — the one thing a weekly window is not. Elsewhere the id names no
    /// period, so it stays unlabelled rather than being given one.
    func testTheWeeklyOpenCodeWindowIsNotLabelledRolling() {
        func label(_ provider: Provider) -> String {
            StatuslineService.windowLabel(
                for: StatuslineCapacityWindow(
                    provider: provider,
                    windowID: "rate-limit",
                    durationMinutes: nil,
                    usedPercent: 85,
                    resetAt: nil,
                    observedAt: StatuslineFixtures.now(),
                    maximumAgeSeconds: 3_600
                )
            )
        }

        XCTAssertEqual(label(.opencode), "7d")
        XCTAssertEqual(label(.codex), "quota")
    }
}

// MARK: - Capacity window mapping and snapshot

final class StatuslineCapacityWindowTests: XCTestCase {
    func testKeepsProviderReportedPercentWindowsWithTheirFreshnessPolicy() throws {
        let now = StatuslineFixtures.now()
        let assessment = try StatuslineFixtures.assessment(
            usedPercent: 42,
            resetAt: now.addingTimeInterval(1_800),
            maximumAge: 900
        )
        let windows = StatuslineService.windows(from: [assessment])
        XCTAssertEqual(windows.count, 1)
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.provider, .claude)
        XCTAssertEqual(window.windowID, "five-hour")
        XCTAssertEqual(window.durationMinutes, 300)
        XCTAssertEqual(window.usedPercent, 42)
        XCTAssertEqual(window.remainingPercent, 58)
        XCTAssertEqual(window.observedAt, now)
        XCTAssertEqual(window.maximumAgeSeconds, 900)
        XCTAssertTrue(window.isFresh(now: now))
        XCTAssertFalse(window.isFresh(now: now.addingTimeInterval(901)))
    }

    func testDropsManualAndIncomparableEvidence() throws {
        let manual = try StatuslineFixtures.assessment(usedPercent: 30, authority: .userEntered)
        let incomparable = try StatuslineFixtures.assessment(
            usedPercent: 30,
            authority: .localDerived,
            comparability: .incomparable
        )
        XCTAssertTrue(StatuslineService.windows(from: [manual, incomparable]).isEmpty)
    }

    func testFutureObservationIsNotTreatedAsFresh() {
        let now = StatuslineFixtures.now()
        let window = StatuslineCapacityWindow(
            provider: .claude,
            windowID: "five-hour",
            durationMinutes: 300,
            usedPercent: 10,
            resetAt: nil,
            observedAt: now.addingTimeInterval(600),
            maximumAgeSeconds: 900
        )
        XCTAssertFalse(window.isFresh(now: now))
    }

    func testPercentIsClampedIntoRange() {
        let low = StatuslineCapacityWindow(provider: .claude, windowID: "five-hour", durationMinutes: 300, usedPercent: -5, resetAt: nil, observedAt: Date(), maximumAgeSeconds: 60)
        let high = StatuslineCapacityWindow(provider: .claude, windowID: "five-hour", durationMinutes: 300, usedPercent: 140, resetAt: nil, observedAt: Date(), maximumAgeSeconds: 60)
        XCTAssertEqual(low.usedPercent, 0)
        XCTAssertEqual(high.usedPercent, 100)
    }
}

final class StatuslineSnapshotStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("statusline-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testRoundTripsThroughDisk() throws {
        let now = StatuslineFixtures.now()
        let store = StatuslineSnapshotStore(directory: directory)
        let snapshot = StatuslineSnapshot(
            generatedAt: now,
            windows: StatuslineService.windows(from: [try StatuslineFixtures.assessment(usedPercent: 25, resetAt: now.addingTimeInterval(600))])
        )
        XCTAssertTrue(store.save(snapshot))

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.schemaVersion, StatuslineSnapshot.currentSchemaVersion)
        XCTAssertEqual(loaded.windows.count, 1)
        XCTAssertEqual(loaded.windows.first?.usedPercent, 25)
        XCTAssertEqual(loaded.windows.first?.provider, .claude)
    }

    func testMissingUnreadableAndNewerSchemaFilesLoadAsNil() throws {
        let store = StatuslineSnapshotStore(directory: directory)
        XCTAssertNil(store.load())

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("statusline-snapshot-v1.json")
        try Data("{ not json".utf8).write(to: fileURL)
        XCTAssertNil(store.load())

        let future = StatuslineSnapshot(generatedAt: Date(), windows: [], schemaVersion: StatuslineSnapshot.currentSchemaVersion + 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(future).write(to: fileURL)
        XCTAssertNil(store.load())
    }

    func testSnapshotCarriesNoPathsOrProjectLabels() throws {
        let now = StatuslineFixtures.now()
        let store = StatuslineSnapshotStore(directory: directory)
        XCTAssertTrue(
            store.save(
                StatuslineSnapshot(
                    generatedAt: now,
                    windows: StatuslineService.windows(from: [try StatuslineFixtures.assessment(usedPercent: 25)])
                )
            )
        )
        let raw = try String(contentsOf: directory.appendingPathComponent("statusline-snapshot-v1.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("/Users/"))
        XCTAssertFalse(raw.contains("statuslineV1"))
        XCTAssertFalse(raw.contains("SecretProject"))
    }
}

// MARK: - CLI surface

final class StatuslineCLITests: XCTestCase {
    func testStatuslineIsRecognizedAsACLIInvocation() {
        XCTAssertTrue(TokenPilotCLIService.isCLIInvocation(["statusline"]))
    }

    func testParsesDefaultsAndFlags() {
        guard case .success(let command) = TokenPilotCLIService.parse(arguments: ["statusline"]) else {
            return XCTFail("statusline should parse")
        }
        XCTAssertEqual(command, .statusline(components: StatuslineComponent.defaultComponents, provider: nil, colorized: true, timeZone: nil))

        guard case .success(let flagged) = TokenPilotCLIService.parse(
            arguments: ["statusline", "--components", "capacity,burn", "--provider", "claude", "--no-color", "--timezone", "UTC"]
        ) else {
            return XCTFail("flags should parse")
        }
        XCTAssertEqual(
            flagged,
            .statusline(components: [.capacity, .burn], provider: .claude, colorized: false, timeZone: TimeZone(identifier: "UTC"))
        )
    }

    func testRejectsUnknownFlagsAndComponents() {
        guard case .failure(let componentError) = TokenPilotCLIService.parse(arguments: ["statusline", "--components", "bogus"]) else {
            return XCTFail("unknown component should fail")
        }
        XCTAssertEqual(componentError, .invalidComponents("bogus"))

        guard case .failure(let flagError) = TokenPilotCLIService.parse(arguments: ["statusline", "--wat"]) else {
            return XCTFail("unknown flag should fail")
        }
        XCTAssertEqual(flagError, .unknownCommand("--wat"))

        guard case .failure(let missingError) = TokenPilotCLIService.parse(arguments: ["statusline", "--components"]) else {
            return XCTFail("missing value should fail")
        }
        XCTAssertEqual(missingError, .missingValue(forFlag: "--components"))
    }

    func testHelpDocumentsTheCommandAndItsRedaction() {
        let help = TokenPilotCLIService.helpText
        XCTAssertTrue(help.contains("TokenPilot statusline"))
        XCTAssertTrue(help.contains("--components"))
        XCTAssertTrue(help.contains("--no-color"))
        XCTAssertTrue(help.contains("never prints paths, project labels, or session identifiers"))
    }
}

// MARK: - Menu bar gauge

final class MenuBarGaugeServiceTests: XCTestCase {
    func testReadsLeadingPercentFromPlainAndDecoratedValues() {
        XCTAssertEqual(MenuBarGaugeService.remainingPercent(displayValue: "63%"), 63)
        XCTAssertEqual(MenuBarGaugeService.remainingPercent(displayValue: "63%·E"), 63)
        XCTAssertEqual(MenuBarGaugeService.remainingPercent(displayValue: "8%·ES"), 8)
        XCTAssertEqual(MenuBarGaugeService.remainingPercent(displayValue: " 100%"), 100)
    }

    func testNonPercentValuesHaveNoBar() {
        XCTAssertNil(MenuBarGaugeService.remainingFraction(displayValue: "Setup"))
        XCTAssertNil(MenuBarGaugeService.remainingFraction(displayValue: "—"))
        XCTAssertNil(MenuBarGaugeService.remainingFraction(displayValue: "$12.30"))
        XCTAssertNil(MenuBarGaugeService.remainingFraction(displayValue: "1.2M"))
        XCTAssertNil(MenuBarGaugeService.remainingFraction(displayValue: "%"))
    }

    func testFractionIsNormalized() {
        XCTAssertEqual(MenuBarGaugeService.remainingFraction(displayValue: "0%"), 0)
        XCTAssertEqual(MenuBarGaugeService.remainingFraction(displayValue: "50%"), 0.5)
        XCTAssertEqual(MenuBarGaugeService.remainingFraction(displayValue: "100%"), 1)
    }
}

// MARK: - Wake refresh

final class WakeRefreshGateTests: XCTestCase {
    func testRefreshesWhenNothingHasRefreshedYet() {
        XCTAssertTrue(WakeRefreshGate.shouldRefresh(lastRefreshFinishedAt: nil, now: Date()))
    }

    func testDebouncesARefreshThatJustFinished() {
        let now = Date()
        XCTAssertFalse(WakeRefreshGate.shouldRefresh(lastRefreshFinishedAt: now.addingTimeInterval(-5), now: now))
        XCTAssertFalse(WakeRefreshGate.shouldRefresh(lastRefreshFinishedAt: now.addingTimeInterval(-29), now: now))
        XCTAssertTrue(WakeRefreshGate.shouldRefresh(lastRefreshFinishedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(WakeRefreshGate.shouldRefresh(lastRefreshFinishedAt: now.addingTimeInterval(-3_600), now: now))
    }

    func testRefreshesWhenTheClockMovedBackwards() {
        let now = Date()
        XCTAssertTrue(WakeRefreshGate.shouldRefresh(lastRefreshFinishedAt: now.addingTimeInterval(120), now: now))
    }
}

// MARK: - Settings

final class MenuBarTrendStyleSettingsTests: XCTestCase {
    func testDefaultsToSparklineSoExistingMenuBarsAreUnchanged() {
        XCTAssertEqual(AppSettings().menuBarTrendStyle, .sparkline)
    }

    func testLegacyPayloadWithoutTheKeyDecodesToSparkline() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.menuBarTrendStyle, .sparkline)
    }

    func testRoundTripsThroughCodable() throws {
        var settings = AppSettings()
        settings.menuBarTrendStyle = .bar
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.menuBarTrendStyle, .bar)
    }
}

// MARK: - Localization

final class StatuslineLocalizationTests: XCTestCase {
    private static let newKeys: [(String, [(TokenPilotLanguage, String, String)])] = [
        (
            "Menu bar trend",
            [
                (.en, "en", "Menu bar trend"),
                (.ko, "ko", "메뉴 막대 추세"),
                (.ja, "ja", "メニューバーのトレンド"),
                (.zhHans, "zh-Hans", "菜单栏趋势"),
                (.zhHant, "zh-Hant", "菜單欄趨勢")
            ]
        ),
        (
            "Remaining bar",
            [
                (.en, "en", "Remaining bar"),
                (.ko, "ko", "잔여 막대"),
                (.ja, "ja", "残量バー"),
                (.zhHans, "zh-Hans", "剩余量条"),
                (.zhHant, "zh-Hant", "剩餘量條")
            ]
        ),
        (
            "No trend",
            [
                (.en, "en", "No trend"),
                (.ko, "ko", "표시 안 함"),
                (.ja, "ja", "表示しない"),
                (.zhHans, "zh-Hans", "不显示"),
                (.zhHant, "zh-Hant", "不顯示")
            ]
        ),
        (
            "Terminal status line",
            [
                (.en, "en", "Terminal status line"),
                (.ko, "ko", "터미널 상태 표시줄"),
                (.ja, "ja", "ターミナルのステータスライン"),
                (.zhHans, "zh-Hans", "终端状态栏"),
                (.zhHant, "zh-Hant", "終端狀態列")
            ]
        )
    ]

    func testNewMenuBarAndStatuslineKeysExistInBothLocalizationSurfaces() throws {
        let rootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalogData = try Data(contentsOf: rootURL.appendingPathComponent("Sources/TokenApp/Resources/Localizable.xcstrings"))
        let catalogRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalogStrings = try XCTUnwrap(catalogRoot["strings"] as? [String: Any])

        for (key, translations) in Self.newKeys {
            let entry = try XCTUnwrap(catalogStrings[key] as? [String: Any], "Missing catalog key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing catalog localizations: \(key)")
            for (language, locale, expected) in translations {
                XCTAssertEqual(TokenPilotLocalizer.localized(key, language: language), expected, "Wrong runtime fallback for \(locale): \(key)")
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "Missing catalog locale \(locale): \(key)")
                let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "Missing catalog string unit \(locale): \(key)")
                XCTAssertEqual(stringUnit["value"] as? String, expected, "Wrong catalog value for \(locale): \(key)")
            }
        }
    }
}
