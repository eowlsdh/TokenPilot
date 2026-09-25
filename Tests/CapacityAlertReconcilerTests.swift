import XCTest
@testable import TokenCore

/// Alerts reached Claude and DeepSeek and no one else. These pin that reconciliation closes that
/// without disturbing anything a user already set — the failure mode that made this worth doing
/// carefully rather than by widening a filter.
final class CapacityAlertReconcilerTests: XCTestCase {
    private let routing = CapacityAlertRouting(macOS: true, telegram: false, discord: false)

    private func rule(
        provider: Provider,
        windowID: String,
        kind: CapacitySeriesKind = .fixedReset,
        condition: CapacityAlertCondition = CapacityAlertCatalogue.defaultThresholds,
        enabled: Bool = true,
        routing: CapacityAlertRouting? = nil
    ) throws -> CapacityAlertRule {
        try CapacityAlertRule(
            provider: provider,
            seriesID: try CapacitySeriesID(provider: provider, providerWindowID: windowID, kind: kind, unit: .percent),
            authority: .providerReported,
            stability: .supported,
            enabled: enabled,
            routing: routing ?? self.routing,
            condition: condition
        )
    }

    func testAWatchedProviderWithNoRulesGetsThem() {
        let result = CapacityAlertReconciler.reconcile(
            existing: [],
            enabledProviders: [.opencode],
            routing: routing
        )

        let windows = result.rules.map(\.seriesID.providerWindowID).sorted()
        XCTAssertEqual(windows, ["opencode-go-monthly", "opencode-go-rolling", "rate-limit"])
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.createdRuleIDs.count, 3)
    }

    /// The whole reason this does not go through the migration, which overwrites by rule ID.
    func testAHandEditedRuleIsLeftExactlyAsItWas() throws {
        let edited = try rule(
            provider: .opencode,
            windowID: "rate-limit",
            condition: .percentThresholds(reset: false, percents: [37, 95]),
            enabled: false,
            routing: CapacityAlertRouting(macOS: false, telegram: true, discord: false)
        )

        let result = CapacityAlertReconciler.reconcile(
            existing: [edited],
            enabledProviders: [.opencode],
            routing: routing
        )

        let survivor = try XCTUnwrap(result.rules.first { $0.id == edited.id })
        XCTAssertEqual(survivor, edited)
        XCTAssertEqual(survivor.condition.enabledPercentThresholds.compactMap(\.percent).sorted(), [37, 95])
        XCTAssertFalse(survivor.enabled)
        XCTAssertFalse(result.createdRuleIDs.contains(edited.id))
    }

    /// Runs on every refresh, so it has to settle after the first one.
    func testRunningItAgainChangesNothing() {
        let first = CapacityAlertReconciler.reconcile(existing: [], enabledProviders: [.kiro, .claude], routing: routing)
        let second = CapacityAlertReconciler.reconcile(existing: first.rules, enabledProviders: [.kiro, .claude], routing: routing)

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(second.rules, first.rules)
    }

    func testAProviderTheUserDoesNotWatchGetsNothing() {
        let result = CapacityAlertReconciler.reconcile(existing: [], enabledProviders: [.claude], routing: routing)

        XCTAssertEqual(Set(result.rules.map(\.provider)), [.claude])
        XCTAssertFalse(result.rules.contains { $0.provider == .jetbrains })
    }

    /// Switching a provider off and on again must not accumulate a second copy of its rules.
    func testTurningAProviderOffAndOnAgainDoesNotDuplicate() {
        let initial = CapacityAlertReconciler.reconcile(existing: [], enabledProviders: [.zai], routing: routing)
        let whileOff = CapacityAlertReconciler.reconcile(existing: initial.rules, enabledProviders: [], routing: routing)
        let backOn = CapacityAlertReconciler.reconcile(existing: whileOff.rules, enabledProviders: [.zai], routing: routing)

        XCTAssertEqual(backOn.rules.count, initial.rules.count)
        XCTAssertFalse(backOn.didChange)
    }

    /// Rules for other providers are carried through untouched, not dropped.
    func testRulesForOtherProvidersSurvive() throws {
        let claudeRule = try rule(provider: .claude, windowID: "five-hour")

        let result = CapacityAlertReconciler.reconcile(
            existing: [claudeRule],
            enabledProviders: [.minimax],
            routing: routing
        )

        XCTAssertTrue(result.rules.contains(claudeRule))
        XCTAssertTrue(result.rules.contains { $0.provider == .minimax })
    }

    /// Every provider the catalogue says is alertable actually receives rules, which is the gap
    /// this closes: it used to be Claude alone.
    func testEveryAlertableProviderIsReachedWhenWatched() {
        let providers = Set(CapacityAlertCatalogue.alertableSeries.map(\.provider))

        let result = CapacityAlertReconciler.reconcile(existing: [], enabledProviders: providers, routing: routing)

        XCTAssertEqual(Set(result.rules.map(\.provider)), providers)
        XCTAssertGreaterThan(providers.count, 5)
    }

    // MARK: - Series the app cannot name in advance

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func assessment(
        provider: Provider,
        windowID: String,
        kind: CapacitySeriesKind = .fixedReset,
        durationMinutes: Int? = nil,
        usedPercent: Int = 40,
        authority: CapacityAuthority = .providerReported,
        stability: CapacityStability = .supported
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
            observedAt: Self.now,
            resetAt: Self.now.addingTimeInterval(3_600),
            value: try CapacityValue(usedPercent: usedPercent),
            authority: authority,
            stability: stability,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: Self.now
        )
        return CapacityAssessmentService().assess(observation, now: Self.now)
    }

    /// Codex sets its own window durations, and a duration is part of a series identity, so no
    /// static entry can name them. They have to come from what was actually observed.
    func testCodexGetsRulesFromWhatWasObserved() throws {
        let observed = [
            try assessment(provider: .codex, windowID: "primary", kind: .rolling, durationMinutes: 15),
            try assessment(provider: .codex, windowID: "secondary", kind: .rolling, durationMinutes: 240)
        ]

        let result = CapacityAlertReconciler.reconcile(
            existing: [],
            enabledProviders: [.codex],
            routing: routing,
            observed: observed
        )

        XCTAssertEqual(result.rules.map(\.seriesID.providerWindowID).sorted(), ["primary", "secondary"])
        XCTAssertEqual(result.rules.compactMap(\.seriesID.durationMinutes).sorted(), [15, 240])
    }

    /// A window whose duration changed is a different series, so it gets its own rule rather than
    /// silently inheriting one meant for a different period.
    func testAChangedWindowDurationIsADifferentRule() throws {
        let first = CapacityAlertReconciler.reconcile(
            existing: [],
            enabledProviders: [.codex],
            routing: routing,
            observed: [try assessment(provider: .codex, windowID: "primary", kind: .rolling, durationMinutes: 15)]
        )
        let second = CapacityAlertReconciler.reconcile(
            existing: first.rules,
            enabledProviders: [.codex],
            routing: routing,
            observed: [try assessment(provider: .codex, windowID: "primary", kind: .rolling, durationMinutes: 300)]
        )

        XCTAssertEqual(second.rules.count, 2)
        XCTAssertTrue(second.didChange)
    }

    /// Only what the pipeline itself calls alertable. Deriving it again here would be a second
    /// opinion that could disagree with the engine that actually delivers.
    ///
    /// Uses a Codex window deliberately: it is not in the catalogue, so the observed path is the
    /// only thing that could create it. Asserting this with a catalogued series would have passed
    /// for the wrong reason — the catalogue creates those regardless of what was observed.
    func testAnUnofficialObservationCreatesNothing() throws {
        let localDerived = try assessment(
            provider: .codex,
            windowID: "primary",
            kind: .rolling,
            durationMinutes: 15,
            authority: .localDerived
        )

        let result = CapacityAlertReconciler.reconcile(
            existing: [],
            enabledProviders: [.codex],
            routing: routing,
            observed: [localDerived]
        )

        XCTAssertTrue(result.rules.isEmpty, "an unofficial reading must not create an alert rule")
    }

    /// Observing a series the user does not watch must not quietly switch alerting on for it.
    func testAnObservationForAnUnwatchedProviderIsIgnored() throws {
        let result = CapacityAlertReconciler.reconcile(
            existing: [],
            enabledProviders: [.claude],
            routing: routing,
            observed: [try assessment(provider: .codex, windowID: "primary", kind: .rolling, durationMinutes: 15)]
        )

        XCTAssertFalse(result.rules.contains { $0.provider == .codex })
    }

    func testNewRulesCarryTheDefaultThresholds() throws {
        let result = CapacityAlertReconciler.reconcile(existing: [], enabledProviders: [.jetbrains], routing: routing)

        let created = try XCTUnwrap(result.rules.first)
        XCTAssertTrue(created.condition.enabledPercentThresholds.contains(.reset))
        XCTAssertEqual(created.condition.enabledPercentThresholds.compactMap(\.percent).sorted(), [80, 100])
        XCTAssertTrue(created.enabled)
    }
}
