import XCTest
@testable import TokenCore

/// Numbers and dates as they reach the screen: in the app's language, and at a precision a person
/// reads rather than the one the value is stored at.
final class DisplayFormattingTests: XCTestCase {
    /// A fixed four places read "$1.4200".
    func testCostShowsCentsUnlessBelowACent() {
        XCTAssertEqual(TokenPilotFormatters.cost(Decimal(string: "1.42") ?? 0), "$1.42")
        XCTAssertEqual(TokenPilotFormatters.cost(Decimal(string: "12.5") ?? 0), "$12.50")
        XCTAssertEqual(TokenPilotFormatters.cost(0), "$0.00")
        XCTAssertEqual(TokenPilotFormatters.cost(Decimal(string: "0.0042") ?? 0), "$0.0042", "a fraction of a cent must not read $0.00")
    }

    /// The seven-day charts showed "Tue Wed … Mon" and "Peak: Mon" in every language.
    func testWeekdaysAreShownInTheAppLanguage() {
        XCTAssertEqual(LocalizedDateLabels.weekday(englishAbbreviation: "Mon", language: .ko), "월")
        XCTAssertEqual(LocalizedDateLabels.weekday(englishAbbreviation: "Sun", language: .ja), "日")
        XCTAssertEqual(LocalizedDateLabels.weekday(englishAbbreviation: "Fri", language: .en), "Fri")
        XCTAssertEqual(LocalizedDateLabels.weekday(englishAbbreviation: "2026-09-28", language: .ko), "2026-09-28", "anything else passes through")
    }

    /// "리셋까지 51m 57s" sat beside "리셋 56분" on the same card.
    func testDurationUnitsFollowTheLanguage() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reset = now.addingTimeInterval(51 * 60 + 57)
        XCTAssertEqual(TokenPilotFormatters.countdown(until: reset, now: now, language: .ko), "51분 57초")
        XCTAssertEqual(TokenPilotFormatters.countdown(until: reset, now: now, language: .en), "51m 57s")
        XCTAssertEqual(TokenPilotFormatters.countdown(until: reset, now: now, showsSeconds: false, language: .ja), "52分")
        XCTAssertEqual(TokenPilotFormatters.compactRemainingTime(until: now.addingTimeInterval(2 * 3_600 + 5), now: now, language: .ko), "2시간")
        XCTAssertEqual(TokenPilotFormatters.compactRemainingTime(until: now.addingTimeInterval(15 * 86_400), now: now, language: .zhHans), "15天")
    }
}
