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

    func testProviderXAIMetadataIsExplicitNoNetworkFoundation() {
        XCTAssertTrue(Provider.allCases.contains(.xai))
        XCTAssertEqual(Provider.xai.rawValue, "xai")
        XCTAssertEqual(Provider.xai.displayName, "Grok / xAI API")
        XCTAssertEqual(Provider.xai.shortName, "xAI")
        XCTAssertEqual(Provider.xai.iconName, "server.rack")
        XCTAssertEqual(UsageDataSource.officialManagementAPI.label, "official management API (future)")
        XCTAssertEqual(TokenPilotLocalizer.localized(Provider.xai.displayName, language: .en), "Grok / xAI API")
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

    func testRemainingTimeFormatterLocalizesUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(7_500)

        XCTAssertEqual(TokenPilotFormatters.remainingTime(until: reset, language: .en, now: now), "2h 5m")
        XCTAssertEqual(TokenPilotFormatters.remainingTime(until: reset, language: .ko, now: now), "2시간 5분")
        XCTAssertEqual(TokenPilotFormatters.remainingTime(until: reset, language: .ja, now: now), "2時間 5分")
        XCTAssertEqual(TokenPilotFormatters.remainingTime(until: reset, language: .zhHans, now: now), "2小时 5分钟")
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
            weekly: LimitWindow(kind: .weekly, usedPercent: 47, resetAt: now.addingTimeInterval(18_720)),
            confidence: .high,
            dataSource: .officialStatusline
        )
        var settings = AppSettings()
        settings.localization.language = .ko

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: now
        )

        XCTAssertEqual(title, "5h 18% · 7d 53%")
    }

    func testMenuBarTitleFallsBackToDataUnavailableWhenWindowPercentMissing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: nil, resetAt: now.addingTimeInterval(7_200)),
            weekly: LimitWindow(kind: .weekly, usedPercent: nil, resetAt: now.addingTimeInterval(18_720)),
            confidence: .high,
            dataSource: .officialStatusline
        )
        var settings = AppSettings()
        settings.localization.language = .ko

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: now
        )

        XCTAssertEqual(title, "TP · LIVE")
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

        XCTAssertEqual(title, "7d 68% EXP")
    }

    func testMenuBarTitleShowsAntigravityBridgeContextRemainingPercent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ProviderSnapshot(
            provider: .gemini,
            updatedAt: now,
            confidence: .high,
            dataSource: .officialStatusline,
            contextWindowUsedPercent: 32
        )
        var settings = AppSettings()
        settings.menuBarDisplayTarget = .gemini

        let title = MenuBarStatusService().title(
            snapshots: [snapshot],
            settings: settings,
            modeLabel: "LIVE",
            now: now
        )

        XCTAssertEqual(title, "BRIDGE 68%")
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

        XCTAssertEqual(title, "Co --%")
        XCTAssertFalse(title.contains("100%"))
        XCTAssertFalse(title.contains("0%"))
    }

    func testMenuBarTreatsXAISetupAsNeutralNoQuotaCandidate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 99, resetAt: now.addingTimeInterval(3_600)),
            confidence: .low,
            dataSource: .manual,
            statusMessage: "Management authentication unconfirmed"
        )
        let liveClaudeSnapshot = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 20, resetAt: now.addingTimeInterval(3_600)),
            confidence: .high,
            dataSource: .officialStatusline
        )
        var settings = AppSettings()
        settings.localization.language = .en
        settings.xAI.teamID = "configured"
        settings.xAI.managementAPIKeyConfigured = true
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        let service = MenuBarStatusService()

        XCTAssertEqual(service.title(snapshots: [snapshot], settings: settings, modeLabel: "LIVE", now: now), "TP · LIVE")
        XCTAssertEqual(service.statusLevel(snapshots: [snapshot], settings: settings), .normal)
        XCTAssertFalse(service.shouldShowStatusDot(snapshots: [snapshot], settings: settings))
        XCTAssertNil(service.lowestRemainingSummary(snapshots: [snapshot], settings: settings))

        settings.menuBarDisplayTarget = .xai
        let targetedTitle = service.title(snapshots: [snapshot], settings: settings, modeLabel: "LIVE", now: now)
        let accessibility = service.accessibilityLabel(snapshots: [snapshot, liveClaudeSnapshot], settings: settings, modeLabel: "LIVE", now: now)

        XCTAssertEqual(targetedTitle, "xAI · Management authentication unconfirmed")
        XCTAssertNotEqual(targetedTitle, "xAI · LIVE")
        XCTAssertFalse(targetedTitle.contains("LIVE"))
        XCTAssertEqual(accessibility, "TokenPilot, xAI · Management authentication unconfirmed")
        XCTAssertTrue(accessibility.contains("TokenPilot"))
        XCTAssertTrue(accessibility.localizedCaseInsensitiveContains("Management authentication unconfirmed"))
        XCTAssertFalse(accessibility.contains("LIVE"))
        XCTAssertFalse(accessibility.localizedCaseInsensitiveContains(TokenPilotLocalizer.localized("Live only", language: settings.localization.language)))
        XCTAssertFalse(accessibility.contains("%"))
        XCTAssertFalse(accessibility.localizedCaseInsensitiveContains("capacity remaining"))

        var noSetupSettings = AppSettings()
        noSetupSettings.localization.language = .en
        XCTAssertTrue(noSetupSettings.setProviderEnabled(.xai, isEnabled: true))
        noSetupSettings.menuBarDisplayTarget = .xai

        let falseLiveTitle = service.title(
            snapshots: [liveClaudeSnapshot],
            settings: noSetupSettings,
            modeLabel: "LIVE",
            now: now
        )
        XCTAssertEqual(falseLiveTitle, "xAI not configured")
        XCTAssertNotEqual(falseLiveTitle, "xAI · LIVE")
        XCTAssertFalse(falseLiveTitle.contains("LIVE"))
    }
    func testCompactMenuBarCompositionIsTruthfulAndLimitedToTwoProviders() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = MenuBarStatusService()
        var settings = AppSettings()
        settings.menuBarDisplayStyle = .compact
        settings.menuBarDisplayTarget = .claude
        settings.menuBarSecondaryDisplayTarget = .codex
        settings.menuBarShowsSecondaryProvider = true
        let snapshots = [
            ProviderSnapshot(
                provider: .claude,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 20),
                confidence: .high,
                dataSource: .officialStatusline
            ),
            ProviderSnapshot(
                provider: .codex,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 74),
                confidence: .manual,
                dataSource: .manual
            )
        ]

        XCTAssertEqual(service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now), "Cl 80% · Co Manual")
        let accessibility = service.accessibilityLabel(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now)
        XCTAssertTrue(accessibility.contains("Claude Code"))
        XCTAssertTrue(accessibility.contains("Codex"))
        XCTAssertFalse(accessibility.contains("Co Manual"))

        settings.menuBarDisplayStyle = .iconOnly
        XCTAssertEqual(service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now), "TP")

        settings.menuBarDisplayStyle = .compact
        settings.menuBarSecondaryDisplayTarget = .claude
        XCTAssertEqual(service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now), "Cl 80%")
        settings.menuBarSecondaryDisplayTarget = .gemini
        XCTAssertTrue(settings.setProviderEnabled(.gemini, isEnabled: false))
        XCTAssertEqual(service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now), "Cl 80%")
    }

    func testCompactMenuBarUsesNativeBalanceAndNeutralUnavailableLabels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = MenuBarStatusService()
        var settings = AppSettings()
        settings.menuBarDisplayStyle = .compact
        settings.menuBarDisplayTarget = .deepseek
        let balance = ProviderSnapshot(
            provider: .deepseek,
            confidence: .high,
            dataSource: .officialTelemetry,
            balance: ProviderBalance(currency: "EUR", toppedUpBalance: Decimal(string: "12.34")!)
        )
        XCTAssertEqual(service.title(snapshots: [balance], settings: settings, modeLabel: "LIVE", now: now), "DS EUR 12.34")

        settings.menuBarDisplayTarget = .xai
        XCTAssertTrue(settings.setProviderEnabled(.xai, isEnabled: true))
        XCTAssertEqual(service.title(snapshots: [balance], settings: settings, modeLabel: "LIVE", now: now), "xAI Unavailable")
        XCTAssertFalse(service.title(snapshots: [balance], settings: settings, modeLabel: "LIVE", now: now).contains("LIVE"))

        settings.menuBarDisplayTarget = .codex
        let localCodex = ProviderSnapshot(provider: .codex, todayTokens: 12_400, confidence: .medium, dataSource: .localLog)
        let title = service.title(snapshots: [localCodex], settings: settings, modeLabel: "LIVE", now: now)
        XCTAssertEqual(title, "Co Local")
        XCTAssertFalse(title.contains("%"))
    }
    func testAutomaticCompactPrimaryExcludesEnabledSecondaryProvider() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = MenuBarStatusService()
        var settings = AppSettings()
        settings.menuBarDisplayStyle = .compact
        settings.menuBarSecondaryDisplayTarget = .claude
        settings.menuBarShowsSecondaryProvider = true
        let snapshots = [
            ProviderSnapshot(
                provider: .claude,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 20),
                confidence: .high,
                dataSource: .officialStatusline
            ),
            ProviderSnapshot(
                provider: .codex,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 30),
                confidence: .high,
                dataSource: .webUsage,
                isExperimental: true
            )
        ]

        XCTAssertEqual(service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now), "Co 70% EXP · Cl 80%")
        let accessibility = service.accessibilityLabel(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now)
        XCTAssertLessThan(accessibility.range(of: "Codex")!.lowerBound, accessibility.range(of: "Claude Code")!.lowerBound)
    }

    func testAutomaticCompactPrimaryFallsBackToSecondaryWhenNoAlternativeExists() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = MenuBarStatusService()
        var settings = AppSettings()
        settings.menuBarDisplayStyle = .compact
        settings.menuBarSecondaryDisplayTarget = .claude
        settings.menuBarShowsSecondaryProvider = true
        let snapshots = [
            ProviderSnapshot(
                provider: .claude,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 20),
                confidence: .high,
                dataSource: .officialStatusline
            )
        ]

        XCTAssertEqual(service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now), "Cl 80%")
        let accessibility = service.accessibilityLabel(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now)
        XCTAssertEqual(accessibility.components(separatedBy: "Claude Code").count, 2)
    }

    func testCompactAndIconOnlyAccessibilityAreLocalizedAndTruthful() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 20),
            confidence: .high,
            dataSource: .officialStatusline
        )

        for language: TokenPilotLanguage in [.en, .ko, .ja, .zhHans] {
            var settings = AppSettings()
            settings.localization.language = language
            settings.menuBarDisplayStyle = .compact
            settings.menuBarDisplayTarget = .claude

            let compactAccessibility = MenuBarStatusService().accessibilityLabel(
                snapshots: [snapshot],
                settings: settings,
                modeLabel: "LIVE",
                now: now
            )
            XCTAssertTrue(compactAccessibility.contains(TokenPilotLocalizer.localized("Claude Code", language: language)))
            XCTAssertTrue(compactAccessibility.contains(String(format: TokenPilotLocalizer.localized("Capacity remaining %d%%", language: language), 80)))
            XCTAssertFalse(compactAccessibility.contains("Cl 80%"))

            settings.menuBarDisplayStyle = .iconOnly
            let iconAccessibility = MenuBarStatusService().accessibilityLabel(
                snapshots: [],
                settings: settings,
                modeLabel: "LIVE",
                now: now
            )
            XCTAssertTrue(iconAccessibility.contains(TokenPilotLocalizer.localized("Unavailable", language: language)))
            XCTAssertFalse(iconAccessibility.contains("%"))
            settings.menuBarDisplayTarget = nil
            let unavailableIconAccessibility = MenuBarStatusService().accessibilityLabel(
                snapshots: [],
                settings: settings,
                modeLabel: "LIVE",
                now: now
            )
            XCTAssertTrue(unavailableIconAccessibility.contains(TokenPilotLocalizer.localized("Menu bar data unavailable", language: language)))
            XCTAssertFalse(unavailableIconAccessibility.contains("%"))
        }
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

        XCTAssertEqual(title, "5h 26% EST · 7d 80% EST")
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
        let normal = ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 52), confidence: .high, dataSource: .officialStatusline)
        let warning = ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 70), confidence: .high, dataSource: .officialStatusline)
        let critical = ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 85), confidence: .high, dataSource: .officialStatusline)

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

    func testViewModelFollowUpLocalizationKeysHaveFourLocaleParityAndObsoleteKeysAreAbsent() throws {
        let targetKeys: [(key: String, translations: [(language: TokenPilotLanguage, locale: String, value: String)])] = [
            (
                "Auto-detected sources: %@",
                [
                    (.en, "en", "Auto-detected sources: %@"),
                    (.ko, "ko", "자동 감지된 소스: %@"),
                    (.ja, "ja", "自動検出したソース: %@"),
                    (.zhHans, "zh-Hans", "已自动检测到来源：%@")
                ]
            ),
            (
                "Choose Claude source",
                [
                    (.en, "en", "Choose Claude source"),
                    (.ko, "ko", "Claude 소스 선택"),
                    (.ja, "ja", "Claude ソースを選択"),
                    (.zhHans, "zh-Hans", "选择 Claude 数据源")
                ]
            ),
            (
                "Choose Claude statusline JSON or a .claude/projects folder.",
                [
                    (.en, "en", "Choose Claude statusline JSON or a .claude/projects folder."),
                    (.ko, "ko", "Claude statusline JSON 또는 .claude/projects 폴더를 선택하세요."),
                    (.ja, "ja", "Claude statusline JSON または .claude/projects フォルダを選択してください。"),
                    (.zhHans, "zh-Hans", "选择 Claude statusline JSON 或 .claude/projects 文件夹。")
                ]
            ),
            (
                "Connection check complete.",
                [
                    (.en, "en", "Connection check complete."),
                    (.ko, "ko", "연결 확인이 완료되었습니다."),
                    (.ja, "ja", "接続確認が完了しました。"),
                    (.zhHans, "zh-Hans", "连接检查完成。")
                ]
            ),
            (
                "Detected",
                [
                    (.en, "en", "Detected"),
                    (.ko, "ko", "감지됨"),
                    (.ja, "ja", "検出済み"),
                    (.zhHans, "zh-Hans", "已检测")
                ]
            ),
            (
                "Detected paths",
                [
                    (.en, "en", "Detected paths"),
                    (.ko, "ko", "감지된 경로"),
                    (.ja, "ja", "検出済みパス"),
                    (.zhHans, "zh-Hans", "检测到的路径")
                ]
            ),
            (
                "Export Usage",
                [
                    (.en, "en", "Export Usage"),
                    (.ko, "ko", "사용량 내보내기"),
                    (.ja, "ja", "使用量を書き出し"),
                    (.zhHans, "zh-Hans", "导出使用量")
                ]
            ),
            (
                "Exported",
                [
                    (.en, "en", "Exported"),
                    (.ko, "ko", "내보냄"),
                    (.ja, "ja", "書き出し済み"),
                    (.zhHans, "zh-Hans", "已导出")
                ]
            ),
            (
                "Invalid format",
                [
                    (.en, "en", "Invalid format"),
                    (.ko, "ko", "잘못된 형식"),
                    (.ja, "ja", "無効な形式"),
                    (.zhHans, "zh-Hans", "格式无效")
                ]
            ),
            (
                "Run Check Connection to scan local paths.",
                [
                    (.en, "en", "Run Check Connection to scan local paths."),
                    (.ko, "ko", "로컬 경로를 스캔하려면 연결 확인을 실행하세요."),
                    (.ja, "ja", "ローカルパスをスキャンするには接続確認を実行してください。"),
                    (.zhHans, "zh-Hans", "运行检查连接以扫描本地路径。")
                ]
            )
        ]

        let viewModelSource = try Self.tokenAppSourceFile("ViewModels/TokenPilotViewModel.swift")
        let liveTargetKeys = Set(targetKeys.map { $0.key }.filter { viewModelSource.contains("t(\"\($0)\")") })
        XCTAssertEqual(liveTargetKeys, Set(targetKeys.map { $0.key }))

        let rootURL = try Self.projectRootURL()
        let coreFallbackSource = try String(contentsOf: rootURL.appendingPathComponent("Sources/TokenCore/TokenPilotLocalization.swift"))
        let catalogData = try Data(contentsOf: rootURL.appendingPathComponent("Sources/TokenApp/Resources/Localizable.xcstrings"))
        let catalogRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalogStrings = try XCTUnwrap(catalogRoot["strings"] as? [String: Any])

        for (key, translations) in targetKeys {
            XCTAssertTrue(coreFallbackSource.contains("\"\(key)\": [.en:"), "Missing runtime fallback key: \(key)")

            let catalogEntry = try XCTUnwrap(catalogStrings[key] as? [String: Any], "Missing catalog key: \(key)")
            let localizations = try XCTUnwrap(catalogEntry["localizations"] as? [String: Any], "Missing catalog localizations: \(key)")

            for (language, locale, expectedValue) in translations {
                let fallbackValue = TokenPilotLocalizer.localized(key, language: language)
                XCTAssertFalse(fallbackValue.isEmpty, "Empty runtime fallback for \(locale): \(key)")
                XCTAssertEqual(fallbackValue, expectedValue, "Wrong runtime fallback for \(locale): \(key)")

                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "Missing catalog locale \(locale): \(key)")
                let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "Missing catalog string unit \(locale): \(key)")
                let catalogValue = try XCTUnwrap(stringUnit["value"] as? String, "Missing catalog value \(locale): \(key)")
                XCTAssertFalse(catalogValue.isEmpty, "Empty catalog value for \(locale): \(key)")
                XCTAssertEqual(catalogValue, expectedValue, "Wrong catalog value for \(locale): \(key)")
            }
        }

        let obsoleteKeys = [
            "capacity.alert.recovery.codes.format",
            "defaultClaudePath",
            "defaultGeminiPath1",
            "defaultGeminiPath2"
        ]
        for obsoleteKey in obsoleteKeys {
            XCTAssertFalse(coreFallbackSource.contains("\"\(obsoleteKey)\""))
            XCTAssertNil(catalogStrings[obsoleteKey])
            XCTAssertEqual(TokenPilotLocalizer.localized(obsoleteKey, language: .ko), obsoleteKey)
        }
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

    func testSettingsDisclosurePolishCopyIsLocalized() {
        let expectations: [(String, TokenPilotLanguage, String)] = [
            ("Settings overview", .en, "Settings overview"),
            ("Settings overview", .ko, "설정 요약"),
            ("Settings overview", .ja, "設定の概要"),
            ("Settings overview", .zhHans, "设置概览"),
            ("Privacy and provider truth", .en, "Privacy and data sources"),
            ("Privacy and provider truth", .ko, "개인정보 및 데이터 출처"),
            ("Privacy and provider truth", .ja, "プライバシーとデータの出所"),
            ("Privacy and provider truth", .zhHans, "隐私与数据来源"),
            ("Expanded", .en, "Expanded"),
            ("Expanded", .ko, "펼쳐짐"),
            ("Expanded", .ja, "展開中"),
            ("Expanded", .zhHans, "已展开"),
            ("Collapsed", .en, "Collapsed"),
            ("Collapsed", .ko, "접힘"),
            ("Collapsed", .ja, "折りたたみ中"),
            ("Collapsed", .zhHans, "已折叠")
        ]

        for (key, language, expected) in expectations {
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: language), expected)
        }
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

    func testProviderMarksUseSemanticBrandSystemWithAccessibilityMotionAndContrast() throws {
        let componentsSource = try Self.tokenAppSourceFile("Views/Components.swift")
        let designSource = try Self.tokenAppSourceFile("DesignSystem/TokenPilotDesign.swift")

        XCTAssertTrue(componentsSource.contains("struct ProviderSignatureMark"))
        XCTAssertTrue(componentsSource.contains("struct TokenPilotBrandMark"))
        XCTAssertTrue(componentsSource.contains("@Environment(\\.accessibilityReduceMotion) private var systemReduceMotion"))
        XCTAssertTrue(componentsSource.contains("@Environment(\\.tokenPilotReduceMotionOverride) private var reduceMotionOverride"))
        XCTAssertTrue(componentsSource.contains("@Environment(\\.tokenPilotSemanticPalette) private var palette"))
        XCTAssertTrue(componentsSource.contains("private var isRevealed: Bool"))
        XCTAssertTrue(componentsSource.contains("if reduceMotion {"))
        XCTAssertTrue(componentsSource.contains("reduceMotionOverride ?? systemReduceMotion"))
        XCTAssertTrue(componentsSource.contains("palette.surface(.cardElevated)"))
        XCTAssertTrue(componentsSource.contains("palette.borderColor()"))
        XCTAssertTrue(componentsSource.contains("lineWidth: palette.borderWidth()"))
        XCTAssertTrue(componentsSource.contains("palette.accent(for: provider)"))
        XCTAssertTrue(designSource.contains("struct SemanticPalette"))
        XCTAssertTrue(designSource.contains("let colorSchemeContrast: ColorSchemeContrast"))
        XCTAssertTrue(designSource.contains("TokenPilotDesign.borderColor(colorSchemeContrast, emphasized: emphasized)"))
        XCTAssertTrue(designSource.contains("TokenPilotDesign.borderWidth(colorSchemeContrast, emphasized: emphasized)"))
        XCTAssertTrue(designSource.contains("TokenPilotDesign.SemanticPalette(colorSchemeContrast: contrastOverride ?? systemColorSchemeContrast)"))
        XCTAssertFalse(componentsSource.contains("@Environment(\\.colorSchemeContrast) private var systemColorSchemeContrast"))
        XCTAssertFalse(componentsSource.contains("@Environment(\\.tokenPilotContrastOverride) private var contrastOverride"))
    }

    func testSettingsDataSourcesUseFiveProviderDisclosuresWithPreservedControls() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertTrue(source.contains("private func providerSetupDisclosure<Content: View>"))
        XCTAssertTrue(source.contains("providerSetupDisclosure(provider: .claude, title: model.t(\"Claude Code\"))"))
        XCTAssertTrue(source.contains("providerSetupDisclosure(provider: .gemini, title: model.t(\"Antigravity CLI\"))"))
        XCTAssertTrue(source.contains("providerSetupDisclosure(provider: .deepseek, title: model.t(\"DeepSeek\"))"))
        XCTAssertTrue(source.contains("providerSetupDisclosure(provider: .codex, title: model.t(\"Codex\"))"))
        XCTAssertTrue(source.contains("providerSetupDisclosure(provider: .xai, title: model.t(\"Grok / xAI API\"))"))
        XCTAssertTrue(source.contains("DisclosureCard(\n            initiallyExpanded: providerDefaultExpanded(provider)"))
        XCTAssertTrue(source.contains("providerSetupSummary(provider: provider, title: title, diagnostic: diagnostic)"))
        XCTAssertTrue(source.contains("CompactProviderStatusRow("))
        XCTAssertTrue(source.contains("diagnostic.confidence.localizedLabel(language: model.settings.localization.language)"))
        XCTAssertTrue(source.contains("providerSecretSummary(provider)"))
        XCTAssertTrue(source.contains("private var providerSetupOrder: [Provider]"))
        XCTAssertTrue(source.contains("[.claude, .gemini, .deepseek, .xai, .codex]"))

        XCTAssertTrue(source.contains("providerToggle(.claude)"))
        XCTAssertTrue(source.contains("providerToggle(.codex)"))
        XCTAssertTrue(source.contains("providerToggle(.gemini)"))
        XCTAssertTrue(source.contains("providerToggle(.deepseek)"))
        XCTAssertTrue(source.contains("providerToggle(.xai)"))
        XCTAssertTrue(source.contains("model.chooseClaudeStatusFile()"))
        XCTAssertTrue(source.contains("model.chooseGeminiTelemetrySource()"))
        XCTAssertTrue(source.contains("Toggle(model.t(\"Use Manual DeepSeek Balance\")"))
        XCTAssertTrue(source.contains("Button(model.t(\"Delete API Key\"), role: .destructive)"))
        XCTAssertTrue(source.contains("Toggle(model.t(\"Use experimental Codex limit hints\")"))
        XCTAssertTrue(source.contains("Toggle(model.t(\"Use Manual Limit Snapshot\")"))
        XCTAssertTrue(source.contains("Button(model.t(\"Paste Status\"))"))
        XCTAssertTrue(source.contains("Button(model.t(\"Parse Status\"))"))
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
        XCTAssertTrue(source.contains("Diagnostics summarize source health without showing raw local paths"))
        XCTAssertTrue(source.contains("ProviderConnectionDiagnostic"))
        XCTAssertTrue(source.contains("diagnosticNextActionText"))
        XCTAssertTrue(source.contains("updateDeepSeekDataSourceForCredentialState()"))
    }

    func testOverviewAndHistoryEmptyStatesLinkToProviderDiagnostics() throws {
        let overviewSource = try Self.tokenAppSourceFile("Views/OverviewScreen.swift")
        let historySource = try Self.tokenAppSourceFile("Views/HistoryScreen.swift")

        XCTAssertTrue(overviewSource.contains("message: model.t(\"Run Auto-detect or Provider Diagnostics to recover source health.\")"))
        XCTAssertTrue(overviewSource.contains("Button(model.t(\"Open Settings\"))"))
        XCTAssertTrue(overviewSource.contains("model.selectedScreen = .settings"))
        XCTAssertFalse(overviewSource.contains("Run Provider Diagnostics in Settings to connect Claude, Codex, or Antigravity."))
        XCTAssertTrue(historySource.contains("Text(model.t(\"Run Auto-detect or Provider Diagnostics to recover source health.\"))"))
        XCTAssertTrue(historySource.contains("Button(model.t(\"Open Provider Diagnostics\"))"))
        XCTAssertTrue(historySource.contains("model.selectedScreen = .settings"))
        XCTAssertTrue(historySource.contains("HistoryCapacityEmptyState(model: model)"))
        XCTAssertTrue(historySource.contains("HistoryEmptyState(hasLimitSignals: hasCapacitySignals, model: model)"))
    }

    func testHistoryScreenShowsCompactCapacityEvidenceTimelineAndHelpfulEmptyStates() throws {
        let appSource = try Self.tokenMonitorAppSource()
        let historySource = try Self.tokenAppSourceFile("Views/HistoryScreen.swift")
        let componentsSource = try Self.tokenAppSourceFile("Views/Components.swift")

        XCTAssertTrue(appSource.contains("@Published var limitHistorySamples"))
        XCTAssertTrue(historySource.contains("private var hasCapacitySignals: Bool"))
        XCTAssertTrue(historySource.contains("!model.capacityPresentations.isEmpty || !model.limitHistorySamples.isEmpty"))
        XCTAssertTrue(historySource.contains("CurrentCapacitySignalCard("))
        XCTAssertTrue(historySource.contains("HistoryLimitSignalCard(samples: model.limitHistorySamples, model: model)"))
        XCTAssertTrue(historySource.contains("DisclosureCard(\n            padding: 10,\n            initiallyExpanded: true"))
        XCTAssertTrue(historySource.contains("DisclosureSummaryRow(\n                title: model.t(\"Recorded capacity signal history\")"))
        XCTAssertTrue(historySource.contains("HistoryUsageTimelineCard(events: model.historyUsage.events, model: model)"))
        XCTAssertTrue(historySource.contains("HistoryUsageEventRow(event: event, model: model)"))
        XCTAssertTrue(historySource.contains("HistoryEmptyState(hasLimitSignals: hasCapacitySignals, model: model)"))
        XCTAssertTrue(historySource.contains("No usage events recorded"))
        XCTAssertTrue(historySource.contains("Capacity signals are available above, but no token usage events are stored for this period."))
        XCTAssertTrue(historySource.contains("Button(model.t(\"Open Provider Diagnostics\"))"))
        XCTAssertTrue(historySource.contains("model.selectedScreen = .settings"))
        XCTAssertTrue(historySource.contains("ProviderSignatureMark(provider: sample.provider, size: 24)"))
        XCTAssertTrue(historySource.contains("ProviderSignatureMark(provider: event.provider, size: 22)"))
        XCTAssertTrue(historySource.contains("SemanticChip("))
        XCTAssertTrue(historySource.contains("role: .truth"))
        XCTAssertTrue(componentsSource.contains("@Environment(\\.accessibilityReduceMotion) private var systemReduceMotion"))
        XCTAssertTrue(componentsSource.contains("@Environment(\\.tokenPilotReduceMotionOverride) private var reduceMotionOverride"))
        XCTAssertTrue(componentsSource.contains("reduceMotionOverride ?? systemReduceMotion"))
        XCTAssertTrue(componentsSource.contains(".transition(reduceMotion ? .identity"))
        XCTAssertTrue(componentsSource.contains("if reduceMotion {"))
        XCTAssertFalse(historySource.contains("@State private var isExpanded = false"))
        XCTAssertFalse(historySource.contains("Show recorded capacity signal history"))
        XCTAssertFalse(historySource.contains("Hide recorded capacity signal history"))
    }

    func testRedesignedCapacityConsoleKeepsCompactDisclosureAndSourceOnlyContracts() throws {
        let appSource = try Self.tokenMonitorAppSource()
        let rootSource = try Self.tokenAppSourceFile("Views/OverviewScreen.swift")
        let settingsSource = try Self.tokenAppSourceFile("Views/SettingsScreen.swift")
        let historySource = try Self.tokenAppSourceFile("Views/HistoryScreen.swift")
        let componentsSource = try Self.tokenAppSourceFile("Views/Components.swift")
        let settingsCollapsed = settingsSource.collapsedWhitespace
        let historyCollapsed = historySource.collapsedWhitespace
        let redesignedViewSource = [rootSource, settingsSource, historySource, componentsSource].joined(separator: "\n")

        XCTAssertTrue(appSource.contains(".frame(width: 420, height: 620)"))
        XCTAssertTrue(rootSource.contains(".frame(width: 420, height: 620)"))

        for removedSurface in ["import Charts", "LineMark(", "BarMark(", "AreaMark(", "Chart(", "Daily challenge", "Provider share"] {
            XCTAssertFalse(redesignedViewSource.contains(removedSurface), "Removed dashboard/chart surface should stay absent: \(removedSurface)")
        }
        XCTAssertFalse(redesignedViewSource.localizedCaseInsensitiveContains("dashboard"))

        XCTAssertTrue(settingsCollapsed.contains("consoleSummary sourceSettings notificationSettings privacySettings"))
        XCTAssertTrue(settingsSource.contains("title: model.t(\"Settings overview\")"))
        XCTAssertFalse(settingsSource.contains("Settings disclosure console"))
        XCTAssertTrue(settingsSource.contains("title: model.t(\"Source health\")"))
        XCTAssertTrue(settingsSource.contains("title: model.t(\"Privacy and provider truth\")"))
        XCTAssertTrue(settingsSource.contains("private var privacyTruthChips: some View"))
        XCTAssertTrue(settingsSource.contains("SemanticChip(label: model.t(\"Local metadata only\")"))
        XCTAssertTrue(settingsSource.contains("SemanticChip(label: model.t(\"Secrets hidden\")"))
        XCTAssertTrue(settingsSource.contains("Reads local metadata and selected files only; secrets stay hidden; raw paths, prompts, and responses are excluded."))
        XCTAssertTrue(settingsSource.contains("SemanticChip(label: model.t(\"Manual/experimental labels shown\")"))
        XCTAssertTrue(settingsCollapsed.contains("DisclosureCard( initiallyExpanded: true, accessibilityLabel: model.t(\"Source health\")"))
        XCTAssertTrue(settingsCollapsed.contains("DisclosureCard( initiallyExpanded: true, accessibilityLabel: model.t(\"Provider Diagnostics\")"))
        XCTAssertTrue(settingsCollapsed.contains("DisclosureCard( initiallyExpanded: privacyDetailsDefaultExpanded"))
        XCTAssertTrue(settingsCollapsed.contains("DisclosureCard( initiallyExpanded: providerDefaultExpanded(provider)"))
        XCTAssertTrue(historyCollapsed.contains("DisclosureCard( padding: 10, initiallyExpanded: true, accessibilityLabel: model.t(\"Recorded capacity signal history\")"))
        XCTAssertTrue(componentsSource.contains("localized(isExpanded ? \"Expanded\" : \"Collapsed\", language: language)"))

        XCTAssertTrue(redesignedViewSource.contains("TokenPilotDesign.surface("))
        XCTAssertTrue(redesignedViewSource.contains("TokenPilotDesign.textPrimary"))
        XCTAssertTrue(redesignedViewSource.contains("TokenPilotDesign.textSecondary"))
        XCTAssertTrue(redesignedViewSource.contains("SemanticChip("))
        XCTAssertTrue(redesignedViewSource.contains("role: .truth"))

        let forbiddenPersistenceMarkers = [
            "UserDefaults",
            "AppSettingsStore(",
            "UsageHistoryStore(",
            "LimitHistoryStore(",
            "CapacityAlertPersistence",
            "FileManager.",
            "JSONEncoder()",
            "JSONDecoder()",
            ".write(to:"
        ]
        for marker in forbiddenPersistenceMarkers {
            XCTAssertFalse(redesignedViewSource.contains(marker), "Redesigned views should not add production persistence: \(marker)")
        }
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
    func testDebugScenarioFixturesInjectProductionViewModelOnlyInDebugAndStayPrivacySafe() throws {
        let rootURL = try Self.projectRootURL()
        let appSource = try String(contentsOf: rootURL.appendingPathComponent("Sources/TokenApp/TokenMonitorApp.swift"))
        let viewModelSource = try String(contentsOf: rootURL.appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))

        XCTAssertTrue(appSource.contains("TokenPilotRootView(model: model)"))
        XCTAssertTrue(appSource.contains("productionMenuBarLabel(model: model)"))
        XCTAssertTrue(appSource.contains("TokenPilotDebugFixture.resolve()"))
        XCTAssertTrue(appSource.contains("TokenPilotViewModel(debugFixture: debugFixture)"))
        XCTAssertFalse(appSource.contains("TokenPilotDebugFixtureView"))
        XCTAssertFalse(appSource.contains("debugFixtureLabel"))
        XCTAssertFalse(appSource.contains("launchState"))
        XCTAssertTrue(appSource.contains("private let debugAccessibilityProfile: TokenPilotDebugAccessibilityProfile?"))
        XCTAssertTrue(appSource.contains(".tokenPilotDebugAccessibilityProfile(debugAccessibilityProfile)"))

        XCTAssertTrue(viewModelSource.contains("#if DEBUG\n    init(debugFixture: TokenPilotDebugFixture? = TokenPilotDebugFixture.resolve())"))
        XCTAssertTrue(viewModelSource.contains("#else\n    init() {\n        self.settings = settingsStore.load()"))
        XCTAssertTrue(viewModelSource.contains("refreshStoredCredentialPresence()"))
        XCTAssertTrue(viewModelSource.contains("guard !debugFixtureMode else { return }"))
        XCTAssertTrue(viewModelSource.contains("blockDebugFixtureExternalAction()"))
        XCTAssertFalse(viewModelSource.contains("func chooseGeminiLogFile()"))

        let fixtureActionGuard = "#if DEBUG\n        guard !blockDebugFixtureExternalAction() else { return }\n#endif"
        for functionName in ["pasteCodexStatusFromClipboard", "markCodexWebSnapshotNow", "copyToClipboard"] {
            let body = try XCTUnwrap(viewModelSource.swiftFunctionBody(named: functionName), "Missing \(functionName)")
            XCTAssertTrue(body.contains(fixtureActionGuard), "\(functionName) must be blocked before pasteboard or wall-clock side effects in DEBUG fixture mode.")
        }
        let fixtureBlockBody = try XCTUnwrap(viewModelSource.swiftFunctionBody(named: "blockDebugFixtureExternalAction"))
        XCTAssertTrue(fixtureBlockBody.contains("bannerMessage = nil"))
        XCTAssertFalse(fixtureBlockBody.localizedCaseInsensitiveContains("DEBUG fixture mode"))
        XCTAssertFalse(viewModelSource.contains("ProcessInfo.processInfo.environment[\"TOKENPILOT_UI_TESTING\"] == \"1\" ? AppSettings() : settingsStore.load()"))
        XCTAssertFalse(viewModelSource.contains("guard ProcessInfo.processInfo.environment[\"TOKENPILOT_UI_TESTING\"] != \"1\" else { return }"))

        let fixtureMarker = "// MARK: - DEBUG deterministic fixtures"
        let fixtureStart = try XCTUnwrap(viewModelSource.range(of: fixtureMarker))
        let fixtureSource = String(viewModelSource[fixtureStart.lowerBound...])
        XCTAssertTrue(fixtureSource.contains("#if DEBUG"))
        XCTAssertTrue(fixtureSource.contains("TOKENPILOT_UI_TESTING"))
        XCTAssertTrue(fixtureSource.contains("TOKENPILOT_DEBUG_SCENARIO"))
        XCTAssertTrue(fixtureSource.contains("TOKENPILOT_DEBUG_SCREEN"))
        XCTAssertTrue(fixtureSource.contains("TOKENPILOT_DEBUG_LANGUAGE"))
        XCTAssertTrue(fixtureSource.contains("Date(timeIntervalSince1970: 1_784_289_600)"))
        XCTAssertTrue(fixtureSource.contains("privacyContract"))
        XCTAssertTrue(fixtureSource.contains("No network. No real provider accounts. No credentials. No local paths. No secrets."))
        XCTAssertFalse(viewModelSource.replacingOccurrences(of: fixtureSource, with: "").contains("TOKENPILOT_UI_TESTING"))
        XCTAssertFalse(viewModelSource.replacingOccurrences(of: fixtureSource, with: "").contains("TOKENPILOT_DEBUG_SCENARIO"))
        XCTAssertFalse(viewModelSource.replacingOccurrences(of: fixtureSource, with: "").contains("TOKENPILOT_DEBUG_SCREEN"))
        XCTAssertFalse(viewModelSource.replacingOccurrences(of: fixtureSource, with: "").contains("TOKENPILOT_DEBUG_LANGUAGE"))

        let approvedScenarios = [
            "empty",
            "claudeOfficialFresh",
            "claudeOfficialStale",
            "codexLocalOnly",
            "codexConnectorExperimental",
            "codexManual",
            "deepseekOfficialBalance",
            "deepseekManualBalance",
            "antigravityBridge",
            "runtimeRecoveryRequired",
            "alertsUnsupportedCodexLegacy",
            "alertsPendingDeepSeekCurrency"
        ]
        for scenario in approvedScenarios {
            XCTAssertTrue(fixtureSource.contains("case \(scenario)"), "Missing DEBUG fixture scenario: \(scenario)")
        }

        XCTAssertTrue(viewModelSource.contains("snapshots = fixture.snapshots"))
        XCTAssertTrue(viewModelSource.contains("capacityAssessments = fixture.capacityAssessments"))
        XCTAssertTrue(viewModelSource.contains("capacityPresentations = fixture.capacityPresentations"))
        XCTAssertTrue(viewModelSource.contains("capacityAlertRules = fixture.capacityAlertRules"))
        XCTAssertTrue(viewModelSource.contains("dataSources = fixture.dataSources"))
        XCTAssertTrue(fixtureSource.contains("detectedPaths: []"))
        XCTAssertTrue(fixtureSource.contains("customPath: nil"))
        XCTAssertTrue(fixtureSource.contains("source: \"debug-fixture\""))
        XCTAssertFalse(fixtureSource.contains("UserDefaults"))
        XCTAssertFalse(fixtureSource.contains("settingsStore.save"))
        XCTAssertFalse(fixtureSource.contains("KeychainService"))
        for visibleFixtureStatusLeak in [
            "statusMessage: \"DEBUG fixture",
            "Official statusline stale",
            "Local log activity only; not web quota",
            "UNOFFICIAL · Codex app-server limit hints",
            "Manual estimate",
            "Official balance endpoint",
            "Manual balance estimate",
            "Antigravity statusline bridge",
            "Legacy Codex local evidence is not alert-deliverable",
            "Manual fixture",
            "resetTimeText: \"fixed\""
        ] {
            XCTAssertFalse(fixtureSource.contains(visibleFixtureStatusLeak), "DEBUG fixture visible copy should be localized or omitted: \(visibleFixtureStatusLeak)")
        }

        for forbidden in ["/Users/", "~/", "Bearer ", "auth.json", "\".env\"", "id_rsa", "id_ed25519", "https://", "http://", "sk-", "pk-"] {
            XCTAssertFalse(fixtureSource.contains(forbidden), "DEBUG fixtures must not contain private paths, credential filenames, URLs, or secret-looking values: \(forbidden)")
        }
    }
    func testDataSourceModesStayTruthfulForCanonicalDebugEvidenceAndLocalizedLabels() throws {
        let viewModelSource = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))
        let fixtureMarker = "// MARK: - DEBUG deterministic fixtures"
        let fixtureStart = try XCTUnwrap(viewModelSource.range(of: fixtureMarker))
        let fixtureSource = String(viewModelSource[fixtureStart.lowerBound...])
        let modeBody = try XCTUnwrap(viewModelSource.swiftFunctionBody(named: "derivedDataSourceMode"))
        let expectedModeBody = try XCTUnwrap(fixtureSource.swiftFunctionBody(named: "expectedDataSourceMode"))

        for declaration in [
            "case live = \"LIVE\"",
            "case stale = \"STALE\"",
            "case local = \"LOCAL\"",
            "case manual = \"MANUAL\"",
            "case experimental = \"EXPERIMENTAL\"",
            "case compatibilityBridge = \"BRIDGE\"",
            "case mock = \"MOCK\"",
            "case disconnected = \"--\""
        ] {
            XCTAssertTrue(viewModelSource.contains(declaration), "Missing DataSourceMode declaration: \(declaration)")
        }

        XCTAssertTrue(viewModelSource.contains("dataSourceMode = determineDataMode(hasConnectedData: result.hasConnectedData, snapshots: result.snapshots, capacityObservations: result.capacityObservations, observedAt: result.observedAt)"))
        XCTAssertTrue(fixtureSource.contains("TokenPilotViewModel.derivedDataSourceMode("))
        XCTAssertTrue(fixtureSource.contains("assert(dataSourceMode == expectedDataSourceMode(for: scenario)"))

        let staleRange = try XCTUnwrap(modeBody.range(of: "return .stale"))
        let liveRange = try XCTUnwrap(modeBody.range(of: "return .live"))
        let experimentalRange = try XCTUnwrap(modeBody.range(of: "return .experimental"))
        let bridgeRange = try XCTUnwrap(modeBody.range(of: "return .compatibilityBridge"))
        let manualRange = try XCTUnwrap(modeBody.range(of: "return .manual"))
        let localRange = try XCTUnwrap(modeBody.range(of: "return .local"))
        XCTAssertLessThan(staleRange.lowerBound, liveRange.lowerBound)
        XCTAssertLessThan(liveRange.lowerBound, experimentalRange.lowerBound)
        XCTAssertLessThan(experimentalRange.lowerBound, bridgeRange.lowerBound)
        XCTAssertLessThan(bridgeRange.lowerBound, manualRange.lowerBound)
        XCTAssertLessThan(manualRange.lowerBound, localRange.lowerBound)

        let expectedScenarioModes = [
            "case .claudeOfficialFresh, .deepseekOfficialBalance:\n            return .live",
            "case .claudeOfficialStale:\n            return .stale",
            "case .codexLocalOnly, .alertsUnsupportedCodexLegacy:\n            return .local",
            "case .codexConnectorExperimental:\n            return .experimental",
            "case .codexManual, .deepseekManualBalance:\n            return .manual",
            "case .antigravityBridge:\n            return .compatibilityBridge",
            "case .empty, .runtimeRecoveryRequired, .alertsPendingDeepSeekCurrency:\n            return .disconnected"
        ]
        for expectation in expectedScenarioModes {
            XCTAssertTrue(expectedModeBody.contains(expectation), "Missing scenario mode expectation: \(expectation)")
        }

        XCTAssertTrue(fixtureSource.contains("case .codexLocalOnly:"))
        XCTAssertTrue(fixtureSource.contains("dataSource: .localLog"))
        XCTAssertTrue(fixtureSource.contains("case .codexConnectorExperimental:"))
        XCTAssertTrue(fixtureSource.contains("stability: .experimentalTransport"))
        XCTAssertTrue(fixtureSource.contains("case .codexManual:"))
        XCTAssertTrue(fixtureSource.contains("authority: .userEntered, stability: .manual"))
        XCTAssertTrue(fixtureSource.contains("case .deepseekManualBalance:"))
        XCTAssertTrue(fixtureSource.contains("moneyObservation(amount: \"8.75\", currency: \"USD\", authority: .userEntered, stability: .manual"))
        XCTAssertTrue(fixtureSource.contains("case .antigravityBridge:"))
        XCTAssertTrue(fixtureSource.contains("stability: .compatibilityBridge"))

        let localizedModes: [(String, String, String, String)] = [
            ("LIVE", "실시간", "ライブ", "实时"),
            ("LOCAL", "로컬", "ローカル", "本地"),
            ("MANUAL", "수동", "手動", "手动"),
            ("EXPERIMENTAL", "실험적", "実験的", "实验性"),
            ("BRIDGE", "브리지", "ブリッジ", "桥接"),
            ("MOCK", "목업", "モック", "模拟"),
            ("STALE", "오래됨", "古い", "过期")
        ]

        for (key, ko, ja, zhHans) in localizedModes {
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: .en), key)
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: .ko), ko)
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: .ja), ja)
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: .zhHans), zhHans)
        }
    }

    func testDebugFixtureResetDatesUseCurrentFixedReferenceClockForDeterministicScreenshots() throws {
        let viewModelSource = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))
        let fixtureMarker = "// MARK: - DEBUG deterministic fixtures"
        let fixtureStart = try XCTUnwrap(viewModelSource.range(of: fixtureMarker))
        let fixtureSource = String(viewModelSource[fixtureStart.lowerBound...])

        XCTAssertTrue(fixtureSource.contains("Date(timeIntervalSince1970: 1_784_289_600)"))
        XCTAssertTrue(fixtureSource.contains("resetAt: resetAfter.map { fixedReferenceDate.addingTimeInterval($0) }"))
        XCTAssertTrue(fixtureSource.contains("let assessments = observations.map { assessmentService.assess($0, now: fixedReferenceDate) }"))
        XCTAssertFalse(fixtureSource.contains("Date(timeIntervalSince1970: 1_700_000_000)"))
        XCTAssertFalse(fixtureSource.contains("Reset 0m"))
    }
    func testDebugScreenAndLanguageControlsAreUiTestingGatedValidatedAndNonPersistent() throws {
        let viewModelSource = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))
        let fixtureMarker = "// MARK: - DEBUG deterministic fixtures"
        let fixtureStart = try XCTUnwrap(viewModelSource.range(of: fixtureMarker))
        let fixtureSource = String(viewModelSource[fixtureStart.lowerBound...])

        let resolveBody = try XCTUnwrap(fixtureSource.swiftFunctionBody(named: "resolve"))
        XCTAssertTrue(resolveBody.contains("guard environment[\"TOKENPILOT_UI_TESTING\"] == \"1\" else { return nil }"))
        XCTAssertTrue(resolveBody.contains("TokenPilotDebugScenario(rawValue: rawScenario) ?? .empty"))
        XCTAssertTrue(resolveBody.contains("debugScreen(from: environment[\"TOKENPILOT_DEBUG_SCREEN\"])"))
        XCTAssertTrue(resolveBody.contains("debugLanguage(from: environment[\"TOKENPILOT_DEBUG_LANGUAGE\"])"))
        XCTAssertTrue(resolveBody.contains("return make(scenario).applying(selectedScreen: selectedScreen, language: language)"))

        let screenBody = try XCTUnwrap(fixtureSource.swiftFunctionBody(named: "debugScreen"))
        XCTAssertTrue(screenBody.contains("case .some(\"overview\"), .none:"))
        XCTAssertTrue(screenBody.contains("return .overview"))
        XCTAssertTrue(screenBody.contains("case .some(\"history\"):"))
        XCTAssertTrue(screenBody.contains("return .history"))
        XCTAssertTrue(screenBody.contains("case .some(\"settings\"):"))
        XCTAssertTrue(screenBody.contains("return .settings"))
        XCTAssertTrue(screenBody.contains("default:\n            return .overview"))

        let languageBody = try XCTUnwrap(fixtureSource.swiftFunctionBody(named: "debugLanguage"))
        XCTAssertTrue(languageBody.contains("case .some(\"en\"), .none:"))
        XCTAssertTrue(languageBody.contains("return .en"))
        XCTAssertTrue(languageBody.contains("case .some(\"ko\"):"))
        XCTAssertTrue(languageBody.contains("return .ko"))
        XCTAssertTrue(languageBody.contains("case .some(\"ja\"):"))
        XCTAssertTrue(languageBody.contains("return .ja"))
        XCTAssertTrue(languageBody.contains("case .some(\"zh-Hans\"):"))
        XCTAssertTrue(languageBody.contains("return .zhHans"))
        XCTAssertTrue(languageBody.contains("default:\n            return .en"))
        XCTAssertFalse(languageBody.contains("return .system"))

        let applyingBody = try XCTUnwrap(fixtureSource.swiftFunctionBody(named: "applying"))
        XCTAssertTrue(applyingBody.contains("var localizedSettings = settings"))
        XCTAssertTrue(applyingBody.contains("localizedSettings.localization.language = language"))
        XCTAssertTrue(applyingBody.contains("selectedScreen: selectedScreen"))
        XCTAssertTrue(applyingBody.contains("settings: localizedSettings"))
        XCTAssertFalse(applyingBody.contains("UserDefaults"))
        XCTAssertFalse(applyingBody.contains("settingsStore"))
        XCTAssertFalse(applyingBody.contains("save("))
        XCTAssertFalse(applyingBody.contains("persistSettingsDebounced"))
        XCTAssertFalse(applyingBody.contains("scheduleSettingsDrivenRefresh"))

        let releaseSource = String(viewModelSource[..<fixtureStart.lowerBound])
        XCTAssertFalse(releaseSource.contains("TOKENPILOT_DEBUG_SCREEN"))
        XCTAssertFalse(releaseSource.contains("TOKENPILOT_DEBUG_LANGUAGE"))
        XCTAssertTrue(releaseSource.contains("#else\n    init() {\n        self.settings = settingsStore.load()"))
    }
    func testDebugAccessibilityProfilesAreUiTestingGatedAppScopedAndReleaseIgnored() throws {
        let appSource = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("Sources/TokenApp/TokenMonitorApp.swift"))
        let designSource = try Self.tokenAppSourceFile("DesignSystem/TokenPilotDesign.swift")
        let componentsSource = try Self.tokenAppSourceFile("Views/Components.swift")
        let resolveBody = try XCTUnwrap(appSource.swiftFunctionBody(named: "resolve"))
        let modifierBody = try XCTUnwrap(appSource.swiftFunctionBody(named: "tokenPilotDebugAccessibilityProfile"))
        let releaseSource = Self.releasePreprocessedSource(from: appSource)

        XCTAssertTrue(appSource.contains("private enum TokenPilotDebugAccessibilityProfile: String"))
        XCTAssertTrue(appSource.contains("debugAccessibilityProfile = TokenPilotDebugAccessibilityProfile.resolve()"))
        XCTAssertTrue(appSource.contains("TokenPilotRootView(model: model)"))
        XCTAssertTrue(appSource.contains(".tokenPilotDebugAccessibilityProfile(debugAccessibilityProfile)"))

        for profileCase in ["case standard", "case reduceMotion", "case reduceTransparency", "case increaseContrast"] {
            XCTAssertTrue(appSource.contains(profileCase), "Missing accessibility profile case: \(profileCase)")
        }

        XCTAssertTrue(resolveBody.contains("guard environment[\"TOKENPILOT_UI_TESTING\"] == \"1\" else { return nil }"))
        XCTAssertTrue(resolveBody.contains("TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE"))
        XCTAssertTrue(resolveBody.contains("return .standard"))
        XCTAssertTrue(resolveBody.contains("guard let profile = Self(rawValue: rawProfile) else {"))
        XCTAssertTrue(resolveBody.contains("preconditionFailure(\"Invalid DEBUG TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE"))
        XCTAssertTrue(resolveBody.contains("return profile"))
        XCTAssertFalse(resolveBody.contains("?? .standard"))

        XCTAssertTrue(appSource.contains("var reduceMotion: Bool {\n        self == .reduceMotion\n    }"))
        XCTAssertTrue(appSource.contains("var reduceTransparency: Bool {\n        self == .reduceTransparency\n    }"))
        XCTAssertTrue(appSource.contains("var colorSchemeContrast: ColorSchemeContrast {\n        self == .increaseContrast ? .increased : .standard\n    }"))
        XCTAssertTrue(modifierBody.contains("environment(\\.tokenPilotReduceMotionOverride, profile.reduceMotion)"))
        XCTAssertTrue(modifierBody.contains("environment(\\.tokenPilotReduceTransparencyOverride, profile.reduceTransparency)"))
        XCTAssertTrue(modifierBody.contains("environment(\\.tokenPilotContrastOverride, profile.colorSchemeContrast)"))
        XCTAssertFalse(modifierBody.contains("environment(\\.accessibilityReduceMotion"))
        XCTAssertFalse(modifierBody.contains("environment(\\.accessibilityReduceTransparency"))
        XCTAssertFalse(modifierBody.contains("environment(\\.colorSchemeContrast"))
        XCTAssertTrue(designSource.contains("private struct TokenPilotReduceMotionOverrideKey: EnvironmentKey"))
        XCTAssertTrue(designSource.contains("private struct TokenPilotReduceTransparencyOverrideKey: EnvironmentKey"))
        XCTAssertTrue(designSource.contains("private struct TokenPilotContrastOverrideKey: EnvironmentKey"))
        XCTAssertTrue(designSource.contains("var tokenPilotReduceMotionOverride: Bool?"))
        XCTAssertTrue(designSource.contains("var tokenPilotReduceTransparencyOverride: Bool?"))
        XCTAssertTrue(designSource.contains("var tokenPilotContrastOverride: ColorSchemeContrast?"))
        XCTAssertTrue(designSource.contains("private struct TokenPilotSemanticPaletteKey: EnvironmentKey"))
        XCTAssertTrue(designSource.contains("var tokenPilotSemanticPalette: TokenPilotDesign.SemanticPalette"))
        XCTAssertTrue(designSource.contains("private struct TokenPilotSemanticPaletteModifier: ViewModifier"))
        XCTAssertTrue(designSource.contains("@Environment(\\.colorSchemeContrast) private var systemColorSchemeContrast"))
        XCTAssertTrue(designSource.contains("@Environment(\\.tokenPilotContrastOverride) private var contrastOverride"))
        XCTAssertTrue(designSource.contains("TokenPilotDesign.SemanticPalette(colorSchemeContrast: contrastOverride ?? systemColorSchemeContrast)"))
        XCTAssertTrue(designSource.contains("reduceTransparencyOverride ?? systemReduceTransparency"))
        XCTAssertTrue(appSource.contains(".tokenPilotSemanticPalette()"))
        XCTAssertTrue(componentsSource.contains("@Environment(\\.tokenPilotSemanticPalette) private var palette"))
        XCTAssertTrue(componentsSource.contains("reduceMotionOverride ?? systemReduceMotion"))
        XCTAssertTrue(componentsSource.contains("palette.borderColor()"))
        XCTAssertFalse(componentsSource.contains("@Environment(\\.tokenPilotContrastOverride) private var contrastOverride"))

        for forbidden in ["System Settings", "com.apple.universalaccess", "osascript", "AXIsProcessTrusted", "AXUIElement", "UserDefaults.standard"] {
            XCTAssertFalse(appSource.contains(forbidden), "DEBUG accessibility profiles must be app-scoped and non-persistent: \(forbidden)")
        }

        XCTAssertTrue(releaseSource.contains("_model = StateObject(wrappedValue: TokenPilotViewModel())"))
        XCTAssertTrue(releaseSource.contains("TokenPilotRootView(model: model)"))
        XCTAssertFalse(releaseSource.contains("TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE"))
        XCTAssertFalse(releaseSource.contains("debugAccessibilityProfile"))
        XCTAssertFalse(releaseSource.contains("accessibilityReduceMotion"))
        XCTAssertFalse(releaseSource.contains("accessibilityReduceTransparency"))
        XCTAssertFalse(releaseSource.contains("colorSchemeContrast"))
    }


    func testOverviewHeroRankingPinsCanonicalFixtureStatesWithoutProviderParsingMathDuplication() throws {
        let appSource = try Self.tokenMonitorAppSource()
        let viewModelSource = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))
        let fixtureMarker = "// MARK: - DEBUG deterministic fixtures"
        let fixtureStart = try XCTUnwrap(viewModelSource.range(of: fixtureMarker))
        let fixtureSource = String(viewModelSource[fixtureStart.lowerBound...])
        let rankBody = try XCTUnwrap(appSource.swiftFunctionBody(named: "capacityDisplayRank"))

        XCTAssertTrue(appSource.contains("items.sorted { capacityDisplayRank($0) > capacityDisplayRank($1) }.first"))
        XCTAssertTrue(rankBody.contains("case .percent: eligibilityRank = 100"))
        XCTAssertTrue(rankBody.contains("case .balance: eligibilityRank = 70"))
        XCTAssertTrue(rankBody.contains("case .ineligible: eligibilityRank = 20"))
        XCTAssertTrue(rankBody.contains("case .critical: riskRank = 60"))
        XCTAssertTrue(rankBody.contains("case .warning: riskRank = 50"))
        XCTAssertTrue(rankBody.contains("case .normal: riskRank = 40"))
        XCTAssertTrue(rankBody.contains("case .informational: riskRank = 30"))
        XCTAssertTrue(rankBody.contains("case .stale: riskRank = 10"))
        XCTAssertTrue(rankBody.contains("case .unavailable: riskRank = 0"))
        XCTAssertFalse(rankBody.contains("ProviderSnapshot("))
        XCTAssertFalse(rankBody.contains("usedPercent"))
        XCTAssertFalse(rankBody.contains("remainingPercent"))

        XCTAssertTrue(fixtureSource.contains("case .claudeOfficialFresh:"))
        XCTAssertTrue(fixtureSource.contains("percentObservation(seriesID: claudeFiveHourSeries(), used: 58"))
        XCTAssertTrue(fixtureSource.contains("authority: .providerReported, stability: .supported, comparability: .comparable"))
        XCTAssertTrue(fixtureSource.contains("case .deepseekOfficialBalance:"))
        XCTAssertTrue(fixtureSource.contains("moneyObservation(amount: \"3.34\", currency: \"USD\", authority: .providerReported, stability: .supported, comparability: .comparable)"))
        XCTAssertTrue(fixtureSource.contains("balanceAlertRule(threshold: \"5.00\", currency: \"USD\")"))
        XCTAssertTrue(fixtureSource.contains("case .codexManual:"))
        XCTAssertTrue(fixtureSource.contains("authority: .userEntered, stability: .manual, comparability: .incomparable"))
        XCTAssertTrue(fixtureSource.contains("case .claudeOfficialStale:"))
        XCTAssertTrue(fixtureSource.contains("freshnessSeconds: 3_600"))
        XCTAssertTrue(fixtureSource.contains("case .empty:"))
        XCTAssertTrue(fixtureSource.contains("return fixture(scenario: scenario, settings: baseSettings(), dataSourceMode: .disconnected)"))
        XCTAssertTrue(fixtureSource.contains("case .runtimeRecoveryRequired:"))
        XCTAssertTrue(fixtureSource.contains("capacityRuntimeRecoveryRequired: true"))
        XCTAssertTrue(fixtureSource.contains("Capacity runtime recovery required; safe defaults are active."))
    }
    func testRuntimeRecoveryFixtureUiHidesInternalCodesAndLocalizesRecoveryErrorCopy() throws {
        let overviewSource = try Self.tokenAppSourceFile("Views/OverviewScreen.swift")
        let viewModelSource = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))
        let fixtureMarker = "// MARK: - DEBUG deterministic fixtures"
        let fixtureStart = try XCTUnwrap(viewModelSource.range(of: fixtureMarker))
        let fixtureSource = String(viewModelSource[fixtureStart.lowerBound...])
        let alertStatusStart = try XCTUnwrap(viewModelSource.range(of: "    var alertStatusText: String {"))
        let alertStatusEnd = try XCTUnwrap(
            viewModelSource.range(
                of: "\n    private var currentCapacityAlertChannels",
                range: alertStatusStart.upperBound..<viewModelSource.endIndex
            )
        )
        let alertStatusSource = String(viewModelSource[alertStatusStart.lowerBound..<alertStatusEnd.lowerBound])
        let alertDetailBody = try XCTUnwrap(viewModelSource.swiftFunctionBody(named: "capacityAlertRowDetail"))
        let recoveryMessageKey = "Capacity runtime recovery required; safe defaults are active."

        XCTAssertTrue(fixtureSource.contains("case .runtimeRecoveryRequired:"))
        XCTAssertTrue(fixtureSource.contains("code: \"runtimeRecoveryRequired\""))
        XCTAssertTrue(fixtureSource.contains("redactedMessage: \"\(recoveryMessageKey)\""))
        XCTAssertTrue(overviewSource.contains("Text(localized(error.redactedMessage, language: language))"))
        XCTAssertTrue(overviewSource.contains("return localized(error.redactedMessage, language: language)"))
        XCTAssertFalse(overviewSource.contains("Text(error.redactedMessage)"))

        XCTAssertTrue(alertStatusSource.contains("if summary.recoveryRequired {\n            parts.append(t(\"Recovery needed\"))"))
        XCTAssertFalse(alertStatusSource.contains("recoveryCodes"))
        XCTAssertFalse(alertStatusSource.contains("runtimeRecoveryRequired"))
        XCTAssertFalse(alertDetailBody.contains("row.recoveryCode"))
        XCTAssertFalse(alertDetailBody.contains("runtimeRecoveryRequired"))


        XCTAssertEqual(TokenPilotLocalizer.localized(recoveryMessageKey, language: .en), recoveryMessageKey)
        XCTAssertFalse(TokenPilotLocalizer.localized(recoveryMessageKey, language: .en).contains("runtimeRecoveryRequired"))

        let recoverySummary = CapacityAlertVisibilityBuilder().make(
            runtime: CapacityRuntimeControl(assessmentEnabled: false),
            runtimeStatus: .recoveryRequired(writeBlocked: true, code: "runtimeRecoveryRequired"),
            rules: [],
            rulesStatus: .ready(source: .absentDefault, generation: nil),
            deliveryStates: [:],
            deliveryStatus: .ready(source: .absentDefault, generation: nil),
            channels: CapacityAlertChannelSettings()
        )
        XCTAssertEqual(recoverySummary.status, .recoveryRequired)
        XCTAssertEqual(recoverySummary.recoveryCodes, ["runtimeRecoveryRequired"])
        XCTAssertEqual(recoverySummary.rows.first?.recoveryCode, "runtimeRecoveryRequired")

        let nonEnglishCopies: [(TokenPilotLanguage, String)] = [
            (.ko, "수용량 런타임 복구가 필요합니다. 안전 기본값이 활성화되어 있습니다."),
            (.ja, "容量ランタイムの復旧が必要です。安全な既定値が有効です。"),
            (.zhHans, "需要恢复容量运行时；安全默认值已启用。")
        ]
        for (language, expected) in nonEnglishCopies {
            let localizedCopy = TokenPilotLocalizer.localized(recoveryMessageKey, language: language)
            XCTAssertEqual(localizedCopy, expected)
            XCTAssertNotEqual(localizedCopy, recoveryMessageKey)
            XCTAssertFalse(localizedCopy.localizedCaseInsensitiveContains("safe defaults"))
            XCTAssertFalse(localizedCopy.localizedCaseInsensitiveContains("Capacity runtime recovery required"))
        }
    }

    func testUnsupportedCodexLegacyFixtureLocalizesNonDeliverableCopyAcrossLocales() throws {
        let overviewSource = try Self.tokenAppSourceFile("Views/OverviewScreen.swift")
        let viewModelSource = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("Sources/TokenApp/ViewModels/TokenPilotViewModel.swift"))
        let fixtureMarker = "// MARK: - DEBUG deterministic fixtures"
        let fixtureStart = try XCTUnwrap(viewModelSource.range(of: fixtureMarker))
        let fixtureSource = String(viewModelSource[fixtureStart.lowerBound...])
        let messageKey = "Codex legacy capacity alerts are unsupported for delivery."
        let expectedCopies: [(language: TokenPilotLanguage, locale: String, value: String)] = [
            (.en, "en", messageKey),
            (.ko, "ko", "Codex 레거시 수용량 알림은 전달을 지원하지 않습니다."),
            (.ja, "ja", "Codex レガシー容量アラートは配信に対応していません。"),
            (.zhHans, "zh-Hans", "Codex 旧版容量提醒不支持投递。")
        ]

        XCTAssertTrue(fixtureSource.contains("case .alertsUnsupportedCodexLegacy:"))
        XCTAssertTrue(fixtureSource.contains("code: \"debugUnsupportedCodexLegacy\""))
        XCTAssertTrue(fixtureSource.contains("redactedMessage: \"\(messageKey)\""))
        XCTAssertTrue(overviewSource.contains("Text(localized(error.redactedMessage, language: language))"))
        XCTAssertTrue(overviewSource.contains("return localized(error.redactedMessage, language: language)"))

        let catalogURL = try Self.projectRootURL()
            .appendingPathComponent("Sources/TokenApp/Resources/Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalogRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalogStrings = try XCTUnwrap(catalogRoot["strings"] as? [String: Any])
        let catalogEntry = try XCTUnwrap(catalogStrings[messageKey] as? [String: Any])
        let localizations = try XCTUnwrap(catalogEntry["localizations"] as? [String: Any])

        for (language, locale, expectedValue) in expectedCopies {
            let localizedCopy = TokenPilotLocalizer.localized(messageKey, language: language)
            XCTAssertFalse(localizedCopy.isEmpty, "Empty runtime fallback for \(locale)")
            XCTAssertEqual(localizedCopy, expectedValue, "Wrong runtime fallback for \(locale)")

            let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "Missing catalog locale \(locale)")
            let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "Missing catalog string unit \(locale)")
            let catalogValue = try XCTUnwrap(stringUnit["value"] as? String, "Missing catalog value \(locale)")
            XCTAssertFalse(catalogValue.isEmpty, "Empty catalog value for \(locale)")
            XCTAssertEqual(catalogValue, expectedValue, "Wrong catalog value for \(locale)")
        }

        for expected in expectedCopies where expected.language != .en {
            let localizedCopy = TokenPilotLocalizer.localized(messageKey, language: expected.language)
            XCTAssertNotEqual(localizedCopy, messageKey)
            XCTAssertFalse(localizedCopy.localizedCaseInsensitiveContains("unsupported for delivery"))
            XCTAssertFalse(localizedCopy.localizedCaseInsensitiveContains("legacy capacity alerts"))
        }
    }


    func testOverviewOmitsChallengeAndPromotionalUsageAnalyticsCards() throws {
        let source = try Self.tokenMonitorAppSource()

        XCTAssertFalse(source.contains("ChallengeCard("))
        XCTAssertFalse(source.contains("struct ChallengeCard"))
        XCTAssertFalse(source.contains("overviewUsage.sevenDayBars"))
        XCTAssertFalse(source.contains("overviewUsage.providerShare"))
    }

    func testActiveCapacityRowsPreferRemainingPercentCopy() throws {
        let overviewSource = try Self.tokenAppSourceFile("Views/OverviewScreen.swift")
        let historySource = try Self.tokenAppSourceFile("Views/HistoryScreen.swift")

        XCTAssertTrue(overviewSource.contains("var remainingPercent: Int? { Int(presentation.data[\"remainingPercent\"] ?? \"\") }"))
        XCTAssertTrue(overviewSource.contains("var progressPercent: Int? {\n        valueKind == .percent ? remainingPercent : nil\n    }"))
        XCTAssertTrue(overviewSource.contains("return \"\\(remainingPercent)%\""))
        XCTAssertTrue(overviewSource.contains("value: item.primaryValue(language: language)"))
        XCTAssertTrue(overviewSource.contains("value: primary.primaryValue(language: language)"))
        XCTAssertTrue(overviewSource.contains("percent: progressPercent"))
        XCTAssertTrue(overviewSource.contains("accessibilityLabel: localized(\"Remaining capacity\", language: language)"))
        XCTAssertTrue(overviewSource.contains("primary.progressAccessibilityValue(language: language)"))
        XCTAssertTrue(historySource.contains("Text(String(format: model.t(\"Remaining %d%%\"), sample.remainingPercent))"))
        XCTAssertTrue(historySource.contains("percent: sample.remainingPercent"))
        XCTAssertTrue(historySource.contains("\"\\(model.t(\"Remaining\")) \\(sample.remainingPercent)%, \\(model.t(\"Used\")) \\(sample.usedPercent)%\""))
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
        XCTAssertTrue(readme.contains("Antigravity CLI setup"))
        XCTAssertTrue(readme.contains("antigravity-statusline.json"))
        XCTAssertTrue(readme.contains("do not claim notarization"))
        XCTAssertFalse(readme.contains("notarized and App Store-ready"))
        XCTAssertTrue(readme.contains("DeepSeek balance"))
        XCTAssertTrue(readme.contains("README.ja.md"))
        XCTAssertTrue(readme.contains("README.zh-CN.md"))
    }

    func testReadmesDocumentDeepSeekScreenshotAndOmitRemovedSurfaces() throws {
        let rootURL = try Self.projectRootURL()
        let readmePaths = ["README.md", "README.ko.md", "README.ja.md", "README.zh-CN.md"]

        let removedSurfaceMarkers = [
            "daily challenge",
            "일일 챌린지",
            "7-day",
            "7일 chart",
            "provider share",
            "Last 7 days",
            "# Executed "
        ]

        for path in readmePaths {
            let readme = try String(contentsOf: rootURL.appendingPathComponent(path))
            XCTAssertTrue(readme.contains("docs/assets/readme-screenshot.png"), "\(path) should show the README screenshot.")
            XCTAssertTrue(readme.contains("DeepSeek"), "\(path) should document DeepSeek.")
            XCTAssertTrue(readme.contains("topped_up_balance"), "\(path) should name the official DeepSeek balance field.")
            XCTAssertTrue(readme.contains("/user/balance"), "\(path) should document the DeepSeek balance endpoint.")
            for marker in removedSurfaceMarkers {
                XCTAssertFalse(readme.localizedCaseInsensitiveContains(marker), "\(path) should not advertise stale removed surface: \(marker)")
            }
        }
    }

    func testReleaseDocsAvoidBrittleTestCountsAndStalePassClaims() throws {
        let rootURL = try Self.projectRootURL()
        let documentationPaths = [
            "README.md",
            "README.ko.md",
            "docs/verification/developer-id-capacity-release.md"
        ]

        for path in documentationPaths {
            let document = try String(contentsOf: rootURL.appendingPathComponent(path))
            XCTAssertNil(
                document.range(of: #"Tests-[0-9]+"#, options: .regularExpression),
                "\(path) should not publish a brittle tests-count badge."
            )
            XCTAssertNil(
                document.range(of: #"[0-9]+\s+passing"#, options: [.regularExpression, .caseInsensitive]),
                "\(path) should not publish a stale passing-count claim."
            )
            XCTAssertNil(
                document.range(of: #"\bPASS\b"#, options: .regularExpression),
                "\(path) should record current evidence instead of permanent PASS claims."
            )
            XCTAssertFalse(document.contains("# Executed 187 tests"), "\(path) should not preserve stale test-run output.")
            XCTAssertFalse(document.contains("swift test                                  PASS"), "\(path) should not preserve stale swift test PASS output.")
            XCTAssertFalse(document.contains("make bundle / make verify                  PASS"), "\(path) should not preserve stale bundle/verify PASS output.")
        }

        let koreanReadme = try String(contentsOf: rootURL.appendingPathComponent("README.ko.md"))
        XCTAssertTrue(koreanReadme.contains("이 문서는 특정 머신의 오래된 통과 결과를 고정 기록하지 않습니다."))
        XCTAssertTrue(koreanReadme.contains("아래 명령은 재현 절차이며 최신 통과 기록이 아닙니다."))
    }

    func testDeveloperIdReleaseDocRequiresExecutableFixtureQAPackage() throws {
        let releaseDoc = try String(contentsOf: try Self.projectRootURL().appendingPathComponent("docs/verification/developer-id-capacity-release.md"))
        let scenarios = [
            "empty",
            "claudeOfficialFresh",
            "claudeOfficialStale",
            "codexLocalOnly",
            "codexConnectorExperimental",
            "codexManual",
            "deepseekOfficialBalance",
            "deepseekManualBalance",
            "antigravityBridge",
            "runtimeRecoveryRequired",
            "alertsUnsupportedCodexLegacy",
            "alertsPendingDeepSeekCurrency"
        ]

        XCTAssertTrue(releaseDoc.contains("actual executable product `TokenMonitor`"))
        for scenario in scenarios {
            XCTAssertTrue(
                releaseDoc.contains("TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=\(scenario) TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor"),
                "Release QA docs should include the five-env-var executable fixture command for \(scenario)."
            )
        }

        let requiredMarkers = [
            "TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=<scenario> TOKENPILOT_DEBUG_SCREEN=<overview|history|settings> TOKENPILOT_DEBUG_LANGUAGE=<en|ko|ja|zh-Hans> TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=<standard|reduceMotion|reduceTransparency|increaseContrast> swift run TokenMonitor",
            "TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard",
            "ignored `.gjc/evidence/redesign/`",
            "\"schema\": \"tokenpilot.redesign.qa.manifest.v1\"",
            "\"artifactBuildSHA\"",
            "\"generatedAt\"",
            "\"counts\"",
            "\"baseline\": 36",
            "\"locale\": 60",
            "\"accessibility\": 45",
            "\"rows\": 141",
            "\"uniqueScreenshots\": 126",
            "\"productTarget\": \"TokenMonitor\"",
            "\"scenario\"",
            "\"screen\"",
            "\"locale\"",
            "\"accessibilityProfile\"",
            "\"matrix\": \"baseline\"",
            "\"windowDimensions\": { \"width\": 420, \"height\": 620 }",
            "\"screenshotPath\"",
            "\"screenshotSHA256\"",
            "\"transcriptPath\"",
            "\"transcriptSHA256\"",
            "\"tester\"",
            "\"capturedAt\"",
            "\"status\": \"pass\"",
            "\"blockedReason\": null",
            "screenshot coverage >=99/100",
            "transcript coverage >=99/100",
            "evidence scoring >=99/100",
            "Baseline scenario/screen matrix — 36 rows",
            "Locale sentinel matrix — 60 rows",
            "unique screenshot count remains 126 rather than 141",
            "Accessibility matrix — 45 captured rows",
            "`standard`, `reduceMotion`, `reduceTransparency`, and `increaseContrast`",
            "app-owned optional SwiftUI environment override keys",
            "macOS accessibility settings are never changed by automation",
            "Automation must not mutate macOS settings",
            "manual final spot-check remains optional and user-controlled",
            "Xcode `TokenPilot` app target alternative",
            "current-build popover screenshot",
            "popover transcript",
            "420×620",
            "keyboard navigation",
            "VoiceOver order",
            "KO/EN/JA/zh-Hans overflow",
            "Reduced Motion",
            "Reduce Transparency",
            "High Contrast",
            "permission-blocked results must be recorded as blocked—not pass",
            "A blocked row never satisfies the release gate until rerun with evidence."
        ]

        for marker in requiredMarkers {
            XCTAssertTrue(releaseDoc.contains(marker), "Missing release QA requirement: \(marker)")
        }
        for forbidden in ["same four environment variables", "keyboard-voiceover", "reduced-motion", "high-contrast", "record the active macOS setting", "tokenpilot.redesign.evidence.v1", "\"currentBuild\"", "\"dimensions\": \"420x620\"", "\"launch\"", "\"screenshotSha256\"", "\"transcriptSha256\"", "\"status\": \"complete\"", "sha256-hex-or-null", "or-current", "local-debug-or-release", "\"blocker\": null"] {
            XCTAssertFalse(releaseDoc.contains(forbidden), "Release QA docs should not contain stale manifest or system-mutation marker: \(forbidden)")
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

    func testXAIProviderFoundationContainsNoURLSessionOrEndpointByDefault() throws {
        let servicesSource = try Self.tokenCoreServicesSource()
        let adapterStart = try XCTUnwrap(servicesSource.range(of: "public struct XAIManagementDiagnosticsAdapter"))
        let adapterEnd = try XCTUnwrap(
            servicesSource.range(
                of: "\npublic enum CapacityObservationFactory",
                range: adapterStart.upperBound..<servicesSource.endIndex
            )
        )
        let adapterSource = String(servicesSource[adapterStart.lowerBound..<adapterEnd.lowerBound])
        let classifyXAI = try XCTUnwrap(servicesSource.swiftFunctionBody(named: "classifyXAI"))
        let viewModelSource = try Self.tokenAppSourceFile("ViewModels/TokenPilotViewModel.swift")
        let saveKeyBody = try XCTUnwrap(viewModelSource.swiftFunctionBody(named: "saveXAIManagementAPIKey"))
        let updateTeamBody = try XCTUnwrap(viewModelSource.swiftFunctionBody(named: "updateXAITeamID"))
        let xaiSource = [adapterSource, classifyXAI, saveKeyBody, updateTeamBody].joined(separator: "\n")

        for forbidden in ["URLSession", "URLRequest", "HTTPURLResponse", "https://", "api.x.ai", "x.ai/api", "/v1/"] {
            XCTAssertFalse(xaiSource.localizedCaseInsensitiveContains(forbidden), "xAI foundation must not contain network endpoint or URLSession marker: \(forbidden)")
        }

        XCTAssertTrue(adapterSource.contains("capacityObservations: []"))
        XCTAssertTrue(adapterSource.contains("typedErrors: []"))
        XCTAssertTrue(adapterSource.contains("Management authentication unconfirmed"))
        XCTAssertTrue(classifyXAI.contains("detectedPaths: []"))
        XCTAssertTrue(saveKeyBody.contains("keychain.saveSecret(key, account: Self.xAIManagementAPIKeyAccount)"))
        XCTAssertTrue(saveKeyBody.contains("No xAI HTTP requests are sent."))
        XCTAssertTrue(updateTeamBody.contains("trimmedXAITeamID"))
    }

    func testSettingsXAITeamIDEntryDoesNotBindOrRenderPersistedValue() throws {
        let settingsSource = try Self.tokenAppSourceFile("Views/SettingsScreen.swift")

        XCTAssertTrue(settingsSource.contains("@State private var xAITeamIDInput = \"\""))
        XCTAssertTrue(settingsSource.contains("SecureField(model.xAITeamIDConfigured ? model.t(\"Saved team ID masked\") : model.t(\"xAI Team ID\"), text: $xAITeamIDInput)"))
        XCTAssertTrue(settingsSource.contains("Button(model.t(\"Save Team ID\"))"))
        XCTAssertTrue(settingsSource.contains("Button(model.t(\"Delete Team ID\"), role: .destructive)"))
        XCTAssertTrue(settingsSource.contains("model.updateXAITeamID(xAITeamIDInput)"))
        XCTAssertTrue(settingsSource.contains("model.updateXAITeamID(\"\")"))
        XCTAssertTrue(settingsSource.contains(".disabled(xAITeamIDInputIsEmpty)"))
        XCTAssertTrue(settingsSource.contains("accessibilityValue(model.xAITeamIDConfigured ? model.t(\"Team ID set\") : model.t(\"No team ID\"))"))

        XCTAssertFalse(settingsSource.contains("TextField(model.t(\"xAI Team ID\"), text: xAITeamIDBinding)"))
        XCTAssertFalse(settingsSource.contains("private var xAITeamIDBinding"))
        XCTAssertFalse(settingsSource.contains("model.settings.xAI.teamID"))
        XCTAssertTrue(settingsSource.contains("guard model.isProviderEnabled(.xai) else { return model.t(\"Disabled\") }"))
        XCTAssertTrue(settingsSource.contains("provider == .xai && model.isProviderEnabled(.xai) && !model.hasSavedXAIManagementAPIKey"))
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
        let historySource = try Self.tokenAppSourceFile("Views/HistoryScreen.swift")
        let sourceCollapsed = source.collapsedWhitespace
        let historyCollapsed = historySource.collapsedWhitespace

        XCTAssertTrue(source.contains("@Published var selectedHistoryPeriod: HistoryPeriod = .last7Days"))
        XCTAssertTrue(source.contains("rebuildHistoryUsage(for: selectedHistoryPeriod)"))
        XCTAssertFalse(
            sourceCollapsed.contains(".onReceive(model.$selectedHistoryPeriod.removeDuplicates())"),
            "History should not subscribe to and write back the same selectedHistoryPeriod publisher; that feedback loop can spin during Settings → History navigation."
        )
        XCTAssertFalse(
            sourceCollapsed.contains(".onChange(of: model.selectedHistoryPeriod"),
            "History should not react to selectedHistoryPeriod changes by mutating the same state during view updates."
        )
        XCTAssertFalse(
            historySource.contains("HistoryPeriodControl"),
            "History should not define or render a period picker/control; the redesign uses the fixed selected history period."
        )
        XCTAssertFalse(
            historyCollapsed.contains("Picker(model.t(\"Period\")"),
            "History screen should not have a period picker."
        )
        XCTAssertFalse(
            historySource.contains("ForEach(HistoryPeriod.allCases)"),
            "History screen should not expose period choices."
        )
        XCTAssertFalse(
            historySource.contains("model.selectHistoryPeriod("),
            "History view should not invoke selectHistoryPeriod while using the fixed history period."
        )

        let selectionBody = try XCTUnwrap(
            source.swiftFunctionBody(named: "selectHistoryPeriod"),
            "Could not find function body for selectHistoryPeriod"
        )
        XCTAssertTrue(
            selectionBody.contains("if selectedHistoryPeriod != period"),
            "selectHistoryPeriod should preserve guarded state updates for non-view callers."
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

    private static func releasePreprocessedSource(from source: String) -> String {
        var output: [String] = []
        var debugStack: [Bool] = []

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "#if DEBUG" {
                debugStack.append(true)
                continue
            }

            if trimmed == "#else", !debugStack.isEmpty {
                debugStack[debugStack.count - 1] = false
                continue
            }

            if trimmed == "#endif", !debugStack.isEmpty {
                debugStack.removeLast()
                continue
            }

            if !debugStack.contains(true) {
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
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

    private static func tokenAppSourceFile(_ relativePath: String) throws -> String {
        let tokenAppDir = try projectRootURL()
            .appendingPathComponent("Sources/TokenApp")
        let sourceURL = relativePath.split(separator: "/").reduce(tokenAppDir) { url, component in
            url.appendingPathComponent(String(component))
        }
        return try String(contentsOf: sourceURL)
    }

    private static func tokenCoreModelsSource() throws -> String {
        let tokenCoreModelsFile = try projectRootURL()
            .appendingPathComponent("Sources/TokenCore/Models/TokenPilotModels.swift")
        return try String(contentsOf: tokenCoreModelsFile)
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
    func testCapacitySeriesCanonicalIdentityAndValidation() throws {
        let series = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, durationMinutes: 300)
        XCTAssertEqual(series.canonicalID, "claude/five-hour/fixedReset/percent/300")
        XCTAssertTrue(series.supportsReset)

        XCTAssertNoThrow(try CapacitySeriesID(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, unit: .percent, durationMinutes: 10_080))
        XCTAssertNoThrow(try CapacitySeriesID(provider: .codex, providerWindowID: "rolling", kind: .rolling, unit: .percent, durationMinutes: 240))
        XCTAssertEqual(try CapacitySeriesID(provider: .codex, providerWindowID: "primary", kind: .rolling, unit: .percent, durationMinutes: 15).canonicalID, "codex/primary/rolling/percent/15")
        XCTAssertNoThrow(try CapacitySeriesID(provider: .gemini, providerWindowID: "daily-requests", kind: .calendarCap, unit: .requestCount))
        XCTAssertNoThrow(try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency))
        XCTAssertNoThrow(try CapacitySeriesID(provider: .claude, providerWindowID: "context", kind: .context, unit: .tokens))

        XCTAssertThrowsError(try CapacitySeriesID(provider: .claude, providerWindowID: "Five Hour", kind: .fixedReset, unit: .percent))
        XCTAssertThrowsError(try CapacitySeriesID(provider: .claude, providerWindowID: "unknown", kind: .fixedReset, unit: .percent))
        XCTAssertThrowsError(try CapacitySeriesID(provider: .codex, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent))
        XCTAssertThrowsError(try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .balance, unit: .currency))
        XCTAssertThrowsError(try CapacitySeriesID(provider: .claude, providerWindowID: "context", kind: .fixedReset, unit: .tokens))
        XCTAssertThrowsError(try CapacitySeriesID(provider: .gemini, providerWindowID: "daily-requests", kind: .balance, unit: .currency))
        XCTAssertThrowsError(try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, durationMinutes: 0))
        XCTAssertThrowsError(try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent, durationMinutes: 301))
    }

    func testCapacityCodableBoundariesRejectInvalidValuesAndSeries() throws {
        let decoder = JSONDecoder()

        XCTAssertThrowsError(try decoder.decode(CapacitySeriesID.self, from: data("""
        {"provider":"claude","providerWindowID":"Five Hour","kind":"fixedReset","unit":"percent","durationMinutes":0}
        """)))
        XCTAssertThrowsError(try decoder.decode(CapacitySeriesID.self, from: data("""
        {"provider":"claude","providerWindowID":"five-hour","kind":"balance","unit":"currency"}
        """)))
        let decodedPercent = try decoder.decode(CapacityValue.self, from: data(#"{"usedPercent":{"_0":50}}"#))
        XCTAssertEqual(decodedPercent.kind, .percent)
        XCTAssertEqual(decodedPercent.usedPercent, 50)
        let decodedMoney = try decoder.decode(CapacityValue.self, from: data(#"{"money":{"_0":1,"currency":"USD"}}"#))
        XCTAssertEqual(decodedMoney.kind, .currency)
        XCTAssertEqual(decodedMoney.moneyAmount, Decimal(1))
        XCTAssertEqual(decodedMoney.currency, "USD")
        XCTAssertEqual(try decoder.decode(CapacityValue.self, from: JSONEncoder().encode(decodedPercent)), decodedPercent)

        XCTAssertThrowsError(try decoder.decode(CapacityValue.self, from: data(#"{"usedPercent":{"_0":101}}"#)))
        XCTAssertThrowsError(try decoder.decode(CapacityValue.self, from: data(#"{"money":{"_0":-1,"currency":"USD"}}"#)))
        XCTAssertThrowsError(try decoder.decode(CapacityValue.self, from: data(#"{"money":{"_0":1,"currency":"usd"}}"#)))
        XCTAssertThrowsError(try decoder.decode(CapacityValue.self, from: data(#"{"count":{"_0":-1}}"#)))
        XCTAssertThrowsError(try decoder.decode(CapacityValue.self, from: data(#"{"tokens":{"_0":-1}}"#)))
        XCTAssertThrowsError(try decoder.decode(CapacityValue.self, from: data(#"{"usedPercent":{"_0":50},"count":{"_0":1}}"#)))
    }

    func testCapacityValueAndObservationBoundaries() throws {
        let source = try Self.tokenCoreModelsSource()
        XCTAssertTrue(source.contains("public struct CapacityValue"))
        XCTAssertFalse(source.contains("public enum CapacityValue"))
        XCTAssertTrue(source.contains("private let storage: Storage"))

        let zero = try CapacityValue(usedPercent: 0)
        let full = try CapacityValue(usedPercent: 100)
        XCTAssertEqual(zero.kind, .percent)
        XCTAssertEqual(zero.usedPercent, 0)
        XCTAssertEqual(full.usedPercent, 100)
        XCTAssertThrowsError(try CapacityValue(usedPercent: 101))

        let balance = try CapacityValue(money: 0, currency: "USD")
        XCTAssertEqual(balance.kind, .currency)
        XCTAssertEqual(balance.moneyAmount, Decimal(0))
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertThrowsError(try CapacityValue(money: -1, currency: "USD"))
        XCTAssertThrowsError(try CapacityValue(money: 1, currency: "usd"))

        let count = try CapacityValue(count: 0)
        let tokens = try CapacityValue(tokens: 1)
        XCTAssertEqual(count.kind, .requestCount)
        XCTAssertEqual(count.count, 0)
        XCTAssertEqual(tokens.kind, .tokens)
        XCTAssertEqual(tokens.tokens, 1)
        XCTAssertThrowsError(try CapacityValue(count: -1))
        XCTAssertThrowsError(try CapacityValue(tokens: -1))

        let now = Date(timeIntervalSince1970: 1_000_000)
        let series = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        let contextSeries = try CapacitySeriesID(provider: .codex, providerWindowID: "context", kind: .context, unit: .tokens)
        let value = try CapacityValue(usedPercent: 70)

        XCTAssertNoThrow(try CapacityObservation(seriesID: series, observedAt: now.addingTimeInterval(60), value: value, authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now))
        XCTAssertThrowsError(try CapacityObservation(seriesID: series, observedAt: now.addingTimeInterval(61), value: value, authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now))
        XCTAssertNoThrow(try CapacityObservation(seriesID: series, observedAt: now.addingTimeInterval(-45 * 86_400), value: value, authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now))
        XCTAssertThrowsError(try CapacityObservation(seriesID: series, observedAt: now.addingTimeInterval(-45 * 86_400 - 1), value: value, authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now))
        XCTAssertThrowsError(try CapacityObservation(seriesID: contextSeries, observedAt: now, resetAt: now.addingTimeInterval(3_600), value: try CapacityValue(tokens: 1), authority: .localDerived, stability: .manual, freshnessPolicy: .init(maximumAge: 900), comparability: .incomparable, parserRevision: "test", now: now))
        XCTAssertThrowsError(try CapacityObservation(seriesID: series, observedAt: now, value: try CapacityValue(count: 1), authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now))
    }

    func testCapacityObservationDecodeIsStructuralAndAdmissionUsesInjectedNow() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = now.addingTimeInterval(61)
        let decoded = try JSONDecoder().decode(CapacityObservation.self, from: data(observationJSON(
            provider: "claude",
            providerWindowID: "five-hour",
            kind: "fixedReset",
            unit: "percent",
            observedAt: future,
            valueJSON: #"{"usedPercent":{"_0":70}}"#,
            authority: "providerReported",
            stability: "supported",
            consent: "notRequired",
            maximumAge: 900,
            comparability: "comparable",
            parserRevision: "test"
        )))
        XCTAssertThrowsError(try decoded.validateAdmission(now: now))

        let stale = now.addingTimeInterval(-45 * 86_400 - 1)
        let structurallyDecodedStale = try JSONDecoder().decode(CapacityObservation.self, from: data(observationJSON(
            provider: "claude",
            providerWindowID: "five-hour",
            kind: "fixedReset",
            unit: "percent",
            observedAt: stale,
            valueJSON: #"{"usedPercent":{"_0":70}}"#,
            authority: "providerReported",
            stability: "supported",
            consent: "notRequired",
            maximumAge: 900,
            comparability: "comparable",
            parserRevision: "test"
        )))
        XCTAssertThrowsError(try structurallyDecodedStale.validateAdmission(now: now))

        XCTAssertThrowsError(try JSONDecoder().decode(CapacityObservation.self, from: data(observationJSON(
            provider: "deepseek",
            providerWindowID: "balance",
            kind: "balance",
            unit: "currency",
            observedAt: now,
            resetAt: now.addingTimeInterval(3_600),
            valueJSON: #"{"money":{"_0":1,"currency":"USD"}}"#,
            authority: "providerReported",
            stability: "supported",
            consent: "notRequired",
            maximumAge: 3_600,
            comparability: "comparable",
            parserRevision: "test"
        ))))
    }

    func testCapacityAssessmentTruthTableAndFreshnessBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let series = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        func observation(_ used: Int, authority: CapacityAuthority = .providerReported, stability: CapacityStability = .supported, consent: CapacityConsent = .notRequired, age: TimeInterval = 900) throws -> CapacityObservation {
            try CapacityObservation(seriesID: series, observedAt: now.addingTimeInterval(-age), resetAt: now.addingTimeInterval(3_600), value: try CapacityValue(usedPercent: used), authority: authority, stability: stability, consent: consent, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now)
        }
        let service = CapacityAssessmentService()
        XCTAssertEqual(service.assess(try observation(69), now: now).risk, .normal)
        XCTAssertEqual(service.assess(try observation(70), now: now).risk, .warning)
        XCTAssertEqual(service.assess(try observation(85), now: now).risk, .critical)
        XCTAssertEqual(service.assess(try observation(80, stability: .compatibilityBridge), now: now).alertEligibility, .ineligible)
        XCTAssertEqual(service.assess(try observation(80, stability: .experimentalTransport), now: now).forecast, .cohortOnly)
        XCTAssertEqual(service.assess(try observation(80, authority: .userEntered), now: now).risk, .informational)
        XCTAssertEqual(service.assess(try observation(80, consent: .unavailable), now: now).alertEligibility, .ineligible)
        XCTAssertEqual(service.assess(try observation(80, age: 901), now: now).freshness, .stale)
    }

    func testCapacityRuleEligibilityRequiresExactIdentityAndConditionCompatibility() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let percentSeries = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        let percentObservation = try CapacityObservation(seriesID: percentSeries, observedAt: now, resetAt: now.addingTimeInterval(1_000), value: try CapacityValue(usedPercent: 80), authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now)
        let percentAssessment = CapacityAssessmentService().assess(percentObservation, now: now)
        let percentRule = try CapacityAlertRule(provider: .claude, seriesID: percentSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: .percentThresholds(reset: true, fifty: false, eighty: true, hundred: true))
        XCTAssertEqual(CapacityAssessmentService().eligibility(for: percentRule, assessment: percentAssessment), .percent)

        let balanceSeries = try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency)
        let balanceRule = try CapacityAlertRule(provider: .deepseek, seriesID: balanceSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: try .balanceBelow(threshold: 5, currency: "USD", rearmAtOrAboveThreshold: true))
        XCTAssertEqual(CapacityAssessmentService().eligibility(for: balanceRule, assessment: percentAssessment), .ineligible)

        let balanceObservation = try CapacityObservation(seriesID: balanceSeries, observedAt: now, value: try CapacityValue(money: Decimal(string: "3.34")!, currency: "USD"), authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 3_600), comparability: .comparable, parserRevision: "test", now: now)
        let balanceAssessment = CapacityAssessmentService().assess(balanceObservation, now: now)
        XCTAssertEqual(CapacityAssessmentService().eligibility(for: balanceRule, assessment: balanceAssessment), .balance)

        let highThresholdMiss = try CapacityAlertRule(provider: .deepseek, seriesID: balanceSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: try .balanceBelow(threshold: 3, currency: "USD", rearmAtOrAboveThreshold: true))
        let currencyMismatch = try CapacityAlertRule(provider: .deepseek, seriesID: balanceSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: try .balanceBelow(threshold: 5, currency: "EUR", rearmAtOrAboveThreshold: true))
        XCTAssertEqual(CapacityAssessmentService().eligibility(for: highThresholdMiss, assessment: balanceAssessment), .ineligible)
        XCTAssertEqual(CapacityAssessmentService().eligibility(for: currencyMismatch, assessment: balanceAssessment), .ineligible)
    }

    func testCapacityAlertRuleConditionAndIdentityValidation() throws {
        let percentSeries = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        let balanceSeries = try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency)

        XCTAssertThrowsError(try CapacityAlertCondition.balanceBelow(threshold: -5, currency: "USD", rearmAtOrAboveThreshold: true))
        XCTAssertThrowsError(try CapacityAlertCondition.balanceBelow(threshold: 5, currency: "usd", rearmAtOrAboveThreshold: true))
        XCTAssertThrowsError(try JSONDecoder().decode(CapacityAlertCondition.self, from: data(#"{"balanceBelow":{"threshold":-5,"currency":"USD","rearmAtOrAboveThreshold":true}}"#)))
        XCTAssertThrowsError(try CapacityAlertRule(provider: .codex, seriesID: percentSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: .percentThresholds(reset: true, fifty: true, eighty: true, hundred: true)))
        XCTAssertThrowsError(try CapacityAlertRule(provider: .deepseek, seriesID: balanceSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: .percentThresholds(reset: true, fifty: true, eighty: true, hundred: true)))
        XCTAssertThrowsError(try CapacityAlertRule(provider: .claude, seriesID: percentSeries, authority: .userEntered, stability: .supported, enabled: true, routing: .init(), condition: .percentThresholds(reset: true, fifty: true, eighty: true, hundred: true)))
        XCTAssertThrowsError(try CapacityAlertRule(provider: .claude, seriesID: percentSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), conditionRevision: 0, condition: .percentThresholds(reset: true, fifty: true, eighty: true, hundred: true)))

        let balanceRule = try CapacityAlertRule(provider: .deepseek, seriesID: balanceSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: try .balanceBelow(threshold: 5, currency: "USD", rearmAtOrAboveThreshold: true))
        let pendingRule = try CapacityAlertRule(provider: .deepseek, seriesID: balanceSeries, authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: .pendingBalanceCurrencyBinding)
        XCTAssertNotEqual(balanceRule.id, pendingRule.id)
        XCTAssertTrue(balanceRule.id.contains("balanceBelow"))
        XCTAssertTrue(pendingRule.id.contains("pendingBalanceCurrencyBinding"))
        XCTAssertFalse(pendingRule.enabled)

        let encodedPending = try JSONEncoder().encode(pendingRule)
        let decodedPending = try JSONDecoder().decode(CapacityAlertRule.self, from: encodedPending)
        XCTAssertFalse(decodedPending.enabled)
    }

    func testCapacityDeliveryKeyAndStateAreTypedAndValidated() throws {
        let series = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        let rule = try CapacityAlertRule(provider: .claude, seriesID: series, authority: .providerReported, stability: .supported, enabled: true, routing: .init(macOS: true, telegram: true), conditionRevision: 2, condition: .percentThresholds(reset: true, fifty: false, eighty: true, hundred: true))
        let macKey = CapacityAlertDeliveryKey(rule: rule, channel: .macOS)
        let telegramKey = CapacityAlertDeliveryKey(rule: rule, channel: .telegram)

        XCTAssertNotEqual(macKey, telegramKey)
        XCTAssertEqual(macKey.ruleID, rule.id)
        XCTAssertEqual(macKey.conditionRevision, 2)
        XCTAssertEqual(macKey.channel, .macOS)

        let state = try CapacityAlertDeliveryState(key: macKey, status: .pending, conditionState: .percent(activeCycleID: "cycle-1", lastUsed: 80, deliveredThresholds: [.eighty]))
        let roundTrip = try JSONDecoder().decode(CapacityAlertDeliveryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(roundTrip, state)

        XCTAssertThrowsError(try CapacityAlertDeliveryKey(ruleID: "", conditionRevision: 1, channel: .macOS))
        XCTAssertThrowsError(try CapacityAlertDeliveryKey(ruleID: rule.id, conditionRevision: 0, channel: .macOS))
        XCTAssertThrowsError(try CapacityAlertDeliveryState(key: macKey, conditionState: .percent(activeCycleID: "", lastUsed: 80, deliveredThresholds: [])))
        XCTAssertThrowsError(try CapacityAlertDeliveryState(key: macKey, conditionState: .percent(activeCycleID: nil, lastUsed: 101, deliveredThresholds: [])))
        XCTAssertThrowsError(try CapacityAlertDeliveryState(key: macKey, conditionState: .balance(lastKnownBelow: nil, crossingGeneration: -1, deliveredCrossingGeneration: nil)))
        XCTAssertThrowsError(try JSONDecoder().decode(CapacityAlertDeliveryKey.self, from: data(#"{"ruleID":"","conditionRevision":1,"channel":"macOS"}"#)))
        XCTAssertThrowsError(try JSONDecoder().decode(CapacityAlertConditionState.self, from: data(#"{"percent":{"lastUsed":50,"deliveredThresholds":["bogus"]}}"#)))
    }

    func testCapacityTransitionRuleAndPresentationSemantics() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let series = try CapacitySeriesID(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent)
        let observation = try CapacityObservation(seriesID: series, observedAt: now, resetAt: now.addingTimeInterval(1_000), value: try CapacityValue(usedPercent: 80), authority: .providerReported, stability: .supported, freshnessPolicy: .init(maximumAge: 900), comparability: .comparable, parserRevision: "test", now: now)
        let assessment = CapacityAssessmentService().assess(observation, now: now)
        let presentation = CapacityPresentationMapper().map(assessment)
        XCTAssertEqual(presentation.titleKey, "capacity.remaining.percent")
        XCTAssertEqual(presentation.data["remainingPercent"], "20")
        XCTAssertFalse(assessment.transitionKey.contains("test"))

        let pending = try CapacityAlertRule(provider: .deepseek, seriesID: try CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency), authority: .providerReported, stability: .supported, enabled: true, routing: .init(), condition: .pendingBalanceCurrencyBinding)
        XCTAssertEqual(CapacityAssessmentService().eligibility(for: pending, assessment: assessment), .ineligible)
    }

    func testAlertFallbackCopyUsesNeutralWaitRefreshGuidance() {
        let eighty = String(format: TokenPilotLocalizer.localized("alert.eighty.body", language: .en), "Claude Code · 5h", 80, "1h")
        let hundred = String(format: TokenPilotLocalizer.localized("alert.hundred.body", language: .en), "Claude Code · 5h", "1h")
        for body in [eighty, hundred] {
            XCTAssertFalse(body.localizedCaseInsensitiveContains("switch"))
            XCTAssertFalse(body.contains("Codex"))
            XCTAssertFalse(body.contains("Gemini"))
            XCTAssertTrue(body.localizedCaseInsensitiveContains("wait"))
            XCTAssertTrue(body.localizedCaseInsensitiveContains("refresh"))
        }
    }

    func testCapacityAlertChannelSettingsRequireParentProviderAndDestinations() {
        var settings = AppSettings()
        let routing = CapacityAlertRouting(macOS: true, telegram: true, discord: true)

        settings.globalNotificationsEnabled = false
        var channels = CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: true)
        XCTAssertFalse(channels.isEnabled(.macOS, routing: routing))
        XCTAssertFalse(channels.isEnabled(.telegram, routing: routing))
        XCTAssertFalse(channels.isEnabled(.discord, routing: routing))

        settings.globalNotificationsEnabled = true
        settings.macOSNotificationsEnabled = false
        channels = CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: true)
        XCTAssertFalse(channels.isEnabled(.macOS, routing: routing))

        settings.macOSNotificationsEnabled = true
        XCTAssertTrue(CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: true).isEnabled(.macOS, routing: routing))

        settings.telegramNotificationsEnabled = true
        settings.telegram.isEnabled = true
        settings.telegram.chatID = ""
        channels = CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: true)
        XCTAssertFalse(channels.isEnabled(.telegram, routing: routing))

        settings.telegram.chatID = "12345"
        XCTAssertTrue(CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: true).isEnabled(.telegram, routing: routing))

        settings.telegram.isEnabled = false
        XCTAssertFalse(CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: true).isEnabled(.telegram, routing: routing))

        settings.discordNotificationsEnabled = true
        settings.discord.isEnabled = true
        XCTAssertFalse(CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: false).isEnabled(.discord, routing: routing))
        XCTAssertTrue(CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: true).isEnabled(.discord, routing: routing))

        settings.discord.isEnabled = false
        XCTAssertFalse(CapacityAlertChannelSettings(settings: settings, telegramCredentialPresent: true, discordCredentialPresent: true).isEnabled(.discord, routing: routing))
    }

    func testG004NotificationAccessibilityAndAlertCopyGuardsStayInPlace() throws {
        let source = try Self.tokenMonitorAppSource()

        let sendTestBody = try XCTUnwrap(source.swiftFunctionBody(named: "sendTestNotification"))
        XCTAssertTrue(sendTestBody.contains("guard settings.globalNotificationsEnabled"))
        XCTAssertTrue(sendTestBody.contains("settings.globalNotificationsEnabled && settings.macOSNotificationsEnabled"))

        let capacityMessageBody = try XCTUnwrap(source.swiftFunctionBody(named: "capacityAlertMessage"))
        XCTAssertTrue(capacityMessageBody.contains("capacity.notification.percent.body"))
        XCTAssertFalse(capacityMessageBody.contains("providerWindowID"))

        XCTAssertTrue(source.contains("capacity.alert.delivery.pending.count"))
        XCTAssertTrue(source.contains("capacity.alert.delivery.failed.count"))
        XCTAssertTrue(source.contains("capacity.alert.status.format"))
        XCTAssertTrue(source.contains("capacity.alert.channel.preference.format"))
        XCTAssertTrue(source.contains("capacity.alert.segment.format"))
        XCTAssertTrue(source.contains("t(\"Global\")"))
        XCTAssertTrue(source.contains("t(\"macOS\")"))
        XCTAssertTrue(source.contains("t(\"Telegram\")"))
        XCTAssertTrue(source.contains("t(\"Discord\")"))
        XCTAssertFalse(source.contains("\\(summary.pendingDeliveryCount) pending"))
        XCTAssertFalse(source.contains("return \"Global \\(global)"))
        XCTAssertFalse(source.contains("· write-blocked"))
        XCTAssertFalse(source.contains("deliveryStatus.rawValue"))
        XCTAssertTrue(source.contains("Button(model.t(\"Delete API Key\"), role: .destructive)"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion) private var systemReduceMotion"))
        XCTAssertTrue(source.contains("@Environment(\\.tokenPilotReduceMotionOverride) private var reduceMotionOverride"))
        XCTAssertTrue(source.contains("let stateValue = localized(isExpanded ? \"Expanded\" : \"Collapsed\", language: language)"))
        XCTAssertTrue(source.contains(".accessibilityValue(\"\\(accessibilityValue), \\(stateValue)\")"))
        XCTAssertTrue(source.contains(".accessibilityValue(stateValue)"))
        XCTAssertTrue(source.contains("accessibilityLabel: localized(\"Remaining capacity\", language: language)"))
        XCTAssertTrue(source.contains("accessibilityLabel: \"\\(localized(provider.displayName, language: language)) \\(localized(\"Remaining capacity\", language: language))\""))
    }

    func testG004LocalizationKeysHaveRuntimeAndCatalogParity() throws {
        let translatedKeys = [
            "Cancel",
            "Alerts",
            "Remaining capacity",
            "Runtime recovery required",
            "Capacity runtime recovery required",
            "Capacity runtime recovery required; safe defaults are active.",
            "DeepSeek API Key",
            "Source unavailable",
            "Unsupported source",
            "Pending",
            "Pending balance",
            "Delivered",
            "Failed",
            "Global",
            "Idle",
            "No trusted capacity",
            "No trusted capacity presentation",
            "Open Provider Diagnostics",
            "Reset",
            "Estimated",
            "Capacity remaining %d%%",
            "Provider reported",
            "Local derived",
            "User entered",
            "Supported",
            "Compatibility bridge",
            "Experimental connector",
            "Manual entry",
            "Fresh",
            "Stale",
            "Freshness unavailable",
            "Wait for reset",
            "Refresh provider",
            "Review source",
            "Review experimental connector",
            "Enter manual value",
            "Review balance",
            "Live only",
            "Local metadata only",
            "Mock preview",
            "Settings overview",
            "Privacy and provider truth",
            "Expanded",
            "Collapsed",
            "write-blocked",
            "LIVE",
            "LOCAL",
            "MANUAL",
            "EXPERIMENTAL",
            "BRIDGE",
            "MOCK",
            "STALE",
            "capacity.alert.channel.preference.format",
            "capacity.alert.channel.state.format",
            "capacity.alert.delivery.failed.count",
            "capacity.alert.delivery.pending.count",
            "capacity.alert.pill.status.format",
            "capacity.alert.rule.count.status",
            "capacity.alert.segment.format",
            "capacity.alert.segment.separator",
            "capacity.alert.status.format",
            "capacity.notification.percent.body",
            "capacity.notification.reset.body",
            "5-hour window"
        ]

        let properNameKeys = [
            "macOS",
            "Telegram",
            "Discord",
            "TG",
            "DC"
        ]

        let keys = translatedKeys + properNameKeys

        for key in translatedKeys {
            XCTAssertNotEqual(TokenPilotLocalizer.localized(key, language: .ko), key)
            XCTAssertNotEqual(TokenPilotLocalizer.localized(key, language: .ja), key)
            XCTAssertNotEqual(TokenPilotLocalizer.localized(key, language: .zhHans), key)
        }

        let catalogURL = try Self.projectRootURL()
            .appendingPathComponent("Sources/TokenApp/Resources/Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
            for locale in ["en", "ko", "ja", "zh-Hans"] {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "Missing \(locale) for \(key)")
                let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "Missing stringUnit for \(key) \(locale)")
                let value = try XCTUnwrap(stringUnit["value"] as? String, "Missing value for \(key) \(locale)")
                XCTAssertFalse(value.isEmpty, "Empty value for \(key) \(locale)")
            }
        }

        let retiredActiveKeys = [
            "Daily challenge",
            "Daily challenge target",
            "Change daily challenge target",
            "Daily challenge progress",
            "7-day usage",
            "Provider share",
            "Settings disclosure console"
        ]
        for key in retiredActiveKeys {
            XCTAssertNil(strings[key], "Retired UI key should not remain in the catalog: \(key)")
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: .ko), key)
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: .ja), key)
            XCTAssertEqual(TokenPilotLocalizer.localized(key, language: .zhHans), key)
        }
    }

    func testXAINoNetworkCriticalStringsHaveRuntimeAndCatalogParity() throws {
        let criticalKeys = [
            "Grok / xAI API",
            "xAI Management API Key",
            "Management authentication unconfirmed",
            "Official xAI Management authentication docs are ambiguous.",
            "TokenPilot will not send xAI HTTP requests until official Management-key transport is documented.",
            "No xAI HTTP requests are sent.",
            "xAI is disabled by default.",
            "xAI API billing is separate from Grok web subscription limits.",
            "Grok web subscription limits are not read or displayed.",
            "Future xAI calls require an endpoint allowlist.",
            "Management API key stored in Keychain only.",
            "Keys and team IDs are never exported, logged, or shown in errors.",
            "Enable xAI",
            "Management key saved",
            "No management key",
            "Team ID set",
            "No team ID",
            "Auth unconfirmed",
            "Setup needed",
            "Management key required",
            "Team ID required",
            "xAI is disabled by default. TokenPilot stores setup locally. No xAI HTTP requests are sent.",
            "xAI local setup presence",
            "Team ID is stored locally and masked in summaries. Diagnostics and accessibility labels use presence only.",
            "A saved key plus team ID still means authentication unconfirmed. No xAI HTTP requests are sent; verify credentials outside TokenPilot.",
            "Replace Management Key",
            "xAI disabled",
            "Management key and team ID required",
            "xAI is disabled by default. Enable it only when you want local setup visibility.",
            "Management key is saved in Keychain and team ID is stored locally. Authentication is unconfirmed. No xAI HTTP requests are sent.",
            "Save an xAI Management key in Keychain and a local team ID. Check Connection only checks local setup. No xAI HTTP requests are sent.",
            "Enable xAI only when you want local setup visibility.",
            "Authentication is unconfirmed; verify credentials outside TokenPilot.",
            "Enter a local team ID and save a Management key; Check Connection stays local.",
            "Enter an xAI Management key first.",
        ]
        let languages: [(TokenPilotLanguage, String)] = [
            (.en, "en"),
            (.ko, "ko"),
            (.ja, "ja"),
            (.zhHans, "zh-Hans")
        ]
        let catalogURL = try Self.projectRootURL()
            .appendingPathComponent("Sources/TokenApp/Resources/Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalogRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalogStrings = try XCTUnwrap(catalogRoot["strings"] as? [String: Any])

        for key in criticalKeys {
            let entry = try XCTUnwrap(catalogStrings[key] as? [String: Any], "Missing catalog key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")

            for (language, locale) in languages {
                let runtimeValue = TokenPilotLocalizer.localized(key, language: language)
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "Missing catalog locale \(locale): \(key)")
                let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "Missing stringUnit \(locale): \(key)")
                let catalogValue = try XCTUnwrap(stringUnit["value"] as? String, "Missing catalog value \(locale): \(key)")

                XCTAssertFalse(runtimeValue.isEmpty, "Empty runtime xAI string for \(locale): \(key)")
                XCTAssertFalse(catalogValue.isEmpty, "Empty catalog xAI string for \(locale): \(key)")
                XCTAssertEqual(catalogValue, runtimeValue, "Runtime/catalog mismatch for \(locale): \(key)")
            }
        }

        XCTAssertTrue(TokenPilotLocalizer.localized("No xAI HTTP requests are sent.", language: .en).contains("No xAI HTTP requests"))
        XCTAssertTrue(TokenPilotLocalizer.localized("TokenPilot will not send xAI HTTP requests until official Management-key transport is documented.", language: .en).contains("will not send xAI HTTP requests"))
        XCTAssertTrue(TokenPilotLocalizer.localized("xAI API billing is separate from Grok web subscription limits.", language: .en).contains("separate from Grok web subscription limits"))
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func observationJSON(
        provider: String,
        providerWindowID: String,
        kind: String,
        unit: String,
        observedAt: Date,
        resetAt: Date? = nil,
        valueJSON: String,
        authority: String,
        stability: String,
        consent: String,
        maximumAge: TimeInterval,
        comparability: String,
        parserRevision: String
    ) -> String {
        let reset = resetAt.map { #","resetAt":\#(jsonDate($0))"# } ?? ""
        return """
        {
          "seriesID":{"provider":"\(provider)","providerWindowID":"\(providerWindowID)","kind":"\(kind)","unit":"\(unit)"},
          "observedAt":\(jsonDate(observedAt))\(reset),
          "value":\(valueJSON),
          "authority":"\(authority)",
          "stability":"\(stability)",
          "consent":"\(consent)",
          "freshnessPolicy":{"maximumAge":\(maximumAge)},
          "comparability":"\(comparability)",
          "parserRevision":"\(parserRevision)"
        }
        """
    }

    private func jsonDate(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate)
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
