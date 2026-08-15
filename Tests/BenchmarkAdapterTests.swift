import XCTest
@testable import TokenCore

final class JetBrainsQuotaParserTests: XCTestCase {
    func testParsesQuotaInfoAndNextRefill() throws {
        let xml = """
        <component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="{&quot;maximum&quot;: 1000000.0, &quot;current&quot;: 250000.0, &quot;available&quot;: 750000.0, &quot;until&quot;: &quot;2026-08-20T00:00:00Z&quot;}" />
          <option name="nextRefill" value="{&quot;refillDate&quot;: &quot;2026-08-20T00:00:00Z&quot;}" />
        </component>
        """
        let quota = JetBrainsQuotaParser().parse(xml: Data(xml.utf8))
        XCTAssertEqual(quota?.usedPercent, 25)
        XCTAssertNotNil(quota?.resetAt)
    }

    func testClampsUsedBeyondMaximum() throws {
        let xml = """
        <component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="{&quot;maximum&quot;: 1000.0, &quot;current&quot;: 5000.0}" />
        </component>
        """
        let quota = JetBrainsQuotaParser().parse(xml: Data(xml.utf8))
        XCTAssertEqual(quota?.usedPercent, 100)
    }

    func testRejectsMissingQuotaInfo() throws {
        let xml = "<component name=\"AIAssistantQuotaManager2\"></component>"
        XCTAssertNil(JetBrainsQuotaParser().parse(xml: Data(xml.utf8)))
    }
}

final class MiniMaxTokenPlanParserTests: XCTestCase {
    func testParsesLowestRemainingPercentAcrossModels() throws {
        let payload: [String: Any] = [
            "model_remains": [
                ["model_name": "MiniMax-M2.7", "current_interval_remaining_percent": 70],
                ["model_name": "MiniMax-M2.5", "current_interval_remaining_percent": 40]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reading = MiniMaxTokenPlanParser().parse(data)
        XCTAssertEqual(reading?.usedPercent, 60, "lowest remaining (40%) means 60% used")
    }

    func testRejectsEmptyModelRemains() throws {
        let data = try JSONSerialization.data(withJSONObject: ["model_remains": []])
        XCTAssertNil(MiniMaxTokenPlanParser().parse(data))
    }

    func testClampsPercent() throws {
        let payload: [String: Any] = [
            "model_remains": [["current_interval_remaining_percent": -5]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(MiniMaxTokenPlanParser().parse(data)?.usedPercent, 100)
    }
}

final class ZAIQuotaParserTests: XCTestCase {
    func testParsesTokensLimitPercentage() throws {
        let payload: [String: Any] = [
            "limits": [
                ["type": "WEB_SEARCH_LIMIT", "percentage": 10],
                ["type": "TOKENS_LIMIT", "percentage": 42, "nextResetTime": "2026-08-20T00:00:00Z"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reading = ZAIQuotaParser().parse(data)
        XCTAssertEqual(reading?.usedPercent, 42)
        XCTAssertNotNil(reading?.resetAt)
    }

    func testRejectsMissingTokensLimit() throws {
        let payload: [String: Any] = ["limits": [["type": "WEB_SEARCH_LIMIT", "percentage": 10]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertNil(ZAIQuotaParser().parse(data))
    }
}

final class OpenRouterUsageParserTests: XCTestCase {
    func testParsesSpendMeter() throws {
        let payload: [String: Any] = [
            "total_credits": 100.0,
            "total_usage": 25.0
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(OpenRouterUsageParser().parseCredits(data)?.usedPercent, 25)
    }

    func testRejectsMissingCeiling() throws {
        let payload: [String: Any] = ["total_usage": 25.0]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertNil(OpenRouterUsageParser().parseCredits(data))
    }

    func testClampsUsageOverCredits() throws {
        let payload: [String: Any] = [
            "total_credits": 50.0,
            "total_usage": 75.0
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(OpenRouterUsageParser().parseCredits(data)?.usedPercent, 100)
    }
}

final class BenchmarkProviderEnablementTests: XCTestCase {
    func testNewProvidersDefaultOffAndEnableable() {
        var settings = AppSettings()
        XCTAssertFalse(settings.jetbrainsEnabled)
        XCTAssertFalse(settings.minimaxEnabled)
        XCTAssertFalse(settings.zaiEnabled)
        XCTAssertFalse(settings.openrouterEnabled)

        settings.setProviderEnabled(.minimax, isEnabled: true)
        XCTAssertTrue(settings.isProviderEnabled(.minimax))
        settings.setProviderEnabled(.jetbrains, isEnabled: true)
        XCTAssertTrue(settings.isProviderEnabled(.jetbrains))
    }

    func testDisabledProviderAdaptersReportDisabled() async {
        let settings = AppSettings()
        let adapters: [any ProviderRefreshAdapter] = [
            JetBrainsAIAssistantAdapter(),
            MiniMaxTokenPlanAdapter(),
            ZAIUsageAdapter(),
            OpenRouterAdapter()
        ]
        for adapter in adapters {
            let result = await adapter.refresh(settings: settings, now: Date())
            XCTAssertEqual(result.snapshot.statusMessage, "Disabled")
            XCTAssertTrue(result.typedErrors.contains { $0.category == .disabled })
        }
    }
}

final class ClaudeOAuthUsageParserTests: XCTestCase {
    func testParsesFiveHourAndSevenDayWindows() throws {
        let payload: [String: Any] = [
            "five_hour": ["utilization": 25, "resets_at": "2026-08-20T00:00:00Z"],
            "seven_day": ["utilization": 40, "resets_at": "2026-08-25T00:00:00Z"]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reading = ClaudeOAuthUsageParser().parse(data)
        XCTAssertEqual(reading?.fiveHourUsedPercent, 25)
        XCTAssertEqual(reading?.sevenDayUsedPercent, 40)
        XCTAssertNotNil(reading?.fiveHourResetAt)
        XCTAssertNotNil(reading?.sevenDayResetAt)
    }

    func testRejectsEmptyPayload() throws {
        let data = try JSONSerialization.data(withJSONObject: [String: Any]())
        XCTAssertNil(ClaudeOAuthUsageParser().parse(data))
    }
}

final class CodexOAuthUsageParserTests: XCTestCase {
    func testParsesPrimaryAndSecondaryWindows() throws {
        let payload: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 6, "reset_at": 1_800_000_000],
                "secondary_window": ["used_percent": 24, "reset_at": 1_800_000_000]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reading = CodexOAuthUsageParser().parse(data)
        XCTAssertEqual(reading?.fiveHourUsedPercent, 6)
        XCTAssertEqual(reading?.sevenDayUsedPercent, 24)
        XCTAssertNotNil(reading?.fiveHourResetAt)
    }

    func testRejectsMissingRateLimit() throws {
        let data = try JSONSerialization.data(withJSONObject: [String: Any]())
        XCTAssertNil(CodexOAuthUsageParser().parse(data))
    }
}

final class GrokTierParserTests: XCTestCase {
    func testParsesSubscriptionTierDisplay() throws {
        let payload: [String: Any] = ["subscription_tier_display": "SuperGrok"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(GrokTierParser().parse(data), "SuperGrok")
    }

    func testRejectsMissingTier() throws {
        let data = try JSONSerialization.data(withJSONObject: ["other": "x"])
        XCTAssertNil(GrokTierParser().parse(data))
    }
}

final class ExperimentalCredentialLoaderTests: XCTestCase {
    func testClaudeLoaderReadsOnlyAccessToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".credentials.json")
        let payload: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "sk-ant-test-token",
                "refreshToken": "rt-secret",
                "expiresAt": 1_800_000_000
            ]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        let loader = LocalClaudeCredentialLoader(fileURL: file)
        XCTAssertEqual(try loader.loadAccessToken().get(), "sk-ant-test-token")
    }

    func testCodexLoaderReadsOnlyAccessToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("auth.json")
        let payload: [String: Any] = [
            "tokens": [
                "access_token": "sk-codex-test",
                "refresh_token": "rt-secret",
                "account_id": "acct-1"
            ],
            "OPENAI_API_KEY": "sk-legacy"
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        let loader = LocalCodexCredentialLoader(fileURL: file)
        XCTAssertEqual(try loader.loadAccessToken().get(), "sk-codex-test")
    }

    func testGrokLoaderReadsOnlyAccessToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("auth.json")
        let payload: [String: Any] = [
            "access_token": "grok-test-token",
            "refresh_token": "rt-secret"
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        let loader = LocalGrokTierCredentialLoader(fileURL: file)
        XCTAssertEqual(try loader.loadAccessToken().get(), "grok-test-token")
    }
}

final class ExperimentalConsentTests: XCTestCase {
    func testExperimentalUsageSettingsDefaultOff() {
        let settings = AppSettings()
        XCTAssertFalse(settings.claudeUsageProbeEnabled)
        XCTAssertFalse(settings.codexUsageProbeEnabled)
        XCTAssertFalse(settings.grokTierProbeEnabled)
    }

    func testConsentVersionRoundTrip() throws {
        var settings = AppSettings()
        settings.experimentalUsage = ExperimentalUsageSettings(
            claudeConsentVersion: ExperimentalUsageSettings.claudeConsentVersionCurrent,
            codexConsentVersion: nil,
            grokTierConsentVersion: ExperimentalUsageSettings.grokTierConsentVersionCurrent
        )
        let data = try JSONEncoder().encode(settings.experimentalUsage)
        let decoded = try JSONDecoder().decode(ExperimentalUsageSettings.self, from: data)
        XCTAssertTrue(decoded.claudeProbeEnabled)
        XCTAssertFalse(decoded.codexProbeEnabled)
        XCTAssertTrue(decoded.grokTierProbeEnabled)
    }
}
