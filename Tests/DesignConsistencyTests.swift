import XCTest
@testable import TokenCore

// MARK: - Shared risk thresholds

final class CapacityRiskThresholdTests: XCTestCase {
    func testUsedPercentBoundaries() {
        XCTAssertEqual(CapacityRisk.forUsedPercent(0), .normal)
        XCTAssertEqual(CapacityRisk.forUsedPercent(69), .normal)
        XCTAssertEqual(CapacityRisk.forUsedPercent(70), .warning)
        XCTAssertEqual(CapacityRisk.forUsedPercent(84), .warning)
        XCTAssertEqual(CapacityRisk.forUsedPercent(85), .critical)
        XCTAssertEqual(CapacityRisk.forUsedPercent(100), .critical)
    }

    func testRemainingPercentIsTheMirrorOfUsedPercent() {
        for used in 0...100 {
            XCTAssertEqual(
                CapacityRisk.forRemainingPercent(100 - used),
                CapacityRisk.forUsedPercent(used),
                "remaining \(100 - used) and used \(used) must agree"
            )
        }
    }

    func testRemainingPercentClampsOutOfRangeInput() {
        XCTAssertEqual(CapacityRisk.forRemainingPercent(-10), .critical)
        XCTAssertEqual(CapacityRisk.forRemainingPercent(140), .normal)
    }

    /// The assessment pipeline must not carry its own copy of the thresholds.
    func testCapacityAssessmentUsesTheSharedThresholds() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        func risk(usedPercent: Int) throws -> CapacityRisk {
            let series = try CapacitySeriesID(
                provider: .claude,
                providerWindowID: "five-hour",
                kind: .fixedReset,
                unit: .percent,
                durationMinutes: 300
            )
            let observation = try CapacityObservation(
                seriesID: series,
                observedAt: now,
                value: try CapacityValue(usedPercent: usedPercent),
                authority: .providerReported,
                stability: .supported,
                freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
                comparability: .comparable,
                parserRevision: "thresholdV1",
                now: now
            )
            return CapacityAssessmentService().assess(observation, now: now).risk
        }

        XCTAssertEqual(try risk(usedPercent: 69), .normal)
        XCTAssertEqual(try risk(usedPercent: 70), .warning)
        XCTAssertEqual(try risk(usedPercent: 85), .critical)
    }

    /// Regression for the split the design review found: the status line used to
    /// warn from 50% used while the popover stayed calm until 70%.
    func testStatuslineColorsFollowTheSharedThresholds() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        func ansiPrefix(usedPercent: Int) throws -> String {
            let series = try CapacitySeriesID(
                provider: .claude,
                providerWindowID: "five-hour",
                kind: .fixedReset,
                unit: .percent,
                durationMinutes: 300
            )
            let observation = try CapacityObservation(
                seriesID: series,
                observedAt: now,
                value: try CapacityValue(usedPercent: usedPercent),
                authority: .providerReported,
                stability: .supported,
                freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
                comparability: .comparable,
                parserRevision: "thresholdV1",
                now: now
            )
            let assessment = CapacityAssessmentService().assess(observation, now: now)
            let line = StatuslineService.render(
                events: [],
                windows: StatuslineService.windows(from: [assessment]),
                components: [.capacity],
                colorized: true,
                now: now,
                calendar: calendar
            )
            return String(line.prefix(5))
        }

        XCTAssertEqual(try ansiPrefix(usedPercent: 85), "\u{001B}[31m")
        XCTAssertEqual(try ansiPrefix(usedPercent: 84), "\u{001B}[33m")
        XCTAssertEqual(try ansiPrefix(usedPercent: 70), "\u{001B}[33m")
        XCTAssertEqual(try ansiPrefix(usedPercent: 69), "\u{001B}[32m")
        XCTAssertEqual(try ansiPrefix(usedPercent: 10), "\u{001B}[32m")
    }
}

// MARK: - Localized date labels

final class LocalizedDateLabelsTests: XCTestCase {
    private var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var august19: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 14, minute: 0))!
    }

    func testMonthAbbreviationFollowsTheAppLanguage() {
        let english = LocalizedDateLabels.monthAbbreviation(for: august19, language: .en, calendar: utcCalendar)
        let korean = LocalizedDateLabels.monthAbbreviation(for: august19, language: .ko, calendar: utcCalendar)
        let japanese = LocalizedDateLabels.monthAbbreviation(for: august19, language: .ja, calendar: utcCalendar)

        XCTAssertEqual(english, "Aug")
        XCTAssertTrue(korean.contains("8"), "Korean month label should be numeric: \(korean)")
        XCTAssertFalse(korean.contains("Aug"), "Korean month label must not fall back to English: \(korean)")
        XCTAssertTrue(japanese.contains("8"), "Japanese month label should be numeric: \(japanese)")
        XCTAssertFalse(japanese.contains("Aug"))
    }

    func testMonthNumberAbbreviationMatchesTheDateVariant() {
        for language in [TokenPilotLanguage.en, .ko, .ja, .zhHans, .zhHant] {
            XCTAssertEqual(
                LocalizedDateLabels.monthAbbreviation(monthNumber: 8, language: language),
                LocalizedDateLabels.monthAbbreviation(for: august19, language: language, calendar: utcCalendar),
                "month-number and date labels disagree for \(language)"
            )
        }
    }

    func testMonthNumberRejectsOutOfRangeValues() {
        XCTAssertEqual(LocalizedDateLabels.monthAbbreviation(monthNumber: nil, language: .en), "")
        XCTAssertEqual(LocalizedDateLabels.monthAbbreviation(monthNumber: 0, language: .en), "")
        XCTAssertEqual(LocalizedDateLabels.monthAbbreviation(monthNumber: 13, language: .en), "")
    }

    func testBlockTimestampCarriesMonthDayAndLocaleHourCycle() {
        let english = LocalizedDateLabels.dayAndTime(for: august19, language: .en, calendar: utcCalendar)
        let korean = LocalizedDateLabels.dayAndTime(for: august19, language: .ko, calendar: utcCalendar)

        XCTAssertTrue(english.contains("19"), english)
        XCTAssertTrue(english.contains("Aug"), english)
        // en resolves to a 12-hour clock; the old hard-coded "HH:mm" could not.
        XCTAssertTrue(english.uppercased().contains("PM"), english)

        XCTAssertTrue(korean.contains("19"), korean)
        XCTAssertTrue(korean.contains("8"), korean)
        XCTAssertFalse(korean.contains("Aug"), korean)
    }

    func testSystemLanguageFollowsTheMacLocale() {
        XCTAssertEqual(LocalizedDateLabels.locale(for: .system), Locale.autoupdatingCurrent)
        XCTAssertEqual(LocalizedDateLabels.locale(for: .ko).identifier, "ko")
    }

    func testRepeatedCallsReturnTheSameLabel() {
        // The formatter cache is shared; repeated calls must stay stable across locales.
        let first = LocalizedDateLabels.monthAbbreviation(for: august19, language: .ko, calendar: utcCalendar)
        _ = LocalizedDateLabels.monthAbbreviation(for: august19, language: .ja, calendar: utcCalendar)
        let second = LocalizedDateLabels.monthAbbreviation(for: august19, language: .ko, calendar: utcCalendar)
        XCTAssertEqual(first, second)
    }
}

// MARK: - Palette contrast

/// Guards the WCAG contrast of the text tokens.
///
/// `TokenPilotDesign` lives in `TokenApp`, which the test target does not link, so
/// the token values are read out of the source file — the same approach the
/// localization catalog tests use.
final class PaletteContrastTests: XCTestCase {
    private static let smallTextMinimum = 4.5

    func testTextTokensMeetSmallTextContrastOnEverySurface() throws {
        let source = try Self.designSystemSource()

        let surfaces = ["cardDefinition", "cardElevatedDefinition", "cardMutedDefinition", "backgroundDefinition"]
        let textTokens = ["textPrimaryDefinition", "textSecondaryDefinition", "textTertiaryDefinition"]

        for appearance in ["light", "dark"] {
            for token in textTokens {
                let foreground = try Self.rgb(token, appearance: appearance, in: source)
                for surface in surfaces {
                    let background = try Self.rgb(surface, appearance: appearance, in: source)
                    let contrast = Self.contrastRatio(foreground, background)
                    XCTAssertGreaterThanOrEqual(
                        contrast,
                        Self.smallTextMinimum,
                        "\(token) on \(surface) (\(appearance)) is \(String(format: "%.2f", contrast)):1, below the 4.5:1 small-text bar"
                    )
                }
            }
        }
    }

    /// The ramp must still read as three steps after the tertiary fix.
    func testTextRampStaysOrderedFromPrimaryToTertiary() throws {
        let source = try Self.designSystemSource()
        for appearance in ["light", "dark"] {
            let card = try Self.rgb("cardDefinition", appearance: appearance, in: source)
            let primary = Self.contrastRatio(try Self.rgb("textPrimaryDefinition", appearance: appearance, in: source), card)
            let secondary = Self.contrastRatio(try Self.rgb("textSecondaryDefinition", appearance: appearance, in: source), card)
            let tertiary = Self.contrastRatio(try Self.rgb("textTertiaryDefinition", appearance: appearance, in: source), card)
            XCTAssertGreaterThan(primary, secondary, "primary must be stronger than secondary (\(appearance))")
            XCTAssertGreaterThan(secondary, tertiary, "secondary must be stronger than tertiary (\(appearance))")
        }
    }

    func testHighContrastVariantsAreAtLeastAsStrongAsTheDefaults() throws {
        let source = try Self.designSystemSource()
        let pairs = [
            ("light", "lightHighContrast", "cardDefinition"),
            ("dark", "darkHighContrast", "cardDefinition")
        ]
        for (appearance, highContrast, surface) in pairs {
            let background = try Self.rgb(surface, appearance: appearance, in: source)
            let backgroundHC = try Self.rgb(surface, appearance: highContrast, in: source)
            let normal = Self.contrastRatio(try Self.rgb("textTertiaryDefinition", appearance: appearance, in: source), background)
            let increased = Self.contrastRatio(try Self.rgb("textTertiaryDefinition", appearance: highContrast, in: source), backgroundHC)
            XCTAssertGreaterThanOrEqual(increased, normal, "increase-contrast tertiary regressed (\(appearance))")
        }
    }

    /// Provider accents label provider names and marks at 11pt, so they are held to the same bar.
    func testProviderAccentsMeetSmallTextContrastInLightAppearance() throws {
        let source = try Self.designSystemSource()
        let card = try Self.rgb("cardDefinition", appearance: "light", in: source)
        let muted = try Self.rgb("cardMutedDefinition", appearance: "light", in: source)

        for provider in Provider.allCases {
            let accent = try Self.accentRGB(provider: provider, appearance: "light", in: source)
            let onCard = Self.contrastRatio(accent, card)
            let onMuted = Self.contrastRatio(accent, muted)
            XCTAssertGreaterThanOrEqual(
                onCard,
                Self.smallTextMinimum,
                "\(provider.rawValue) accent is \(String(format: "%.2f", onCard)):1 on card"
            )
            XCTAssertGreaterThanOrEqual(
                onMuted,
                4.0,
                "\(provider.rawValue) accent is \(String(format: "%.2f", onMuted)):1 on a muted card"
            )
        }
    }

    /// Status colors sit on both card surfaces in both appearances.
    func testStatusColorsMeetSmallTextContrast() throws {
        let source = try Self.designSystemSource()
        for appearance in ["light", "dark"] {
            let card = try Self.rgb("cardDefinition", appearance: appearance, in: source)
            for token in ["dangerDefinition", "warningDefinition", "calmDefinition", "goalDefinition", "trustDefinition"] {
                let color = try Self.rgb(token, appearance: appearance, in: source)
                let contrast = Self.contrastRatio(color, card)
                XCTAssertGreaterThanOrEqual(
                    contrast,
                    Self.smallTextMinimum,
                    "\(token) on card (\(appearance)) is \(String(format: "%.2f", contrast)):1"
                )
            }
        }
    }

    // MARK: helpers

    /// Reads the `case .<provider>: return SemanticColorDefinition(...)` accent arms.
    private static func accentRGB(provider: Provider, appearance: String, in source: String) throws -> (Double, Double, Double) {
        // Match the case arm only, so a comment between the arm and the definition cannot turn this
        // guard into a silent skip.
        guard let accentRange = source.range(of: "private static func accent(for provider: Provider"),
              let caseRange = source.range(of: "case .\(provider.rawValue):", range: accentRange.upperBound..<source.endIndex) else {
            throw XCTSkip("accent arm not found: \(provider.rawValue)")
        }
        let window = String(source[caseRange.upperBound...].prefix(500))
        let regex = try NSRegularExpression(pattern: "\(appearance): rgb\\(([0-9.]+), ([0-9.]+), ([0-9.]+)\\)")
        guard let match = regex.firstMatch(in: window, range: NSRange(window.startIndex..<window.endIndex, in: window)),
              match.numberOfRanges == 4,
              let r = Range(match.range(at: 1), in: window).flatMap({ Double(window[$0]) }),
              let g = Range(match.range(at: 2), in: window).flatMap({ Double(window[$0]) }),
              let b = Range(match.range(at: 3), in: window).flatMap({ Double(window[$0]) }) else {
            XCTFail("could not read \(appearance) accent for \(provider.rawValue)")
            return (0, 0, 0)
        }
        return (r, g, b)
    }

    private static func designSystemSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenApp/DesignSystem/TokenPilotDesign.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Reads `<name> = SemanticColorDefinition(... <appearance>: rgb(r, g, b) ...)`.
    private static func rgb(_ name: String, appearance: String, in source: String) throws -> (Double, Double, Double) {
        guard let declarationRange = source.range(of: "let \(name) = SemanticColorDefinition(") else {
            throw XCTSkip("definition not found: \(name)")
        }
        let window = source[declarationRange.upperBound...].prefix(600)
        let pattern = "\(appearance): rgb\\(([0-9.]+), ([0-9.]+), ([0-9.]+)\\)"
        let regex = try NSRegularExpression(pattern: pattern)
        let text = String(window)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges == 4,
              let r = Range(match.range(at: 1), in: text).flatMap({ Double(text[$0]) }),
              let g = Range(match.range(at: 2), in: text).flatMap({ Double(text[$0]) }),
              let b = Range(match.range(at: 3), in: text).flatMap({ Double(text[$0]) }) else {
            throw XCTSkip("could not read \(appearance) channel values for \(name)")
        }
        return (r, g, b)
    }

    private static func contrastRatio(_ foreground: (Double, Double, Double), _ background: (Double, Double, Double)) -> Double {
        let a = relativeLuminance(foreground)
        let b = relativeLuminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ color: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.0) + 0.7152 * channel(color.1) + 0.0722 * channel(color.2)
    }
}

// MARK: - Sandbox source grants

/// A sandboxed build (the App Store entitlements) can only read folders the user granted, so these
/// cover both halves: the Developer ID build keeps reading its default paths, and the sandboxed one
/// asks for a grant instead of reporting "not found".
final class ProviderSourceAccessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("source-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testUnsandboxedBuildKeepsUsingDefaultPaths() {
        let defaults = [URL(fileURLWithPath: "/tmp/defaults", isDirectory: true)]
        let resolution = ProviderSourceAccess.resolve(
            provider: .commandcode,
            settings: AppSettings(),
            defaults: defaults,
            sandboxed: false
        )
        defer { resolution.release() }
        XCTAssertEqual(resolution.roots, defaults)
        XCTAssertFalse(resolution.needsUserGrant)
    }

    func testSandboxedBuildWithoutAGrantAsksForOne() {
        let resolution = ProviderSourceAccess.resolve(
            provider: .commandcode,
            settings: AppSettings(),
            defaults: [URL(fileURLWithPath: "/tmp/defaults", isDirectory: true)],
            sandboxed: true
        )
        defer { resolution.release() }
        XCTAssertTrue(resolution.roots.isEmpty, "a sandboxed build must not pretend it can read a default path")
        XCTAssertTrue(resolution.needsUserGrant)
    }

    func testGrantedFolderWinsOverDefaults() {
        var settings = AppSettings()
        settings.monitoredProviders.customPaths[.kiro] = directory.path
        let resolution = ProviderSourceAccess.resolve(
            provider: .kiro,
            settings: settings,
            defaults: [URL(fileURLWithPath: "/tmp/defaults", isDirectory: true)],
            sandboxed: false
        )
        defer { resolution.release() }
        XCTAssertEqual(resolution.roots.map(\.path), [directory.path])
        XCTAssertFalse(resolution.needsUserGrant)
    }

    func testBookmarkResolvesAndSatisfiesASandboxedBuild() throws {
        let bookmark = try TokenPilotSecurityScopedBookmarks.makeReadOnlyBookmarkData(for: directory)
        var settings = AppSettings()
        settings.monitoredProviders.customPaths[.codex] = directory.path
        settings.monitoredProviders.customBookmarks[.codex] = bookmark

        let resolution = ProviderSourceAccess.resolve(
            provider: .codex,
            settings: settings,
            defaults: [],
            sandboxed: true
        )
        defer { resolution.release() }
        XCTAssertFalse(resolution.needsUserGrant)
        XCTAssertEqual(resolution.roots.first?.standardizedFileURL.path, directory.standardizedFileURL.path)
    }

    func testGrantsSurviveASettingsRoundTrip() throws {
        let bookmark = try TokenPilotSecurityScopedBookmarks.makeReadOnlyBookmarkData(for: directory)
        var settings = AppSettings()
        settings.monitoredProviders.customPaths[.opencode] = directory.path
        settings.monitoredProviders.customBookmarks[.opencode] = bookmark

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.monitoredProviders.customPaths[.opencode], directory.path)
        XCTAssertEqual(decoded.monitoredProviders.customBookmarks[.opencode], bookmark)
    }

    func testAdapterReportsTheGrantInsteadOfAMissingFolder() async {
        var settings = AppSettings()
        _ = settings.setProviderEnabled(.commandcode, isEnabled: true)
        // The adapter resolves through ProviderSourceAccess, so an ungranted sandboxed build stops
        // before touching the filesystem; unsandboxed here, a missing default folder still reports
        // the honest "not found" message.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-created-\(UUID().uuidString)", isDirectory: true)
        let snapshot = await CommandCodeLocalSessionAdapter(projectRoots: [missing]).snapshot(settings: settings)
        XCTAssertTrue(
            snapshot.statusMessage == "Command Code session folder not found" ||
            snapshot.statusMessage == "Choose the Command Code folder to grant access",
            "unexpected status: \(snapshot.statusMessage ?? "nil")"
        )
        XCTAssertEqual(snapshot.dataSource, .unknown)
    }

    /// Every file-backed provider must be grantable, or a sandboxed build silently loses it.
    func testEveryFileBackedProviderResolvesThroughTheGrantPath() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenApp/Views/SettingsScreen.swift"),
            encoding: .utf8
        )
        for provider in [Provider.claude, .codex, .opencode, .kiro, .commandcode, .jetbrains, .xai] {
            XCTAssertTrue(
                source.contains("sourceGrantRow(.\(provider.rawValue))"),
                "\(provider.rawValue) has no way to be granted a source folder"
            )
        }
    }

    func testGrantMessagesAreLocalized() {
        let keys = [
            "Choose the Command Code folder to grant access",
            "Choose the Kiro folder to grant access",
            "Choose the Codex folder to grant access",
            "Choose the opencode folder to grant access",
            "Choose the Grok folder to grant access",
            "Choose the JetBrains folder to grant access",
            "Choose Folder",
            "This build is sandboxed, so it only reads folders you grant. Choose this provider's folder once to start monitoring it."
        ]
        for key in keys {
            for language in [TokenPilotLanguage.ko, .ja, .zhHans, .zhHant] {
                let value = TokenPilotLocalizer.localized(key, language: language)
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, key, "missing \(language) translation for: \(key)")
            }
        }
    }
}
