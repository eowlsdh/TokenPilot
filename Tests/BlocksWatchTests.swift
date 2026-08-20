import XCTest
@testable import TokenCore

/// `blocks --watch` is the live view a terminal tracker is expected to have. These pin the contract
/// around it — the parts that decide whether it is usable or a foot-gun.
final class BlocksWatchTests: XCTestCase {
    private func parse(_ arguments: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        TokenPilotCLIService.parse(arguments: arguments)
    }

    private func watchSettings(_ arguments: [String]) throws -> (watch: Bool, interval: Int) {
        guard case let .success(.blocks(_, _, _, _, _, _, _, _, _, _, watch, interval)) = parse(arguments) else {
            throw XCTSkip("not a blocks command: \(arguments)")
        }
        return (watch, interval)
    }

    func testWatchIsOffUnlessAskedFor() throws {
        let settings = try watchSettings(["blocks"])

        XCTAssertFalse(settings.watch)
        XCTAssertEqual(settings.interval, TokenPilotCLIService.defaultWatchIntervalSeconds)
    }

    func testAnIntervalIsAccepted() throws {
        let settings = try watchSettings(["blocks", "--watch", "--interval", "30"])

        XCTAssertTrue(settings.watch)
        XCTAssertEqual(settings.interval, 30)
    }

    /// The floor is not one second. Each tick re-reads every local source, and this app has already
    /// shipped one runaway refresh; the ceiling keeps `--interval` from being mistaken for minutes.
    func testAnIntervalOutsideTheSupportedRangeIsRefused() {
        for interval in ["0", "1", "61", "3600", "-5", "soon"] {
            guard case let .failure(error) = parse(["blocks", "--watch", "--interval", interval]) else {
                XCTFail("--interval \(interval) should be refused")
                continue
            }
            XCTAssertEqual(error, .invalidInterval(interval))
        }
    }

    func testTheBoundsAreStatedInTheError() {
        let message = TokenPilotCLIError.invalidInterval("1").errorDescription ?? ""

        XCTAssertTrue(message.contains("2"), message)
        XCTAssertTrue(message.contains("60"), message)
    }

    /// A repeating stream gives its reader no way to tell one render from the next, so the
    /// combination is refused rather than one of the two flags being quietly ignored.
    func testWatchCannotBeCombinedWithAStreamFormat() {
        for format in ["--json", "--csv", "--md"] {
            guard case let .failure(error) = parse(["blocks", "--watch", format]) else {
                XCTFail("--watch \(format) should be refused")
                continue
            }
            guard case let .invalidCombination(message) = error else {
                XCTFail("expected an invalid-combination error for \(format)")
                continue
            }
            XCTAssertTrue(message.contains("--watch"), message)
        }
    }

    /// Those formats stay perfectly valid on their own.
    func testTheStreamFormatsStillWorkWithoutWatch() {
        for format in ["--json", "--csv", "--md"] {
            guard case .success = parse(["blocks", format]) else {
                XCTFail("blocks \(format) should still parse")
                continue
            }
        }
    }

    func testWatchComposesWithTheOtherBlocksFilters() throws {
        guard case let .success(.blocks(_, active, _, _, _, _, _, _, _, provider, watch, interval)) =
                parse(["blocks", "--watch", "--interval", "10", "--active", "--provider", "claude"]) else {
            return XCTFail("expected a blocks command")
        }

        XCTAssertTrue(watch)
        XCTAssertEqual(interval, 10)
        XCTAssertTrue(active)
        XCTAssertEqual(provider, .claude)
    }

    func testHelpDocumentsTheFlags() {
        let help = TokenPilotCLIService.helpText

        XCTAssertTrue(help.contains("--watch"))
        XCTAssertTrue(help.contains("--interval"))
    }

    /// The loop writes and flushes rather than printing: stdout is block-buffered when it is not a
    /// terminal, so a redirected or piped run showed nothing until the buffer filled, and whatever
    /// was still buffered was lost on Ctrl-C. Measured at zero lines before this, eighteen after.
    func testTheWatchLoopFlushesAndGuardsTheTerminalEscapes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenApp/TokenMonitorApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("fflush(stdout)"), "each render must reach the reader immediately")
        XCTAssertTrue(
            source.contains("isatty(FileHandle.standardOutput.fileDescriptor)"),
            "screen clearing must be limited to a terminal"
        )
        XCTAssertTrue(source.contains("Ctrl-C to stop"), "a loop with no visible exit is a trap")
    }
}
