import XCTest
@testable import TokenCore

/// Cache reads are context being re-sent. Counting them into "how much did I do" made a headline
/// read as broken and a budget fire on nothing; these pin which surfaces use which number.
final class WorkingTokenTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        reasoning: Int = 0,
        at offset: TimeInterval = 0
    ) -> UsageEvent {
        UsageEvent(
            provider: .claude,
            timestamp: Self.now.addingTimeInterval(offset),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            reasoningTokens: reasoning,
            requestCount: 1,
            source: "test",
            dataSource: .localLog
        )
    }

    /// A cache write is new content being stored; a cache read is the same content coming back.
    /// Only the read is excluded.
    func testWorkingTokensDropCacheReadsButKeepEverythingElse() {
        let sample = event(input: 100, output: 200, cacheRead: 900_000, cacheCreation: 50, reasoning: 25)

        XCTAssertEqual(sample.totalTokens, 900_375)
        XCTAssertEqual(sample.workingTokens, 375)
        XCTAssertEqual(sample.cacheTokens, 900_050)
    }

    func testWorkingTokensNeverGoNegative() {
        XCTAssertEqual(event(cacheRead: 1_000).workingTokens, 0)
        XCTAssertEqual(event().workingTokens, 0)
    }

    /// An override arrives as an opaque total, so there are no components to subtract from and
    /// pretending otherwise would silently shrink a provider's numbers.
    func testAnOverriddenTotalIsReportedWhole() {
        var overridden = event(cacheRead: 900_000)
        overridden.totalTokensOverride = 1_234

        XCTAssertEqual(overridden.totalTokens, 1_234)
        XCTAssertEqual(overridden.workingTokens, 1_234)
    }

    func testSnapshotSubtractsOnlyWhatTheSourceReported() {
        let split = ProviderSnapshot(provider: .claude, todayTokens: 1_000, todayCacheReadTokens: 940)
        XCTAssertEqual(split.todayWorkingTokens, 60)

        // A provider that cannot break its total down is never made to look smaller than it is.
        let opaque = ProviderSnapshot(provider: .codex, todayTokens: 1_000)
        XCTAssertEqual(opaque.todayWorkingTokens, 1_000)

        // A source claiming more cache than total is clamped rather than producing a negative.
        let inconsistent = ProviderSnapshot(provider: .claude, todayTokens: 100, todayCacheReadTokens: 5_000)
        XCTAssertEqual(inconsistent.todayCacheReadTokens, 100)
        XCTAssertEqual(inconsistent.todayWorkingTokens, 0)
    }

    func testCacheReadTotalSurvivesAnEncodeAndLegacyPayloadsDecode() throws {
        let snapshot = ProviderSnapshot(provider: .claude, todayTokens: 1_000, todayCacheReadTokens: 940)
        let roundTrip = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundTrip.todayCacheReadTokens, 940)

        let legacy = try JSONDecoder().decode(
            ProviderSnapshot.self,
            from: Data(#"{"provider":"claude","todayTokens":1000}"#.utf8)
        )
        XCTAssertEqual(legacy.todayCacheReadTokens, 0)
        XCTAssertEqual(legacy.todayWorkingTokens, 1_000)
    }

    /// The functional half of the bug: a token budget was blown by the first conversation of the
    /// day, so the guardrail alerted on re-sent context rather than on work.
    func testATokenBudgetIsNotBlownByCacheReads() {
        let events = [event(input: 500, output: 500, cacheRead: 5_000_000)]
        let settings = BudgetGuardrailSettings(dailyTokens: 100_000, alertThresholdPercent: 80)

        let progress = BudgetGuardrailService().dailyProgress(events: events, settings: settings, now: Self.now)

        XCTAssertEqual(progress.tokens, 1_000)
        XCTAssertEqual(progress.percent, 1)
        XCTAssertFalse(progress.crossedThreshold)
    }

    func testMilestonesAreNotHandedOutForReSentContext() {
        let events = [event(output: 1_000, cacheRead: 9_000_000)]

        let milestones = ActivityMilestoneService().achievedMilestones(events: events, now: Self.now)

        XCTAssertFalse(
            milestones.contains { $0.dimension == .lifetimeTokens },
            "9M cache reads and 1K of output is not a token milestone"
        )
    }

    /// The menu bar shows one number, so it shows the one that means "work done" — and the metric
    /// picker is offered for the compact layout too, which used to ignore it entirely.
    func testTheMenuBarTodayTokenMetricUsesWorkingTokensInBothTextLayouts() {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            todayTokens: 545_000_000,
            todayCacheReadTokens: 535_000_000,
            confidence: .medium,
            dataSource: .localLog
        )
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.localization.language = .en
        settings.menuBarPrimaryMetric = .todayTokens
        settings.menuBarDisplayTarget = .claude
        settings.menuBarWidthLimit = .full

        for style in [MenuBarDisplayStyle.detailed, .compact] {
            var styled = settings
            styled.menuBarDisplayStyle = style
            let title = MenuBarStatusService().title(
                snapshots: [snapshot],
                settings: styled,
                modeLabel: "LIVE",
                now: Self.now
            )
            XCTAssertTrue(title.contains("10.0Mtok") || title.contains("10Mtok"), "\(style): \(title)")
            XCTAssertFalse(title.contains("545"), "\(style): \(title)")
        }
    }

    /// Full accounting is exactly what History and the export are for, so they keep every token.
    /// This guards the other direction: the fix must not quietly shrink the ledger.
    func testHistoryStyleTotalsStillCountEveryToken() {
        let events = [event(input: 100, output: 200, cacheRead: 900_000, cacheCreation: 50)]

        XCTAssertEqual(events.reduce(0) { $0 + $1.totalTokens }, 900_350)
        XCTAssertEqual(events.reduce(0) { $0 + $1.cacheTokens }, 900_050)
    }
}
