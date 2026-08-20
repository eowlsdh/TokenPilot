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

    func testNewRulesCarryTheDefaultThresholds() throws {
        let result = CapacityAlertReconciler.reconcile(existing: [], enabledProviders: [.jetbrains], routing: routing)

        let created = try XCTUnwrap(result.rules.first)
        XCTAssertTrue(created.condition.enabledPercentThresholds.contains(.reset))
        XCTAssertEqual(created.condition.enabledPercentThresholds.compactMap(\.percent).sorted(), [80, 100])
        XCTAssertTrue(created.enabled)
    }
}
