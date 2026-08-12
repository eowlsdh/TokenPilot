import Foundation
import os
import XCTest
@testable import TokenCore

private final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func saveSecret(_ secret: String, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key(service: service, account: account)] = secret
    }

    func readSecret(service: String, account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key(service: service, account: account)]
    }

    func deleteSecret(service: String, account: String, ignoreMissing: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = key(service: service, account: account)
        guard values.removeValue(forKey: key) != nil else {
            if ignoreMissing { return }
            throw KeychainError.itemNotFound
        }
    }

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}

private final class StubDeepSeekHTTPClient: DeepSeekBalanceHTTPClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StubDeepSeekHTTPClient")
    private var responses: [(Data, Int)]
    private var callCountValue = 0

    init(data: Data, statusCode: Int = 200) {
        self.responses = [(data, statusCode)]
    }

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let responsePayload = queue.sync { () -> (Data, Int) in
            callCountValue += 1
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.deepseek.com/user/balance")!,
            statusCode: responsePayload.1,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responsePayload.0, response)
    }

    func callCount() -> Int {
        queue.sync { callCountValue }
    }
}

final class TokenPilotServicesTests: XCTestCase {
    func testCodexStatusParserKeepsManualConfidenceLowOrMedium() {
        let parsed = CodexStatusParser.parse(
            """
            Plan: Pro
            Session (5h): 82% resets 1h24m
            Week (7d): 47%
            """,
            previous: CodexManualSettings()
        )

        XCTAssertEqual(parsed.planLabel, "Pro")
        XCTAssertEqual(parsed.fiveHourUsagePercentage, 82)
        XCTAssertEqual(parsed.weeklyUsagePercentage, 47)
        XCTAssertEqual(parsed.confidence, .medium)
    }

    func testLimitWindowRemainingPercentIsInverseOfUsedPercent() {
        XCTAssertEqual(LimitWindow(kind: .fiveHour, usedPercent: 97).remainingPercent, 3)
        XCTAssertEqual(LimitWindow(kind: .weekly, usedPercent: 0).remainingPercent, 100)
        XCTAssertNil(LimitWindow(kind: .weekly).remainingPercent)
    }

    func testDateValueNormalizesMillisecondEpochsToTheSameInstantAsSeconds() {
        let seconds: TimeInterval = 1_700_000_000
        let expected = Date(timeIntervalSince1970: seconds)
        let millis = seconds * 1_000

        // Seconds epochs (number and string) are unchanged.
        XCTAssertEqual(dateValue(seconds), expected)
        XCTAssertEqual(dateValue(seconds as NSNumber), expected)
        XCTAssertEqual(dateValue(String(Int64(seconds))), expected)

        // Millisecond epochs must land on the same instant, not the year ~55,899.
        XCTAssertEqual(dateValue(millis), expected)
        XCTAssertEqual(dateValue(millis as NSNumber), expected)
        XCTAssertEqual(dateValue(String(Int64(millis))), expected)
    }

    func testDateValueParsesISO8601WithAndWithoutFractionalSeconds() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = { (month: Int, day: Int, second: TimeInterval) in
            utc.date(from: DateComponents(year: 2027, month: month, day: day, hour: 0, minute: 0, second: 0))!
                .addingTimeInterval(second)
        }

        XCTAssertEqual(dateValue("2027-01-15T00:00:00Z"), date(1, 15, 0))

        let fractional = dateValue("2027-02-03T00:00:00.123Z")
        let whole = date(2, 3, 0)
        if let fractional {
            XCTAssertEqual(Int((fractional.timeIntervalSince(whole) * 1000).rounded()), 123)
        } else {
            XCTFail("fractional ISO8601 date did not parse")
        }
    }
    func testProviderSnapshotLegacyDecodeAndMonthlyRoundTrip() throws {
        let legacyJSON = """
        {
          "provider": "xai",
          "updatedAt": 1800000000,
          "fiveHour": {
            "id": "fiveHour",
            "kind": "fiveHour",
            "name": "Legacy window",
            "usedPercent": 12,
            "label": "5h",
            "confidence": "low"
          },
          "todayTokens": 0,
          "confidence": "low",
          "dataSource": "localLog",
          "isExperimental": true,
          "isStale": false,
          "events": []
        }
        """
        let legacy = try JSONDecoder().decode(ProviderSnapshot.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(legacy.fiveHour?.usedPercent, 12)
        XCTAssertNil(legacy.monthly)
        XCTAssertEqual(legacy.dataSource, .localLog)

        let monthly = ProviderSnapshot(
            provider: .xai,
            monthly: LimitWindow(kind: .monthly, usedPercent: 37),
            dataSource: .experimentalCLI,
            isExperimental: true
        )
        let roundTrip = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(monthly))

        XCTAssertEqual(roundTrip.monthly?.kind, .monthly)
        XCTAssertEqual(roundTrip.primaryUsedPercent, 37)
        XCTAssertEqual(roundTrip.dataSource, .experimentalCLI)
    }


    func testAppSettingsDecodeUsesClaudeStatuslineDefaultPath() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(
            decoded.claudeStatusFilePath,
            "~/Library/Application Support/TokenPilot/claude-statusline.json"
        )
    }
    func testAppSettingsDefaultsGeminiSourceToAntigravityStatusline() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(decoded.geminiTelemetryLogPath, AppSettings.defaultAntigravityStatuslinePath)
        XCTAssertEqual(AppSettings().geminiTelemetryLogPath, "~/Library/Application Support/TokenPilot/antigravity-statusline.json")
    }


    func testAppSettingsPersistsSecurityScopedBookmarksForUserSelectedSources() throws {
        let claudeBookmark = Data([0x01, 0x02, 0x03])
        let geminiBookmark = Data([0x04, 0x05, 0x06])
        let settings = AppSettings(
            claudeStatusFileBookmarkData: claudeBookmark,
            geminiTelemetrySourceBookmarkData: geminiBookmark
        )

        XCTAssertEqual(settings.localSourceBookmarkData(for: .claude), claudeBookmark)
        XCTAssertEqual(settings.localSourceBookmarkData(for: .gemini), geminiBookmark)
        XCTAssertNil(settings.localSourceBookmarkData(for: .codex))

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertEqual(decoded.claudeStatusFileBookmarkData, claudeBookmark)
        XCTAssertEqual(decoded.geminiTelemetrySourceBookmarkData, geminiBookmark)
    }

    func testAppSettingsPreXAIAndUnknownProviderDecodeKeepXAIExplicit() throws {
        let legacyJSON = """
        {
          "claudeEnabled": true,
          "codexEnabled": true,
          "geminiEnabled": true,
          "deepseekEnabled": true,
          "monitoredProviders": {
            "enabledProviders": ["claude", "codex", "gemini", "deepseek"]
          }
        }
        """
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))

        XCTAssertFalse(legacy.xaiEnabled)
        XCTAssertFalse(legacy.xAI.managementAPIKeyConfigured)
        XCTAssertEqual(legacy.xAI.teamID, "")
        XCTAssertEqual(legacy.xAI.managementAPILookbackDays, 30)
        XCTAssertFalse(legacy.xAI.prepaidBalanceAlertsEnabled)
        XCTAssertEqual(legacy.xAI.prepaidBalanceAlertThresholdUSD, Decimal(5))
        XCTAssertFalse(legacy.enabledProviders.contains(.xai))
        XCTAssertFalse(legacy.alertRules.contains { $0.provider == .xai })
        XCTAssertEqual(legacy.xAI.usageSource, .managementSetup)

        var experimental = AppSettings()
        experimental.xAI = XAISettings(usageSource: .experimentalOpenCodeBarCLI)
        let experimentalRoundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(experimental))
        XCTAssertEqual(experimentalRoundTrip.xAI.usageSource, .managementSetup)

        let unknownProviderJSON = """
        {
          "menuBarDisplayTarget": "future-provider",
          "monitoredProviders": {
            "enabledProviders": ["claude", "future-provider"],
            "providerModes": {
              "claude": "auto",
              "future-provider": "custom"
            },
            "customPaths": {
              "claude": "/tmp/claude",
              "future-provider": "/tmp/future"
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(unknownProviderJSON.utf8))

        XCTAssertNil(decoded.menuBarDisplayTarget)
        XCTAssertEqual(decoded.enabledProviders, [.claude, .opencode, .kiro])
        XCTAssertEqual(decoded.monitoredProviders.enabledProviders, [.claude])
        XCTAssertEqual(decoded.monitoredProviders.providerModes, [.claude: .auto])
        XCTAssertEqual(decoded.monitoredProviders.customPaths, [.claude: "/tmp/claude"])
        XCTAssertFalse(decoded.xaiEnabled)
        XCTAssertFalse(decoded.enabledProviders.contains(.xai))
    }
    func testMenuBarCompositionSettingsDefaultAndRoundTrip() throws {
        let defaults = AppSettings()
        XCTAssertEqual(defaults.menuBarDisplayStyle, .detailed)
        XCTAssertNil(defaults.menuBarSecondaryDisplayTarget)
        XCTAssertFalse(defaults.menuBarShowsSecondaryProvider)

        var settings = defaults
        settings.menuBarDisplayStyle = .compact
        settings.menuBarDisplayTarget = .claude
        settings.menuBarSecondaryDisplayTarget = .deepseek
        settings.menuBarShowsSecondaryProvider = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.menuBarDisplayStyle, .compact)
        XCTAssertEqual(decoded.menuBarDisplayTarget, .claude)
        XCTAssertEqual(decoded.menuBarSecondaryDisplayTarget, .deepseek)
        XCTAssertTrue(decoded.menuBarShowsSecondaryProvider)
    }
    func testMenuBarProviderMetricSettingsRoundTripAndLegacyDefaults() throws {
        var settings = AppSettings()
        settings.menuBarProviderGrouping = .combined
        settings.menuBarMetricProviders = [.claude, .gemini]

        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.menuBarProviderGrouping, .combined)
        XCTAssertEqual(roundTrip.menuBarMetricProviders, [.claude, .gemini])

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.menuBarProviderGrouping, .separate)
        XCTAssertEqual(legacy.menuBarMetricProviders, Set(legacy.enabledProviders))
    }

    func testLaunchAtLoginSettingRoundTripAndLegacyDefault() throws {
        var settings = AppSettings()
        XCTAssertFalse(settings.launchAtLogin)

        settings.launchAtLogin = true
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(roundTrip.launchAtLogin)

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.launchAtLogin)
    }

    func testVersionDisplayStringFormatsVersionAndBuild() {
        XCTAssertEqual(TokenPilotVersion.displayString(version: "1.0.0", build: "1"), "1.0.0 (1)")
        XCTAssertEqual(TokenPilotVersion.displayString(version: "1.0.0", build: nil), "1.0.0")
        XCTAssertEqual(TokenPilotVersion.displayString(version: nil, build: "42"), "(42)")
        XCTAssertEqual(TokenPilotVersion.displayString(version: nil, build: nil), "--")
        XCTAssertEqual(TokenPilotVersion.displayString(version: " 1.0.0 ", build: " 1 "), "1.0.0 (1)")
        XCTAssertEqual(TokenPilotVersion.displayString(version: "", build: ""), "--")
    }

    func testUsageEventProjectLabelRoundTripAndLegacyDefault() throws {
        let event = UsageEvent(
            provider: .opencode,
            model: "opencode-go/deepseek",
            inputTokens: 100,
            outputTokens: 20,
            source: "opencode-session",
            dataSource: .localLog,
            projectLabel: "TokenPilot"
        )
        let decoded = try JSONDecoder().decode(UsageEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.projectLabel, "TokenPilot")

        let legacy = try JSONDecoder().decode(UsageEvent.self, from: Data(#"{"provider":"opencode"}"#.utf8))
        XCTAssertNil(legacy.projectLabel)
    }

    func testAggregatedProjectBreakdownRanksOpenCodeProjectsAndSkipsUnlabeled() {
        let now = Date()
        let service = AggregationService()
        let events = [
            openCodeEvent(project: "TokenPilot", input: 5_000, output: 1_000, cost: 0.4, at: now),
            openCodeEvent(project: "TokenPilot", input: 3_000, output: 500, cost: 0.2, at: now.addingTimeInterval(-60)),
            openCodeEvent(project: "Other", input: 1_000, output: 200, cost: nil, at: now.addingTimeInterval(-120)),
            openCodeEvent(project: nil, input: 999, output: 1, cost: nil, at: now.addingTimeInterval(-180))
        ]
        let snapshot = ProviderSnapshot(provider: .opencode, events: events)
        let usage = service.aggregate(snapshots: [snapshot], period: .today, now: now)

        // totalTokens covers all events (11,700); unlabeled events never create a bucket.
        XCTAssertEqual(usage.metrics.totalTokens, 11_700)
        XCTAssertEqual(usage.projectBreakdown.map(\.label), ["TokenPilot", "Other"])
        XCTAssertEqual(usage.projectBreakdown.map(\.tokens), [9_500, 1_200])
        XCTAssertEqual(usage.projectBreakdown.map(\.tokenPercent), [81, 10])
        XCTAssertEqual(usage.projectBreakdown[0].requestCount, 2)
        XCTAssertEqual(usage.projectBreakdown[0].estimatedCostUSD, 0.6)
        XCTAssertNil(usage.projectBreakdown[1].estimatedCostUSD)
        XCTAssertTrue(usage.projectBreakdown.allSatisfy { $0.provider == .opencode })
    }

    func testExportPayloadAndCSVExcludeProjectLabels() throws {
        let now = Date()
        let event = openCodeEvent(project: "ConfidentialProjectName", input: 100, output: 10, cost: 0.5, at: now)
        let snapshot = ProviderSnapshot(provider: .opencode, events: [event])
        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .today, now: now)

        let json = try XCTUnwrap(String(
            data: UsageExportService().export(usage: usage, snapshots: [snapshot], dataMode: "LIVE", format: .json, generatedAt: now),
            encoding: .utf8
        ))
        XCTAssertFalse(json.contains("ConfidentialProjectName"), "Project folder names must never appear in JSON export.")
        XCTAssertFalse(json.contains("projectLabel"), "projectLabel must never appear in JSON export.")

        let csv = UsageExportService().makeCSVString(usage: usage)
        XCTAssertFalse(csv.contains("ConfidentialProjectName"), "Project folder names must never appear in CSV export.")
    }

    private func openCodeEvent(project: String?, input: Int, output: Int, cost: Decimal?, at date: Date) -> UsageEvent {
        UsageEvent(
            provider: .opencode,
            model: "opencode-go/model",
            timestamp: date,
            inputTokens: input,
            outputTokens: output,
            estimatedCostUSD: cost,
            source: "opencode-session",
            dataSource: .localLog,
            projectLabel: project
        )
    }

    func testMenuBarProviderMetricSettingsDropUnknownValues() throws {
        let json = """
        {
          "menuBarProviderGrouping": "Future grouping",
          "menuBarMetricProviders": ["claude", "future-provider"]
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.menuBarProviderGrouping, .separate)
        XCTAssertEqual(decoded.menuBarMetricProviders, [.claude])
    }

    func testProviderMetricsSegmentsFilterAndOrderSelectedProviders() {
        var settings = AppSettings()
        settings.menuBarMetricProviders = [.claude, .gemini]
        settings.menuBarDisplayTarget = .gemini

        let segments = MenuBarStatusService().providerMetricsSegments(snapshots: [], settings: settings)

        XCTAssertEqual(segments.map(\.provider), [.gemini, .claude])
    }

    func testProviderMetricsSegmentsFallBackToFirstEnabledProvider() {
        var settings = AppSettings()
        settings.menuBarMetricProviders = [.codex]
        XCTAssertTrue(settings.setProviderEnabled(.codex, isEnabled: false))
        settings.normalizeMenuBarComposition()
        XCTAssertEqual(settings.menuBarMetricProviders, [.claude])

        let segments = MenuBarStatusService().providerMetricsSegments(snapshots: [], settings: settings)

        XCTAssertEqual(segments.map(\.provider), [.claude])
    }


    func testMenuBarCompositionSettingsUnknownStyleAndProviderDecodeSafely() throws {
        let json = """
        {
          "menuBarDisplayStyle": "Future display",
          "menuBarDisplayTarget": "claude",
          "menuBarSecondaryDisplayTarget": "future-provider",
          "menuBarShowsSecondaryProvider": true
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.menuBarDisplayStyle, .detailed)
        XCTAssertEqual(decoded.menuBarDisplayTarget, .claude)
        XCTAssertNil(decoded.menuBarSecondaryDisplayTarget)
        XCTAssertFalse(decoded.menuBarShowsSecondaryProvider)
    }
    func testAppSettingsDecodeNormalizesInvalidMenuBarComposition() throws {
        let json = """
        {
          "claudeEnabled": true,
          "codexEnabled": false,
          "geminiEnabled": false,
          "deepseekEnabled": false,
          "monitoredProviders": {
            "enabledProviders": ["claude"]
          },
          "menuBarDisplayTarget": "codex",
          "menuBarSecondaryDisplayTarget": "claude",
          "menuBarShowsSecondaryProvider": true
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertNil(decoded.menuBarDisplayTarget)
        XCTAssertEqual(decoded.menuBarSecondaryDisplayTarget, .claude)
        XCTAssertTrue(decoded.menuBarShowsSecondaryProvider)
    }

    func testSettingsStoreRepairsInvalidMenuBarComposition() {
        let suite = "TokenPilotMenuBarCompositionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokenPilotSettingsStore(defaults: defaults)

        var settings = AppSettings()
        settings.menuBarDisplayStyle = .iconOnly
        settings.menuBarDisplayTarget = .claude
        settings.menuBarSecondaryDisplayTarget = .claude
        settings.menuBarShowsSecondaryProvider = true

        store.save(settings)
        let loaded = store.load()

        XCTAssertEqual(loaded.menuBarDisplayStyle, .iconOnly)
        XCTAssertEqual(loaded.menuBarDisplayTarget, .claude)
        XCTAssertNil(loaded.menuBarSecondaryDisplayTarget)
        XCTAssertFalse(loaded.menuBarShowsSecondaryProvider)
    }

    func testCLIInvocationDetection() {
        XCTAssertTrue(TokenPilotCLIService.isCLIInvocation(["export"]))
        XCTAssertTrue(TokenPilotCLIService.isCLIInvocation(["summary"]))
        XCTAssertTrue(TokenPilotCLIService.isCLIInvocation(["report"]))
        XCTAssertTrue(TokenPilotCLIService.isCLIInvocation(["help"]))
        XCTAssertTrue(TokenPilotCLIService.isCLIInvocation(["--help"]))
        XCTAssertFalse(TokenPilotCLIService.isCLIInvocation([]))
        XCTAssertFalse(TokenPilotCLIService.isCLIInvocation(["TokenMonitor"]))
    }

    func testCLIParseExportDefaults() {
        let result = TokenPilotCLIService.parse(arguments: ["export"])
        XCTAssertEqual(result, .success(.export(format: .json, period: .last7Days, outputPath: nil, includesCapacity: false)))
    }

    func testCLIParseExportFlags() {
        let result = TokenPilotCLIService.parse(
            arguments: ["export", "--format", "csv", "--period", "today", "--out", "/tmp/tokenpilot.csv"]
        )
        XCTAssertEqual(
            result,
            .success(.export(format: .csv, period: .today, outputPath: "/tmp/tokenpilot.csv", includesCapacity: false))
        )
    }

    func testCLIParseExportCapacityFlag() {
        let result = TokenPilotCLIService.parse(arguments: ["export", "--capacity"])
        XCTAssertEqual(result, .success(.export(format: .json, period: .last7Days, outputPath: nil, includesCapacity: true)))
    }

    func testCLIParseExportSectionsFlag() {
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--sections", "today,last7Days"]),
            .success(.export(format: .json, period: .last7Days, outputPath: nil, includesCapacity: false, sections: [.today, .last7Days]))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--sections", "today", "--format", "csv"]),
            .failure(.invalidCombination("--sections requires --json output."))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--sections", "today", "--since", "2026-08-01"]),
            .failure(.invalidCombination("--sections cannot be combined with --since, --until, or --days."))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--sections", "bogus"]),
            .failure(.invalidPeriod("bogus"))
        )
    }

    func testCapacityRecordRoundTripFeedsCLICapacityExportSection() throws {
        let now = Date()
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
            resetAt: now.addingTimeInterval(3_600),
            value: try CapacityValue(usedPercent: 62),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "cliCapacityV1",
            now: now
        )

        let record = try CapacityEvidenceRecord(observation: observation)
        let converted = try record.observationForAssessment(now: now)
        XCTAssertEqual(converted.seriesID.canonicalID, observation.seriesID.canonicalID)
        XCTAssertEqual(converted.value.usedPercent, 62)

        let assessment = CapacityAssessmentService().assess(converted, now: now)
        XCTAssertEqual(assessment.risk, .normal)

        let section = CapacityExportSection(assessments: [assessment])
        XCTAssertEqual(section.observations.count, 1)
        XCTAssertEqual(section.observations.first?.usedPercent, 62)
        XCTAssertEqual(section.observations.first?.remainingPercent, 38)
    }

    func testCLIParseRejectsInvalidInput() {
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["bogus"]), .failure(.unknownCommand("bogus")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--format", "xml"]), .failure(.invalidFormat("xml")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--period", "yesterday"]), .failure(.invalidPeriod("yesterday")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--format"]), .failure(.missingValue(forFlag: "--format")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--bogus"]), .failure(.unknownCommand("--bogus")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--since", "13/08/2026"]), .failure(.invalidDate("13/08/2026")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--until", "yesterday"]), .failure(.invalidDate("yesterday")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--days", "zero"]), .failure(.invalidDays("zero")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--days", "0"]), .failure(.invalidDays("0")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--days", "-3"]), .failure(.invalidDays("-3")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--timezone", "Mars/Olympus"]), .failure(.invalidTimezone("Mars/Olympus")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--timezone"]), .failure(.missingValue(forFlag: "--timezone")))
    }

    func testCLIParseTimezone() {
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--timezone", "UTC"]),
            .success(.report(period: .last7Days, format: .text, timeZone: TimeZone(identifier: "UTC")))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["stats", "--period", "today", "--timezone", "Asia/Tokyo"]),
            .success(.stats(period: .today, timeZone: TimeZone(identifier: "Asia/Tokyo")))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--days", "30", "--timezone", "America/New_York", "--format", "csv"]),
            .success(.export(format: .csv, period: .last7Days, outputPath: nil, includesCapacity: false, days: 30, timeZone: TimeZone(identifier: "America/New_York")))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--md", "--timezone", "UTC", "--no-cost"]),
            .success(.report(period: .last7Days, format: .markdown, includesCost: false, timeZone: TimeZone(identifier: "UTC")))
        )
    }

    func testCLIParseSinceUntilDates() {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let since = formatter.date(from: "2026-08-01")
        let until = formatter.date(from: "2026-08-13")
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--since", "2026-08-01"]),
            .success(.report(period: .last7Days, format: .text, since: since, until: nil))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--until", "2026-08-13"]),
            .success(.report(period: .last7Days, format: .text, since: nil, until: until))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--since", "2026-08-01", "--until", "2026-08-13", "--svg"]),
            .success(.report(period: .today, format: .svg, since: since, until: until))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--since", "2026-08-01", "--until", "2026-08-13", "--format", "csv"]),
            .success(.export(format: .csv, period: .last7Days, outputPath: nil, includesCapacity: false, since: since, until: until))
        )
    }

    func testCLIParseNoCostFlag() {
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--no-cost"]),
            .success(.report(period: .last7Days, format: .text, includesCost: false))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--svg", "--no-cost"]),
            .success(.report(period: .today, format: .svg, includesCost: false))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--no-cost", "--md"]),
            .success(.report(period: .last7Days, format: .markdown, includesCost: false))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--format", "csv", "--no-cost"]),
            .success(.export(format: .csv, period: .last7Days, outputPath: nil, includesCapacity: false, includesCost: false))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--capacity", "--no-cost"]),
            .success(.export(format: .json, period: .last7Days, outputPath: nil, includesCapacity: true, includesCost: false))
        )
    }

    func testCLIParseDaysWindow() {
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--days", "14"]),
            .success(.report(period: .last7Days, format: .text, days: 14))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--days", "30", "--svg"]),
            .success(.report(period: .today, format: .svg, days: 30))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--format", "csv", "--days", "90", "--no-cost"]),
            .success(.export(format: .csv, period: .last7Days, outputPath: nil, includesCapacity: false, days: 90, includesCost: false))
        )
    }

    func testCLIParseSummaryAndHelp() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let since = formatter.date(from: "2026-08-01")
        let until = formatter.date(from: "2026-08-13")
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary"]), .success(.summary()))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--json"]), .success(.summary(includesJSON: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--period", "last7Days"]), .success(.summary(period: .last7Days)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--period", "thisMonth", "--json"]), .success(.summary(period: .thisMonth, includesJSON: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--period", "bogus"]), .failure(.invalidPeriod("bogus")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--since", "2026-08-01"]), .success(.summary(since: since)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--until", "2026-08-13"]), .success(.summary(until: until)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--since", "2026-08-01", "--until", "2026-08-13", "--json"]), .success(.summary(since: since, until: until, includesJSON: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--days", "3"]), .success(.summary(days: 3)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--days", "3", "--since", "2026-08-01"]), .failure(.invalidCombination("--days cannot be combined with --since or --until.")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--timezone", "UTC"]), .success(.summary(timeZone: TimeZone(identifier: "UTC"))))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--project", "project-a"]), .success(.summary(project: "project-a")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--no-cost"]), .success(.summary(includesCost: false)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--no-cost", "--json"]), .success(.summary(includesCost: false, includesJSON: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--since", "13/08/2026"]), .failure(.invalidDate("13/08/2026")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["summary", "--bogus"]), .failure(.unknownCommand("--bogus")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["help"]), .success(.help))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["-h"]), .success(.help))
    }

    func testCLIParseAuditJSONFlag() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let since = formatter.date(from: "2026-08-01")
        let until = formatter.date(from: "2026-08-13")
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit"]), .success(.audit()))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit", "--json"]), .success(.audit(includesJSON: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit", "--since", "2026-08-01"]), .success(.audit(since: since)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit", "--until", "2026-08-13"]), .success(.audit(until: until)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit", "--days", "14"]), .success(.audit(days: 14)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit", "--days", "14", "--since", "2026-08-01"]), .failure(.invalidCombination("--days cannot be combined with --since or --until.")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit", "--timezone", "UTC"]), .success(.audit(timeZone: TimeZone(identifier: "UTC"))))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit", "--project", "project-a"]), .success(.audit(project: "project-a")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["audit", "--bogus"]), .failure(.unknownCommand("--bogus")))
    }

    func testCLIParseBlocksCommand() {
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["blocks"]), .success(.blocks()))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["blocks", "--json"]), .success(.blocks(includesJSON: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["blocks", "--active"]), .success(.blocks(active: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["blocks", "--recent"]), .success(.blocks(recent: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["blocks", "--json", "--active", "--recent"]), .success(.blocks(includesJSON: true, active: true, recent: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["blocks", "--bogus"]), .failure(.unknownCommand("--bogus")))
    }

    func testCLIParseStatsCommand() {
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats"]), .success(.stats(period: .last7Days)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--period", "today"]), .success(.stats(period: .today)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--period", "thisMonth"]), .success(.stats(period: .thisMonth)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--days", "30"]), .success(.stats(period: .last7Days, days: 30)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--period", "today", "--days", "14", "--no-cost"]), .success(.stats(period: .today, days: 14, includesCost: false)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--json"]), .success(.stats(period: .last7Days, includesJSON: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--period", "today", "--days", "14", "--no-cost", "--json"]), .success(.stats(period: .today, days: 14, includesCost: false, includesJSON: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--json", "--sections", "today,last7Days,thisMonth"]), .success(.stats(period: .last7Days, includesJSON: true, sections: [.today, .last7Days, .thisMonth])))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--json", "--sections", "today"]), .success(.stats(period: .last7Days, includesJSON: true, sections: [.today])))
        // --sections requires --json and cannot be combined with custom windows.
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["stats", "--sections", "today"]),
            .failure(.invalidCombination("--sections requires --json output."))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["stats", "--json", "--sections", "today", "--days", "14"]),
            .failure(.invalidCombination("--sections cannot be combined with --since, --until, or --days."))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["stats", "--json", "--sections", "today,bogus"]),
            .failure(.invalidPeriod("bogus"))
        )
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--period", "bogus"]), .failure(.invalidPeriod("bogus")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--days", "zero"]), .failure(.invalidDays("zero")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--bogus"]), .failure(.unknownCommand("--bogus")))
    }

    func testCLIParseReportDefaultsAndFlags() {
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report"]), .success(.report(period: .last7Days, format: .text)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--period", "today"]), .success(.report(period: .today, format: .text)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--period", "thisMonth"]), .success(.report(period: .thisMonth, format: .text)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--svg"]), .success(.report(period: .last7Days, format: .svg)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--svg"]), .success(.report(period: .today, format: .svg)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--md"]), .success(.report(period: .last7Days, format: .markdown)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--md"]), .success(.report(period: .today, format: .markdown)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--json"]), .success(.report(period: .last7Days, format: .json)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--json"]), .success(.report(period: .today, format: .json)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--breakdown"]), .success(.report(period: .last7Days, format: .text, includesBreakdown: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--md", "--breakdown"]), .success(.report(period: .today, format: .markdown, includesBreakdown: true)))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--project", "my-workspace"]), .success(.report(period: .last7Days, format: .text, project: "my-workspace")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--md", "--project", "my-workspace", "--breakdown"]), .success(.report(period: .today, format: .markdown, includesBreakdown: true, project: "my-workspace")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--period", "bogus"]), .failure(.invalidPeriod("bogus")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--bogus"]), .failure(.unknownCommand("--bogus")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["report", "--project"]), .failure(.missingValue(forFlag: "--project")))
    }

    func testCLIParseReportSections() {
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--json", "--sections", "today,last7Days,thisMonth"]),
            .success(.report(period: .last7Days, format: .json, sections: [.today, .last7Days, .thisMonth]))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--json", "--sections", "today"]),
            .success(.report(period: .last7Days, format: .json, sections: [.today]))
        )
        // Invalid section name is rejected as an invalid period.
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--json", "--sections", "today,bogus"]),
            .failure(.invalidPeriod("bogus"))
        )
        // --sections requires --json and cannot be combined with custom windows.
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--sections", "today"]),
            .failure(.invalidCombination("--sections requires --json output."))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--json", "--sections", "today", "--days", "14"]),
            .failure(.invalidCombination("--sections cannot be combined with --since, --until, or --days."))
        )
    }

    func testCLIParseStartOfWeek() {
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--start-of-week", "monday"]),
            .success(.report(period: .last7Days, format: .text, weekStartDay: .monday))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["stats", "--json", "--start-of-week", "sunday"]),
            .success(.stats(period: .last7Days, includesJSON: true, weekStartDay: .sunday))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--format", "csv", "--start-of-week", "thursday"]),
            .success(.export(format: .csv, period: .last7Days, outputPath: nil, includesCapacity: false, weekStartDay: .thursday))
        )
        // Invalid day name is rejected.
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--start-of-week", "funday"]),
            .failure(.invalidWeekStartDay("funday"))
        )
        // --start-of-week cannot be combined with custom windows.
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--start-of-week", "monday", "--days", "14"]),
            .failure(.invalidCombination("--start-of-week cannot be combined with --since, --until, --days, or --sections."))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["export", "--start-of-week", "monday", "--since", "2026-08-01"]),
            .failure(.invalidCombination("--start-of-week cannot be combined with --since, --until, --days, or --sections."))
        )
    }

    func testCLIParseReportInstances() {
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--json", "--instances"]),
            .success(.report(period: .last7Days, format: .json, instances: true))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--period", "today", "--json", "--instances", "--breakdown"]),
            .success(.report(period: .today, format: .json, includesBreakdown: true, instances: true))
        )
        // --instances combines with --sections (each period carries its own project grouping).
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--json", "--instances", "--sections", "today,last7Days"]),
            .success(.report(period: .last7Days, format: .json, sections: [.today, .last7Days], instances: true))
        )
        // --instances requires --json and still conflicts with --project.
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--instances"]),
            .failure(.invalidCombination("--instances requires --json output."))
        )
        XCTAssertEqual(
            TokenPilotCLIService.parse(arguments: ["report", "--json", "--instances", "--project", "my-workspace"]),
            .failure(.invalidCombination("--instances cannot be combined with --project."))
        )
    }

    func testCLIParseProjectOnStatsAndExport() {
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["stats", "--project", "my-workspace"]), .success(.stats(period: .last7Days, project: "my-workspace")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--format", "csv", "--project", "my-workspace"]), .success(.export(format: .csv, period: .last7Days, outputPath: nil, includesCapacity: false, project: "my-workspace")))
        XCTAssertEqual(TokenPilotCLIService.parse(arguments: ["export", "--project"]), .failure(.missingValue(forFlag: "--project")))
    }

    func testCLIReportTextIncludesDailyBreakdownAndCacheEfficiency() {
        let now = Date()
        let calendar = Calendar.current
        let dayAgo = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 3_000, outputTokens: 1_000, cacheReadTokens: 6_000, source: "report-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: dayAgo, inputTokens: 2_000, outputTokens: 0, source: "report-test", dataSource: .localLog),
        ]
        let text = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("TokenPilot · Report"))
        XCTAssertTrue(text.contains("Total tokens: 12K"))
        // Cache hit rate over the period events: 6000 / (3000+2000 + 6000) = 55%.
        XCTAssertTrue(text.contains("Cache hit rate: 55%"))
        XCTAssertTrue(text.contains("Daily breakdown"))
        XCTAssertTrue(text.contains("opencode"))
        XCTAssertTrue(text.contains("Local activity, not provider quota"))
    }

    func testCLIReportIncludesDailyCostBreakdown() {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.25), source: "report-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: now.addingTimeInterval(-60), inputTokens: 1_000, outputTokens: 0, estimatedCostUSD: Decimal(0.05), source: "report-test", dataSource: .localLog),
        ]
        let text = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now,
            calendar: calendar
        )
        // The daily breakdown line for today aggregates the two costs into $0.30.
        let dayLine = text.components(separatedBy: "\n").first { $0.contains("· $0.30") }
        XCTAssertNotNil(dayLine)
        XCTAssertTrue(dayLine?.contains("tok") == true)
    }

    func testCLIReportSVGContainsAggregatesAndEscapes() {
        let now = Date()
        let calendar = Calendar.current
        let dayAgo = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 3_000, outputTokens: 1_000, cacheReadTokens: 6_000, source: "report-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: dayAgo, inputTokens: 2_000, outputTokens: 0, source: "report-test", dataSource: .localLog),
        ]
        let svg = TokenPilotCLIService.reportSVGText(
            events: events,
            enabledProviders: [.opencode],
            period: .last7Days,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(svg.hasSuffix("</svg>"))
        XCTAssertTrue(svg.contains("TokenPilot · Report"))
        XCTAssertTrue(svg.contains("Total tokens: 12K"))
        XCTAssertTrue(svg.contains("Cache hit rate: 55%"))
        XCTAssertTrue(svg.contains("Daily breakdown"))
        XCTAssertTrue(svg.contains("Local activity, not provider quota"))
        // Aggregates only: no raw event fields leak into the markup.
        XCTAssertFalse(svg.contains("report-test"))
        XCTAssertFalse(svg.contains("inputTokens"))
    }

    func testCLIReportIncludesTopModelsRanking() {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, model: "model-a", timestamp: now, inputTokens: 6_000, outputTokens: 0, estimatedCostUSD: Decimal(0.12), source: "report-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, model: "model-b", timestamp: now, inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.05), source: "report-test", dataSource: .localLog),
        ]
        let text = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Top models"))
        XCTAssertTrue(text.contains("model-a"))
        XCTAssertTrue(text.contains("model-b"))
        // Ranked first: model-a has the most tokens and carries its cost.
        let lines = text.components(separatedBy: "\n")
        let topLine = lines.first { $0.hasPrefix("model-a:") }
        XCTAssertNotNil(topLine)
        XCTAssertTrue(topLine?.contains("$0.12") == true)
    }

    func testCLIReportIncludesTopProjectsRanking() {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, model: nil, timestamp: now, inputTokens: 5_000, outputTokens: 0, estimatedCostUSD: Decimal(0.10), source: "report-test", dataSource: .localLog, projectLabel: "project-a"),
            UsageEvent(provider: .opencode, model: nil, timestamp: now, inputTokens: 1_000, outputTokens: 0, estimatedCostUSD: Decimal(0.02), source: "report-test", dataSource: .localLog, projectLabel: "project-b"),
        ]
        let text = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Top projects"))
        XCTAssertTrue(text.contains("project-a"))
        XCTAssertTrue(text.contains("project-b"))
        // Ranked first: project-a has the most tokens and carries its cost.
        let lines = text.components(separatedBy: "\n")
        let topLine = lines.first { $0.hasPrefix("project-a:") }
        XCTAssertNotNil(topLine)
        XCTAssertTrue(topLine?.contains("$0.10") == true)
    }

    func testCLIReportMarkdownOutputIsCopyPasteableAndAggregatesOnly() {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.10), source: "md-test", dataSource: .localLog, projectLabel: "project-a"),
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now.addingTimeInterval(-60), inputTokens: 1_000, outputTokens: 0, estimatedCostUSD: Decimal(0.05), source: "md-test", dataSource: .localLog, projectLabel: "project-a"),
        ]
        let md = TokenPilotCLIService.reportMarkdownText(
            events: events,
            enabledProviders: [.opencode],
            period: .last7Days,
            now: now,
            calendar: calendar
        )
        // Markdown table structure: header, separator, and rows are pipe-delimited.
        XCTAssertTrue(md.hasPrefix("## TokenPilot · Report"))
        XCTAssertTrue(md.contains("| Metric | Value |"))
        XCTAssertTrue(md.contains("|---|---|"))
        XCTAssertTrue(md.contains("| Total tokens | 4K |"))
        XCTAssertTrue(md.contains("| Requests | 2 |"))
        XCTAssertTrue(md.contains("| Estimated cost | $0.15 |"))
        // Provider and top-model tables are pipe-delimited too.
        XCTAssertTrue(md.contains("**Top models**"))
        XCTAssertTrue(md.contains("| Model | Tokens | Cost |"))
        XCTAssertTrue(md.contains("opencode-sonnet"))
        XCTAssertTrue(md.contains("**Providers**"))
        XCTAssertTrue(md.contains("| Provider | Tokens | Requests | Cost |"))
        XCTAssertTrue(md.contains("opencode"))
        // Honest labeling footer.
        XCTAssertTrue(md.contains("_Local activity, not provider quota._"))
        // Aggregates-only redaction: no per-event source labels or project folders leak.
        XCTAssertFalse(md.contains("md-test"))
        XCTAssertFalse(md.contains("project-a"))
    }

    func testCLIReportJSONPayloadStructureAndValues() throws {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.06), source: "json-test", dataSource: .localLog),
            UsageEvent(provider: .claude, model: "claude-sonnet", timestamp: yesterday, inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "json-test", dataSource: .localLog),
        ]
        let data = try TokenPilotCLIService.reportJSON(
            events: events,
            enabledProviders: [.opencode, .claude],
            period: .last7Days,
            includesCost: true,
            now: now,
            calendar: calendar
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Totals mirror the text receipt.
        XCTAssertEqual(json["totalTokens"] as? Int, 5_000)
        XCTAssertEqual(json["requestCount"] as? Int, 2)
        XCTAssertEqual(json["period"] as? String, "Last 7 days")
        // Cost present when includesCost is true; provider share and top models populated.
        let cost = try XCTUnwrap(json["estimatedCostUSD"] as? NSNumber)
        XCTAssertEqual(cost.doubleValue, 0.10, accuracy: 0.001)
        let shares = try XCTUnwrap(json["providerShare"] as? [[String: Any]])
        XCTAssertEqual(shares.count, 2)
        let models = try XCTUnwrap(json["topModels"] as? [[String: Any]])
        XCTAssertEqual(models.first?["model"] as? String, "opencode-sonnet")
        let daily = try XCTUnwrap(json["dailyBreakdown"] as? [[String: Any]])
        XCTAssertEqual(daily.count, 2)
        // Per-provider model breakdown (ccusage --by-agent style): each provider lists its
        // models, and provider totals sum to the combined row (opencode 3K, claude 2K).
        let providerBreakdown = try XCTUnwrap(json["providerBreakdown"] as? [[String: Any]])
        XCTAssertEqual(providerBreakdown.count, 2)
        let opencodeBreakdown = try XCTUnwrap(providerBreakdown.first { $0["provider"] as? String == "opencode" })
        XCTAssertEqual(opencodeBreakdown["tokens"] as? Int, 3_000)
        let opencodeModels = try XCTUnwrap(opencodeBreakdown["models"] as? [[String: Any]])
        XCTAssertEqual(opencodeModels.first?["model"] as? String, "opencode-sonnet")
        XCTAssertEqual(opencodeModels.first?["tokens"] as? Int, 3_000)
        // No per-event source labels leak into the payload.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("json-test"))
    }

    func testCLIReportJSONNoCostAndBreakdown() throws {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.06), source: "json-test", dataSource: .localLog),
        ]
        // --no-cost: cost fields are omitted entirely (ccusage --json --no-cost).
        let noCost = try TokenPilotCLIService.reportJSON(
            events: events,
            enabledProviders: [.opencode],
            period: .last7Days,
            includesCost: false,
            now: now,
            calendar: calendar
        )
        let noCostJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: noCost) as? [String: Any])
        XCTAssertNil(noCostJSON["estimatedCostUSD"])
        let noCostShare = try XCTUnwrap(noCostJSON["providerShare"] as? [[String: Any]])
        XCTAssertNil(noCostShare.first?["estimatedCostUSD"])
        // --breakdown: per-day per-model rows are present.
        let breakdown = try TokenPilotCLIService.reportJSON(
            events: events,
            enabledProviders: [.opencode],
            period: .last7Days,
            includesBreakdown: true,
            now: now,
            calendar: calendar
        )
        let breakdownJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: breakdown) as? [String: Any])
        let modelRows = try XCTUnwrap(breakdownJSON["dailyModelBreakdown"] as? [[String: Any]])
        XCTAssertEqual(modelRows.count, 1)
        let models = try XCTUnwrap(modelRows.first?["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["model"] as? String, "opencode-sonnet")
    }

    func testCLIReportJSONSectionsEmitsEnvelope() throws {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 23, minute: 0, second: 0))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        // Today-only 3K event plus a yesterday 2K event (both inside last7Days/thisMonth).
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.06), source: "sections-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: yesterday, inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "sections-test", dataSource: .localLog),
        ]
        let data = try TokenPilotCLIService.reportJSON(
            events: events,
            enabledProviders: [.opencode],
            period: .last7Days,
            includesCost: true,
            sections: [.today, .last7Days, .thisMonth],
            now: now,
            calendar: calendar
        )
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Envelope carries an ordered sections array and a totals object last.
        let sections = try XCTUnwrap(envelope["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0]["period"] as? String, "Today")
        XCTAssertEqual(sections[0]["totalTokens"] as? Int, 3_000)
        XCTAssertEqual(sections[1]["period"] as? String, "Last 7 days")
        XCTAssertEqual(sections[1]["totalTokens"] as? Int, 5_000)
        XCTAssertEqual(sections[2]["period"] as? String, "This month")
        XCTAssertEqual(sections[2]["totalTokens"] as? Int, 5_000)
        // Totals sum across sections: 3K + 5K + 5K tokens, 1 + 2 + 2 requests,
        // and cost 0.06 + 0.10 + 0.10 = 0.26.
        let totals = try XCTUnwrap(envelope["totals"] as? [String: Any])
        XCTAssertEqual(totals["totalTokens"] as? Int, 13_000)
        XCTAssertEqual(totals["requestCount"] as? Int, 5)
        let totalCost = try XCTUnwrap(totals["estimatedCostUSD"] as? NSNumber)
        XCTAssertEqual(totalCost.doubleValue, 0.26, accuracy: 0.001)
        // No per-event source labels leak into the envelope.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("sections-test"))
    }

    func testCLIReportJSONInstancesGroupsByProject() throws {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 23, minute: 0, second: 0))!
        // project-a carries 3K tokens, project-b 2K; the combined row is 5K.
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.06), source: "instances-test", dataSource: .localLog, projectLabel: "project-a"),
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now.addingTimeInterval(-60), inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "instances-test", dataSource: .localLog, projectLabel: "project-b"),
        ]
        let data = try TokenPilotCLIService.reportJSON(
            events: events,
            enabledProviders: [.opencode],
            period: .last7Days,
            includesCost: true,
            instances: true,
            now: now,
            calendar: calendar
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Combined row stays the union of both projects.
        XCTAssertEqual(json["totalTokens"] as? Int, 5_000)
        // projects carries one full payload per workspace label (ccusage --instances style).
        let projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 2)
        let projectA = try XCTUnwrap(projects.first { $0["project"] as? String == "project-a" })
        let projectAPayload = try XCTUnwrap(projectA["payload"] as? [String: Any])
        XCTAssertEqual(projectAPayload["totalTokens"] as? Int, 3_000)
        let projectB = try XCTUnwrap(projects.first { $0["project"] as? String == "project-b" })
        let projectBPayload = try XCTUnwrap(projectB["payload"] as? [String: Any])
        XCTAssertEqual(projectBPayload["totalTokens"] as? Int, 2_000)
        // No per-event source labels leak into the payload.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("instances-test"))
    }

    func testCLIReportJSONSectionsWithInstancesCarriesProjectsPerSection() throws {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 23, minute: 0, second: 0))!
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.06), source: "sections-instances-test", dataSource: .localLog, projectLabel: "project-a"),
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now.addingTimeInterval(-60), inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "sections-instances-test", dataSource: .localLog, projectLabel: "project-b"),
        ]
        let data = try TokenPilotCLIService.reportJSON(
            events: events,
            enabledProviders: [.opencode],
            period: .last7Days,
            includesCost: true,
            sections: [.today, .last7Days],
            instances: true,
            now: now,
            calendar: calendar
        )
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sections = try XCTUnwrap(envelope["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.count, 2)
        // Every period carries its own project grouping (ccusage --sections --by-agent).
        for section in sections {
            let projects = try XCTUnwrap(section["projects"] as? [[String: Any]])
            XCTAssertEqual(projects.count, 2)
            let projectA = try XCTUnwrap(projects.first { $0["project"] as? String == "project-a" })
            let projectAPayload = try XCTUnwrap(projectA["payload"] as? [String: Any])
            XCTAssertEqual(projectAPayload["totalTokens"] as? Int, 3_000)
        }
        // Combined row per section is the union of both projects.
        XCTAssertEqual(sections[0]["totalTokens"] as? Int, 5_000)
        XCTAssertEqual(sections[1]["totalTokens"] as? Int, 5_000)
        // No per-event source labels leak.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("sections-instances-test"))
    }

    func testCLIReportBreakdownAddsPerDayPerModelSection() {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.06), source: "breakdown-test", dataSource: .localLog),
            UsageEvent(provider: .claude, model: "claude-sonnet", timestamp: yesterday, inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "breakdown-test", dataSource: .localLog),
        ]
        let text = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode, .claude],
            language: .en,
            period: .last7Days,
            includesBreakdown: true,
            now: now,
            calendar: calendar
        )
        // Breakdown section header plus per-day model lines (ccusage --breakdown style).
        XCTAssertTrue(text.contains("Breakdown"))
        XCTAssertTrue(text.contains("  opencode-sonnet: 3K tok · $0.06"))
        XCTAssertTrue(text.contains("  claude-sonnet: 2K tok · $0.04"))
        // Without the flag the breakdown section is absent.
        let plain = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode, .claude],
            language: .en,
            period: .last7Days,
            includesBreakdown: false,
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(plain.contains("Breakdown"))
        XCTAssertFalse(plain.contains("  opencode-sonnet: 3K tok"))
    }

    func testCLIReportBreakdownMarkdownUsesFencedBlock() {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.06), source: "breakdown-md", dataSource: .localLog),
        ]
        let md = TokenPilotCLIService.reportMarkdownText(
            events: events,
            enabledProviders: [.opencode],
            period: .last7Days,
            includesBreakdown: true,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(md.contains("**Breakdown**"))
        XCTAssertTrue(md.contains("```"))
        XCTAssertTrue(md.contains("  opencode-sonnet: 3K tok · $0.06"))
    }

    func testCLIReportSinceUntilFiltersEventsToDateRange() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let since = formatter.date(from: "2026-08-01")!
        let until = formatter.date(from: "2026-08-13")!
        // Two events inside the window, one well outside (before since, same provider).
        let inWindow = [
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .day, value: -1, to: until)!, inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "range-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .day, value: -2, to: until)!, inputTokens: 1_000, outputTokens: 0, estimatedCostUSD: Decimal(0.02), source: "range-test", dataSource: .localLog),
        ]
        let outside = [
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .day, value: -20, to: since)!, inputTokens: 50_000, outputTokens: 0, estimatedCostUSD: Decimal(1.00), source: "range-test", dataSource: .localLog),
        ]
        let text = TokenPilotCLIService.reportText(
            events: inWindow + outside,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            since: since,
            until: until,
            now: until.addingTimeInterval(86_400),
            calendar: calendar
        )
        // Only the two in-window events count; the 50K event is outside the range.
        XCTAssertTrue(text.contains("Total tokens: 3K"))
        XCTAssertTrue(text.contains("Requests: 2"))
        // The explicit date window is reflected in the period label.
        XCTAssertTrue(text.contains("2026-08-01 → 2026-08-13"))
    }

    func testCLIReportDaysWindowFiltersAndLabels() {
        let now = Date()
        let calendar = Calendar.current
        // Three days ago is inside a 14-day window; 30 days ago is outside.
        let recent = UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .day, value: -3, to: now)!, inputTokens: 4_000, outputTokens: 0, estimatedCostUSD: Decimal(0.08), source: "days-test", dataSource: .localLog)
        let stale = UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .day, value: -30, to: now)!, inputTokens: 20_000, outputTokens: 0, estimatedCostUSD: Decimal(0.40), source: "days-test", dataSource: .localLog)
        let text = TokenPilotCLIService.reportText(
            events: [recent, stale],
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            days: 14,
            now: now,
            calendar: calendar
        )
        // Only the 3-day-old event counts; the 30-day-old event is outside the window.
        XCTAssertTrue(text.contains("Total tokens: 4K"))
        XCTAssertTrue(text.contains("Requests: 1"))
        XCTAssertFalse(text.contains("20K"))
        // The relative window is reflected in the period label.
        XCTAssertTrue(text.contains("Last 14 days"))
    }

    func testCLIReportProjectFiltersToWorkspaceLabel() {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 5_000, outputTokens: 0, estimatedCostUSD: Decimal(0.10), source: "proj-test", dataSource: .localLog, projectLabel: "project-a"),
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "proj-test", dataSource: .localLog, projectLabel: "project-b"),
        ]
        let scoped = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            project: "project-a",
            now: now,
            calendar: calendar
        )
        // Only project-a's 5K event counts; project-b's 2K event is excluded.
        XCTAssertTrue(scoped.contains("Total tokens: 5K"))
        XCTAssertTrue(scoped.contains("Requests: 1"))
        XCTAssertFalse(scoped.contains("2K"))
        // Project ranking now reflects only the scoped label.
        XCTAssertTrue(scoped.contains("project-a"))
        XCTAssertFalse(scoped.contains("project-b"))

        let unscoped = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(unscoped.contains("Total tokens: 7K"))
        XCTAssertTrue(unscoped.contains("project-b"))
    }

    func testCLIReportTimezoneShiftsDayGrouping() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 11 PM UTC on Jan 1 is 8 AM JST on Jan 2 (ccusage's documented timezone effect).
        let eventTime = utcCalendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 23, minute: 0))!
        let event = UsageEvent(provider: .opencode, timestamp: eventTime, inputTokens: 1_000, outputTokens: 0, source: "tz-test", dataSource: .localLog)
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12, minute: 0))!

        let utcText = TokenPilotCLIService.reportText(
            events: [event],
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now,
            calendar: utcCalendar
        )
        let tokyoText = TokenPilotCLIService.reportText(
            events: [event],
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now,
            calendar: tokyoCalendar
        )
        // UTC groups the event on Jan 1; Tokyo groups it on Jan 2 (JST).
        XCTAssertTrue(utcText.contains("01-01: 1K tok"))
        XCTAssertTrue(tokyoText.contains("01-02: 1K tok"))
        XCTAssertFalse(utcText.contains("01-02: 1K tok"))
        XCTAssertFalse(tokyoText.contains("01-01: 1K tok"))
    }

    func testCLIReportStartOfWeekAlignsWindowToMonday() {
        let calendar = Calendar(identifier: .gregorian)
        // 2026-08-13 is a Thursday; Monday-aligned week start is 2026-08-10.
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 12, minute: 0))!
        let weekStart = TokenPilotCLIService.weekStartDate(.monday, now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: weekStart), 2)
        XCTAssertTrue(calendar.isDate(weekStart, inSameDayAs: calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))!))
        // An event before the week start (previous Thursday) is excluded; a current-week event counts.
        let stale = UsageEvent(provider: .opencode, timestamp: calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 10))!, inputTokens: 5_000, outputTokens: 0, source: "week-start-test", dataSource: .localLog)
        let current = UsageEvent(provider: .opencode, timestamp: calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 10))!, inputTokens: 2_000, outputTokens: 0, source: "week-start-test", dataSource: .localLog)
        let text = TokenPilotCLIService.reportText(
            events: [stale, current],
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            since: weekStart,
            now: now,
            calendar: calendar
        )
        // Only the current-week 2K event counts; the previous-week 5K event is outside the window.
        XCTAssertTrue(text.contains("Total tokens: 2K"))
        XCTAssertTrue(text.contains("Requests: 1"))
        XCTAssertFalse(text.contains("5K"))
    }

    func testCLIReportNoCostOmitsCostFigures() {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 5_000, outputTokens: 0, estimatedCostUSD: Decimal(0.50), source: "no-cost-test", dataSource: .localLog),
            UsageEvent(provider: .claude, model: "claude-sonnet", timestamp: now.addingTimeInterval(-60), inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.20), source: "no-cost-test", dataSource: .localLog),
        ]
        let withCost = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode, .claude],
            language: .en,
            period: .last7Days,
            includesCost: true,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(withCost.contains("Estimated cost: $0.70"))
        XCTAssertTrue(withCost.contains("· $0.50"))

        let noCost = TokenPilotCLIService.reportText(
            events: events,
            enabledProviders: [.opencode, .claude],
            language: .en,
            period: .last7Days,
            includesCost: false,
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(noCost.contains("Estimated cost"))
        XCTAssertFalse(noCost.contains("$"))
        // Token/request aggregates and labels still appear.
        XCTAssertTrue(noCost.contains("Total tokens: 7K"))
        XCTAssertTrue(noCost.contains("Requests: 2"))
        XCTAssertTrue(noCost.contains("opencode"))
        XCTAssertTrue(noCost.contains("claude"))

        let noCostMD = TokenPilotCLIService.reportMarkdownText(
            events: events,
            enabledProviders: [.opencode, .claude],
            period: .last7Days,
            includesCost: false,
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(noCostMD.contains("Estimated cost"))
        XCTAssertFalse(noCostMD.contains("| Cost |"))
        XCTAssertFalse(noCostMD.contains("$"))
        XCTAssertTrue(noCostMD.contains("| Total tokens | 7K |"))
        XCTAssertTrue(noCostMD.contains("| Provider | Tokens | Requests |"))
    }

    func testCLIExportNoCostBlanksCostFields() throws {
        let now = Date()
        let calendar = Calendar.current
        let events = [
            UsageEvent(provider: .opencode, model: "opencode-sonnet", timestamp: now, inputTokens: 5_000, outputTokens: 0, estimatedCostUSD: Decimal(0.50), source: "no-cost-export", dataSource: .localLog),
        ]
        let snapshots = [ProviderSnapshot(provider: .opencode, events: events)]
        let usage = AggregationService().aggregate(snapshots: snapshots, period: .last7Days, now: now)

        let jsonData = try UsageExportService().makeJSONData(
            usage: usage,
            snapshots: snapshots,
            dataMode: "CLI",
            includesCost: false
        )
        let json = String(data: jsonData, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("0.5"))
        XCTAssertFalse(json.contains("0.50"))

        let csv = UsageExportService().makeCSVString(usage: usage, includesCost: false)
        XCTAssertFalse(csv.contains("0.5"))
        XCTAssertFalse(csv.contains("0.50"))
        // CSV keeps the schema columns but blanks the cost value in the total row.
        XCTAssertTrue(csv.contains("cost_usd"))
    }

    func testCLIExportSectionsEnvelopeTotals() throws {
        let now = Date()
        let calendar = Calendar.current
        // Events are anchored in the past relative to `now` so the export service's
        // live re-aggregation (`sanitizedUsageForExport`) keeps them in the window.
        let todayEvent = UsageEvent(
            provider: .opencode,
            model: "opencode-sonnet",
            timestamp: now.addingTimeInterval(-3_600),
            inputTokens: 6_000,
            outputTokens: 0,
            estimatedCostUSD: Decimal(0.12),
            source: "sections-export-test",
            dataSource: .localLog
        )
        let yesterdayEvent = UsageEvent(
            provider: .opencode,
            model: "opencode-sonnet",
            timestamp: now.addingTimeInterval(-86_400),
            inputTokens: 2_000,
            outputTokens: 0,
            estimatedCostUSD: Decimal(0.04),
            source: "sections-export-test",
            dataSource: .localLog
        )
        let events = [todayEvent, yesterdayEvent]
        let snapshots = [ProviderSnapshot(provider: .opencode, events: events)]
        let exporter = UsageExportService()
        // Build one payload per requested period the same way runExport does.
        let payloads = [HistoryPeriod.today, .last7Days].map { section in
            let window = TokenPilotCLIService.explicitDateRange(period: section, since: nil, until: nil, days: nil, calendar: calendar)
            let usage = AggregationService().aggregate(snapshots: snapshots, period: section, customRange: window, now: now)
            return exporter.makeJSONPayload(usage: usage, snapshots: snapshots, dataMode: "CLI", generatedAt: now, includesCost: true)
        }
        let data = try exporter.makeSectionsJSON(payloads: payloads, generatedAt: now, includesCost: true)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Envelope carries an ordered sections array and a totals object last.
        let sections = try XCTUnwrap(envelope["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0]["period"] as? String, "today")
        XCTAssertEqual(sections[1]["period"] as? String, "last7Days")
        // Each section carries its own metrics; the Today section holds only today's event.
        let todayMetrics = try XCTUnwrap(sections[0]["metrics"] as? [String: Any])
        XCTAssertEqual(todayMetrics["totalTokens"] as? Int, 6_000)
        let weekMetrics = try XCTUnwrap(sections[1]["metrics"] as? [String: Any])
        XCTAssertEqual(weekMetrics["totalTokens"] as? Int, 8_000)
        // Totals sum across sections: 6K + 8K tokens, 1 + 2 requests, cost 0.12 + 0.16.
        let totals = try XCTUnwrap(envelope["totals"] as? [String: Any])
        XCTAssertEqual(totals["totalTokens"] as? Int, 14_000)
        XCTAssertEqual(totals["requestCount"] as? Int, 3)
        let totalCost = try XCTUnwrap(totals["estimatedCostUSD"] as? NSNumber)
        XCTAssertEqual(totalCost.doubleValue, 0.28, accuracy: 0.001)
        // --no-cost blanks the envelope totals without hiding the sections themselves.
        let noCostData = try exporter.makeSectionsJSON(payloads: payloads, generatedAt: now, includesCost: false)
        let noCostEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: noCostData) as? [String: Any])
        let noCostTotals = try XCTUnwrap(noCostEnvelope["totals"] as? [String: Any])
        XCTAssertNil(noCostTotals["estimatedCostUSD"])
        XCTAssertEqual(noCostTotals["totalTokens"] as? Int, 14_000)
    }

    func testCLISummaryTextUsesAggregatesOnly() {
        let now = Date()
        let event = UsageEvent(
            provider: .claude,
            model: "claude-sonnet",
            timestamp: now,
            inputTokens: 100,
            outputTokens: 50,
            requestCount: 3,
            estimatedCostUSD: Decimal(0.12),
            source: "statusline",
            dataSource: .officialStatusline
        )

        let text = TokenPilotCLIService.summaryText(
            events: [event],
            enabledProviders: [.claude],
            language: .en,
            period: .today,
            now: now
        )

        XCTAssertTrue(text.contains("Total tokens: 150"))
        XCTAssertTrue(text.contains("Requests: 3"))
        XCTAssertTrue(text.contains("$0.12"))
        XCTAssertTrue(text.contains("Claude"))
        XCTAssertFalse(text.contains("claude-sonnet"))
        XCTAssertFalse(text.contains("statusline"))
    }

    func testCLISummaryJSONPayloadMatchesSummaryText() throws {
        let now = Date()
        let event = UsageEvent(
            provider: .claude,
            model: "claude-sonnet",
            timestamp: now,
            inputTokens: 100,
            outputTokens: 50,
            requestCount: 3,
            estimatedCostUSD: Decimal(0.12),
            source: "statusline",
            dataSource: .officialStatusline
        )
        let data = try TokenPilotCLIService.summaryJSON(
            events: [event],
            enabledProviders: [.claude],
            period: .today,
            now: now
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["period"] as? String, "Today")
        XCTAssertEqual(json["totalTokens"] as? Int, 150)
        XCTAssertEqual(json["requestCount"] as? Int, 3)
        let cost = try XCTUnwrap(json["estimatedCostUSD"] as? NSNumber)
        XCTAssertEqual(cost.doubleValue, 0.12, accuracy: 0.001)
        let shares = try XCTUnwrap(json["providerShare"] as? [[String: Any]])
        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(shares.first?["provider"] as? String, "Claude Code")
        // Aggregates only: no per-event model or source leaks.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("claude-sonnet"))
        XCTAssertFalse(serialized.contains("statusline"))
    }

    func testCLISummaryNoCostBlanksCostFields() throws {
        let now = Date()
        let event = UsageEvent(
            provider: .claude,
            model: "claude-sonnet",
            timestamp: now,
            inputTokens: 100,
            outputTokens: 50,
            requestCount: 3,
            estimatedCostUSD: Decimal(0.12),
            source: "statusline",
            dataSource: .officialStatusline
        )
        // --no-cost drops the estimated-cost line and share cost from the text summary.
        let text = TokenPilotCLIService.summaryText(
            events: [event],
            enabledProviders: [.claude],
            language: .en,
            period: .today,
            includesCost: false,
            now: now
        )
        XCTAssertTrue(text.contains("Total tokens: 150"))
        XCTAssertTrue(text.contains("Requests: 3"))
        XCTAssertFalse(text.contains("$0.12"))

        // JSON payload nils both the payload cost and the per-share cost.
        let data = try TokenPilotCLIService.summaryJSON(
            events: [event],
            enabledProviders: [.claude],
            period: .today,
            includesCost: false,
            now: now
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["estimatedCostUSD"])
        let shares = try XCTUnwrap(json["providerShare"] as? [[String: Any]])
        XCTAssertNil(shares.first?["estimatedCostUSD"])
    }

    func testCLISummaryPeriodSelectsWindow() throws {
        let calendar = Calendar.current
        let now = Date()
        // Six days ago sits at the inclusive edge of the last7Days window.
        let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now)!
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 3_000, outputTokens: 0, estimatedCostUSD: Decimal(0.06), source: "period-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: sixDaysAgo, inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "period-test", dataSource: .localLog),
        ]
        // last7Days includes both events and is labeled "Last 7 days".
        let text = TokenPilotCLIService.summaryText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now
        )
        XCTAssertTrue(text.contains("Period: Last 7 days"))
        XCTAssertTrue(text.contains("Total tokens: 5K"))
        XCTAssertTrue(text.contains("Requests: 2"))

        // today excludes the six-days-ago event.
        let todayText = TokenPilotCLIService.summaryText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            period: .today,
            now: now
        )
        XCTAssertTrue(todayText.contains("Total tokens: 3K"))
        XCTAssertTrue(todayText.contains("Requests: 1"))

        // JSON payload reflects the selected period label.
        let data = try TokenPilotCLIService.summaryJSON(
            events: events,
            enabledProviders: [.opencode],
            period: .thisMonth,
            now: now
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["period"] as? String, "This month")
        XCTAssertEqual(json["totalTokens"] as? Int, 5_000)
        XCTAssertEqual(json["requestCount"] as? Int, 2)
    }

    func testCLISummaryWindowSelectorsFilterEvents() throws {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let since = formatter.date(from: "2026-08-01")!
        let until = formatter.date(from: "2026-08-13")!
        // Two events inside the window, one well outside (before since, same provider).
        let inWindow = [
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .day, value: -1, to: until)!, inputTokens: 2_000, outputTokens: 0, estimatedCostUSD: Decimal(0.04), source: "range-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .day, value: -2, to: until)!, inputTokens: 1_000, outputTokens: 0, estimatedCostUSD: Decimal(0.02), source: "range-test", dataSource: .localLog),
        ]
        let outside = [
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .day, value: -20, to: since)!, inputTokens: 50_000, outputTokens: 0, estimatedCostUSD: Decimal(1.00), source: "range-test", dataSource: .localLog),
        ]
        let text = TokenPilotCLIService.summaryText(
            events: inWindow + outside,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            since: since,
            until: until,
            now: until.addingTimeInterval(86_400),
            calendar: calendar
        )
        // Only the two in-window events count; the 50K event is outside the range.
        XCTAssertTrue(text.contains("Total tokens: 3K"))
        XCTAssertTrue(text.contains("Requests: 2"))
        // The explicit date window is reflected in the period label.
        XCTAssertTrue(text.contains("2026-08-01 → 2026-08-13"))

        // --days narrows the window the same way it does for report.
        let daysText = TokenPilotCLIService.summaryText(
            events: inWindow + outside,
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            days: 3,
            now: until,
            calendar: calendar
        )
        XCTAssertTrue(daysText.contains("Total tokens: 3K"))
        XCTAssertTrue(daysText.contains("Requests: 2"))
        XCTAssertFalse(daysText.contains("50K"))

        // JSON payload honors the explicit window in its period label and totals.
        let data = try TokenPilotCLIService.summaryJSON(
            events: inWindow + outside,
            enabledProviders: [.opencode],
            period: .last7Days,
            since: since,
            until: until,
            now: until.addingTimeInterval(86_400),
            calendar: calendar
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["period"] as? String, "2026-08-01 → 2026-08-13")
        XCTAssertEqual(json["totalTokens"] as? Int, 3_000)
        XCTAssertEqual(json["requestCount"] as? Int, 2)
    }

    func testCLIStatsTextDerivesWindowStatistics() {
        let calendar = Calendar.current
        // Fixed 23:00 anchor so the 15:30/09:00 fixtures are always inside the window.
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 23, minute: 0, second: 0))!
        // Two active days: today (heavier) and yesterday; busiest hour is 15:00.
        let todayEvent = UsageEvent(
            provider: .opencode,
            model: "opencode-sonnet",
            timestamp: calendar.date(bySettingHour: 15, minute: 30, second: 0, of: now)!,
            inputTokens: 6_000,
            outputTokens: 0,
            estimatedCostUSD: Decimal(0.12),
            source: "stats-test",
            dataSource: .localLog
        )
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let yesterdayEvent = UsageEvent(
            provider: .opencode,
            model: "opencode-sonnet",
            timestamp: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: yesterday)!,
            inputTokens: 2_000,
            outputTokens: 0,
            estimatedCostUSD: Decimal(0.04),
            source: "stats-test",
            dataSource: .localLog
        )
        let text = TokenPilotCLIService.statsText(
            events: [todayEvent, yesterdayEvent],
            enabledProviders: [.opencode],
            language: .en,
            period: .last7Days,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Total tokens: 8K"))
        XCTAssertTrue(text.contains("Requests: 2"))
        XCTAssertTrue(text.contains("$0.16"))
        // Two distinct active days; daily average over the 7-day window (8000/7 ≈ 1.1K).
        XCTAssertTrue(text.contains("Active days: 2"))
        XCTAssertTrue(text.contains("Daily average: 1.1K tok"))
        // Busiest day (today) and busiest hour (15:00) are reported.
        XCTAssertTrue(text.contains("Busiest day:"))
        XCTAssertTrue(text.contains("Busiest hour: 15:00"))
        XCTAssertTrue(text.contains("Most used provider: opencode"))
        // Aggregates-only: no per-event model or source leaks.
        XCTAssertFalse(text.contains("opencode-sonnet"))
        XCTAssertFalse(text.contains("stats-test"))
    }

    func testCLIStatsJSONPayloadMatchesTextStatistics() throws {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 23, minute: 0, second: 0))!
        let todayEvent = UsageEvent(
            provider: .opencode,
            model: "opencode-sonnet",
            timestamp: calendar.date(bySettingHour: 15, minute: 30, second: 0, of: now)!,
            inputTokens: 6_000,
            outputTokens: 0,
            estimatedCostUSD: Decimal(0.12),
            source: "stats-test",
            dataSource: .localLog
        )
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let yesterdayEvent = UsageEvent(
            provider: .opencode,
            model: "opencode-sonnet",
            timestamp: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: yesterday)!,
            inputTokens: 2_000,
            outputTokens: 0,
            estimatedCostUSD: Decimal(0.04),
            source: "stats-test",
            dataSource: .localLog
        )
        let data = try TokenPilotCLIService.statsJSON(
            events: [todayEvent, yesterdayEvent],
            enabledProviders: [.opencode],
            period: .last7Days,
            includesCost: true,
            now: now,
            calendar: calendar
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["period"] as? String, "Last 7 days")
        XCTAssertEqual(json["totalTokens"] as? Int, 8_000)
        XCTAssertEqual(json["requestCount"] as? Int, 2)
        let cost = try XCTUnwrap(json["estimatedCostUSD"] as? NSNumber)
        XCTAssertEqual(cost.doubleValue, 0.16, accuracy: 0.001)
        XCTAssertEqual(json["activeDays"] as? Int, 2)
        XCTAssertEqual(json["dailyAverage"] as? Int, 8_000 / 7)
        XCTAssertEqual(json["busiestDay"] as? String, "08-13")
        XCTAssertEqual(json["busiestHour"] as? Int, 15)
        XCTAssertEqual(json["mostUsedProvider"] as? String, "opencode")
        // Per-provider model breakdown (ccusage --by-agent style): each provider lists
        // its models and per-provider totals sum exactly to the combined row.
        let providers = try XCTUnwrap(json["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.count, 1)
        let opencodeRow = try XCTUnwrap(providers.first)
        XCTAssertEqual(opencodeRow["provider"] as? String, "opencode")
        XCTAssertEqual(opencodeRow["tokens"] as? Int, 8_000)
        XCTAssertEqual(opencodeRow["requestCount"] as? Int, 2)
        let opencodeRowCost = try XCTUnwrap(opencodeRow["estimatedCostUSD"] as? NSNumber)
        XCTAssertEqual(opencodeRowCost.doubleValue, 0.16, accuracy: 0.001)
        let models = try XCTUnwrap(opencodeRow["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?["model"] as? String, "opencode-sonnet")
        XCTAssertEqual(models.first?["tokens"] as? Int, 8_000)
        // Source labels still never leak; model names are legitimate breakdown data.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("stats-test"))

        // --no-cost omits the cost field entirely (toktrack stats --json --no-cost style).
        let noCost = try TokenPilotCLIService.statsJSON(
            events: [todayEvent, yesterdayEvent],
            enabledProviders: [.opencode],
            period: .last7Days,
            includesCost: false,
            now: now,
            calendar: calendar
        )
        let noCostJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: noCost) as? [String: Any])
        XCTAssertNil(noCostJSON["estimatedCostUSD"])
        // The provider breakdown also hides cost when --no-cost is set.
        let noCostProviders = try XCTUnwrap(noCostJSON["providers"] as? [[String: Any]])
        XCTAssertNil(noCostProviders.first?["estimatedCostUSD"])
        let noCostModels = try XCTUnwrap(noCostProviders.first?["models"] as? [[String: Any]])
        XCTAssertNil(noCostModels.first?["estimatedCostUSD"])
    }

    func testCLIStatsJSONSectionsEmitsEnvelope() throws {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 23, minute: 0, second: 0))!
        let todayEvent = UsageEvent(
            provider: .opencode,
            model: "opencode-sonnet",
            timestamp: calendar.date(bySettingHour: 15, minute: 30, second: 0, of: now)!,
            inputTokens: 6_000,
            outputTokens: 0,
            estimatedCostUSD: Decimal(0.12),
            source: "stats-sections-test",
            dataSource: .localLog
        )
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let yesterdayEvent = UsageEvent(
            provider: .opencode,
            model: "opencode-sonnet",
            timestamp: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: yesterday)!,
            inputTokens: 2_000,
            outputTokens: 0,
            estimatedCostUSD: Decimal(0.04),
            source: "stats-sections-test",
            dataSource: .localLog
        )
        let data = try TokenPilotCLIService.statsJSON(
            events: [todayEvent, yesterdayEvent],
            enabledProviders: [.opencode],
            period: .last7Days,
            includesCost: true,
            sections: [.today, .last7Days],
            now: now,
            calendar: calendar
        )
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Envelope carries an ordered sections array and a totals object last.
        let sections = try XCTUnwrap(envelope["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0]["period"] as? String, "Today")
        XCTAssertEqual(sections[0]["totalTokens"] as? Int, 6_000)
        XCTAssertEqual(sections[0]["requestCount"] as? Int, 1)
        XCTAssertEqual(sections[1]["period"] as? String, "Last 7 days")
        XCTAssertEqual(sections[1]["totalTokens"] as? Int, 8_000)
        XCTAssertEqual(sections[1]["requestCount"] as? Int, 2)
        // Totals sum across sections: 6K + 8K tokens, 1 + 2 requests, cost 0.12 + 0.16.
        let totals = try XCTUnwrap(envelope["totals"] as? [String: Any])
        XCTAssertEqual(totals["totalTokens"] as? Int, 14_000)
        XCTAssertEqual(totals["requestCount"] as? Int, 3)
        let totalCost = try XCTUnwrap(totals["estimatedCostUSD"] as? NSNumber)
        XCTAssertEqual(totalCost.doubleValue, 0.28, accuracy: 0.001)
        // Each section carries its own per-provider model breakdown; the Today section
        // holds only today's event while the 7-day section holds both events.
        let todayProviders = try XCTUnwrap(sections[0]["providers"] as? [[String: Any]])
        XCTAssertEqual(todayProviders.count, 1)
        XCTAssertEqual(todayProviders.first?["tokens"] as? Int, 6_000)
        let weekProviders = try XCTUnwrap(sections[1]["providers"] as? [[String: Any]])
        XCTAssertEqual(weekProviders.count, 1)
        XCTAssertEqual(weekProviders.first?["tokens"] as? Int, 8_000)
        // Source labels still never leak; model names are legitimate breakdown data.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("stats-sections-test"))
    }

    func testCLISummaryTextIncludesCapacityRemaining() {
        let now = Date()
        let snapshot = ProviderSnapshot(
            provider: .claude,
            updatedAt: now,
            fiveHour: LimitWindow(
                kind: .fiveHour,
                usedPercent: 60,
                resetAt: now.addingTimeInterval(3_600),
                confidence: .medium
            ),
            confidence: .medium,
            dataSource: .officialStatusline,
            events: []
        )

        let text = TokenPilotCLIService.summaryText(
            events: [],
            snapshots: [snapshot],
            enabledProviders: [.claude],
            language: .en,
            period: .today,
            now: now
        )

        XCTAssertTrue(text.contains("Claude Code (5h window): 40% Remaining"))
    }

    func testMenuBarSparklineNormalizesRemainingPercentTrend() {
        let now = Date()
        let samples = [
            ProviderLimitSample(
                provider: .claude,
                timestamp: now.addingTimeInterval(-3_600),
                window: .fiveHour,
                usedPercent: 80,
                remainingPercent: 20,
                source: "limit-history"
            ),
            ProviderLimitSample(
                provider: .claude,
                timestamp: now.addingTimeInterval(-2_400),
                window: .fiveHour,
                usedPercent: 60,
                remainingPercent: 40,
                source: "limit-history"
            ),
            ProviderLimitSample(
                provider: .claude,
                timestamp: now.addingTimeInterval(-1_200),
                window: .fiveHour,
                usedPercent: 30,
                remainingPercent: 70,
                source: "limit-history"
            ),
            ProviderLimitSample(
                provider: .codex,
                timestamp: now.addingTimeInterval(-600),
                window: .fiveHour,
                usedPercent: 50,
                remainingPercent: 50,
                source: "limit-history"
            ),
            ProviderLimitSample(
                provider: .claude,
                timestamp: now.addingTimeInterval(-300),
                window: .weekly,
                usedPercent: 90,
                remainingPercent: 10,
                source: "limit-history"
            )
        ]

        let fiveHour = MenuBarSparklineService.normalizedValues(
            samples: samples,
            provider: .claude,
            window: .fiveHour,
            now: now
        )
        XCTAssertEqual(fiveHour, [0.2, 0.4, 0.7])

        let anyWindow = MenuBarSparklineService.normalizedValues(
            samples: samples,
            provider: .claude,
            now: now
        )
        XCTAssertEqual(anyWindow, [0.2, 0.4, 0.7, 0.1])

        let otherProvider = MenuBarSparklineService.normalizedValues(
            samples: samples,
            provider: .deepseek,
            now: now
        )
        XCTAssertTrue(otherProvider.isEmpty)
    }

    func testMenuBarSparklineCapsCountAndSkipsDegenerateSeries() {
        let now = Date()
        let samples = (0..<10).map { index in
            ProviderLimitSample(
                provider: .claude,
                timestamp: now.addingTimeInterval(-Double(10 - index) * 60),
                window: .fiveHour,
                usedPercent: index * 5,
                remainingPercent: 100 - index * 5,
                source: "limit-history"
            )
        }

        let capped = MenuBarSparklineService.normalizedValues(
            samples: samples,
            provider: .claude,
            maxCount: 3,
            now: now
        )
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(capped, [0.65, 0.6, 0.55])

        let single = MenuBarSparklineService.normalizedValues(
            samples: Array(samples.prefix(1)),
            provider: .claude,
            now: now
        )
        XCTAssertTrue(single.isEmpty)
    }

    func testMenuBarSparklineWindowKindMapping() {
        XCTAssertEqual(MenuBarSparklineService.windowKind(forSeriesID: "claude/five-hour"), .fiveHour)
        XCTAssertEqual(MenuBarSparklineService.windowKind(forSeriesID: "claude/seven-day"), .weekly)
        XCTAssertEqual(MenuBarSparklineService.windowKind(forSeriesID: "gemini/daily-requests"), .dailyRequests)
        XCTAssertNil(MenuBarSparklineService.windowKind(forSeriesID: "codex/rolling"))
        XCTAssertNil(MenuBarSparklineService.windowKind(forSeriesID: "xai/oauth-weekly"))
    }

    func testMenuBarSegmentCarriesSparklineForProviderReportedPercent() {
        let now = Date()
        let snapshot = ProviderSnapshot(
            provider: .claude,
            updatedAt: now,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 60, resetAt: now.addingTimeInterval(3_600), confidence: .medium),
            confidence: .medium,
            dataSource: .officialStatusline,
            events: []
        )
        let samples = [
            ProviderLimitSample(
                provider: .claude,
                timestamp: now.addingTimeInterval(-3_600),
                window: .fiveHour,
                usedPercent: 80,
                remainingPercent: 20,
                source: "limit-history"
            ),
            ProviderLimitSample(
                provider: .claude,
                timestamp: now.addingTimeInterval(-1_800),
                window: .fiveHour,
                usedPercent: 60,
                remainingPercent: 40,
                source: "limit-history"
            )
        ]

        let segments = MenuBarStatusService().providerMetricsSegments(
            snapshots: [snapshot],
            settings: AppSettings(),
            now: now,
            limitSamples: samples
        )

        let claude = segments.first { $0.provider == .claude }
        XCTAssertEqual(claude?.displayValue, "40%")
        XCTAssertEqual(claude?.sparklineValues, [0.2, 0.4])
    }

    func testDailyGoalProgressMath() {
        XCTAssertEqual(
            DailyGoalService.progress(tokens: 0, targetTokens: 10_000),
            DailyGoalProgress(tokens: 0, targetTokens: 10_000, percent: 0)
        )
        XCTAssertEqual(DailyGoalService.progress(tokens: 5_000, targetTokens: 10_000).percent, 50)
        XCTAssertEqual(DailyGoalService.progress(tokens: 10_000, targetTokens: 10_000).percent, 100)
        XCTAssertEqual(DailyGoalService.progress(tokens: 20_000, targetTokens: 10_000).percent, 100)
        XCTAssertEqual(DailyGoalService.progress(tokens: 500, targetTokens: 0).targetTokens, 1)
    }

    // MARK: - SettingsBackupService

    func testSettingsBackupRoundTripsSettings() throws {
        var settings = AppSettings()
        settings.challengeTargetTokens = 42_000
        settings.weekStartDay = .sunday
        settings.menuBarPrimaryMetric = .todayCost
        settings.budget.dailyTokens = 20_000

        let service = SettingsBackupService()
        let data = try service.exportData(settings: settings)
        let imported = try service.importSettings(from: data)

        XCTAssertEqual(imported.challengeTargetTokens, 42_000)
        XCTAssertEqual(imported.weekStartDay, .sunday)
        XCTAssertEqual(imported.menuBarPrimaryMetric, .todayCost)
        XCTAssertEqual(imported.budget.dailyTokens, 20_000)
    }

    func testSettingsBackupScrubsTelegramChatID() throws {
        var settings = AppSettings()
        settings.telegram.isEnabled = true
        settings.telegram.chatID = "123456789"
        settings.telegram.connectionStatus = "Connected"

        let service = SettingsBackupService()
        let data = try service.exportData(settings: settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let telegram = try XCTUnwrap(json["telegram"] as? [String: Any])

        XCTAssertEqual(telegram["chatID"] as? String, "")
        XCTAssertEqual(telegram["isEnabled"] as? Bool, true)

        let imported = try service.importSettings(from: data)
        XCTAssertEqual(imported.telegram.chatID, "")
        XCTAssertEqual(imported.telegram.isEnabled, true)
    }

    func testSettingsBackupRejectsInvalidPayload() {
        let service = SettingsBackupService()
        XCTAssertThrowsError(try service.importSettings(from: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? SettingsBackupError, .invalidPayload)
        }
    }

    // MARK: - WeekStartDay

    func testWeekStartDayDaysBefore() {
        // Calendar weekday: Sun=1, Mon=2, Tue=3, Wed=4, Thu=5, Fri=6, Sat=7.
        // daysBefore(weekday) = days to roll back from `weekday` to this week's start.
        XCTAssertEqual(WeekStartDay.monday.daysBefore(1), 6)
        XCTAssertEqual(WeekStartDay.monday.daysBefore(2), 0)
        XCTAssertEqual(WeekStartDay.sunday.daysBefore(1), 0)
        XCTAssertEqual(WeekStartDay.saturday.daysBefore(4), 4)
        XCTAssertEqual(WeekStartDay.tuesday.daysBefore(2), 6)
    }

    func testBudgetGuardrailWeeklyProgressHonorsWeekStartDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        // Friday 2026-08-14. Sunday-start week begins 2026-08-09; Monday-start begins 2026-08-10.
        let friday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 12))
        )
        let sundayStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 9)))
        let mondayStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10)))

        let settings = BudgetGuardrailSettings(weeklyTokens: 100_000)
        let service = BudgetGuardrailService()
        let events = [
            UsageEvent(provider: .opencode, timestamp: sundayStart.addingTimeInterval(3_600), inputTokens: 10_000, outputTokens: 0, source: "week-test", dataSource: .localLog)
        ]

        let sundayWeek = service.weeklyProgress(events: events, settings: settings, now: friday, calendar: calendar, weekStartDay: .sunday)
        XCTAssertEqual(sundayWeek.tokens, 10_000)

        let mondayWeek = service.weeklyProgress(events: events, settings: settings, now: friday, calendar: calendar, weekStartDay: .monday)
        XCTAssertEqual(mondayWeek.tokens, 0)
    }

    func testWeeklyDigestHonorsWeekStartDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let sunday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 18)))
        let friday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 18)))
        let events = [
            UsageEvent(provider: .opencode, timestamp: sunday.addingTimeInterval(3_600), inputTokens: 5_000, outputTokens: 0, source: "week-test", dataSource: .localLog)
        ]

        let sundayText = WeeklyDigestService.digestText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            now: friday,
            calendar: calendar,
            weekStartDay: .sunday
        )
        XCTAssertTrue(sundayText.contains("Total tokens: 5K"))

        let mondayText = WeeklyDigestService.digestText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            now: friday,
            calendar: calendar,
            weekStartDay: .monday
        )
        XCTAssertTrue(mondayText.contains("Total tokens: 0"))
    }

    func testWeeklyDigestGateFireWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let monday9 = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))
        )

        XCTAssertTrue(WeeklyDigestGate.isInFireWindow(now: monday9.addingTimeInterval(5 * 60), lastSentAt: nil, calendar: calendar))
        XCTAssertFalse(WeeklyDigestGate.isInFireWindow(now: monday9.addingTimeInterval(-60), lastSentAt: nil, calendar: calendar))
        XCTAssertFalse(WeeklyDigestGate.isInFireWindow(now: monday9.addingTimeInterval(2 * 3_600), lastSentAt: nil, calendar: calendar))
        XCTAssertFalse(WeeklyDigestGate.isInFireWindow(now: monday9.addingTimeInterval(5 * 60), lastSentAt: monday9, calendar: calendar))

        let lastWeekMonday = monday9.addingTimeInterval(-7 * 24 * 3_600)
        XCTAssertTrue(WeeklyDigestGate.isInFireWindow(now: monday9.addingTimeInterval(5 * 60), lastSentAt: lastWeekMonday, calendar: calendar))
    }

    func testWeeklyDigestGateHonorsCustomSchedule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        // Custom schedule 15:30: only fires inside the 15:30–16:30 window.
        let schedule = WeeklyDigestSchedule(hour: 15, minute: 30)
        let monday1530 = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 15, minute: 30))
        )

        XCTAssertTrue(WeeklyDigestGate.isInFireWindow(now: monday1530.addingTimeInterval(5 * 60), lastSentAt: nil, calendar: calendar, schedule: schedule))
        XCTAssertFalse(WeeklyDigestGate.isInFireWindow(now: monday1530.addingTimeInterval(-60), lastSentAt: nil, calendar: calendar, schedule: schedule))
        XCTAssertFalse(WeeklyDigestGate.isInFireWindow(now: monday1530.addingTimeInterval(2 * 3_600), lastSentAt: nil, calendar: calendar, schedule: schedule))
        // The default 09:00 schedule does not fire at 15:30.
        XCTAssertFalse(WeeklyDigestGate.isInFireWindow(now: monday1530.addingTimeInterval(5 * 60), lastSentAt: nil, calendar: calendar))
    }

    func testWeeklyDigestTextAggregatesWeekToDateOnly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let monday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))
        )
        let friday = monday.addingTimeInterval(4 * 24 * 3_600 + 2 * 3_600)
        let events = [
            UsageEvent(
                provider: .claude,
                model: "claude-sonnet",
                timestamp: monday.addingTimeInterval(3_600),
                inputTokens: 100,
                outputTokens: 23,
                requestCount: 2,
                estimatedCostUSD: Decimal(0.30),
                source: "statusline",
                dataSource: .officialStatusline
            ),
            UsageEvent(
                provider: .codex,
                model: "codex-mini",
                timestamp: friday,
                inputTokens: 400,
                outputTokens: 56,
                requestCount: 1,
                estimatedCostUSD: Decimal(0.20),
                source: "session-jsonl",
                dataSource: .localLog
            ),
            UsageEvent(
                provider: .gemini,
                timestamp: monday.addingTimeInterval(-24 * 3_600),
                inputTokens: 999,
                source: "telemetry"
            )
        ]

        let text = WeeklyDigestService.digestText(
            events: events,
            enabledProviders: [.claude, .codex, .gemini],
            language: .en,
            now: friday,
            calendar: calendar
        )

        XCTAssertTrue(text.contains("This week"))
        XCTAssertTrue(text.contains("Total tokens: 579"))
        XCTAssertTrue(text.contains("Requests: 3"))
        XCTAssertTrue(text.contains("$0.50"))
        XCTAssertTrue(text.contains("Top provider: Codex (79%)"))
        XCTAssertFalse(text.contains("statusline"))
        XCTAssertFalse(text.contains("session-jsonl"))
        XCTAssertFalse(text.contains("claude-sonnet"))
        XCTAssertFalse(text.contains("999"))
    }

    func testWeeklyDigestIncludesTopModel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let monday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))
        )
        // model-a has the most tokens this week.
        let events = [
            UsageEvent(provider: .opencode, model: "model-a", timestamp: monday, inputTokens: 800, outputTokens: 0, source: "report-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, model: "model-b", timestamp: monday, inputTokens: 200, outputTokens: 0, source: "report-test", dataSource: .localLog),
        ]

        let text = WeeklyDigestService.digestText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            now: monday,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Top model: model-a (80%)"))
    }

    func testWeeklyDigestIncludesCacheHitRate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let monday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))
        )
        // 6K cache reads / 10K context reads = 60% hit rate.
        let events = [
            UsageEvent(provider: .opencode, timestamp: monday, inputTokens: 4_000, cacheReadTokens: 6_000, source: "report-test", dataSource: .localLog),
        ]

        let text = WeeklyDigestService.digestText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            now: monday,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Cache hit rate: 60%"))
    }

    func testWeeklyDigestIncludesBudgetUsage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let monday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))
        )
        // 5K of a 10K weekly budget -> 50%.
        let events = [
            UsageEvent(provider: .opencode, timestamp: monday, inputTokens: 5_000, outputTokens: 0, source: "report-test", dataSource: .localLog),
        ]
        let budget = BudgetGuardrailSettings(weeklyTokens: 10_000)

        let text = WeeklyDigestService.digestText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            now: monday,
            calendar: calendar,
            budget: budget
        )
        XCTAssertTrue(text.contains("Weekly budget used: 50%"))
    }

    func testWeeklyDigestTextLocalizedKorean() {
        let text = WeeklyDigestService.digestText(
            events: [],
            enabledProviders: [.claude],
            language: .ko,
            now: Date()
        )
        XCTAssertTrue(text.contains("이번 주"))
        XCTAssertTrue(text.contains("전체 토큰"))
    }

    func testWeeklyDigestStoreRoundtrip() {
        let suite = "TokenPilotWeeklyDigestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WeeklyDigestStore(defaults: defaults)

        XCTAssertNil(store.loadLastSent())
        let date = Date()
        store.saveLastSent(date)
        XCTAssertEqual(store.loadLastSent(), date)
    }

    func testDailyDigestGateFireWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let sixPM = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18))
        )

        XCTAssertTrue(DailyDigestGate.isInFireWindow(now: sixPM.addingTimeInterval(5 * 60), lastSentAt: nil, calendar: calendar))
        XCTAssertFalse(DailyDigestGate.isInFireWindow(now: sixPM.addingTimeInterval(-60), lastSentAt: nil, calendar: calendar))
        XCTAssertFalse(DailyDigestGate.isInFireWindow(now: sixPM.addingTimeInterval(2 * 3_600), lastSentAt: nil, calendar: calendar))
        XCTAssertFalse(DailyDigestGate.isInFireWindow(now: sixPM.addingTimeInterval(5 * 60), lastSentAt: sixPM, calendar: calendar))

        let yesterday = sixPM.addingTimeInterval(-24 * 3_600)
        XCTAssertTrue(DailyDigestGate.isInFireWindow(now: sixPM.addingTimeInterval(5 * 60), lastSentAt: yesterday, calendar: calendar))
    }

    func testDailyDigestTextAggregatesTodayOnly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18))
        )
        let today = now.addingTimeInterval(-3_600)
        let yesterday = now.addingTimeInterval(-24 * 3_600)
        let events = [
            UsageEvent(
                provider: .claude,
                timestamp: today,
                inputTokens: 100,
                outputTokens: 23,
                requestCount: 2,
                estimatedCostUSD: Decimal(0.30),
                source: "statusline",
                dataSource: .officialStatusline
            ),
            UsageEvent(
                provider: .codex,
                timestamp: yesterday,
                inputTokens: 400,
                outputTokens: 56,
                requestCount: 1,
                estimatedCostUSD: Decimal(0.20),
                source: "session-jsonl",
                dataSource: .localLog
            ),
        ]

        let text = DailyDigestService.digestText(
            events: events,
            enabledProviders: [.claude, .codex],
            language: .en,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Total tokens: 123"))
        XCTAssertTrue(text.contains("Requests: 2"))
        XCTAssertTrue(text.contains("Estimated cost: $0.30"))
        XCTAssertTrue(text.contains("Local activity, not provider quota"))
        XCTAssertFalse(text.contains("456"))
    }

    func testDailyDigestIncludesTopModel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18))
        )
        // model-a has the most tokens today.
        let events = [
            UsageEvent(provider: .opencode, model: "model-a", timestamp: now, inputTokens: 800, outputTokens: 0, source: "report-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, model: "model-b", timestamp: now, inputTokens: 200, outputTokens: 0, source: "report-test", dataSource: .localLog),
        ]

        let text = DailyDigestService.digestText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Top model: model-a (80%)"))
    }

    func testDailyDigestIncludesCacheHitRate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18))
        )
        // 5K cache reads / 10K context reads = 50% hit rate.
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 5_000, cacheReadTokens: 5_000, source: "report-test", dataSource: .localLog),
        ]

        let text = DailyDigestService.digestText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Cache hit rate: 50%"))
    }

    func testDailyDigestIncludesBudgetUsage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18))
        )
        // 3K of a 6K daily budget -> 50%.
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 3_000, outputTokens: 0, source: "report-test", dataSource: .localLog),
        ]
        let budget = BudgetGuardrailSettings(dailyTokens: 6_000)

        let text = DailyDigestService.digestText(
            events: events,
            enabledProviders: [.opencode],
            language: .en,
            now: now,
            calendar: calendar,
            budget: budget
        )
        XCTAssertTrue(text.contains("Daily budget used: 50%"))
    }

    func testDailyDigestStoreRoundtrip() {
        let suite = "TokenPilotDailyDigestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DailyDigestStore(defaults: defaults)

        XCTAssertNil(store.loadLastSent())
        let date = Date()
        store.saveLastSent(date)
        XCTAssertEqual(store.loadLastSent(), date)
    }

    func testRefreshIntervalDefaultsAndClamp() {
        XCTAssertEqual(AppSettings().refreshIntervalSeconds, 60)
        XCTAssertFalse(AppSettings().menuBarHotkeyEnabled)

        let suite = "TokenPilotRefreshIntervalTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokenPilotSettingsStore(defaults: defaults)

        var settings = AppSettings()
        settings.refreshIntervalSeconds = 5
        store.save(settings)
        XCTAssertEqual(store.load().refreshIntervalSeconds, 15)

        settings.refreshIntervalSeconds = 9_999
        store.save(settings)
        XCTAssertEqual(store.load().refreshIntervalSeconds, 900)

        settings.refreshIntervalSeconds = 120
        settings.menuBarHotkeyEnabled = true
        settings.challengeTargetTokens = 0
        settings.weeklyDigestEnabled = true
        store.save(settings)
        let loaded = store.load()
        XCTAssertEqual(loaded.refreshIntervalSeconds, 120)
        XCTAssertTrue(loaded.menuBarHotkeyEnabled)
        XCTAssertEqual(loaded.challengeTargetTokens, 1)
        XCTAssertTrue(loaded.weeklyDigestEnabled)
    }

    func testSettingsStoreResetToDefaults() {
        let suite = "TokenPilotSettingsResetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokenPilotSettingsStore(defaults: defaults)

        var custom = AppSettings()
        custom.refreshIntervalSeconds = 300
        custom.weeklyDigestEnabled = true
        custom.weekStartDay = .sunday
        custom.challengeTargetTokens = 500_000
        store.save(custom)

        let reset = store.resetToDefaults()
        XCTAssertEqual(reset.refreshIntervalSeconds, 60)
        XCTAssertFalse(reset.weeklyDigestEnabled)
        XCTAssertEqual(reset.weekStartDay, .monday)
        XCTAssertEqual(reset.challengeTargetTokens, 10_000)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.refreshIntervalSeconds, 60)
        XCTAssertEqual(reloaded.weekStartDay, .monday)
    }

    func testLegacySettingsDecodeKeepsNewDefaults() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"launchAtLogin": true}"#.utf8)
        )
        XCTAssertEqual(decoded.refreshIntervalSeconds, 60)
        XCTAssertFalse(decoded.menuBarHotkeyEnabled)
        XCTAssertFalse(decoded.weeklyDigestEnabled)
    }

    private func abortKeychainTestOnAuthorizationError(_ error: Error) throws {
        #if canImport(Security)
        guard case let KeychainError.unhandledStatus(status) = error,
              (status == -60006 || status == -60008) else {
            return
        }
        throw XCTSkip("Skipping keychain persistence assertions: keychain authorization unavailable (status: \(status)).")
        #endif
    }

    func testKeychainDeleteSecret_ThrowsNotFound_WhenItemMissing() throws {
        let service = KeychainService(service: "com.tokenpilot.tests.\(UUID().uuidString)", backend: InMemoryKeychainBackend())

        XCTAssertThrowsError(try service.deleteSecret(account: "missing-\(UUID().uuidString)")) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
    }

    func testKeychainDeleteSecret_SavesThenDeletesValue() throws {
        let service = KeychainService(service: "com.tokenpilot.tests.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
        let account = "test-\(UUID().uuidString)"
        let value = "token-value-\(UUID().uuidString)"

        try service.saveSecret(value, account: account)
        XCTAssertEqual(try service.readSecret(account: account), value)
        try service.deleteSecret(account: account)
        XCTAssertNil(try service.readSecret(account: account))
        try service.saveSecret(value, account: account)
        XCTAssertEqual(try service.readSecret(account: account), value)
        try service.deleteSecret(account: account)
        XCTAssertNil(try service.readSecret(account: account))
    }

    func testXAIManagementKeychainAccountStoresAndDeletesPresenceOnly() throws {
        let service = KeychainService(service: "com.tokenpilot.tests.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
        let account = KeychainService.xaiManagementAPIKeyAccount

        XCTAssertEqual(account, "xai.managementAPIKey")
        XCTAssertNil(try service.readSecret(account: account))

        try service.saveSecret("fixture-management-value", account: account)

        XCTAssertEqual(try service.readSecret(account: account), "fixture-management-value")
        XCTAssertTrue(try service.readSecret(account: account) != nil)

        try service.deleteSecret(account: account)

        XCTAssertNil(try service.readSecret(account: account))
        XCTAssertThrowsError(try service.deleteSecret(account: account)) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
    }

    func testSecurityScopedBookmarkServiceResolvesReadOnlyBookmark() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TokenPilotBookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("telemetry.log")
        try "{}".write(to: file, atomically: true, encoding: .utf8)

        let bookmark = try TokenPilotSecurityScopedBookmarks.makeReadOnlyBookmarkData(for: file)
        let access = try TokenPilotSecurityScopedBookmarks.resolve(bookmarkData: bookmark, fallbackPath: file.path)
        defer { access.stop() }

        XCTAssertEqual(access.url.standardizedFileURL.path, file.standardizedFileURL.path)
    }

    func testCommercialDefaultDoesNotShowSampleDataAsRealUsage() throws {
        XCTAssertFalse(
            AppSettings().showMockDataWhenDisconnected,
            "Commercial builds should start honest: no sample usage should appear until the user explicitly enables preview data."
        )

        let decodedLegacySettings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(
            decodedLegacySettings.showMockDataWhenDisconnected,
            "Settings decoded without the key should use the commercial default instead of silently enabling sample data."
        )
    }

    func testUsageStoreRequiresExplicitSamplePreviewWhenDisconnected() async {
        let store = UsageStore(adapters: [
            FixedProviderAdapter(snapshot: ProviderSnapshot(provider: .claude)),
            FixedProviderAdapter(snapshot: ProviderSnapshot(provider: .codex)),
            FixedProviderAdapter(snapshot: ProviderSnapshot(provider: .gemini))
        ])

        let commercialDefault = await store.refresh(settings: AppSettings())
        XCTAssertFalse(commercialDefault.hasConnectedData)
        XCTAssertTrue(commercialDefault.snapshots.allSatisfy { $0.dataSource != .mock })
        XCTAssertTrue(commercialDefault.snapshots.allSatisfy { $0.todayTokens == 0 })

        let preview = await store.refresh(settings: AppSettings(showMockDataWhenDisconnected: true))
        XCTAssertFalse(preview.hasConnectedData)
        XCTAssertTrue(preview.snapshots.contains { $0.dataSource == .mock })
        XCTAssertTrue(preview.snapshots.contains { $0.todayTokens > 0 })
    }
    func testUsageStoreCompositeRefreshInvokesCodexAndDeepSeekOnceWithCapacityObservations() async throws {
        let codexResponse = """
        {"id":2,"result":{"planType":"plus","rateLimits":{"primary":{"used_percent":42,"window_minutes":300,"resets_at":"2027-01-15T00:00:00Z"},"secondary":{"used_percent":18,"window_minutes":10080,"resets_at":1800000000}}}}
        """.data(using: .utf8)!
        let appServer = StubCodexAppServerRateLimitClient(data: codexResponse)
        let codex = CodexWebUsageAdapter(appServerClient: appServer)

        let deepSeekPayload = """
        {"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.34","granted_balance":"0","topped_up_balance":"12.34"}]}
        """.data(using: .utf8)!
        let deepSeekHTTP = StubDeepSeekHTTPClient(data: deepSeekPayload)
        let keychain = KeychainService(service: "com.tokenpilot.tests.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
        try keychain.saveSecret("deepseek-test-key", account: "deepseek.apiKey")
        let deepSeek = DeepSeekBalanceAdapter(httpClient: deepSeekHTTP, keychain: keychain)

        var settings = AppSettings(showMockDataWhenDisconnected: false, monitoredProviders: MonitoredProviderSettings(enabledProviders: [.codex, .deepseek]))
        settings.codexManual.webConnectorEnabled = true
        settings.deepseekAPIKeyConfigured = true

        let result = await UsageStore(refreshAdapters: [codex, deepSeek]).refresh(settings: settings)

        let appServerCallCount = await appServer.callCount()
        XCTAssertEqual(appServerCallCount, 1)
        XCTAssertEqual(deepSeekHTTP.callCount(), 1)
        XCTAssertEqual(Set(result.snapshots.map(\.provider)), [.codex, .deepseek])
        XCTAssertEqual(result.capacityErrors, [])
        XCTAssertEqual(result.capacityObservations.filter { $0.seriesID.provider == .codex }.count, 2)
        XCTAssertEqual(result.capacityObservations.filter { $0.seriesID.provider == .deepseek }.count, 1)
        XCTAssertTrue(result.capacityObservations.allSatisfy { observation in
            result.snapshots.contains { $0.provider == observation.seriesID.provider && $0.updatedAt == observation.observedAt }
        })
    }

    func testAggregationComputesRequiredMetrics() {
        let now = Date()
        let events = [
            UsageEvent(provider: .claude, timestamp: now, inputTokens: 100, outputTokens: 50, cacheReadTokens: 20, cacheCreationTokens: 10, requestCount: 1, estimatedCostUSD: 0.01, source: "test"),
            UsageEvent(provider: .gemini, timestamp: now, inputTokens: 200, outputTokens: 100, cacheReadTokens: 30, requestCount: 2, source: "test")
        ]
        let snapshots = [
            ProviderSnapshot(provider: .claude, events: [events[0]]),
            ProviderSnapshot(provider: .gemini, events: [events[1]])
        ]

        let usage = AggregationService().aggregate(snapshots: snapshots, period: .today)

        XCTAssertEqual(usage.metrics.totalTokens, 510)
        XCTAssertEqual(usage.metrics.inputTokens, 300)
        XCTAssertEqual(usage.metrics.outputTokens, 150)
        XCTAssertEqual(usage.metrics.cacheTokens, 60)
        XCTAssertEqual(usage.metrics.requestCount, 3)
        XCTAssertEqual(usage.sevenDayBars.count, 7)
        XCTAssertEqual(usage.providerShare.count, Provider.allCases.count)
        XCTAssertEqual(usage.providerShare.first(where: { $0.provider == .claude })?.requestCount, 1)
        XCTAssertEqual(usage.providerShare.first(where: { $0.provider == .claude })?.estimatedCostUSD, 0.01)
        XCTAssertEqual(usage.providerShare.first(where: { $0.provider == .gemini })?.requestCount, 2)
        XCTAssertNil(usage.providerShare.first(where: { $0.provider == .gemini })?.estimatedCostUSD)
    }

    func testLimitHistoryStoreRecordsPercentSamplesWhenTokenEventsAreUnavailable() {
        let defaults = UserDefaults(suiteName: "TokenPilotLimitHistoryTests-\(UUID().uuidString)")!
        let key = "limit-samples"
        defaults.removeObject(forKey: key)
        let store = LimitHistoryStore(defaults: defaults, key: key)
        let now = Date()
        let snapshot = ProviderSnapshot(
            provider: .claude,
            updatedAt: now,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 82, confidence: .high),
            weekly: LimitWindow(kind: .weekly, usedPercent: 47, confidence: .high),
            todayTokens: 0,
            confidence: .high,
            dataSource: .officialStatusline
        )

        let recorded = store.record(snapshots: [snapshot], enabledProviders: [.claude], referenceDate: now)
        let today = store.samples(period: .today, enabledProviders: [.claude], referenceDate: now)

        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(today.map(\.window), [.weekly, .fiveHour])
        XCTAssertEqual(today.map(\.remainingPercent), [53, 18])
        XCTAssertTrue(today.allSatisfy { $0.provider == .claude && $0.totalTokens == nil })
    }

    func testMenuBarLowestRemainingUsesMinimumEnabledWindowAcrossPresentationSnapshots() {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 21),
            weekly: LimitWindow(kind: .weekly, usedPercent: 34),
            confidence: .manual,
            dataSource: .manual
        )

        let summary = MenuBarStatusService().lowestRemainingSummary(snapshots: [snapshot], settings: AppSettings())

        XCTAssertEqual(summary?.provider, .codex)
        XCTAssertEqual(summary?.remainingPercent, 66)
        XCTAssertEqual(summary?.displayText, "Co 66%")

        let codex = ProviderSnapshot(
            provider: .codex,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 21),
            weekly: LimitWindow(kind: .weekly, usedPercent: 34),
            confidence: .manual,
            dataSource: .manual
        )
        let claude = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 73),
            confidence: .high,
            dataSource: .officialStatusline
        )

        let globalSummary = MenuBarStatusService().lowestRemainingSummary(snapshots: [codex, claude], settings: AppSettings())

        XCTAssertEqual(globalSummary?.provider, .claude)
        XCTAssertEqual(globalSummary?.remainingPercent, 27)
        XCTAssertEqual(globalSummary?.displayText, "Cl 27%")

        var settings = AppSettings()
        settings.claudeEnabled = false
        let disabledClaude = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 95),
            confidence: .high,
            dataSource: .officialStatusline
        )
        let enabledCodex = ProviderSnapshot(
            provider: .codex,
            weekly: LimitWindow(kind: .weekly, usedPercent: 34),
            confidence: .manual,
            dataSource: .manual
        )

        let enabledSummary = MenuBarStatusService().lowestRemainingSummary(snapshots: [disabledClaude, enabledCodex], settings: settings)

        XCTAssertEqual(enabledSummary?.provider, .codex)
        XCTAssertEqual(enabledSummary?.remainingPercent, 66)
        XCTAssertEqual(enabledSummary?.displayText, "Co 66%")
    }

    func testCodexPresentationSnapshotsMatchMenuBarManualFallbackWhenConnectorIsOff() {
        var settings = AppSettings()
        settings.menuBarDisplayTarget = .codex
        settings.codexManual.webConnectorEnabled = false
        settings.codexManual.webSnapshotEnabled = false
        settings.codexManual.fiveHourUsagePercentage = 74
        settings.codexManual.weeklyUsagePercentage = 20
        settings.codexManual.webTodayTokens = 12_345

        let localLogOnly = ProviderSnapshot(
            provider: .codex,
            todayTokens: 4_321,
            confidence: .medium,
            dataSource: .localLog,
            isExperimental: true,
            statusMessage: "EXPERIMENTAL · local Codex log · not web quota"
        )

        let service = MenuBarStatusService()
        let summary = service.lowestRemainingSummary(snapshots: [localLogOnly], settings: settings)
        let presentation = service.presentationSnapshots(from: [localLogOnly], settings: settings)

        XCTAssertEqual(summary?.provider, .codex)
        XCTAssertEqual(summary?.remainingPercent, 26)
        XCTAssertEqual(summary?.displayText, "Co 26%")
        XCTAssertEqual(presentation.count, 1)
        XCTAssertEqual(presentation.first?.provider, .codex)
        XCTAssertEqual(presentation.first?.fiveHour?.usedPercent, 74)
        XCTAssertEqual(presentation.first?.weekly?.usedPercent, 20)
        XCTAssertEqual(presentation.first?.primaryUsedPercent, 74)
        XCTAssertEqual(presentation.first?.todayTokens, 4_321)
    }

    func testNotificationThresholdDeduplicatesWithinResetCycle() {
        let defaults = UserDefaults(suiteName: "TokenPilotTests-\(UUID().uuidString)")!
        let store = AlertDeduplicationStore(defaults: defaults, key: "state")
        let service = NotificationRuleService(store: store)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.alertRules = [AlertRule(provider: .claude, window: .fiveHour)]
        let resetAt = Date().addingTimeInterval(3600)

        let below = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 40, resetAt: resetAt, confidence: .high)
        )
        XCTAssertTrue(service.evaluate(snapshots: [below], settings: settings).isEmpty)

        let crossed = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 82, resetAt: resetAt, confidence: .high)
        )
        let firstEvents = service.evaluate(snapshots: [crossed], settings: settings)
        XCTAssertEqual(firstEvents.map(\.threshold), [.eighty])

        let duplicateEvents = service.evaluate(snapshots: [crossed], settings: settings)
        XCTAssertTrue(duplicateEvents.isEmpty)
    }


    func testNotificationResetDoesNotFireJustBecauseResetTimeMovesWhileUsageIsHigh() {
        let defaults = UserDefaults(suiteName: "TokenPilotTests-\(UUID().uuidString)")!
        let store = AlertDeduplicationStore(defaults: defaults, key: "state")
        let service = NotificationRuleService(store: store)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.alertRules = [AlertRule(provider: .claude, window: .fiveHour)]

        let firstReset = Date().addingTimeInterval(3_600)
        let movedReset = Date().addingTimeInterval(7_200)
        let highUsage = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 88, resetAt: firstReset, confidence: .high)
        )
        let movedHighUsage = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 89, resetAt: movedReset, confidence: .high)
        )

        XCTAssertTrue(service.evaluate(snapshots: [highUsage], settings: settings).isEmpty)
        XCTAssertTrue(service.evaluate(snapshots: [movedHighUsage], settings: settings).isEmpty)
    }

    func testNotificationResetFiresWhenUsageDropsNearZeroAfterRealUsage() {
        let defaults = UserDefaults(suiteName: "TokenPilotTests-\(UUID().uuidString)")!
        let store = AlertDeduplicationStore(defaults: defaults, key: "state")
        let service = NotificationRuleService(store: store)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.alertRules = [AlertRule(provider: .claude, window: .fiveHour)]
        let resetAt = Date().addingTimeInterval(3_600)

        let active = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 42, resetAt: resetAt, confidence: .high)
        )
        let reset = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 1, resetAt: resetAt.addingTimeInterval(18_000), confidence: .high)
        )

        XCTAssertTrue(service.evaluate(snapshots: [active], settings: settings).isEmpty)
        XCTAssertEqual(service.evaluate(snapshots: [reset], settings: settings).map(\.threshold), [.reset])
    }

    func testLocalNotificationPermissionStatusDoesNotCrashOutsideAppBundle() async {
        let status = await LocalNotificationService().permissionStatus()
        XCTAssertTrue(NotificationPermissionState.allCases.contains(status))
    }

    func testDefaultCodexManualSnapshotDoesNotPretendToBeConnectedUsage() async {
        let snapshot = await CodexManualAdapter().snapshot(settings: AppSettings())

        XCTAssertNil(snapshot.primaryUsedPercent)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.statusMessage, "Manual mode · no data entered")
    }

    func testCodexStatusParserPrefersWindowLabelsOverUnrelatedPercentages() {
        let parsed = CodexStatusParser.parse(
            """
            Context left: 95%
            Plan: Pro
            5h usage: 82% resets in 1h 24m
            Weekly usage: 47%
            """,
            previous: CodexManualSettings()
        )

        XCTAssertEqual(parsed.planLabel, "Pro")
        XCTAssertEqual(parsed.fiveHourUsagePercentage, 82)
        XCTAssertEqual(parsed.weeklyUsagePercentage, 47)
        XCTAssertEqual(parsed.confidence, .medium)
    }

    func testCodexStatusParserDoesNotTreatGenericSessionPercentAsFiveHourUsage() {
        let parsed = CodexStatusParser.parse(
            """
            Session memory: 90%
            Weekly usage: 31%
            """,
            previous: CodexManualSettings()
        )

        XCTAssertEqual(parsed.fiveHourUsagePercentage, 0)
        XCTAssertEqual(parsed.weeklyUsagePercentage, 31)
        XCTAssertEqual(parsed.confidence, .medium)
    }

    func testCodexStatusParserExtractsObviousResetText() {
        let parsed = CodexStatusParser.parse(
            """
            Plan: Pro
            5-hour usage: 42%
            Reset: 2026-05-17T10:00:00Z
            """,
            previous: CodexManualSettings()
        )

        XCTAssertEqual(parsed.fiveHourUsagePercentage, 42)
        XCTAssertEqual(parsed.resetTimeText, "2026-05-17T10:00:00Z")
        XCTAssertEqual(parsed.confidence, .medium)
    }

    func testCodexLocalSessionAdapterBoundaryScanDoesNotDropCompleteLineAtBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotCodexBoundaryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filler = String(repeating: "x", count: 65_000)
        let tokenLine = "{\"timestamp\":\"\(timestamp)\",\"type\":\"token_count\",\"info\":{\"filler\":\"\(filler)\",\"last_token_usage\":{\"input_tokens\":12,\"output_tokens\":3,\"cached_input_tokens\":2,\"reasoning_output_tokens\":1}}}\n"
        let content = "x\n" + tokenLine
        try content.data(using: .utf8)!.write(to: fileURL)

        let payload = ProviderSnapshot(provider: .codex, confidence: .low, statusMessage: "web unavailable")
        let adapter = CodexLocalSessionAdapter(
            sessionRoots: [directory],
            manualFallback: CodexManualAdapter(),
            webUsageAdapter: FixedProviderAdapter(snapshot: payload),
            environment: ProcessInfo.processInfo.environment,
            currentHomeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            maxSessionFiles: 1,
            largeFileFullScanLimitBytes: max(64 * 1024, UInt64(tokenLine.utf8.count)),
            largeFileTailBytes: UInt64(tokenLine.utf8.count)
        )

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = false
        settings.codexManual.webSnapshotEnabled = false
        let snapshot = await adapter.snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.totalTokens, 18)
    }

    func testGeminiTelemetryAdapterParsesNestedMetadataTokenFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","name":"gemini_cli.api_response","metadata":{"input_token_count":120,"output_token_count":30,"cached_content_token_count":10,"thoughts_token_count":5,"tool_token_count":7,"model":"gemini-2.5-pro","duration_ms":456,"auth_type":"oauth"}}
        """
        try line.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 172)
        XCTAssertEqual(snapshot.dailyRequestsUsed, 1)
        XCTAssertEqual(snapshot.model, "gemini-2.5-pro")
    }

    func testCodexLocalSessionAdapterResolvesDuplicateLineWithoutIDDeduplicatesUsingLineFingerprint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotCodexDuplicateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let tokenLine = "{\"timestamp\":\"\(timestamp)\",\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":12,\"output_tokens\":3,\"cached_input_tokens\":2,\"reasoning_output_tokens\":1}}}"
        let content = tokenLine + "\n" + tokenLine + "\n"
        try content.data(using: .utf8)!.write(to: fileURL)

        let payload = ProviderSnapshot(provider: .codex, confidence: .low, statusMessage: "web unavailable")
        let adapter = CodexLocalSessionAdapter(
            sessionRoots: [directory],
            manualFallback: CodexManualAdapter(),
            webUsageAdapter: FixedProviderAdapter(snapshot: payload),
            environment: ProcessInfo.processInfo.environment,
            currentHomeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            maxSessionFiles: 1,
            largeFileFullScanLimitBytes: 4 * 1_024,
            largeFileTailBytes: 4 * 1_024
        )

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = false
        settings.codexManual.webSnapshotEnabled = false
        let snapshot = await adapter.snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testTokenPilotLocalizerTranslatesCoreKoreanLabels() {
        XCTAssertEqual(TokenPilotLocalizer.localized("Overview", language: .ko), "개요")
        XCTAssertEqual(TokenPilotLocalizer.localized("Total tokens", language: .ko), "전체 토큰")
        XCTAssertEqual(HistoryPeriod.last7Days.localizedLabel(language: .ko), "최근 7일")
        XCTAssertEqual(
            TokenPilotLocalizer.localized("No notification channel is enabled or configured.", language: .ko),
            "켜져 있거나 설정 완료된 알림 채널이 없습니다."
        )
    }

    // MARK: - ClaudeStatuslineAdapter Tests

    func testClaudeAdapter_FileMissing_ReturnsEmptyState() async throws {
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = "/nonexistent/path/claude-statusline.json"
        let snapshot = await ClaudeStatuslineAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertEqual(snapshot.isStale, false)
        XCTAssertEqual(snapshot.statusMessage, "Connect Claude statusline")
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testClaudeAdapter_InvalidJSON_ReturnsErrorState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("claude-statusline.json")
        try "not valid json{{{".write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = logURL.path
        let snapshot = await ClaudeStatuslineAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertEqual(snapshot.isStale, true)
        XCTAssertEqual(snapshot.statusMessage, "Invalid JSON")
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testClaudeAdapter_ValidJSON_HighConfidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("claude-statusline.json")
        let json = """
        {
            "rate_limits": {
                "five_hour": { "used_percentage": 82, "resets_at": "2026-05-16T10:00:00Z" },
                "seven_day": { "used_percentage": 47, "resets_at": "2026-05-22T00:00:00Z" }
            },
            "context_window": {
                "current_usage": {
                    "input_tokens": 1200,
                    "output_tokens": 3400,
                    "cache_creation_input_tokens": 500,
                    "cache_read_input_tokens": 800
                }
            },
            "cost": { "total_cost_usd": 1.24 },
            "model": { "display_name": "Claude Sonnet 4" }
        }
        """
        try json.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = logURL.path
        let snapshot = await ClaudeStatuslineAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.isStale, false)
        XCTAssertEqual(snapshot.statusMessage, "Connected")
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 82)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 47)
        XCTAssertEqual(snapshot.todayCostUSD, 1.24)
        XCTAssertEqual(snapshot.model, "Claude Sonnet 4")
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].inputTokens, 1200)
        XCTAssertEqual(snapshot.events[0].outputTokens, 3400)
        XCTAssertEqual(snapshot.events[0].cacheReadTokens, 800)
        XCTAssertEqual(snapshot.events[0].cacheCreationTokens, 500)
    }

    func testClaudeAdapter_MissingRateLimits_StaysLowConfidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("claude-statusline.json")
        let json = """
        {
            "context_window": { "current_usage": {} },
            "model": { "display_name": "Claude" }
        }
        """
        try json.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = logURL.path
        let snapshot = await ClaudeStatuslineAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertEqual(snapshot.fiveHour, nil)
        XCTAssertEqual(snapshot.weekly, nil)
        XCTAssertEqual(snapshot.events.count, 0)
    }

    func testClaudeAdapter_ContextWindowUsageIsParsedWithoutTokenEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("claude-statusline.json")
        let json = """
        {
            "context_window": {
                "used_percentage": 63,
                "current_usage": {}
            },
            "model": { "display_name": "Claude Sonnet" }
        }
        """
        try json.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = logURL.path
        let snapshot = await ClaudeStatuslineAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.contextWindowUsedPercent, 63)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.statusMessage, "Connected")
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testClaudeAdapter_StaleFile_MediumConfidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("claude-statusline.json")
        let json = """
        {
            "rate_limits": {
                "five_hour": { "used_percentage": 82 },
                "seven_day": { "used_percentage": 47 }
            },
            "context_window": { "current_usage": { "input_tokens": 100, "output_tokens": 50 } },
            "model": { "display_name": "Claude Sonnet" }
        }
        """
        try json.write(to: logURL, atomically: true, encoding: .utf8)

        // Set file modification date beyond the 5-minute stale threshold
        let sixMinutesAgo = Date().addingTimeInterval(-360)
        try FileManager.default.setAttributes([.modificationDate: sixMinutesAgo], ofItemAtPath: logURL.path)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = logURL.path
        let snapshot = await ClaudeStatuslineAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .medium)
        XCTAssertEqual(snapshot.isStale, true)
        XCTAssertEqual(snapshot.statusMessage, "STALE · older than 5 minutes")
    }

    // MARK: - GeminiTelemetryAdapter Tests

    func testGeminiAdapter_FileMissing_ReturnsEmptyState() async throws {
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = "/nonexistent/telemetry.log"
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .gemini)
        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertEqual(snapshot.statusMessage, "Select Antigravity statusline JSON or legacy Gemini source")
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testGeminiAdapter_NoApiResponseEvents_ReturnsNoTelemetryState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        try "some other log line\nanother log entry\n".write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertEqual(snapshot.statusMessage, "No Antigravity or Gemini token events yet")
        XCTAssertEqual(snapshot.events.count, 0)
    }

    func testGeminiAdapter_ParsesApiResponse_HighConfidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        let line = """
        {"timestamp":"\(ISO8601DateFormatter().string(from: Date()))","name":"gemini_cli.api_response","metadata":{"input_token_count":120,"output_token_count":30,"cached_content_token_count":10,"total_token_count":160,"model":"gemini-2.5-flash","duration_ms":456,"auth_type":"api_key"}}
        """
        try line.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.isStale, false)
        XCTAssertEqual(snapshot.statusMessage, "Connected")
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].inputTokens, 120)
        XCTAssertEqual(snapshot.events[0].outputTokens, 30)
        XCTAssertEqual(snapshot.events[0].cacheReadTokens, 10)
        XCTAssertEqual(snapshot.model, "gemini-2.5-flash")
    }

    func testGeminiAdapter_ParsesPrettyPrintedOpenTelemetryLogRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = """
        {
          "body": "API response from gemini-2.5-pro. Status: 200. Duration: 456ms.",
          "attributes": {
            "event.name": "gemini_cli.api_response",
            "event.timestamp": "\(timestamp)",
            "model": "gemini-2.5-pro",
            "duration_ms": 456,
            "input_token_count": 80,
            "output_token_count": 40,
            "cached_content_token_count": 10,
            "thoughts_token_count": 5,
            "tool_token_count": 0,
            "total_token_count": 150,
            "auth_type": "oauth",
            "response_text": "must not be surfaced"
          }
        }
        {
          "body": "API response from gemini-2.5-flash. Status: 200. Duration: 123ms.",
          "attributes": {
            "event.name": "gemini_cli.api_response",
            "event.timestamp": "\(timestamp)",
            "model": "gemini-2.5-flash",
            "duration_ms": 123,
            "input_token_count": 40,
            "output_token_count": 20,
            "cached_content_token_count": 5,
            "thoughts_token_count": 10,
            "tool_token_count": 0,
            "total_token_count": 75,
            "auth_type": "oauth"
          }
        }
        """
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(snapshot.dailyRequestsUsed, 2)
        XCTAssertEqual(snapshot.todayTokens, 225)
        XCTAssertEqual(snapshot.model, "gemini-2.5-flash")
        XCTAssertEqual(snapshot.events[0].authType, "oauth")
        XCTAssertFalse(snapshot.events.contains { $0.model?.contains("must not be surfaced") == true })
    }
    func testGeminiAdapterParsesAntigravityStatuslineContextWindowUsage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let statuslineURL = directory.appendingPathComponent("antigravity-statusline.json")
        let content = """
        {
          "product": "antigravity-cli",
          "model": {
            "id": "gemini-3.5-pro",
            "display_name": "Gemini 3.5 Pro"
          },
          "context_window": {
            "context_window_size": 1048576,
            "used_percentage": 12,
            "remaining_percentage": 88,
            "current_usage": {
              "input_tokens": 120,
              "output_tokens": 80,
              "cache_creation_input_tokens": 30,
              "cache_read_input_tokens": 170
            }
          }
        }
        """
        try content.write(to: statuslineURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = statuslineURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.dataSource, .officialStatusline)
        XCTAssertEqual(snapshot.statusMessage, "Connected")
        XCTAssertEqual(snapshot.contextWindowUsedPercent, 12)
        XCTAssertNil(snapshot.dailyRequestsUsed)
        XCTAssertNil(snapshot.dailyRequestsLimit)
        XCTAssertEqual(snapshot.todayTokens, 400)
        XCTAssertEqual(snapshot.model, "Gemini 3.5 Pro")
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].source, "antigravity-statusline")
        XCTAssertEqual(snapshot.events[0].requestCount, 0)
        XCTAssertEqual(snapshot.events[0].totalTokens, 400)
    }

    func testGeminiAdapterPrefersAntigravityContextWindowTotalsWhenPresent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let statuslineURL = directory.appendingPathComponent("antigravity-statusline.json")
        let content = """
        {
          "product": "antigravity-cli",
          "model": {
            "id": "gemini-next",
            "display_name": "Gemini Next"
          },
          "context_window": {
            "total_input_tokens": 88244,
            "total_output_tokens": 61074,
            "context_window_size": 1048576,
            "used_percentage": 8.4,
            "remaining_percentage": 91.6,
            "current_usage": {
              "input_tokens": 63382,
              "output_tokens": 346,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 20857
            }
          },
          "email": "developer@example.com"
        }
        """
        try content.write(to: statuslineURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = statuslineURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .officialStatusline)
        XCTAssertEqual(snapshot.contextWindowUsedPercent, 8)
        XCTAssertEqual(snapshot.todayTokens, 149_318)
        XCTAssertEqual(snapshot.model, "Gemini Next")
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].inputTokens, 88_244)
        XCTAssertEqual(snapshot.events[0].outputTokens, 61_074)
        XCTAssertEqual(snapshot.events[0].cacheReadTokens, 0)
        XCTAssertEqual(snapshot.events[0].totalTokens, 149_318)
        XCTAssertNil(snapshot.events[0].authType)
    }

    func testGeminiAdapterFallsBackToLegacyTelemetryWhenAntigravityStatuslineHasNoUsableTokens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let statuslineURL = directory.appendingPathComponent("antigravity-statusline.json")
        let legacyURL = directory.appendingPathComponent("telemetry.log")
        try """
        {
          "product": "antigravity-cli",
          "context_window": {
            "current_usage": {
              "input_tokens": 0,
              "output_tokens": 0,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0
            }
          }
        }
        """.write(to: statuslineURL, atomically: true, encoding: .utf8)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        try """
        {"timestamp":"\(timestamp)","name":"gemini_cli.api_response","metadata":{"input_token_count":60,"output_token_count":30,"total_token_count":90,"model":"gemini-2.5-pro"}}
        """.write(to: legacyURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = statuslineURL.path
        let snapshot = await GeminiTelemetryAdapter(logURLs: [legacyURL]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .officialTelemetry)
        XCTAssertEqual(snapshot.todayTokens, 90)
        XCTAssertEqual(snapshot.model, "gemini-2.5-pro")
        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testGeminiAdapterPrefersAntigravityStatuslineOverPersistedLegacyDefaultWhenBothExist() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tokenPilotDir = home.appendingPathComponent("Library/Application Support/TokenPilot", isDirectory: true)
        let legacyGeminiDir = home.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenPilotDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyGeminiDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let statuslineURL = tokenPilotDir.appendingPathComponent("antigravity-statusline.json")
        let legacyURL = legacyGeminiDir.appendingPathComponent("telemetry.log")
        try """
        {
          "product": "antigravity-cli",
          "model": { "display_name": "Gemini Antigravity" },
          "context_window": {
            "total_input_tokens": 1000,
            "total_output_tokens": 250,
            "current_usage": {
              "input_tokens": 40,
              "output_tokens": 10
            }
          }
        }
        """.write(to: statuslineURL, atomically: true, encoding: .utf8)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        try """
        {"timestamp":"\(timestamp)","name":"gemini_cli.api_response","metadata":{"input_token_count":60,"output_token_count":30,"total_token_count":90,"model":"legacy-gemini"}}
        """.write(to: legacyURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = legacyURL.path
        let snapshot = await GeminiTelemetryAdapter(logURLs: [statuslineURL, legacyURL]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .officialStatusline)
        XCTAssertEqual(snapshot.todayTokens, 1_250)
        XCTAssertEqual(snapshot.model, "Gemini Antigravity")
        XCTAssertEqual(snapshot.events.map(\.source), ["antigravity-statusline"])
    }


    func testUsageStoreIgnoresDetectedGeminiSessionFolderWhenDefaultTelemetryLogMissing() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let geminiTmp = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionURL = geminiTmp.appendingPathComponent("session-tokenpilot.json")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = """
        {"timestamp":"\(timestamp)","prompt":"raw user prompt","response":"raw model response","name":"gemini_cli.api_response","metadata":{"input_token_count":60,"output_token_count":30,"total_token_count":90,"model":"gemini-2.5-pro"}}
        """
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let resolver = DefaultPathResolver(environment: [:], currentHomeDirectory: home, additionalHomeDirectories: [])
        let store = UsageStore(pathResolver: resolver)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        _ = settings.setProviderEnabled(.claude, isEnabled: false)
        _ = settings.setProviderEnabled(.codex, isEnabled: false)
        _ = settings.setProviderEnabled(.deepseek, isEnabled: false)
        let result = await store.refresh(settings: settings)
        let snapshot = try XCTUnwrap(result.snapshots.first { $0.provider == .gemini })

        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.todayTokens, 0)
        XCTAssertEqual(snapshot.confidence, .low)
    }
    func testUsageStoreUsesDetectedAntigravityStatuslineWhenDefaultPathMissingInInjectedHome() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tokenPilotDir = home.appendingPathComponent("Library/Application Support/TokenPilot", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenPilotDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let statuslineURL = tokenPilotDir.appendingPathComponent("antigravity-statusline.json")
        let content = """
        {
          "product": "antigravity-cli",
          "model": { "display_name": "Gemini Antigravity" },
          "context_window": {
            "current_usage": {
              "input_tokens": 200,
              "output_tokens": 50
            }
          }
        }
        """
        try content.write(to: statuslineURL, atomically: true, encoding: .utf8)

        let resolver = DefaultPathResolver(environment: ["HOME": home.path], currentHomeDirectory: home, additionalHomeDirectories: [])
        let store = UsageStore(pathResolver: resolver)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = AppSettings.defaultAntigravityStatuslinePath
        _ = settings.setProviderEnabled(.claude, isEnabled: false)
        _ = settings.setProviderEnabled(.codex, isEnabled: false)
        _ = settings.setProviderEnabled(.deepseek, isEnabled: false)
        let result = await store.refresh(settings: settings)
        let snapshot = try XCTUnwrap(result.snapshots.first { $0.provider == .gemini })

        XCTAssertTrue(result.hasConnectedData)
        XCTAssertEqual(snapshot.dataSource, .officialStatusline)
        XCTAssertEqual(snapshot.todayTokens, 250)
        XCTAssertEqual(snapshot.model, "Gemini Antigravity")
        XCTAssertNil(snapshot.dailyRequestsUsed)
    }

    func testUsageStoreUsesApprovedGeminiTelemetryAndIgnoresSiblingSessionFile() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true)
        let geminiTmp = geminiRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let telemetryLine = """
        {"timestamp":"\(timestamp)","name":"gemini_cli.api_response","metadata":{"input_token_count":60,"output_token_count":30,"total_token_count":90,"model":"gemini-2.5-pro","auth_type":"oauth","duration_ms":123}}
        """
        let sessionLine = """
        {"timestamp":"\(timestamp)","prompt":"raw user prompt","response":"raw model response","name":"gemini_cli.api_response","metadata":{"input_token_count":600,"output_token_count":300,"total_token_count":900,"model":"gemini-2.5-pro","auth_type":"oauth","duration_ms":123}}
        """
        try telemetryLine.write(to: geminiRoot.appendingPathComponent("telemetry.log"), atomically: true, encoding: .utf8)
        try sessionLine.write(to: geminiTmp.appendingPathComponent("session-tokenpilot.json"), atomically: true, encoding: .utf8)

        let resolver = DefaultPathResolver(environment: [:], currentHomeDirectory: home, additionalHomeDirectories: [])
        let store = UsageStore(pathResolver: resolver)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        _ = settings.setProviderEnabled(.claude, isEnabled: false)
        _ = settings.setProviderEnabled(.codex, isEnabled: false)
        _ = settings.setProviderEnabled(.deepseek, isEnabled: false)
        let result = await store.refresh(settings: settings)
        let snapshot = try XCTUnwrap(result.snapshots.first { $0.provider == .gemini })

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 90)
        XCTAssertEqual(snapshot.dailyRequestsUsed, 1)
    }

    func testGeminiAdapter_SkipsMalformedLines() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        let content = """
        {"timestamp":"\(ISO8601DateFormatter().string(from: Date()))","name":"gemini_cli.api_response","metadata":{"input_token_count":100,"output_token_count":50,"total_token_count":150}}
        invalid json line
        another malformed {{{
        {"timestamp":"\(ISO8601DateFormatter().string(from: Date()))","name":"gemini_cli.api_response","metadata":{"input_token_count":200,"output_token_count":80,"total_token_count":280}}
        """
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        // Should parse 2 valid events, skip 2 malformed
        XCTAssertEqual(snapshot.events.count, 2)
    }

    func testGeminiAdapter_StaleEvents_MediumConfidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        let sixMinutesAgo = Date().addingTimeInterval(-360)
        let line = """
        {"timestamp":"\(ISO8601DateFormatter().string(from: sixMinutesAgo))","name":"gemini_cli.api_response","metadata":{"input_token_count":100,"output_token_count":50,"total_token_count":150}}
        """
        try line.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .medium)
        XCTAssertEqual(snapshot.isStale, true)
        XCTAssertEqual(snapshot.statusMessage, "STALE · older than 5 minutes")
    }

    func testGeminiAdapter_TracksDailyRequestCount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let stableSameDayTime = startOfToday.addingTimeInterval(12 * 60 * 60)
        let tsFormatter = ISO8601DateFormatter()
        var lines: [String] = []
        for i in 0..<5 {
            let ts = tsFormatter.string(from: stableSameDayTime.addingTimeInterval(TimeInterval(-i * 60)))
            let line = "{\"timestamp\":\"\(ts)\",\"name\":\"gemini_cli.api_response\",\"metadata\":{\"input_token_count\":100,\"output_token_count\":50,\"total_token_count\":150}}"
            lines.append(line)
        }
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.dailyRequestsUsed, 5)
        XCTAssertEqual(snapshot.todayTokens, 5 * 150)
    }

    func testGeminiAdapter_PreservesOfficialTotalTokenCountWhenComponentsArePartial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","name":"gemini_cli.api_response","metadata":{"input_token_count":10,"output_token_count":5,"total_token_count":42,"model":"gemini-2.5-pro"}}
        """
        try line.write(to: logURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].inputTokens, 10)
        XCTAssertEqual(snapshot.events[0].outputTokens, 5)
        XCTAssertEqual(snapshot.events[0].totalTokens, 42)
        XCTAssertEqual(snapshot.todayTokens, 42)
    }

    func testGeminiAdapter_KeepsCurrentMonthEventsForHistoryAggregation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("telemetry.log")
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        let formatter = ISO8601DateFormatter()
        let lines = (0..<130).map { index -> String in
            let timestamp = formatter.string(from: startOfMonth.addingTimeInterval(TimeInterval(index * 60)))
            return "{\"timestamp\":\"\(timestamp)\",\"name\":\"gemini_cli.api_response\",\"metadata\":{\"total_token_count\":1,\"model\":\"gemini-2.5-flash\"}}"
        }
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        // All 130 events live within the first ~130 minutes of the month; anchor `now` just past the
        // last event so aggregation is deterministic even when the test runs at a month boundary.
        let now = startOfMonth.addingTimeInterval(130 * 60)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)
        let monthly = AggregationService().aggregate(snapshots: [snapshot], period: .thisMonth, now: now)

        XCTAssertEqual(snapshot.events.count, 130)
        XCTAssertEqual(monthly.metrics.totalTokens, 130)
        XCTAssertEqual(monthly.metrics.requestCount, 130)
    }

    // MARK: - CodexManualAdapter Tests

    func testCodexAdapter_NoData_ReturnsManualConfidence() async throws {
        let settings = AppSettings()
        let snapshot = await CodexManualAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.confidence, .manual)
        XCTAssertEqual(snapshot.statusMessage, "Manual mode · no data entered")
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testCodexManualWebSnapshotRequiresCapturedEvidenceBeforeShowingZero() async {
        var settings = AppSettings()
        settings.codexManual.webSnapshotEnabled = true

        let snapshot = await CodexManualAdapter().snapshot(settings: settings)

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.statusMessage, "Manual mode · no data entered")
    }

    func testCodexManualWebSnapshotPreservesExplicitCapturedZero() async {
        var settings = AppSettings()
        settings.codexManual.webSnapshotEnabled = true
        settings.codexManual.webSnapshotCapturedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = await CodexManualAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 0)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 0)
        XCTAssertEqual(snapshot.statusMessage, "Manual web snapshot · user-entered Codex web values")
    }

    func testCodexManualWebSnapshotShowsUserEnteredWebQuotaWithoutEstimatedLabel() async throws {
        var settings = AppSettings()
        settings.codexManual.webSnapshotEnabled = true
        settings.codexManual.webTodayTokens = 123_456
        settings.codexManual.fiveHourUsagePercentage = 42
        settings.codexManual.weeklyUsagePercentage = 18
        settings.codexManual.planLabel = "Codex Pro"

        let snapshot = await CodexManualAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.dataSource, .manual)
        XCTAssertFalse(snapshot.isExperimental)
        XCTAssertEqual(snapshot.todayTokens, 123_456)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 18)
        XCTAssertEqual(snapshot.statusMessage, "Manual web snapshot · user-entered Codex web values")
        XCTAssertFalse(snapshot.statusMessage?.contains("est.") == true)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testCodexLocalAdapterUsesManualWebSnapshotInsteadOfLocalLogWhenEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let jsonl = """
        {"timestamp":"\(timestamp)","type":"token_count","info":{"last_token_usage":{"input_tokens":900000,"output_tokens":100000,"total_tokens":1000000},"model":"gpt-5"}}
        """
        try jsonl.write(to: sessions.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webSnapshotEnabled = true
        settings.codexManual.webTodayTokens = 12_345
        settings.codexManual.fiveHourUsagePercentage = 27
        settings.codexManual.weeklyUsagePercentage = 9
        settings.codexManual.planLabel = "Codex Web"

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [sessions]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .manual)
        XCTAssertFalse(snapshot.isExperimental)
        XCTAssertEqual(snapshot.todayTokens, 12_345)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 27)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 9)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testCodexWebSnapshotRoundTripsThroughSettingsStoreAndClampsValues() {
        let suite = "TokenPilotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokenPilotSettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.codexManual.webSnapshotEnabled = true
        settings.codexManual.webTodayTokens = -10
        settings.codexManual.fiveHourUsagePercentage = 140
        settings.codexManual.weeklyUsagePercentage = -20

        store.save(settings)
        let loaded = store.load()

        XCTAssertTrue(loaded.codexManual.webSnapshotEnabled)
        XCTAssertEqual(loaded.codexManual.webTodayTokens, 0)
        XCTAssertEqual(loaded.codexManual.fiveHourUsagePercentage, 100)
        XCTAssertEqual(loaded.codexManual.weeklyUsagePercentage, 0)
    }

    func testSettingsStoreParsesAndDropsRawCodexStatusOutput() {
        let suite = "TokenPilotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokenPilotSettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.codexManual.pastedStatusOutput = "Plan: Pro\nSession (5h): 82% resets 1h24m\nWeek (7d): 47%"

        store.save(settings)
        let loaded = store.load()

        XCTAssertEqual(loaded.codexManual.planLabel, "Pro")
        XCTAssertEqual(loaded.codexManual.fiveHourUsagePercentage, 82)
        XCTAssertEqual(loaded.codexManual.weeklyUsagePercentage, 47)
        XCTAssertEqual(loaded.codexManual.confidence, .medium)
        XCTAssertEqual(loaded.codexManual.pastedStatusOutput, "")
    }

    func testCodexAdapter_ParsedStatus_ShowsMediumConfidenceWithEst() async throws {
        var settings = AppSettings()
        settings.codexManual.pastedStatusOutput = "Plan: Pro\nSession (5h): 82% resets 1h24m\nWeek (7d): 47%"
        settings.codexManual.fiveHourUsagePercentage = 82
        settings.codexManual.weeklyUsagePercentage = 47
        settings.codexManual.confidence = .medium

        let snapshot = await CodexManualAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .medium)
        XCTAssertTrue(snapshot.statusMessage?.contains("est.") == true)
        XCTAssertTrue(snapshot.statusMessage?.contains("Medium") == true)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 82)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 47)
    }

    func testCodexAdapter_HighConfidenceDowngradedToMedium() async throws {
        var settings = AppSettings()
        settings.codexManual.fiveHourUsagePercentage = 50
        settings.codexManual.weeklyUsagePercentage = 30
        settings.codexManual.confidence = .high

        let snapshot = await CodexManualAdapter().snapshot(settings: settings)

        // High is downgraded to medium max for Codex
        XCTAssertEqual(snapshot.confidence, .medium)
        XCTAssertTrue(snapshot.statusMessage?.contains("est.") == true)
    }

    func testCodexAdapter_AlwaysShowsEstLabel() async throws {
        var settings = AppSettings()
        settings.codexManual.fiveHourUsagePercentage = 25
        settings.codexManual.confidence = .low

        let snapshot = await CodexManualAdapter().snapshot(settings: settings)

        XCTAssertTrue(snapshot.statusMessage?.contains("est.") == true)
        XCTAssertTrue(snapshot.statusMessage?.contains("Low") == true)
    }

    func testCodexAdapter_EmptyPlanLabel_SetsModelNil() async throws {
        var settings = AppSettings()
        settings.codexManual.planLabel = ""
        settings.codexManual.fiveHourUsagePercentage = 50

        let snapshot = await CodexManualAdapter().snapshot(settings: settings)

        XCTAssertNil(snapshot.model)
    }

    func testClaudeAdapterFallsBackToLocalJsonlUsageRowsWithoutReadingCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let jsonlURL = projectDirectory.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","sessionId":"s1","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":120,"output_tokens":30,"cache_creation_input_tokens":10,"cache_read_input_tokens":40}},"costUSD":0.02}
        """
        try line.write(to: jsonlURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = directory.appendingPathComponent("missing-status.json").path
        let snapshot = await ClaudeStatuslineAdapter(fileURL: directory.appendingPathComponent("missing-status.json"), fallbackProjectRoots: [projectDirectory]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.confidence, .medium)
        XCTAssertEqual(snapshot.dataSource, .localLog)
        XCTAssertEqual(snapshot.statusMessage, "Local JSONL · rate limits unavailable")
        XCTAssertEqual(snapshot.todayTokens, 200)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].source, "claude-jsonl")
        XCTAssertEqual(snapshot.events[0].dataSource, .localLog)
    }

    func testDataSourceConnectionServiceMarksClaudeLocalJsonlConnectedFromDefaultProjects() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = home.appendingPathComponent(".claude/projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","requestId":"r-default","message":{"id":"m-default","model":"claude-sonnet-4","usage":{"input_tokens":80,"output_tokens":20}}}
        """
        try line.write(to: projectDirectory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let resolver = DefaultPathResolver(environment: ["HOME": home.path], currentHomeDirectory: home, additionalHomeDirectories: [])
        let source = await DataSourceConnectionService(pathResolver: resolver).check(settings: AppSettings(showMockDataWhenDisconnected: false), provider: .claude)

        XCTAssertEqual(source.status, .connected)
        XCTAssertEqual(source.mode, .custom)
        XCTAssertEqual(source.confidence, .medium)
        XCTAssertTrue(source.detectedPaths.contains { $0.kind == "projects" && $0.path == home.appendingPathComponent(".claude/projects", isDirectory: true).path && $0.exists })
        XCTAssertEqual(source.statusMessage, "Local JSONL · rate limits unavailable")
    }
    func testDataSourceConnectionServiceMarksAntigravityStatuslineConnectedFromDefaultPath() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tokenPilotDir = home.appendingPathComponent("Library/Application Support/TokenPilot", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenPilotDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let statuslineURL = tokenPilotDir.appendingPathComponent("antigravity-statusline.json")
        let content = """
        {
          "product": "antigravity-cli",
          "model": { "id": "gemini-3.5-pro" },
          "context_window": {
            "current_usage": {
              "input_tokens": 70,
              "output_tokens": 30
            }
          }
        }
        """
        try content.write(to: statuslineURL, atomically: true, encoding: .utf8)

        let settings = AppSettings(showMockDataWhenDisconnected: false)
        let resolver = DefaultPathResolver(environment: ["HOME": home.path], currentHomeDirectory: home, additionalHomeDirectories: [])
        let source = await DataSourceConnectionService(pathResolver: resolver).check(settings: settings, provider: .gemini)

        XCTAssertEqual(source.status, .connected)
        XCTAssertEqual(source.mode, .custom)
        XCTAssertEqual(source.confidence, .high)
        XCTAssertEqual(source.statusMessage, "Connected")
        XCTAssertTrue(source.detectedPaths.contains { $0.kind == "antigravity_statusline" && $0.path == statuslineURL.path && $0.exists })
    }


    func testProviderConnectionDiagnosticMapsEveryStatusToNextAction() throws {
        let expectations: [ProviderDataSourceStatus: ProviderConnectionNextAction] = [
            .connected: .refreshWhenStale,
            .notFound: .chooseLocalSource,
            .permissionDenied: .grantFileAccess,
            .noUsableData: .verifyTelemetry,
            .stale: .runProviderAndRefresh,
            .invalidFormat: .chooseValidSource,
            .disabled: .enableProvider,
            .manual: .pasteCodexStatus,
            .estimated: .reviewManualEstimate
        ]

        for (status, expectedAction) in expectations {
            let diagnostic = ProviderDataSource(
                provider: .claude,
                lastScanAt: Date(timeIntervalSince1970: 1_700_000_000),
                status: status,
                confidence: .medium
            ).connectionDiagnostic()

            XCTAssertEqual(diagnostic.nextAction, expectedAction, "Unexpected next action for \(status)")
            XCTAssertFalse(diagnostic.redactedDetail.contains("/Users/"))
            XCTAssertFalse(diagnostic.redactedDetail.contains("prompt"))
            XCTAssertFalse(diagnostic.redactedDetail.contains("token"))
        }
    }

    func testProviderConnectionDiagnosticUsesCodexManualActionWhenNotFound() throws {
        let diagnostic = ProviderDataSource(
            provider: .codex,
            status: .notFound,
            confidence: .low
        ).connectionDiagnostic()

        XCTAssertEqual(diagnostic.nextAction, .pasteCodexStatus)
        XCTAssertEqual(diagnostic.status, .notFound)
    }

    func testUsageStoreDefaultAdaptersUseDetectedClaudeProjectRoots() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = home.appendingPathComponent(".claude/projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","requestId":"usage-store-default","message":{"id":"usage-store-message","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":25,"cache_read_input_tokens":5}}}
        """
        try line.write(to: projectDirectory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let resolver = DefaultPathResolver(environment: ["HOME": home.path], currentHomeDirectory: home, additionalHomeDirectories: [])
        let store = UsageStore(pathResolver: resolver)
        let settings = AppSettings(
            showMockDataWhenDisconnected: false,
            monitoredProviders: MonitoredProviderSettings(enabledProviders: [.claude])
        )
        let result = await store.refresh(settings: settings)
        let claude = result.snapshots.first { $0.provider == .claude }

        XCTAssertTrue(result.hasConnectedData)
        XCTAssertEqual(claude?.dataSource, .localLog)
        XCTAssertEqual(claude?.todayTokens, 130)
        XCTAssertEqual(claude?.events.count, 1)
    }

    func testClaudeAdapterAcceptsDetectedProjectsDirectoryAsConfiguredSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","requestId":"configured-project-dir","message":{"id":"configured-project-message","model":"claude-sonnet-4","usage":{"input_tokens":60,"output_tokens":15}}}
        """
        try line.write(to: projectDirectory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = directory.appendingPathComponent("projects", isDirectory: true).path

        let snapshot = await ClaudeStatuslineAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .localLog)
        XCTAssertEqual(snapshot.todayTokens, 75)
        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testConnectionServiceAppliesDetectedClaudeProjectsWhenDefaultStatuslineIsMissing() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("example", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = DefaultPathResolver(environment: ["HOME": home.path], currentHomeDirectory: home, additionalHomeDirectories: [])
        let service = DataSourceConnectionService(pathResolver: resolver)
        var source = ProviderDataSource(provider: .claude, detectedPaths: resolver.resolveDefaultPaths(for: .claude), status: .connected, confidence: .medium)
        source.isEnabled = true
        let adoption = service.applyingPreferredDetectedSources(settings: AppSettings(showMockDataWhenDisconnected: false), sources: [source])

        XCTAssertEqual(adoption.adoptedProviders, [.claude])
        XCTAssertEqual(adoption.settings.claudeStatusFilePath, projects.path)
        XCTAssertNil(adoption.settings.claudeStatusFileBookmarkData)
    }

    func testConnectionServiceReplacesMissingCustomClaudePathWithDetectedProjects() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = home.appendingPathComponent(".claude/projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","requestId":"missing-custom","message":{"id":"missing-custom-message","model":"claude-sonnet-4","usage":{"input_tokens":40,"output_tokens":10}}}
        """
        try line.write(to: projectDirectory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = home.appendingPathComponent("old-missing-statusline.json").path
        let resolver = DefaultPathResolver(environment: ["HOME": home.path], currentHomeDirectory: home, additionalHomeDirectories: [])
        let service = DataSourceConnectionService(pathResolver: resolver)
        let source = await service.check(settings: settings, provider: .claude)
        let adoption = service.applyingPreferredDetectedSources(settings: settings, sources: [source])

        XCTAssertEqual(source.status, .connected)
        XCTAssertEqual(adoption.adoptedProviders, [.claude])
        XCTAssertEqual(adoption.settings.claudeStatusFilePath, home.appendingPathComponent(".claude/projects", isDirectory: true).path)
    }

    func testClaudeLocalJsonlDedupesMessageRequestRowsAndKeepsRicherUsage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonlURL = projectDirectory.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let first = "{\"timestamp\":\"\(timestamp)\",\"sessionId\":\"s1\",\"requestId\":\"req-1\",\"message\":{\"id\":\"msg-1\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}"
        let richerDuplicate = "{\"timestamp\":\"\(timestamp)\",\"sessionId\":\"s1\",\"requestId\":\"req-1\",\"message\":{\"id\":\"msg-1\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":25,\"output_tokens\":15,\"cache_read_input_tokens\":10}}}"
        try [first, richerDuplicate].joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = directory.appendingPathComponent("missing-status.json").path
        let snapshot = await ClaudeStatuslineAdapter(fileURL: directory.appendingPathComponent("missing-status.json"), fallbackProjectRoots: [projectDirectory]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 50)
        XCTAssertEqual(snapshot.events[0].inputTokens, 25)
        XCTAssertEqual(snapshot.events[0].outputTokens, 15)
        XCTAssertEqual(snapshot.events[0].cacheReadTokens, 10)
    }

    func testClaudeLocalJsonlDedupesSameMessageEvenWhenRequestIDIsMissingOnOneRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonlURL = projectDirectory.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let withoutRequest = "{\"timestamp\":\"\(timestamp)\",\"sessionId\":\"s1\",\"message\":{\"id\":\"msg-1\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}"
        let withRequest = "{\"timestamp\":\"\(timestamp)\",\"sessionId\":\"s1\",\"requestId\":\"req-1\",\"message\":{\"id\":\"msg-1\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":30,\"output_tokens\":20}}}"
        try [withoutRequest, withRequest].joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = directory.appendingPathComponent("missing-status.json").path
        let snapshot = await ClaudeStatuslineAdapter(fileURL: directory.appendingPathComponent("missing-status.json"), fallbackProjectRoots: [projectDirectory]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 50)
        XCTAssertEqual(snapshot.events[0].inputTokens, 30)
        XCTAssertEqual(snapshot.events[0].outputTokens, 20)
    }

    func testClaudeLocalJsonlMergesSplitMessageAndRequestAliases() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonlURL = projectDirectory.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let messageOnly = "{\"timestamp\":\"\(timestamp)\",\"message\":{\"id\":\"msg-bridge\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":10}}}"
        let requestOnly = "{\"timestamp\":\"\(timestamp)\",\"requestId\":\"req-bridge\",\"message\":{\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":15}}}"
        let bridged = "{\"timestamp\":\"\(timestamp)\",\"requestId\":\"req-bridge\",\"message\":{\"id\":\"msg-bridge\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":25,\"output_tokens\":5}}}"
        try [messageOnly, requestOnly, bridged].joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = directory.appendingPathComponent("missing-status.json").path
        let snapshot = await ClaudeStatuslineAdapter(fileURL: directory.appendingPathComponent("missing-status.json"), fallbackProjectRoots: [projectDirectory]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 30)
        XCTAssertEqual(snapshot.events[0].inputTokens, 25)
        XCTAssertEqual(snapshot.events[0].outputTokens, 5)
    }

    func testClaudeLocalJsonlTodayCostUsesTodayEventsOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonlURL = projectDirectory.appendingPathComponent("session.jsonl")
        let today = ISO8601DateFormatter().string(from: Date())
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 24 * 60 * 60))
        let oldLine = "{\"timestamp\":\"\(old)\",\"requestId\":\"old\",\"message\":{\"id\":\"old-msg\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}},\"costUSD\":0.90}"
        let todayLine = "{\"timestamp\":\"\(today)\",\"requestId\":\"today\",\"message\":{\"id\":\"today-msg\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}},\"costUSD\":0.02}"
        try [oldLine, todayLine].joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.claudeStatusFilePath = directory.appendingPathComponent("missing-status.json").path
        let snapshot = await ClaudeStatuslineAdapter(fileURL: directory.appendingPathComponent("missing-status.json"), fallbackProjectRoots: [projectDirectory]).snapshot(settings: settings)

        XCTAssertEqual(snapshot.todayTokens, 15)
        XCTAssertEqual(snapshot.todayCostUSD, Decimal(string: "0.02"))
    }

    // MARK: - CodexWebUsageAdapter Tests

    func testCodexWebUsageAdapterLegacyDirectHTTPIsDisabledEvenWhenAllowedFlagIsSet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try "{\"tokens\":{\"access_token\":\"fixture-access-value\"}}".write(to: authURL, atomically: true, encoding: .utf8)
        let client = RecordingCodexWebUsageHTTPClient(data: Data(), failIfCalled: true)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(authFileURL: authURL, httpClient: client, appServerClient: nil, allowLegacyDirectHTTP: true).snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertTrue(snapshot.events.isEmpty)
        let authorizationHeader = await client.authorizationHeader()
        let requestURL = await client.requestURL()
        XCTAssertNil(authorizationHeader)
        XCTAssertNil(requestURL)
        XCTAssertTrue(snapshot.statusMessage?.contains("direct HTTP disabled") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("fixture-access-value") == true)
    }

    func testCodexWebUsageAdapterStaysOffByDefaultAndDoesNotCallHTTP() async throws {
        let client = RecordingCodexWebUsageHTTPClient(data: Data(), failIfCalled: true)
        let snapshot = await CodexWebUsageAdapter(authFileURL: URL(fileURLWithPath: "/missing/auth.json"), httpClient: client, appServerClient: nil).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.dataSource, .unknown)
        let requestURL = await client.requestURL()
        XCTAssertNil(requestURL)
        XCTAssertTrue(snapshot.statusMessage?.contains("off") == true)
    }

    func testCodexWebUsageAdapterMissingAuthDoesNotCallHTTP() async throws {
        let client = RecordingCodexWebUsageHTTPClient(data: Data(), failIfCalled: true)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(authFileURL: URL(fileURLWithPath: "/missing/auth.json"), httpClient: client, appServerClient: nil, allowLegacyDirectHTTP: true).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .low)
        let requestURL = await client.requestURL()
        XCTAssertNil(requestURL)
        XCTAssertTrue(snapshot.statusMessage?.contains("direct HTTP disabled") == true)
    }

    func testCodexWebUsageAdapterMissingAccessTokenDoesNotCallHTTP() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try "{\"tokens\":{}}".write(to: authURL, atomically: true, encoding: .utf8)
        let client = RecordingCodexWebUsageHTTPClient(data: Data(), failIfCalled: true)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(authFileURL: authURL, httpClient: client, appServerClient: nil, allowLegacyDirectHTTP: true).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .low)
        let requestURL = await client.requestURL()
        XCTAssertNil(requestURL)
        XCTAssertTrue(snapshot.statusMessage?.contains("direct HTTP disabled") == true)
    }

    func testCodexWebUsageAdapterHandlesAuthExpiredWithoutLeakingCredentialMaterial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try "{\"tokens\":{\"access_token\":\"fixture-expired-value\"}}".write(to: authURL, atomically: true, encoding: .utf8)
        let client = RecordingCodexWebUsageHTTPClient(data: Data(), statusCode: 403)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(authFileURL: authURL, httpClient: client, appServerClient: nil, allowLegacyDirectHTTP: true).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertTrue(snapshot.statusMessage?.contains("direct HTTP disabled") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("fixture-expired-value") == true)
    }

    func testCodexWebUsageAdapterMalformedPayloadReturnsLowConfidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try "{\"tokens\":{\"access_token\":\"fixture-malformed-value\"}}".write(to: authURL, atomically: true, encoding: .utf8)
        let response = "{\"plan_type\":\"plus\",\"rate_limit\":{}}".data(using: .utf8)!
        let client = RecordingCodexWebUsageHTTPClient(data: response)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(authFileURL: authURL, httpClient: client, appServerClient: nil, allowLegacyDirectHTTP: true).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertTrue(snapshot.statusMessage?.contains("direct HTTP disabled") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("fixture-malformed-value") == true)
    }

    func testCodexWebUsageAdapterPrefersCodexAppServerRateLimitRpcOverTokenHttp() async throws {
        let response = """
        {"id":2,"result":{"planType":"plus","rateLimits":{"primary":{"used_percent":0.42,"window_minutes":300,"resets_at":"2027-01-15T00:00:00Z"},"secondary":{"used_percent":"18%","window_minutes":10080,"resets_at":1800000000}}}}
        """.data(using: .utf8)!
        let appServer = StubCodexAppServerRateLimitClient(data: response)
        let httpClient = RecordingCodexWebUsageHTTPClient(data: Data(), failIfCalled: true)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(
            authFileURL: URL(fileURLWithPath: "/missing/auth.json"),
            httpClient: httpClient,
            appServerClient: appServer
        ).snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 18)
        XCTAssertEqual(snapshot.fiveHour?.providerWindowID, "primary")
        XCTAssertEqual(snapshot.fiveHour?.durationMinutes, 300)
        XCTAssertEqual(snapshot.weekly?.providerWindowID, "secondary")
        XCTAssertEqual(snapshot.weekly?.durationMinutes, 10_080)
        XCTAssertEqual(snapshot.fiveHour?.resetAt, ISO8601DateFormatter().date(from: "2027-01-15T00:00:00Z"))
        XCTAssertEqual(snapshot.model, "plus")
        XCTAssertEqual(snapshot.todayTokens, 0)
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertTrue(snapshot.statusMessage?.contains("app-server") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("Bearer") == true)
        let appServerCalls = await appServer.callCount()
        let requestURL = await httpClient.requestURL()
        XCTAssertEqual(appServerCalls, 1)
        XCTAssertNil(requestURL)
    }

    func testCodexAppServerPreservesDynamicRollingWindowsForEvidenceAndMenu() async throws {
        let referenceNow = Date(timeIntervalSince1970: 1_779_000_000)
        let response = """
        {"id":2,"result":{"planType":"plus","rateLimits":{"primary":{"used_percent":60,"window_minutes":15,"resets_at":1800000000},"secondary":{"used_percent":25,"window_minutes":240,"resets_at":1800000600}}}}
        """.data(using: .utf8)!
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true
        settings.menuBarDisplayTarget = .codex

        let snapshot = await CodexWebUsageAdapter(
            appServerClient: StubCodexAppServerRateLimitClient(data: response),
            now: { referenceNow }
        ).snapshot(settings: settings)
        let observations = CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: referenceNow)
        let title = MenuBarStatusService().title(snapshots: [snapshot], settings: settings, modeLabel: "LIVE", now: referenceNow)

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 60)
        XCTAssertEqual(snapshot.fiveHour?.providerWindowID, "primary")
        XCTAssertEqual(snapshot.fiveHour?.durationMinutes, 15)
        XCTAssertEqual(snapshot.fiveHour?.label, "15m")
        XCTAssertEqual(snapshot.weekly?.usedPercent, 25)
        XCTAssertEqual(snapshot.weekly?.providerWindowID, "secondary")
        XCTAssertEqual(snapshot.weekly?.durationMinutes, 240)
        XCTAssertEqual(snapshot.weekly?.label, "4h")
        XCTAssertEqual(observations.map(\.seriesID.canonicalID), [
            "codex/primary/rolling/percent/15",
            "codex/secondary/rolling/percent/240"
        ])
        XCTAssertEqual(title, "15m 40% EXP·243d · 4h 75% EXP·243d")
    }

    func testCodexAppServerRateLimitsCanDeriveUsageFromUsedAndLimitFields() async throws {
        let response = """
        {
            "id":2,
            "result": {
                "planType":"plus",
                "rateLimits": {
                    "primary": {
                        "used": 42,
                        "limit": 100,
                        "window_minutes": 300,
                        "resets_at": "2027-01-15T00:00:00Z"
                    },
                    "secondary": {
                        "used": 12,
                        "max": 60,
                        "window_minutes": 10080,
                        "resets_at": 1800000000
                    }
                }
            }
        }
        """.data(using: .utf8)!
        let appServer = StubCodexAppServerRateLimitClient(data: response)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(appServerClient: appServer).snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 20)
        XCTAssertEqual(snapshot.fiveHour?.resetAt, ISO8601DateFormatter().date(from: "2027-01-15T00:00:00Z"))
        XCTAssertEqual(snapshot.model, "plus")
    }

    func testCodexAppServerRateLimitsDoNotTreatBareRemainingAsPercent() async throws {
        let referenceNow = Date(timeIntervalSince1970: 1_779_000_000)
        let fiveHourReset = Date(timeIntervalSince1970: 1_800_000_000)
        let response = """
        {
            "id":2,
            "result": {
                "planType":"plus",
                "rateLimits": {
                    "primary": {
                        "remaining": 0,
                        "window_minutes": 300,
                        "resets_at": \(Int(fiveHourReset.timeIntervalSince1970))
                    }
                }
            }
        }
        """.data(using: .utf8)!
        let appServer = StubCodexAppServerRateLimitClient(data: response)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(
            appServerClient: appServer,
            now: { referenceNow }
        ).snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.fiveHour?.kind, .fiveHour)
        XCTAssertNil(snapshot.fiveHour?.usedPercent)
        XCTAssertEqual(snapshot.fiveHour?.resetAt, fiveHourReset)

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: referenceNow
        )
        XCTAssertFalse(title.contains("5h 0%"))
    }

    func testCodexAppServerRateLimitsParseLiveCamelCaseNestedPlanShape() async throws {
        let referenceNow = Date(timeIntervalSince1970: 1_779_000_000)
        let fiveHourReset = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = Date(timeIntervalSince1970: 1_800_604_800)
        let response = """
        {
            "id":2,
            "result": {
                "rateLimits": {
                    "limitId": "codex",
                    "planType": "prolite",
                    "primary": {
                        "resetsAt": \(Int(fiveHourReset.timeIntervalSince1970)),
                        "usedPercent": 45,
                        "windowDurationMins": 300
                    },
                    "secondary": {
                        "resetsAt": \(Int(weeklyReset.timeIntervalSince1970)),
                        "usedPercent": 50,
                        "windowDurationMins": 10080
                    }
                }
            }
        }
        """.data(using: .utf8)!
        let appServer = StubCodexAppServerRateLimitClient(data: response)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(
            appServerClient: appServer,
            now: { referenceNow }
        ).snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.fiveHour?.kind, .fiveHour)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 45)
        XCTAssertEqual(snapshot.fiveHour?.resetAt, fiveHourReset)
        XCTAssertEqual(snapshot.weekly?.kind, .weekly)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 50)
        XCTAssertEqual(snapshot.weekly?.resetAt, weeklyReset)
        XCTAssertEqual(snapshot.model, "prolite")
    }

    func testCodexAppServerRateLimitsTreatExpiredResetAliasesAsNoHealthyCurrentCapacity() async throws {
        let frozenNow = Date(timeIntervalSince1970: 1_781_000_000)
        let expiredPrimaryReset = Date(timeIntervalSince1970: 1_780_420_741)
        let weeklyReset = Date(timeIntervalSince1970: 1_800_604_800)
        let response = """
        {
            "id":2,
            "result": {
                "rateLimits": {
                    "primary": {
                        "resetAt": \(Int(expiredPrimaryReset.timeIntervalSince1970)),
                        "usedPercent": 97,
                        "windowDurationMins": 300
                    },
                    "secondary": {
                        "resetsAt": \(Int(weeklyReset.timeIntervalSince1970)),
                        "usedPercent": 50,
                        "windowDurationMins": 10080
                    }
                }
            }
        }
        """.data(using: .utf8)!
        let appServer = StubCodexAppServerRateLimitClient(data: response)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(
            appServerClient: appServer,
            now: { frozenNow }
        ).snapshot(settings: settings)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.kind, .weekly)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 50)
        XCTAssertEqual(snapshot.weekly?.resetAt, weeklyReset)
    }

    func testCodexAppServerRequestPayloadsUseInitializeAndRateLimitsRead() throws {
        let lines = CodexAppServerRateLimitProcessClient.makeRequestLinesForTesting(
            clientName: "tokenpilot-test",
            clientTitle: "TokenPilot Test",
            clientVersion: "1.2.3"
        )
        XCTAssertEqual(lines.count, 3)

        let initObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertNil(initObject["jsonrpc"])
        XCTAssertEqual(initObject["method"] as? String, "initialize")
        let params = try XCTUnwrap(initObject["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "tokenpilot-test")

        let initializedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertNil(initializedObject["jsonrpc"])
        XCTAssertEqual(initializedObject["method"] as? String, "initialized")

        let readObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any])
        XCTAssertNil(readObject["jsonrpc"])
        XCTAssertEqual(readObject["method"] as? String, "account/rateLimits/read")
    }

    func testCodexAppServerTimeoutDoesNotWaitForUncooperativeChildExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeCodex = directory.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        trap '' TERM
        sleep 3
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let client = CodexAppServerRateLimitProcessClient(
            codexExecutablePath: fakeCodex.path,
            timeoutSeconds: 1,
            clientName: "tokenpilot-timeout-test"
        )
        let start = Date()
        do {
            _ = try await client.readRateLimits()
            XCTFail("Expected app-server timeout")
        } catch CodexAppServerRateLimitError.timeout {
            // Expected. The important part is that cleanup is bounded even if the child ignores SIGTERM.
        } catch {
            XCTFail("Expected timeout, got \(error)")
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            2.25,
            "Timeout cleanup must not block until an uncooperative Codex child exits naturally; otherwise refresh stays active and Settings → Overview can appear to run forever."
        )
    }

    func testCodexAppServerCancellationReturnsCancelledPromptly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeCodex = directory.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        trap '' TERM
        while true; do sleep 1; done
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let client = CodexAppServerRateLimitProcessClient(
            codexExecutablePath: fakeCodex.path,
            timeoutSeconds: 5,
            clientName: "tokenpilot-cancel-test"
        )
        let task = Task {
            try await client.readRateLimits()
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelStart = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected app-server cancellation")
        } catch CodexAppServerRateLimitError.cancelled {
            // Expected.
        } catch {
            XCTFail("Expected cancelled, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(cancelStart), 1.0)
    }

    func testCodexWebUsageAdapterHandlesAppServerAuthRequiredWithoutHttpFallback() async throws {
        let response = """
        {"error":{"code":-32600,"message":"codex account authentication required to read rate limits"},"id":2}
        """.data(using: .utf8)!
        let appServer = StubCodexAppServerRateLimitClient(data: response)
        let httpClient = RecordingCodexWebUsageHTTPClient(data: Data(), failIfCalled: true)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(
            authFileURL: URL(fileURLWithPath: "/missing/auth.json"),
            httpClient: httpClient,
            appServerClient: appServer
        ).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertTrue(snapshot.statusMessage?.contains("auth required") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("access_token") == true)
        let appServerCalls = await appServer.callCount()
        let requestURL = await httpClient.requestURL()
        XCTAssertEqual(appServerCalls, 1)
        XCTAssertNil(requestURL)
    }

    func testCodexWebUsageAdapterRedactsAppServerErrorDetails() async throws {
        let response = """
        {"error":{"code":-32000,"message":"upstream failed at /Users/alice/.codex/auth.json prompt: summarize credentials with Bearer fixture-token and api_key=sk-abcdefghijklmnopqrstuvwxyz123456"},"id":2}
        """.data(using: .utf8)!
        let appServer = StubCodexAppServerRateLimitClient(data: response)
        let httpClient = RecordingCodexWebUsageHTTPClient(data: Data(), failIfCalled: true)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(
            authFileURL: URL(fileURLWithPath: "/missing/auth.json"),
            httpClient: httpClient,
            appServerClient: appServer
        ).snapshot(settings: settings)

        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertTrue(snapshot.statusMessage?.contains("[REDACTED]") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("fixture-token") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("/Users/alice") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("auth.json") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("summarize credentials") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("sk-abcdefghijklmnopqrstuvwxyz123456") == true)
        let requestURL = await httpClient.requestURL()
        XCTAssertNil(requestURL)
    }

    func testCodexWebUsageAdapterDoesNotUseLegacyDirectHTTPUnlessExplicitlyAllowed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try "{\"tokens\":{\"access_token\":\"fixture-direct-disabled-value\"}}".write(to: authURL, atomically: true, encoding: .utf8)
        let httpClient = RecordingCodexWebUsageHTTPClient(data: Data(), failIfCalled: true)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexWebUsageAdapter(
            authFileURL: authURL,
            httpClient: httpClient,
            appServerClient: nil
        ).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.confidence, .low)
        XCTAssertTrue(snapshot.statusMessage?.contains("direct HTTP disabled") == true)
        XCTAssertFalse(snapshot.statusMessage?.contains("fixture-direct-disabled-value") == true)
        let requestURL = await httpClient.requestURL()
        XCTAssertNil(requestURL)
    }

    func testCodexLocalSessionAdapterUsesWebConnectorBeforeLocalLogWhenEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900000,"output_tokens":100000,"total_tokens":1000000},"model":"gpt-5"}}}
        """.write(to: sessions.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
        let response = """
        {"id":2,"result":{"planType":"team","rateLimits":{"primary":{"used_percent":7,"window_minutes":300},"secondary":{"used_percent":11,"window_minutes":10080}}}}
        """.data(using: .utf8)!
        let webAdapter = CodexWebUsageAdapter(appServerClient: StubCodexAppServerRateLimitClient(data: response), allowLegacyDirectHTTP: false)
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.codexManual.webConnectorEnabled = true

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [sessions], webUsageAdapter: webAdapter).snapshot(settings: settings)

        XCTAssertEqual(snapshot.dataSource, .webUsage)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 7)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 11)
        XCTAssertEqual(snapshot.todayTokens, 0)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    // MARK: - CodexLocalSessionAdapter Tests

    func testDefaultPathResolverIncludesClaudeProjectRootsAndStatuslineDefault() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = sandbox.appendingPathComponent("macos-home", isDirectory: true)
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let configDir = sandbox.appendingPathComponent("claude-config", isDirectory: true)
        let configProjects = configDir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configProjects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let resolver = DefaultPathResolver(
            environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": configDir.path],
            currentHomeDirectory: home,
            additionalHomeDirectories: []
        )
        let candidates = resolver.resolveDefaultPaths(for: .claude)

        XCTAssertTrue(candidates.contains { $0.kind == "projects" && $0.path == projects.path && $0.exists && $0.readable })
        XCTAssertTrue(candidates.contains { $0.kind == "config_projects" && $0.path == configProjects.path && $0.exists && $0.readable })
        XCTAssertTrue(candidates.contains { $0.kind == "statusline" && $0.path == home.appendingPathComponent("Library/Application Support/TokenPilot/claude-statusline.json").path })
    }
    func testDefaultPathResolverIncludesAntigravityStatuslineAndLegacyGeminiSources() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = sandbox.appendingPathComponent("macos-home", isDirectory: true)
        let tokenPilotDir = home.appendingPathComponent("Library/Application Support/TokenPilot", isDirectory: true)
        let legacyGeminiTmp = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenPilotDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyGeminiTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let antigravityStatusline = tokenPilotDir.appendingPathComponent("antigravity-statusline.json")
        try "{}".write(to: antigravityStatusline, atomically: true, encoding: .utf8)

        let resolver = DefaultPathResolver(
            environment: ["HOME": home.path],
            currentHomeDirectory: home,
            additionalHomeDirectories: []
        )
        let candidates = resolver.resolveDefaultPaths(for: .gemini)

        XCTAssertTrue(candidates.contains { $0.kind == "antigravity_statusline" && $0.path == antigravityStatusline.path && $0.exists && $0.readable })
        XCTAssertFalse(candidates.contains { $0.kind == "antigravity_settings" || $0.kind == "settings" })
        XCTAssertTrue(candidates.contains { $0.kind == "tmp" && $0.path == legacyGeminiTmp.path && $0.exists && $0.readable })
    }

    func testDefaultPathResolverDetectsCodexSessionsInMacOSHomeWhenProcessHomeDiffers() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let processHome = sandbox.appendingPathComponent("hermes-profile-home", isDirectory: true)
        let macOSHome = sandbox.appendingPathComponent("macos-home", isDirectory: true)
        let processSessions = processHome.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        let macOSSessions = macOSHome.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: processHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOSSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let resolver = DefaultPathResolver(
            environment: ["HOME": processHome.path],
            currentHomeDirectory: processHome,
            additionalHomeDirectories: [macOSHome]
        )
        let candidates = resolver.resolveDefaultPaths(for: .codex)

        XCTAssertTrue(candidates.contains { $0.kind == "sessions" && $0.path == processSessions.path && !$0.exists })
        XCTAssertTrue(candidates.contains { $0.kind == "sessions" && $0.path == macOSSessions.path && $0.exists && $0.readable })
    }

    func testDefaultPathResolverPrioritizesCODEX_HOMEBeforeHomeFallbacks() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let processHome = sandbox.appendingPathComponent("hermes-profile-home", isDirectory: true)
        let macOSHome = sandbox.appendingPathComponent("macos-home", isDirectory: true)
        let codexHome = sandbox.appendingPathComponent("custom-codex-home", isDirectory: true)
        let codexHomeSessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: processHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOSHome.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("sessions", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHomeSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let resolver = DefaultPathResolver(
            environment: ["HOME": processHome.path, "CODEX_HOME": codexHome.path],
            currentHomeDirectory: processHome,
            additionalHomeDirectories: [macOSHome]
        )
        let firstSessions = resolver.resolveDefaultPaths(for: .codex).first { $0.kind == "sessions" }

        XCTAssertEqual(firstSessions?.path, codexHomeSessions.path)
        XCTAssertEqual(firstSessions?.source, "CODEX_HOME")
    }

    func testDefaultPathResolverIncludesCodexArchivedSessionsBesideActiveSessions() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let macOSHome = sandbox.appendingPathComponent("macos-home", isDirectory: true)
        let codexRoot = macOSHome.appendingPathComponent(".codex", isDirectory: true)
        let sessions = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let archived = codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let resolver = DefaultPathResolver(
            environment: ["HOME": macOSHome.path],
            currentHomeDirectory: macOSHome,
            additionalHomeDirectories: []
        )
        let candidates = resolver.resolveDefaultPaths(for: .codex)

        XCTAssertTrue(candidates.contains { $0.kind == "sessions" && $0.path == sessions.path && $0.exists })
        XCTAssertTrue(candidates.contains { $0.kind == "archived_sessions" && $0.path == archived.path && $0.exists })
    }

    func testCodexLocalSessionAdapterUsesMacOSHomeFallbackWhenProcessHomeHasNoCodexSessions() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let processHome = sandbox.appendingPathComponent("hermes-profile-home", isDirectory: true)
        let macOSHome = sandbox.appendingPathComponent("macos-home", isDirectory: true)
        let sessions = macOSHome.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("18", isDirectory: true)
        try FileManager.default.createDirectory(at: processHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let jsonlURL = sessions.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"output_tokens":15,"cached_input_tokens":5,"reasoning_output_tokens":4,"total_tokens":64}}}}
        """
        try content.write(to: jsonlURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(
            environment: ["HOME": processHome.path],
            currentHomeDirectory: processHome,
            additionalHomeDirectories: [macOSHome]
        ).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.dataSource, .localLog)
        XCTAssertEqual(snapshot.todayTokens, 64)
        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testCodexLocalSessionAdapterParsesLastTokenUsageAsExperimentalLocalLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions/2026/05/17", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let jsonlURL = sessions.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = """
        {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-5.3-codex"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":40,"cached_input_tokens":20,"reasoning_output_tokens":30,"total_tokens":190}}}}
        """
        try content.write(to: jsonlURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [directory.appendingPathComponent("sessions")]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.confidence, .medium)
        XCTAssertEqual(snapshot.dataSource, .localLog)
        XCTAssertEqual(snapshot.isExperimental, true)
        XCTAssertEqual(snapshot.statusMessage, "EXPERIMENTAL · local Codex log · not web quota")
        XCTAssertEqual(snapshot.todayTokens, 190)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].model, "gpt-5.3-codex")
        XCTAssertEqual(snapshot.events[0].totalTokens, 190)
    }

    func testCodexLocalSessionAdapterParsesTopLevelTokenCountRowsFromRecentCodexLogs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions/2026/05/17", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonlURL = sessions.appendingPathComponent("rollout-top-level.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = """
        {"type":"turn_context","timestamp":"\(timestamp)","model":"gpt-5.4-codex"}
        {"type":"token_count","timestamp":"\(timestamp)","info":{"last_token_usage":{"input_tokens":42,"output_tokens":11,"cached_input_tokens":9,"reasoning_output_tokens":5,"total_tokens":67},"model":"gpt-5.4-codex"}}
        """
        try content.write(to: jsonlURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [directory.appendingPathComponent("sessions")]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.dataSource, .localLog)
        XCTAssertEqual(snapshot.todayTokens, 67)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].model, "gpt-5.4-codex")
        XCTAssertEqual(snapshot.events[0].inputTokens, 42)
        XCTAssertEqual(snapshot.events[0].cacheReadTokens, 9)
        XCTAssertEqual(snapshot.events[0].reasoningTokens, 5)
    }

    func testCodexLocalSessionAdapterDedupesDuplicateEventsAcrossSessionRoots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        let archived = directory.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":30,\"output_tokens\":10,\"total_tokens\":40},\"model\":\"gpt-5\"}}}"
        try line.write(to: sessions.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: archived.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [sessions, archived]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 40)
    }

    func testCodexLocalSessionAdapterDoesNotCollapseDistinctRowsWithSameTimestampAndUsage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let first = "{\"id\":\"evt-1\",\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":30,\"output_tokens\":10,\"total_tokens\":40},\"model\":\"gpt-5\"}}}"
        let second = "{\"id\":\"evt-2\",\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":30,\"output_tokens\":10,\"total_tokens\":40},\"model\":\"gpt-5\"}}}"
        try [first, second].joined(separator: "\n").write(to: sessions.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [sessions]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(snapshot.todayTokens, 80)
    }

    func testCodexLocalSessionAdapterParsesRateLimitsFromTokenCountRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions/2026/05/18", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let jsonlURL = sessions.appendingPathComponent("rollout-test.jsonl")
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let reset5h = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        let resetWeekly = ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
        let content = """
        {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-5.5"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":25,"reasoning_output_tokens":5,"total_tokens":140},"rate_limits":{"primary":{"used_percent":63,"resets_at":"\(reset5h)","window_minutes":300},"secondary":{"used_percent":41,"resets_at":"\(resetWeekly)","window_minutes":10080}}}}}
        """
        try content.write(to: jsonlURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [directory.appendingPathComponent("sessions")]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 63)
        XCTAssertEqual(snapshot.fiveHour?.providerWindowID, "rate-limit")
        XCTAssertEqual(snapshot.weekly?.usedPercent, 41)
        XCTAssertEqual(snapshot.weekly?.providerWindowID, "rate-limit")
        XCTAssertNotNil(snapshot.fiveHour?.resetAt)
        XCTAssertNotNil(snapshot.weekly?.resetAt)
        XCTAssertEqual(snapshot.model, "gpt-5.5")
    }

    func testCodexLocalSessionTokenCountsAreExactNotEstimated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions/2026/05/18", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let content = """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":25,"reasoning_output_tokens":5,"total_tokens":140}}}}
        """
        try content.write(to: sessions.appendingPathComponent("rollout-exact.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [directory.appendingPathComponent("sessions")])
            .snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        let event = try XCTUnwrap(snapshot.events.first)
        XCTAssertFalse(event.isEstimated, "Server-reported token counts are exact, not estimates.")
        XCTAssertEqual(event.totalTokens, 140)
    }

    func testCodexLocalSessionAdapterParsesRemainingPercentAndRawCountsFromSessionRateLimits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions/2026/05/18", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jsonlURL = sessions.appendingPathComponent("rollout-limit-shapes.jsonl")
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let reset5h = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        let content = """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":5,"total_tokens":25},"rate_limits":{"primary":{"remaining_percent":"37%","resetsAt":"\(reset5h)","window_minutes":300},"secondary":{"used":12,"limit":60,"reset_after_seconds":7200,"window_minutes":10080}}}}}
        """
        try content.write(to: jsonlURL, atomically: true, encoding: .utf8)

        let adapter = CodexLocalSessionAdapter(
            sessionRoots: [directory.appendingPathComponent("sessions")],
            webUsageAdapter: FixedProviderAdapter(snapshot: ProviderSnapshot(provider: .codex, confidence: .low, statusMessage: "web unavailable"))
        )
        let snapshot = await adapter.snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 63)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 20)
        XCTAssertNotNil(snapshot.fiveHour?.resetAt)
        XCTAssertNotNil(snapshot.weekly?.resetAt)
        XCTAssertEqual(snapshot.todayTokens, 25)
    }

    func testDataSourceConnectionServiceMarksCodexLocalLogsConnected() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let macOSHome = sandbox.appendingPathComponent("macos-home", isDirectory: true)
        let sessions = macOSHome.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions/2026/05/18", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":20,"total_tokens":70}}}}
        """
        try content.write(to: sessions.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        let resolver = DefaultPathResolver(environment: ["HOME": macOSHome.path], currentHomeDirectory: macOSHome, additionalHomeDirectories: [])
        let service = DataSourceConnectionService(pathResolver: resolver)

        let source = await service.check(settings: AppSettings(showMockDataWhenDisconnected: false), provider: .codex)

        XCTAssertEqual(source.status, .connected)
        XCTAssertTrue(source.statusMessage?.contains("local Codex") == true)
    }

    func testCodexLocalSessionAdapterDoesNotCarryExpiredFiveHourLimitAsCurrentUsage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions/2026/05/18", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-600))
        let expiredReset = Int(now.addingTimeInterval(-60).timeIntervalSince1970)
        let weeklyReset = Int(now.addingTimeInterval(86_400).timeIntervalSince1970)
        let content = """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":20,"total_tokens":70},"rate_limits":{"primary":{"used_percent":97,"resets_at":\(expiredReset),"window_minutes":300},"secondary":{"used_percent":32,"resets_at":\(weeklyReset),"window_minutes":10080}}}}}
        """
        try content.write(to: sessions.appendingPathComponent("rollout-expired-limit.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [directory.appendingPathComponent("sessions")]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 32)
        XCTAssertNotNil(snapshot.weekly?.resetAt)
    }

    func testCodexLocalSessionAdapterIgnoresTimestamplessUsageRowsEvenWhenFileWasModifiedToday() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jsonlURL = sessions.appendingPathComponent("session.jsonl")
        let content = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":20,"total_tokens":70}}}}
        """
        try content.write(to: jsonlURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: jsonlURL.path)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [sessions]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.events.count, 0)
        XCTAssertEqual(snapshot.todayTokens, 0)
    }

    func testCodexLocalSessionAdapterTailScansLargeSessionFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jsonlURL = sessions.appendingPathComponent("large-session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let oldLine = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":999,\"output_tokens\":1,\"total_tokens\":1000}}}}"
        let tailLine = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":7,\"output_tokens\":3,\"total_tokens\":10}}}}"
        let padding = String(repeating: "x", count: 80_000)
        try [oldLine, padding, tailLine].joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)

        let adapter = CodexLocalSessionAdapter(
            sessionRoots: [sessions],
            environment: [:],
            currentHomeDirectory: directory,
            largeFileFullScanLimitBytes: 1_024,
            largeFileTailBytes: 1_024
        )
        let snapshot = await adapter.snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 10)
    }

    func testCodexLocalSessionAdapterUsesTotalTokenDeltaFallbackAndSkipsDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let jsonlURL = sessions.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let first = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"output_tokens\":20,\"total_tokens\":120}}}}"
        let second = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":180,\"output_tokens\":40,\"total_tokens\":220}}}}"
        try [first, second, second].joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [sessions]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 100)
        XCTAssertEqual(snapshot.events[0].inputTokens, 80)
        XCTAssertEqual(snapshot.events[0].outputTokens, 20)
        XCTAssertEqual(snapshot.events[0].totalTokens, 100)
    }

    func testCodexLocalSessionAdapterSkipsInvalidJsonAndKeepsValidRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let jsonlURL = sessions.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let valid = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}}"
        try ["not json", valid].joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexLocalSessionAdapter(sessionRoots: [sessions]).snapshot(settings: AppSettings(showMockDataWhenDisconnected: false))

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 15)
        XCTAssertEqual(snapshot.statusMessage, "EXPERIMENTAL · local Codex log · not web quota")
    }

    func testGeminiAdapterDirectoryIgnoresSessionAndChatFilesWhileAcceptingTelemetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chats = directory.appendingPathComponent("project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let telemetryURL = directory.appendingPathComponent("TELEMETRY.LOG")
        let unsafeURLs = [
            directory.appendingPathComponent("session-1.json"),
            directory.appendingPathComponent("session-1.jsonl"),
            chats.appendingPathComponent("conversation.json")
        ]
        try """
        {"timestamp":"\(timestamp)","name":"gemini_cli.api_response","metadata":{"input_token_count":60,"output_token_count":30,"total_token_count":90,"model":"gemini-2.5-pro"}}
        """.write(to: telemetryURL, atomically: true, encoding: .utf8)
        for unsafeURL in unsafeURLs {
            try """
            {"timestamp":"\(timestamp)","prompt":"raw user prompt","response":"raw model response","name":"gemini_cli.api_response","metadata":{"input_token_count":600,"output_token_count":300,"total_token_count":900,"model":"gemini-2.5-pro"}}
            """.write(to: unsafeURL, atomically: true, encoding: .utf8)
        }

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = directory.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 90)
        XCTAssertEqual(snapshot.dataSource, .officialTelemetry)
    }

    func testGeminiAdapterDirectSelectionRejectsSessionAndChatFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chats = directory.appendingPathComponent("project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let unsafeURLs = [
            directory.appendingPathComponent("session-1.json"),
            directory.appendingPathComponent("session-1.jsonl"),
            chats.appendingPathComponent("conversation.json")
        ]
        for unsafeURL in unsafeURLs {
            try """
            {"timestamp":"\(timestamp)","prompt":"raw user prompt","response":"raw model response","name":"gemini_cli.api_response","metadata":{"input_token_count":600,"output_token_count":300,"total_token_count":900,"model":"gemini-2.5-pro"}}
            """.write(to: unsafeURL, atomically: true, encoding: .utf8)

            var settings = AppSettings(showMockDataWhenDisconnected: false)
            settings.geminiTelemetryLogPath = unsafeURL.path
            let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

            XCTAssertTrue(snapshot.events.isEmpty)
            XCTAssertEqual(snapshot.todayTokens, 0)
            XCTAssertEqual(snapshot.confidence, .low)
        }
    }

    // MARK: - Discord notifications

    func testDiscordNotificationsAreOffByDefaultAndWebhookIsNotStoredInSettings() {
        let settings = AppSettings()

        XCTAssertFalse(settings.discordNotificationsEnabled)
        XCTAssertFalse(settings.discord.isEnabled)
        XCTAssertEqual(settings.discord.connectionStatus, "Not configured")
        XCTAssertEqual(settings.discord.webhookSummary, "No webhook")
    }

    func testDiscordWebhookRequestUsesWebhookURLWithoutLeakingItIntoPayload() throws {
        let webhookURL = "https://discord.com/api/webhooks/" + "1234567890/" + "redacted-test-token"
        let message = "TokenPilot alert: Claude Code reached 80%."

        let request = try DiscordNotificationService.makeRequest(webhookURL: webhookURL, content: message)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString, webhookURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(payload["content"] as? String, message)
        XCTAssertFalse(String(data: body, encoding: .utf8)?.contains(webhookURL) ?? true)
    }

    func testAlertRuleCanRouteToDiscordIndependentlyFromTelegram() {
        let rule = AlertRule(provider: .claude, window: .fiveHour, macOSEnabled: false, telegramEnabled: false, discordEnabled: true)

        XCTAssertFalse(rule.macOSEnabled)
        XCTAssertFalse(rule.telegramEnabled)
        XCTAssertTrue(rule.discordEnabled)
    }

    // MARK: - Usage history

    func testUsageHistoryStoreRetainsCostOnlySnapshotsWithZeroTokensAndRequestsForExport() throws {
        let suite = "TokenPilotCostOnlyHistoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageHistoryStore(defaults: defaults, key: "history")
        let now = Date()
        let cost = Decimal(string: "1.23")!
        let snapshot = ProviderSnapshot(
            provider: .claude,
            updatedAt: now,
            todayTokens: 0,
            todayCostUSD: cost,
            confidence: .high,
            dataSource: .officialStatusline,
            model: "Claude Cost"
        )

        let retained = store.record(snapshots: [snapshot], enabledProviders: [.claude])
        let event = try XCTUnwrap(retained.first)

        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(event.provider, .claude)
        XCTAssertEqual(event.totalTokens, 0)
        XCTAssertEqual(event.inputTokens, 0)
        XCTAssertEqual(event.outputTokens, 0)
        XCTAssertEqual(event.requestCount, 0)
        XCTAssertEqual(event.estimatedCostUSD, cost)
        XCTAssertEqual(event.source, "snapshot-daily-total")

        let historySnapshots = store.snapshotsForHistory(
            currentSnapshots: [ProviderSnapshot(provider: .claude, dataSource: .officialStatusline)],
            events: store.loadEvents(),
            enabledProviders: [.claude],
            referenceDate: now
        )
        let historySnapshot = try XCTUnwrap(historySnapshots.first)
        let usage = AggregationService().aggregate(snapshots: historySnapshots, period: .today)

        XCTAssertEqual(historySnapshot.todayTokens, 0)
        XCTAssertEqual(historySnapshot.todayCostUSD, cost)
        XCTAssertEqual(usage.metrics.totalTokens, 0)
        XCTAssertEqual(usage.metrics.requestCount, 0)
        XCTAssertEqual(usage.metrics.estimatedCostUSD, cost)

        let data = try UsageExportService().makeJSONData(
            usage: usage,
            snapshots: historySnapshots,
            dataMode: "LIVE",
            generatedAt: now
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(UsageExportPayload.self, from: data)

        XCTAssertEqual(payload.metrics.totalTokens, 0)
        XCTAssertEqual(payload.metrics.requestCount, 0)
        XCTAssertEqual(payload.metrics.estimatedCostUSD, cost)
        XCTAssertEqual(payload.events.first?.totalTokens, 0)
        XCTAssertEqual(payload.events.first?.requestCount, 0)
        XCTAssertEqual(payload.events.first?.estimatedCostUSD, cost)
        XCTAssertEqual(payload.snapshots.first?.todayTokens, 0)
        XCTAssertEqual(payload.snapshots.first?.todayCostUSD, cost)
    }

    func testUsageHistoryStoreDefaultKeyIgnoresLegacyV1AndV2Blobs() {
        let suite = "TokenPilotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyEvent = UsageEvent(provider: .codex, timestamp: Date(), inputTokens: 10, outputTokens: 0, source: "codex-session-jsonl")
        let legacyData = try? JSONEncoder().encode([legacyEvent])
        defaults.set(legacyData, forKey: "tokenPilot.usageEvents.v1")
        defaults.set(legacyData, forKey: "tokenPilot.usageEvents.v2")

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertEqual(store.loadEvents().count, 0)
    }

    func testUsageHistoryStoreCreatesDailySnapshotEventsWithoutDuplicatingRefreshes() {
        let defaults = UserDefaults(suiteName: "TokenPilotTests-\(UUID().uuidString)")!
        let store = UsageHistoryStore(defaults: defaults, key: "history")
        let now = Date()
        let first = ProviderSnapshot(provider: .claude, updatedAt: now, todayTokens: 1_000, model: "Claude")
        let second = ProviderSnapshot(provider: .claude, updatedAt: now.addingTimeInterval(60), todayTokens: 1_500, model: "Claude")

        _ = store.record(snapshots: [first], enabledProviders: [.claude])
        let retained = store.record(snapshots: [second], enabledProviders: [.claude])

        XCTAssertEqual(retained.filter { $0.provider == .claude && $0.source == "snapshot-daily-total" }.count, 1)
        XCTAssertEqual(retained.first?.totalTokens, 1_500)
    }

    func testAggregationIncludesExperimentalCodexLocalLogTokensInInAppStats() {
        let now = Date()
        let codexLocal = UsageEvent(
            provider: .codex,
            timestamp: now,
            inputTokens: 1_000,
            outputTokens: 0,
            source: "codex-session-jsonl",
            dataSource: .localLog,
            isEstimated: true,
            isExperimental: true
        )
        let claude = UsageEvent(provider: .claude, timestamp: now, inputTokens: 100, outputTokens: 0, source: "claude-status")
        let snapshots = [
            ProviderSnapshot(provider: .codex, todayTokens: 1_000, dataSource: .localLog, isExperimental: true, events: [codexLocal]),
            ProviderSnapshot(provider: .claude, todayTokens: 100, events: [claude])
        ]

        let usage = AggregationService().aggregate(snapshots: snapshots, period: .today)

        XCTAssertEqual(usage.metrics.totalTokens, 1100)
        XCTAssertEqual(usage.providerShare.first(where: { $0.provider == .codex })?.tokens, 1000)
        XCTAssertEqual(usage.providerShare.first(where: { $0.provider == .claude })?.tokens, 100)
    }

    func testUsageHistoryStoreKeepsExperimentalCodexLocalLogEventsForInAppStats() {
        let suite = "TokenPilotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageHistoryStore(defaults: defaults, key: "history")
        let codexLocal = UsageEvent(
            provider: .codex,
            timestamp: Date(),
            inputTokens: 2_000,
            outputTokens: 0,
            source: "codex-session-jsonl",
            dataSource: .localLog,
            isEstimated: true,
            isExperimental: true
        )
        let snapshot = ProviderSnapshot(provider: .codex, todayTokens: 2_000, dataSource: .localLog, isExperimental: true, events: [codexLocal])

        let retained = store.record(snapshots: [snapshot], enabledProviders: [.codex])

        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(store.loadEvents().count, 1)

        let historySnapshots = store.snapshotsForHistory(
            currentSnapshots: [snapshot],
            events: retained,
            enabledProviders: [.codex]
        )

        XCTAssertEqual(historySnapshots.first?.events.count, 1)
        XCTAssertEqual(historySnapshots.first?.todayTokens, 2_000)
    }

    func testUsageExportSanitizesExperimentalCodexLocalLogSnapshotTokens() throws {
        let now = Date()
        let codexLocal = UsageEvent(
            provider: .codex,
            timestamp: now,
            inputTokens: 9_999,
            outputTokens: 0,
            source: "codex-session-jsonl",
            dataSource: .localLog,
            isEstimated: true,
            isExperimental: true
        )
        let snapshot = ProviderSnapshot(
            provider: .codex,
            todayTokens: 9_999,
            dataSource: .localLog,
            isExperimental: true,
            statusMessage: "EXPERIMENTAL · local Codex log · not web quota",
            events: [codexLocal]
        )
        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .today)
        let data = try UsageExportService().makeJSONData(usage: usage, snapshots: [snapshot], dataMode: "LIVE")
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(UsageExportPayload.self, from: data)

        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.localActivity.scope, LocalActivityExport.defaultScope)
        XCTAssertTrue(payload.localActivity.quotaComparableOnly)
        XCTAssertEqual(payload.sevenDayBars, payload.localActivity.sevenDayBars)
        XCTAssertEqual(payload.providerShare, payload.localActivity.providerShare)
        XCTAssertEqual(payload.snapshots.first?.todayTokens, 0)
        XCTAssertEqual(payload.metrics.totalTokens, 0)
        XCTAssertTrue(payload.events.isEmpty)
        XCTAssertFalse(raw.contains("codex-session-jsonl"))
        XCTAssertFalse(raw.contains("9999"))
    }

    func testUsageExportCSVMarksV2LocalActivityAndExcludesExperimentalCodexLocalLogEvents() throws {
        let now = Date()
        let included = UsageEvent(
            provider: .claude,
            timestamp: now,
            inputTokens: 10,
            outputTokens: 5,
            source: "claude-statusline",
            dataSource: .officialStatusline
        )
        let excluded = UsageEvent(
            provider: .codex,
            timestamp: now,
            inputTokens: 9_999,
            outputTokens: 0,
            source: "codex-session-jsonl",
            dataSource: .localLog,
            isEstimated: true,
            isExperimental: true
        )
        let snapshots = [
            ProviderSnapshot(provider: .claude, events: [included]),
            ProviderSnapshot(provider: .codex, todayTokens: 9_999, dataSource: .localLog, isExperimental: true, events: [excluded])
        ]
        let usage = AggregationService().aggregate(snapshots: snapshots, period: .today)

        let csv = UsageExportService().makeCSVString(usage: usage)
        let rows = csv.split(separator: "\n").map(String.init)

        XCTAssertTrue(rows.contains { $0.hasPrefix("metadata,today,,schema_version,") && $0.contains(",2,,,,local_activity_contract,") })
        XCTAssertTrue(rows.filter { $0.hasPrefix("provider_share,") }.allSatisfy { $0.contains(",local_activity_not_provider_quota,") })
        XCTAssertTrue(rows.filter { $0.hasPrefix("daily_bar,") }.allSatisfy { $0.contains(",local_activity_not_provider_quota,") })
        XCTAssertTrue(csv.contains("claude-statusline"))
        XCTAssertFalse(csv.contains("codex-session-jsonl"))
        XCTAssertFalse(csv.contains("9999"))
    }
    func testCapacityExportIsVersionedAndExcludesStatusModelForecastAndRawPaths() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let assessment = try percentAssessment(used: 82, resetAt: now.addingTimeInterval(3_600), now: now)
        let data = try UsageExportService().makeJSONData(
            usage: AggregatedUsage(period: .today),
            snapshots: [],
            dataMode: "LIVE",
            generatedAt: now,
            capacityAssessments: [assessment]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(UsageExportPayload.self, from: data)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(payload.capacity?.schemaVersion, 1)
        XCTAssertEqual(payload.capacity?.observations.first?.provider, .claude)
        XCTAssertEqual(payload.capacity?.observations.first?.remainingPercent, 18)
        XCTAssertFalse(raw.contains("forecast"))
        XCTAssertFalse(raw.contains("statusMessage"))
        XCTAssertFalse(raw.contains("/Users/"))
        XCTAssertFalse(raw.contains("secret"))
        // "model" appears in modelBreakdown keys but the old model/statusMessage fields from
        // ProviderSnapshot must not be present as regular export fields.
        XCTAssertFalse(raw.contains("\"statusMessage\""))
    }

    func testUsageExportRedactsSnapshotAndEventDiagnosticFields() throws {
        let now = Date()
        let event = UsageEvent(
            provider: .claude,
            model: "/Users/alice/project prompt: disclose bearer token api_key=sk-abcdefghijklmnopqrstuvwxyz123456",
            timestamp: now,
            inputTokens: 10,
            outputTokens: 5,
            source: "claude-statusline",
            dataSource: .officialStatusline
        )
        let snapshot = ProviderSnapshot(
            provider: .claude,
            updatedAt: now,
            todayTokens: 15,
            confidence: .high,
            dataSource: .officialStatusline,
            statusMessage: "Failed reading /Users/alice/.codex/auth.json response: secret prompt transcript",
            model: "Bearer fixture-token-from-model",
            events: [event]
        )
        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .today)

        let data = try UsageExportService().makeJSONData(usage: usage, snapshots: [snapshot], dataMode: "LIVE", generatedAt: now)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(UsageExportPayload.self, from: data)

        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.localActivity.scope, LocalActivityExport.defaultScope)
        XCTAssertTrue(payload.localActivity.quotaComparableOnly)
        XCTAssertEqual(payload.sevenDayBars, payload.localActivity.sevenDayBars)
        XCTAssertEqual(payload.providerShare, payload.localActivity.providerShare)
        XCTAssertEqual(payload.metrics.totalTokens, 15)
        XCTAssertEqual(payload.events.first?.totalTokens, 15)
        XCTAssertFalse(raw.contains("/Users/alice"))
        XCTAssertFalse(raw.contains("auth.json"))
        XCTAssertFalse(raw.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(raw.contains("fixture-token-from-model"))
        XCTAssertFalse(raw.contains("secret prompt transcript"))
        XCTAssertFalse(raw.contains("disclose bearer token"))
    }

    func testAggregationPeriodsChangeWhenHistoryContainsOlderEvents() {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 15
        components.hour = 12
        let now = calendar.date(from: components)!
        let current = UsageEvent(provider: .claude, timestamp: now, inputTokens: 100, outputTokens: 0, source: "test")
        let yesterday = UsageEvent(provider: .claude, timestamp: now.addingTimeInterval(-24 * 60 * 60), inputTokens: 200, outputTokens: 0, source: "test")
        let snapshots = [ProviderSnapshot(provider: .claude, updatedAt: now, todayTokens: 100, events: [current, yesterday])]
        let service = AggregationService()

        let today = service.aggregate(snapshots: snapshots, period: .today, now: now)
        let sevenDays = service.aggregate(snapshots: snapshots, period: .last7Days, now: now)
        let month = service.aggregate(snapshots: snapshots, period: .thisMonth, now: now)

        XCTAssertEqual(today.metrics.totalTokens, 100)
        XCTAssertEqual(sevenDays.metrics.totalTokens, 300)
        XCTAssertGreaterThanOrEqual(month.metrics.totalTokens, sevenDays.metrics.totalTokens)
        XCTAssertNotEqual(today.metrics.totalTokens, sevenDays.metrics.totalTokens)
    }

    // MARK: - Provider visibility and menu bar selection

    func testXAIProviderEnablementRequiresExplicitSelection() {
        var settings = AppSettings()

        XCTAssertFalse(settings.xaiEnabled)
        XCTAssertFalse(settings.isProviderEnabled(.xai))
        XCTAssertFalse(settings.enabledProviders.contains(.xai))

        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        XCTAssertTrue(settings.xaiEnabled)
        XCTAssertTrue(settings.isProviderEnabled(.xai))
        XCTAssertTrue(settings.monitoredProviders.enabledProviders.contains(.xai))

        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: false))
        XCTAssertFalse(settings.xaiEnabled)
        XCTAssertFalse(settings.isProviderEnabled(.xai))
        XCTAssertFalse(settings.monitoredProviders.enabledProviders.contains(.xai))

        let monitoredOnly = AppSettings(
            xaiEnabled: false,
            monitoredProviders: MonitoredProviderSettings(enabledProviders: [.claude, .xai])
        )

        XCTAssertFalse(monitoredOnly.xaiEnabled)
        XCTAssertEqual(monitoredOnly.enabledProviders, [.claude, .xai, .opencode, .kiro])
        XCTAssertTrue(monitoredOnly.isProviderEnabled(.xai))
    }

    func testXAIDisabledDefaultsAreNeutralAndSkippedByUsageStore() async {
        let settings = AppSettings()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let adapter = XAIManagementDiagnosticsAdapter()

        let direct = await adapter.refresh(settings: settings, now: now)
        XCTAssertEqual(direct.snapshot.provider, .xai)
        XCTAssertEqual(direct.snapshot.updatedAt, now)
        XCTAssertEqual(direct.snapshot.confidence, .low)
        XCTAssertEqual(direct.snapshot.dataSource, .unknown)
        XCTAssertEqual(direct.snapshot.statusMessage, "Disabled")
        XCTAssertEqual(direct.snapshot.todayTokens, 0)
        XCTAssertTrue(direct.snapshot.events.isEmpty)
        XCTAssertTrue(direct.capacityObservations.isEmpty)
        XCTAssertTrue(direct.typedErrors.isEmpty)

        let skipped = await UsageStore(refreshAdapters: [adapter]).refresh(settings: settings)

        XCTAssertTrue(skipped.snapshots.isEmpty)
        XCTAssertFalse(skipped.hasConnectedData)
        XCTAssertTrue(skipped.capacityObservations.isEmpty)
        XCTAssertTrue(skipped.capacityErrors.isEmpty)
    }

    func testXAIConnectionDiagnosticsStayLocalAndAuthenticationUnconfirmed() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotXAITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = DefaultPathResolver(environment: ["HOME": home.path], currentHomeDirectory: home, additionalHomeDirectories: [])
        let service = DataSourceConnectionService(pathResolver: resolver)

        XCTAssertEqual(resolver.resolveDefaultPaths(for: .xai), [])

        let disabled = await service.check(settings: AppSettings(), provider: .xai)
        XCTAssertEqual(disabled.provider, .xai)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(disabled.mode, .disabled)
        XCTAssertEqual(disabled.detectedPaths, [])
        XCTAssertNil(disabled.customPath)
        XCTAssertEqual(disabled.status, .disabled)
        XCTAssertEqual(disabled.confidence, .low)
        XCTAssertEqual(disabled.statusMessage, "Disabled")

        var setupNeeded = AppSettings()
        XCTAssertTrue(setupNeeded.setProviderEnabled(.xai, isEnabled: true))
        let setupSource = await service.check(settings: setupNeeded, provider: .xai)
        XCTAssertTrue(setupSource.isEnabled)
        XCTAssertEqual(setupSource.mode, .custom)
        XCTAssertEqual(setupSource.detectedPaths, [])
        XCTAssertEqual(setupSource.status, .manual)
        XCTAssertEqual(setupSource.confidence, .manual)
        XCTAssertEqual(setupSource.statusMessage, "Setup needed · save management key in Keychain and local team ID")
        XCTAssertEqual(setupSource.connectionDiagnostic().nextAction, .enterAPIKey)

        var keyOnly = setupNeeded
        keyOnly.xAI = XAISettings(managementAPIKeyConfigured: true)
        let keyOnlySource = await service.check(settings: keyOnly, provider: .xai)
        XCTAssertEqual(keyOnlySource.statusMessage, "Setup needed · local team ID required")

        var teamOnly = setupNeeded
        teamOnly.xAI = XAISettings(teamID: " team-local-123 ")
        let teamOnlySource = await service.check(settings: teamOnly, provider: .xai)
        XCTAssertEqual(teamOnlySource.statusMessage, "Setup needed · management key required in Keychain")

        var complete = setupNeeded
        complete.xAI = XAISettings(teamID: " team-local-123 ", managementAPIKeyConfigured: true)
        let completeSource = await service.check(settings: complete, provider: .xai)
        let diagnostic = completeSource.connectionDiagnostic()

        XCTAssertEqual(complete.xAI.teamID, "team-local-123")
        XCTAssertEqual(completeSource.status, .manual)
        XCTAssertEqual(completeSource.confidence, .manual)
        XCTAssertEqual(completeSource.statusMessage, "Management authentication unconfirmed")
        XCTAssertEqual(diagnostic.status, .manual)
        XCTAssertEqual(diagnostic.nextAction, .enterAPIKey)
        XCTAssertFalse(diagnostic.redactedDetail.contains("team-local-123"))
        XCTAssertFalse(diagnostic.redactedDetail.contains("/Users/"))
        XCTAssertFalse(diagnostic.redactedDetail.localizedCaseInsensitiveContains("api.x.ai"))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let refresh = await XAIManagementDiagnosticsAdapter().refresh(settings: complete, now: now)

        XCTAssertEqual(refresh.snapshot.provider, .xai)
        XCTAssertEqual(refresh.snapshot.updatedAt, now)
        XCTAssertEqual(refresh.snapshot.confidence, .low)
        XCTAssertEqual(refresh.snapshot.dataSource, .manual)
        XCTAssertEqual(refresh.snapshot.statusMessage, "Management authentication unconfirmed")
        XCTAssertEqual(refresh.snapshot.todayTokens, 0)
        XCTAssertNil(refresh.snapshot.primaryUsedPercent)
        XCTAssertNil(refresh.snapshot.balance)
        XCTAssertTrue(refresh.snapshot.events.isEmpty)
        XCTAssertTrue(refresh.capacityObservations.isEmpty)
        XCTAssertTrue(refresh.typedErrors.isEmpty)
    }

    func testXAIOpenCodeBarAdapterTrustsOnlyCanonicalSecureHomebrewExecutables() {
        XCTAssertTrue(XAIOpenCodeBarAdapter.isTrustedExecutable(
            canonicalPath: "/opt/homebrew/Cellar/opencode-bar/1.2.3/bin/opencodebar",
            isRegularFile: true,
            isExecutable: true,
            ownerID: 0,
            currentUserID: 501,
            permissions: 0o755
        ))
        XCTAssertTrue(XAIOpenCodeBarAdapter.isTrustedExecutable(
            canonicalPath: "/usr/local/Cellar/opencode-bar/1.2.3/bin/opencodebar",
            isRegularFile: true,
            isExecutable: true,
            ownerID: 0,
            currentUserID: 501,
            permissions: 0o555
        ))
        XCTAssertFalse(XAIOpenCodeBarAdapter.isTrustedExecutable(
            canonicalPath: "/Users/person/bin/opencodebar",
            isRegularFile: true,
            isExecutable: true,
            ownerID: 0,
            currentUserID: 501,
            permissions: 0o755
        ))
        XCTAssertFalse(XAIOpenCodeBarAdapter.isTrustedExecutable(
            canonicalPath: "/opt/homebrew/Cellar/opencode-bar/1.2.3/bin/opencodebar",
            isRegularFile: true,
            isExecutable: true,
            ownerID: 0,
            currentUserID: 501,
            permissions: 0o775
        ))
        XCTAssertFalse(XAIOpenCodeBarAdapter.isTrustedExecutable(
            canonicalPath: "/opt/homebrew/Cellar/opencode-bar/1.2.3/bin/opencodebar",
            isRegularFile: false,
            isExecutable: true,
            ownerID: 0,
            currentUserID: 501,
            permissions: 0o755
        ))
    }
    func testXAIOpenCodeBarAdapterUsesInjectedRunnerOnlyForExplicitExperimentalSource() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = AppSettings()
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        settings.xAI = XAISettings(teamID: "local-team", managementAPIKeyConfigured: true)

        let adapter = XAIOpenCodeBarAdapter(runner: {
            throw CancellationError()
        })
        let management = await adapter.refresh(settings: settings, now: now)

        XCTAssertEqual(management.snapshot.dataSource, .manual)
        XCTAssertEqual(management.snapshot.statusMessage, "Management authentication unconfirmed")
        XCTAssertFalse(management.snapshot.isExperimental)

        settings.xAI.usageSource = .experimentalOpenCodeBarCLI
        let experimental = await adapter.refresh(settings: settings, now: now)

        XCTAssertTrue(experimental.snapshot.isExperimental)
        XCTAssertEqual(experimental.snapshot.dataSource, .experimentalCLI)
        XCTAssertNil(experimental.snapshot.primaryUsedPercent)
        XCTAssertTrue(experimental.snapshot.statusMessage?.contains("EXPERIMENTAL") == true)
        XCTAssertTrue(experimental.snapshot.statusMessage?.contains("UNOFFICIAL") == true)
        XCTAssertFalse(experimental.snapshot.statusMessage?.contains("CancellationError") == true)
    }

    func testXAIOpenCodeBarAdapterParsesTopLevelGrokMonthlyUsageWithoutIdentityFields() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = """
        {
          "grok": {
            "usagePercentage": "37.4",
            "monthlyResetsAt": "2027-01-01T00:00:00Z",
            "email": "person@example.com",
            "accountId": "account-123",
            "oauthToken": "oauth-secret",
            "authSource": "cookies"
          }
        }
        """
        var settings = AppSettings()
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        settings.xAI.usageSource = .experimentalOpenCodeBarCLI
        let adapter = XAIOpenCodeBarAdapter(runner: { Data(payload.utf8) })

        let result = await adapter.refresh(settings: settings, now: now)
        let snapshot = result.snapshot

        XCTAssertEqual(snapshot.provider, .xai)
        XCTAssertEqual(snapshot.monthly?.kind, .monthly)
        XCTAssertEqual(snapshot.monthly?.usedPercent, 37)
        XCTAssertEqual(snapshot.monthly?.resetAt, Date(timeIntervalSince1970: 1_798_761_600))
        XCTAssertEqual(snapshot.monthly?.name, "Grok monthly usage")
        XCTAssertEqual(snapshot.monthly?.label, "Grok monthly usage")
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.dataSource, .experimentalCLI)
        XCTAssertTrue(snapshot.isExperimental)
        XCTAssertTrue(snapshot.statusMessage?.contains("EXPERIMENTAL") == true)
        XCTAssertTrue(snapshot.statusMessage?.contains("UNOFFICIAL") == true)
        XCTAssertTrue(snapshot.statusMessage?.localizedCaseInsensitiveContains("monthly") == true)
        let exposed = "\(snapshot.statusMessage ?? "") \(snapshot.events)"
        XCTAssertFalse(exposed.contains("person@example.com"))
        XCTAssertFalse(exposed.contains("account-123"))
        XCTAssertFalse(exposed.contains("oauth-secret"))
        XCTAssertFalse(exposed.contains("cookies"))
    }

    func testXAIOpenCodeBarAdapterReturnsNeutralUnavailableSnapshotsForInvalidRunnerResults() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = AppSettings()
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        settings.xAI.usageSource = .experimentalOpenCodeBarCLI

        let malformed = await XAIOpenCodeBarAdapter(runner: { Data("{".utf8) }).refresh(settings: settings, now: now)
        let missing = await XAIOpenCodeBarAdapter(runner: { Data(#"{"grok":{}}"#.utf8) }).refresh(settings: settings, now: now)
        let oversized = await XAIOpenCodeBarAdapter(runner: { Data(repeating: 0x20, count: 64 * 1_024 + 1) }).refresh(settings: settings, now: now)
        let failed = await XAIOpenCodeBarAdapter(runner: {
            throw NSError(domain: "raw stderr oauth-secret person@example.com", code: 1)
        }).refresh(settings: settings, now: now)

        for result in [malformed, missing, oversized, failed] {
            XCTAssertEqual(result.snapshot.provider, .xai)
            XCTAssertEqual(result.snapshot.dataSource, .experimentalCLI)
            XCTAssertTrue(result.snapshot.isExperimental)
            XCTAssertNil(result.snapshot.primaryUsedPercent)
            XCTAssertNil(result.snapshot.fiveHour)
            XCTAssertNil(result.snapshot.monthly)
            XCTAssertTrue(result.snapshot.events.isEmpty)
            XCTAssertTrue(result.capacityObservations.isEmpty)
            XCTAssertTrue(result.typedErrors.isEmpty)
        }
        XCTAssertTrue(malformed.snapshot.statusMessage?.contains("unsupported response") == true)
        XCTAssertTrue(missing.snapshot.statusMessage?.contains("unsupported response") == true)
        XCTAssertTrue(oversized.snapshot.statusMessage?.contains("too much data") == true)
        XCTAssertTrue(failed.snapshot.statusMessage?.contains("unavailable") == true)
        XCTAssertFalse(failed.snapshot.statusMessage?.contains("raw stderr") == true)
        XCTAssertFalse(failed.snapshot.statusMessage?.contains("oauth-secret") == true)
        XCTAssertFalse(failed.snapshot.statusMessage?.contains("person@example.com") == true)
    }
    func testGrokLocalSignalsAdapterUsesNewestValidSignalsFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotGrokSignals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let older = root.appendingPathComponent("older", isDirectory: true).appendingPathComponent("signals.json")
        let newer = root.appendingPathComponent("newer", isDirectory: true).appendingPathComponent("signals.json")
        try FileManager.default.createDirectory(at: older.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"contextWindowUsage":12}"#.utf8).write(to: older)
        try Data(#"{"contextTokensUsed":640,"contextWindowTokens":800}"#.utf8).write(to: newer)
        let olderDate = Date(timeIntervalSince1970: 1_700_000_100)
        let newerDate = Date(timeIntervalSince1970: 1_700_000_200)
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newer.path)
        // Keep the parent session directories discoverable via summary markers.
        try Data(#"{"updated_at":"2023-11-14T22:16:40Z"}"#.utf8).write(to: older.deletingLastPathComponent().appendingPathComponent("summary.json"))
        try Data(#"{"updated_at":"2023-11-14T22:16:40Z"}"#.utf8).write(to: newer.deletingLastPathComponent().appendingPathComponent("summary.json"))
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: older.deletingLastPathComponent().appendingPathComponent("summary.json").path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newer.deletingLastPathComponent().appendingPathComponent("summary.json").path)

        let now = newerDate.addingTimeInterval(60)
        let result = await GrokLocalSignalsAdapter(sessionRoots: [root]).refresh(settings: AppSettings(), now: now)

        XCTAssertEqual(result.snapshot.provider, .xai)
        XCTAssertEqual(result.snapshot.updatedAt, newerDate)
        XCTAssertEqual(result.snapshot.dataSource, .localLog)
        XCTAssertEqual(result.snapshot.model, "Grok Build")
        XCTAssertEqual(result.snapshot.contextWindowUsedPercent, 80)
        XCTAssertFalse(result.snapshot.isStale)
        XCTAssertEqual(result.snapshot.statusMessage, "LOCAL · Grok Build context window")
        XCTAssertNil(result.snapshot.fiveHour)
        XCTAssertNil(result.snapshot.weekly)
        XCTAssertNil(result.snapshot.monthly)
        XCTAssertEqual(result.snapshot.todayTokens, 0)
        XCTAssertTrue(result.snapshot.events.isEmpty)
        XCTAssertTrue(result.capacityObservations.isEmpty)
    }

    func testGrokLocalSignalsAdapterRejectsAuthSymlinkOversizedAndNonSignalsFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotGrokSignals-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotGrokOutside-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data(#"{"contextWindowUsage":99}"#.utf8).write(to: root.appendingPathComponent("auth.json"))
        try Data(#"{"contextWindowUsage":90}"#.utf8).write(to: root.appendingPathComponent("other.json"))
        try Data(repeating: 0x20, count: 256 * 1_024 + 1).write(to: root.appendingPathComponent("signals.json"))
        try Data(#"{"contextWindowUsage":85}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked", isDirectory: true), withDestinationURL: outside.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("session", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("session", isDirectory: true).appendingPathComponent("signals.json"), withDestinationURL: outside)

        let result = await GrokLocalSignalsAdapter(sessionRoots: [root]).refresh(settings: AppSettings(), now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(result.snapshot.dataSource, .localLog)
        XCTAssertNil(result.snapshot.contextWindowUsedPercent)
        XCTAssertEqual(result.snapshot.statusMessage, "LOCAL · Grok Build context window unavailable")
        XCTAssertTrue(result.snapshot.events.isEmpty)
    }

    func testGrokLocalSignalsAdapterReturnsNeutralLocalUnavailableWhenMissing() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotGrokSignals-\(UUID().uuidString)", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let result = await GrokLocalSignalsAdapter(sessionRoots: [root]).refresh(settings: AppSettings(), now: now)

        XCTAssertEqual(result.snapshot.provider, .xai)
        XCTAssertEqual(result.snapshot.updatedAt, now)
        XCTAssertEqual(result.snapshot.dataSource, .localLog)
        XCTAssertEqual(result.snapshot.model, "Grok Build")
        XCTAssertNil(result.snapshot.contextWindowUsedPercent)
        XCTAssertNil(result.snapshot.primaryUsedPercent)
        XCTAssertEqual(result.snapshot.todayTokens, 0)
        XCTAssertTrue(result.snapshot.events.isEmpty)
        XCTAssertEqual(result.snapshot.statusMessage, "LOCAL · Grok Build context window unavailable")
    }
    func testGrokLocalSignalsAdapterMarksStaleSignalsAndHidesWhenNewerSessionHasNoSignals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotGrokSignals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldSession = root.appendingPathComponent("old-session", isDirectory: true)
        let newSession = root.appendingPathComponent("new-session", isDirectory: true)
        try FileManager.default.createDirectory(at: oldSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newSession, withIntermediateDirectories: true)

        let signals = oldSession.appendingPathComponent("signals.json")
        try Data(#"{"contextWindowUsage":20}"#.utf8).write(to: signals)
        try Data(#"{"updated_at":"2023-11-14T22:00:00Z"}"#.utf8).write(to: oldSession.appendingPathComponent("summary.json"))
        try Data(#"{"updated_at":"2023-11-14T23:00:00Z"}"#.utf8).write(to: newSession.appendingPathComponent("summary.json"))
        try Data("".utf8).write(to: newSession.appendingPathComponent("chat_history.jsonl"))

        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_003_600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: signals.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldSession.appendingPathComponent("summary.json").path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newSession.appendingPathComponent("summary.json").path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newSession.appendingPathComponent("chat_history.jsonl").path)

        let staleOnlyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotGrokSignalsStale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleOnlyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staleOnlyRoot) }
        let staleSession = staleOnlyRoot.appendingPathComponent("only", isDirectory: true)
        try FileManager.default.createDirectory(at: staleSession, withIntermediateDirectories: true)
        let staleSignals = staleSession.appendingPathComponent("signals.json")
        try Data(#"{"contextWindowUsage":20}"#.utf8).write(to: staleSignals)
        try Data(#"{"updated_at":"2023-11-14T22:00:00Z"}"#.utf8).write(to: staleSession.appendingPathComponent("summary.json"))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleSignals.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleSession.appendingPathComponent("summary.json").path)

        let staleNow = oldDate.addingTimeInterval(20 * 60)
        let staleResult = await GrokLocalSignalsAdapter(sessionRoots: [staleOnlyRoot]).refresh(settings: AppSettings(), now: staleNow)
        XCTAssertEqual(staleResult.snapshot.contextWindowUsedPercent, 20)
        XCTAssertTrue(staleResult.snapshot.isStale)
        XCTAssertEqual(staleResult.snapshot.updatedAt, oldDate)
        XCTAssertEqual(staleResult.snapshot.statusMessage, "STALE · LOCAL · Grok Build context window")

        let hiddenResult = await GrokLocalSignalsAdapter(sessionRoots: [root]).refresh(settings: AppSettings(), now: newDate.addingTimeInterval(30))
        XCTAssertNil(hiddenResult.snapshot.contextWindowUsedPercent)
        XCTAssertEqual(hiddenResult.snapshot.statusMessage, "LOCAL · Grok Build context window unavailable · newer session has no signals")
        XCTAssertTrue(hiddenResult.snapshot.events.isEmpty)
    }

    func testMenuBarProviderMetricsUsesOnlySelectedEnabledProviders() {
        var settings = AppSettings()
        settings.menuBarMetricProviders = [.claude, .codex]
        XCTAssertTrue(settings.setProviderEnabled(.codex, isEnabled: false))
        let snapshots = [
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 20)),
            ProviderSnapshot(provider: .codex, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 80))
        ]

        let segments = MenuBarStatusService().providerMetricsSegments(snapshots: snapshots, settings: settings)

        XCTAssertEqual(segments.map(\.provider), [.claude])
    }
    func testMenuBarShowsGrokLocalContextAsLocalRemainingOnly() {
        var settings = AppSettings()
        settings.localization.language = .en
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        settings.menuBarDisplayStyle = .providerMetrics
        settings.menuBarDisplayTarget = .xai
        let snapshot = ProviderSnapshot(
            provider: .xai,
            dataSource: .localLog,
            statusMessage: "LOCAL · Grok Build context window",
            model: "Grok Build",
            contextWindowUsedPercent: 63
        )
        let staleSnapshot = ProviderSnapshot(
            provider: .xai,
            dataSource: .localLog,
            isStale: true,
            statusMessage: "STALE · LOCAL · Grok Build context window",
            model: "Grok Build",
            contextWindowUsedPercent: 20
        )

        let segment = MenuBarStatusService().providerMetricsSegments(snapshots: [snapshot], settings: settings).first
        let staleSegment = MenuBarStatusService().providerMetricsSegments(snapshots: [staleSnapshot], settings: settings).first
        let unavailable = MenuBarStatusService().providerMetricsSegments(
            snapshots: [
                ProviderSnapshot(
                    provider: .xai,
                    dataSource: .localLog,
                    statusMessage: "LOCAL · Grok Build context window unavailable · newer session has no signals",
                    model: "Grok Build"
                )
            ],
            settings: settings
        ).first

        XCTAssertEqual(segment?.providerShortLabel, "GROK CTX")
        XCTAssertEqual(segment?.displayValue, "37%")
        XCTAssertTrue(segment?.accessibilityLabel.contains("Grok / xAI API") == true)
        XCTAssertTrue(segment?.accessibilityLabel.contains("Grok Build context window") == true)
        XCTAssertTrue(segment?.accessibilityLabel.contains("Not subscription quota") == true)
        XCTAssertTrue(segment?.accessibilityLabel.contains("Remaining 37%") == true)
        XCTAssertTrue(segment?.accessibilityLabel.contains("Used 63%") == true)
        XCTAssertFalse(segment?.accessibilityLabel.contains("provider-reported") == true)
        XCTAssertFalse(segment?.accessibilityLabel.localizedCaseInsensitiveContains("capacity") == true)

        XCTAssertEqual(staleSegment?.displayValue, "80%·S")
        XCTAssertTrue(staleSegment?.accessibilityLabel.contains("Stale") == true)
        XCTAssertTrue(staleSegment?.accessibilityLabel.contains("Not subscription quota") == true)
        XCTAssertEqual(unavailable?.displayValue, "—")
    }

    func testMenuBarPrefersManualGrokWeeklyLimitOverLocalContext() {
        var settings = AppSettings()
        settings.localization.language = .en
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        settings.menuBarDisplayStyle = .providerMetrics
        settings.menuBarMetricProviders = [.xai]
        settings.xAI.weeklySnapshotEnabled = true
        settings.xAI.weeklyRemainingPercent = 64
        settings.xAI.weeklySnapshotCapturedAt = Date()

        let local = ProviderSnapshot(
            provider: .xai,
            dataSource: .localLog,
            statusMessage: "LOCAL · Grok Build context window",
            model: "Grok Build",
            contextWindowUsedPercent: 20
        )
        let segment = MenuBarStatusService().providerMetricsSegments(snapshots: [local], settings: settings)
            .first { $0.provider == .xai }

        XCTAssertEqual(segment?.providerShortLabel, "GROK")
        XCTAssertEqual(segment?.displayValue, "64%·M")
        XCTAssertTrue(segment?.accessibilityLabel.contains("Manual weekly limit") == true)
        XCTAssertTrue(segment?.accessibilityLabel.contains("Remaining 64%") == true)
        XCTAssertTrue(segment?.accessibilityLabel.contains("Used 36%") == true)
        XCTAssertTrue(segment?.accessibilityLabel.contains("Not automatic Orca-style session import") == true)
        XCTAssertFalse(segment?.accessibilityLabel.contains("Grok Build context window") == true)
    }
    func testMenuBarDisplaysOpenCodeBarAsUnofficialMonthlyOnlyWhenOptedIn() {
        var settings = AppSettings()
        settings.localization.language = .en
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        settings.menuBarDisplayStyle = .providerMetrics
        settings.menuBarDisplayTarget = .xai
        let snapshot = ProviderSnapshot(
            provider: .xai,
            monthly: LimitWindow(kind: .monthly, usedPercent: 37),
            dataSource: .experimentalCLI,
            isExperimental: true,
            statusMessage: "EXPERIMENTAL · UNOFFICIAL · OpenCode Bar CLI · Monthly usage"
        )
        let service = MenuBarStatusService()

        XCTAssertEqual(service.displayWindow(for: snapshot)?.kind, .monthly)
        XCTAssertNil(service.displayWindow(for: ProviderSnapshot(
            provider: .xai,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 37),
            dataSource: .experimentalCLI,
            isExperimental: true,
            statusMessage: "EXPERIMENTAL · UNOFFICIAL · OpenCode Bar CLI"
        )))

        settings.xAI.usageSource = .experimentalOpenCodeBarCLI
        let optedIn = service.providerMetricsSegments(snapshots: [snapshot], settings: settings)
        XCTAssertEqual(optedIn.first?.displayValue, "63%·E")
        XCTAssertTrue(optedIn.first?.accessibilityLabel.contains("Unofficial") == true)
        XCTAssertTrue(optedIn.first?.accessibilityLabel.contains("Monthly") == true)

        settings.xAI.usageSource = .managementSetup
        let optedOut = service.providerMetricsSegments(snapshots: [snapshot], settings: settings)
        XCTAssertNotEqual(optedOut.first?.displayValue, "63%·E")
    }
    func testXAINoDefaultAlertsOrCapacityEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = AppSettings()
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        settings.xAI = XAISettings(teamID: "team-local-123", managementAPIKeyConfigured: true)
        let snapshot = ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 90),
            todayTokens: 123,
            confidence: .low,
            dataSource: .manual,
            statusMessage: "Management authentication unconfirmed"
        )

        XCTAssertFalse(AppSettings.defaultAlertRules.contains { $0.provider == .xai })
        XCTAssertEqual(CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now), [])
        XCTAssertEqual(CapacityObservationFactory.errors(from: snapshot, provider: .xai), [])

        let suite = "TokenPilotXAINotificationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = NotificationRuleService(store: AlertDeduplicationStore(defaults: defaults))
            .evaluate(snapshots: [snapshot], settings: AppSettings())

        XCTAssertTrue(notifications.isEmpty)
    }

    func testXAITeamIDTrimmingRedactionAndExportExclusion() throws {
        let teamID = "team-secret-123"
        var settings = AppSettings()
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        settings.xAI = XAISettings(teamID: "  \(teamID)\n", managementAPIKeyConfigured: true)

        XCTAssertEqual(settings.xAI.teamID, teamID)

        let suite = "TokenPilotXAISettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokenPilotSettingsStore(defaults: defaults)
        store.save(settings)
        let loaded = store.load()

        XCTAssertEqual(loaded.xAI.teamID, teamID)
        XCTAssertTrue(loaded.xAI.managementAPIKeyConfigured)
        XCTAssertTrue(loaded.isProviderEnabled(.xai))

        let redacted = TokenPilotPrivacyRedactor.redact(
            "xai team id=\(teamID) org id=org-secret-456 /teams/\(teamID) api_key=management-secret-value-1234567890"
        )

        XCTAssertFalse(redacted.contains(teamID))
        XCTAssertFalse(redacted.contains("org-secret-456"))
        XCTAssertFalse(redacted.contains("management-secret-value-1234567890"))
        XCTAssertTrue(redacted.contains("[REDACTED_TEAM]"))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            todayTokens: 0,
            confidence: .manual,
            dataSource: .manual,
            statusMessage: "xai team id=\(teamID) api_key=management-secret-value-1234567890",
            model: teamID
        )
        let data = try UsageExportService().makeJSONData(
            usage: AggregatedUsage(period: .today),
            snapshots: [snapshot],
            dataMode: "LIVE",
            generatedAt: now
        )
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(UsageExportPayload.self, from: data)

        XCTAssertEqual(payload.snapshots.first?.provider, .xai)
        XCTAssertEqual(payload.snapshots.first?.todayTokens, 0)
        XCTAssertTrue(payload.events.isEmpty)
        XCTAssertFalse(raw.contains(teamID))
        XCTAssertFalse(raw.contains("management-secret-value-1234567890"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("teamID"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("team id"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("statusMessage"))
    }

    func testProviderEnablementKeepsLegacyFlagsAndMonitoredSetInSync() {
        var settings = AppSettings()

        XCTAssertTrue(settings.setProviderEnabled(.claude, isEnabled: false))
        XCTAssertFalse(settings.isProviderEnabled(.claude))
        XCTAssertFalse(settings.claudeEnabled)
        XCTAssertFalse(settings.monitoredProviders.enabledProviders.contains(.claude))

        XCTAssertTrue(settings.setProviderEnabled(.claude, isEnabled: true))
        XCTAssertTrue(settings.isProviderEnabled(.claude))
        XCTAssertTrue(settings.claudeEnabled)
        XCTAssertTrue(settings.monitoredProviders.enabledProviders.contains(.claude))
    }

    func testProviderEnablementKeepsAtLeastOneProviderEnabled() {
        var settings = AppSettings()
        XCTAssertTrue(settings.setProviderEnabled(.claude, isEnabled: false))
        XCTAssertTrue(settings.setProviderEnabled(.gemini, isEnabled: false))

        XCTAssertTrue(settings.setProviderEnabled(.codex, isEnabled: false))
        XCTAssertEqual(settings.enabledProviders, [.deepseek, .opencode, .kiro])
        XCTAssertTrue(settings.isProviderEnabled(.deepseek))
    }

    func testDeepSeekDefaultsOnForLegacyMonitoredProviderSets() {
        let legacyMonitored = MonitoredProviderSettings(enabledProviders: [.claude, .codex, .gemini])
        let settings = AppSettings(monitoredProviders: legacyMonitored)

        XCTAssertTrue(settings.deepseekEnabled)
        XCTAssertTrue(settings.isProviderEnabled(.deepseek))
        XCTAssertEqual(settings.enabledProviders, [.claude, .codex, .gemini, .deepseek, .opencode, .kiro])
    }

    func testDeepSeekDiagnosticsRequireAPIKeyBeforeConnection() async {
        let service = DataSourceConnectionService()
        var settings = AppSettings()
        settings.deepseekAPIKeyConfigured = false

        let source = await service.check(settings: settings, provider: .deepseek)
        let diagnostic = source.connectionDiagnostic()

        XCTAssertEqual(source.status, .manual)
        XCTAssertEqual(source.statusMessage, "API key required")
        XCTAssertEqual(diagnostic.nextAction, .enterAPIKey)
        XCTAssertFalse(diagnostic.redactedDetail.contains("sk-"))
        XCTAssertFalse(diagnostic.redactedDetail.contains("Authorization"))
    }

    func testDeepSeekDiagnosticsShowConnectedWhenAPIKeyIsSaved() async {
        let service = DataSourceConnectionService()
        var settings = AppSettings()
        settings.deepseekAPIKeyConfigured = true

        let source = await service.check(settings: settings, provider: .deepseek)
        let diagnostic = source.connectionDiagnostic()

        XCTAssertEqual(source.status, .connected)
        XCTAssertEqual(source.statusMessage, "API key saved in Keychain")
        XCTAssertEqual(diagnostic.nextAction, .refreshWhenStale)
    }

    func testDeepSeekBalanceParserUsesToppedUpBalanceAndCurrency() throws {
        let data = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "11.50",
              "granted_balance": "1.25",
              "topped_up_balance": "10.25"
            }
          ]
        }
        """.data(using: .utf8)!

        let balance = try DeepSeekBalanceParser().parse(data)

        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.totalBalance, Decimal(string: "11.50"))
        XCTAssertEqual(balance.grantedBalance, Decimal(string: "1.25"))
        XCTAssertEqual(balance.toppedUpBalance, Decimal(string: "10.25"))
        XCTAssertEqual(DeepSeekBalanceFormatter.display(balance), "$10.25")
    }

    func testDeepSeekBalanceParserKeepsUnavailableZeroBalance() throws {
        let data = """
        {"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0.00","granted_balance":"0","topped_up_balance":"0.00"}]}
        """.data(using: .utf8)!

        let balance = try DeepSeekBalanceParser().parse(data)

        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.toppedUpBalance, Decimal(0))
        XCTAssertEqual(DeepSeekBalanceFormatter.display(balance), "$0.00")
    }

    func testDeepSeekBalanceFormatterKeepsNativeNonUSDCurrency() {
        let balance = ProviderBalance(currency: "cny", toppedUpBalance: Decimal(string: "42.8")!)

        XCTAssertEqual(DeepSeekBalanceFormatter.display(balance), "CNY 42.80")
    }

    func testDeepSeekBalanceAdapterUsesKeychainAPIAndStaleLastSuccess() async throws {
        let keychain = KeychainService(service: "com.tokenpilot.tests.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
        try keychain.saveSecret("sk-test-secret", account: "deepseek.apiKey")
        let firstPayload = """
        {"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"8.00","granted_balance":"0","topped_up_balance":"8.00"}]}
        """.data(using: .utf8)!
        let adapter = DeepSeekBalanceAdapter(httpClient: StubDeepSeekHTTPClient(responses: [(firstPayload, 200), (Data(), 500)]), keychain: keychain)

        let first = await adapter.snapshot(settings: AppSettings(deepseekAPIKeyConfigured: true))
        XCTAssertEqual(first.balance?.toppedUpBalance, Decimal(8))
        XCTAssertEqual(first.model, "$8.00")
        XCTAssertEqual(first.confidence, .high)
        XCTAssertFalse(first.isStale)

        let staleAdapter = adapter
        let stale = await staleAdapter.snapshot(settings: AppSettings(deepseekAPIKeyConfigured: true))
        XCTAssertEqual(stale.balance?.toppedUpBalance, Decimal(8))
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.confidence, .medium)
    }

    func testDeepSeekManualFallbackDoesNotEmitLegacyLowBalanceAlert() async {
        var settings = AppSettings()
        settings.deepSeekBalance.manualFallbackEnabled = true
        settings.deepSeekBalance.manualBalanceText = "4.99"
        settings.deepSeekBalance.manualCurrency = "USD"
        settings.deepSeekBalance.lowBalanceThreshold = 5

        let snapshot = await DeepSeekBalanceAdapter(
            httpClient: StubDeepSeekHTTPClient(data: Data(), statusCode: 500),
            keychain: KeychainService(service: "com.tokenpilot.tests.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
        ).snapshot(settings: settings)

        XCTAssertEqual(snapshot.balance?.toppedUpBalance, Decimal(string: "4.99"))
        XCTAssertEqual(snapshot.model, "$4.99")
        XCTAssertEqual(snapshot.confidence, .manual)

        let events = NotificationRuleService(store: AlertDeduplicationStore(defaults: UserDefaults(suiteName: "deepseek-alert-\(UUID().uuidString)")!))
            .evaluate(snapshots: [snapshot], settings: settings)
        XCTAssertTrue(events.isEmpty)
    }

    func testDeepSeekLowBalanceAlertDedupesWithinCycleAndResetsNextCycle() {
        let defaults = UserDefaults(suiteName: "deepseek-alert-cycle-\(UUID().uuidString)")!
        let service = NotificationRuleService(store: AlertDeduplicationStore(defaults: defaults))
        var settings = AppSettings()
        settings.deepSeekBalance.lowBalanceThreshold = 5
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let tomorrow = today.addingTimeInterval(86_400)
        let todaySnapshot = ProviderSnapshot(
            provider: .deepseek,
            confidence: .high,
            dataSource: .officialTelemetry,
            balance: ProviderBalance(currency: "USD", toppedUpBalance: Decimal(1), capturedAt: today)
        )
        let tomorrowSnapshot = ProviderSnapshot(
            provider: .deepseek,
            confidence: .high,
            dataSource: .officialTelemetry,
            balance: ProviderBalance(currency: "USD", toppedUpBalance: Decimal(1), capturedAt: tomorrow)
        )

        XCTAssertEqual(service.evaluate(snapshots: [todaySnapshot], settings: settings).count, 1)
        XCTAssertEqual(service.evaluate(snapshots: [todaySnapshot], settings: settings).count, 0)
        XCTAssertEqual(service.evaluate(snapshots: [tomorrowSnapshot], settings: settings).count, 1)
        XCTAssertEqual(service.evaluate(snapshots: [tomorrowSnapshot], settings: settings).count, 0)
    }

    func testUsageStoreOnlyRefreshesEnabledProviders() async {
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        XCTAssertTrue(settings.setProviderEnabled(.claude, isEnabled: false))
        XCTAssertTrue(settings.setProviderEnabled(.gemini, isEnabled: false))

        let store = UsageStore(adapters: [
            FixedProviderAdapter(snapshot: ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 92))),
            FixedProviderAdapter(snapshot: ProviderSnapshot(provider: .codex, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 36))),
            FixedProviderAdapter(snapshot: ProviderSnapshot(provider: .gemini, dailyRequestsUsed: 4, dailyRequestsLimit: 100))
        ])

        let result = await store.refresh(settings: settings)

        XCTAssertEqual(result.snapshots.map(\.provider), [.codex])
    }

    func testUsageHistoryStoreDoesNotDoubleCountClaudeStatuslineDailySnapshots() {
        let suite = "TokenPilotUsageHistoryStatuslineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageHistoryStore(defaults: defaults, key: "usage-statusline-test")
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let firstDate = startOfToday.addingTimeInterval(10)
        let secondDate = startOfToday.addingTimeInterval(20)
        let first = UsageEvent(provider: .claude, model: "claude-sonnet-4", timestamp: firstDate, inputTokens: 60, outputTokens: 40, source: "claude-statusline", dataSource: .officialStatusline)
        let second = UsageEvent(provider: .claude, model: "claude-sonnet-4", timestamp: secondDate, inputTokens: 60, outputTokens: 40, source: "claude-statusline", dataSource: .officialStatusline)

        _ = store.record(snapshots: [ProviderSnapshot(provider: .claude, updatedAt: firstDate, todayTokens: 100, dataSource: .officialStatusline, model: "claude-sonnet-4", events: [first])], enabledProviders: [.claude])
        _ = store.record(snapshots: [ProviderSnapshot(provider: .claude, updatedAt: secondDate, todayTokens: 100, dataSource: .officialStatusline, model: "claude-sonnet-4", events: [second])], enabledProviders: [.claude])

        let historySnapshots = store.snapshotsForHistory(
            currentSnapshots: [ProviderSnapshot(provider: .claude, dataSource: .officialStatusline)],
            events: store.loadEvents(),
            enabledProviders: [.claude],
            referenceDate: secondDate
        )
        let result = AggregationService().aggregate(snapshots: historySnapshots, period: .today)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.metrics.totalTokens, 100)
    }
    func testUsageHistoryStoreDoesNotDoubleCountAntigravityStatuslineDailySnapshots() {
        let suite = "TokenPilotUsageHistoryAntigravityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageHistoryStore(defaults: defaults, key: "usage-antigravity-statusline-test")
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let firstDate = startOfToday.addingTimeInterval(10)
        let secondDate = startOfToday.addingTimeInterval(20)
        let first = UsageEvent(provider: .gemini, model: "gemini-3.5-pro", timestamp: firstDate, inputTokens: 60, outputTokens: 40, source: "antigravity-statusline", dataSource: .officialStatusline)
        let second = UsageEvent(provider: .gemini, model: "gemini-3.5-pro", timestamp: secondDate, inputTokens: 70, outputTokens: 50, source: "antigravity-statusline", dataSource: .officialStatusline)

        _ = store.record(snapshots: [ProviderSnapshot(provider: .gemini, updatedAt: firstDate, todayTokens: 100, dataSource: .officialStatusline, model: "gemini-3.5-pro", events: [first])], enabledProviders: [.gemini])
        _ = store.record(snapshots: [ProviderSnapshot(provider: .gemini, updatedAt: secondDate, todayTokens: 120, dataSource: .officialStatusline, model: "gemini-3.5-pro", events: [second])], enabledProviders: [.gemini])

        let historySnapshots = store.snapshotsForHistory(
            currentSnapshots: [ProviderSnapshot(provider: .gemini, dataSource: .officialStatusline)],
            events: store.loadEvents(),
            enabledProviders: [.gemini],
            referenceDate: secondDate
        )
        let result = AggregationService().aggregate(snapshots: historySnapshots, period: .today)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.metrics.totalTokens, 120)
    }

    func testUsageHistoryStorePrunesPersistedEventsWhenRefreshHasNoIncomingEvents() throws {
        let suite = "TokenPilotUsageHistoryEmptyRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "usage-empty-refresh-test"
        let store = UsageHistoryStore(defaults: defaults, key: key, maxAgeDays: 1)
        let now = Date()
        let current = UsageEvent(provider: .claude, timestamp: now.addingTimeInterval(-60), inputTokens: 100, source: "test")
        let expired = UsageEvent(provider: .claude, timestamp: now.addingTimeInterval(-3 * 24 * 60 * 60), inputTokens: 999, source: "test")
        defaults.set(try JSONEncoder().encode([expired, current]), forKey: key)

        _ = store.record(snapshots: [], enabledProviders: [.claude])

        XCTAssertEqual(store.loadEvents().map(\.totalTokens), [100])
    }

    func testLimitHistoryStorePrunesPersistedSamplesWhenRefreshHasNoIncomingSamples() throws {
        let suite = "TokenPilotLimitHistoryEmptyRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "limit-empty-refresh-test"
        let store = LimitHistoryStore(defaults: defaults, key: key, maxAgeDays: 1)
        let now = Date()
        let current = ProviderLimitSample(provider: .claude, timestamp: now.addingTimeInterval(-60), window: .fiveHour, usedPercent: 30, remainingPercent: 70, source: "test")
        let expired = ProviderLimitSample(provider: .claude, timestamp: now.addingTimeInterval(-3 * 24 * 60 * 60), window: .fiveHour, usedPercent: 90, remainingPercent: 10, source: "test")
        defaults.set(try JSONEncoder().encode([expired, current]), forKey: key)

        _ = store.record(snapshots: [ProviderSnapshot](), enabledProviders: [.claude], referenceDate: now)

        XCTAssertEqual(store.loadSamples().map(\.usedPercent), [30])
    }

    func testRefreshPolicyRequestsRefreshForUsageRelevantSettings() {
        var previous = AppSettings()
        var next = previous
        next.codexManual.fiveHourUsagePercentage = 74

        XCTAssertTrue(TokenPilotRefreshPolicy.usageRefreshNeeded(from: previous, to: next))

        previous = AppSettings()
        next = previous
        XCTAssertTrue(next.setProviderEnabled(.gemini, isEnabled: false))

        XCTAssertTrue(TokenPilotRefreshPolicy.usageRefreshNeeded(from: previous, to: next))

        previous = AppSettings()
        next = previous
        next.deepseekAPIKeyConfigured = true
        XCTAssertTrue(TokenPilotRefreshPolicy.usageRefreshNeeded(from: previous, to: next))

        previous = AppSettings()
        next = previous
        next.deepSeekBalance.manualBalanceText = "12.34"
        XCTAssertTrue(TokenPilotRefreshPolicy.usageRefreshNeeded(from: previous, to: next))
    }

    func testRefreshPolicyIgnoresDisplayOnlySettings() {
        let previous = AppSettings()
        var next = previous
        next.menuBarDisplayTarget = .codex
        next.localization.language = .ko
        next.telegram.chatID = "12345"

        XCTAssertFalse(TokenPilotRefreshPolicy.usageRefreshNeeded(from: previous, to: next))
    }

    func testMenuBarStatusServiceUsesSelectedProviderWhenEnabled() {
        var settings = AppSettings()
        settings.localization.language = .ko
        settings.menuBarDisplayTarget = .codex
        let snapshots = [
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 92), weekly: LimitWindow(kind: .weekly, usedPercent: 71), todayTokens: 12_000, confidence: .high, dataSource: .officialStatusline),
            ProviderSnapshot(provider: .codex, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 36), weekly: LimitWindow(kind: .weekly, usedPercent: 44), todayTokens: 4_800, confidence: .manual, dataSource: .manual),
            ProviderSnapshot(provider: .gemini, dailyRequestsUsed: 40, dailyRequestsLimit: 100, todayTokens: 9_500, confidence: .medium, dataSource: .localLog)
        ]

        let service = MenuBarStatusService()

        XCTAssertEqual(service.selectedSnapshot(from: snapshots, settings: settings)?.provider, .codex)
        XCTAssertEqual(service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE"), "5h 64% EST · 7d 56% EST")
    }

    func testMenuBarStatusServiceShowsSelectedDeepSeekBalance() {
        var settings = AppSettings()
        settings.menuBarDisplayTarget = .deepseek
        let snapshot = ProviderSnapshot(
            provider: .deepseek,
            confidence: .high,
            dataSource: .officialTelemetry,
            balance: ProviderBalance(currency: "USD", toppedUpBalance: Decimal(string: "12.34")!)
        )

        let title = MenuBarStatusService().title(snapshots: [snapshot], settings: settings, modeLabel: "LIVE")

        XCTAssertEqual(title, "DS $12.34")
    }

    func testMenuBarStatusServiceDoesNotPresentCodexLocalActivityAsQuota() {
        var settings = AppSettings()
        settings.localization.language = .en
        settings.menuBarDisplayTarget = .codex
        let snapshot = ProviderSnapshot(
            provider: .codex,
            todayTokens: 12_400,
            confidence: .medium,
            dataSource: .localLog
        )

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE"
        )

        XCTAssertEqual(title, "Co · Unavailable")
        XCTAssertFalse(title.contains("tok"))
        XCTAssertFalse(title.contains("12.4K"))
    }

    func testMenuBarStatusServiceKeepsExplicitCodexTargetWhenQuotaIsUnavailable() {
        var settings = AppSettings()
        settings.localization.language = .en
        settings.menuBarDisplayTarget = .codex
        let deepSeek = ProviderSnapshot(
            provider: .deepseek,
            confidence: .high,
            dataSource: .officialTelemetry,
            balance: ProviderBalance(currency: "USD", toppedUpBalance: Decimal(string: "0.85")!)
        )

        let title = MenuBarStatusService().title(
            snapshots: [deepSeek],
            settings: settings,
            modeLabel: "LIVE"
        )

        XCTAssertEqual(title, "Co · Unavailable")
    }

    func testMenuBarStatusServiceShowsRemainingPercentagesForFiveHourAndWeekly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var settings = AppSettings()
        settings.localization.language = .ko
        let service = MenuBarStatusService()
        let snapshots = [
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 88), weekly: LimitWindow(kind: .weekly, usedPercent: 62, resetAt: now.addingTimeInterval(18_720)), todayTokens: 12_000, confidence: .high, dataSource: .officialStatusline)
        ]

        let title = service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now)
        XCTAssertEqual(title, "5h 12% · 7d 38%·5h")
        XCTAssertFalse(title.contains("12K"))
    }

    func testMenuBarAccessibilityLocalizesCapacitySemanticsAcrossModesAndLanguages() {
        struct AccessibilityScenario {
            let name: String
            let snapshot: ProviderSnapshot
            let modeLabel: String
            let expectedFragments: [(TokenPilotLanguage, [String])]
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scenarios = [
            AccessibilityScenario(
                name: "official fresh percent",
                snapshot: ProviderSnapshot(
                    provider: .claude,
                    fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 82, resetAt: now.addingTimeInterval(3_600)),
                    confidence: .high,
                    dataSource: .officialStatusline
                ),
                modeLabel: "LIVE",
                expectedFragments: [
                    (.en, ["Capacity remaining 18%", "Reset 1h 0m", "Provider reported", "Supported", "Fresh", "Wait for reset", "Live only"]),
                    (.ko, ["수용량 18% 남음", "리셋 1시간 0분", "제공자 보고", "지원됨", "최신", "리셋 대기", "실시간만"]),
                    (.ja, ["容量残り 18%", "リセット 1時間 0分", "プロバイダ報告", "対応済み", "新鮮", "リセット待ち", "ライブのみ"]),
                    (.zhHans, ["容量剩余 18%", "重置 1小时 0分钟", "提供方报告", "受支持", "新鲜", "等待重置", "仅实时"])
                ]
            ),
            AccessibilityScenario(
                name: "official stale percent",
                snapshot: ProviderSnapshot(
                    provider: .claude,
                    fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 82, resetAt: now.addingTimeInterval(3_600)),
                    confidence: .high,
                    dataSource: .officialStatusline,
                    isStale: true
                ),
                modeLabel: "STALE",
                expectedFragments: [
                    (.en, ["Capacity remaining 18%", "Provider reported", "Supported", "Stale", "Refresh provider"]),
                    (.ko, ["수용량 18% 남음", "제공자 보고", "지원됨", "오래됨", "제공자 새로고침"]),
                    (.ja, ["容量残り 18%", "プロバイダ報告", "対応済み", "古い", "プロバイダを更新"]),
                    (.zhHans, ["容量剩余 18%", "提供方报告", "受支持", "过期", "刷新提供方"])
                ]
            ),
            AccessibilityScenario(
                name: "manual percent",
                snapshot: ProviderSnapshot(
                    provider: .codex,
                    fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 74),
                    confidence: .manual,
                    dataSource: .manual
                ),
                modeLabel: "MANUAL",
                expectedFragments: [
                    (.en, ["Capacity remaining 26%", "User entered", "Manual entry", "Fresh", "Enter manual value"]),
                    (.ko, ["수용량 26% 남음", "사용자 입력", "수동 입력", "최신", "수동 값 입력"]),
                    (.ja, ["容量残り 26%", "ユーザー入力", "手動入力", "新鮮", "手動値を入力"]),
                    (.zhHans, ["容量剩余 26%", "用户输入", "手动输入", "新鲜", "输入手动值"])
                ]
            ),
            AccessibilityScenario(
                name: "experimental percent",
                snapshot: ProviderSnapshot(
                    provider: .codex,
                    fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 42),
                    confidence: .high,
                    dataSource: .webUsage,
                    isExperimental: true
                ),
                modeLabel: "EXPERIMENTAL",
                expectedFragments: [
                    (.en, ["Capacity remaining 58%", "Provider reported", "Experimental connector", "Fresh", "Review experimental connector"]),
                    (.ko, ["수용량 58% 남음", "제공자 보고", "실험적 커넥터", "최신", "실험적 커넥터 검토"]),
                    (.ja, ["容量残り 58%", "プロバイダ報告", "実験的コネクタ", "新鮮", "実験的コネクタを確認"]),
                    (.zhHans, ["容量剩余 58%", "提供方报告", "实验性连接器", "新鲜", "检查实验性连接器"])
                ]
            ),
            AccessibilityScenario(
                name: "local activity",
                snapshot: ProviderSnapshot(
                    provider: .codex,
                    todayTokens: 4_800,
                    confidence: .low,
                    dataSource: .localLog
                ),
                modeLabel: "LOCAL",
                expectedFragments: [
                    (.en, ["Local derived", "Local metadata only", "Fresh", "Open Provider Diagnostics"]),
                    (.ko, ["로컬 파생", "로컬 메타데이터만", "최신", "제공자 진단 열기"]),
                    (.ja, ["ローカル派生", "ローカルメタデータのみ", "新鮮", "プロバイダ診断を開く"]),
                    (.zhHans, ["本地推导", "仅本地元数据", "新鲜", "打开提供方诊断"])
                ]
            ),
            AccessibilityScenario(
                name: "compatibility bridge",
                snapshot: ProviderSnapshot(
                    provider: .gemini,
                    confidence: .high,
                    dataSource: .officialStatusline,
                    contextWindowUsedPercent: 32
                ),
                modeLabel: "BRIDGE",
                expectedFragments: [
                    (.en, ["Capacity remaining 68%", "Provider reported", "Compatibility bridge", "Fresh", "Review source"]),
                    (.ko, ["수용량 68% 남음", "제공자 보고", "호환성 브리지", "최신", "소스 검토"]),
                    (.ja, ["容量残り 68%", "プロバイダ報告", "互換ブリッジ", "新鮮", "ソースを確認"]),
                    (.zhHans, ["容量剩余 68%", "提供方报告", "兼容桥接", "新鲜", "检查来源"])
                ]
            ),
            AccessibilityScenario(
                name: "official balance",
                snapshot: ProviderSnapshot(
                    provider: .deepseek,
                    confidence: .high,
                    dataSource: .officialTelemetry,
                    balance: ProviderBalance(currency: "USD", toppedUpBalance: Decimal(string: "0.85")!)
                ),
                modeLabel: "LIVE",
                expectedFragments: [
                    (.en, ["Provider reported", "Supported", "Fresh", "Review balance", "Live only"]),
                    (.ko, ["제공자 보고", "지원됨", "최신", "잔액 검토", "실시간만"]),
                    (.ja, ["プロバイダ報告", "対応済み", "新鮮", "残高を確認", "ライブのみ"]),
                    (.zhHans, ["提供方报告", "受支持", "新鲜", "检查余额", "仅实时"])
                ]
            )
        ]

        let rawFragments = [
            "waitForReset",
            "refreshProvider",
            "reviewSource",
            "reviewExperimentalConnector",
            "enterManualValue",
            "reviewBalance",
            "openProviderDiagnostics",
            "provider-reported",
            "local-derived",
            "user-entered",
            "providerReported",
            "localDerived",
            "userEntered",
            "LIVE"
        ]
        let nonEnglishFragments = [
            "remaining",
            "reset",
            "Provider reported",
            "Local derived",
            "User entered",
            "Supported",
            "Manual entry",
            "Compatibility bridge",
            "Experimental connector",
            "Fresh",
            "Stale",
            "Wait for reset",
            "Refresh provider",
            "Review balance",
            "Open Provider Diagnostics",
            "Review source",
            "Review experimental connector",
            "Enter manual value",
            "Live only",
            "Local metadata only"
        ]

        for scenario in scenarios {
            for (language, expectedFragments) in scenario.expectedFragments {
                var settings = AppSettings()
                settings.localization.language = language
                let label = MenuBarStatusService().accessibilityLabel(
                    snapshots: [scenario.snapshot],
                    settings: settings,
                    modeLabel: scenario.modeLabel,
                    now: now
                )

                for fragment in expectedFragments {
                    XCTAssertTrue(label.contains(fragment), "Missing \(fragment) for \(scenario.name) \(language): \(label)")
                }
                for raw in rawFragments {
                    XCTAssertFalse(label.contains(raw), "Raw fragment \(raw) leaked for \(scenario.name) \(language): \(label)")
                }
                if language != .en {
                    for fragment in nonEnglishFragments {
                        XCTAssertFalse(label.localizedCaseInsensitiveContains(fragment), "English fragment \(fragment) leaked for \(scenario.name) \(language): \(label)")
                    }
                }
            }
        }
    }

    func testMenuBarStatusServiceUsesExplicitTargetAndSameRankHysteresis() {
        var settings = AppSettings()
        let service = MenuBarStatusService()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = [
            ProviderSnapshot(provider: .codex, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 50), confidence: .manual, dataSource: .manual),
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 49), confidence: .manual, dataSource: .manual)
        ]

        XCTAssertTrue(service.accessibilityLabel(snapshots: first, settings: settings, modeLabel: "LIVE", now: now).contains("Codex"))

        let plusOne = [
            ProviderSnapshot(provider: .codex, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 50), confidence: .manual, dataSource: .manual),
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 51), confidence: .manual, dataSource: .manual)
        ]
        XCTAssertTrue(service.accessibilityLabel(snapshots: plusOne, settings: settings, modeLabel: "LIVE", now: now.addingTimeInterval(10)).contains("Codex"))
        XCTAssertTrue(service.accessibilityLabel(snapshots: plusOne, settings: settings, modeLabel: "LIVE", now: now.addingTimeInterval(61)).contains("Claude Code"))

        settings.menuBarDisplayTarget = .codex
        XCTAssertTrue(service.accessibilityLabel(snapshots: plusOne, settings: settings, modeLabel: "LIVE", now: now.addingTimeInterval(62)).contains("Codex"))
    }

    func testMenuBarStatusServiceFallsBackToHighestRiskWhenSelectedProviderDisabled() {
        var settings = AppSettings()
        settings.menuBarDisplayTarget = .gemini
        XCTAssertTrue(settings.setProviderEnabled(.gemini, isEnabled: false))
        let snapshots = [
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 82), todayTokens: 12_000, confidence: .high, dataSource: .officialStatusline),
            ProviderSnapshot(provider: .codex, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 36), todayTokens: 4_800, confidence: .manual, dataSource: .manual),
            ProviderSnapshot(provider: .gemini, dailyRequestsUsed: 98, dailyRequestsLimit: 100, todayTokens: 9_500, confidence: .medium, dataSource: .localLog)
        ]

        let service = MenuBarStatusService()

        XCTAssertEqual(service.selectedSnapshot(from: snapshots, settings: settings)?.provider, .claude)
    }

    func testAggregationHistoryDataPipelineMultiDay() {
        let calendar = Calendar.current
        let now = Date()

        // Build deterministic dates relative to now, all strictly in the past
        let todayStart = calendar.startOfDay(for: now)
        let todayDate = todayStart.addingTimeInterval(10) // 10s after midnight = always today, always past
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: todayStart)!.addingTimeInterval(14 * 3_600) // yesterday 14:00
        let sixDaysAgoDate = calendar.date(byAdding: .day, value: -6, to: todayStart)!.addingTimeInterval(9 * 3_600) // 6 days ago 09:00
        let tenDaysAgoDate = calendar.date(byAdding: .day, value: -10, to: todayStart)!.addingTimeInterval(11 * 3_600) // 10 days ago 11:00

        let todayEvent = UsageEvent(provider: .claude, timestamp: todayDate, inputTokens: 100, source: "test")
        let yesterdayEvent = UsageEvent(provider: .codex, timestamp: yesterdayDate, inputTokens: 200, source: "test")
        let sixDaysAgoEvent = UsageEvent(provider: .gemini, timestamp: sixDaysAgoDate, inputTokens: 300, source: "test")
        let tenDaysAgoEvent = UsageEvent(provider: .claude, timestamp: tenDaysAgoDate, inputTokens: 400, source: "test")

        let snapshots = [
            ProviderSnapshot(provider: .claude, events: [todayEvent, tenDaysAgoEvent]),
            ProviderSnapshot(provider: .codex, events: [yesterdayEvent]),
            ProviderSnapshot(provider: .gemini, events: [sixDaysAgoEvent])
        ]

        // MARK: - .today period
        let todayResult = AggregationService().aggregate(snapshots: snapshots, period: .today, now: now)
        XCTAssertEqual(todayResult.metrics.totalTokens, 100, ".today should only count today's event")
        XCTAssertEqual(todayResult.metrics.inputTokens, 100)
        XCTAssertEqual(todayResult.metrics.outputTokens, 0)

        // sevenDayBars always shows the actual last seven calendar days, regardless of selected summary period.
        XCTAssertEqual(todayResult.sevenDayBars.count, 7, "sevenDayBars must have exactly 7 entries")
        // Bars are reversed: [6d-ago, 5d-ago, ..., yesterday, today].
        XCTAssertEqual(todayResult.sevenDayBars[6].tokens, 100, "Today's bar should include today's tokens only")
        XCTAssertEqual(todayResult.sevenDayBars[5].tokens, 200, "Yesterday's bar should include yesterday's tokens only")
        XCTAssertEqual(todayResult.sevenDayBars[0].tokens, 300, "6-days-ago bar should include the oldest in-window day")
        XCTAssertFalse(
            todayResult.sevenDayBars.contains { $0.tokens == 400 },
            "Events older than the seven calendar-day chart window must not appear in sevenDayBars"
        )

        // providerShare should have 3 providers (all cases)
        XCTAssertEqual(todayResult.providerShare.count, Provider.allCases.count)
        if let claudeShare = todayResult.providerShare.first(where: { $0.provider == .claude }) {
            XCTAssertEqual(claudeShare.tokens, 100)
            XCTAssertEqual(claudeShare.percent, 100) // only claude in today filter
        }
        if let codexShare = todayResult.providerShare.first(where: { $0.provider == .codex }) {
            XCTAssertEqual(codexShare.tokens, 0)
        }

        // MARK: - .last7Days period
        let last7Result = AggregationService().aggregate(snapshots: snapshots, period: .last7Days, now: now)
        // Should include today (100), yesterday (200), 6 days ago (300) = 600
        // Should exclude 10 days ago (400)
        XCTAssertEqual(last7Result.metrics.totalTokens, 600, ".last7Days should count events from last 7 days (600)")
        XCTAssertEqual(last7Result.metrics.inputTokens, 600)
        XCTAssertEqual(last7Result.events.count, 3, "Should have 3 events in last 7 days")

        // sevenDayBars are identical regardless of period (always uses all events)
        XCTAssertEqual(last7Result.sevenDayBars.count, 7)
        XCTAssertEqual(last7Result.sevenDayBars, todayResult.sevenDayBars)

        // Provider share for last7Days
        if let claudeShare = last7Result.providerShare.first(where: { $0.provider == .claude }) {
            XCTAssertEqual(claudeShare.tokens, 100)
        }
        if let codexShare = last7Result.providerShare.first(where: { $0.provider == .codex }) {
            XCTAssertEqual(codexShare.tokens, 200)
        }
        if let geminiShare = last7Result.providerShare.first(where: { $0.provider == .gemini }) {
            XCTAssertEqual(geminiShare.tokens, 300)
        }

        // MARK: - .thisMonth period
        let monthResult = AggregationService().aggregate(snapshots: snapshots, period: .thisMonth, now: now)
        // Should include all events that actually fall in the current month. This keeps the
        // test deterministic at the beginning of a month, when 6/10-days-ago can be previous month.
        let monthEvents = [todayEvent, yesterdayEvent, sixDaysAgoEvent, tenDaysAgoEvent].filter {
            calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month)
        }
        let monthTotal = monthEvents.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(monthResult.metrics.totalTokens, monthTotal, ".thisMonth should count all events in the month")
        XCTAssertEqual(monthResult.metrics.inputTokens, monthTotal)
        XCTAssertEqual(monthResult.events.count, monthEvents.count, "Should have only events from the current month")

        // Provider share for thisMonth
        if let claudeShare = monthResult.providerShare.first(where: { $0.provider == .claude }) {
            let claudeMonthTotal = monthEvents.filter { $0.provider == .claude }.reduce(0) { $0 + $1.totalTokens }
            XCTAssertEqual(claudeShare.tokens, claudeMonthTotal)
        }

        // Verify period is correctly set on result
        XCTAssertEqual(todayResult.period, .today)
        XCTAssertEqual(last7Result.period, .last7Days)
        XCTAssertEqual(monthResult.period, .thisMonth)
    }
    func testCapacityEvidenceStoreAdmissionCardinalityAndWinnerSelection() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = try capacityTempDirectory()
        let store = CapacityEvidenceStore(directory: directory, clock: FixedCapacityClock(now: now))

        let futureBoundary = try decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: now.addingTimeInterval(60), used: 10, authority: .providerReported, stability: .supported)
        let futureRejected = try decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: now.addingTimeInterval(61), used: 11, authority: .providerReported, stability: .supported)
        let oldestBoundary = try decodedPercentObservation(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, durationMinutes: nil, observedAt: now.addingTimeInterval(-45 * 86_400), used: 12, authority: .providerReported, stability: .supported)
        let expiredRejected = try decodedPercentObservation(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, durationMinutes: nil, observedAt: now.addingTimeInterval(-45 * 86_400 - 1), used: 13, authority: .providerReported, stability: .supported)

        let initial = await store.record([futureBoundary, futureRejected, oldestBoundary, expiredRejected])
        XCTAssertEqual(initial.acceptedCount, 2)
        XCTAssertEqual(initial.quarantinedCount, 2)
        XCTAssertEqual(initial.snapshot?.quarantine.map(\.code).sorted(), ["futureObservation"])

        let cardinalityDirectory = try capacityTempDirectory()
        let cardinalityStore = CapacityEvidenceStore(directory: cardinalityDirectory, clock: FixedCapacityClock(now: now))
        let codexObservations = try (1...9).map { duration in
            try decodedPercentObservation(provider: .codex, providerWindowID: "rolling", kind: .rolling, durationMinutes: duration, observedAt: now.addingTimeInterval(TimeInterval(duration)), used: duration, authority: .providerReported, stability: .supported)
        }
        let cardinality = await cardinalityStore.record(codexObservations)
        XCTAssertEqual(cardinality.acceptedCount, 8)
        XCTAssertEqual(cardinality.quarantinedCount, 1)
        XCTAssertEqual(Set(cardinality.snapshot?.records.map { $0.seriesID.canonicalID } ?? []).count, 8)
        XCTAssertEqual(cardinality.snapshot?.quarantine.first?.code, "providerCardinalityExceeded")

        let winnerDirectory = try capacityTempDirectory()
        let winnerStore = CapacityEvidenceStore(directory: winnerDirectory, clock: FixedCapacityClock(now: now))
        let sameBucket = now.addingTimeInterval(-120)
        let lowerPriorityLater = try decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: sameBucket.addingTimeInterval(20), used: 30, authority: .localDerived, stability: .compatibilityBridge)
        let supportedEarlier = try decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: sameBucket, used: 70, authority: .providerReported, stability: .supported)
        let sameTimestampUser = try decodedPercentObservation(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, durationMinutes: nil, observedAt: sameBucket, used: 40, authority: .userEntered, stability: .manual)
        let sameTimestampSupported = try decodedPercentObservation(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, durationMinutes: nil, observedAt: sameBucket, used: 80, authority: .providerReported, stability: .supported)

        let winners = await winnerStore.record([supportedEarlier, lowerPriorityLater, sameTimestampUser, sameTimestampSupported])
        let bySeries = (winners.snapshot?.records ?? []).reduce(into: [String: Int]()) { result, record in
            result[record.seriesID.providerWindowID] = record.value.usedPercent
        }
        XCTAssertEqual(bySeries["five-hour"], 30, "Later observation must win before authority tie-breakers.")
        XCTAssertEqual(bySeries["seven-day"], 80, "Supported provider-reported evidence must win equal-timestamp ties.")
    }

    func testCapacityEvidenceStoreCompactsRawAndDailyClosingsWithoutSyntheticDays() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = try capacityTempDirectory()
        let store = CapacityEvidenceStore(directory: directory, clock: FixedCapacityClock(now: now))
        let observations = try [
            decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: now.addingTimeInterval(-2 * 86_400), used: 20, authority: .providerReported, stability: .supported),
            decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: now.addingTimeInterval(-8 * 86_400 + 60), used: 30, authority: .providerReported, stability: .supported),
            decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: now.addingTimeInterval(-8 * 86_400 + 3_600), used: 35, authority: .providerReported, stability: .supported),
            decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: now.addingTimeInterval(-10 * 86_400 + 600), used: 40, authority: .providerReported, stability: .supported)
        ]

        let result = await store.record(observations)
        let records = result.snapshot?.records ?? []
        XCTAssertEqual(records.filter { $0.retention == .raw }.count, 1)
        XCTAssertEqual(records.filter { $0.retention == .dailyClosing }.count, 2)
        XCTAssertEqual(records.filter { $0.retention == .dailyClosing }.compactMap { $0.value.usedPercent }.sorted(), [35, 40])
        XCTAssertLessThanOrEqual(Dictionary(grouping: records, by: { $0.seriesID.canonicalID }).values.map(\.count).max() ?? 0, CapacityEvidenceStore.maxRecordsPerSeries)
    }

    func testCapacityEvidenceStoreWritesCanonicalDecimalAndVerifiesChecksum() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = try capacityTempDirectory()
        let files = CapacityEvidenceFileSet(directory: directory)
        let store = CapacityEvidenceStore(files: files, clock: FixedCapacityClock(now: now))
        let balance = try decodedBalanceObservation(observedAt: now, amount: "1.2300", currency: "USD")

        let result = await store.record([balance])
        XCTAssertFalse(result.recoveryStatus.recoveryRequired)

        let raw = try String(decoding: Data(contentsOf: files.primary), as: UTF8.self)
        XCTAssertTrue(raw.contains(#""amount":"1.23""#))
        XCTAssertFalse(raw.contains("1.2300"))
        XCTAssertEqual(try CapacityAlertCondition.balanceBelow(threshold: Decimal(string: "5.5000")!, currency: "USD", rearmAtOrAboveThreshold: true).thresholdCanonical, "5.5")
        XCTAssertEqual(CapacityCanonical.thresholdCanonical(Decimal(string: "0.00000100")!), "0.000001")

        let loaded = await store.loadSnapshot()
        XCTAssertEqual(loaded.records.first?.value.moneyAmount, Decimal(string: "1.23"))
        XCTAssertFalse(loaded.recoveryStatus.recoveryRequired)
    }

    func testCapacityEvidenceRecoveryTableAndWriteBlockingPreservation() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = try decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: now, used: 42, authority: .providerReported, stability: .supported)
        let seedDirectory = try capacityTempDirectory()
        let seedFiles = CapacityEvidenceFileSet(directory: seedDirectory)
        let seedStore = CapacityEvidenceStore(files: seedFiles, clock: FixedCapacityClock(now: now))
        _ = await seedStore.record([observation])
        let validPrimary = try Data(contentsOf: seedFiles.primary)
        let validChecksum = try checksum(inEvidenceData: validPrimary)
        let validGeneration = try generation(inEvidenceData: validPrimary)

        try await assertEvidenceRecoveryCase(now: now, expectedSource: .primary) { files in
            try validPrimary.write(to: files.primary)
            try Data("not-json".utf8).write(to: files.txn)
            try Data("orphan".utf8).write(to: files.temp)
        } verify: { files in
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.temp.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: files.primary.path))
        }

        try await assertEvidenceRecoveryCase(now: now, expectedSource: .primary) { files in
            try validPrimary.write(to: files.primary)
            try validPrimary.write(to: files.temp)
            try evidenceTxn(baseGeneration: 0, targetGeneration: validGeneration, checksum: validChecksum, phase: "prepared").write(to: files.txn)
        }

        try await assertEvidenceRecoveryCase(now: now, expectedSource: .primary) { files in
            try validPrimary.write(to: files.primary)
            try Data("corrupt-temp".utf8).write(to: files.temp)
            try evidenceTxn(baseGeneration: 0, targetGeneration: validGeneration, checksum: validChecksum, phase: "prepared").write(to: files.txn)
        }

        try await assertEvidenceRecoveryCase(now: now, expectedSource: .temp) { files in
            try validPrimary.write(to: files.temp)
            try evidenceTxn(baseGeneration: 0, targetGeneration: validGeneration, checksum: validChecksum, phase: "prepared").write(to: files.txn)
        } verify: { files in
            XCTAssertTrue(FileManager.default.fileExists(atPath: files.primary.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.temp.path))
        }

        try await assertEvidenceRecoveryCase(now: now, expectedSource: .backup) { files in
            try validPrimary.write(to: files.backup)
            try evidenceTxn(baseGeneration: 0, targetGeneration: validGeneration, checksum: validChecksum, phase: "prepared").write(to: files.txn)
        }

        try await assertEvidenceRecoveryCase(now: now, expectedSource: .backup) { files in
            try Data("invalid-primary".utf8).write(to: files.primary)
            try validPrimary.write(to: files.backup)
            try validPrimary.write(to: files.temp)
            try evidenceTxn(baseGeneration: 1, targetGeneration: validGeneration, checksum: validChecksum, phase: "prepared").write(to: files.txn)
        }

        try await assertEvidenceRecoveryCase(now: now, expectedSource: .primary) { files in
            try validPrimary.write(to: files.primary)
            try evidenceTxn(baseGeneration: 0, targetGeneration: validGeneration, checksum: validChecksum, phase: "primaryReplaced").write(to: files.txn)
        }

        try await assertEvidenceRecoveryCase(now: now, expectedSource: .backup) { files in
            try Data("invalid-primary".utf8).write(to: files.primary)
            try validPrimary.write(to: files.backup)
        }

        let blockedDirectory = try capacityTempDirectory()
        let blockedFiles = CapacityEvidenceFileSet(directory: blockedDirectory)
        try Data("invalid-primary".utf8).write(to: blockedFiles.primary)
        try Data("invalid-backup".utf8).write(to: blockedFiles.backup)
        try Data("forensic-temp".utf8).write(to: blockedFiles.temp)
        try Data("forensic-txn".utf8).write(to: blockedFiles.txn)
        let before = try [blockedFiles.primary, blockedFiles.backup, blockedFiles.temp, blockedFiles.txn].map { try Data(contentsOf: $0) }
        let blockedStore = CapacityEvidenceStore(files: blockedFiles, clock: FixedCapacityClock(now: now))
        let blocked = await blockedStore.record([observation])
        let after = try [blockedFiles.primary, blockedFiles.backup, blockedFiles.temp, blockedFiles.txn].map { try Data(contentsOf: $0) }
        XCTAssertTrue(blocked.recoveryStatus.writeBlocked)
        XCTAssertEqual(before, after)
    }

    func testCapacityRuntimeRulesAndDeliveryStoresFailClosedOnCorruption() async throws {
        let directory = try capacityTempDirectory()
        let runtime = CapacityRuntimeStore(directory: directory)
        let absentRuntime = await runtime.load()
        XCTAssertTrue(absentRuntime.deliveryEnabled)
        _ = await runtime.save(CapacityRuntimeControl(assessmentEnabled: false))
        let savedRuntime = await runtime.load()
        XCTAssertFalse(savedRuntime.control.assessmentEnabled)

        let runtimeFile = directory.appendingPathComponent("capacity-runtime-v1.json")
        try Data("corrupt".utf8).write(to: runtimeFile)
        let corruptRuntime = await CapacityRuntimeStore(directory: directory).load()
        XCTAssertFalse(corruptRuntime.deliveryEnabled)
        XCTAssertTrue(corruptRuntime.recoveryStatus.writeBlocked)

        let rulesDirectory = try capacityTempDirectory()
        let rules = CapacityAlertRuleStore(directory: rulesDirectory)
        let percentRule = try capacityPercentRule()
        _ = await rules.save([percentRule])
        let savedRules = await rules.load()
        XCTAssertEqual(savedRules.rules.map(\.id), [percentRule.id])
        try Data("corrupt".utf8).write(to: rulesDirectory.appendingPathComponent("capacity-alert-rules-v1.json"))
        let corruptRules = await CapacityAlertRuleStore(directory: rulesDirectory).load()
        XCTAssertFalse(corruptRules.deliveryEnabled)

        let deliveryDirectory = try capacityTempDirectory()
        let delivery = CapacityAlertDeliveryStore(directory: deliveryDirectory)
        let key = CapacityAlertDeliveryKey(rule: percentRule, channel: .macOS)
        let state = try CapacityAlertDeliveryState(key: key, conditionState: .percent(activeCycleID: "cycle", lastUsed: 40, deliveredThresholds: []))
        _ = await delivery.save([key: state])
        let savedDelivery = await delivery.load()
        XCTAssertEqual(savedDelivery.states[key], state)
        try Data("corrupt".utf8).write(to: deliveryDirectory.appendingPathComponent("capacity-alert-delivery-v1.json"))
        let corruptDelivery = await CapacityAlertDeliveryStore(directory: deliveryDirectory).load()
        XCTAssertFalse(corruptDelivery.deliveryEnabled)
    }

    func testCapacityEvidenceStoreRawRetentionUsesExactUTCDayWindow() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let todayStart = try XCTUnwrap(calendar.date(from: DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2027, month: 1, day: 8)))
        let now = todayStart.addingTimeInterval(86_400 - 30)
        let rawLowerBound = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: todayStart))
        let rawUpperBound = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: todayStart))
        let directory = try capacityTempDirectory()
        let store = CapacityEvidenceStore(directory: directory, clock: FixedCapacityClock(now: now))

        var observations: [CapacityObservation] = []
        for offset in stride(from: 0, to: 7 * 86_400, by: 300) {
            observations.append(try decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: rawLowerBound.addingTimeInterval(TimeInterval(offset)), used: (offset / 300) % 101, authority: .providerReported, stability: .supported))
        }
        observations.append(try decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: rawLowerBound.addingTimeInterval(-1), used: 77, authority: .providerReported, stability: .supported))
        observations.append(try decodedPercentObservation(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, durationMinutes: nil, observedAt: rawUpperBound, used: 88, authority: .providerReported, stability: .supported))

        let result = await store.record(observations)
        let records = result.snapshot?.records ?? []
        let raw = records.filter { $0.retention == .raw }

        XCTAssertEqual(raw.count, 2_016)
        XCTAssertTrue(raw.contains { $0.observedAt == rawLowerBound })
        XCTAssertFalse(raw.contains { $0.observedAt == rawUpperBound })
        XCTAssertLessThanOrEqual(records.count, CapacityEvidenceStore.maxRecordsPerSeries)
    }

    func testCapacityLegacyMigrationPersistsMarkerNoOpsAndFailsClosedOnCorruptEvidenceBytes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = try capacityTempDirectory()
        let files = CapacityEvidenceFileSet(directory: directory)
        let store = CapacityEvidenceStore(files: files, clock: FixedCapacityClock(now: now))
        let sample = ProviderLimitSample(provider: .claude, timestamp: now, window: .fiveHour, usedPercent: 40, remainingPercent: 60, confidence: .high, source: UsageDataSource.officialStatusline.label)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyData = try encoder.encode([sample])

        let first = await store.migrateLegacyLimitSamples(from: legacyData)
        XCTAssertEqual(first.acceptedCount, 1)
        let firstGeneration = try generation(inEvidenceData: Data(contentsOf: files.primary))
        let marker = try JSONDecoder().decode(CapacityLegacyMigrationMarker.self, from: Data(contentsOf: files.legacyMigrationMarker))
        XCTAssertEqual(marker.sourceDigest, CapacityLegacyEvidenceConverter.sourceDigest(for: legacyData))
        XCTAssertEqual(marker.committedGeneration, firstGeneration)

        let second = await store.migrateLegacyLimitSamples(from: legacyData)
        XCTAssertEqual(second.acceptedCount, 0)
        XCTAssertEqual(try generation(inEvidenceData: Data(contentsOf: files.primary)), firstGeneration)

        let blockedDirectory = try capacityTempDirectory()
        let blockedFiles = CapacityEvidenceFileSet(directory: blockedDirectory)
        try Data("invalid-primary".utf8).write(to: blockedFiles.primary)
        try Data("invalid-backup".utf8).write(to: blockedFiles.backup)
        try Data("forensic-temp".utf8).write(to: blockedFiles.temp)
        try Data("forensic-txn".utf8).write(to: blockedFiles.txn)
        let before = try [blockedFiles.primary, blockedFiles.backup, blockedFiles.temp, blockedFiles.txn].map { try Data(contentsOf: $0) }

        let blocked = await CapacityEvidenceStore(files: blockedFiles, clock: FixedCapacityClock(now: now)).migrateLegacyLimitSamples(from: legacyData)
        let after = try [blockedFiles.primary, blockedFiles.backup, blockedFiles.temp, blockedFiles.txn].map { try Data(contentsOf: $0) }

        XCTAssertTrue(blocked.recoveryStatus.writeBlocked)
        XCTAssertEqual(before, after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockedFiles.legacyMigrationMarker.path))
    }

    func testLimitHistoryStoreFreezesLegacyWritesAfterCommittedMigrationMarker() throws {
        let suite = "TokenPilotLimitHistoryFrozenTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "limit-frozen-test"
        let directory = try capacityTempDirectory()
        let files = CapacityEvidenceFileSet(directory: directory)
        let seed = [ProviderLimitSample(provider: .claude, timestamp: Date(timeIntervalSince1970: 100), window: .fiveHour, usedPercent: 20, remainingPercent: 80, source: "seed")]
        let seedData = try JSONEncoder().encode(seed)
        defaults.set(seedData, forKey: key)
        let marker = CapacityLegacyMigrationMarker(sourceDigest: "abc123", committedGeneration: 1)
        try JSONEncoder().encode(marker).write(to: files.legacyMigrationMarker)

        let store = LimitHistoryStore(defaults: defaults, key: key, legacyWritePolicy: CapacityLegacyLimitHistoryWritePolicy(directory: directory))
        let snapshot = ProviderSnapshot(provider: .claude, updatedAt: Date(timeIntervalSince1970: 200), fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 90), confidence: .high, dataSource: .officialStatusline)
        let recorded = store.record(snapshots: [snapshot], enabledProviders: [.claude], referenceDate: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(recorded, seed)
        XCTAssertEqual(defaults.data(forKey: key), seedData)
    }

    func testLimitHistoryStoreBlocksCorruptLegacyBytesBeforeMarker() throws {
        let suite = "TokenPilotLimitHistoryCorruptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "limit-corrupt-test"
        let corrupt = Data("not-provider-limit-samples".utf8)
        defaults.set(corrupt, forKey: key)
        let directory = try capacityTempDirectory()
        let store = LimitHistoryStore(defaults: defaults, key: key, legacyWritePolicy: CapacityLegacyLimitHistoryWritePolicy(directory: directory))
        let snapshot = ProviderSnapshot(provider: .claude, updatedAt: Date(timeIntervalSince1970: 200), fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 90), confidence: .high, dataSource: .officialStatusline)

        let recorded = store.recordWithRecoveryStatus(snapshots: [snapshot], enabledProviders: [.claude], referenceDate: Date(timeIntervalSince1970: 200))
        let clearStatus = store.clearWithRecoveryStatus()

        XCTAssertTrue(recorded.recoveryStatus.writeBlocked)
        XCTAssertEqual(recorded.recoveryStatus, .recoveryRequired(writeBlocked: true, code: "legacyLimitHistoryRecoveryRequired"))
        XCTAssertEqual(clearStatus, recorded.recoveryStatus)
        XCTAssertEqual(recorded.samples, [])
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }

    func testCapacityTransactionalStoresSerializeCrossInstanceCommits() async throws {
        let directory = try capacityTempDirectory()
        let first = CapacityAlertRuleStore(directory: directory)
        let second = CapacityAlertRuleStore(directory: directory)
        let firstRule = try capacityPercentRule(conditionRevision: 1)
        let secondRule = try capacityPercentRule(conditionRevision: 2)

        async let firstSave = first.save([firstRule])
        async let secondSave = second.save([secondRule])
        let (firstResult, secondResult) = await (firstSave, secondSave)
        let loaded = await CapacityAlertRuleStore(directory: directory).load()

        XCTAssertFalse(firstResult.recoveryStatus.writeBlocked)
        XCTAssertFalse(secondResult.recoveryStatus.writeBlocked)
        XCTAssertFalse(loaded.recoveryStatus.writeBlocked)
        XCTAssertEqual(loaded.rules.count, 1)
        XCTAssertTrue(loaded.rules.first.map { [1, 2].contains($0.conditionRevision) } ?? false)
    }

    func testCapacityAlertTransitionEnginePercentSeedingCrossingRevisionChannelAndRetry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = CapacityAlertTransitionEngine()
        let rule = try capacityPercentRule(conditionRevision: 1, routing: .init(macOS: true, telegram: true, discord: false))
        let channels = CapacityAlertChannelSettings(globalEnabled: true, macOSEnabled: true, telegramEnabled: true, discordEnabled: true, telegramCredentialPresent: true, discordCredentialPresent: true)

        let seeded = engine.evaluate(rules: [rule], assessments: [try percentAssessment(used: 40, resetAt: now.addingTimeInterval(3_600), now: now)], previousStates: [:], channels: channels, now: now)
        XCTAssertTrue(seeded.attempts.isEmpty)
        XCTAssertEqual(seeded.states.count, 2)

        let crossed = engine.evaluate(rules: [rule], assessments: [try percentAssessment(used: 80, resetAt: now.addingTimeInterval(3_600), now: now.addingTimeInterval(60))], previousStates: seeded.states, channels: channels, now: now.addingTimeInterval(60))
        XCTAssertEqual(crossed.attempts.compactMap(\.threshold), [.eighty, .eighty])
        XCTAssertEqual(Set(crossed.attempts.map(\.key.channel)), [.macOS, .telegram])

        let mac = crossed.attempts.first { $0.key.channel == .macOS }!
        let telegram = crossed.attempts.first { $0.key.channel == .telegram }!
        let afterOutcomes = engine.applyingDeliveryOutcomes([
            CapacityAlertDeliveryOutcome(attempt: mac, succeeded: true, completedAt: now.addingTimeInterval(61)),
            CapacityAlertDeliveryOutcome(attempt: telegram, succeeded: false, completedAt: now.addingTimeInterval(61))
        ], to: crossed.states)

        let tooSoon = engine.evaluate(rules: [rule], assessments: [try percentAssessment(used: 82, resetAt: now.addingTimeInterval(3_600), now: now.addingTimeInterval(120))], previousStates: afterOutcomes, channels: channels, now: now.addingTimeInterval(120))
        XCTAssertTrue(tooSoon.attempts.isEmpty)

        let retry = engine.evaluate(rules: [rule], assessments: [try percentAssessment(used: 82, resetAt: now.addingTimeInterval(3_600), now: now.addingTimeInterval(362))], previousStates: afterOutcomes, channels: channels, now: now.addingTimeInterval(362))
        XCTAssertEqual(retry.attempts.map(\.key.channel), [.telegram])
        XCTAssertEqual(retry.attempts.first?.threshold, .eighty)

        let revisionRule = try capacityPercentRule(conditionRevision: 2, routing: rule.routing)
        let revisionSeed = engine.evaluate(rules: [revisionRule], assessments: [try percentAssessment(used: 90, resetAt: now.addingTimeInterval(3_600), now: now.addingTimeInterval(420))], previousStates: afterOutcomes, channels: channels, now: now.addingTimeInterval(420))
        XCTAssertTrue(revisionSeed.attempts.isEmpty)
        XCTAssertTrue(revisionSeed.states.keys.contains { $0.conditionRevision == 2 })

        let sameCycleDrop = engine.evaluate(rules: [rule], assessments: [try percentAssessment(used: 20, resetAt: now.addingTimeInterval(3_600), now: now.addingTimeInterval(480))], previousStates: afterOutcomes, channels: channels, now: now.addingTimeInterval(480))
        XCTAssertTrue(sameCycleDrop.attempts.isEmpty)

        let newCycle = engine.evaluate(rules: [rule], assessments: [try percentAssessment(used: 10, resetAt: now.addingTimeInterval(8_000), now: now.addingTimeInterval(500))], previousStates: afterOutcomes, channels: channels, now: now.addingTimeInterval(500))
        XCTAssertEqual(Set(newCycle.attempts.compactMap(\.threshold)), [.reset])
    }

    func testCapacityAlertTransitionEngineBalanceStrictRearmCurrencyPendingAndRetry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = CapacityAlertTransitionEngine()
        let rule = try capacityBalanceRule(threshold: Decimal(5), currency: "USD", routing: .init(macOS: true, telegram: true, discord: false))
        let channels = CapacityAlertChannelSettings(globalEnabled: true, macOSEnabled: true, telegramEnabled: true, telegramCredentialPresent: true)

        let firstBelow = engine.evaluate(rules: [rule], assessments: [try balanceAssessment(amount: "4.00", currency: "USD", now: now)], previousStates: [:], channels: channels, now: now)
        XCTAssertTrue(firstBelow.attempts.isEmpty)

        let equalThreshold = engine.evaluate(rules: [rule], assessments: [try balanceAssessment(amount: "5.00", currency: "USD", now: now.addingTimeInterval(60))], previousStates: firstBelow.states, channels: channels, now: now.addingTimeInterval(60))
        XCTAssertTrue(equalThreshold.attempts.isEmpty)

        let crossing = engine.evaluate(rules: [rule], assessments: [try balanceAssessment(amount: "4.99", currency: "USD", now: now.addingTimeInterval(120))], previousStates: equalThreshold.states, channels: channels, now: now.addingTimeInterval(120))
        XCTAssertEqual(Set(crossing.attempts.map(\.key.channel)), [.macOS, .telegram])
        XCTAssertTrue(crossing.attempts.allSatisfy { $0.id.contains("/USD/5/1/") })

        let failed = engine.applyingDeliveryOutcomes(crossing.attempts.map { CapacityAlertDeliveryOutcome(attempt: $0, succeeded: false, completedAt: now.addingTimeInterval(121)) }, to: crossing.states)
        let currencyMismatch = engine.evaluate(rules: [rule], assessments: [try balanceAssessment(amount: "4.00", currency: "EUR", now: now.addingTimeInterval(180))], previousStates: failed, channels: channels, now: now.addingTimeInterval(180))
        XCTAssertTrue(currencyMismatch.attempts.isEmpty)
        XCTAssertEqual(currencyMismatch.states, failed)

        let retry = engine.evaluate(rules: [rule], assessments: [try balanceAssessment(amount: "4.00", currency: "USD", now: now.addingTimeInterval(422))], previousStates: failed, channels: channels, now: now.addingTimeInterval(422))
        XCTAssertEqual(retry.attempts.count, 2)

        let pending = try CapacityAlertRule(provider: .deepseek, seriesID: try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency), authority: .providerReported, stability: .supported, enabled: true, routing: .init(macOS: true), condition: .pendingBalanceCurrencyBinding)
        let pendingResult = engine.evaluate(rules: [pending], assessments: [try balanceAssessment(amount: "1.00", currency: "USD", now: now)], previousStates: [:], channels: channels, now: now)
        XCTAssertTrue(pendingResult.attempts.isEmpty)
        XCTAssertTrue(pendingResult.states.isEmpty)
    }

    func testCapacityLegacyConversionIsIdempotentAndQuarantinesInvalidMappings() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = ProviderLimitSample(provider: .claude, timestamp: now, window: .fiveHour, usedPercent: 40, remainingPercent: 60, confidence: .high, source: UsageDataSource.officialStatusline.label)
        let invalidPair = ProviderLimitSample(provider: .claude, timestamp: now, window: .weekly, usedPercent: 40, remainingPercent: 61, source: UsageDataSource.officialStatusline.label)
        let unsupported = ProviderLimitSample(provider: .codex, timestamp: now, window: .weekly, usedPercent: 40, remainingPercent: 60, source: UsageDataSource.localLog.label)

        let converted = CapacityLegacyEvidenceConverter.convert(samples: [valid, invalidPair, unsupported], now: now)
        XCTAssertEqual(converted.observations.count, 1)
        XCTAssertEqual(converted.observations.first?.parserRevision, "legacyV1")
        XCTAssertEqual(converted.observations.first?.authority, .providerReported)
        XCTAssertEqual(converted.quarantine.map(\.code).sorted(), ["invalidLegacyMapping", "invalidUsedRemainingPair"])
        XCTAssertFalse(converted.quarantine.map(\.recordDigest).joined().contains(valid.source))

        let legacyBytes = try JSONEncoder().encode([valid])
        let marker = CapacityLegacyEvidenceConverter.marker(for: legacyBytes, committedGeneration: 7)
        XCTAssertFalse(CapacityLegacyEvidenceConverter.shouldMigrate(data: legacyBytes, existingMarker: marker))
        XCTAssertTrue(CapacityLegacyEvidenceConverter.shouldMigrate(data: Data("changed".utf8), existingMarker: marker))

        var settings = AppSettings()
        settings.alertRules = [AlertRule(provider: .claude, window: .fiveHour, fiftyEnabled: true, macOSEnabled: true, telegramEnabled: true)]
        let migration = try CapacityAlertLegacyMigrator.migrate(settings: settings, deepSeekBalance: nil)
        let repeatMigration = try CapacityAlertLegacyMigrator.migrate(settings: settings, deepSeekBalance: nil, existingMarker: migration.marker)
        XCTAssertTrue(migration.didMigrate)
        XCTAssertFalse(repeatMigration.didMigrate)
        XCTAssertTrue(migration.rules.contains { $0.provider == .deepseek && $0.isPendingBalanceBinding && !$0.enabled })
        XCTAssertTrue(migration.rules.contains { $0.provider == .claude && $0.condition.enabledPercentThresholds.contains(.fifty) })
    }

    func testCapacityAlertMigrationIgnoresUnsupportedLegacyProvidersAndIsIdempotent() throws {
        var settings = AppSettings()
        settings.alertRules = [
            AlertRule(provider: .claude, window: .fiveHour, fiftyEnabled: true, macOSEnabled: true, telegramEnabled: true),
            AlertRule(provider: .codex, window: .fiveHour, fiftyEnabled: true, macOSEnabled: true, telegramEnabled: true, discordEnabled: true),
            AlertRule(provider: .gemini, window: .dailyRequests, fiftyEnabled: true, macOSEnabled: true)
        ]

        let migration = try CapacityAlertLegacyMigrator.migrate(settings: settings, deepSeekBalance: nil)
        let repeatMigration = try CapacityAlertLegacyMigrator.migrate(settings: settings, deepSeekBalance: nil, existingMarker: migration.marker)

        XCTAssertTrue(migration.didMigrate)
        XCTAssertFalse(repeatMigration.didMigrate)
        XCTAssertFalse(migration.rules.contains { $0.provider == .codex || $0.provider == .gemini })
        XCTAssertTrue(migration.rules.contains { $0.provider == .deepseek && $0.isPendingBalanceBinding && !$0.enabled })
        let claudeRule = try XCTUnwrap(migration.rules.first { $0.provider == .claude })
        XCTAssertTrue(claudeRule.routing.macOS)
        XCTAssertTrue(claudeRule.routing.telegram)
        XCTAssertFalse(claudeRule.routing.discord)
        XCTAssertTrue(claudeRule.condition.enabledPercentThresholds.contains(.fifty))
    }

    func testCapacityAlertMigrationBindsDeepSeekOnlyAfterOfficialCurrencyAndRemovesPendingRule() async throws {
        let directory = try capacityTempDirectory()
        var settings = AppSettings()
        settings.alertRules = []
        settings.deepSeekBalance.lowBalanceThreshold = 7
        settings.telegramNotificationsEnabled = true

        let coordinator = CapacityAlertLegacyMigrationCoordinator(directory: directory)
        let pending = await coordinator.migrate(settings: settings, deepSeekBalance: nil)
        XCTAssertTrue(pending.didMigrate)
        XCTAssertTrue(pending.rules.contains { $0.provider == .deepseek && $0.isPendingBalanceBinding && !$0.enabled })

        let officialBalance = ProviderBalance(currency: "usd", toppedUpBalance: 10)
        let bound = await coordinator.migrate(settings: settings, deepSeekBalance: officialBalance)
        let loaded = await CapacityAlertRuleStore(directory: directory).load()

        XCTAssertTrue(bound.didMigrate)
        XCTAssertFalse(loaded.rules.contains { $0.provider == .deepseek && $0.isPendingBalanceBinding })
        let balanceRule = try XCTUnwrap(loaded.rules.first { $0.provider == .deepseek && $0.condition.kind == .balanceBelow })
        XCTAssertTrue(balanceRule.enabled)
        XCTAssertEqual(balanceRule.condition.balanceCurrency, "USD")
        XCTAssertEqual(balanceRule.condition.thresholdCanonical, "7")
        XCTAssertTrue(balanceRule.routing.macOS)
        XCTAssertTrue(balanceRule.routing.telegram)
        XCTAssertFalse(balanceRule.routing.discord)

        let repeatMigration = await coordinator.migrate(settings: settings, deepSeekBalance: officialBalance)
        let loadedAfterRepeat = await CapacityAlertRuleStore(directory: directory).load()
        XCTAssertFalse(repeatMigration.didMigrate)
        XCTAssertEqual(loadedAfterRepeat.rules, loaded.rules)
    }

    func testCapacityAlertVisibilityMarksCodexAndGeminiUnsupportedAndEngineSkipsCodexRule() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codexSeries = try CapacitySeriesID(provider: .codex, providerWindowID: "primary", kind: .rolling, unit: .percent, durationMinutes: 300)
        let codexRule = try CapacityAlertRule(
            provider: .codex,
            seriesID: codexSeries,
            authority: .providerReported,
            stability: .supported,
            enabled: true,
            routing: .init(macOS: true, telegram: true, discord: true),
            condition: .percentThresholds(reset: true, fifty: true, eighty: true, hundred: true)
        )
        let codexObservation = try CapacityObservation(
            seriesID: codexSeries,
            observedAt: now,
            resetAt: now.addingTimeInterval(3_600),
            value: try CapacityValue(usedPercent: 90),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        let codexAssessment = CapacityAssessmentService().assess(codexObservation, now: now)
        let transition = CapacityAlertTransitionEngine().evaluate(
            rules: [codexRule],
            assessments: [codexAssessment],
            previousStates: [:],
            channels: CapacityAlertChannelSettings(globalEnabled: true, macOSEnabled: true, telegramEnabled: true, discordEnabled: true, telegramCredentialPresent: true, discordCredentialPresent: true),
            now: now
        )

        XCTAssertTrue(transition.attempts.isEmpty)
        XCTAssertTrue(transition.states.isEmpty)

        let summary = CapacityAlertVisibilityBuilder().make(
            runtime: CapacityRuntimeControl(),
            runtimeStatus: .ready(source: .primary, generation: nil),
            rules: [codexRule],
            rulesStatus: .ready(source: .primary, generation: nil),
            deliveryStates: [:],
            deliveryStatus: .ready(source: .primary, generation: nil),
            channels: CapacityAlertChannelSettings(globalEnabled: true, macOSEnabled: true),
            includeUnsupportedNotices: true
        )
        let unsupportedRows = summary.rows.filter { $0.kind == .unsupportedNotice }
        XCTAssertEqual(Set(unsupportedRows.compactMap(\.provider)), [.codex, .gemini])
        XCTAssertTrue(unsupportedRows.allSatisfy { $0.readOnly && !$0.deliverable && $0.status == .unsupportedSource })
        XCTAssertFalse(summary.rows.contains { $0.provider == .codex && $0.deliverable })
    }

    func testCapacityAlertVisibilitySummaryUsesCapacityRulesDeliveryAndChannelPreferences() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rule = try capacityPercentRule(routing: .init(macOS: true, telegram: true, discord: false))
        let macKey = CapacityAlertDeliveryKey(rule: rule, channel: .macOS)
        let delivered = try CapacityAlertDeliveryState(
            key: macKey,
            status: .delivered,
            lastAttemptAt: now,
            lastSuccessAt: now,
            conditionState: .percent(activeCycleID: "cycle", lastUsed: 80, deliveredThresholds: [.eighty])
        )

        let summary = CapacityAlertVisibilityBuilder().make(
            runtime: CapacityRuntimeControl(),
            runtimeStatus: .ready(source: .primary, generation: nil),
            rules: [rule],
            rulesStatus: .ready(source: .primary, generation: nil),
            deliveryStates: [macKey: delivered],
            deliveryStatus: .ready(source: .primary, generation: nil),
            channels: CapacityAlertChannelSettings(globalEnabled: true, macOSEnabled: true, telegramEnabled: true, discordEnabled: true, telegramCredentialPresent: false, discordCredentialPresent: true),
            includeUnsupportedNotices: false
        )

        XCTAssertEqual(summary.status, .deliverable)
        XCTAssertEqual(summary.deliverableRuleCount, 1)
        XCTAssertEqual(summary.effectiveChannelCount, 1)
        let row = try XCTUnwrap(summary.rows.first { $0.kind == .capacityRule })
        XCTAssertEqual(row.percentThresholds, [.reset, .eighty, .hundred])
        XCTAssertFalse(row.percentThresholds.contains(.fifty))
        XCTAssertEqual(row.channels.first { $0.channel == .macOS }?.deliveryStatus, .delivered)
        XCTAssertEqual(row.channels.first { $0.channel == .macOS }?.effective, true)
        XCTAssertEqual(row.channels.first { $0.channel == .telegram }?.effective, false)
        XCTAssertEqual(row.channels.first { $0.channel == .discord }?.routed, false)

        let recovery = CapacityAlertVisibilityBuilder().make(
            runtime: CapacityRuntimeControl(),
            runtimeStatus: .recoveryRequired(writeBlocked: true, code: "runtimeRecoveryRequired"),
            rules: [rule],
            rulesStatus: .ready(source: .primary, generation: nil),
            deliveryStates: [:],
            deliveryStatus: .ready(source: .primary, generation: nil),
            channels: CapacityAlertChannelSettings(globalEnabled: true, macOSEnabled: true),
            includeUnsupportedNotices: false
        )
        XCTAssertEqual(recovery.status, .recoveryRequired)
        XCTAssertEqual(recovery.recoveryCodes, ["runtimeRecoveryRequired"])
        XCTAssertTrue(recovery.recoveryWriteBlocked)
    }

    func testCapacityAlertMigrationCoordinatorRetriesMarkerFailureWithoutDuplicateRulesOrDelivery() async throws {
        let directory = try capacityTempDirectory()
        let fileSystem = FailOnceCapacityFileSystem(failWriteOnceForLastPathComponent: "capacity-alert-migration-v1.json.temp")
        var settings = AppSettings()
        settings.alertRules = [AlertRule(provider: .claude, window: .fiveHour, fiftyEnabled: true, macOSEnabled: true)]
        let planned = try CapacityAlertLegacyMigrator.migrate(settings: settings, deepSeekBalance: nil)
        let migratedRuleIDs = Set(planned.marker.migratedRuleIDs)
        let migratedRule = try XCTUnwrap(planned.rules.first { $0.provider == .claude })
        let key = CapacityAlertDeliveryKey(rule: migratedRule, channel: .macOS)
        let delivered = try CapacityAlertDeliveryState(
            key: key,
            status: .delivered,
            lastAttemptAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSuccessAt: Date(timeIntervalSince1970: 1_800_000_000),
            conditionState: .percent(activeCycleID: "cycle", lastUsed: 50, deliveredThresholds: [.fifty])
        )
        let coordinator = CapacityAlertLegacyMigrationCoordinator(directory: directory, fileSystem: fileSystem)

        let first = await coordinator.migrate(settings: settings, deepSeekBalance: nil, initialDeliveryStates: [key: delivered])
        let rulesAfterFirst = await CapacityAlertRuleStore(directory: directory, fileSystem: fileSystem).load()
        let deliveryAfterFirst = await CapacityAlertDeliveryStore(directory: directory, fileSystem: fileSystem).load()

        XCTAssertTrue(first.recoveryStatus.writeBlocked)
        XCTAssertEqual(Set(rulesAfterFirst.rules.map(\.id)), migratedRuleIDs)
        XCTAssertEqual(deliveryAfterFirst.states[key], delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capacity-alert-migration-v1.json").path))

        let second = await coordinator.migrate(settings: settings, deepSeekBalance: nil, initialDeliveryStates: [key: delivered])
        let rulesAfterRetry = await CapacityAlertRuleStore(directory: directory, fileSystem: fileSystem).load()
        let deliveryAfterRetry = await CapacityAlertDeliveryStore(directory: directory, fileSystem: fileSystem).load()
        let committedMarker = try JSONDecoder().decode(CapacityAlertMigrationMarker.self, from: Data(contentsOf: directory.appendingPathComponent("capacity-alert-migration-v1.json")))

        XCTAssertFalse(second.recoveryStatus.writeBlocked)
        XCTAssertTrue(second.didMigrate)
        XCTAssertEqual(rulesAfterRetry.rules.count, rulesAfterFirst.rules.count)
        XCTAssertEqual(Set(rulesAfterRetry.rules.map(\.id)), migratedRuleIDs)
        XCTAssertEqual(deliveryAfterRetry.states[key], delivered)
        XCTAssertEqual(committedMarker.sourceSettingsDigest, planned.marker.sourceSettingsDigest)
        XCTAssertEqual(committedMarker.migratedRuleIDs, planned.marker.migratedRuleIDs)

        let third = await coordinator.migrate(settings: settings, deepSeekBalance: nil, initialDeliveryStates: [key: delivered])
        let rulesAfterNoOp = await CapacityAlertRuleStore(directory: directory, fileSystem: fileSystem).load()
        XCTAssertFalse(third.didMigrate)
        XCTAssertEqual(rulesAfterNoOp.rules.count, rulesAfterRetry.rules.count)
    }

    func testCapacityAlertMigrationCoordinatorFailsClosedOnCorruptMarkerWithoutDependentWrites() async throws {
        let directory = try capacityTempDirectory()
        try Data("corrupt-marker".utf8).write(to: directory.appendingPathComponent("capacity-alert-migration-v1.json"))
        var settings = AppSettings()
        settings.alertRules = [AlertRule(provider: .claude, window: .fiveHour, fiftyEnabled: true)]
        let result = await CapacityAlertLegacyMigrationCoordinator(directory: directory).migrate(settings: settings, deepSeekBalance: nil)

        XCTAssertTrue(result.recoveryStatus.writeBlocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capacity-alert-rules-v1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capacity-alert-delivery-v1.json").path))
    }

    private func capacityTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotCapacityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func decodedPercentObservation(provider: Provider, providerWindowID: String, kind: CapacitySeriesKind, durationMinutes: Int?, observedAt: Date, used: Int, authority: CapacityAuthority, stability: CapacityStability) throws -> CapacityObservation {
        let duration = durationMinutes.map { #","durationMinutes":\#($0)"# } ?? ""
        let json = """
        {
          "seriesID":{"provider":"\(provider.rawValue)","providerWindowID":"\(providerWindowID)","kind":"\(kind.rawValue)","unit":"percent"\(duration)},
          "observedAt":\(observedAt.timeIntervalSinceReferenceDate),
          "value":{"usedPercent":{"_0":\(used)}},
          "authority":"\(authority.rawValue)",
          "stability":"\(stability.rawValue)",
          "consent":"notRequired",
          "freshnessPolicy":{"maximumAge":\(45 * 86_400)},
          "comparability":"comparable",
          "parserRevision":"test"
        }
        """
        return try JSONDecoder().decode(CapacityObservation.self, from: Data(json.utf8))
    }

    private func decodedBalanceObservation(observedAt: Date, amount: String, currency: String) throws -> CapacityObservation {
        let series = try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency)
        return try CapacityObservation(
            seriesID: series,
            observedAt: observedAt,
            value: try CapacityValue(money: Decimal(string: amount)!, currency: currency),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: observedAt
        )
    }

    private func percentAssessment(used: Int, resetAt: Date, now: Date) throws -> CapacityAssessment {
        let series = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        let observation = try CapacityObservation(seriesID: series, observedAt: now, resetAt: resetAt, value: try CapacityValue(usedPercent: used), authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now)
        return CapacityAssessmentService().assess(observation, now: now)
    }

    private func balanceAssessment(amount: String, currency: String, now: Date) throws -> CapacityAssessment {
        let series = try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency)
        let observation = try CapacityObservation(seriesID: series, observedAt: now, value: try CapacityValue(money: Decimal(string: amount)!, currency: currency), authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now)
        return CapacityAssessmentService().assess(observation, now: now)
    }

    private func capacityPercentRule(conditionRevision: Int = 1, routing: CapacityAlertRouting = .init(macOS: true, telegram: false, discord: false)) throws -> CapacityAlertRule {
        try CapacityAlertRule(
            provider: .claude,
            seriesID: try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent),
            authority: .providerReported,
            stability: .supported,
            enabled: true,
            routing: routing,
            conditionRevision: conditionRevision,
            condition: .percentThresholds(reset: true, fifty: false, eighty: true, hundred: true)
        )
    }

    private func capacityBalanceRule(threshold: Decimal, currency: String, routing: CapacityAlertRouting) throws -> CapacityAlertRule {
        try CapacityAlertRule(
            provider: .deepseek,
            seriesID: try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency),
            authority: .providerReported,
            stability: .supported,
            enabled: true,
            routing: routing,
            condition: try .balanceBelow(threshold: threshold, currency: currency, rearmAtOrAboveThreshold: true)
        )
    }

    private func checksum(inEvidenceData data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["checksum"] as? String)
    }

    private func generation(inEvidenceData data: Data) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["generation"] as? Int)
    }

    private func evidenceTxn(baseGeneration: Int, targetGeneration: Int, checksum: String, phase: String) -> Data {
        Data(#"{"baseGeneration":\#(baseGeneration),"phase":"\#(phase)","targetChecksum":"\#(checksum)","targetGeneration":\#(targetGeneration)}"#.utf8)
    }

    private func assertEvidenceRecoveryCase(now: Date, expectedSource: CapacityPersistenceSource, setup: (CapacityEvidenceFileSet) throws -> Void, verify: (CapacityEvidenceFileSet) throws -> Void = { _ in }) async throws {
        let directory = try capacityTempDirectory()
        let files = CapacityEvidenceFileSet(directory: directory)
        try setup(files)
        let store = CapacityEvidenceStore(files: files, clock: FixedCapacityClock(now: now))
        let snapshot = await store.loadSnapshot()
        XCTAssertEqual(snapshot.recoveryStatus, .ready(source: expectedSource, generation: snapshot.generation))
        try verify(files)
    }

    func testTokenPilotRelativeTimestampFormatting() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // No recorded timestamp yet → no label.
        XCTAssertNil(TokenPilotRelativeTimestamp.format(from: nil, now: now))

        // A future timestamp (clock skew) is normalized to "just now".
        XCTAssertEqual(TokenPilotRelativeTimestamp.format(from: now.addingTimeInterval(30), now: now)?.key, "Updated just now")

        // Under a minute.
        let justNow = TokenPilotRelativeTimestamp.format(from: now.addingTimeInterval(-5), now: now)
        XCTAssertEqual(justNow?.key, "Updated just now")
        XCTAssertNil(justNow?.arg)

        // Minutes.
        let minutes = TokenPilotRelativeTimestamp.format(from: now.addingTimeInterval(-3 * 60), now: now)
        XCTAssertEqual(minutes?.key, "Updated %d min ago")
        XCTAssertEqual(minutes?.arg, 3)

        // Hours.
        let hours = TokenPilotRelativeTimestamp.format(from: now.addingTimeInterval(-2 * 3600), now: now)
        XCTAssertEqual(hours?.key, "Updated %d hr ago")
        XCTAssertEqual(hours?.arg, 2)

        // Days.
        let days = TokenPilotRelativeTimestamp.format(from: now.addingTimeInterval(-5 * 86400), now: now)
        XCTAssertEqual(days?.key, "Updated %d days ago")
        XCTAssertEqual(days?.arg, 5)
    }

    // MARK: - CapacityPaceService

    func testCapacityPaceProjectsExhaustionFromElapsedWindowShare() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        // 60% used over 3 elapsed hours of a 5h window -> 20%/hour -> remaining 40% -> 2h.
        let resetAt = now.addingTimeInterval(2 * 3600)
        let observation = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, durationMinutes: 300),
            observedAt: now,
            resetAt: resetAt,
            value: try CapacityValue(usedPercent: 60),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        let projection = try XCTUnwrap(CapacityPaceService().projection(observation: observation, now: now))
        XCTAssertEqual(projection.usedPercent, 60)
        XCTAssertEqual(projection.remainingPercent, 40)
        XCTAssertEqual(projection.percentPerHour, 20, accuracy: 0.001)
        XCTAssertEqual(projection.hoursUntilExhaustion, 2, accuracy: 0.01)
        XCTAssertEqual(projection.estimatedExhaustionAt.timeIntervalSince(now), 2 * 3600, accuracy: 10)
    }

    func testCapacityPaceReturnsNilForNonPercentOrMissingWindow() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let service = CapacityPaceService()
        let balance = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency),
            observedAt: now,
            value: try CapacityValue(money: 5, currency: "USD"),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        XCTAssertNil(service.projection(observation: balance, now: now))
        let noReset = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .kiro, providerWindowID: "context-percent", kind: .context, unit: .percent),
            observedAt: now,
            value: try CapacityValue(usedPercent: 40),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        XCTAssertNil(service.projection(observation: noReset, now: now))
    }

    func testCapacityPaceSkipsEmptyExhaustedAndTinyElapsedWindows() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let service = CapacityPaceService()
        let zero = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent),
            observedAt: now,
            resetAt: now.addingTimeInterval(5 * 3600),
            value: try CapacityValue(usedPercent: 0),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        XCTAssertNil(service.projection(observation: zero, now: now))
        let exhausted = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent),
            observedAt: now,
            resetAt: now.addingTimeInterval(5 * 3600),
            value: try CapacityValue(usedPercent: 100),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        XCTAssertNil(service.projection(observation: exhausted, now: now))
        let fresh = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent),
            observedAt: now,
            resetAt: now.addingTimeInterval(5 * 3600 - 60),
            value: try CapacityValue(usedPercent: 5),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        XCTAssertNil(service.projection(observation: fresh, now: now))
        let past = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent),
            observedAt: now,
            resetAt: now.addingTimeInterval(-3_600),
            value: try CapacityValue(usedPercent: 30),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        XCTAssertNil(service.projection(observation: past, now: now))
    }

    func testPacingZoneClassifiesBurnRatioAgainstSustainableRate() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let service = CapacityPaceService()
        let seriesID = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, durationMinutes: 300)

        func observation(usedPercent: Int, resetAt: Date) throws -> CapacityObservation {
            try CapacityObservation(
                seriesID: seriesID,
                observedAt: now,
                resetAt: resetAt,
                value: try CapacityValue(usedPercent: usedPercent),
                authority: .providerReported,
                stability: .supported,
                freshnessPolicy: .init(maximumAge: 900),
                comparability: .comparable,
                parserRevision: "test",
                now: now
            )
        }

        // 60% used over 3 elapsed hours of a 5h window -> 20%/hour burn, 2h left in window.
        // Sustainable rate for the remaining 40% over 2h is 20%/hour -> ratio 1.0 -> hot.
        let hot = try observation(usedPercent: 60, resetAt: now.addingTimeInterval(2 * 3600))
        let hotAssessment = try XCTUnwrap(service.pacingZone(observation: hot, now: now))
        XCTAssertEqual(hotAssessment.zone, .hot)
        XCTAssertEqual(hotAssessment.burnRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(hotAssessment.hoursUntilReset, 2, accuracy: 0.001)

        // 20% used over 3 elapsed hours of a 5h window -> 6.67%/hour burn, 2h left.
        // Sustainable rate for remaining 80% over 2h is 40%/hour -> ratio 0.167 -> safe.
        let safe = try observation(usedPercent: 20, resetAt: now.addingTimeInterval(2 * 3600))
        let safeAssessment = try XCTUnwrap(service.pacingZone(observation: safe, now: now))
        XCTAssertEqual(safeAssessment.zone, .safe)
        XCTAssertLessThan(safeAssessment.burnRatio, 0.5)

        // 50% used over 3 elapsed hours of a 5h window -> 16.67%/hour burn, 2h left.
        // Sustainable rate for remaining 50% over 2h is 25%/hour -> ratio 0.667 -> steady.
        let steady = try observation(usedPercent: 50, resetAt: now.addingTimeInterval(2 * 3600))
        let steadyAssessment = try XCTUnwrap(service.pacingZone(observation: steady, now: now))
        XCTAssertEqual(steadyAssessment.zone, .steady)
        XCTAssertEqual(steadyAssessment.burnRatio, 16.6667 / 25.0, accuracy: 0.001)
    }

    func testPacingZoneReturnsNilWhenProjectionUnavailable() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let service = CapacityPaceService()
        // Non-percent observation: no projection -> no zone.
        let balance = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency),
            observedAt: now,
            value: try CapacityValue(money: 5, currency: "USD"),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        XCTAssertNil(service.pacingZone(observation: balance, now: now))
        // Reset in the past: hoursUntilReset <= 0 -> nil.
        let pastReset = try CapacityObservation(
            seriesID: try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, durationMinutes: 300),
            observedAt: now,
            resetAt: now.addingTimeInterval(-3_600),
            value: try CapacityValue(usedPercent: 30),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        XCTAssertNil(service.pacingZone(observation: pastReset, now: now))
    }

    // MARK: - BudgetGuardrailService

    func testBudgetGuardrailDailyProgressComputesPercentAndThreshold() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let service = BudgetGuardrailService()
        let today = now
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let settings = BudgetGuardrailSettings(dailyTokens: 10_000, alertThresholdPercent: 80)

        let events = [
            UsageEvent(provider: .opencode, timestamp: today, inputTokens: 6_000, outputTokens: 2_000, source: "budget-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: today.addingTimeInterval(60), inputTokens: 1_000, outputTokens: 0, source: "budget-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: yesterday, inputTokens: 9_000, outputTokens: 0, source: "budget-test", dataSource: .localLog),
        ]

        let progress = service.dailyProgress(events: events, settings: settings, now: now, calendar: calendar)
        XCTAssertEqual(progress.tokens, 9_000)
        XCTAssertEqual(progress.budgetTokens, 10_000)
        XCTAssertEqual(progress.percent, 90)
        XCTAssertTrue(progress.crossedThreshold)
    }

    // MARK: - BudgetPaceService

    func testBudgetPaceProjectsExhaustionFromElapsedDayShare() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        // 6,000 of a 12,000 budget over 12 elapsed hours -> 500/hour -> remaining 6,000 -> 12h.
        let progress = BudgetGuardrailProgress(tokens: 6_000, budgetTokens: 12_000, percent: 50, crossedThreshold: false)

        let projection = try XCTUnwrap(BudgetPaceService().projection(progress: progress, now: now, calendar: calendar))
        XCTAssertEqual(projection.usedTokens, 6_000)
        XCTAssertEqual(projection.budgetTokens, 12_000)
        XCTAssertEqual(projection.tokensPerHour, 500, accuracy: 0.001)
        XCTAssertEqual(projection.hoursUntilExhaustion, 12, accuracy: 0.01)
        XCTAssertEqual(projection.estimatedExhaustionAt.timeIntervalSince(now), 12 * 3600, accuracy: 10)
    }

    func testBudgetPaceReturnsNilForDisabledEmptyExhaustedAndTinyElapsed() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let service = BudgetPaceService()

        let disabled = BudgetGuardrailProgress(tokens: 100, budgetTokens: 0, percent: 0, crossedThreshold: false)
        XCTAssertNil(service.projection(progress: disabled, now: now, calendar: calendar))

        let empty = BudgetGuardrailProgress(tokens: 0, budgetTokens: 10_000, percent: 0, crossedThreshold: false)
        XCTAssertNil(service.projection(progress: empty, now: now, calendar: calendar))

        let exhausted = BudgetGuardrailProgress(tokens: 10_000, budgetTokens: 10_000, percent: 100, crossedThreshold: true)
        XCTAssertNil(service.projection(progress: exhausted, now: now, calendar: calendar))

        // Just after midnight: less than 30 minutes elapsed -> no stable rate yet.
        let early = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 0, minute: 10))!
        let earlyProgress = BudgetGuardrailProgress(tokens: 500, budgetTokens: 10_000, percent: 5, crossedThreshold: false)
        XCTAssertNil(service.projection(progress: earlyProgress, now: early, calendar: calendar))
    }

    // MARK: - ActivityMilestoneService

    func testActivityMilestonesReportsAchievedThresholds() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }

        // 5 days of activity, 60K tokens/day (2 x 30K events), 2 requests/day -> 300K tokens, 10 requests, 5 active days, 5-day streak.
        let events = (0..<5).flatMap { offset in
            (0..<2).map { _ in
                UsageEvent(provider: .opencode, timestamp: day(-offset), inputTokens: 30_000, outputTokens: 0, requestCount: 1, source: "milestone-test", dataSource: .localLog)
            }
        }

        let milestones = ActivityMilestoneService().achievedMilestones(events: events, now: now, calendar: calendar)
        let tokens = milestones.filter { $0.dimension == .lifetimeTokens }.map(\.threshold)
        XCTAssertTrue(tokens.contains(100_000))
        XCTAssertTrue(tokens.contains(500_000) == false)
        let days = milestones.filter { $0.dimension == .activeDays }.map(\.threshold)
        XCTAssertTrue(days.contains(10) == false)
        XCTAssertTrue(days.contains(5) == false)
        let requests = milestones.filter { $0.dimension == .totalRequests }.map(\.threshold)
        XCTAssertTrue(requests.contains(100) == false)
        XCTAssertEqual(requests.count, 0)
        let streaks = milestones.filter { $0.dimension == .longestStreak }.map(\.threshold)
        XCTAssertTrue(streaks.contains(3))
        XCTAssertTrue(streaks.contains(7) == false)
    }

    func testActivityMilestonesEmptyHistory() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let milestones = ActivityMilestoneService().achievedMilestones(events: [], now: now, calendar: calendar)
        XCTAssertTrue(milestones.isEmpty)
    }

    // MARK: - MilestoneNotificationService

    func testMilestoneNotificationReportsNewlyAchievedOnce() throws {
        let suite = "milestone-notification-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilestoneNotificationStore(defaults: defaults)
        let service = MilestoneNotificationService(store: store)

        let milestones = [
            ActivityMilestone(dimension: .lifetimeTokens, threshold: 100_000),
            ActivityMilestone(dimension: .longestStreak, threshold: 7),
        ]

        let first = service.newlyAchieved(milestones: milestones)
        XCTAssertEqual(first.count, 2)

        service.markNotified(first)

        let second = service.newlyAchieved(milestones: milestones)
        XCTAssertTrue(second.isEmpty, "achieved milestones should alert only once")

        // A newly achieved threshold still reports.
        let extended = milestones + [ActivityMilestone(dimension: .activeDays, threshold: 30)]
        let third = service.newlyAchieved(milestones: extended)
        XCTAssertEqual(third.map(\.id), ["activeDays.30"])
    }

    func testMilestoneNotificationStoreRoundtrip() {
        let suite = "milestone-notification-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilestoneNotificationStore(defaults: defaults)

        XCTAssertTrue(store.notifiedIDs().isEmpty)
        store.markNotified(["lifetimeTokens.100000"])
        XCTAssertEqual(store.notifiedIDs(), ["lifetimeTokens.100000"])
    }

    func testBudgetGuardrailDisabledWindowReturnsZeroProgress() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let service = BudgetGuardrailService()
        let settings = BudgetGuardrailSettings(dailyTokens: 0, weeklyTokens: 0, monthlyTokens: 0)

        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 5_000, outputTokens: 0, source: "budget-test", dataSource: .localLog)
        ]

        let daily = service.dailyProgress(events: events, settings: settings, now: now, calendar: calendar)
        XCTAssertEqual(daily.budgetTokens, 0)
        XCTAssertEqual(daily.percent, 0)
        XCTAssertFalse(daily.crossedThreshold)

        let weekly = service.weeklyProgress(events: events, settings: settings, now: now, calendar: calendar)
        XCTAssertEqual(weekly.budgetTokens, 0)
        XCTAssertEqual(weekly.percent, 0)

        let monthly = service.monthlyProgress(events: events, settings: settings, now: now, calendar: calendar)
        XCTAssertEqual(monthly.budgetTokens, 0)
        XCTAssertEqual(monthly.percent, 0)
    }

    func testBudgetGuardrailWeeklyAndMonthlyScopeWindows() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let service = BudgetGuardrailService()
        let settings = BudgetGuardrailSettings(weeklyTokens: 100_000, monthlyTokens: 500_000)

        let lastWeek = calendar.date(byAdding: .day, value: -8, to: now) ?? now
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 10_000, outputTokens: 0, source: "budget-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: lastWeek, inputTokens: 60_000, outputTokens: 0, source: "budget-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: lastMonth, inputTokens: 90_000, outputTokens: 0, source: "budget-test", dataSource: .localLog),
        ]

        let weekly = service.weeklyProgress(events: events, settings: settings, now: now, calendar: calendar)
        // Only events within the current week (now) count; lastWeek is outside.
        XCTAssertEqual(weekly.tokens, 10_000)
        XCTAssertEqual(weekly.percent, 10)

        let monthly = service.monthlyProgress(events: events, settings: settings, now: now, calendar: calendar)
        // lastWeek (03-09) is still inside the current month (starts 03-01); lastMonth (02-17) is outside.
        XCTAssertEqual(monthly.tokens, 70_000)
        XCTAssertEqual(monthly.percent, 14)
    }

    func testBudgetAlertServiceReportsCrossingOncePerCycle() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let settings = BudgetGuardrailSettings(dailyTokens: 10_000, alertThresholdPercent: 80)

        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 9_000, outputTokens: 0, source: "budget-test", dataSource: .localLog)
        ]

        let store = BudgetAlertDedupStore(defaults: UserDefaults(suiteName: "budget-alert-test-\(UUID().uuidString)")!)
        store.markDelivered([])
        let service = BudgetAlertService(store: store)

        let first = service.crossingCandidates(events: events, settings: settings, now: now, calendar: calendar)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.window, .daily)
        XCTAssertEqual(first.first?.percent, 90)
        XCTAssertTrue(first.first?.dedupeKey.hasPrefix("budget.daily.") ?? false)

        service.markDelivered(first)

        let second = service.crossingCandidates(events: events, settings: settings, now: now, calendar: calendar)
        XCTAssertTrue(second.isEmpty, "crossing should alert only once per cycle")

        // A later date is a new cycle and can alert again when usage resumes that day.
        let later = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let nextDayEvents = [
            UsageEvent(provider: .opencode, timestamp: later, inputTokens: 9_000, outputTokens: 0, source: "budget-test", dataSource: .localLog)
        ]
        let nextDay = service.crossingCandidates(events: nextDayEvents, settings: settings, now: later, calendar: calendar)
        XCTAssertEqual(nextDay.count, 1)
    }

    func testBudgetAlertServiceSkipsDisabledAndUnderThreshold() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let store = BudgetAlertDedupStore(defaults: UserDefaults(suiteName: "budget-alert-test-\(UUID().uuidString)")!)
        let service = BudgetAlertService(store: store)

        let disabled = BudgetGuardrailSettings()
        XCTAssertTrue(service.crossingCandidates(events: [], settings: disabled, now: now, calendar: calendar).isEmpty)

        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 5_000, outputTokens: 0, source: "budget-test", dataSource: .localLog)
        ]
        let highThreshold = BudgetGuardrailSettings(dailyTokens: 10_000, alertThresholdPercent: 90)
        XCTAssertTrue(
            service.crossingCandidates(events: events, settings: highThreshold, now: now, calendar: calendar).isEmpty,
            "50% usage below an 90% threshold must not alert"
        )
    }

    // MARK: - UsageStreakService

    func testUsageStreakCountsConsecutiveActiveDays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }

        // Activity on today, yesterday, and 2 days ago -> current streak 3.
        let events = [-2, -1, 0].map { offset in
            UsageEvent(provider: .opencode, timestamp: day(offset), inputTokens: 500, outputTokens: 0, source: "streak-test", dataSource: .localLog)
        }
        let streak = UsageStreakService.streak(events: events, now: now, calendar: calendar)
        XCTAssertEqual(streak.currentDays, 3)
        XCTAssertEqual(streak.longestDays, 3)
        XCTAssertEqual(streak.currentStart, calendar.startOfDay(for: day(-2)))
    }

    func testUsageStreakBreaksOnGapAndKeepsLongest() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }

        // Run of 5 (offsets -10...-6), then a gap, then 2 consecutive (offsets -1, 0).
        var offsets = Array(-10...(-6))
        offsets.append(contentsOf: [-1, 0])
        let events = offsets.map { offset in
            UsageEvent(provider: .opencode, timestamp: day(offset), inputTokens: 500, outputTokens: 0, source: "streak-test", dataSource: .localLog)
        }
        let streak = UsageStreakService.streak(events: events, now: now, calendar: calendar)
        XCTAssertEqual(streak.currentDays, 2)
        XCTAssertEqual(streak.longestDays, 5)
        XCTAssertEqual(streak.longestStart, calendar.startOfDay(for: day(-10)))
    }

    func testUsageStreakTreatsTodayIdleAsContinuingFromYesterday() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }

        // Activity on yesterday and 2 days ago, none today -> current streak still 2.
        let events = [-2, -1].map { offset in
            UsageEvent(provider: .opencode, timestamp: day(offset), inputTokens: 500, outputTokens: 0, source: "streak-test", dataSource: .localLog)
        }
        let streak = UsageStreakService.streak(events: events, now: now, calendar: calendar)
        XCTAssertEqual(streak.currentDays, 2)
    }

    func testUsageStreakReturnsZeroWithoutActivity() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let streak = UsageStreakService.streak(events: [], now: now, calendar: calendar)
        XCTAssertEqual(streak.currentDays, 0)
        XCTAssertEqual(streak.longestDays, 0)
        XCTAssertFalse(streak.hasActivity)
    }

    // MARK: - CacheEfficiencyService

    func testCacheEfficiencyComputesHitRateFromReadShare() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 3_000, outputTokens: 1_000, cacheReadTokens: 7_000, cacheCreationTokens: 2_000, source: "cache-test", dataSource: .localLog)
        ]
        let summary = CacheEfficiencyService.summary(events: events, now: now)
        XCTAssertEqual(summary.inputTokens, 3_000)
        XCTAssertEqual(summary.outputTokens, 1_000)
        XCTAssertEqual(summary.cacheReadTokens, 7_000)
        XCTAssertEqual(summary.cacheCreationTokens, 2_000)
        // Hit rate = cacheRead / (input + cacheRead) = 7000 / 10000 = 0.7
        XCTAssertEqual(summary.cacheHitRate, 0.7, accuracy: 0.001)
        XCTAssertTrue(summary.hasCacheActivity)
        XCTAssertEqual(summary.totalTokens, 13_000)
    }

    func testCacheEfficiencyAggregatesAcrossEventsAndClamps() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 1_000, outputTokens: 0, cacheReadTokens: 1_000, source: "cache-test", dataSource: .localLog),
            UsageEvent(provider: .claude, timestamp: now, inputTokens: 1_000, outputTokens: 0, cacheReadTokens: 0, source: "cache-test", dataSource: .localLog)
        ]
        let summary = CacheEfficiencyService.summary(events: events, now: now)
        // Hit rate = cacheRead / (input + cacheRead) = 1000 / (2000 + 1000) = 0.333
        XCTAssertEqual(summary.cacheHitRate, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(summary.inputTokens, 2_000)
        XCTAssertEqual(summary.cacheReadTokens, 1_000)
    }

    func testCacheEfficiencyReturnsZeroForNoActivityAndNoReads() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let empty = CacheEfficiencyService.summary(events: [], now: now)
        XCTAssertEqual(empty.cacheHitRate, 0)
        XCTAssertFalse(empty.hasAnyActivity)
        XCTAssertFalse(empty.hasCacheActivity)

        let outputOnly = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 0, outputTokens: 500, source: "cache-test", dataSource: .localLog)
        ]
        let summary = CacheEfficiencyService.summary(events: outputOnly, now: now)
        XCTAssertEqual(summary.cacheHitRate, 0)
        XCTAssertFalse(summary.hasCacheActivity)
        XCTAssertTrue(summary.hasAnyActivity)
    }

    // MARK: - ProviderCacheEfficiencyService

    func testProviderCacheEfficiencyRanksProvidersByContextReads() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        // opencode: 7K cacheRead / 10K reads = 70%. claude: 1K / 10K = 10%.
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 3_000, cacheReadTokens: 7_000, source: "cache-test", dataSource: .localLog),
            UsageEvent(provider: .claude, timestamp: now, inputTokens: 9_000, cacheReadTokens: 1_000, source: "cache-test", dataSource: .localLog),
        ]

        let summary = ProviderCacheEfficiencyService().summary(events: events, now: now)
        XCTAssertEqual(summary.providers.count, 2)
        XCTAssertTrue(summary.hasAnyActivity)

        let opencode = try XCTUnwrap(summary.providers.first { $0.provider == .opencode })
        XCTAssertEqual(opencode.hitRate, 0.7, accuracy: 0.001)
        let claude = try XCTUnwrap(summary.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.hitRate, 0.1, accuracy: 0.001)
    }

    func testProviderCacheEfficiencyExcludesProvidersWithoutReads() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, outputTokens: 500, source: "cache-test", dataSource: .localLog)
        ]
        let summary = ProviderCacheEfficiencyService().summary(events: events, now: now)
        XCTAssertTrue(summary.providers.isEmpty)
        XCTAssertFalse(summary.hasAnyActivity)
    }

    // MARK: - CacheTrendService

    func testCacheTrendComputesDailyRatesAndDetectsDegradation() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }

        // Yesterday: 60% hit (6000/10000). Today: 30% hit (3000/10000).
        // Average of active days = 45%, latest = 30% -> 15 points below -> degrading.
        let events = [
            UsageEvent(provider: .opencode, timestamp: day(-1), inputTokens: 4_000, cacheReadTokens: 6_000, source: "cache-trend-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: day(0), inputTokens: 7_000, cacheReadTokens: 3_000, source: "cache-trend-test", dataSource: .localLog),
        ]

        let trend = CacheTrendService.trend(events: events, days: 3, now: now, calendar: calendar)
        XCTAssertEqual(trend.days.count, 3)
        let active = trend.days.filter(\.hasActivity)
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(try XCTUnwrap(trend.latestHitRate), 0.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(trend.averageHitRate), 0.45, accuracy: 0.001)
        XCTAssertTrue(trend.isDegrading)
    }

    func testCacheTrendNoDegradationWhenRateStableOrSingleDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }

        // Stable 60% both days.
        let stable = [
            UsageEvent(provider: .opencode, timestamp: day(-1), inputTokens: 4_000, cacheReadTokens: 6_000, source: "cache-trend-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: day(0), inputTokens: 4_000, cacheReadTokens: 6_000, source: "cache-trend-test", dataSource: .localLog),
        ]
        let stableTrend = CacheTrendService.trend(events: stable, days: 3, now: now, calendar: calendar)
        XCTAssertFalse(stableTrend.isDegrading)

        // Single active day -> no degradation signal.
        let single = [
            UsageEvent(provider: .opencode, timestamp: day(0), inputTokens: 4_000, cacheReadTokens: 6_000, source: "cache-trend-test", dataSource: .localLog)
        ]
        let singleTrend = CacheTrendService.trend(events: single, days: 3, now: now, calendar: calendar)
        XCTAssertFalse(singleTrend.isDegrading)

        let emptyTrend = CacheTrendService.trend(events: [], days: 3, now: now, calendar: calendar)
        XCTAssertNil(emptyTrend.latestHitRate)
        XCTAssertNil(emptyTrend.averageHitRate)
        XCTAssertFalse(emptyTrend.isDegrading)
    }

    // MARK: - ThroughputService

    func testThroughputComputesTokensPerMinuteOverWindow() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        // 3,000 tokens across 30 minutes -> 100 tok/min.
        let events = [
            UsageEvent(provider: .opencode, timestamp: now.addingTimeInterval(-30 * 60), inputTokens: 1_000, outputTokens: 0, source: "throughput-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: now.addingTimeInterval(-15 * 60), inputTokens: 2_000, outputTokens: 0, source: "throughput-test", dataSource: .localLog),
        ]

        let reading = ThroughputService().reading(events: events, windowMinutes: 60, now: now)
        XCTAssertTrue(reading.hasActivity)
        XCTAssertEqual(reading.windowTokens, 3_000)
        XCTAssertEqual(reading.tokensPerMinute, 100, accuracy: 0.001)
        XCTAssertEqual(reading.windowMinutes, 60)
    }

    func testThroughputUsesOldestEventForElapsedWindow() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        // 6,000 tokens across the oldest event at -40 min (window 60) -> elapsed 40 -> 150 tok/min.
        let events = [
            UsageEvent(provider: .opencode, timestamp: now.addingTimeInterval(-40 * 60), inputTokens: 4_000, outputTokens: 0, source: "throughput-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: now.addingTimeInterval(-20 * 60), inputTokens: 2_000, outputTokens: 0, source: "throughput-test", dataSource: .localLog),
        ]

        let reading = ThroughputService().reading(events: events, windowMinutes: 60, now: now)
        XCTAssertEqual(reading.tokensPerMinute, 150, accuracy: 0.001)
    }

    func testThroughputReturnsNoActivityWithoutTokens() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let empty = ThroughputService().reading(events: [], windowMinutes: 60, now: now)
        XCTAssertFalse(empty.hasActivity)
        XCTAssertEqual(empty.tokensPerMinute, 0)
        XCTAssertEqual(empty.windowTokens, 0)
    }

    // MARK: - BudgetHistoryService

    func testBudgetHistoryTracksDailyUsageAgainstBudget() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }

        // Today: 12K of a 10K budget -> exceeded. Yesterday: 5K -> 50%.
        let events = [
            UsageEvent(provider: .opencode, timestamp: day(0), inputTokens: 12_000, outputTokens: 0, source: "budget-history-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: day(-1), inputTokens: 5_000, outputTokens: 0, source: "budget-history-test", dataSource: .localLog),
        ]

        let trend = BudgetHistoryService().trend(events: events, dailyBudgetTokens: 10_000, days: 3, now: now, calendar: calendar)
        XCTAssertEqual(trend.days.count, 3)
        XCTAssertEqual(trend.activeDayCount, 2)
        XCTAssertEqual(trend.exceededCount, 1)

        let today = trend.days.last
        XCTAssertEqual(today?.percent, 100)
        XCTAssertTrue(today?.exceeded == true)

        let yesterday = trend.days[trend.days.count - 2]
        XCTAssertEqual(yesterday.percent, 50)
        XCTAssertFalse(yesterday.exceeded)

        let emptyDay = trend.days.first
        XCTAssertFalse(emptyDay?.hasActivity == true)
        XCTAssertEqual(emptyDay?.percent, 0)
    }

    func testBudgetHistoryDisabledBudgetYieldsZeroPercent() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 5_000, outputTokens: 0, source: "budget-history-test", dataSource: .localLog)
        ]

        let trend = BudgetHistoryService().trend(events: events, dailyBudgetTokens: 0, days: 3, now: now, calendar: calendar)
        XCTAssertEqual(trend.exceededCount, 0)
        XCTAssertTrue(trend.days.allSatisfy { $0.percent == 0 && !$0.exceeded })
        XCTAssertEqual(trend.activeDayCount, 1)
    }

    // MARK: - RequestHistoryService

    func testRequestHistoryAggregatesDailyRequestCounts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18))
        )
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 1_000, outputTokens: 0, requestCount: 3, source: "request-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: yesterday, inputTokens: 1_000, outputTokens: 0, requestCount: 2, source: "request-test", dataSource: .localLog),
        ]

        let trend = RequestHistoryService().trend(events: events, days: 3, now: now, calendar: calendar)
        XCTAssertEqual(trend.days.count, 3)
        XCTAssertEqual(trend.totalRequests, 5)
        XCTAssertEqual(trend.days.last?.requestCount, 3)
        XCTAssertEqual(trend.days[trend.days.count - 2].requestCount, 2)
        XCTAssertEqual(trend.days.first?.requestCount, 0)
        XCTAssertNotNil(trend.peakDayLabel)
    }

    func testRequestHistoryEmptyWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18))
        )

        let trend = RequestHistoryService().trend(events: [], days: 7, now: now, calendar: calendar)
        XCTAssertEqual(trend.days.count, 7)
        XCTAssertEqual(trend.totalRequests, 0)
        XCTAssertNil(trend.peakDayLabel)
    }

    // MARK: - FiveHourBlocksService

    func testFiveHourBlocksBucketsAlignedToLocalMidnight() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!

        // 07:30 -> block [05:00, 10:00); 12:00 -> block [10:00, 15:00); 23:30 -> block [20:00, 25:00).
        let events = [
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .hour, value: -4, to: now)!, inputTokens: 100, outputTokens: 0, source: "block-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 200, outputTokens: 0, source: "block-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .hour, value: 11, to: now)!, inputTokens: 300, outputTokens: 0, source: "block-test", dataSource: .localLog),
        ]

        let blocks = FiveHourBlocksService.blocks(events: events, now: now, calendar: calendar)
        XCTAssertEqual(blocks.count, 3)

        // Verify alignment: each block starts at an hour divisible by 5 from midnight.
        let midnight = calendar.startOfDay(for: now)
        for block in blocks {
            let seconds = block.start.timeIntervalSince(midnight)
            XCTAssertEqual(Int(seconds) % Int(FiveHourBlocksService.blockDuration), 0, "block \(block.start) is not 5-hour aligned")
        }

        let totalTokens = blocks.reduce(0) { $0 + $1.tokens }
        XCTAssertEqual(totalTokens, 600)
        let totalRequests = blocks.reduce(0) { $0 + $1.requestCount }
        XCTAssertEqual(totalRequests, 3)
    }

    func testFiveHourBlocksReturnsEmptyWithoutEvents() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let blocks = FiveHourBlocksService.blocks(events: [], now: now, calendar: calendar)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testFiveHourBlockStartAlignsToMidnight() throws {
        let calendar = Calendar(identifier: .gregorian)
        let midnight = calendar.startOfDay(for: calendar.date(from: DateComponents(year: 2030, month: 3, day: 17))!)

        // 04:59 -> block [00:00, 05:00)
        let early = midnight.addingTimeInterval(4 * 3600 + 59 * 60)
        XCTAssertEqual(FiveHourBlocksService.blockStart(of: early, calendar: calendar), midnight)

        // 05:00 -> block [05:00, 10:00)
        let five = midnight.addingTimeInterval(5 * 3600)
        XCTAssertEqual(FiveHourBlocksService.blockStart(of: five, calendar: calendar), midnight.addingTimeInterval(5 * 3600))

        // 21:30 -> block [20:00, 25:00)
        let late = midnight.addingTimeInterval(21.5 * 3600)
        XCTAssertEqual(FiveHourBlocksService.blockStart(of: late, calendar: calendar), midnight.addingTimeInterval(20 * 3600))
    }

    // MARK: - ProviderStatusService

    func testProviderStatusParserMapsIndicators() throws {
        let parser = ProviderStatusParser()

        let operational = try parser.parse(try statusPayload(indicator: "none", description: "All Systems Operational"))
        XCTAssertEqual(operational.health, .operational)
        XCTAssertEqual(operational.description, "All Systems Operational")

        let minor = try parser.parse(try statusPayload(indicator: "minor", description: "Partial Service Outage"))
        XCTAssertEqual(minor.health, .degraded)

        let major = try parser.parse(try statusPayload(indicator: "major", description: "Major Outage"))
        XCTAssertEqual(major.health, .degraded)

        let critical = try parser.parse(try statusPayload(indicator: "critical", description: "Critical Outage"))
        XCTAssertEqual(critical.health, .outage)

        let unknown = try parser.parse(try statusPayload(indicator: "weird", description: ""))
        XCTAssertEqual(unknown.health, .unknown)
    }

    func testProviderStatusParserRejectsNonStatuspagePayload() {
        let parser = ProviderStatusParser()
        XCTAssertThrowsError(try parser.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try parser.parse(Data("not json".utf8)))
    }

    func testProviderStatusServiceFetchesCachesAndFallsBack() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let operationalData = try statusPayload(indicator: "none", description: "All Systems Operational")
        let outageData = try statusPayload(indicator: "critical", description: "Critical Outage")

        let client = StubProviderStatusHTTPClient(responses: [
            .init(status: 200, data: operationalData),
            .init(status: 500, data: Data()),
        ])
        let defaults = UserDefaults(suiteName: "provider-status-test-\(UUID().uuidString)")!
        let service = ProviderStatusService(
            httpClient: client,
            session: URLSession(configuration: .ephemeral),
            defaults: defaults,
            ttl: 3_600
        )

        // First fetch succeeds and caches.
        let first = await service.refreshStatus(for: .claude, now: now)
        XCTAssertEqual(first.health, .operational)
        XCTAssertEqual(first.description, "All Systems Operational")

        // A second fetch within TTL serves the cached reading without a network call.
        let cached = await service.refreshStatus(for: .claude, now: now.addingTimeInterval(60))
        XCTAssertEqual(cached.health, .operational)
        XCTAssertEqual(client.callCount, 1)

        // A fetch after TTL retries; the HTTP failure falls back to the cached value.
        let afterTTL = await service.refreshStatus(for: .claude, now: now.addingTimeInterval(3_700))
        XCTAssertEqual(afterTTL.health, .operational)
    }

    func testProviderStatusServiceReportsUnknownWithoutEndpoint() async {
        let client = StubProviderStatusHTTPClient(responses: [])
        let service = ProviderStatusService(
            httpClient: client,
            session: URLSession(configuration: .ephemeral),
            defaults: UserDefaults(suiteName: "provider-status-test-\(UUID().uuidString)")!
        )
        let report = await service.refreshStatus(for: .opencode)
        XCTAssertEqual(report.health, .unknown)
        XCTAssertTrue(report.description.isEmpty)
    }

    // MARK: - HourlyActivityService

    func testHourlyActivityBucketsByHourAndKeepsEmptyHours() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 500, outputTokens: 0, source: "hourly-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: now.addingTimeInterval(30 * 60), inputTokens: 300, outputTokens: 0, source: "hourly-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .hour, value: -3, to: now)!, inputTokens: 200, outputTokens: 0, source: "hourly-test", dataSource: .localLog),
        ]

        let buckets = HourlyActivityService.hourlyBuckets(events: events, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 24)
        let hour9 = buckets.first { $0.hour == 9 }
        XCTAssertEqual(hour9?.tokens, 200)
        let hour12 = buckets.first { $0.hour == 12 }
        XCTAssertEqual(hour12?.tokens, 800)
        XCTAssertEqual(hour12?.requestCount, 2)
        let hour0 = buckets.first { $0.hour == 0 }
        XCTAssertEqual(hour0?.tokens, 0)
    }

    func testHourlyActivityPeakHourAndEmptySummary() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 100, outputTokens: 0, source: "hourly-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .hour, value: -2, to: now)!, inputTokens: 900, outputTokens: 0, source: "hourly-test", dataSource: .localLog),
        ]

        let summary = HourlyActivitySummary(buckets: HourlyActivityService.hourlyBuckets(events: events, now: now, calendar: calendar))
        XCTAssertEqual(summary.peakHour, 10)

        let empty = HourlyActivitySummary(buckets: HourlyActivityService.hourlyBuckets(events: [], now: now, calendar: calendar))
        XCTAssertNil(empty.peakHour)
    }

    // MARK: - MonthlyTrendService

    func testMonthlyTrendBucketsByCalendarMonthAndFillsWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 500, outputTokens: 0, source: "monthly-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .month, value: -2, to: now)!, inputTokens: 300, outputTokens: 0, source: "monthly-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: calendar.date(byAdding: .month, value: -13, to: now)!, inputTokens: 900, outputTokens: 0, source: "monthly-test", dataSource: .localLog),
        ]

        let bars = MonthlyTrendService.monthlyBars(events: events, months: 12, now: now, calendar: calendar)
        XCTAssertEqual(bars.count, 12)
        XCTAssertEqual(bars.last?.monthLabel, "2030-03")
        XCTAssertEqual(bars.last?.tokens, 500)
        // 2 months back is inside the 12-month window.
        XCTAssertTrue(bars.contains { $0.monthLabel == "2030-01" && $0.tokens == 300 })
        // 13 months back is outside the window.
        XCTAssertFalse(bars.contains { $0.tokens == 900 })
        // Zero months between stay visible.
        XCTAssertEqual(bars.count, 12)
        let total = bars.reduce(0) { $0 + $1.tokens }
        XCTAssertEqual(total, 800)
    }

    func testMonthlyTrendEmptyAndSingleMonth() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!

        let empty = MonthlyTrendService.monthlyBars(events: [], months: 6, now: now, calendar: calendar)
        XCTAssertEqual(empty.count, 6)
        XCTAssertTrue(empty.allSatisfy { $0.tokens == 0 })

        let single = MonthlyTrendService.monthlyBars(events: [], months: 1, now: now, calendar: calendar)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.monthLabel, "2030-03")
    }

    // MARK: - CostEfficiencyService

    func testCostEfficiencyComputesPerRequestMetrics() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 1_000, outputTokens: 1_000, requestCount: 2, estimatedCostUSD: Decimal(0.20), source: "cost-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: now.addingTimeInterval(60), inputTokens: 2_000, outputTokens: 0, requestCount: 1, source: "cost-test", dataSource: .localLog),
        ]

        let summary = CostEfficiencyService.summary(events: events, now: now)
        XCTAssertEqual(summary.totalTokens, 4_000)
        XCTAssertEqual(summary.requestCount, 3)
        XCTAssertEqual(summary.totalCostUSD, Decimal(0.20))
        // cost / request over all requests = 0.20 / 3
        XCTAssertEqual(summary.costPerRequestUSD, Decimal(0.20) / Decimal(3))
        // tokens / request = 4000 / 3
        XCTAssertEqual(summary.tokensPerRequest, 4_000.0 / 3.0, accuracy: 0.001)
        // output share = 1000 / 4000
        XCTAssertEqual(summary.outputTokenRatio, 0.25, accuracy: 0.001)
        XCTAssertTrue(summary.hasAnyActivity)
    }

    func testCostEfficiencyIgnoresEventsWithoutCostAndEmpty() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let events = [
            UsageEvent(provider: .opencode, timestamp: now, inputTokens: 500, outputTokens: 0, requestCount: 2, source: "cost-test", dataSource: .localLog)
        ]

        let summary = CostEfficiencyService.summary(events: events, now: now)
        XCTAssertNil(summary.totalCostUSD)
        XCTAssertNil(summary.costPerRequestUSD)
        XCTAssertEqual(summary.tokensPerRequest, 250, accuracy: 0.001)
        XCTAssertEqual(summary.outputTokenRatio, 0)

        let empty = CostEfficiencyService.summary(events: [], now: now)
        XCTAssertEqual(empty.requestCount, 0)
        XCTAssertEqual(empty.tokensPerRequest, 0)
        XCTAssertFalse(empty.hasAnyActivity)
    }

    // MARK: - UsageCoverageService

    func testUsageCoverageCountsActiveDaysAndGaps() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }

        // Activity today, yesterday, and 5 days ago. In a 7-day window
        // (offsets -6..0) the inactive runs are day -6 and days -4..-2.
        let events = [0, -1, -5].map { offset in
            UsageEvent(provider: .opencode, timestamp: day(offset), inputTokens: 500, outputTokens: 0, source: "coverage-test", dataSource: .localLog)
        }

        let coverage = UsageCoverageService.coverage(events: events, windowDays: 7, now: now, calendar: calendar)
        XCTAssertEqual(coverage.windowDays, 7)
        XCTAssertEqual(coverage.activeDays, 3)
        XCTAssertEqual(coverage.gapRunCount, 2)
        XCTAssertEqual(coverage.longestGapDays, 3)
        XCTAssertEqual(coverage.oldestEventDay, calendar.startOfDay(for: day(-5)))
        XCTAssertEqual(coverage.newestEventDay, calendar.startOfDay(for: day(0)))
    }

    func testUsageCoverageEmptyHistory() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let coverage = UsageCoverageService.coverage(events: [], windowDays: 45, now: now, calendar: calendar)
        XCTAssertEqual(coverage.activeDays, 0)
        XCTAssertEqual(coverage.coverageRatio, 0)
        XCTAssertNil(coverage.oldestEventDay)
        XCTAssertNil(coverage.newestEventDay)
        XCTAssertEqual(coverage.gapRunCount, 0)
        XCTAssertEqual(coverage.longestGapDays, 0)
    }

    func testCLIAuditTextReportsCoverage() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }
        let events = [0, -1].map { offset in
            UsageEvent(provider: .opencode, timestamp: day(offset), inputTokens: 500, outputTokens: 0, source: "coverage-test", dataSource: .localLog)
        }
        let text = TokenPilotCLIService.auditText(
            events: events,
            language: .en,
            windowDays: 7,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("TokenPilot · Audit"))
        XCTAssertTrue(text.contains("Active days: 2"))
        XCTAssertTrue(text.contains("Local activity, not provider quota"))
    }

    func testCLIAuditJSONPayloadMatchesCoverage() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }
        // Today and yesterday are active; the other five window days are gaps.
        let events = [0, -1].map { offset in
            UsageEvent(provider: .opencode, timestamp: day(offset), inputTokens: 500, outputTokens: 0, source: "coverage-test", dataSource: .localLog)
        }
        let data = try TokenPilotCLIService.auditJSON(
            events: events,
            windowDays: 7,
            now: now,
            calendar: calendar
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["windowDays"] as? Int, 7)
        XCTAssertEqual(json["activeDays"] as? Int, 2)
        XCTAssertEqual(json["coveragePercent"] as? Int, 29)
        XCTAssertEqual(json["gapRunCount"] as? Int, 1)
        XCTAssertEqual(json["longestGapDays"] as? Int, 5)
        XCTAssertEqual(json["oldestEventDay"] as? String, "2030-03-16")
        XCTAssertEqual(json["newestEventDay"] as? String, "2030-03-17")
        // Per-day breakdown (toktrack audit --json style): one row per window day.
        let days = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 7)
        let todayRow = try XCTUnwrap(days.first { $0["date"] as? String == "2030-03-17" })
        XCTAssertEqual(todayRow["active"] as? Bool, true)
        XCTAssertEqual(todayRow["tokens"] as? Int, 500)
        let yesterdayRow = try XCTUnwrap(days.first { $0["date"] as? String == "2030-03-16" })
        XCTAssertEqual(yesterdayRow["active"] as? Bool, true)
        let gapRow = try XCTUnwrap(days.first { $0["date"] as? String == "2030-03-12" })
        XCTAssertEqual(gapRow["active"] as? Bool, false)
        XCTAssertEqual(gapRow["tokens"] as? Int, 0)
        // Aggregates only: no per-event source labels leak.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("coverage-test"))
    }

    func testCLIAuditWindowSelectorsScopeCoverage() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let day = { (offset: Int) -> Date in
            calendar.date(byAdding: .day, value: offset, to: now)!
        }
        let inWindow = [
            UsageEvent(provider: .opencode, timestamp: day(0), inputTokens: 500, outputTokens: 0, source: "coverage-test", dataSource: .localLog),
            UsageEvent(provider: .opencode, timestamp: day(-1), inputTokens: 500, outputTokens: 0, source: "coverage-test", dataSource: .localLog),
        ]
        let outside = [
            UsageEvent(provider: .opencode, timestamp: day(-10), inputTokens: 500, outputTokens: 0, source: "coverage-test", dataSource: .localLog),
        ]
        // --since/--until scope the audited window: the 10-days-ago event is outside.
        let text = TokenPilotCLIService.auditText(
            events: inWindow + outside,
            language: .en,
            since: day(-2),
            until: day(0),
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Active days: 2"))
        XCTAssertTrue(text.contains("of last 3 days"))

        // JSON payload reflects the scoped window in its per-day breakdown rows.
        let data = try TokenPilotCLIService.auditJSON(
            events: inWindow + outside,
            since: day(-2),
            until: day(0),
            now: now,
            calendar: calendar
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["windowDays"] as? Int, 3)
        XCTAssertEqual(json["activeDays"] as? Int, 2)
        let days = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 3)

        // --project restricts the audited events to one workspace label.
        let scoped = [
            UsageEvent(provider: .opencode, timestamp: day(0), inputTokens: 500, outputTokens: 0, source: "coverage-test", dataSource: .localLog, projectLabel: "project-a"),
            UsageEvent(provider: .opencode, timestamp: day(0), inputTokens: 500, outputTokens: 0, source: "coverage-test", dataSource: .localLog, projectLabel: "project-b"),
        ]
        let projectText = TokenPilotCLIService.auditText(
            events: scoped,
            language: .en,
            windowDays: 7,
            project: "project-a",
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(projectText.contains("Active days: 1"))
    }

    func testCLIBlocksTextAndJSONReportWindowStatus() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
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
            resetAt: now.addingTimeInterval(3_600),
            value: try CapacityValue(usedPercent: 62),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "blocksV1",
            now: now
        )
        let record = try CapacityEvidenceRecord(observation: observation)
        let assessment = CapacityAssessmentService().assess(try record.observationForAssessment(now: now), now: now)

        let text = TokenPilotCLIService.blocksText(assessments: [assessment], now: now, calendar: calendar)
        XCTAssertTrue(text.contains("TokenPilot · Blocks"))
        XCTAssertTrue(text.contains("Claude Code (five-hour)"))
        XCTAssertTrue(text.contains("62% used"))
        XCTAssertTrue(text.contains("38% remaining"))
        XCTAssertTrue(text.contains("resets"))

        let data = try TokenPilotCLIService.blocksJSON(assessments: [assessment], now: now, calendar: calendar)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let blocks = try XCTUnwrap(json["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        let row = try XCTUnwrap(blocks.first)
        XCTAssertEqual(row["provider"] as? String, "Claude Code")
        XCTAssertEqual(row["windowID"] as? String, "five-hour")
        XCTAssertEqual(row["usedPercent"] as? Int, 62)
        XCTAssertEqual(row["remainingPercent"] as? Int, 38)
        // Aggregates only: no parser revision leaks.
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("blocksV1"))
    }

    func testCLIBlocksActiveAndRecentFilters() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 17, hour: 12))!
        let series = try CapacitySeriesID(
            provider: .claude,
            providerWindowID: "five-hour",
            kind: .fixedReset,
            unit: .percent,
            durationMinutes: 300
        )
        // Active block: resetAt is in the future. Inactive block: resetAt already elapsed.
        let active = try CapacityAssessmentService().assess(
            try CapacityEvidenceRecord(
                observation: try CapacityObservation(
                    seriesID: series,
                    observedAt: now,
                    resetAt: now.addingTimeInterval(3_600),
                    value: try CapacityValue(usedPercent: 40),
                    authority: .providerReported,
                    stability: .supported,
                    freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
                    comparability: .comparable,
                    parserRevision: "filterV1",
                    now: now
                )
            ).observationForAssessment(now: now),
            now: now
        )
        let inactive = try CapacityAssessmentService().assess(
            try CapacityEvidenceRecord(
                observation: try CapacityObservation(
                    seriesID: series,
                    observedAt: now,
                    resetAt: now.addingTimeInterval(-3_600),
                    value: try CapacityValue(usedPercent: 80),
                    authority: .providerReported,
                    stability: .supported,
                    freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
                    comparability: .comparable,
                    parserRevision: "filterV1",
                    now: now
                )
            ).observationForAssessment(now: now),
            now: now
        )
        let text = TokenPilotCLIService.blocksText(
            assessments: [active, inactive],
            active: true,
            now: now,
            calendar: calendar
        )
        // --active keeps only the future-reset block (40% used).
        XCTAssertTrue(text.contains("40% used"))
        XCTAssertFalse(text.contains("80% used"))

        // --recent keeps only blocks observed within the freshness window. Build a stale
        // observation older than its maximumAge so it drops out.
        let stale = try CapacityAssessmentService().assess(
            try CapacityEvidenceRecord(
                observation: try CapacityObservation(
                    seriesID: series,
                    observedAt: now.addingTimeInterval(-10_800),
                    resetAt: now.addingTimeInterval(3_600),
                    value: try CapacityValue(usedPercent: 25),
                    authority: .providerReported,
                    stability: .supported,
                    freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 3_600),
                    comparability: .comparable,
                    parserRevision: "filterV1",
                    now: now
                )
            ).observationForAssessment(now: now),
            now: now
        )
        let recentText = TokenPilotCLIService.blocksText(
            assessments: [active, stale],
            recent: true,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(recentText.contains("40% used"))
        XCTAssertFalse(recentText.contains("25% used"))
    }

    // MARK: - ContextHealthService

    func testContextHealthClassifiesLevelsAndDelta() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let series = try CapacitySeriesID(provider: .kiro, providerWindowID: "context-percent", kind: .context, unit: .percent)
        let early = try CapacityObservation(
            seriesID: series,
            observedAt: now.addingTimeInterval(-3_600),
            value: try CapacityValue(usedPercent: 55),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        let latest = try CapacityObservation(
            seriesID: series,
            observedAt: now,
            value: try CapacityValue(usedPercent: 72),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        let records = try [early, latest].map { try CapacityEvidenceRecord(observation: $0) }

        let assessments = ContextHealthService().assess(records: records, now: now)
        XCTAssertEqual(assessments.count, 1)
        let assessment = try XCTUnwrap(assessments.first)
        XCTAssertEqual(assessment.provider, .kiro)
        XCTAssertEqual(assessment.usedPercent, 72)
        XCTAssertEqual(assessment.level, .elevated)
        XCTAssertEqual(assessment.recentDelta, 17)
        XCTAssertTrue(assessment.isFillingFast)
    }

    func testContextHealthMarksFastFillAndBloat() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let series = try CapacitySeriesID(provider: .kiro, providerWindowID: "context-percent", kind: .context, unit: .percent)
        let early = try CapacityObservation(
            seriesID: series,
            observedAt: now.addingTimeInterval(-3_600),
            value: try CapacityValue(usedPercent: 60),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        let latest = try CapacityObservation(
            seriesID: series,
            observedAt: now,
            value: try CapacityValue(usedPercent: 85),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 3_600),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        let records = try [early, latest].map { try CapacityEvidenceRecord(observation: $0) }

        let assessments = ContextHealthService().assess(records: records, now: now)
        let assessment = try XCTUnwrap(assessments.first)
        XCTAssertEqual(assessment.level, .bloat)
        XCTAssertEqual(assessment.recentDelta, 25)
        XCTAssertTrue(assessment.isFillingFast)
    }

    func testContextHealthIgnoresNonContextRecords() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let percentSeries = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, durationMinutes: 300)
        let observation = try CapacityObservation(
            seriesID: percentSeries,
            observedAt: now,
            value: try CapacityValue(usedPercent: 60),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        let records = [try CapacityEvidenceRecord(observation: observation)]

        let assessments = ContextHealthService().assess(records: records, now: now)
        XCTAssertTrue(assessments.isEmpty)
    }

    private func statusPayload(indicator: String, description: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "page": ["id": "test"],
            "status": ["indicator": indicator, "description": description],
        ])
    }
}

private final class StubProviderStatusHTTPClient: ProviderStatusHTTPClient, @unchecked Sendable {
    struct StubResponse: Sendable {
        let status: Int
        let data: Data
    }

    private let responses: [StubResponse]
    private let counterLock = OSAllocatedUnfairLock(initialState: 0)

    init(responses: [StubResponse]) {
        self.responses = responses
    }

    var callCount: Int {
        counterLock.withLock { $0 }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let callIndex = counterLock.withLock { count -> Int in
            defer { count += 1 }
            return count
        }
        guard callIndex < responses.count else {
            throw ProviderStatusError.invalidHTTPResponse
        }
        let response = responses[callIndex]
        let url = request.url ?? URL(string: "https://status.example.com")!
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (response.data, http)
    }
}

private struct FixedCapacityClock: CapacityEvidenceClock {
    let now: Date
}

private final class FailOnceCapacityFileSystem: CapacityEvidenceFileSystem, @unchecked Sendable {
    private let base = LocalCapacityEvidenceFileSystem()
    private let lock = NSLock()
    private var failingNames: Set<String>

    init(failWriteOnceForLastPathComponent: String) {
        self.failingNames = [failWriteOnceForLastPathComponent]
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try base.readData(at: url)
    }

    func writeDataExclusively(_ data: Data, to url: URL) throws {
        if shouldFail(url) {
            throw CocoaError(.fileWriteUnknown)
        }
        try base.writeDataExclusively(data, to: url)
    }

    func replaceItem(at target: URL, withItemAt source: URL) throws {
        try base.replaceItem(at: target, withItemAt: source)
    }

    func copyItem(at source: URL, to target: URL) throws {
        try base.copyItem(at: source, to: target)
    }

    func removeItemIfExists(at url: URL) throws {
        try base.removeItemIfExists(at: url)
    }

    func createDirectory(at url: URL) throws {
        try base.createDirectory(at: url)
    }

    func synchronizeFile(at url: URL) throws {
        try base.synchronizeFile(at: url)
    }

    func synchronizeDirectory(at url: URL) throws {
        try base.synchronizeDirectory(at: url)
    }

    private func shouldFail(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failingNames.remove(url.lastPathComponent) != nil
    }
}

private final class FixedProviderAdapter: ProviderAdapter, @unchecked Sendable {
    let provider: Provider
    private let snapshotValue: ProviderSnapshot

    init(snapshot: ProviderSnapshot) {
        self.provider = snapshot.provider
        self.snapshotValue = snapshot
    }

    func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        snapshotValue
    }
}

private actor StubCodexAppServerRateLimitClient: CodexAppServerRateLimitClient {
    private let dataValue: Data
    private var calls = 0

    init(data: Data) {
        self.dataValue = data
    }

    func readRateLimits() async throws -> Data {
        calls += 1
        return dataValue
    }

    func callCount() -> Int { calls }
}

private actor RecordingCodexWebUsageHTTPClient: CodexWebUsageHTTPClient {
    private let dataValue: Data
    private let statusCode: Int
    private let failIfCalled: Bool
    private var recordedRequest: URLRequest?

    init(data: Data, statusCode: Int = 200, failIfCalled: Bool = false) {
        self.dataValue = data
        self.statusCode = statusCode
        self.failIfCalled = failIfCalled
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if failIfCalled {
            XCTFail("HTTP client should not be called")
        }
        recordedRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (dataValue, response)
    }

    func authorizationHeader() -> String? {
        recordedRequest?.value(forHTTPHeaderField: "Authorization")
    }

    func requestURL() -> URL? {
        recordedRequest?.url
    }
}

private final class StubGrokOAuthDescriptorLoader: GrokOAuthDescriptorLoading, @unchecked Sendable {
    private let result: Result<Data, XAIUnavailableReason>

    init(result: Result<Data, XAIUnavailableReason>) {
        self.result = result
    }

    func loadDescriptorBytes() -> Result<Data, XAIUnavailableReason> {
        result
    }
}

private final class StubGrokOAuthBillingTransport: GrokOAuthBillingTransporting, @unchecked Sendable {
    private let result: Result<(statusCode: Int, body: Data), XAIUnavailableReason>
    private let lock = NSLock()
    private var calls = 0

    init(result: Result<(statusCode: Int, body: Data), XAIUnavailableReason>) {
        self.result = result
    }

    func fetchWeeklyBilling(accessToken: String) async -> Result<(statusCode: Int, body: Data), XAIUnavailableReason> {
        XCTAssertEqual(accessToken, "synthetic-access")
        lock.withLock {
            calls += 1
        }
        return result
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class GrokOAuthFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class GrokOAuthWeeklyUsageTests: XCTestCase {
    func testDisabledConsentDoesNotConstructSensitiveDependencies() async {
        let counter = GrokOAuthFactoryCounter()
        let adapter = GrokOAuthWeeklyUsageAdapter(
            executionCapability: XAIExecutionCapability(isSandboxed: false),
            makeDescriptorLoader: {
                counter.increment()
                return StubGrokOAuthDescriptorLoader(result: .failure(.descriptorNotFound))
            },
            makeTransport: {
                counter.increment()
                return StubGrokOAuthBillingTransport(result: .failure(.billingNetwork))
            }
        )
        var settings = AppSettings()
        settings.xaiEnabled = true
        _ = settings.setProviderEnabled(.xai, isEnabled: true)
        settings.xAI.experimentalOAuthWeeklyConsentVersion = nil

        let result = await adapter.refresh(
            XAIExperimentalWeeklyInput(
                settings: settings,
                intent: .manual,
                ticket: XAIRefreshTicket(generation: 1),
                now: Date(timeIntervalSince1970: 1_900_000_000)
            )
        )

        XCTAssertEqual(result.oauthFailure, .consentNotGranted)
        XCTAssertEqual(counter.current(), 0)
    }

    func testSandboxDoesNotConstructSensitiveDependencies() async {
        let counter = GrokOAuthFactoryCounter()
        let adapter = GrokOAuthWeeklyUsageAdapter(
            executionCapability: XAIExecutionCapability(isSandboxed: true),
            makeDescriptorLoader: {
                counter.increment()
                return StubGrokOAuthDescriptorLoader(result: .failure(.descriptorNotFound))
            },
            makeTransport: {
                counter.increment()
                return StubGrokOAuthBillingTransport(result: .failure(.billingNetwork))
            }
        )
        var settings = AppSettings()
        settings.xaiEnabled = true
        _ = settings.setProviderEnabled(.xai, isEnabled: true)
        settings.xAI.experimentalOAuthWeeklyConsentVersion = 1

        let result = await adapter.refresh(
            XAIExperimentalWeeklyInput(
                settings: settings,
                intent: .manual,
                ticket: XAIRefreshTicket(generation: 1),
                now: Date(timeIntervalSince1970: 1_900_000_000)
            )
        )

        XCTAssertEqual(result.oauthFailure, .appSandboxed)
        XCTAssertEqual(counter.current(), 0)
    }

    func testInjectedOAuthSuccessReturnsTransientWeeklyResultOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiry = formatter.string(from: now.addingTimeInterval(86_400))
        let start = formatter.string(from: now.addingTimeInterval(-86_400))
        let end = formatter.string(from: now.addingTimeInterval((6 * 86_400)))
        let descriptor = try JSONSerialization.data(withJSONObject: [
            GrokOAuthWeeklyUsageAdapter.selectedScopeKey: [
                "access_token": "synthetic-access",
                "expires_at": expiry,
                "auth_mode": "oidc",
                "oidc_issuer": "https://auth.x.ai",
                "oidc_client_id": "b1a00492-073a-47ea-816f-4c329264a828"
            ]
        ])
        let billing = try JSONSerialization.data(withJSONObject: [
            "config": ["isUnifiedBillingUser": true],
            "currentPeriod": [
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": start,
                "end": end
            ],
            "creditUsagePercent": 36
        ])
        let transport = StubGrokOAuthBillingTransport(result: .success((200, billing)))
        let adapter = GrokOAuthWeeklyUsageAdapter(
            executionCapability: XAIExecutionCapability(isSandboxed: false),
            makeDescriptorLoader: { StubGrokOAuthDescriptorLoader(result: .success(descriptor)) },
            makeTransport: { transport }
        )
        var settings = AppSettings()
        settings.xaiEnabled = true
        _ = settings.setProviderEnabled(.xai, isEnabled: true)
        settings.xAI.experimentalOAuthWeeklyConsentVersion = 1

        let result = await adapter.refresh(
            XAIExperimentalWeeklyInput(
                settings: settings,
                intent: .manual,
                ticket: XAIRefreshTicket(generation: 1),
                now: now
            )
        )

        XCTAssertEqual(result.selectedOutcome, .oauthWeekly)
        XCTAssertNil(result.oauthFailure)
        XCTAssertEqual(result.selectedSnapshot.provenance, .experimentalOAuthWeekly)
        XCTAssertEqual(result.selectedSnapshot.storage.weekly?.usedPercent, 36)
        XCTAssertEqual(transport.callCount(), 1)
    }

    func testMalformedConsentDecodesFailClosedWithoutLosingOtherSettings() throws {
        let data = Data(#"{"xaiEnabled":true,"xAI":{"experimentalOAuthWeeklyConsentVersion":"1","weeklyRemainingPercent":73}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(decoded.xAI.experimentalOAuthWeeklyConsentVersion)
        XCTAssertEqual(decoded.xAI.weeklyRemainingPercent, 73)
    }

    func testLimitHistoryAdmissionExcludesExperimentalOAuthWeeklyAndAcceptsStandard() {
        let suite = "TokenPilotOAuthLimitAdmission-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let key = "limit-samples"
        defaults.removeObject(forKey: key)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LimitHistoryStore(defaults: defaults, key: key)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let standard = ProviderSnapshot(
            provider: .claude,
            updatedAt: now,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 40, confidence: .high),
            confidence: .high,
            dataSource: .officialStatusline
        )
        let oauthWeekly = ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            weekly: LimitWindow(kind: .weekly, usedPercent: 36, confidence: .low),
            confidence: .low,
            dataSource: .experimentalCLI,
            isExperimental: true
        )
        let envelopes = [
            XAIProvenancedSnapshot(standard: standard),
            XAIProvenancedSnapshot(experimentalOAuthWeekly: oauthWeekly, capability: .owned)
        ]

        let result = store.record(
            snapshots: envelopes,
            enabledProviders: [.claude, .xai],
            referenceDate: now
        )

        XCTAssertEqual(result.exclusions, [.excludedExperimentalOAuthWeekly(provider: .xai, sink: .limitHistory)])
        XCTAssertEqual(result.samples.map(\.provider), [.claude])
        XCTAssertFalse(result.samples.contains(where: { $0.provider == .xai }))
        XCTAssertEqual(store.loadSamples().map(\.provider), [.claude])
    }

    func testCapacityEvidenceAdmissionExcludesExperimentalOAuthWeeklyAndAcceptsStandard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenPilotOAuthCapacityAdmission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let store = CapacityEvidenceStore(directory: directory, clock: FixedCapacityClock(now: now))
        let series = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        let standardObservation = try CapacityObservation(
            seriesID: series,
            observedAt: now,
            resetAt: now.addingTimeInterval(3_600),
            value: try CapacityValue(usedPercent: 42),
            authority: .providerReported,
            stability: .supported,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        // Valid series identity used only as payload; provenance, not series, drives exclusion.
        let oauthSeries = try CapacitySeriesID(provider: .codex, providerWindowID: "rolling", kind: .rolling, unit: .percent, durationMinutes: 300)
        let oauthObservation = try CapacityObservation(
            seriesID: oauthSeries,
            observedAt: now,
            resetAt: now.addingTimeInterval(86_400),
            value: try CapacityValue(usedPercent: 36),
            authority: .providerReported,
            stability: .experimentalTransport,
            freshnessPolicy: .init(maximumAge: 900),
            comparability: .comparable,
            parserRevision: "test",
            now: now
        )
        let envelopes = [
            XAIProvenancedObservation(standard: standardObservation),
            XAIProvenancedObservation(experimentalOAuthWeekly: oauthObservation, capability: .owned)
        ]

        let result = await store.record(envelopes)
        let snapshot = await store.loadSnapshot()

        XCTAssertEqual(result.exclusions, [.excludedExperimentalOAuthWeekly(provider: .codex, sink: .capacityEvidence)])
        XCTAssertEqual(result.acceptedCount, 1)
        XCTAssertEqual(snapshot.records.map(\.seriesID.provider), [.claude])
        XCTAssertFalse(snapshot.records.contains(where: { $0.seriesID.provider == .codex }))
    }

    func testNotificationAdmissionExcludesExperimentalOAuthWeeklyAndAcceptsStandard() {
        let suite = "TokenPilotOAuthNotificationAdmission-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = NotificationRuleService(store: AlertDeduplicationStore(defaults: defaults, key: "state"))
        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.alertRules = [
            AlertRule(provider: .claude, window: .fiveHour, eightyEnabled: true),
            AlertRule(provider: .xai, window: .weekly, eightyEnabled: true)
        ]
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let standard = ProviderSnapshot(
            provider: .claude,
            updatedAt: now,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 85, resetAt: now.addingTimeInterval(3_600), confidence: .high),
            confidence: .high,
            dataSource: .officialStatusline
        )
        let oauthWeekly = ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            weekly: LimitWindow(kind: .weekly, usedPercent: 90, resetAt: now.addingTimeInterval(86_400), confidence: .low),
            confidence: .low,
            dataSource: .experimentalCLI,
            isExperimental: true
        )
        let envelopes = [
            XAIProvenancedSnapshot(standard: standard),
            XAIProvenancedSnapshot(experimentalOAuthWeekly: oauthWeekly, capability: .owned)
        ]
        let baseline = ProviderSnapshot(
            provider: .claude,
            updatedAt: now.addingTimeInterval(-60),
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 70, resetAt: now.addingTimeInterval(3_600), confidence: .high),
            confidence: .high,
            dataSource: .officialStatusline
        )
        _ = service.evaluate(
            snapshots: [XAIProvenancedSnapshot(standard: baseline)],
            settings: settings
        )

        let evaluation = service.evaluate(snapshots: envelopes, settings: settings)

        XCTAssertEqual(evaluation.exclusions, [.excludedExperimentalOAuthWeekly(provider: .xai, sink: .notification)])
        XCTAssertEqual(evaluation.events.map(\.provider), [.claude])
        XCTAssertEqual(evaluation.events.map(\.threshold), [.eighty])
        XCTAssertFalse(evaluation.events.contains(where: { $0.provider == .xai }))
    }

    func testSinkAdmissionHelperRejectsOnlyExperimentalOAuthWeekly() {
        let standard = ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 10), confidence: .high, dataSource: .officialStatusline)
        let oauth = ProviderSnapshot(
            provider: .xai,
            weekly: LimitWindow(kind: .weekly, usedPercent: 36, confidence: .low),
            confidence: .low,
            dataSource: .experimentalCLI,
            isExperimental: true
        )
        let admission = XAISinkAdmission.admitSnapshots(
            [
                XAIProvenancedSnapshot(standard: standard),
                XAIProvenancedSnapshot(experimentalOAuthWeekly: oauth, capability: .owned)
            ],
            sink: .limitHistory
        )
        XCTAssertEqual(admission.accepted.map(\.provider), [.claude])
        XCTAssertEqual(admission.exclusions, [.excludedExperimentalOAuthWeekly(provider: .xai, sink: .limitHistory)])
    }
}
final class GrokOAuthRaceFallbackTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_900_000_000)

    func testCredentialExpiredDoesNotCallBillingTransport() async throws {
        let transport = StubGrokOAuthBillingTransport(result: .failure(.billingNetwork))
        let adapter = try makeEligibleAdapter(
            descriptor: expiredDescriptor(),
            transport: transport
        )
        let result = await adapter.refresh(input())
        XCTAssertEqual(result.oauthFailure, .credentialExpired)
        XCTAssertEqual(result.selectedOutcome, .neutral)
        XCTAssertEqual(transport.callCount(), 0)
    }

    func testWrongScopeMissingDoesNotCallBillingTransport() async throws {
        let transport = StubGrokOAuthBillingTransport(result: .failure(.billingNetwork))
        let descriptor = try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::wrong-scope": [
                "access_token": "synthetic-access",
                "expires_at": futureExpiry()
            ]
        ])
        let adapter = try makeEligibleAdapter(descriptor: descriptor, transport: transport)
        let result = await adapter.refresh(input())
        XCTAssertEqual(result.oauthFailure, .selectedScopeMissing)
        XCTAssertEqual(transport.callCount(), 0)
    }

    func testBillingHTTP401IsSingleRequestWithLoginRequired() async throws {
        let transport = StubGrokOAuthBillingTransport(result: .success((401, Data())))
        let adapter = try makeEligibleAdapter(descriptor: validDescriptor(), transport: transport)
        var settings = eligibleSettings()
        settings.xAI.weeklySnapshotEnabled = true
        settings.xAI.weeklyRemainingPercent = 40
        let result = await adapter.refresh(input(settings: settings))
        XCTAssertEqual(result.oauthFailure, .billingHTTP401)
        XCTAssertEqual(result.statusKey, "xai.oauth.status.login_required")
        XCTAssertEqual(result.selectedOutcome, .manualWeekly)
        XCTAssertEqual(result.selectedSnapshot.storage.weekly?.usedPercent, 60)
        XCTAssertEqual(result.selectedSnapshot.provenance, .standard)
        XCTAssertEqual(transport.callCount(), 1)
    }

    func testBillingHTTP403IsSingleRequestWithLoginRequired() async throws {
        let transport = StubGrokOAuthBillingTransport(result: .success((403, Data())))
        let adapter = try makeEligibleAdapter(descriptor: validDescriptor(), transport: transport)
        let result = await adapter.refresh(input())
        XCTAssertEqual(result.oauthFailure, .billingHTTP403)
        XCTAssertEqual(result.statusKey, "xai.oauth.status.login_required")
        XCTAssertEqual(result.selectedOutcome, .neutral)
        XCTAssertEqual(transport.callCount(), 1)
    }

    func testOversizedBillingBodyMapsResponseInvalidWithoutRetry() async throws {
        let oversized = Data(repeating: 0x61, count: GrokOAuthWeeklyUsageAdapter.maximumBillingBodyBytes + 1)
        let transport = StubGrokOAuthBillingTransport(result: .success((200, oversized)))
        let adapter = try makeEligibleAdapter(descriptor: validDescriptor(), transport: transport)
        let result = await adapter.refresh(input())
        XCTAssertEqual(result.oauthFailure, .billingResponseTooLarge)
        XCTAssertEqual(result.statusKey, "xai.oauth.status.response_invalid")
        XCTAssertEqual(transport.callCount(), 1)
    }

    func testMalformedBillingDTOMapsResponseInvalid() async throws {
        let transport = StubGrokOAuthBillingTransport(result: .success((200, Data("not-json".utf8))))
        let adapter = try makeEligibleAdapter(descriptor: validDescriptor(), transport: transport)
        let result = await adapter.refresh(input())
        XCTAssertEqual(result.oauthFailure, .billingDTOInvalid)
        XCTAssertEqual(result.statusKey, "xai.oauth.status.response_invalid")
        XCTAssertEqual(transport.callCount(), 1)
    }

    func testManualFallbackBeatsNeutralOnOAuthFailure() async throws {
        let transport = StubGrokOAuthBillingTransport(result: .success((429, Data())))
        let adapter = try makeEligibleAdapter(descriptor: validDescriptor(), transport: transport)
        var settings = eligibleSettings()
        settings.xAI.weeklySnapshotEnabled = true
        settings.xAI.weeklyRemainingPercent = 25
        let result = await adapter.refresh(input(settings: settings))
        XCTAssertEqual(result.oauthFailure, .billingHTTP429)
        XCTAssertEqual(result.selectedOutcome, .manualWeekly)
        XCTAssertEqual(result.selectedSnapshot.storage.dataSource, .manual)
        XCTAssertEqual(result.selectedSnapshot.storage.weekly?.usedPercent, 75)
        XCTAssertFalse(result.selectedSnapshot.storage.isExperimental)
        XCTAssertEqual(result.selectedSnapshot.provenance, .standard)
    }

    func testRevokeBeforeBillingCompletesYieldsStaleCancelledResult() async throws {
        let gate = GrokOAuthAsyncGate()
        let transport = GatingGrokOAuthBillingTransport(gate: gate, result: .success((200, try validBillingBody())))
        let adapter = try makeEligibleAdapter(descriptor: validDescriptor(), transport: transport)
        let ticket = XAIRefreshTicket(generation: 7)
        let request = input(ticket: ticket)
        async let pending = adapter.refresh(request)
        await gate.waitUntilEntered()
        await adapter.revoke(ticket: ticket)
        gate.open()
        let result = await pending
        XCTAssertEqual(result.oauthFailure, .staleResult)
        XCTAssertEqual(result.completion, .cancelledOrdinarily)
        XCTAssertNotEqual(result.selectedOutcome, .oauthWeekly)
        XCTAssertEqual(transport.callCount(), 1)
    }

    func testUsageStoreDropsStaleResultAfterRevokeAndNeverMergesIntoSnapshots() async throws {
        let gate = GrokOAuthAsyncGate()
        let transport = GatingGrokOAuthBillingTransport(gate: gate, result: .success((200, try validBillingBody())))
        let adapter = try makeEligibleAdapter(descriptor: validDescriptor(), transport: transport)
        let store = UsageStore(
            refreshAdapters: [],
            makeExperimentalWeeklyService: { adapter },
            executionCapability: XAIExecutionCapability(isSandboxed: false)
        )
        let settings = eligibleSettings()
        async let pending = store.refresh(settings: settings, intent: .manual)
        await gate.waitUntilEntered()
        await store.revokeXAIExperimentalWeekly()
        gate.open()
        let result = await pending
        XCTAssertNil(result.xaiOAuthResult)
        XCTAssertFalse(result.snapshots.contains(where: { $0.provider == .xai && $0.dataSource == .experimentalCLI }))
        XCTAssertEqual(transport.callCount(), 1)
    }

    func testUsageStoreFactoryNotConstructedWhenIneligible() async {
        let counter = GrokOAuthFactoryCounter()
        let store = UsageStore(
            refreshAdapters: [],
            makeExperimentalWeeklyService: {
                counter.increment()
                return GrokOAuthWeeklyUsageAdapter(executionCapability: XAIExecutionCapability(isSandboxed: false))
            },
            executionCapability: XAIExecutionCapability(isSandboxed: false)
        )
        var settings = AppSettings()
        settings.xaiEnabled = true
        _ = settings.setProviderEnabled(.xai, isEnabled: true)
        settings.xAI.experimentalOAuthWeeklyConsentVersion = nil
        let result = await store.refresh(settings: settings, intent: .manual)
        XCTAssertNil(result.xaiOAuthResult)
        XCTAssertEqual(counter.current(), 0)
    }

    func testMenuBarIsolationIgnoresOAuthFailureAndCancelledResults() {
        let now = fixedNow
        let failure = XAIRefreshResult(
            selectedOutcome: .manualWeekly,
            selectedSnapshot: XAIProvenancedSnapshot(
                standard: ProviderSnapshot(
                    provider: .xai,
                    updatedAt: now,
                    weekly: LimitWindow(kind: .weekly, usedPercent: 55, confidence: .manual),
                    confidence: .manual,
                    dataSource: .manual
                )
            ),
            oauthFailure: .billingHTTP401,
            statusKey: "xai.oauth.status.login_required",
            actionKey: "xai.oauth.action.run_grok_login",
            fetchedAt: nil,
            resolvedAt: now,
            origin: .fresh,
            completion: .completed
        )
        let cancelled = XAIRefreshResult(
            selectedOutcome: .neutral,
            selectedSnapshot: XAIProvenancedSnapshot(standard: ProviderSnapshot(provider: .xai, updatedAt: now)),
            oauthFailure: .staleResult,
            statusKey: "xai.oauth.status.unavailable",
            actionKey: "xai.oauth.action.refresh",
            fetchedAt: nil,
            resolvedAt: now,
            origin: .fresh,
            completion: .cancelledOrdinarily
        )
        let local = ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            confidence: .medium,
            dataSource: .localLog,
            statusMessage: "LOCAL · Grok Build context window",
            model: "Grok Build",
            contextWindowUsedPercent: 80
        )
        var settings = AppSettings()
        settings.xaiEnabled = true
        _ = settings.setProviderEnabled(.xai, isEnabled: true)
        settings.menuBarDisplayTarget = .xai
        settings.menuBarDisplayStyle = .providerMetrics

        let failureSegments = MenuBarStatusService().providerMetricsSegments(
            snapshots: [local],
            settings: settings,
            now: now,
            xaiOAuthResult: failure
        )
        let cancelledSegments = MenuBarStatusService().providerMetricsSegments(
            snapshots: [local],
            settings: settings,
            now: now,
            xaiOAuthResult: cancelled
        )
        XCTAssertEqual(failureSegments.first?.displayValue, "20%")
        XCTAssertEqual(cancelledSegments.first?.displayValue, "20%")
        XCTAssertFalse(failureSegments.contains(where: { $0.displayValue.contains("55") }))
    }

    // MARK: - Helpers

    private func eligibleSettings() -> AppSettings {
        var settings = AppSettings()
        settings.xaiEnabled = true
        _ = settings.setProviderEnabled(.xai, isEnabled: true)
        settings.xAI.experimentalOAuthWeeklyConsentVersion = 1
        return settings
    }

    private func input(
        settings: AppSettings? = nil,
        ticket: XAIRefreshTicket = XAIRefreshTicket(generation: 1)
    ) -> XAIExperimentalWeeklyInput {
        XAIExperimentalWeeklyInput(
            settings: settings ?? eligibleSettings(),
            intent: .manual,
            ticket: ticket,
            now: fixedNow
        )
    }

    private func makeEligibleAdapter(
        descriptor: Data,
        transport: any GrokOAuthBillingTransporting
    ) throws -> GrokOAuthWeeklyUsageAdapter {
        GrokOAuthWeeklyUsageAdapter(
            executionCapability: XAIExecutionCapability(isSandboxed: false),
            makeDescriptorLoader: { StubGrokOAuthDescriptorLoader(result: .success(descriptor)) },
            makeTransport: { transport }
        )
    }

    private func futureExpiry() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: fixedNow.addingTimeInterval(86_400))
    }

    private func validDescriptor() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            GrokOAuthWeeklyUsageAdapter.selectedScopeKey: [
                "access_token": "synthetic-access",
                "expires_at": futureExpiry(),
                "auth_mode": "oidc",
                "oidc_issuer": "https://auth.x.ai",
                "oidc_client_id": "b1a00492-073a-47ea-816f-4c329264a828"
            ]
        ])
    }

    private func expiredDescriptor() throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let past = formatter.string(from: fixedNow.addingTimeInterval(-60))
        return try JSONSerialization.data(withJSONObject: [
            GrokOAuthWeeklyUsageAdapter.selectedScopeKey: [
                "access_token": "synthetic-access",
                "expires_at": past,
                "auth_mode": "oidc",
                "oidc_issuer": "https://auth.x.ai",
                "oidc_client_id": "b1a00492-073a-47ea-816f-4c329264a828"
            ]
        ])
    }

    private func validBillingBody() throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let start = formatter.string(from: fixedNow.addingTimeInterval(-86_400))
        let end = formatter.string(from: fixedNow.addingTimeInterval(6 * 86_400))
        return try JSONSerialization.data(withJSONObject: [
            "config": ["isUnifiedBillingUser": true],
            "currentPeriod": [
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": start,
                "end": end
            ],
            "creditUsagePercent": 36
        ])
    }
}

private final class GrokOAuthAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var opened = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if entered {
                    return true
                }
                enterWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func waitUntilOpened() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if opened {
                    return true
                }
                openWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func markEntered() {
        let waiters = lock.withLock {
            entered = true
            let waiters = enterWaiters
            enterWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func open() {
        let waiters = lock.withLock {
            opened = true
            let waiters = openWaiters
            openWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class GatingGrokOAuthBillingTransport: GrokOAuthBillingTransporting, @unchecked Sendable {
    private let gate: GrokOAuthAsyncGate
    private let result: Result<(statusCode: Int, body: Data), XAIUnavailableReason>
    private let lock = NSLock()
    private var calls = 0

    init(gate: GrokOAuthAsyncGate, result: Result<(statusCode: Int, body: Data), XAIUnavailableReason>) {
        self.gate = gate
        self.result = result
    }

    func fetchWeeklyBilling(accessToken: String) async -> Result<(statusCode: Int, body: Data), XAIUnavailableReason> {
        XCTAssertEqual(accessToken, "synthetic-access")
        lock.withLock {
            calls += 1
        }
        gate.markEntered()
        await gate.waitUntilOpened()
        return result
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
