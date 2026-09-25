import XCTest
@testable import TokenCore

/// Alert rules used to come only from a migration filtering on `provider == .claude`, so everything
/// else the app measured was shown on screen and never warned — the one thing a limit monitor
/// exists to do. `CapacityAlertReconciler` closes that; these tests keep the catalogue it works
/// from honest, so a new provider window cannot quietly join the list of things that never alert.
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
                && CapacityAlertCatalogue.notAlertableAtTheEvidenceLevel[key] == nil
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

    /// The catalogue is **not** derivable from `CapacitySeriesID`'s semantics table, which was the
    /// next change I was about to make. The table says a duration is *permitted*
    /// (`optionalExact(300)`); it does not say whether the factory emits it. Claude's windows are
    /// built with `durationMinutes: nil` while opencode's rolling window carries 300, so deriving
    /// from the table would have produced a Claude rule identified by a duration no observation
    /// carries — a rule that looks right and can never fire.
    ///
    /// This asserts the property that actually matters instead: every alertable entry names an
    /// identity the factory really emits, duration included.
    func testEveryAlertableEntryMatchesAnIdentityTheFactoryEmits() {
        let emitted = Self.seriesIdentities()

        for entry in CapacityAlertCatalogue.alertableSeries {
            let match = emitted.contains {
                $0.provider == entry.provider
                    && $0.windowID == entry.providerWindowID
                    && $0.duration == entry.durationMinutes
            }
            XCTAssertTrue(
                match,
                "\(entry.provider.rawValue)/\(entry.providerWindowID) duration=\(String(describing: entry.durationMinutes)) is not an identity the factory emits"
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

    /// Every provider the catalogue calls alertable must be a provider the app actually measures.
    /// An entry for something never observed would be a rule that quietly watches nothing.
    ///
    /// Coverage itself is asserted in `CapacityAlertReconcilerTests`, from behaviour rather than
    /// from a literal — an earlier version of this test compared against a hardcoded `[.claude]`
    /// and would have gone on passing after the gap closed, reporting a state that was no longer
    /// true.
    func testEveryAlertableProviderIsOneTheAppMeasures() throws {
        let measured = Set(try Self.seriesConstructions().map(\.0))
        let alertable = Set(CapacityAlertCatalogue.alertableSeries.map(\.provider))

        XCTAssertTrue(
            alertable.isSubset(of: measured),
            "alertable but never measured: \(alertable.subtracting(measured).map(\.rawValue).sorted())"
        )
        XCTAssertGreaterThan(alertable.count, 5, "alert coverage should span more than a couple of providers")
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
        seriesIdentities().map { ($0.provider, $0.windowID) }
    }

    /// Provider, window, and **duration** — the duration is part of a series identity, so a
    /// catalogue entry that omits one the factory emits (or adds one it does not) describes a
    /// series that will never receive an observation.
    private static func seriesIdentities() -> [(provider: Provider, windowID: String, duration: Int?)] {
        guard let lines = try? observationFactorySource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init) else { return [] }
        var found: [(Provider, String, Int?)] = []

        for (index, line) in lines.enumerated() {
            guard let windowID = value(after: "providerWindowID:", in: line) else { continue }
            // The provider and duration sit on this line or a few around it, inside the same call.
            let before = lines[max(0, index - 6)...index].reversed()
            guard let providerRaw = before.compactMap({ value(after: "provider: .", in: $0, quoted: false) }).first,
                  let provider = Provider(rawValue: providerRaw) else { continue }
            let after = lines[index..<min(lines.count, index + 4)]
            let durationRaw = ([line] + after).compactMap { value(after: "durationMinutes:", in: $0, quoted: false) }.first
            found.append((provider, windowID, durationRaw.flatMap { Int($0.replacingOccurrences(of: "_", with: "")) }))
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
        let identifier = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return identifier.isEmpty ? nil : String(identifier)
    }
}
