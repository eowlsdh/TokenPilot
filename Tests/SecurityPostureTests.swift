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
