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

    init(data: Data, statusCode: Int = 200) {
        self.responses = [(data, statusCode)]
    }

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let responsePayload = queue.sync { responses.count > 1 ? responses.removeFirst() : responses[0] }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.deepseek.com/user/balance")!,
            statusCode: responsePayload.1,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responsePayload.0, response)
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
            weekly: LimitWindow(kind: .weekly, usedPercent: 34)
        )

        let summary = MenuBarStatusService().lowestRemainingSummary(snapshots: [snapshot], settings: AppSettings())

        XCTAssertEqual(summary?.provider, .codex)
        XCTAssertEqual(summary?.remainingPercent, 66)
        XCTAssertEqual(summary?.displayText, "Co 66%")

        let codex = ProviderSnapshot(
            provider: .codex,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 21),
            weekly: LimitWindow(kind: .weekly, usedPercent: 34)
        )
        let claude = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 73)
        )

        let globalSummary = MenuBarStatusService().lowestRemainingSummary(snapshots: [codex, claude], settings: AppSettings())

        XCTAssertEqual(globalSummary?.provider, .claude)
        XCTAssertEqual(globalSummary?.remainingPercent, 27)
        XCTAssertEqual(globalSummary?.displayText, "Cl 27%")

        var settings = AppSettings()
        settings.claudeEnabled = false
        let disabledClaude = ProviderSnapshot(
            provider: .claude,
            fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 95)
        )
        let enabledCodex = ProviderSnapshot(
            provider: .codex,
            weekly: LimitWindow(kind: .weekly, usedPercent: 34)
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


    func testUsageStoreUsesDetectedGeminiSessionFolderWhenDefaultTelemetryLogMissing() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let geminiTmp = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionURL = geminiTmp.appendingPathComponent("session-tokenpilot.json")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","name":"gemini_cli.api_response","metadata":{"input_token_count":60,"output_token_count":30,"total_token_count":90,"model":"gemini-2.5-pro"}}
        """
        try line.write(to: sessionURL, atomically: true, encoding: .utf8)

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
        XCTAssertEqual(snapshot.model, "gemini-2.5-pro")
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

    func testUsageStoreDeduplicatesGeminiEventAcrossDetectedTelemetryAndSessionFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true)
        let geminiTmp = geminiRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","name":"gemini_cli.api_response","metadata":{"input_token_count":60,"output_token_count":30,"total_token_count":90,"model":"gemini-2.5-pro","auth_type":"oauth","duration_ms":123}}
        """
        try line.write(to: geminiRoot.appendingPathComponent("telemetry.log"), atomically: true, encoding: .utf8)
        try line.write(to: geminiTmp.appendingPathComponent("session-tokenpilot.json"), atomically: true, encoding: .utf8)

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

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = logURL.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)
        let monthly = AggregationService().aggregate(snapshots: [snapshot], period: .thisMonth)

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
        XCTAssertEqual(lines.count, 2)

        let initObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(initObject["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(initObject["method"] as? String, "initialize")
        let params = try XCTUnwrap(initObject["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "tokenpilot-test")

        let readObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(readObject["jsonrpc"] as? String, "2.0")
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
        {"error":{"code":-32000,"message":"upstream failed with Bearer fixture-token"},"id":2}
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
        XCTAssertEqual(snapshot.weekly?.usedPercent, 41)
        XCTAssertNotNil(snapshot.fiveHour?.resetAt)
        XCTAssertNotNil(snapshot.weekly?.resetAt)
        XCTAssertEqual(snapshot.model, "gpt-5.5")
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

    func testGeminiAdapterParsesSessionJsonlTokenObjectsFromDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonlURL = directory.appendingPathComponent("session-1.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","type":"message","model":"gemini-2.5-pro","tokens":{"input":100,"output":20,"cached":5,"thoughts":7,"tool":3,"total":135}}
        """
        try line.write(to: jsonlURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = directory.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.dataSource, .localLog)
        XCTAssertEqual(snapshot.todayTokens, 135)
        XCTAssertEqual(snapshot.events[0].model, "gemini-2.5-pro")
        XCTAssertEqual(snapshot.events[0].toolTokens, 3)
        XCTAssertEqual(snapshot.events[0].reasoningTokens, 7)
    }

    func testGeminiAdapterParsesPrettySessionJsonMessagesFromChatsFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chats = directory.appendingPathComponent("project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let jsonURL = chats.appendingPathComponent("conversation.json")
        let content = """
        {
          "sessionId": "gemini-session-a",
          "startTime": "\(timestamp)",
          "messages": [
            {
              "id": "message-a",
              "timestamp": "\(timestamp)",
              "type": "gemini",
              "model": "gemini-2.5-flash",
              "tokens": {
                "input": 120,
                "output": 30,
                "cached": 20,
                "thoughts": 5,
                "tool": 2,
                "total": 177
              }
            }
          ]
        }
        """
        try content.write(to: jsonURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = directory.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.dataSource, .localLog)
        XCTAssertEqual(snapshot.todayTokens, 177)
        XCTAssertEqual(snapshot.events[0].model, "gemini-2.5-flash")
        XCTAssertEqual(snapshot.events[0].toolTokens, 2)
        XCTAssertEqual(snapshot.events[0].reasoningTokens, 5)
    }

    func testGeminiAdapterDoesNotDoubleCountMessagesAndAggregateStats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chats = directory.appendingPathComponent("project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let jsonURL = chats.appendingPathComponent("conversation-with-stats.json")
        let content = """
        {
          "sessionId": "gemini-session-with-stats",
          "startTime": "\(timestamp)",
          "messages": [
            {
              "id": "message-a",
              "timestamp": "\(timestamp)",
              "type": "gemini",
              "model": "gemini-2.5-flash",
              "tokens": {"input": 80, "output": 20, "total": 100}
            }
          ],
          "stats": {
            "tokens": {"prompt": 80, "candidates": 20, "total_tokens": 100}
          }
        }
        """
        try content.write(to: jsonURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = directory.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 100)
        XCTAssertEqual(snapshot.events[0].totalTokens, 100)
    }

    func testGeminiAdapterParsesStatsModelsTokenObjects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let jsonURL = directory.appendingPathComponent("session-stats.json")
        let content = """
        {
          "session_id": "gemini-session-stats",
          "timestamp": "\(timestamp)",
          "stats": {
            "models": {
              "gemini-2.5-pro": {
                "tokens": {
                  "prompt": 80,
                  "candidates": 20,
                  "cached_tokens": 10,
                  "reasoning_tokens": 7,
                  "tool_tokens": 3,
                  "total_tokens": 120
                }
              }
            }
          }
        }
        """
        try content.write(to: jsonURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = directory.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].model, "gemini-2.5-pro")
        XCTAssertEqual(snapshot.events[0].totalTokens, 120)
        XCTAssertEqual(snapshot.events[0].cacheReadTokens, 10)
        XCTAssertEqual(snapshot.events[0].reasoningTokens, 7)
    }

    func testGeminiAdapterPrefersPerModelStatsOverAggregateStatsToAvoidDoubleCounting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let jsonURL = directory.appendingPathComponent("session-stats.json")
        let content = """
        {
          "timestamp": "\(timestamp)",
          "stats": {
            "tokens": {"prompt": 80, "candidates": 20, "total_tokens": 100},
            "models": {
              "gemini-2.5-pro": {"tokens": {"prompt": 80, "candidates": 20, "total_tokens": 100}}
            }
          }
        }
        """
        try content.write(to: jsonURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = directory.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.todayTokens, 100)
        XCTAssertEqual(snapshot.events[0].model, "gemini-2.5-pro")
    }

    func testGeminiAdapterIgnoresLowerLocalTotalWhenComponentsAreRicher() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let jsonlURL = directory.appendingPathComponent("session-1.jsonl")
        let line = "{\"timestamp\":\"\(timestamp)\",\"model\":\"gemini-2.5-pro\",\"tokens\":{\"input\":100,\"output\":50,\"total\":120}}"
        try line.write(to: jsonlURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = directory.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].totalTokens, 150)
        XCTAssertEqual(snapshot.todayTokens, 150)
    }

    func testGeminiAdapterUsesRootStartTimeForMessagesWithoutOwnTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chats = directory.appendingPathComponent("project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date().addingTimeInterval(-86_400)
        let timestamp = ISO8601DateFormatter().string(from: yesterday)
        let jsonURL = chats.appendingPathComponent("conversation.json")
        let content = """
        {
          "startTime": "\(timestamp)",
          "messages": [
            {"model": "gemini-2.5-flash", "tokens": {"input": 40, "output": 10, "total": 50}}
          ]
        }
        """
        try content.write(to: jsonURL, atomically: true, encoding: .utf8)

        var settings = AppSettings(showMockDataWhenDisconnected: false)
        settings.geminiTelemetryLogPath = directory.path
        let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].timestamp.timeIntervalSince1970, yesterday.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(snapshot.todayTokens, 0)
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
        let snapshot = ProviderSnapshot(
            provider: .codex,
            todayTokens: 9_999,
            dataSource: .localLog,
            isExperimental: true,
            statusMessage: "EXPERIMENTAL · local Codex log · not web quota"
        )
        let usage = AggregationService().aggregate(snapshots: [snapshot], period: .today)
        let data = try UsageExportService().makeJSONData(usage: usage, snapshots: [snapshot], dataMode: "LIVE")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(UsageExportPayload.self, from: data)

        XCTAssertEqual(payload.snapshots.first?.todayTokens, 0)
        XCTAssertEqual(payload.metrics.totalTokens, 0)
    }

    func testAggregationPeriodsChangeWhenHistoryContainsOlderEvents() {
        let now = Date()
        let current = UsageEvent(provider: .claude, timestamp: now, inputTokens: 100, outputTokens: 0, source: "test")
        let yesterday = UsageEvent(provider: .claude, timestamp: now.addingTimeInterval(-24 * 60 * 60), inputTokens: 200, outputTokens: 0, source: "test")
        let snapshots = [ProviderSnapshot(provider: .claude, updatedAt: now, todayTokens: 100, events: [current, yesterday])]
        let service = AggregationService()

        let today = service.aggregate(snapshots: snapshots, period: .today)
        let sevenDays = service.aggregate(snapshots: snapshots, period: .last7Days)
        let month = service.aggregate(snapshots: snapshots, period: .thisMonth)

        XCTAssertEqual(today.metrics.totalTokens, 100)
        XCTAssertEqual(sevenDays.metrics.totalTokens, 300)
        XCTAssertGreaterThanOrEqual(month.metrics.totalTokens, sevenDays.metrics.totalTokens)
        XCTAssertNotEqual(today.metrics.totalTokens, sevenDays.metrics.totalTokens)
    }

    // MARK: - Provider visibility and menu bar selection

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
        XCTAssertEqual(settings.enabledProviders, [.deepseek])
        XCTAssertTrue(settings.isProviderEnabled(.deepseek))
    }

    func testDeepSeekDefaultsOnForLegacyMonitoredProviderSets() {
        let legacyMonitored = MonitoredProviderSettings(enabledProviders: [.claude, .codex, .gemini])
        let settings = AppSettings(monitoredProviders: legacyMonitored)

        XCTAssertTrue(settings.deepseekEnabled)
        XCTAssertTrue(settings.isProviderEnabled(.deepseek))
        XCTAssertEqual(settings.enabledProviders, [.claude, .codex, .gemini, .deepseek])
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

    func testDeepSeekManualFallbackAndLowBalanceAlert() async {
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
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.provider, .deepseek)
        XCTAssertTrue(events.first?.body.contains("$4.99") == true)
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
            balance: ProviderBalance(currency: "USD", toppedUpBalance: Decimal(1), capturedAt: today)
        )
        let tomorrowSnapshot = ProviderSnapshot(
            provider: .deepseek,
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

        _ = store.record(snapshots: [], enabledProviders: [.claude], referenceDate: now)

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
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 92), weekly: LimitWindow(kind: .weekly, usedPercent: 71), todayTokens: 12_000),
            ProviderSnapshot(provider: .codex, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 36), weekly: LimitWindow(kind: .weekly, usedPercent: 44), todayTokens: 4_800, confidence: .manual),
            ProviderSnapshot(provider: .gemini, dailyRequestsUsed: 40, dailyRequestsLimit: 100, todayTokens: 9_500)
        ]

        let service = MenuBarStatusService()

        XCTAssertEqual(service.selectedSnapshot(from: snapshots, settings: settings)?.provider, .codex)
        XCTAssertEqual(service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE"), "5h 64% · W 56% 추정")
    }

    func testMenuBarStatusServiceShowsSelectedDeepSeekBalance() {
        var settings = AppSettings()
        settings.menuBarDisplayTarget = .deepseek
        let snapshot = ProviderSnapshot(
            provider: .deepseek,
            confidence: .high,
            balance: ProviderBalance(currency: "USD", toppedUpBalance: Decimal(string: "12.34")!)
        )

        let title = MenuBarStatusService().title(snapshots: [snapshot], settings: settings, modeLabel: "LIVE")

        XCTAssertEqual(title, "DS $12.34")
    }

    func testMenuBarStatusServiceShowsRemainingPercentagesForFiveHourAndWeekly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var settings = AppSettings()
        settings.localization.language = .ko
        let service = MenuBarStatusService()
        let snapshots = [
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 88), weekly: LimitWindow(kind: .weekly, usedPercent: 62, resetAt: now.addingTimeInterval(18_720)), todayTokens: 12_000)
        ]

        let title = service.title(snapshots: snapshots, settings: settings, modeLabel: "LIVE", now: now)
        XCTAssertEqual(title, "5h 12% · W 38%")
        XCTAssertFalse(title.contains("12K"))
    }

    func testMenuBarStatusServiceFallsBackToHighestRiskWhenSelectedProviderDisabled() {
        var settings = AppSettings()
        settings.menuBarDisplayTarget = .gemini
        XCTAssertTrue(settings.setProviderEnabled(.gemini, isEnabled: false))
        let snapshots = [
            ProviderSnapshot(provider: .claude, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 82), todayTokens: 12_000),
            ProviderSnapshot(provider: .codex, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 36), todayTokens: 4_800),
            ProviderSnapshot(provider: .gemini, dailyRequestsUsed: 98, dailyRequestsLimit: 100, todayTokens: 9_500)
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
        let todayResult = AggregationService().aggregate(snapshots: snapshots, period: .today)
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
        let last7Result = AggregationService().aggregate(snapshots: snapshots, period: .last7Days)
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
        let monthResult = AggregationService().aggregate(snapshots: snapshots, period: .thisMonth)
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
