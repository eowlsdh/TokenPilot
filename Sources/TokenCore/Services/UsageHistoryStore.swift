import Foundation
import os

/// Where the usage history keeps its day partitions.
///
/// The history used to be one JSON array in UserDefaults, capped at 2 000 events and rewritten
/// whole on every change. For a heavy Claude Code user 2 000 events was about two and a half days,
/// so the 45-day retention was never real, and raising the cap would have meant rewriting a
/// preferences file of ~13 MB on every refresh. Partitioning by day means a refresh rewrites only
/// the days that actually changed — almost always just today.
public protocol UsageHistoryStorage: AnyObject, Sendable {
    /// The day keys (`yyyy-MM-dd`, UTC) that currently hold data.
    func dayKeys() -> [String]
    func read(day: String) -> Data?
    /// Writes a day's encoded events. Callers only write when the bytes changed.
    func write(day: String, data: Data)
    func remove(day: String)
}

/// Production storage: one file per UTC day under Application Support.
public final class FileUsageHistoryStorage: UsageHistoryStorage, @unchecked Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("TokenPilot/UsageHistory", isDirectory: true)
    }

    public func dayKeys() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let day = String(name.dropLast(5))
            return UsageHistoryStore.isDayKey(day) ? day : nil
        }
    }

    public func read(day: String) -> Data? {
        try? Data(contentsOf: fileURL(day))
    }

    public func write(day: String, data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(day), options: .atomic)
    }

    public func remove(day: String) {
        try? FileManager.default.removeItem(at: fileURL(day))
    }

    private func fileURL(_ day: String) -> URL {
        directory.appendingPathComponent("\(day).json")
    }
}

/// Test storage: one UserDefaults key per day plus an index of days, written through the
/// change guard.
public final class DefaultsUsageHistoryStorage: UsageHistoryStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String
    private let indexKey: String

    public init(defaults: UserDefaults, prefix: String) {
        self.defaults = defaults
        self.prefix = prefix + ".day."
        self.indexKey = prefix + ".days"
    }

    public func dayKeys() -> [String] {
        guard let data = defaults.data(forKey: indexKey),
              let days = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return days
    }

    public func read(day: String) -> Data? {
        defaults.data(forKey: prefix + day)
    }

    public func write(day: String, data: Data) {
        defaults.setIfChanged(data, forKey: prefix + day)
        saveIndex(Set(dayKeys()).union([day]))
    }

    public func remove(day: String) {
        defaults.removeObject(forKey: prefix + day)
        saveIndex(Set(dayKeys()).subtracting([day]))
    }

    private func saveIndex(_ days: Set<String>) {
        guard let data = try? JSONEncoder().encode(days.sorted()) else { return }
        defaults.setIfChanged(data, forKey: indexKey)
    }
}

public final class UsageHistoryStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let storage: any UsageHistoryStorage
    private let legacyDefaults: UserDefaults?
    private let legacyKey: String?
    private let maxAge: TimeInterval
    /// A safety bound per day, not a retention policy — far above any real day's events.
    private let maxEventsPerDay: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Decoded days, loaded once. This process is the only writer; the CLI builds its own store.
    private var days: [String: [UsageEvent]]?

    /// Production: day files under Application Support, importing the old UserDefaults blob once.
    public convenience init(maxAgeDays: Int = 45) {
        self.init(
            storage: FileUsageHistoryStorage(directory: FileUsageHistoryStorage.defaultDirectory),
            legacyDefaults: .standard,
            legacyKey: "tokenPilot.usageEvents.v3",
            maxAgeDays: maxAgeDays
        )
    }

    /// Day partitions kept in `defaults` under `key` — what tests use. A blob stored directly at
    /// `key` in the old single-array format is imported on first use.
    public convenience init(
        defaults: UserDefaults,
        key: String = "tokenPilot.usageEvents.v3",
        maxAgeDays: Int = 45,
        maxEvents: Int = 20_000
    ) {
        self.init(
            storage: DefaultsUsageHistoryStorage(defaults: defaults, prefix: key),
            legacyDefaults: defaults,
            legacyKey: key,
            maxAgeDays: maxAgeDays,
            maxEventsPerDay: maxEvents
        )
    }

    public init(
        storage: any UsageHistoryStorage,
        legacyDefaults: UserDefaults? = nil,
        legacyKey: String? = nil,
        maxAgeDays: Int = 45,
        maxEventsPerDay: Int = 20_000
    ) {
        self.storage = storage
        self.legacyDefaults = legacyDefaults
        self.legacyKey = legacyKey
        self.maxAge = TimeInterval(max(maxAgeDays, 1) * 24 * 60 * 60)
        self.maxEventsPerDay = max(maxEventsPerDay, 1)
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    public func record(snapshots: [ProviderSnapshot], enabledProviders: Set<Provider>, now: Date = Date()) -> [UsageEvent] {
        lock.withLock {
            let incoming = snapshots
                .filter { enabledProviders.contains($0.provider) }
                .flatMap { snapshot -> [UsageEvent] in
                    let explicitEvents = snapshot.events.filter { event in
                        enabledProviders.contains(event.provider) && (event.totalTokens > 0 || event.requestCount > 0 || event.estimatedCostUSD != nil)
                    }
                    if !explicitEvents.isEmpty { return explicitEvents }
                    guard snapshot.isWebQuotaComparable else { return [] }
                    guard snapshot.todayTokens > 0 || snapshot.todayCostUSD != nil else { return [] }
                    // Synthetic fallback: no per-field breakdown available; totals stay in their token/cost fields.
                    // Mark as estimated to distinguish from explicit adapter events.
                    return [UsageEvent(
                        provider: snapshot.provider,
                        model: snapshot.model,
                        timestamp: snapshot.updatedAt,
                        inputTokens: snapshot.todayTokens,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        cacheCreationTokens: 0,
                        reasoningTokens: 0,
                        toolTokens: 0,
                        requestCount: max(snapshot.dailyRequestsUsed ?? 0, 0),
                        estimatedCostUSD: snapshot.todayCostUSD,
                        source: "snapshot-daily-total",
                        dataSource: snapshot.dataSource,
                        isEstimated: true,
                        isExperimental: snapshot.isExperimental
                    )]
                }
                .filter { $0.timestamp >= now.addingTimeInterval(-maxAge) && $0.timestamp <= now.addingTimeInterval(60) }

            var loaded = loadDaysUnlocked()
            let incomingByDay = Dictionary(grouping: incoming, by: { Self.dayKey($0.timestamp) })
            for (day, dayIncoming) in incomingByDay {
                let merged = mergedDay(existing: loaded[day] ?? [], incoming: dayIncoming)
                if merged != loaded[day] {
                    saveDayUnlocked(day, merged)
                    loaded[day] = merged
                }
            }

            // Once-per-day readings are keyed by the *local* day, and a local day spans two UTC
            // partitions anywhere but UTC. The latest reading replaces the earlier one wherever it
            // was stored, or each partition would keep its own copy and the day would count twice.
            for (day, dayIncoming) in incomingByDay {
                let dailyKeys = Set(dayIncoming.filter(Self.isDailyKeyed).map(eventKey))
                guard !dailyKeys.isEmpty else { continue }
                for (otherDay, events) in loaded where otherDay != day {
                    let kept = events.filter { !(Self.isDailyKeyed($0) && dailyKeys.contains(eventKey($0))) }
                    if kept.count != events.count {
                        saveDayUnlocked(otherDay, kept)
                        loaded[otherDay] = kept
                    }
                }
            }

            let oldestKept = Self.dayKey(now.addingTimeInterval(-maxAge))
            for day in loaded.keys where day < oldestKept {
                storage.remove(day: day)
                loaded.removeValue(forKey: day)
            }
            days = loaded
            return Self.flattened(loaded)
        }
    }

    public func loadEvents() -> [UsageEvent] {
        lock.withLock {
            Self.flattened(loadDaysUnlocked())
        }
    }

    public func clear() {
        lock.withLock {
            for day in storage.dayKeys() {
                storage.remove(day: day)
            }
            if let legacyDefaults, let legacyKey {
                legacyDefaults.removeObject(forKey: legacyKey)
            }
            days = [:]
        }
    }

    public func snapshotsForHistory(
        currentSnapshots: [ProviderSnapshot],
        events: [UsageEvent],
        enabledProviders: Set<Provider>,
        referenceDate: Date = Date()
    ) -> [ProviderSnapshot] {
        let eventsByProvider = Dictionary(grouping: events.filter { enabledProviders.contains($0.provider) }, by: \.provider)
        return currentSnapshots
            .filter { enabledProviders.contains($0.provider) }
            .map { snapshot in
            var copy = snapshot
            let providerEvents = eventsByProvider[snapshot.provider] ?? []
            copy.events = providerEvents
            copy.todayTokens = todayTokens(in: providerEvents, referenceDate: referenceDate)
            copy.todayCacheReadTokens = todayCacheReadTokens(in: providerEvents, referenceDate: referenceDate)
            if let todayCostUSD = todayCostUSD(in: providerEvents, referenceDate: referenceDate) {
                copy.todayCostUSD = todayCostUSD
            }
            return copy
            }
    }

    // MARK: - Day partitions (callers must hold lock)

    private func loadDaysUnlocked() -> [String: [UsageEvent]] {
        if let days { return days }
        var loaded: [String: [UsageEvent]] = [:]
        for day in storage.dayKeys() {
            guard let data = storage.read(day: day),
                  let events = try? decoder.decode([UsageEvent].self, from: data) else { continue }
            loaded[day] = events
        }
        loaded = importLegacyBlobUnlocked(into: loaded)
        days = loaded
        return loaded
    }

    /// The old single-array blob, imported into day partitions once and then removed.
    private func importLegacyBlobUnlocked(into loaded: [String: [UsageEvent]]) -> [String: [UsageEvent]] {
        guard let legacyDefaults, let legacyKey,
              let data = legacyDefaults.data(forKey: legacyKey) else { return loaded }
        var result = loaded
        if let legacy = try? decoder.decode([UsageEvent].self, from: data) {
            for (day, events) in Dictionary(grouping: legacy, by: { Self.dayKey($0.timestamp) }) {
                let merged = mergedDay(existing: result[day] ?? [], incoming: events)
                saveDayUnlocked(day, merged)
                result[day] = merged
            }
        }
        legacyDefaults.removeObject(forKey: legacyKey)
        return result
    }

    private func saveDayUnlocked(_ day: String, _ events: [UsageEvent]) {
        guard let data = try? encoder.encode(events) else { return }
        storage.write(day: day, data: data)
    }

    /// Existing events first, then incoming, keeping the latest reading per key.
    ///
    /// An incoming event with a `sourceEventID` also retires stored copies of the same content that
    /// predate the ID — events recorded before the store knew message identity — so the switch to
    /// ID-keyed dedupe does not count a month of Claude history twice.
    private func mergedDay(existing: [UsageEvent], incoming: [UsageEvent]) -> [UsageEvent] {
        let identifiedContent = Set(incoming.filter { $0.sourceEventID != nil }.map(contentKey))
        var byKey: [String: UsageEvent] = [:]
        var order: [String] = []
        for event in existing + incoming {
            if event.sourceEventID == nil, identifiedContent.contains(contentKey(event)) { continue }
            let key = eventKey(event)
            if let stored = byKey[key] {
                // Adapters mint a fresh UUID each time they re-emit an event. A reading that repeats
                // the stored one keeps the stored one, or every re-emitted day would differ by IDs
                // alone and be rewritten on every refresh.
                var sameReading = event
                sameReading.id = stored.id
                if sameReading == stored { continue }
            } else {
                order.append(key)
            }
            byKey[key] = event
        }
        let events = order.compactMap { byKey[$0] }.sorted { $0.timestamp < $1.timestamp }
        return events.count > maxEventsPerDay ? Array(events.suffix(maxEventsPerDay)) : events
    }

    private func eventKey(_ event: UsageEvent) -> String {
        if let sourceEventID = event.sourceEventID {
            return [event.provider.rawValue, event.source, "id", sourceEventID].joined(separator: "|")
        }
        if Self.isDailyKeyed(event) {
            let day = Self.localDayFormatter.string(from: event.timestamp)
            return [event.provider.rawValue, event.source, event.model ?? "", day].joined(separator: "|")
        }
        return contentKey(event)
    }

    /// Sources that report a running total for the day rather than individual events.
    private static func isDailyKeyed(_ event: UsageEvent) -> Bool {
        event.sourceEventID == nil
            && ["snapshot-daily-total", "claude-statusline", "antigravity-statusline"].contains(event.source)
    }

    private func contentKey(_ event: UsageEvent) -> String {
        let bucket = Int(event.timestamp.timeIntervalSince1970.rounded())
        let cost = event.estimatedCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        return [
            event.provider.rawValue,
            event.source,
            event.model ?? "",
            String(bucket),
            String(event.inputTokens),
            String(event.outputTokens),
            String(event.cacheReadTokens),
            String(event.cacheCreationTokens),
            String(event.reasoningTokens),
            String(event.toolTokens),
            String(event.requestCount),
            String(event.totalTokens),
            cost
        ].joined(separator: "|")
    }

    private static func flattened(_ days: [String: [UsageEvent]]) -> [UsageEvent] {
        days.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Day keys

    /// UTC, so a time zone change can never place one event in two partitions.
    static func dayKey(_ date: Date) -> String {
        utcDayFormatter.withLock { $0.string(from: date) }
    }

    static func isDayKey(_ value: String) -> Bool {
        value.count == 10 && utcDayFormatter.withLock { $0.date(from: value) } != nil
    }

    private static let utcDayFormatter = OSAllocatedUnfairLock(initialState: {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }())

    private func todayTokens(in events: [UsageEvent], referenceDate: Date) -> Int {
        let calendar = Calendar.current
        return events
            .filter { calendar.isDate($0.timestamp, inSameDayAs: referenceDate) }
            .reduce(0) { $0 + $1.totalTokens }
    }

    private func todayCacheReadTokens(in events: [UsageEvent], referenceDate: Date) -> Int {
        let calendar = Calendar.current
        return events
            .filter { calendar.isDate($0.timestamp, inSameDayAs: referenceDate) }
            .reduce(0) { $0 + $1.cacheReadTokens }
    }

    private func todayCostUSD(in events: [UsageEvent], referenceDate: Date) -> Decimal? {
        let calendar = Calendar.current
        let costs = events
            .filter { calendar.isDate($0.timestamp, inSameDayAs: referenceDate) }
            .compactMap(\.estimatedCostUSD)
        guard !costs.isEmpty else { return nil }
        return costs.reduce(Decimal(0), +)
    }

    private static let localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
