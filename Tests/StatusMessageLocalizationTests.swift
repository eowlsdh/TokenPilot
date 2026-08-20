import XCTest
@testable import TokenCore

/// Provider status messages are the sentence a user reads when a provider is not behaving, in the
/// Overview row and in the Setup Guide. 35 of the 57 in the app reached a Korean or Japanese user
/// in English, which is the worst possible moment to switch languages on someone.
///
/// This sweeps the adapters for their literals rather than pinning a hand-written list, so a new
/// message cannot ship untranslated by being forgotten.
final class StatusMessageLocalizationTests: XCTestCase {
    /// Markers that are deliberately the same in every language. They are visual flags, like the
    /// menu bar's E/M/S suffixes, and translating them would weaken exactly the labels that exist
    /// to stop mock or unofficial data being mistaken for real quota.
    private static let neutralMarkers = ["MOCK", "STALE", "EXPERIMENTAL", "UNOFFICIAL", "LOCAL", "EST"]

    func testEveryAdapterStatusMessageIsTranslated() throws {
        let messages = try Self.statusMessageLiterals()
        XCTAssertGreaterThan(messages.count, 40, "the sweep found suspiciously few messages; has the shape changed?")

        var untranslated: [String] = []
        for message in messages.sorted() {
            let korean = TokenPilotLocalizer.localized(message, language: .ko)
            if korean == message, !Self.isAcceptablyIdentical(message) {
                untranslated.append(message)
            }
        }

        XCTAssertTrue(
            untranslated.isEmpty,
            "these provider status messages would reach a Korean user in English:\n" + untranslated.joined(separator: "\n")
        )
    }

    func testTranslationsExistForEveryShippedLanguage() throws {
        for message in try Self.statusMessageLiterals() where !Self.isAcceptablyIdentical(message) {
            for language in TokenPilotLanguage.allCases where language != .system && language != .en {
                let localized = TokenPilotLocalizer.localized(message, language: language)
                XCTAssertNotEqual(localized, message, "\(message) is untranslated in \(language)")
            }
        }
    }

    /// The honesty markers survive translation, so a warning cannot be softened into a phrase a
    /// reader might skim past.
    func testHonestyMarkersSurviveTranslation() {
        let marked = [
            "MOCK · sample data",
            "STALE · older than 5 minutes",
            "EXPERIMENTAL · UNOFFICIAL · Claude OAuth usage"
        ]

        for message in marked {
            for language in TokenPilotLanguage.allCases where language != .system {
                let localized = TokenPilotLocalizer.localized(message, language: language)
                for marker in Self.neutralMarkers where message.contains(marker) {
                    XCTAssertTrue(
                        localized.contains(marker),
                        "\(marker) must stay legible in \(language): \(localized)"
                    )
                }
            }
        }
    }

    /// A message that is genuinely the same in every language — a bare product name, or one whose
    /// words are all product names — is not a translation failure.
    private static func isAcceptablyIdentical(_ message: String) -> Bool {
        let productOnly: Set<String> = ["MiniMax Token Plan", "OpenCode Bar"]
        return productOnly.contains(message)
    }

    private static func statusMessageLiterals() throws -> Set<String> {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        var found: Set<String> = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            found.formUnion(literals(in: text, after: "statusMessage: \""))
            found.formUnion(literals(in: text, after: "statusMessage = \""))
            found.formUnion(ternaryLiterals(in: text))
        }
        return found
    }

    /// Pulls the string that starts right after `marker`, stopping at the closing quote. Skips
    /// anything with an escape or an interpolation, which cannot be a lookup key anyway.
    private static func literals(in text: String, after marker: String) -> [String] {
        var results: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let start = text.range(of: marker, range: searchRange) {
            searchRange = start.upperBound..<text.endIndex
            guard let end = text[start.upperBound...].firstIndex(of: "\"") else { continue }
            let value = String(text[start.upperBound..<end])
            if value.count >= 3, !value.contains("\\") {
                results.append(value)
            }
        }
        return results
    }

    /// `statusMessage: isStale ? "a" : "b"` — both arms are shown to a user.
    private static func ternaryLiterals(in text: String) -> [String] {
        var results: [String] = []
        for line in text.split(separator: "\n") where line.contains("statusMessage") && line.contains("?") {
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
            for (index, part) in quoted.enumerated() where index % 2 == 1 {
                let value = String(part)
                if value.count >= 3, !value.contains("\\") {
                    results.append(value)
                }
            }
        }
        return results
    }
}
