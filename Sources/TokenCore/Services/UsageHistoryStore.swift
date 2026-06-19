import Foundation
import os

public final class UsageHistoryStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let defaults: UserDefaults
    private let key: String
    private let maxAge: TimeInterval
    private let maxEvents: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "tokenPilot.usageEvents.v3",
        maxAgeDays: Int = 45,
        maxEvents: Int = 2_000
    ) {
        self.defaults = defaults
        self.key = key
        self.maxAge = TimeInterval(max(maxAgeDays, 1) * 24 * 60 * 60)
        self.maxEvents = max(maxEvents, 1)
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    public func record(snapshots: [ProviderSnapshot], enabledProviders: Set<Provider>) -> [UsageEvent] {
        lock.withLock {
            let incoming = snapshots
                .filter { enabledProviders.contains($0.provider) }
                .flatMap { snapshot -> [UsageEvent] in
                    let explicitEvents = snapshot.events.filter { event in
                        enabledProviders.contains(event.provider) && (event.totalTokens > 0 || event.requestCount > 0)
                    }
                    if !explicitEvents.isEmpty { return explicitEvents }
                    guard snapshot.isWebQuotaComparable else { return [] }
                    guard snapshot.todayTokens > 0 else { return [] }
                    // Synthetic fallback: no per-field breakdown available, total placed in inputTokens.
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
                        estimatedCostUSD: nil,
                        source: "snapshot-daily-total",
                        dataSource: snapshot.dataSource,
                        isEstimated: true,
                        isExperimental: snapshot.isExperimental
                    )]
                }

            guard !incoming.isEmpty else {
                let retained = capped(pruned(loadEventsUnlocked()).sorted { $0.timestamp < $1.timestamp })
                saveUnlocked(retained)
                return retained
            }

            let merged = deduplicated(loadEventsUnlocked() + incoming)
            let retained = capped(pruned(merged).sorted { $0.timestamp < $1.timestamp })
            saveUnlocked(retained)
            return retained
        }
    }

    public func loadEvents() -> [UsageEvent] {
        lock.withLock {
            loadEventsUnlocked()
        }
    }

    public func clear() {
        lock.withLock {
            defaults.removeObject(forKey: key)
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
            return copy
            }
    }

    // MARK: - Internal (callers must hold lock)

    private func loadEventsUnlocked() -> [UsageEvent] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode([UsageEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveUnlocked(_ events: [UsageEvent]) {
        guard let data = try? encoder.encode(events) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: - Private helpers (pure computation, no I/O)

    private func pruned(_ events: [UsageEvent], now: Date = Date()) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-maxAge)
        return events.filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(60) }
    }

    private func deduplicated(_ events: [UsageEvent]) -> [UsageEvent] {
        var latestByKey: [String: UsageEvent] = [:]
        for event in events {
            latestByKey[eventKey(event)] = event
        }
        return Array(latestByKey.values)
    }

    private func capped(_ events: [UsageEvent]) -> [UsageEvent] {
        guard events.count > maxEvents else { return events }
        return Array(events.suffix(maxEvents))
    }

    private func eventKey(_ event: UsageEvent) -> String {
        if event.source == "snapshot-daily-total" || event.source == "claude-statusline" || event.source == "antigravity-statusline" {
            let day = Self.dayKeyFormatter.string(from: event.timestamp)
            return [event.provider.rawValue, event.source, event.model ?? "", day].joined(separator: "|")
        }

        let bucket = Int(event.timestamp.timeIntervalSince1970.rounded())
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
            String(event.totalTokens)
        ].joined(separator: "|")
    }

    private func todayTokens(in events: [UsageEvent], referenceDate: Date) -> Int {
        let calendar = Calendar.current
        return events
            .filter { calendar.isDate($0.timestamp, inSameDayAs: referenceDate) }
            .reduce(0) { $0 + $1.totalTokens }
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
