import Foundation

public final class AggregationService: Sendable {
    public init() {}

    public func aggregate(snapshots: [ProviderSnapshot], period: HistoryPeriod) -> AggregatedUsage {
        let webComparableEvents = snapshots.flatMap { $0.events }.filter(\.isWebQuotaComparable)
        let filteredEvents = filterEvents(webComparableEvents, period: period)

        let totalTokens = filteredEvents.reduce(0) { $0 + $1.totalTokens }
        let inputTokens = filteredEvents.reduce(0) { $0 + $1.inputTokens }
        let outputTokens = filteredEvents.reduce(0) { $0 + $1.outputTokens }
        let cacheTokens = filteredEvents.reduce(0) { $0 + $1.cacheTokens }
        let requestCount = filteredEvents.reduce(0) { $0 + $1.requestCount }
        let cost = filteredEvents.compactMap { $0.estimatedCostUSD }.reduce(0, +)
        let providerTokens = Dictionary(grouping: filteredEvents, by: \.provider).mapValues { events in
            events.reduce(0) { $0 + $1.totalTokens }
        }
        let share = Provider.allCases.map { provider in
            let tokens = providerTokens[provider] ?? 0
            let percent = totalTokens > 0 ? Int((Double(tokens) / Double(totalTokens) * 100).rounded()) : 0
            return ProviderShare(provider: provider, tokens: tokens, percent: percent)
        }
        let mostUsed = share.max(by: { $0.tokens < $1.tokens }).flatMap { $0.tokens > 0 ? $0.provider : nil }

        return AggregatedUsage(
            period: period,
            metrics: UsageMetrics(
                totalTokens: totalTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheTokens: cacheTokens,
                requestCount: requestCount,
                estimatedCostUSD: cost,
                mostUsedProvider: mostUsed,
                busiestHour: busiestHour(in: filteredEvents)
            ),
            sevenDayBars: sevenDayBars(from: webComparableEvents),
            providerShare: share,
            events: filteredEvents
        )
    }

    private func filterEvents(_ events: [UsageEvent], period: HistoryPeriod) -> [UsageEvent] {
        let calendar = Calendar.current
        let now = Date()
        let start: Date
        switch period {
        case .today:
            start = calendar.startOfDay(for: now)
        case .last7Days:
            start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .thisMonth:
            start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? calendar.startOfDay(for: now)
        }
        return events.filter { $0.timestamp >= start && $0.timestamp <= now.addingTimeInterval(1) }
    }

    private func sevenDayBars(from events: [UsageEvent]) -> [DailyUsageBar] {
        let calendar = Calendar.current
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "E"

        return (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) ?? now
            let tokens = events
                .filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
                .reduce(0) { $0 + $1.totalTokens }
            return DailyUsageBar(dayLabel: formatter.string(from: date), tokens: tokens)
        }
    }

    private func busiestHour(in events: [UsageEvent]) -> Int? {
        let counts = Dictionary(grouping: events) { event in
            Calendar.current.component(.hour, from: event.timestamp)
        }.mapValues { grouped in
            grouped.reduce(0) { $0 + $1.totalTokens }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
