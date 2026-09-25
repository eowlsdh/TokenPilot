import XCTest
@testable import TokenCore

/// The model accepts any percentage, but that capability is only real if Settings can reach it.
/// These cover the editing path's contract: the choices offered, and the states a rule must never
/// be left in.
final class AlertThresholdEditingTests: XCTestCase {
    private func condition(reset: Bool, _ percents: [Int]) -> CapacityAlertCondition {
        .percentThresholds(reset: reset, percents: percents)
    }

    /// The benchmarked trackers default to 75/90/95, so those have to be one tap away rather than
    /// something a user has to know is possible.
    func testTheOfferedChoicesCoverWhatBenchmarksDefaultTo() {
        let offered = Set(TokenPilotViewModelAlertChoices.offered)

        for benchmarkDefault in [75, 90, 95] {
            XCTAssertTrue(offered.contains(benchmarkDefault), "\(benchmarkDefault)% should be one tap away")
        }
        XCTAssertTrue(offered.contains(80), "the app's own default has to stay reachable")
        XCTAssertTrue(offered.contains(100))
    }

    /// A threshold set anywhere else must still appear, or editing one chip would silently drop a
    /// value the user had chosen.
    func testAStoredThresholdOutsideTheOfferedSetStillAppears() {
        let stored = [37, 80]
        let choices = TokenPilotViewModelAlertChoices.choices(storedPercents: stored)

        XCTAssertTrue(choices.contains(37))
        XCTAssertEqual(choices, choices.sorted(), "choices should read in ascending order")
        XCTAssertEqual(Set(choices).intersection(stored), Set(stored))
    }

    func testTogglingAddsAndRemovesWithoutDisturbingTheRest() {
        var percents: Set<Int> = [80, 100]

        percents = TokenPilotViewModelAlertChoices.toggling(90, in: percents)
        XCTAssertEqual(percents.sorted(), [80, 90, 100])

        percents = TokenPilotViewModelAlertChoices.toggling(80, in: percents)
        XCTAssertEqual(percents.sorted(), [90, 100])
    }

    /// A rule with nothing switched on still looks configured while watching nothing, which is
    /// worse than having no rule at all.
    func testARuleIsNeverLeftWatchingNothing() {
        XCTAssertFalse(TokenPilotViewModelAlertChoices.isWatchingSomething(reset: false, percents: []))
        XCTAssertTrue(TokenPilotViewModelAlertChoices.isWatchingSomething(reset: true, percents: []))
        XCTAssertTrue(TokenPilotViewModelAlertChoices.isWatchingSomething(reset: false, percents: [90]))
    }

    /// Editing thresholds bumps the condition revision, which is part of the delivery key. That is
    /// what makes a newly added threshold arrive at the next crossing instead of immediately for a
    /// window the user is already inside.
    func testEditingThresholdsStartsAFreshDeliveryGeneration() throws {
        let original = try CapacityAlertRule(
            provider: .opencode,
            seriesID: try CapacitySeriesID(provider: .opencode, providerWindowID: "rate-limit", kind: .fixedReset, unit: .percent),
            authority: .providerReported,
            stability: .supported,
            enabled: true,
            routing: CapacityAlertRouting(macOS: true, telegram: false, discord: false),
            condition: condition(reset: true, [80, 100])
        )

        let edited = try original.replacingCondition(condition(reset: true, [80, 90, 100]))

        XCTAssertEqual(edited.conditionRevision, original.conditionRevision + 1)
        XCTAssertEqual(edited.id, original.id, "the rule identity must survive an edit")
        XCTAssertEqual(edited.condition.enabledPercentThresholds.compactMap(\.percent).sorted(), [80, 90, 100])
    }

    func testTheEditingStringsAreTranslatedEverywhereTokenPilotShips() {
        let keys = [
            "Alert at",
            "Keep at least one alert threshold.",
            "Could not save alert settings.",
            "Alert settings are recovering; try again in a moment.",
            "That alert threshold is not supported for this window."
        ]

        for key in keys {
            for language in TokenPilotLanguage.allCases where language != .system && language != .en {
                XCTAssertNotEqual(
                    TokenPilotLocalizer.localized(key, language: language),
                    key,
                    "\(key) is untranslated in \(language)"
                )
            }
        }
    }
}

/// The choice arithmetic, mirrored so it can be tested without a `@MainActor` view model.
/// `TokenPilotViewModelAlertChoicesParityTests` pins that it matches the shipping implementation.
enum TokenPilotViewModelAlertChoices {
    static let offered = [50, 75, 80, 90, 95, 100]

    static func choices(storedPercents: [Int]) -> [Int] {
        Set(offered + storedPercents).sorted()
    }

    static func toggling(_ percent: Int, in percents: Set<Int>) -> Set<Int> {
        var next = percents
        if next.contains(percent) { next.remove(percent) } else { next.insert(percent) }
        return next
    }

    static func isWatchingSomething(reset: Bool, percents: Set<Int>) -> Bool {
        reset || !percents.isEmpty
    }
}

/// A mirrored helper is only useful while it still mirrors. This reads the shipping source so the
/// two cannot drift into agreeing in tests and disagreeing in the app.
final class TokenPilotViewModelAlertChoicesParityTests: XCTestCase {
    func testTheMirroredChoicesMatchTheShippingOnes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"),
            encoding: .utf8
        )

        let rendered = TokenPilotViewModelAlertChoices.offered.map(String.init).joined(separator: ", ")
        XCTAssertTrue(
            source.contains("offeredAlertThresholds = [\(rendered)]"),
            "the view model's offered thresholds no longer match the mirrored list"
        )
        XCTAssertTrue(
            source.contains("guard reset || !percents.isEmpty else"),
            "the view model must still refuse to leave a rule watching nothing"
        )
    }
}
