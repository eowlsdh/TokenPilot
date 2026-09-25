import XCTest
@testable import TokenCore

/// The menu bar is shared space. These cover the two ways TokenPilot stops taking more of
/// it than the user agreed to: the width budget, and splitting the title into separate items.
final class MenuBarTextWidthTests: XCTestCase {
    func testLatinTextCostsOneCellPerCharacter() {
        XCTAssertEqual(MenuBarTextWidth.cells("OC 85% 7d"), 9)
        XCTAssertEqual(MenuBarTextWidth.cells(""), 0)
    }

    /// A Korean or Japanese label is twice as wide as its character count, so a budget that
    /// counted characters would be generous in English and meaningless everywhere else.
    func testCJKAndHangulCostTwoCells() {
        XCTAssertEqual(MenuBarTextWidth.cells("설정"), 4)
        XCTAssertEqual(MenuBarTextWidth.cells("設定"), 4)
        XCTAssertEqual(MenuBarTextWidth.cells("CC 설정"), 7)
        XCTAssertEqual(MenuBarTextWidth.cells("데이터 없음"), 11)
    }

    func testBudgetsRunFromUncappedToOneReading() {
        XCTAssertNil(MenuBarWidthLimit.full.characterBudget)
        XCTAssertEqual(MenuBarWidthLimit.standard.characterBudget, 26)
        XCTAssertEqual(MenuBarWidthLimit.narrow.characterBudget, 13)
    }
}

final class MenuBarWidthLimitTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two windows with reset countdowns: the widest thing the detailed layout draws.
    private func codexSnapshot() -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .codex,
            fiveHour: LimitWindow(
                kind: .fiveHour,
                usedPercent: 36,
                resetAt: Self.now.addingTimeInterval(3 * 3600)
            ),
            weekly: LimitWindow(
                kind: .weekly,
                usedPercent: 44,
                resetAt: Self.now.addingTimeInterval(4 * 86_400)
            ),
            todayTokens: 4_800,
            confidence: .manual,
            dataSource: .manual
        )
    }

    private func settings(_ limit: MenuBarWidthLimit) -> AppSettings {
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.localization.language = .en
        settings.menuBarDisplayTarget = .codex
        settings.menuBarWidthLimit = limit
        return settings
    }

    private func title(_ limit: MenuBarWidthLimit) -> String {
        MenuBarStatusService().title(
            snapshots: [codexSnapshot()],
            settings: settings(limit),
            modeLabel: "LIVE",
            now: Self.now
        )
    }

    func testFullKeepsBothWindowsAndBothCountdowns() {
        let full = title(.full)
        XCTAssertTrue(full.contains("5h 64%"), full)
        XCTAssertTrue(full.contains("7d 56%"), full)
        XCTAssertTrue(full.contains("·3h"), full)
        XCTAssertTrue(full.contains("·4d"), full)
    }

    /// Decoration goes before data: the countdown repeats what the popover shows, a window does not.
    /// The `EST` marker is not decoration — it says the number is an estimate — so it stays.
    func testStandardDropsCountdownsBeforeItDropsAWindow() {
        let standard = title(.standard)
        XCTAssertEqual(standard, "5h 64% EST · 7d 56% EST")
        XCTAssertLessThanOrEqual(MenuBarTextWidth.cells(standard), 26)
    }

    func testNarrowKeepsOneReadingWithItsCountdown() {
        let narrow = title(.narrow)
        XCTAssertTrue(narrow.hasPrefix("5h 64%"), narrow)
        XCTAssertFalse(narrow.contains("7d"), narrow)
        XCTAssertLessThanOrEqual(MenuBarTextWidth.cells(narrow), 13)
    }

    /// Whole components are dropped, never characters: a menu bar that says "5h 64%…" is
    /// asking the user to guess, and a truncated percentage would be a wrong number.
    func testTrimmingNeverCutsInsideAWord() {
        for limit in MenuBarWidthLimit.allCases {
            let rendered = title(limit)
            XCTAssertFalse(rendered.contains("…"), "\(limit): \(rendered)")
            XCTAssertFalse(rendered.contains("..."), "\(limit): \(rendered)")
            XCTAssertTrue(rendered.contains("64%"), "\(limit): \(rendered)")
        }
    }

    /// A budget that cannot be met still renders the leanest form rather than nothing.
    func testUnfittableTitleFallsBackToTheLeanestRendering() {
        var narrow = settings(.narrow)
        narrow.localization.language = .ko
        let rendered = MenuBarStatusService().title(
            snapshots: [],
            settings: narrow,
            modeLabel: "LIVE",
            now: Self.now
        )
        XCTAssertFalse(rendered.isEmpty)
    }

    func testWidthLimitRoundTripsAndDefaultsToStandard() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.menuBarWidthLimit, .standard)

        settings.menuBarWidthLimit = .narrow
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.menuBarWidthLimit, .narrow)

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.menuBarWidthLimit, .standard)

        let unknown = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"menuBarWidthLimit":"Hairline"}"#.utf8)
        )
        XCTAssertEqual(unknown.menuBarWidthLimit, .standard)
    }

    func testWidthSettingIsTranslatedEverywhereTokenPilotShips() {
        let keys = [
            "Menu bar width",
            "Full",
            "Standard",
            "Narrow",
            "The primary and secondary providers get their own menu bar items."
        ]
        for key in keys {
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

final class MenuBarTitleSegmentTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshots() -> [ProviderSnapshot] {
        [
            ProviderSnapshot(
                provider: .claude,
                fiveHour: LimitWindow(kind: .fiveHour, name: "5h", usedPercent: 20, confidence: .high),
                todayTokens: 1_000,
                confidence: .high,
                dataSource: .officialStatusline
            ),
            ProviderSnapshot(
                provider: .deepseek,
                confidence: .high,
                dataSource: .officialTelemetry,
                balance: ProviderBalance(currency: "USD", toppedUpBalance: Decimal(string: "12.34")!)
            )
        ]
    }

    private func compactSettings() -> AppSettings {
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.menuBarDisplayStyle = .compact
        settings.menuBarDisplayTarget = .claude
        settings.menuBarSecondaryDisplayTarget = .deepseek
        settings.menuBarShowsSecondaryProvider = true
        settings.menuBarWidthLimit = .full
        return settings
    }

    /// "Separate items" can only draw one item per provider if the title says where it splits.
    func testCompactTitleSplitsIntoOneSegmentPerProvider() {
        let segments = MenuBarStatusService().titleSegments(
            snapshots: snapshots(),
            settings: compactSettings(),
            modeLabel: "LIVE",
            now: Self.now
        )

        XCTAssertEqual(segments.map(\.provider), [.claude, .deepseek])
        XCTAssertTrue(segments[0].text.hasPrefix(Provider.claude.shortName), segments[0].text)
        XCTAssertTrue(segments[1].text.hasPrefix(Provider.deepseek.shortName), segments[1].text)
    }

    func testSegmentsRejoinIntoTheCombinedTitle() {
        let settings = compactSettings()
        let service = MenuBarStatusService()
        let joined = service.titleSegments(
            snapshots: snapshots(),
            settings: settings,
            modeLabel: "LIVE",
            now: Self.now
        )
        .map(\.text)
        .joined(separator: " · ")

        XCTAssertEqual(
            joined,
            service.title(snapshots: snapshots(), settings: settings, modeLabel: "LIVE", now: Self.now)
        )
    }

    /// Each item announces itself, because with separate items VoiceOver reaches them one at a time.
    func testEverySegmentCarriesItsOwnSpokenLabel() {
        let segments = MenuBarStatusService().titleSegments(
            snapshots: snapshots(),
            settings: compactSettings(),
            modeLabel: "LIVE",
            now: Self.now
        )

        for segment in segments {
            XCTAssertTrue(segment.accessibilityLabel.hasPrefix("TokenPilot,"), segment.accessibilityLabel)
            XCTAssertGreaterThan(segment.accessibilityLabel.count, segment.text.count)
        }
    }

    /// Detailed without a secondary describes one provider's windows; splitting those across
    /// two menu bar items would read as two providers.
    func testDetailedWithoutASecondaryStaysOneItem() {
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.menuBarDisplayStyle = .detailed
        settings.menuBarDisplayTarget = .claude
        settings.menuBarShowsSecondaryProvider = false

        let segments = MenuBarStatusService().titleSegments(
            snapshots: snapshots(),
            settings: settings,
            modeLabel: "LIVE",
            now: Self.now
        )

        XCTAssertEqual(segments.count, 1)
    }

    /// An idle provider produces no candidate. The primary slot used to fall back to the app
    /// itself, so a provider that was enabled, read, and simply quiet disappeared from the menu
    /// bar behind a generic "TP Setup" — which reads as "nothing is being watched".
    func testAnIdleProviderKeepsItsNameInsteadOfCollapsingIntoTheApp() {
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.localization.language = .en
        settings.menuBarDisplayStyle = .compact
        settings.menuBarWidthLimit = .full
        XCTAssertTrue(settings.setProviderEnabled(.deepseek, isEnabled: false))

        let idle = ProviderSnapshot(
            provider: .claude,
            todayTokens: 0,
            confidence: .low,
            dataSource: .localLog,
            isStale: true
        )
        let segments = MenuBarStatusService().titleSegments(
            snapshots: [idle],
            settings: settings,
            modeLabel: "LIVE",
            now: Self.now
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].provider, .claude)
        XCTAssertEqual(segments[0].text, "\(Provider.claude.shortName) — STALE")
        XCTAssertFalse(segments[0].text.contains("TP"), segments[0].text)
    }

    /// "Setup" has to keep meaning "there is no source here" — telling a configured user to set
    /// up a provider they already set up sends them looking for a problem that does not exist.
    func testAProviderWithNoSnapshotAtAllStillAsksForSetup() {
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.localization.language = .en
        settings.menuBarDisplayStyle = .compact
        settings.menuBarDisplayTarget = .claude

        let segments = MenuBarStatusService().titleSegments(
            snapshots: [],
            settings: settings,
            modeLabel: "LIVE",
            now: Self.now
        )

        XCTAssertEqual(segments[0].text, "\(Provider.claude.shortName) Setup")
    }

    /// The secondary provider is the user's explicit choice; an idle primary must not take its slot.
    func testAnIdlePrimaryDoesNotSwallowTheSecondarySlot() {
        var settings = compactSettings()
        settings.menuBarDisplayTarget = nil

        let idle = ProviderSnapshot(provider: .claude, todayTokens: 0, confidence: .low, dataSource: .localLog)
        let segments = MenuBarStatusService().titleSegments(
            snapshots: [idle],
            settings: settings,
            modeLabel: "LIVE",
            now: Self.now
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertNotEqual(segments[0].provider, segments[1].provider)
        XCTAssertEqual(segments[1].provider, .deepseek)
    }

    /// A per-item budget can only give back decoration; dropping the reading would leave a
    /// provider with an item that says nothing.
    func testNarrowSegmentsKeepTheirReading() {
        var settings = compactSettings()
        settings.menuBarWidthLimit = .narrow

        let segments = MenuBarStatusService().titleSegments(
            snapshots: snapshots(),
            settings: settings,
            modeLabel: "LIVE",
            now: Self.now
        )

        XCTAssertEqual(segments.count, 2)
        for segment in segments {
            XCTAssertFalse(segment.text.isEmpty)
            XCTAssertFalse(segment.text.contains("…"))
        }
    }
}

/// The consent flags were encoded but never read back, so an opt-in silently expired at the
/// next launch and the experimental probes went quiet with nothing to explain why.
final class ExperimentalConsentPersistenceTests: XCTestCase {
    func testExperimentalConsentSurvivesASettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.experimentalUsage.claudeConsentVersion = ExperimentalUsageSettings.claudeConsentVersionCurrent
        settings.experimentalUsage.codexConsentVersion = ExperimentalUsageSettings.codexConsentVersionCurrent

        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertTrue(roundTrip.experimentalUsage.claudeProbeEnabled)
        XCTAssertTrue(roundTrip.experimentalUsage.codexProbeEnabled)
        XCTAssertFalse(roundTrip.experimentalUsage.grokTierProbeEnabled)
    }

    func testConsentIsStillOffByDefaultAndAStaleVersionDoesNotCount() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.experimentalUsage.claudeProbeEnabled)
        XCTAssertFalse(legacy.experimentalUsage.codexProbeEnabled)
        XCTAssertFalse(legacy.experimentalUsage.grokTierProbeEnabled)

        let stale = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"experimentalUsage":{"claudeConsentVersion":0}}"#.utf8)
        )
        XCTAssertFalse(stale.experimentalUsage.claudeProbeEnabled)
    }
}
