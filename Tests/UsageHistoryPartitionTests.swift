import XCTest
@testable import TokenCore

/// The history was one UserDefaults array capped at 2 000 events and rewritten whole on every
/// change. On a real install that cap held two and a half days of a 45-day retention. These pin the
/// day-partitioned replacement.
final class UsageHistoryPartitionTests: XCTestCase {
    private final class CountingDefaults: UserDefaults, @unchecked Sendable {
        private var storage: [String: Any] = [:]
        private(set) var writes = 0

        override init?(suiteName: String?) { super.init(suiteName: nil) }
        override func object(forKey key: String) -> Any? { storage[key] }
        override func data(forKey key: String) -> Data? { storage[key] as? Data }
        override func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
        override func set(_ value: Any?, forKey key: String) {
            writes += 1
            storage[key] = value
        }
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(daysAgo: Double, tokens: Int = 100, source: String = "partition-test", id: String? = nil) -> UsageEvent {
        var event = UsageEvent(
            provider: .claude,
            model: "claude-sonnet-4",
            timestamp: now.addingTimeInterval(-daysAgo * 86_400),
            inputTokens: tokens,
            outputTokens: 0,
            source: source,
            dataSource: .localLog
        )
        event.sourceEventID = id
        return event
    }

    private func record(_ store: UsageHistoryStore, _ events: [UsageEvent]) -> [UsageEvent] {
        store.record(snapshots: [ProviderSnapshot(provider: .claude, events: events)], enabledProviders: [.claude], now: now)
    }

    func testFortyFiveDaysAreKeptWhateverTheVolume() {
        let store = UsageHistoryStore(defaults: makeTestDefaults("history-volume"))
        let events = (0..<40).flatMap { day in
            (0..<150).map { n in self.event(daysAgo: Double(day) + Double(n) / 1_000, tokens: n + 1) }
        }
        let retained = record(store, events)
        XCTAssertEqual(retained.count, 6_000, "the old 2 000-event cap would have kept about thirteen of these days")
        XCTAssertEqual(store.loadEvents().count, 6_000)
    }

    func testEventsPastTheRetentionAreDropped() {
        let store = UsageHistoryStore(defaults: makeTestDefaults("history-retention"), maxAgeDays: 45)
        let retained = record(store, [event(daysAgo: 1), event(daysAgo: 50)])
        XCTAssertEqual(retained.count, 1)
    }

    func testOnlyTheDayThatChangedIsRewritten() throws {
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: nil))
        let store = UsageHistoryStore(defaults: defaults, key: "partitioned")
        _ = record(store, [event(daysAgo: 0.01), event(daysAgo: 10), event(daysAgo: 20)])
        let afterFirst = defaults.writes

        // Adapters re-emit their whole window every refresh; only today has anything new.
        _ = record(store, [event(daysAgo: 0.01), event(daysAgo: 10), event(daysAgo: 20), event(daysAgo: 0.005, tokens: 7)])
        XCTAssertEqual(defaults.writes, afterFirst + 1, "one changed day, one write")
    }

    func testTheOldSingleArrayIsImportedOnceAndRemoved() throws {
        let defaults = makeTestDefaults("history-legacy")
        defaults.set(try JSONEncoder().encode([event(daysAgo: 3), event(daysAgo: 12)]), forKey: "legacy")
        let store = UsageHistoryStore(defaults: defaults, key: "legacy")

        XCTAssertEqual(store.loadEvents().count, 2)
        XCTAssertNil(defaults.data(forKey: "legacy"), "imported, then removed")
        XCTAssertEqual(UsageHistoryStore(defaults: defaults, key: "legacy").loadEvents().count, 2, "and still there for a fresh store")
    }

    /// A refresh that lands while a Claude message is still being written stores an early line; the
    /// next sees a richer one. Keyed by content, both were kept and the message counted twice.
    func testALaterReadingOfTheSameMessageReplacesTheEarlierOne() {
        let store = UsageHistoryStore(defaults: makeTestDefaults("history-message"))
        _ = record(store, [event(daysAgo: 0.1, tokens: 40, id: "message:msg_1")])
        let retained = record(store, [event(daysAgo: 0.1, tokens: 90, id: "message:msg_1")])
        XCTAssertEqual(retained.map(\.inputTokens), [90])
    }

    /// Events stored before messages carried an ID are retired as soon as the same content comes
    /// back with one, so the switch to ID-keyed dedupe does not count a month twice.
    func testAnEventStoredWithoutAnIDIsRetiredWhenItComesBackWithOne() {
        let store = UsageHistoryStore(defaults: makeTestDefaults("history-upgrade"))
        _ = record(store, [event(daysAgo: 2, tokens: 55)])
        let retained = record(store, [event(daysAgo: 2, tokens: 55, id: "message:msg_2")])
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.sourceEventID, "message:msg_2")
    }

    /// Daily readings are keyed by the local day, which spans two UTC partitions outside UTC.
    func testADailyReadingIsKeptOncePerLocalDayAcrossPartitions() {
        let store = UsageHistoryStore(defaults: makeTestDefaults("history-daily"))
        let utcMidnight = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
        var first = event(daysAgo: 0, tokens: 100, source: "snapshot-daily-total")
        first.timestamp = utcMidnight.addingTimeInterval(-30 * 60)
        var second = event(daysAgo: 0, tokens: 150, source: "snapshot-daily-total")
        second.timestamp = utcMidnight.addingTimeInterval(30 * 60)

        _ = record(store, [first])
        let retained = record(store, [second])
        let sameLocalDay = Calendar.current.isDate(first.timestamp, inSameDayAs: second.timestamp)
        XCTAssertEqual(retained.count, sameLocalDay ? 1 : 2)
        if sameLocalDay { XCTAssertEqual(retained.first?.inputTokens, 150) }
    }

    func testFileStorageKeepsOneFilePerDay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = UsageHistoryStore(storage: FileUsageHistoryStorage(directory: directory))
        _ = record(store, [event(daysAgo: 0.01), event(daysAgo: 5)])

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".json") })
        XCTAssertEqual(UsageHistoryStore(storage: FileUsageHistoryStorage(directory: directory)).loadEvents().count, 2)
    }
}
