import XCTest
@testable import TokenCore

/// The app showed what is left; provider dashboards show what is used. A setting chooses, and the
/// number must say which — but colour and risk always come from what is left.
final class CapacityPercentDisplayTests: XCTestCase {
    func testTheShownNumberFollowsTheSetting() {
        XCTAssertEqual(CapacityPercentDisplay.remaining.shown(remaining: 15, used: 85), 15)
        XCTAssertEqual(CapacityPercentDisplay.used.shown(remaining: 15, used: 85), 85)
        XCTAssertEqual(CapacityPercentDisplay.used.shown(remaining: 15, used: nil), 85, "derived when used is missing")
    }

    func testExistingSettingsKeepRemaining() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.capacityPercentDisplay, .remaining)

        var settings = AppSettings()
        settings.capacityPercentDisplay = .used
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.capacityPercentDisplay, .used)
    }

    func testTheMenuBarShowsUsedButStillColoursByWhatIsLeft() {
        let now = Date()
        let claude = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 90),
            confidence: .high,
            dataSource: .officialStatusline
        )
        var settings = AppSettings()
        settings.menuBarMetricProviders = [.claude]

        let remaining = MenuBarStatusService().providerMetricsSegments(snapshots: [claude], settings: settings, now: now)
        XCTAssertEqual(remaining.first?.displayValue, "10%")

        settings.capacityPercentDisplay = .used
        let used = MenuBarStatusService().providerMetricsSegments(snapshots: [claude], settings: settings, now: now)
        XCTAssertEqual(used.first?.displayValue, "90%")
        XCTAssertEqual(used.first?.remainingPercent, 10, "colour must come from the 10% left, not the 90% shown")
        XCTAssertTrue(used.first?.accessibilityLabel.contains("90") == true)
    }
}
