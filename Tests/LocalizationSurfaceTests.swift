import XCTest
@testable import TokenCore

/// TokenPilot carries two localization surfaces: the string catalog Xcode compiles, and the Swift
/// fallback tables. They drifted apart without anything noticing, and the catalog the shipped app
/// carried could not be read at all. These pin both halves of that.
final class LocalizationSurfaceTests: XCTestCase {
    private static let shippedLanguages = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func catalogURL() -> URL {
        projectRoot().appendingPathComponent("Sources/TokenApp/Resources/Localizable.xcstrings")
    }

    private func catalog() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: catalogURL())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])

        var out: [String: [String: String]] = [:]
        for (key, entry) in strings {
            guard let localizations = entry["localizations"] as? [String: [String: Any]] else { continue }
            for (locale, localization) in localizations {
                if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                    out[key, default: [:]][locale] = value
                }
            }
        }
        return out
    }

    // MARK: - Reachability

    /// The defect this file was written for. `build.sh` verifies `Localizable.xcstrings` is inside
    /// the app, and it is — nested one level down in the SwiftPM resource bundle, where
    /// `url(forResource:)` does not look. The check passed while the catalog was unreadable.
    func testTheCatalogIsFoundWhereTheShippedAppKeepsIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenpilot-localization-\(UUID().uuidString)")
        let app = root.appendingPathComponent("TokenPilot.app")
        let nested = app.appendingPathComponent("Contents/Resources/\(TokenPilotLocalizer.resourceBundleName)")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(contentsOf: catalogURL()).write(to: nested.appendingPathComponent("Localizable.xcstrings"))

        XCTAssertNil(
            Bundle(url: app)?.url(forResource: "Localizable", withExtension: "xcstrings"),
            "if this ever starts resolving, the search below is no longer the thing keeping the catalog readable"
        )
        XCTAssertEqual(TokenPilotLocalizer.catalogURLs(searchingFrom: [app]).count, 1)
    }

    /// A neighbouring app's catalog must never be picked up, which is why the bundle is matched by
    /// name instead of by scanning for `.bundle` children.
    func testAnUnrelatedBundleBesideTheAppIsIgnored() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenpilot-localization-\(UUID().uuidString)")
        let app = root.appendingPathComponent("TokenPilot.app")
        let stranger = root.appendingPathComponent("SomeoneElse.bundle")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(contentsOf: catalogURL()).write(to: stranger.appendingPathComponent("Localizable.xcstrings"))

        XCTAssertTrue(TokenPilotLocalizer.catalogURLs(searchingFrom: [app]).isEmpty)
    }

    /// `build.sh` copies the resource bundle by name and the localizer looks for it by name. A
    /// package or target rename would silently break the catalog again, so the two are asserted equal
    /// rather than left to agree by luck.
    func testTheResourceBundleNameMatchesTheBuildScript() throws {
        let script = try String(contentsOf: projectRoot().appendingPathComponent("build.sh"), encoding: .utf8)

        XCTAssertTrue(
            script.contains("RESOURCE_BUNDLE_NAME=\"\(TokenPilotLocalizer.resourceBundleName)\""),
            "build.sh and TokenPilotLocalizer.resourceBundleName must name the same bundle"
        )
    }

    /// The Developer ID app ships a string catalog, not `.lproj` folders, so macOS had no way to see
    /// that it speaks five languages: `Bundle.localizations` read `["en"]` while the Xcode build of
    /// the same app read all five. Declaring them keeps the offer of a per-app language honest, and
    /// asserting against the enum means a sixth language cannot be added in only one of the places.
    func testTheAppDeclaresEveryLanguageItActuallySpeaks() throws {
        let plist = try String(contentsOf: projectRoot().appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        let offered = TokenPilotLanguage.allCases.compactMap(\.localeIdentifier).sorted()

        XCTAssertEqual(offered, Self.shippedLanguages.sorted())
        XCTAssertTrue(plist.contains("<key>CFBundleLocalizations</key>"))
        for language in offered {
            XCTAssertTrue(plist.contains("<string>\(language)</string>"), "Info.plist does not declare \(language)")
        }
    }

    /// Proves the catalog is actually consulted at runtime rather than merely present: these keys
    /// exist only in the catalog, so an answer other than the key itself can only have come from it.
    func testAStringOnlyTheCatalogCarriesIsServed() {
        XCTAssertEqual(TokenPilotLocalizer.localized("TokenPilot limit reached", language: .ko), "TokenPilot 한도 도달")
        XCTAssertEqual(TokenPilotLocalizer.localized("TokenPilot limit reached", language: .zhHant), "TokenPilot 已達到限制")
    }

    // MARK: - Coverage

    func testEveryCatalogStringIsTranslatedIntoEveryShippedLanguage() throws {
        let catalog = try catalog()
        XCTAssertGreaterThan(catalog.count, 700)

        for (key, values) in catalog {
            for language in Self.shippedLanguages {
                let value = values[language]
                XCTAssertNotNil(value, "\(key) has no \(language) translation")
                XCTAssertFalse(value?.isEmpty ?? true, "\(key) has an empty \(language) translation")
            }
        }
    }

    /// The catalog is JSON, and JSON silently keeps one of two entries that share a key. `Weekly
    /// window` was in there twice with different Korean, so the two builds disagreed on which one a
    /// user saw. Duplicates have to be caught textually — parsing the file hides them.
    func testNoStringIsDeclaredTwice() throws {
        let source = try String(contentsOf: catalogURL(), encoding: .utf8)
        var counts: [String: Int] = [:]

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("    \""), let range = line.range(of: "\" :", options: .backwards)
                    ?? line.range(of: "\":", options: .backwards) else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 5)..<range.lowerBound])
            counts[key, default: 0] += 1
        }

        let duplicated = counts.filter { $0.value > 1 }.keys.sorted()
        XCTAssertTrue(duplicated.isEmpty, "declared more than once: \(duplicated)")
    }

    // MARK: - Agreement between the two surfaces

    /// Both surfaces answer for most keys, and whichever one a given build reads has to say the same
    /// thing. Twelve had drifted; a build.sh app and an Xcode app showed different Korean.
    func testTheCatalogAndTheFallbackTablesAgree() throws {
        let languages: [(String, TokenPilotLanguage)] = [
            ("en", .en), ("ja", .ja), ("ko", .ko), ("zh-Hans", .zhHans), ("zh-Hant", .zhHant)
        ]
        var compared = 0

        for (key, values) in try catalog() {
            for (code, language) in languages {
                guard let catalogValue = values[code],
                      let tableValue = TokenPilotLocalizer.fallbackValue(key, language: language) else { continue }
                compared += 1
                XCTAssertEqual(tableValue, catalogValue, "\(key) [\(code)] differs between the two surfaces")
            }
        }

        XCTAssertGreaterThan(compared, 3_000, "the surfaces overlap far less than expected; check the extraction")
    }

    /// The catalog is not complete on its own — 218 strings live only in the tables.
    func testAStringMissingFromTheCatalogStillComesBackTranslated() {
        let key = "At least one provider must stay enabled."

        for language in [TokenPilotLanguage.ko, .ja, .zhHans, .zhHant] {
            let localized = TokenPilotLocalizer.localized(key, language: language)
            XCTAssertNotEqual(localized, key, "\(language) fell all the way through to the raw key")
            XCTAssertNotEqual(
                localized,
                TokenPilotLocalizer.localized(key, language: .en),
                "\(language) came back in English while a translation exists"
            )
        }
    }

    /// The shared table is the one surface that carries all five languages per entry, and nothing
    /// required it to. Since it no longer borrows English for a language it lacks, a half-filled row
    /// would drop to the per-language table below it — or to the raw English key.
    func testTheSharedTableCarriesEveryLanguageForEveryEntry() throws {
        let source = try String(
            contentsOf: projectRoot().appendingPathComponent("Sources/TokenCore/TokenPilotLocalization.swift"),
            encoding: .utf8
        )
        let rows = source
            .split(separator: "\n")
            .filter { $0.contains("[.en:") }
        XCTAssertGreaterThan(rows.count, 500)

        for row in rows {
            for language in [".ko:", ".ja:", ".zhHans:", ".zhHant:"] {
                XCTAssertTrue(row.contains(language), "a shared-table row is missing \(language): \(row.prefix(70))")
            }
        }
    }

    // MARK: - Priority

    /// Both halves of the catalog lookup used to answer in English when the requested language was
    /// missing, which reads as harmless and is not: English is filled in for every key, so the
    /// translation tables were never reached and the gap was invisible. Neither half may do it.
    func testTheCatalogNeverAnswersInEnglishForAnotherLanguage() {
        let catalog = ["en": ["Overview": "Overview"], "ko": ["Overview": "개요"]]

        XCTAssertEqual(TokenPilotLocalizer.catalogValue("Overview", langCode: "ko", in: catalog), "개요")
        XCTAssertEqual(TokenPilotLocalizer.catalogValue("Overview", langCode: "en", in: catalog), "Overview")
        XCTAssertNil(
            TokenPilotLocalizer.catalogValue("Overview", langCode: "zh-Hant", in: catalog),
            "a language the catalog lacks must fall through to the tables, not borrow English"
        )
    }

    /// The same rule for the compiled `.lproj` half, which is what an Xcode-built app reads. This is
    /// the shape that shipped: `zh-Hant.lproj` carried 135 of 746 keys, and every one of the other
    /// 611 resolved to English out of the app's development region.
    func testACompiledLanguageBundleDoesNotBorrowEnglish() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenpilot-lproj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        for (language, contents) in [
            ("en", "\"Overview\" = \"Overview\";\n\"Settings\" = \"Settings\";\n"),
            ("zh-Hant", "\"Settings\" = \"設置\";\n")
        ] {
            let folder = root.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try contents.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }

        let base = try XCTUnwrap(Bundle(url: root))
        let traditional = TokenPilotLocalizer.candidateBundles(for: .zhHant, bases: [base])

        XCTAssertEqual(TokenPilotLocalizer.bundleValue("Settings", in: traditional), "設置")
        XCTAssertNil(
            TokenPilotLocalizer.bundleValue("Overview", in: traditional),
            "a key the language bundle lacks must fall through, not come back in English"
        )
        XCTAssertEqual(
            TokenPilotLocalizer.bundleValue("Overview", in: TokenPilotLocalizer.candidateBundles(for: .en, bases: [base])),
            "Overview"
        )
    }

    // MARK: - Coverage

    /// Every other guard in this file starts from a surface that already exists — the catalog, or the
    /// shared table — and checks it is complete. A string that reached the localizer while being in
    /// *neither* surface is invisible to all of them, and twenty of them shipped that way: banner
    /// messages, provider setup guidance and the whole `stats`/`blocks` CLI vocabulary, all reaching
    /// a Korean user in English. This one starts from the call sites instead.
    func testEveryLocalizedLiteralInTheSourceIsDeclaredForEveryShippedLanguage() throws {
        // English is the development region: the key *is* the English string, so `en` needs no
        // declaration and demanding one only produces noise. And a key with no letters in it —
        // an em dash placeholder, a unit — has nothing to translate.
        let required = Self.shippedLanguages.filter { $0 != "en" }
        let keys = try localizedLiteralsInSource()
            .filter { $0.key.contains(where: \.isLetter) }

        XCTAssertGreaterThan(keys.count, 400, "the source scan found almost no localized literals; check the walk")

        let catalog = try catalog()
        var offenders: [String] = []

        for (key, site) in keys.sorted(by: { $0.key < $1.key }) {
            let undeclared = required.filter { code in
                if let value = catalog[key]?[code], !value.isEmpty { return false }
                guard let language = Self.language(forCode: code) else { return true }
                return TokenPilotLocalizer.fallbackValue(key, language: language) == nil
            }
            if !undeclared.isEmpty {
                offenders.append("\(site): \"\(key)\" — missing \(undeclared.joined(separator: ", "))")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "these strings reach the localizer but no surface declares them, so they ship in English:\n"
                + offenders.joined(separator: "\n")
        )
    }

    private static func language(forCode code: String) -> TokenPilotLanguage? {
        TokenPilotLanguage.allCases.first { $0.bundleCode == code }
    }

    /// `t("…")` in the app layer and `localized("…")` in the services both land on
    /// `TokenPilotLocalizer`. A key built at runtime cannot be scanned for and is out of scope here.
    private func localizedLiteralsInSource() throws -> [String: String] {
        let sources = projectRoot().appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"\b(?:t|localized)\(\s*"((?:[^"\\]|\\.)*)""#)

        var found: [String: String] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let literal = Range(match.range(at: 1), in: text) else { continue }
                let key = Self.unescaped(String(text[literal]))
                guard !key.isEmpty, found[key] == nil else { continue }
                let line = text[text.startIndex..<literal.lowerBound].filter { $0 == "\n" }.count + 1
                found[key] = "\(url.lastPathComponent):\(line)"
            }
        }

        return found
    }

    private static func unescaped(_ literal: String) -> String {
        literal
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
