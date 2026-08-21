import XCTest
@testable import TokenCore

/// The failure this pins is the one a limit monitor cannot have: going quiet exactly when a limit is
/// reached. opencode's monthly window stopped being recorded on 2026-08-19T02:58 — 1,171 samples,
/// then nothing, while the rolling and weekly windows carried on to 1,665 — and the provider's own
/// dashboard shows that same window at 100%. The parser required `status == "ok"` and dropped
/// everything else.
final class OpenCodeExhaustedWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ usage: [String: Any]) -> OpenCodeRateLimit? {
        let data = try? JSONSerialization.data(withJSONObject: ["usage": usage])
        return OpenCodeRateLimitObserver.parse(data: data ?? Data(), now: now)
    }

    /// The three windows exactly as the provider's dashboard showed them.
    func testTheDashboardsThreeWindowsAllSurvive() throws {
        let limit = try XCTUnwrap(parse([
            "rolling": ["status": "ok", "percent": 0],
            "weekly": ["status": "ok", "percent": 15],
            "monthly": ["status": "limited", "percent": 100]
        ]))

        XCTAssertEqual(limit.rolling?.usedPercent, 0)
        XCTAssertEqual(limit.weekly?.usedPercent, 15)
        XCTAssertEqual(limit.monthly?.usedPercent, 100, "an exhausted window is the one that matters most")
    }

    /// Whatever word the provider uses for "you have hit the limit", the reading survives it. The
    /// vocabulary is not documented, which is precisely why it cannot be an allow-list.
    func testAnyStatusKeepsAWindowThatCarriesAReading() throws {
        for status in ["ok", "limited", "exceeded", "rate_limited", "throttled", "warning", "unknown"] {
            let limit = try XCTUnwrap(parse(["monthly": ["status": status, "percent": 100]]), status)
            XCTAssertEqual(limit.monthly?.usedPercent, 100, "status \(status) discarded a real reading")
        }
    }

    func testAWindowWithNoStatusAtAllIsStillARead() throws {
        let limit = try XCTUnwrap(parse(["weekly": ["percent": 42]]))

        XCTAssertEqual(limit.weekly?.usedPercent, 42)
    }

    /// The gate moved to the reading, so a payload without one is still refused — the app does not
    /// invent a percentage for a window the provider did not measure.
    func testAWindowWithoutAPercentageIsStillRefused() {
        XCTAssertNil(parse(["monthly": ["status": "ok"]]))
        XCTAssertNil(parse(["monthly": ["status": "ok", "percent": "not a number"]]))
        XCTAssertNil(parse(["monthly": "not an object"]))
    }

    /// A reading at the ceiling has to come through as the ceiling, not be clamped away.
    func testAnExhaustedWindowReportsAHundredPercentUsed() throws {
        let limit = try XCTUnwrap(parse(["monthly": ["status": "limited", "percent": 100.0]]))
        let window = try XCTUnwrap(limit.monthly)

        XCTAssertEqual(window.usedPercent, 100)
    }
}
