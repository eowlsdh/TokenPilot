import XCTest

final class SecurityPostureTests: XCTestCase {
    func testGitleaksConfigKeepsDefaultRulesAndNarrowsHistoricalFalsePositive() throws {
        let config = try String(contentsOf: Self.projectRootURL().appendingPathComponent(".gitleaks.toml"))

        XCTAssertTrue(config.contains("useDefault = true"))
        XCTAssertTrue(config.contains("e431acb604693d83c9bebd5471c8b87a9c6a5a91"))
        XCTAssertTrue(config.contains("COMPLETION_REPORT"))
        XCTAssertFalse(config.contains(".*"))
    }

    func testAppStoreEntitlementsEnableSandboxWithoutChangingDefaultProfile() throws {
        let root = Self.projectRootURL()
        let defaultEntitlements = try Self.plistDictionary(at: root.appendingPathComponent("Resources/TokenPilot.entitlements"))
        let appStoreEntitlements = try Self.plistDictionary(at: root.appendingPathComponent("Resources/TokenPilot-AppStore.entitlements"))

        XCTAssertNil(defaultEntitlements["com.apple.security.app-sandbox"])
        XCTAssertEqual(appStoreEntitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(appStoreEntitlements["com.apple.security.files.user-selected.read-only"] as? Bool, true)
        XCTAssertEqual(appStoreEntitlements["com.apple.security.network.client"] as? Bool, true)
    }

    func testSecurityDocsTreatTelegramRequestURLsAsSecretBearing() throws {
        let root = Self.projectRootURL()
        let security = try String(contentsOf: root.appendingPathComponent("SECURITY.md"))
        let privacy = try String(contentsOf: root.appendingPathComponent("docs/PRIVACY.md"))

        XCTAssertTrue(security.contains("Telegram Bot API endpoints include the bot token in the URL path"))
        XCTAssertTrue(security.contains("must not log, export, persist, proxy-debug, or surface full Telegram request URLs"))
        XCTAssertTrue(privacy.contains("Telegram's Bot API places the bot token in the request URL path"))
        XCTAssertTrue(privacy.contains("never be logged, exported, proxied for debugging, or shown"))
    }

    func testGrokLocalSignalsDocsStayTruthfulAndCredentialFree() throws {
        let root = Self.projectRootURL()
        let documentationPaths = [
            "README.md",
            "README.ko.md",
            "README.ja.md",
            "README.zh-CN.md",
            "SETTINGS_GUIDE.md",
            "SECURITY.md",
            "docs/PRIVACY.md"
        ]
        let forbiddenClaims = [
            "https://api.x.ai",
            "http://api.x.ai",
            "api.x.ai",
            "console.x.ai",
            "x.ai/api",
            "/v1/usage",
            "/v1/billing",
            "/v1/teams",
            "supports live xAI billing",
            "supports Grok web subscription",
            "validates xAI credentials"
        ]

        for path in documentationPaths {
            let document = try String(contentsOf: root.appendingPathComponent(path))
            for claim in forbiddenClaims {
                XCTAssertFalse(document.localizedCaseInsensitiveContains(claim), "\(path) should not claim a live xAI endpoint or capability: \(claim)")
            }
            XCTAssertTrue(document.localizedCaseInsensitiveContains("signals.json"), "\(path) should document the bounded Grok local-signals source.")
            XCTAssertTrue(document.localizedCaseInsensitiveContains("auth.json"), "\(path) should state that Grok authentication files are excluded.")
        }

        for path in ["README.md", "README.ko.md", "README.ja.md", "README.zh-CN.md"] {
            let readme = try String(contentsOf: root.appendingPathComponent(path))
            XCTAssertTrue(readme.localizedCaseInsensitiveContains("grok"), "\(path) should document Grok local context.")
            XCTAssertTrue(readme.localizedCaseInsensitiveContains("xai"), "\(path) should identify the xAI provider.")
            XCTAssertTrue(readme.localizedCaseInsensitiveContains("oauth"), "\(path) should state that OAuth tokens are excluded.")
            XCTAssertTrue(readme.localizedCaseInsensitiveContains("contextWindowUsage"), "\(path) should identify the numeric local-context basis.")
            XCTAssertFalse(readme.localizedCaseInsensitiveContains("live xAI billing is supported"))
            XCTAssertFalse(readme.localizedCaseInsensitiveContains("Grok web subscription tracking is supported"))
        }

        let settings = try String(contentsOf: root.appendingPathComponent("SETTINGS_GUIDE.md"))
        let security = try String(contentsOf: root.appendingPathComponent("SECURITY.md"))
        let privacy = try String(contentsOf: root.appendingPathComponent("docs/PRIVACY.md"))

        XCTAssertTrue(settings.contains("파일명은 정확히 `signals.json`이어야 합니다"))
        XCTAssertTrue(settings.contains("symlink는 거부합니다"))
        XCTAssertTrue(settings.contains("최대 256 KiB"))
        XCTAssertTrue(security.contains("it does not ingest prompts, responses, credentials, or other session content"))
        XCTAssertTrue(security.contains("not provider quota, subscription quota, or API billing data"))
        XCTAssertTrue(privacy.contains("rejects symlinks"))
        XCTAssertTrue(privacy.contains("parses only numeric context fields"))
    }

    func testGitignoreRejectsXAILocalCredentialsAndResponses() throws {
        let ignore = try String(contentsOf: Self.projectRootURL().appendingPathComponent(".gitignore"))

        XCTAssertTrue(ignore.contains("xai-api-key*"))
        XCTAssertTrue(ignore.contains("xai-management-key*"))
        XCTAssertTrue(ignore.contains("xai-response*.json"))
    }

    private static func projectRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func plistDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }
}
