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

    /// The sparkline is stored as what was left. Drawn as-is beside a Used number, the line fell
    /// while the number rose.
    func testTheMenuBarTrendRunsTheSameWayAsTheNumber() {
        let now = Date()
        let claude = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 90),
            confidence: .high,
            dataSource: .officialStatusline
        )
        let samples = [(60, 40), (30, 70), (10, 90)].enumerated().map { index, reading in
            ProviderLimitSample(
                provider: .claude,
                timestamp: now.addingTimeInterval(Double(index - 3) * 600),
                window: .fiveHour,
                usedPercent: reading.1,
                remainingPercent: reading.0,
                source: "test"
            )
        }
        var settings = AppSettings()
        settings.menuBarMetricProviders = [.claude]

        let remaining = MenuBarStatusService().providerMetricsSegments(snapshots: [claude], settings: settings, now: now, limitSamples: samples)
        XCTAssertEqual(remaining.first?.sparklineValues, [0.6, 0.3, 0.1])

        settings.capacityPercentDisplay = .used
        let used = MenuBarStatusService().providerMetricsSegments(snapshots: [claude], settings: settings, now: now, limitSamples: samples)
        let trend = used.first?.sparklineValues ?? []
        XCTAssertEqual(trend.count, 3)
        for (value, expected) in zip(trend, [0.4, 0.7, 0.9]) {
            XCTAssertEqual(value, expected, accuracy: 0.0001, "rising, like the 90% beside it")
        }
    }
}
