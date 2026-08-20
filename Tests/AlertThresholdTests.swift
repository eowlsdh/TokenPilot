import XCTest
@testable import TokenCore

/// Alert thresholds were four fixed cases — reset, 50, 80, 100 — so a user who wanted warning at
/// 90% could not have one. That is a strange limitation in a tool whose whole job is warning you
/// before you run out.
final class AlertThresholdTests: XCTestCase {
    func testAnyReachablePercentageIsAThreshold() throws {
        for percent in [1, 37, 75, 90, 95, 99, 100] {
            let threshold = try XCTUnwrap(CapacityAlertPercentThreshold.percent(percent), "\(percent)")
            XCTAssertEqual(threshold.percent, percent)
            XCTAssertFalse(threshold.isReset)
        }
    }

    /// Rejected rather than clamped: a threshold at 0 fires on an untouched window and one above
    /// 100 can never be reached, and quietly moving either to something valid hides that.
    func testUnreachableThresholdsAreRejectedNotClamped() {
        for percent in [0, -5, 101, 1_000] {
            XCTAssertNil(CapacityAlertPercentThreshold.percent(percent), "\(percent)")
        }
    }

    /// The three original percentages keep their original stored spellings. Delivered-alert state
    /// is persisted by raw value, so renaming them would make every already-delivered alert look
    /// undelivered and fire a second time on the first launch after updating.
    func testTheOriginalPercentagesKeepTheirStoredSpelling() {
        XCTAssertEqual(CapacityAlertPercentThreshold.percent(50), .fifty)
        XCTAssertEqual(CapacityAlertPercentThreshold.percent(80), .eighty)
        XCTAssertEqual(CapacityAlertPercentThreshold.percent(100), .hundred)
        XCTAssertEqual(CapacityAlertPercentThreshold.fifty.rawValue, "fifty")
        XCTAssertEqual(CapacityAlertPercentThreshold.eighty.rawValue, "eighty")
        XCTAssertEqual(CapacityAlertPercentThreshold.hundred.rawValue, "hundred")
        XCTAssertEqual(CapacityAlertPercentThreshold.percent(90)?.rawValue, "p90")
    }

    func testResetIsAnEventNotALevel() {
        XCTAssertTrue(CapacityAlertPercentThreshold.reset.isReset)
        XCTAssertNil(CapacityAlertPercentThreshold.reset.percent)
    }

    /// Reset first, then ascending — the order a window actually crosses them in, so a jump past
    /// several thresholds reports them in the order they were passed.
    func testThresholdsSortResetFirstThenAscending() throws {
        let sorted = try [
            XCTUnwrap(CapacityAlertPercentThreshold.percent(90)),
            .hundred,
            .reset,
            .fifty
        ].sorted()

        XCTAssertEqual(sorted.map(\.rawValue), ["reset", "fifty", "p90", "hundred"])
    }

    func testAThresholdSurvivesAnEncodeAndAnUnknownOneIsRejected() throws {
        let threshold = try XCTUnwrap(CapacityAlertPercentThreshold.percent(90))
        let roundTrip = try JSONDecoder().decode(
            CapacityAlertPercentThreshold.self,
            from: JSONEncoder().encode(threshold)
        )
        XCTAssertEqual(roundTrip, threshold)

        // A raw value that means nothing must not silently become a threshold that never fires.
        XCTAssertThrowsError(
            try JSONDecoder().decode(CapacityAlertPercentThreshold.self, from: Data("\"p0\"".utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(CapacityAlertPercentThreshold.self, from: Data("\"sometimes\"".utf8))
        )
    }
}

final class AlertConditionCompatibilityTests: XCTestCase {
    private func encoded(_ condition: CapacityAlertCondition) throws -> [String: Any] {
        let data = try JSONEncoder().encode(condition)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["percentThresholds"] as? [String: Any])
    }

    func testACustomSetKeepsOnlyReachablePercentages() {
        let condition = CapacityAlertCondition.percentThresholds(reset: true, percents: [90, 0, 101, 75])

        XCTAssertEqual(
            condition.enabledPercentThresholds.compactMap(\.percent).sorted(),
            [75, 90]
        )
        XCTAssertTrue(condition.enabledPercentThresholds.contains(.reset))
    }

    /// A build from before thresholds were configurable must still read a file this one writes, so
    /// the three original percentages keep their boolean keys alongside the full list.
    func testTheStoredFormatStaysReadableByAnOlderBuild() throws {
        let condition = CapacityAlertCondition.percentThresholds(reset: true, percents: [50, 90, 100])
        let nested = try encoded(condition)

        XCTAssertEqual(nested["reset"] as? Bool, true)
        XCTAssertEqual(nested["fifty"] as? Bool, true)
        XCTAssertEqual(nested["eighty"] as? Bool, false)
        XCTAssertEqual(nested["hundred"] as? Bool, true)
        XCTAssertEqual(nested["percents"] as? [Int], [50, 90, 100])
    }

    /// The other direction: a file written before this change has no `percents`, and the booleans
    /// already carry everything it could express.
    func testAFileWrittenBeforeThisChangeStillDecodes() throws {
        let legacy = Data(#"{"percentThresholds":{"reset":true,"fifty":false,"eighty":true,"hundred":true}}"#.utf8)

        let condition = try JSONDecoder().decode(CapacityAlertCondition.self, from: legacy)

        XCTAssertEqual(condition.kind, .percentThresholds)
        XCTAssertEqual(condition.enabledPercentThresholds, [.reset, .eighty, .hundred])
    }

    func testACustomThresholdSurvivesARoundTrip() throws {
        let condition = CapacityAlertCondition.percentThresholds(reset: false, percents: [37, 90])

        let roundTrip = try JSONDecoder().decode(
            CapacityAlertCondition.self,
            from: JSONEncoder().encode(condition)
        )

        XCTAssertEqual(roundTrip, condition)
        XCTAssertEqual(roundTrip.enabledPercentThresholds.compactMap(\.percent).sorted(), [37, 90])
    }

    /// A stored percentage that is not reachable must fail the decode rather than load as a rule
    /// that silently never fires.
    func testAnUnreachableStoredPercentageFailsTheDecode() {
        let corrupt = Data(#"{"percentThresholds":{"reset":false,"percents":[0,90]}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(CapacityAlertCondition.self, from: corrupt))
    }

    /// The old four-boolean factory still exists because most callers and every stored rule speak
    /// in it; it must produce exactly what it always did.
    func testTheOriginalFactoryStillProducesTheOriginalSet() {
        let condition = CapacityAlertCondition.percentThresholds(reset: true, fifty: false, eighty: true, hundred: true)

        XCTAssertEqual(condition.enabledPercentThresholds, [.reset, .eighty, .hundred])
    }
}
