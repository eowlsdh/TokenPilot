import XCTest
@testable import TokenCore

/// Alert rules exist for Claude's two windows and DeepSeek's balance, and nothing else: the legacy
/// migration filters on `provider == .claude`. Everything else the app measures is shown on screen
/// and never warns, which is the one thing a limit monitor exists to do.
///
/// These tests do not fix that — wiring it touches persisted delivery state and the migration
/// merge, which overwrites by rule ID and would reset a user's own thresholds. They pin the size and
/// shape of the gap so it cannot be forgotten, and so a new provider window cannot quietly join the
/// list of things that never alert.
final class CapacityAlertCoverageTests: XCTestCase {
    private static func observationFactorySource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenCore/Services/TokenPilotServices.swift"),
            encoding: .utf8
        )
    }

    /// Every series the observation factory builds is either something an alert can watch or
    /// something we decided against, with the reason written down. "Forgot" is not a third option.
    ///
    /// Scans whole `CapacitySeriesID(...)` constructions rather than single lines: eight of the
    /// twenty-four are written across several lines, including Claude's and every Codex window, and
    /// a line-at-a-time scan skipped exactly those while looking like it covered everything.
    func testEverySeriesTheFactoryBuildsIsClassified() throws {
        let constructions = try Self.seriesConstructions()

        XCTAssertGreaterThanOrEqual(
            constructions.count, 22,
            "the scan found too few series; has the factory's shape changed?"
        )

        let unclassified = constructions.filter { provider, windowID in
            let alertable = CapacityAlertCatalogue.alertableSeries.contains {
                $0.provider == provider && $0.providerWindowID == windowID
            }
            let key = "\(provider.rawValue)/\(windowID)"
            return !alertable
                && CapacityAlertCatalogue.deliberatelyNotAlertable[key] == nil
                && CapacityAlertCatalogue.alertableOnlyFromObservedSeries[key] == nil
                && CapacityAlertCatalogue.needsAConditionKindThatDoesNotExistYet[key] == nil
        }

        XCTAssertTrue(
            unclassified.isEmpty,
            "these series are neither alertable nor recorded as deliberately not:\n"
                + unclassified.map { "\($0.rawValue)/\($1)" }.joined(separator: "\n")
        )
    }

    /// Every catalogue entry has to resolve to a real series identity, or a rule built from it would
    /// silently watch nothing.
    func testEveryCatalogueEntryResolvesToASeries() {
        for entry in CapacityAlertCatalogue.alertableSeries {
            XCTAssertNotNil(entry.seriesID, "\(entry.provider.rawValue)/\(entry.providerWindowID)")
        }
    }

    /// Resolving to a series is not the same as being able to watch it. `CapacityAlertRule` rejects
    /// a percent-threshold rule whose series is counted in anything but percent, so an entry can
    /// look alertable and be unbuildable — which is exactly what Gemini's daily *request* cap was
    /// until this test existed.
    func testEveryAlertableEntryCanActuallyBuildARule() throws {
        for entry in CapacityAlertCatalogue.alertableSeries {
            let seriesID = try XCTUnwrap(entry.seriesID)
            XCTAssertNoThrow(
                try CapacityAlertRule(
                    provider: entry.provider,
                    seriesID: seriesID,
                    authority: .providerReported,
                    stability: .supported,
                    enabled: true,
                    routing: CapacityAlertRouting(macOS: true, telegram: false, discord: false),
                    condition: CapacityAlertCatalogue.defaultThresholds
                ),
                "\(entry.provider.rawValue)/\(entry.providerWindowID) is listed as alertable but no rule can be built for it"
            )
        }
    }

    /// A balance, a context window, or a running cost is not a quota. Alerting on them would either
    /// fire constantly or claim a limit the provider never stated.
    func testNoBalanceOrContextSeriesIsMarkedAlertable() {
        for entry in CapacityAlertCatalogue.alertableSeries {
            XCTAssertNotEqual(entry.kind, .balance, "\(entry.providerWindowID)")
            XCTAssertNotEqual(entry.kind, .context, "\(entry.providerWindowID)")
        }
    }

    /// The gap, stated as a number. When rules stop being Claude-only this test is what says so.
    func testAlertsCurrentlyReachFarFewerProvidersThanTheAppMeasures() {
        let measured = Set(CapacityAlertCatalogue.alertableSeries.map(\.provider))
        let alerted: Set<Provider> = [.claude]

        XCTAssertTrue(alerted.isSubset(of: measured))
        XCTAssertGreaterThan(
            measured.subtracting(alerted).count, 5,
            "if this dropped, alert coverage grew — update the expectation and the note above"
        )
    }

    /// A freshly created rule should warn before the wall and at it, and say when the window turned
    /// over. Half a window is noise for most people, so it stays off until asked for.
    func testDefaultThresholdsWarnBeforeAndAtTheLimit() {
        let thresholds = CapacityAlertCatalogue.defaultThresholds.enabledPercentThresholds

        XCTAssertTrue(thresholds.contains(.reset))
        XCTAssertEqual(thresholds.compactMap(\.percent).sorted(), [80, 100])
    }

    /// Every series the factory names, as (provider, providerWindowID).
    ///
    /// Anchored on `providerWindowID:` and searching backwards for the `provider:` it belongs to.
    /// Anchoring on `CapacitySeriesID(` instead missed eight of the twenty-four, because Claude's
    /// and Codex's windows reach the initialiser through a local helper rather than constructing it
    /// in place — and the scan looked complete while skipping exactly those.
    private static func seriesConstructions() throws -> [(Provider, String)] {
        let lines = try observationFactorySource().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [(Provider, String)] = []

        for (index, line) in lines.enumerated() {
            guard let windowID = value(after: "providerWindowID:", in: line) else { continue }
            // The provider is either on this line or a few above it, inside the same call.
            let window = lines[max(0, index - 6)...index].reversed()
            guard let providerRaw = window.compactMap({ value(after: "provider: .", in: $0, quoted: false) }).first,
                  let provider = Provider(rawValue: providerRaw) else { continue }
            found.append((provider, windowID))
        }
        return found
    }

    /// Pulls `provider: .opencode,` or `providerWindowID: "rate-limit"` out of a construction.
    private static func value(after marker: String, in text: String, quoted: Bool = true) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...].drop { $0 == " " || $0 == "\n" }
        if quoted {
            guard rest.first == "\"", let end = rest.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(rest[rest.index(after: rest.startIndex)..<end])
        }
        let identifier = rest.prefix { $0.isLetter || $0.isNumber }
        return identifier.isEmpty ? nil : String(identifier)
    }
}
