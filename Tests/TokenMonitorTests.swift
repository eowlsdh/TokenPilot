import XCTest
@testable import TokenCore

final class TokenMonitorTests: XCTestCase {
    func testUsageEventClampsNegativeTokenValues() {
        let event = UsageEvent(
            provider: .claude,
            inputTokens: -10,
            outputTokens: 20,
            cacheReadTokens: -5,
            cacheCreationTokens: 3,
            requestCount: -1,
            source: "test"
        )

        XCTAssertEqual(event.inputTokens, 0)
        XCTAssertEqual(event.outputTokens, 20)
        XCTAssertEqual(event.cacheReadTokens, 0)
        XCTAssertEqual(event.cacheCreationTokens, 3)
        XCTAssertEqual(event.requestCount, 0)
        XCTAssertEqual(event.totalTokens, 23)
    }

    func testUsageEventUsesOfficialTotalOverrideEvenWhenComponentsAreHigher() {
        let event = UsageEvent(
            provider: .codex,
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 1_000,
            reasoningTokens: 5,
            source: "test",
            totalTokensOverride: 125
        )

        XCTAssertEqual(event.totalTokens, 125)
    }

    func testLimitWindowPercentClamping() {
        XCTAssertEqual(LimitWindow(kind: .fiveHour, usedPercent: 150).usedPercent, 100)
        XCTAssertEqual(LimitWindow(kind: .weekly, usedPercent: -50).usedPercent, 0)
        XCTAssertEqual(LimitWindow(kind: .dailyRequests, usedPercent: 45).usedPercent, 45)
    }

    func testProviderSnapshotDailyRequestPercent() {
        let snapshot = ProviderSnapshot(
            provider: .gemini,
            dailyRequestsUsed: 250,
            dailyRequestsLimit: 1_000
        )

        XCTAssertEqual(snapshot.dailyRequestsPercent, 25)
    }

    func testProviderSnapshotPrimaryRiskPrefersFiveHourThenDailyThenWeekly() {
        let claude = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 82),
            weekly: LimitWindow(kind: .weekly, usedPercent: 47)
        )
        let gemini = ProviderSnapshot(
            provider: .gemini,
            weekly: LimitWindow(kind: .weekly, usedPercent: 99),
            dailyRequestsUsed: 210,
            dailyRequestsLimit: 1_000
        )

        XCTAssertEqual(claude.primaryUsedPercent, 82)
        XCTAssertEqual(gemini.primaryUsedPercent, 21)
    }

    func testCompactNumberFormatter() {
        XCTAssertEqual(TokenPilotFormatters.compactNumber(500), "500")
        XCTAssertEqual(TokenPilotFormatters.compactNumber(1_500), "1.5K")
        XCTAssertEqual(TokenPilotFormatters.compactNumber(1_000), "1K")
        XCTAssertEqual(TokenPilotFormatters.compactNumber(1_000_000), "1M")
    }

    func testDefaultAlertRulesCoverMVPProvidersAndWindows() {
        let rules = AppSettings.defaultAlertRules
        XCTAssertTrue(rules.contains { $0.provider == .claude && $0.window == .fiveHour })
        XCTAssertTrue(rules.contains { $0.provider == .claude && $0.window == .weekly })
        XCTAssertTrue(rules.contains { $0.provider == .codex && $0.window == .fiveHour })
        XCTAssertTrue(rules.contains { $0.provider == .codex && $0.window == .weekly })
        XCTAssertTrue(rules.contains { $0.provider == .gemini && $0.window == .dailyRequests })
        XCTAssertTrue(rules.allSatisfy(\.resetEnabled))
        XCTAssertTrue(rules.allSatisfy { !$0.fiftyEnabled })
        XCTAssertTrue(rules.allSatisfy(\.eightyEnabled))
        XCTAssertTrue(rules.allSatisfy(\.hundredEnabled))
        XCTAssertTrue(rules.allSatisfy { !$0.telegramEnabled })
    }

    func testMenuBarTitleShowsFiveHourAndWeeklyRemainingPercentages() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 82, resetAt: now.addingTimeInterval(7_200)),
            weekly: LimitWindow(kind: .weekly, usedPercent: 47, resetAt: now.addingTimeInterval(18_720))
        )
        var settings = AppSettings()
        settings.localization.language = .ko

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: now
        )

        XCTAssertEqual(title, "5h 18% · W 53%")
    }

    func testMenuBarTitleFallsBackToDataUnavailableWhenWindowPercentMissing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: nil, resetAt: now.addingTimeInterval(7_200)),
            weekly: LimitWindow(kind: .weekly, usedPercent: nil, resetAt: now.addingTimeInterval(18_720))
        )
        var settings = AppSettings()
        settings.localization.language = .ko

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: now
        )

        XCTAssertEqual(title, "5h 데이터 없음 · W 데이터 없음")
    }

    func testMenuBarTitleShowsOnlyValidWeeklyWhenFiveHourUnavailable() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ProviderSnapshot(
            provider: .codex,
            weekly: LimitWindow(kind: .weekly, usedPercent: 32, resetAt: now.addingTimeInterval(18_720)),
            confidence: .high,
            dataSource: .webUsage,
            isExperimental: true,
            statusMessage: "UNOFFICIAL · Codex app-server limit hints"
        )
        var settings = AppSettings()
        settings.localization.language = .ko
        settings.menuBarDisplayTarget = .codex

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: now
        )

        XCTAssertEqual(title, "W 68%")
    }

    func testMenuBarTitleDoesNotShowHealthyQuotaWhenCodexLimitWindowsUnavailable() {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            confidence: .low,
            dataSource: .webUsage,
            isExperimental: true,
            statusMessage: "Codex app-server limit hints rate limits unavailable"
        )
        var settings = AppSettings()
        settings.localization.language = .ko
        settings.menuBarDisplayTarget = .codex

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: Date(timeIntervalSince1970: 1_000_000)
        )

        XCTAssertEqual(title, "Co · LIVE")
        XCTAssertFalse(title.contains("100%"))
        XCTAssertFalse(title.contains("0%"))
    }

    func testMenuBarTitleUsesSelectedCodexManualValuesBeforeNextRefresh() {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            todayTokens: 4_800,
            confidence: .low,
            dataSource: .webUsage,
            isExperimental: true,
            statusMessage: "Codex app-server limit hints rate limits unavailable"
        )
        var settings = AppSettings()
        settings.localization.language = .ko
        settings.menuBarDisplayTarget = .codex
        settings.codexManual.fiveHourUsagePercentage = 74
        settings.codexManual.weeklyUsagePercentage = 20

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: Date(timeIntervalSince1970: 1_000_000)
        )

        XCTAssertEqual(title, "5h 26% · W 80% 추정")
    }

    func testMenuBarTitleLocalizesTokenUnitFallback() {
        var settings = AppSettings()
        settings.localization.language = .ko
        let snapshot = ProviderSnapshot(provider: .claude, todayTokens: 12_000)

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE"
        )

        XCTAssertEqual(title, "Cl 12K토큰")
    }

    func testMenuBarStatusDotOnlyAppearsForWarningOrCriticalRisk() {
        var settings = AppSettings()
        let service = MenuBarStatusService()
        let normal = ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 52))
        let warning = ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 70))
        let critical = ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 85))

        XCTAssertEqual(service.statusLevel(snapshots: [normal], settings: settings), .normal)
        XCTAssertEqual(service.statusLevel(snapshots: [warning], settings: settings), .warning)
        XCTAssertEqual(service.statusLevel(snapshots: [critical], settings: settings), .critical)
        XCTAssertFalse(service.shouldShowStatusDot(snapshots: [normal], settings: settings))
        XCTAssertTrue(service.shouldShowStatusDot(snapshots: [warning], settings: settings))
        XCTAssertTrue(service.shouldShowStatusDot(snapshots: [critical], settings: settings))

        settings.claudeEnabled = false
        settings.normalizeProviderEnablement()
        XCTAssertEqual(service.statusLevel(snapshots: [critical], settings: settings), .normal)
    }

    func testDataSourceSettingsCopyHasKoreanFallbacks() {
        XCTAssertEqual(
            TokenPilotLocalizer.localized("Auto-detect sources", language: .ko),
            "소스 자동 감지"
        )
        XCTAssertEqual(
            TokenPilotLocalizer.localized("Scans only local default paths and user-selected files.", language: .ko),
            "로컬 기본 경로와 사용자가 선택한 파일만 확인합니다."
        )
        XCTAssertEqual(
            TokenPilotLocalizer.localized("Toggle providers shown on Overview. Disabled providers are hidden and not refreshed.", language: .ko),
            "개요에 표시할 제공자를 선택합니다. 꺼진 제공자는 숨기고 새로고침하지 않지만 데이터는 삭제하지 않습니다."
        )
    }

    func testExportPrivacyCopyClarifiesUsageTotalsAreIncludedButSecretsAreExcluded() {
        let copy = TokenPilotLocalizer.localized(
            "Exports the selected History period only. Credentials, tokens, chat IDs, webhooks, and local file paths are not included.",
            language: .ko
        )

        XCTAssertTrue(copy.contains("선택한 기록 사용량"))
        XCTAssertTrue(copy.contains("제공자 요약"))
        XCTAssertTrue(copy.contains("비밀 토큰"))
        XCTAssertTrue(copy.contains("원문 프롬프트/응답 본문"))
    }

    func testCodexPublicPositioningCopyFramesConnectorAsLimitHints() {
        XCTAssertEqual(
            TokenPilotLocalizer.localized("Limit Hints Connector", language: .ko),
            "Codex 한도 힌트 커넥터"
        )

        let connectorCopy = TokenPilotLocalizer.localized(
            "Asks the local Codex CLI app-server for account/rateLimits/read. TokenPilot does not read, store, display, or export Codex access tokens.",
            language: .ko
        )
        XCTAssertTrue(connectorCopy.contains("Codex CLI app-server"))
        XCTAssertTrue(connectorCopy.contains("읽거나 저장하거나 표시하거나 내보내지 않습니다"))

        let warningCopy = TokenPilotLocalizer.localized(
            "Codex app-server limit hints are unofficial and may break if the Codex CLI changes. Disable to fall back to local activity/manual values.",
            language: .ko
        )
        XCTAssertTrue(warningCopy.contains("공식 한도 보장값이 아닌 힌트"))

        let privacyCopy = TokenPilotLocalizer.localized(
            "Codex Limit Hints Connector is opt-in and asks the local Codex CLI app-server for account/rateLimits/read; TokenPilot never reads, displays, or stores Codex access tokens.",
            language: .ko
        )
        XCTAssertTrue(privacyCopy.contains("기본 꺼짐"))
        XCTAssertTrue(privacyCopy.contains("Codex CLI app-server"))
        XCTAssertFalse(privacyCopy.localizedCaseInsensitiveContains("wham"))
        XCTAssertFalse(privacyCopy.localizedCaseInsensitiveContains("auth.json"))
    }

    func testSamplePreviewCopyFramesMockDataAsOptional() {
        XCTAssertEqual(
            TokenPilotLocalizer.localized("Preview sample data when no source is connected", language: .ko),
            "소스가 연결되지 않았을 때 샘플 데이터 미리보기"
        )

        let copy = TokenPilotLocalizer.localized(
            "Sample preview is optional and off by default so release builds never look connected before setup.",
            language: .ko
        )
        XCTAssertTrue(copy.contains("선택 사항"))
        XCTAssertTrue(copy.contains("기본 꺼짐"))
        XCTAssertTrue(copy.contains("연결된 것처럼"))
    }

    func testOverviewDoesNotShowToolRecommendationCard() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertFalse(source.contains("BestToolCard("))
        XCTAssertFalse(source.contains("struct BestToolCard"))
        XCTAssertFalse(source.contains("localized(\"Lowest current usage\""))
        XCTAssertFalse(source.contains("localized(\"Best tool now\""))
    }

    func testFilePickerStoresSecurityScopedBookmarksForAppStoreSandboxReadiness() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("TokenPilotSecurityScopedBookmarks.makeReadOnlyBookmarkData"))
        XCTAssertTrue(source.contains("claudeStatusFileBookmarkData"))
        XCTAssertTrue(source.contains("geminiTelemetrySourceBookmarkData"))
    }

    func testMenuBarRunsLiveRefreshWithoutWaitingForPopoverOpen() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("private let menuBarTickInterval: TimeInterval = 1"))
        XCTAssertTrue(source.contains("private let dataRefreshInterval: TimeInterval = 5"))
        XCTAssertTrue(source.contains("RunLoop.main.add(timer, forMode: .common)"))
        XCTAssertTrue(source.contains("await refresh(reason: .automaticTimer)"))
        XCTAssertFalse(source.contains("Timer.scheduledTimer(withTimeInterval: menuBarTickInterval"))
    }

    func testProviderMarksUseCustomAnimatedBrandSystem() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("struct ProviderSignatureMark"))
        XCTAssertTrue(source.contains("withAnimation(.spring"))
        XCTAssertTrue(source.contains("ProviderSetupCard("))
        XCTAssertTrue(source.contains("TokenPilotBrandMark"))
        XCTAssertFalse(source.contains("ProviderMark(provider: snapshot.provider)"))
    }

    func testSettingsDataSourcesAreSplitIntoProviderCards() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("ProviderSetupCard(provider: .claude"))
        XCTAssertTrue(source.contains("ProviderSetupCard(provider: .codex"))
        XCTAssertTrue(source.contains("ProviderSetupCard(provider: .gemini"))
        XCTAssertTrue(source.contains("ProviderSetupCard(provider: .deepseek"))
        XCTAssertTrue(source.contains("Use Manual DeepSeek Balance"))
        XCTAssertFalse(source.contains("Divider().padding(.vertical, 4)"))
    }

    func testAntigravitySetupSnippetInstallsPrivacySafeStatuslineBridge() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("statusLine"))
        XCTAssertTrue(source.contains("antigravity-statusline.json"))
        XCTAssertTrue(source.contains("antigravity-statusline-writer.py"))
        XCTAssertTrue(source.contains("safe_text"))
        XCTAssertTrue(source.contains("safe_int"))
        XCTAssertTrue(source.contains("except FileNotFoundError"))
        XCTAssertTrue(source.contains("TokenPilot could not parse"))
        XCTAssertFalse(source.contains("\"outfile\": \"~/.gemini/telemetry.log\""))
        XCTAssertFalse(source.contains("\"log_file\""))
        XCTAssertFalse(source.contains("\"email\""))
        XCTAssertFalse(source.contains("\"plan_tier\""))
        XCTAssertFalse(source.contains("\"cwd\""))
        XCTAssertFalse(source.contains("\"workspace\""))
    }

    func testSettingsShowsProviderDiagnosticsMVPWithoutRawPathSummary() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("Provider Diagnostics"))
        XCTAssertTrue(source.contains("model.providerDiagnostics"))
        XCTAssertTrue(source.contains("Check all providers"))
        XCTAssertTrue(source.contains("Before diagnostics, TokenPilot checks local usage metadata"))
        XCTAssertTrue(source.contains("ProviderConnectionDiagnostic"))
        XCTAssertTrue(source.contains("diagnosticNextActionText"))
        XCTAssertTrue(source.contains("updateDeepSeekDataSourceForCredentialState()"))
    }

    func testOverviewAndHistoryEmptyStatesLinkToProviderDiagnostics() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("Run Provider Diagnostics in Settings to connect Claude, Codex, or Antigravity."))
        XCTAssertTrue(source.contains("Open Provider Diagnostics"))
        XCTAssertTrue(source.contains("model.selectedScreen = .settings"))
        XCTAssertTrue(source.contains("HistoryEmptyState("))
    }

    func testHistoryScreenShowsLimitSignalsAndHelpfulEmptyState() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("@Published var limitHistorySamples"))
        XCTAssertTrue(source.contains("HistoryLimitSignalCard(samples: model.limitHistorySamples"))
        XCTAssertTrue(source.contains("HistoryEmptyState("))
        XCTAssertTrue(source.contains("No token event history yet"))
        XCTAssertTrue(source.contains("@State private var isExpanded = false"))
        XCTAssertTrue(source.contains("if isExpanded {"))
        XCTAssertTrue(source.contains("Show latest limit signals"))
        XCTAssertTrue(source.contains("Hide latest limit signals"))
    }

    func testMenuBarLabelUsesSingleLineCompactTitleInsteadOfClippedBadgeStack() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("Text(model.menuBarTitle)"))
        XCTAssertFalse(
            source.contains("MenuBarProviderMark(provider: provider)"),
            "Provider marks can become the only visible macOS status item content; keep remaining quota numbers as the direct menu bar label."
        )
        XCTAssertFalse(
            source.contains("TokenPilotMenuBarMark()"),
            "Fallback marks can hide the compact title in the constrained menu bar label."
        )
        XCTAssertFalse(
            source.contains("MenuBarRemainingBadgeRow(badges: model.menuBarRemainingBadges)"),
            "MenuBarExtra labels are one-line macOS status items; adding a VStack/badge row clips or hides Codex 5h/W numbers."
        )
        XCTAssertFalse(
            source.contains("if !model.menuBarRemainingBadges.isEmpty"),
            "Remaining badges belong inside the popover, not in the menu bar label."
        )
    }

    func testOverviewOmitsSevenDayAndProviderShareCards() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertFalse(source.contains("SevenDayBarChart(bars: model.overviewUsage.sevenDayBars)"))
        XCTAssertFalse(source.contains("ProviderShareRow(shares: model.overviewUsage.providerShare)"))
        XCTAssertTrue(source.contains("SevenDayBarChart(bars: model.historyUsage.sevenDayBars)"))
        XCTAssertTrue(source.contains("ProviderShareRow(shares: model.historyUsage.providerShare)"))
    }

    func testLimitCardsPreferRemainingPercentCopy() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("remainingPercentText"))
        XCTAssertTrue(source.contains("localized(\"Lowest remaining\""))
        XCTAssertTrue(source.contains("ProgressLine(percent: remainingPercent"))
        XCTAssertTrue(source.contains("return \"\\(remainingPercent)%\""))
        XCTAssertFalse(source.contains("return TokenPilotFormatters.remainingTime(until: resetAt)"))
        XCTAssertTrue(source.contains("remainingPercentText(window.remainingPercent)"))
        XCTAssertTrue(source.contains("String(format: localized(\"Remaining %d%%\""))
        XCTAssertFalse(source.contains("Text(percentText)"))
        XCTAssertFalse(source.contains("value: percentText(window.usedPercent)"))
    }

    func testCommercialReleaseResourcesArePresentAndPackaged() throws {
        let rootURL = try Self.projectRootURL()
        let fileManager = FileManager.default

        let privacyURL = rootURL.appendingPathComponent("Resources/PrivacyInfo.xcprivacy")
        XCTAssertTrue(fileManager.fileExists(atPath: privacyURL.path), "Commercial builds should include an app privacy manifest.")
        let privacyData = try Data(contentsOf: privacyURL)
        let privacyPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: privacyData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(privacyPlist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((privacyPlist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let accessedAPIs = try XCTUnwrap(privacyPlist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let accessedCategories = Set(accessedAPIs.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
        XCTAssertTrue(accessedCategories.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        XCTAssertTrue(accessedCategories.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))

        let iconContentsURL = rootURL.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset/Contents.json")
        let iconData = try Data(contentsOf: iconContentsURL)
        let iconJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: iconData) as? [String: Any])
        let images = try XCTUnwrap(iconJSON["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 10)
        for image in images {
            let filename = try XCTUnwrap(image["filename"] as? String)
            XCTAssertFalse(filename.isEmpty)
            let iconURL = iconContentsURL.deletingLastPathComponent().appendingPathComponent(filename)
            XCTAssertTrue(fileManager.fileExists(atPath: iconURL.path), "Missing app icon asset: \(filename)")
        }

        XCTAssertTrue(
            fileManager.fileExists(atPath: rootURL.appendingPathComponent("Resources/TokenPilot.icns").path),
            "The local .app packaging path should include a compiled icns file."
        )

        let buildScript = try String(contentsOf: rootURL.appendingPathComponent("build.sh"))
        XCTAssertTrue(buildScript.contains("PrivacyInfo.xcprivacy"))
        XCTAssertTrue(buildScript.contains("TokenPilot.icns"))
        XCTAssertTrue(buildScript.contains("TokenPilot.zip"))
        XCTAssertTrue(buildScript.contains("ditto -c -k --keepParent"))

        let xcodeGenConfig = try String(contentsOf: rootURL.appendingPathComponent("project.yml"))
        XCTAssertTrue(
            xcodeGenConfig.contains("Resources/Assets.xcassets"),
            "Xcode builds should compile the AppIcon asset catalog, not only the manual build.sh bundle."
        )
        XCTAssertTrue(
            xcodeGenConfig.contains("Resources/PrivacyInfo.xcprivacy"),
            "Xcode builds should include the app privacy manifest for App Store validation."
        )
        XCTAssertTrue(
            xcodeGenConfig.contains("Resources/TokenPilot.icns"),
            "Xcode builds should include the manual icns fallback used by CFBundleIconFile."
        )
    }

    func testReadmeDocumentsGitHubReleasePositioningWithoutOverclaims() throws {
        let readme = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("README.md"))

        XCTAssertTrue(readme.contains("GitHub Release positioning"))
        XCTAssertTrue(readme.contains("build/TokenPilot.zip"))
        XCTAssertTrue(readme.contains("No cloud dashboard"))
        XCTAssertTrue(readme.contains("No account required"))
        XCTAssertTrue(readme.contains("No provider token collection"))
        XCTAssertTrue(readme.contains("Settings → Provider Diagnostics"))
        XCTAssertTrue(readme.contains("docs/assets/readme-screenshot.png"))
        XCTAssertTrue(readme.contains("Release copy must stay evidence-bound"))
        XCTAssertTrue(readme.contains("# Executed 171 tests, with 0 failures"))
        XCTAssertTrue(readme.contains("do not claim notarization"))
        XCTAssertFalse(readme.contains("notarized and App Store-ready"))
        XCTAssertTrue(readme.contains("DeepSeek balance"))
        XCTAssertTrue(readme.contains("DS $12.34"))
        XCTAssertTrue(readme.contains("README.ja.md"))
        XCTAssertTrue(readme.contains("README.zh-CN.md"))
    }

    func testLocalizedReadmesDocumentDeepSeekAndScreenshot() throws {
        let rootURL = try Self.projectRootURL()
        let readmePaths = ["README.ko.md", "README.ja.md", "README.zh-CN.md"]

        for path in readmePaths {
            let readme = try String(contentsOf: rootURL.appendingPathComponent(path))
            XCTAssertTrue(readme.contains("docs/assets/readme-screenshot.png"), "\(path) should show the README screenshot.")
            XCTAssertTrue(readme.contains("DeepSeek"), "\(path) should document DeepSeek.")
            XCTAssertTrue(readme.contains("topped_up_balance"), "\(path) should name the official DeepSeek balance field.")
            XCTAssertTrue(readme.contains("/user/balance"), "\(path) should document the DeepSeek balance endpoint.")
        }
    }

    func testPublicReleaseGitIgnoreCoversSecretAndCredentialFiles() throws {
        let gitignore = try String(contentsOf: try Self.projectRootURL().appendingPathComponent(".gitignore"))
        let ignoredPatterns = Set(gitignore.components(separatedBy: .newlines))
        let requiredPatterns = [
            ".env",
            ".env.*",
            "*.env",
            ".secrets/",
            "*.pem",
            "*.key",
            "*.p8",
            "*.p12",
            "auth.json",
            "credentials.json",
            "token.json",
            "cookies.txt",
            ".gjc/",
            "*.xcresult",
            "*.crash",
            "*.ips",
            "TokenPilot-usage-*.json",
            "TokenPilot-usage-*.csv",
            "*.cer",
            "*.csr",
            "*.certSigningRequest",
            "*.der",
            "*.pfx",
            "*.mobileprovision",
            "*.provisionprofile",
            "*.xcarchive",
            "*.jks",
            "*.keystore",
            "*.asc",
            "*.gpg",
            "*.age",
            "*.kdbx",
            "id_rsa",
            "id_ed25519",
            "known_hosts",
            "codex-auth.json",
            "claude-statusline.json",
            "antigravity-statusline.json",
            "antigravity-statusline-writer.py",
            "antigravity-statusline.sh",
            "telemetry.log",
            "openai-auth.json",
            "anthropic-auth.json",
            "gemini-auth.json",
            "deepseek-auth.json",
            ".netrc",
            "*.token",
            "*.tokens",
            "*.secret",
            "*.secrets",
            "*.credentials",
            "*.credentials.json",
            "api-key*.txt",
            "*-api-key.txt",
            "deepseek-api-key*",
            "deepseek-balance*.json",
            "deepseek-response*.json",
            "gemini-telemetry.log",
            "sessions/",
            "archived_sessions/",
            "codex-sessions/",
            "gemini-sessions/",
            "claude-projects/",
        ]

        for pattern in requiredPatterns {
            XCTAssertTrue(
                ignoredPatterns.contains(pattern),
                "Public release .gitignore should exclude secret or credential file pattern: \(pattern)"
            )
        }
    }

    func testPublicReleaseDocsDoNotExposePersonalLocalPathsOrCredentialFilenames() throws {
        let rootURL = try Self.projectRootURL()
        let fileManager = FileManager.default
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        let publicDocURLs = try [rootURL]
            .flatMap { root in
                try fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            }
            + (try fileManager.contentsOfDirectory(
                at: docsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { ["md", "markdown", "html"].contains($0.pathExtension.lowercased()) })

        let localUserFragments = [NSUserName(), NSFullUserName()]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "root" }
        let forbiddenFragments = [
            "/Users/",
            "/Volumes/",
            ".codex/auth.json"
        ] + localUserFragments

        for url in publicDocURLs {
            let content = try String(contentsOf: url)
            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    content.contains(fragment),
                    "Public document \(url.lastPathComponent) should not expose personal local path or credential metadata fragment: \(fragment)"
                )
            }
        }
    }

    func testCodexLimitHintsSourceDoesNotContainLegacyAuthFileDirectHTTPReader() throws {
        let source = try Self.tokenCoreServicesSource()

        XCTAssertFalse(
            source.contains("readAccessToken"),
            "Public release code should not include a Codex auth-file access-token reader."
        )
        XCTAssertFalse(
            source.contains("resolvedAuthFileURL"),
            "Public release code should not resolve ~/.codex/auth.json for direct HTTP limit hints."
        )
        XCTAssertFalse(
            source.contains("Bearer \\(accessToken)"),
            "Public release code should not build a Codex web Authorization header from a local auth file."
        )
    }

    func testSettingsMutationEntryPointsUseDebouncedRefreshOnly() throws {
        let source = try Self.tokenMonitorAppSource()

        let usageRelevantMutationFunctions = [
            "setProvider",
            "parseCodexStatus",
            "markCodexWebSnapshotNow"
        ]

        for functionName in usageRelevantMutationFunctions {
            let body = try XCTUnwrap(
                source.swiftFunctionBody(named: functionName),
                "Could not find function body for \(functionName)"
            )
            XCTAssertFalse(
                body.collapsedWhitespace.contains("Task { await refresh() }"),
                "\(functionName) should rely on settings didSet debouncing instead of launching an immediate refresh. Immediate refresh storms can freeze Settings ↔ Overview switching."
            )
        }

        let localSourceBody = try XCTUnwrap(
            source.swiftFunctionBody(named: "chooseLocalSource"),
            "Could not find function body for chooseLocalSource"
        )
        XCTAssertFalse(
            localSourceBody.collapsedWhitespace.contains("await refresh()"),
            "chooseLocalSource should check the selected provider and let the debounced settings refresh update usage data."
        )

        let sourceCollapsed = source.collapsedWhitespace
        XCTAssertFalse(
            sourceCollapsed.contains(".onAppear { Task { await model.refresh() } }"),
            "Popover onAppear should not launch an unthrottled full refresh; use the lightweight stale-check path instead."
        )
        XCTAssertTrue(
            sourceCollapsed.contains("Task { await model.refreshAfterPopoverOpen() }"),
            "Popover onAppear should use refreshAfterPopoverOpen so view lifecycle work stays lightweight."
        )

        let popoverRefreshBody = try XCTUnwrap(
            source.swiftFunctionBody(named: "refreshAfterPopoverOpen"),
            "Could not find function body for refreshAfterPopoverOpen"
        )
        XCTAssertFalse(
            popoverRefreshBody.collapsedWhitespace.contains("handleAutoRefreshTick()"),
            "Opening the popover or rebuilding the root view during Settings → Overview should not enter the heavy auto-refresh path."
        )
        XCTAssertFalse(
            popoverRefreshBody.collapsedWhitespace.contains("refresh()"),
            "Opening the popover or rebuilding the root view during Settings → Overview should never start a provider refresh directly."
        )
        XCTAssertTrue(
            popoverRefreshBody.collapsedWhitespace.contains("menuBarNow = Date()"),
            "Popover open should only update lightweight time-dependent menu/overview labels."
        )
    }

    func testReleaseBuildAndSettingsAvoidStaleArtifactsRawPathsAndRefreshStorms() throws {
        let rootURL = try Self.projectRootURL()
        let buildScript = try String(contentsOf: rootURL.appendingPathComponent("build.sh"))
        let appSource = try Self.tokenMonitorAppSource()
        let refreshBody = try XCTUnwrap(
            appSource.swiftFunctionBody(named: "performRefreshPass"),
            "Could not find performRefreshPass body"
        )
        let detailBody = try XCTUnwrap(
            appSource.swiftFunctionBody(named: "sourceDetailText"),
            "Could not find sourceDetailText body"
        )

        XCTAssertTrue(
            buildScript.contains("rm -rf \"$APP_DIR\""),
            "Release bundle creation must delete the previous .app first so stale resources do not ship in TokenPilot.zip."
        )
        XCTAssertFalse(
            refreshBody.contains("connectionService.checkAll"),
            "Automatic refresh should not repeatedly run full provider diagnostics or spawn the Codex app-server every few seconds."
        )
        XCTAssertFalse(
            detailBody.contains("\\(path)"),
            "Settings status copy must not expose raw local source paths in release-facing diagnostics."
        )
    }

    func testProviderAdaptersUseBoundedFileReadsForLargeLogs() throws {
        let serviceSource = try Self.tokenCoreServicesSource()
        XCTAssertTrue(serviceSource.contains("tokenPilotBoundedTextContents"))
        XCTAssertFalse(
            serviceSource.contains("String(contentsOf: file, encoding: .utf8)"),
            "Provider adapters must not full-read arbitrary large log/session files in the menu bar app."
        )
    }

    func testHistoryScreenDoesNotCreateSelectionPublisherFeedbackLoop() throws {
        let source = try Self.tokenMonitorAppSource()
        let sourceCollapsed = source.collapsedWhitespace

        XCTAssertFalse(
            sourceCollapsed.contains(".onReceive(model.$selectedHistoryPeriod.removeDuplicates())"),
            "History should not subscribe to and write back the same selectedHistoryPeriod publisher; that feedback loop can spin during Settings → History navigation."
        )
        XCTAssertFalse(
            sourceCollapsed.contains(".onChange(of: model.selectedHistoryPeriod"),
            "History should not react to selectedHistoryPeriod changes by mutating the same state during view updates."
        )
        // Period picker was removed — history screen now uses a fixed last7Days period
        XCTAssertFalse(
            sourceCollapsed.contains("Picker(model.t(\"Period\")"),
            "History screen should not have a period picker (removed per user request)."
        )

        let selectionBody = try XCTUnwrap(
            source.swiftFunctionBody(named: "selectHistoryPeriod"),
            "Could not find function body for selectHistoryPeriod"
        )
        XCTAssertFalse(
            selectionBody.collapsedWhitespace.contains("selectedHistoryPeriod = period historyUsage"),
            "selectHistoryPeriod should avoid unconditional writeback of the same selectedHistoryPeriod before recomputing history."
        )
        XCTAssertFalse(
            selectionBody.collapsedWhitespace.contains("snapshots: filteredSnapshots"),
            "History period recomputation should use historySnapshots directly, not a computed view fallback that can couple History with Overview state."
        )
    }

    private static func projectRootURL() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func tokenMonitorAppSource() throws -> String {
        let tokenAppDir = try projectRootURL()
            .appendingPathComponent("Sources/TokenApp")
        let fm = FileManager.default
        var allFiles: [URL] = []
        let enumerator = fm.enumerator(at: tokenAppDir, includingPropertiesForKeys: nil)!
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "swift" {
                allFiles.append(url)
            }
        }
        return try allFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0) }.joined(separator: "\n")
    }

    private static func tokenCoreServicesSource() throws -> String {
        let tokenCoreServicesDir = try projectRootURL()
            .appendingPathComponent("Sources/TokenCore/Services")
        let fm = FileManager.default
        var allFiles: [URL] = []
        let enumerator = fm.enumerator(at: tokenCoreServicesDir, includingPropertiesForKeys: nil)!
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "swift" {
                allFiles.append(url)
            }
        }
        return try allFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0) }.joined(separator: "\n")
    }
}

private extension String {
    var collapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func swiftFunctionBody(named functionName: String) -> String? {
        guard let signatureRange = range(of: "func \(functionName)") else { return nil }
        guard let openingBrace = self[signatureRange.lowerBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var index = openingBrace
        while index < endIndex {
            let character = self[index]
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            let nextIndex = self.index(after: index)
            if depth == 0 {
                return String(self[openingBrace..<nextIndex])
            }
            index = nextIndex
        }
        return nil
    }
}
