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

        XCTAssertTrue(copy.contains("사용량 합계"))
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

    func testOverviewRecommendationCopyAvoidsOverclaimingBestTool() throws {
        XCTAssertEqual(
            TokenPilotLocalizer.localized("Lowest current usage", language: .ko),
            "현재 사용률이 가장 낮은 툴"
        )

        let source = try Self.tokenMonitorAppSource()
        XCTAssertTrue(source.contains("localized(\"Lowest current usage\""))
        XCTAssertFalse(
            source.contains("localized(\"Best tool now\""),
            "Overview should frame the card as observed usage, not a definitive best-tool recommendation."
        )
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
        XCTAssertFalse(source.contains("Divider().padding(.vertical, 4)"))
    }

    func testHistoryScreenShowsLimitSignalsAndHelpfulEmptyState() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("@Published var limitHistorySamples"))
        XCTAssertTrue(source.contains("HistoryLimitSignalCard(samples: model.limitHistorySamples"))
        XCTAssertTrue(source.contains("HistoryEmptyState("))
        XCTAssertTrue(source.contains("No token event history yet"))
    }

    func testMenuBarLabelUsesVisualRemainingPercentBadges() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertFalse(source.contains("struct MenuBarRemainingBadgeView"))
        XCTAssertTrue(source.contains("Text(model.menuBarTitle)"))
        XCTAssertTrue(source.contains("MenuBarRemainingStatusBadge"))
        XCTAssertFalse(source.contains("MenuBarRemainingBadgeRow(badges:"))
        XCTAssertFalse(source.contains("menuBarRemainingBadges.isEmpty"))
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