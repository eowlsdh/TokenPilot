import XCTest
@testable import TokenCore

/// Writing bytes identical to the ones already stored still rewrites the preferences file whole.
/// Measured on a real install: 786 KB every ninety seconds, storing exactly what was already there.
final class PreferencesWriteGuardTests: XCTestCase {
    /// Counts writes rather than trusting that the guard is reached.
    private final class CountingDefaults: UserDefaults, @unchecked Sendable {
        private var storage: [String: Any] = [:]
        private(set) var writes = 0

        override init?(suiteName: String?) { super.init(suiteName: nil) }
        override func object(forKey key: String) -> Any? { storage[key] }
        override func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
        override func set(_ value: Any?, forKey key: String) {
            writes += 1
            storage[key] = value
        }
    }

    func testIdenticalBytesAreNotWrittenTwice() throws {
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: nil))
        let payload = Data("same".utf8)

        defaults.setIfChanged(payload, forKey: "key")
        defaults.setIfChanged(payload, forKey: "key")
        defaults.setIfChanged(payload, forKey: "key")

        XCTAssertEqual(defaults.writes, 1)
        XCTAssertEqual(defaults.data(forKey: "key"), payload)
    }

    func testChangedBytesAreWritten() throws {
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: nil))

        defaults.setIfChanged(Data("first".utf8), forKey: "key")
        defaults.setIfChanged(Data("second".utf8), forKey: "key")

        XCTAssertEqual(defaults.writes, 2)
        XCTAssertEqual(defaults.data(forKey: "key"), Data("second".utf8))
    }

    /// The case this was found in: a refresh that brings nothing new still saves, and did so on every
    /// pass for anyone whose enabled providers report no token events.
    func testARefreshWithNothingNewDoesNotRewriteTheHistory() throws {
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: nil))
        let store = UsageHistoryStore(defaults: defaults, key: "events")
        let event = UsageEvent(
            provider: .claude,
            model: "sonnet",
            timestamp: Date(),
            inputTokens: 10,
            outputTokens: 5,
            requestCount: 1,
            source: "test"
        )
        let snapshot = ProviderSnapshot(provider: .claude, events: [event])

        store.record(snapshots: [snapshot], enabledProviders: [.claude])
        let afterFirst = defaults.writes
        XCTAssertGreaterThan(afterFirst, 0)

        for _ in 0..<5 {
            store.record(snapshots: [], enabledProviders: [.claude])
        }

        XCTAssertEqual(defaults.writes, afterFirst, "five empty refreshes must not rewrite the history five times")
        XCTAssertEqual(store.loadEvents().count, 1)
    }

    /// Every encoded blob in the app goes through the guard, so a new store cannot reintroduce the
    /// pattern by writing straight to `set`.
    func testNoStoreWritesAnEncodedBlobDirectly() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenCore")
        let files = FileManager.default.enumerator(at: services, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "UserDefaultsWriteGuard.swift" } ?? []
        XCTAssertGreaterThan(files.count, 10)

        for file in files {
            let body = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                body.contains(".set(data, forKey:"),
                "\(file.lastPathComponent) writes an encoded blob directly — use setIfChanged"
            )
        }
    }

    /// The limit-sample store had the same shape as the evidence store: a five-minute bucket that
    /// took the newest sample, so re-reading an unchanged quota replaced the bucket's sample with one
    /// carrying a later timestamp and rewrote 108 KB of preferences every ninety seconds.
    func testRereadingTheSameQuotaDoesNotRewriteTheLimitHistory() throws {
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: nil))
        let store = LimitHistoryStore(defaults: defaults, key: "samples")
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        func snapshot(at date: Date, usedPercent: Int) -> ProviderSnapshot {
            ProviderSnapshot(
                provider: .opencode,
                updatedAt: date,
                weekly: LimitWindow(kind: .weekly, usedPercent: usedPercent, confidence: .high),
                confidence: .high
            )
        }

        store.record(snapshots: [snapshot(at: start, usedPercent: 15)], enabledProviders: [.opencode], referenceDate: start)
        let afterFirst = defaults.writes
        XCTAssertGreaterThan(afterFirst, 0)

        // Three more polls inside the same five-minute bucket, same quota.
        for seconds in [90.0, 180.0, 270.0] {
            let at = start.addingTimeInterval(seconds)
            store.record(snapshots: [snapshot(at: at, usedPercent: 15)], enabledProviders: [.opencode], referenceDate: at)
        }

        XCTAssertEqual(defaults.writes, afterFirst, "an unchanged quota re-read three times must not rewrite three times")
    }

    /// A quota that actually moved is still recorded.
    func testAChangedQuotaIsStillRecorded() throws {
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: nil))
        let store = LimitHistoryStore(defaults: defaults, key: "samples")
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        func snapshot(at date: Date, usedPercent: Int) -> ProviderSnapshot {
            ProviderSnapshot(
                provider: .opencode,
                updatedAt: date,
                weekly: LimitWindow(kind: .weekly, usedPercent: usedPercent, confidence: .high),
                confidence: .high
            )
        }

        store.record(snapshots: [snapshot(at: start, usedPercent: 15)], enabledProviders: [.opencode], referenceDate: start)
        let afterFirst = defaults.writes

        let later = start.addingTimeInterval(90)
        store.record(snapshots: [snapshot(at: later, usedPercent: 16)], enabledProviders: [.opencode], referenceDate: later)

        XCTAssertGreaterThan(defaults.writes, afterFirst)
        XCTAssertEqual(store.loadSamples().map(\.usedPercent), [16])
    }
}
