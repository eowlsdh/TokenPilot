import XCTest
import os
@testable import TokenCore

/// Provider *depth* — twelve providers is worth nothing if one of them cannot tell the user its data
/// has gone cold. Found by driving every local adapter against this machine's real sources and
/// comparing what came back: Claude, Kiro, opencode and Grok all reported staleness; Codex reported
/// `stale=false` on a session log 130 minutes old, because the flag was hardcoded.
final class ProviderDepthTests: XCTestCase {
    /// A snapshot built from a local log has to be able to say its data went cold. The other
    /// hardcodes are legitimate — a freshly fetched balance, a value the user typed, a file that
    /// parsed but carried nothing — so the check is scoped to the source that ages.
    ///
    /// The first version of this read one file and looked complete. It was the file Codex lives in;
    /// JetBrains lives in another and had the same defect, worse, and went unflagged. It walks the
    /// whole services directory now.
    func testNoLocalLogSnapshotHardcodesFreshness() throws {
        var offenders: [String] = []
        var scanned = 0

        for file in try adapterSources() {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("dataSource: .localLog") {
                scanned += 1
                let window = lines[max(0, index - 10)...min(lines.count - 1, index + 10)]
                if window.contains(where: { $0.contains("isStale: false") }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertGreaterThan(scanned, 5, "the scan found almost no local-log snapshots; check the walk")
        XCTAssertTrue(
            offenders.isEmpty,
            "a local-log snapshot that cannot go stale cannot warn anyone: \(offenders)"
        )
    }

    /// A local file's reading was taken when the file was written, not when it was read. Stamping
    /// `now` does not just mislabel the age — it makes every freshness check downstream unreachable.
    func testNoLocalLogSnapshotStampsItselfWithTheReadTime() throws {
        var offenders: [String] = []

        for file in try adapterSources() {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("dataSource: .localLog") {
                let window = lines[max(0, index - 10)...min(lines.count - 1, index + 10)]
                // A snapshot with nothing in it — "quota file not found", "window unavailable" — has
                // no reading whose age could be misreported, so only ones carrying a value count.
                let carriesAReading = window.contains { $0.contains("LimitWindow(") || $0.contains("todayTokens:") }
                if carriesAReading, window.contains(where: { $0.contains("updatedAt: now") }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "a reading from a file was taken when the file was written, not when it was read: \(offenders)"
        )
    }

    private func adapterSources() throws -> [URL] {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenCore/Services")
        return try FileManager.default
            .contentsOfDirectory(at: services, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    /// Codex's threshold has to agree with the freshness the capacity pipeline already applies to its
    /// windows, or the provider row and the capacity card would disagree about the same reading.
    func testCodexStalenessMatchesTheCapacityFreshnessItAlreadyUses() throws {
        let services = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenCore/Services/TokenPilotServices.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(CodexLocalSessionAdapter.sessionStaleThreshold, 15 * 60)
        XCTAssertTrue(
            services.contains("maximumAge: 15 * 60"),
            "the capacity pipeline no longer uses a 15-minute window; the adapter has to follow"
        )
    }

    /// A session log older than the threshold has to say so, and a fresh one must not.
    func testACodexSessionOlderThanTheThresholdIsMarkedStale() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexDepth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        func snapshot(minutesAgo: Int) async throws -> ProviderSnapshot {
            let at = Date().addingTimeInterval(-Double(minutesAgo) * 60)
            let stamp = ISO8601DateFormatter().string(from: at)
            let line = "{\"timestamp\":\"\(stamp)\",\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":12,\"output_tokens\":3,\"cached_input_tokens\":2,\"reasoning_output_tokens\":1}}}\n"
            let file = directory.appendingPathComponent("session-\(minutesAgo).jsonl")
            try line.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: file.path)
            defer { try? FileManager.default.removeItem(at: file) }

            var settings = AppSettings()
            settings.codexEnabled = true
            let adapter = CodexLocalSessionAdapter(sessionRoots: [directory])
            return await adapter.snapshot(settings: settings)
        }

        let fresh = try await snapshot(minutesAgo: 2)
        let cold = try await snapshot(minutesAgo: 130)

        XCTAssertFalse(fresh.isStale, "a session written two minutes ago is not stale")
        XCTAssertTrue(cold.isStale, "a session written 130 minutes ago is")
        XCTAssertTrue(cold.statusMessage?.contains("STALE") == true, cold.statusMessage ?? "no status message")
    }

    // MARK: - JetBrains

    private func jetBrainsQuotaFile(writtenDaysAgo days: Double) throws -> (url: URL, written: Date) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JetBrainsDepth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let xml = """
        <component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="{&quot;maximum&quot;: 1000000.0, &quot;current&quot;: 250000.0, &quot;available&quot;: 750000.0}" />
        </component>
        """
        let url = directory.appendingPathComponent("AIAssistantQuotaManager2.xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let written = Date().addingTimeInterval(-days * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
        return (url, written)
    }

    private func jetBrainsSnapshot(daysOld: Double) async throws -> (snapshot: ProviderSnapshot, written: Date) {
        let file = try jetBrainsQuotaFile(writtenDaysAgo: daysOld)
        var settings = AppSettings()
        settings.setProviderEnabled(.jetbrains, isEnabled: true)
        let adapter = JetBrainsAIAssistantAdapter(quotaFileURLs: [file.url])
        let result = await adapter.refresh(settings: settings, now: Date())
        return (result.snapshot, file.written)
    }

    /// The quota file is a cache the IDE wrote when it last talked to the service, so that is when
    /// the reading was taken. Stamping the read time instead made the pipeline's own 24-hour
    /// freshness check unreachable — a three-week-old cache was assessed as an observation from this
    /// instant, at high confidence, with no stale marker anywhere.
    func testTheJetBrainsReadingIsDatedWhenTheCacheWasWritten() async throws {
        let (snapshot, written) = try await jetBrainsSnapshot(daysOld: 21)

        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, written.timeIntervalSince1970, accuracy: 2)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 25, "the reading itself still has to survive")
    }

    func testAnOldJetBrainsQuotaCacheIsMarkedStale() async throws {
        let (cold, _) = try await jetBrainsSnapshot(daysOld: 21)

        XCTAssertTrue(cold.isStale)
        XCTAssertEqual(cold.confidence, .medium, "a cache three weeks old is not high-confidence")
        XCTAssertTrue(cold.statusMessage?.contains("STALE") == true, cold.statusMessage ?? "no status message")
    }

    func testAFreshJetBrainsQuotaCacheIsNotMarkedStale() async throws {
        let (fresh, _) = try await jetBrainsSnapshot(daysOld: 0.01)

        XCTAssertFalse(fresh.isStale)
        XCTAssertEqual(fresh.confidence, .high)
        XCTAssertEqual(fresh.statusMessage, "Local IDE quota cache")
    }

    /// Same rule as Codex: the provider row and the capacity card have to agree about one reading.
    func testJetBrainsStalenessMatchesTheCapacityFreshnessItAlreadyUses() throws {
        let services = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TokenCore/Services/TokenPilotServices.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(JetBrainsAIAssistantAdapter.quotaCacheStaleThreshold, 24 * 60 * 60)
        XCTAssertTrue(services.contains("maximumAge: 24 * 60 * 60"))
    }

    // MARK: - The API-backed providers

    private struct StubKeychain: KeychainBackend, @unchecked Sendable {
        let secret: String?
        func saveSecret(_ secret: String, service: String, account: String) throws {}
        func readSecret(service: String, account: String) throws -> String? { secret }
        func deleteSecret(service: String, account: String, ignoreMissing: Bool) throws {}
    }

    private struct StubHTTP: MiniMaxUsageHTTPClient, ZAIUsageHTTPClient, OpenRouterHTTPClient, @unchecked Sendable {
        let body: Data
        let status: Int

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private func keychain(_ secret: String?) -> KeychainService {
        KeychainService(service: "com.tokenpilot.depth.\(UUID().uuidString)", backend: StubKeychain(secret: secret))
    }

    private func enabled(_ provider: Provider) -> AppSettings {
        var settings = AppSettings()
        settings.setProviderEnabled(provider, isEnabled: true)
        return settings
    }

    /// A reading fetched from the provider's own API this second is fresh, is official, and produces
    /// a capacity observation. The three API-backed providers had parser tests and no test that the
    /// adapter around them labels what it returns.
    func testTheAPIBackedProvidersReportOfficialFreshReadings() async throws {
        let now = Date()
        let cases: [(Provider, any ProviderRefreshAdapter, Int)] = [
            (.minimax, MiniMaxTokenPlanAdapter(
                httpClient: StubHTTP(body: try JSONSerialization.data(withJSONObject: [
                    "model_remains": [["model_name": "MiniMax-M2.7", "current_interval_remaining_percent": 40]]
                ]), status: 200),
                keychain: keychain("key")
            ), 60),
            (.zai, ZAIUsageAdapter(
                httpClient: StubHTTP(body: try JSONSerialization.data(withJSONObject: [
                    "limits": [["type": "TOKENS_LIMIT", "percentage": 42]]
                ]), status: 200),
                keychain: keychain("key")
            ), 42),
            (.openrouter, OpenRouterAdapter(
                httpClient: StubHTTP(body: try JSONSerialization.data(withJSONObject: [
                    "total_credits": 100.0, "total_usage": 25.0
                ]), status: 200),
                keychain: keychain("key")
            ), 25)
        ]

        for (provider, adapter, expectedUsed) in cases {
            let result = await adapter.refresh(settings: enabled(provider), now: now)
            let snapshot = result.snapshot

            XCTAssertEqual(snapshot.weekly?.usedPercent, expectedUsed, "\(provider)")
            XCTAssertEqual(snapshot.dataSource, .officialUsageAPI, "\(provider)")
            XCTAssertEqual(snapshot.confidence, .high, "\(provider)")
            XCTAssertFalse(snapshot.isStale, "\(provider) was fetched just now")
            XCTAssertEqual(snapshot.updatedAt, now, "\(provider)")
            XCTAssertFalse(result.capacityObservations.isEmpty, "\(provider) produced no capacity observation")
        }
    }

    /// When the fetch fails there is nothing current to show, and the honest answer is to show
    /// nothing rather than the last value without a date on it. These three keep no cache, which is
    /// why they are correct here — the test exists so a cache cannot be added without one.
    func testAFailedFetchCarriesNoQuotaWindow() async throws {
        let now = Date()
        let failing: [(Provider, any ProviderRefreshAdapter)] = [
            (.minimax, MiniMaxTokenPlanAdapter(httpClient: StubHTTP(body: Data(), status: 500), keychain: keychain("key"))),
            (.zai, ZAIUsageAdapter(httpClient: StubHTTP(body: Data(), status: 500), keychain: keychain("key"))),
            (.openrouter, OpenRouterAdapter(httpClient: StubHTTP(body: Data(), status: 500), keychain: keychain("key")))
        ]

        for (provider, adapter) in failing {
            let snapshot = await adapter.refresh(settings: enabled(provider), now: now).snapshot

            XCTAssertNil(snapshot.weekly, "\(provider) showed a quota window it could not fetch")
            XCTAssertEqual(snapshot.confidence, .low, "\(provider)")
            XCTAssertTrue(snapshot.statusMessage?.contains("unavailable") == true, snapshot.statusMessage ?? "\(provider): none")
        }
    }

    /// Without a key there is no reading at all, and the app says so instead of showing zero.
    func testWithoutAKeyTheProviderAsksForOneRatherThanReportingZero() async throws {
        let now = Date()
        let adapters: [(Provider, any ProviderRefreshAdapter)] = [
            (.minimax, MiniMaxTokenPlanAdapter(httpClient: StubHTTP(body: Data(), status: 200), keychain: keychain(nil))),
            (.zai, ZAIUsageAdapter(httpClient: StubHTTP(body: Data(), status: 200), keychain: keychain(nil))),
            (.openrouter, OpenRouterAdapter(httpClient: StubHTTP(body: Data(), status: 200), keychain: keychain(nil)))
        ]

        for (provider, adapter) in adapters {
            let snapshot = await adapter.refresh(settings: enabled(provider), now: now).snapshot

            XCTAssertNil(snapshot.weekly, "\(provider)")
            XCTAssertEqual(snapshot.statusMessage, "API key required", "\(provider)")
        }
    }

    // MARK: - DeepSeek

    /// DeepSeek is the one provider that keeps the last good reading when a fetch fails, so it is the
    /// one where a cache could be shown as current. It is not: the fallback drops to medium
    /// confidence and says so. This pins that, because it is the pattern Codex and JetBrains were
    /// missing and the only place in the app that already had it right.
    func testTheDeepSeekCachedBalanceIsMarkedStaleRatherThanShownAsCurrent() async throws {
        final class FlakyHTTP: DeepSeekBalanceHTTPClient, @unchecked Sendable {
            private let body: Data
            private let calls = OSAllocatedUnfairLock(initialState: 0)

            init(body: Data) { self.body = body }

            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let first = calls.withLock { count -> Bool in
                    count += 1
                    return count == 1
                }
                let status = first ? 200 : 500
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (first ? body : Data(), response)
            }
        }

        let body = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.34","granted_balance":"0","topped_up_balance":"12.34"}]}"#.utf8)
        let adapter = DeepSeekBalanceAdapter(httpClient: FlakyHTTP(body: body), keychain: keychain("key"))
        var settings = AppSettings()
        settings.setProviderEnabled(.deepseek, isEnabled: true)

        let fresh = await adapter.snapshot(settings: settings)
        XCTAssertEqual(fresh.confidence, .high)
        XCTAssertFalse(fresh.isStale)

        let cached = await adapter.snapshot(settings: settings)
        XCTAssertTrue(cached.isStale, "a cached balance is not a current one")
        XCTAssertEqual(cached.confidence, .medium)
        XCTAssertTrue(cached.statusMessage?.contains("stale") == true, cached.statusMessage ?? "no status message")
        XCTAssertEqual(cached.balance?.totalBalance, fresh.balance?.totalBalance, "the value itself still comes through")
    }
}
