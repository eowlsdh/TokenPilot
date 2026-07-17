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

    func testXAINoNetworkFoundationDocsStayTruthfulAndEndpointFree() throws {
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
        }

        for path in documentationPaths {
            let document = try String(contentsOf: root.appendingPathComponent(path))
            XCTAssertTrue(document.localizedCaseInsensitiveContains("team id"), "\(path) should document the xAI team-ID privacy boundary.")
            XCTAssertTrue(
                document.localizedCaseInsensitiveContains("masked") ||
                    document.localizedCaseInsensitiveContains("presence-only") ||
                    document.contains("마스킹"),
                "\(path) should promise masked or presence-only xAI team-ID display."
            )
        }

        for path in ["README.md", "README.ko.md", "README.ja.md", "README.zh-CN.md"] {
            let readme = try String(contentsOf: root.appendingPathComponent(path))
            XCTAssertTrue(readme.localizedCaseInsensitiveContains("grok"), "\(path) should document Grok/xAI setup.")
            XCTAssertTrue(readme.localizedCaseInsensitiveContains("xai"), "\(path) should document xAI setup.")
            XCTAssertTrue(readme.localizedCaseInsensitiveContains("auth-unconfirmed"), "\(path) should keep Management authentication unconfirmed.")
            XCTAssertTrue(readme.localizedCaseInsensitiveContains("xai http"), "\(path) should document the no-network xAI policy.")
            XCTAssertTrue(readme.contains("0") || readme.localizedCaseInsensitiveContains("zero"), "\(path) should state zero xAI HTTP requests.")
            XCTAssertFalse(readme.localizedCaseInsensitiveContains("live xAI billing is supported"))
            XCTAssertFalse(readme.localizedCaseInsensitiveContains("Grok web subscription tracking is supported"))
        }

        let security = try String(contentsOf: root.appendingPathComponent("SECURITY.md"))
        let privacy = try String(contentsOf: root.appendingPathComponent("docs/PRIVACY.md"))

        XCTAssertTrue(security.contains("saving setup values must not trigger xAI HTTP requests"))
        XCTAssertTrue(security.contains("production code must not call xAI endpoints"))
        XCTAssertTrue(security.contains("must not claim live xAI billing or Grok web subscription limit support"))
        XCTAssertTrue(privacy.contains("sends no xAI HTTP requests in production"))
        XCTAssertTrue(privacy.contains("does not claim live xAI billing support"))
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
