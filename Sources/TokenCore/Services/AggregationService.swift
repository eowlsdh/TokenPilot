import Foundation
import os

public final class AggregationService: Sendable {
    public init() {}

    public func aggregate(
        snapshots: [ProviderSnapshot],
        period: HistoryPeriod,
        customRange: ClosedRange<Date>? = nil,
        now: Date = Date()
    ) -> AggregatedUsage {
        let usageEvents = snapshots.flatMap { $0.events }
        let filteredEvents = filterEvents(usageEvents, period: period, customRange: customRange, now: now)

        let totalTokens = filteredEvents.reduce(0) { $0 + $1.totalTokens }
        let inputTokens = filteredEvents.reduce(0) { $0 + $1.inputTokens }
        let outputTokens = filteredEvents.reduce(0) { $0 + $1.outputTokens }
        let cacheTokens = filteredEvents.reduce(0) { $0 + $1.cacheTokens }
        let requestCount = filteredEvents.reduce(0) { $0 + $1.requestCount }
        let cost = filteredEvents.compactMap { $0.estimatedCostUSD }.reduce(0, +)
        let providerTokens = Dictionary(grouping: filteredEvents, by: \.provider).mapValues { events in
            events.reduce(0) { $0 + $1.totalTokens }
        }
        let providerRequests = Dictionary(grouping: filteredEvents, by: \.provider).mapValues { events in
            events.reduce(0) { $0 + $1.requestCount }
        }
        let providerCosts = Dictionary(grouping: filteredEvents, by: \.provider).compactMapValues { events -> Decimal? in
            let costs = events.compactMap(\.estimatedCostUSD)
            guard !costs.isEmpty else { return nil }
            return costs.reduce(Decimal(0), +)
        }
        let share = Provider.allCases.map { provider in
            let tokens = providerTokens[provider] ?? 0
            let percent = totalTokens > 0 ? Int((Double(tokens) / Double(totalTokens) * 100).rounded()) : 0
            return ProviderShare(
                provider: provider,
                tokens: tokens,
                percent: percent,
                requestCount: providerRequests[provider] ?? 0,
                estimatedCostUSD: providerCosts[provider]
            )
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
            sevenDayBars: sevenDayBars(from: usageEvents, now: now),
            providerShare: share,
            events: filteredEvents,
            modelBreakdown: modelBreakdown(from: filteredEvents, totalTokens: totalTokens),
            projectBreakdown: projectBreakdown(from: filteredEvents, totalTokens: totalTokens)
        )
    }

    private func modelBreakdown(from events: [UsageEvent], totalTokens: Int) -> [ModelUsageShare] {
        let grouped = Dictionary(grouping: events) { event in
            ModelKey(provider: event.provider, model: event.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }

        return grouped.compactMap { key, groupedEvents -> ModelUsageShare? in
            let tokens = groupedEvents.reduce(0) { $0 + $1.totalTokens }
            let requests = groupedEvents.reduce(0) { $0 + $1.requestCount }
            guard tokens > 0 || requests > 0 else { return nil }
            let costs = groupedEvents.compactMap(\.estimatedCostUSD)
            return ModelUsageShare(
                provider: key.provider,
                model: key.model.isEmpty ? "unknown" : key.model,
                tokens: tokens,
                requestCount: requests,
                estimatedCostUSD: costs.isEmpty ? nil : costs.reduce(Decimal(0), +),
                tokenPercent: totalTokens > 0 ? Int((Double(tokens) / Double(totalTokens) * 100).rounded()) : 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            if lhs.requestCount != rhs.requestCount { return lhs.requestCount > rhs.requestCount }
            return lhs.id < rhs.id
        }
    }

    /// Rolls up local activity by workspace label (opencode only today). Events without a
    /// `projectLabel` are excluded so other providers never fall into an "unknown" bucket.
    private func projectBreakdown(from events: [UsageEvent], totalTokens: Int) -> [ProjectUsageShare] {
        let grouped = Dictionary(grouping: events) { event in
            ProjectKey(
                provider: event.provider,
                label: event.projectLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }

        return grouped.compactMap { key, groupedEvents -> ProjectUsageShare? in
            guard !key.label.isEmpty else { return nil }
            let tokens = groupedEvents.reduce(0) { $0 + $1.totalTokens }
            let requests = groupedEvents.reduce(0) { $0 + $1.requestCount }
            guard tokens > 0 || requests > 0 else { return nil }
            let costs = groupedEvents.compactMap(\.estimatedCostUSD)
            return ProjectUsageShare(
                provider: key.provider,
                label: key.label,
                tokens: tokens,
                requestCount: requests,
                estimatedCostUSD: costs.isEmpty ? nil : costs.reduce(Decimal(0), +),
                tokenPercent: totalTokens > 0 ? Int((Double(tokens) / Double(totalTokens) * 100).rounded()) : 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            if lhs.requestCount != rhs.requestCount { return lhs.requestCount > rhs.requestCount }
            return lhs.id < rhs.id
        }
    }

    private struct ModelKey: Hashable {
        var provider: Provider
        var model: String
    }

    private struct ProjectKey: Hashable {
        var provider: Provider
        var label: String
    }

    private func filterEvents(_ events: [UsageEvent], period: HistoryPeriod, customRange: ClosedRange<Date>?, now: Date) -> [UsageEvent] {
        if let customRange {
            return events.filter { customRange.contains($0.timestamp) }
        }
        let calendar = Calendar.current
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

    private func sevenDayBars(from events: [UsageEvent], now: Date) -> [DailyUsageBar] {
        let calendar = Calendar.current
        let formatter = Self.dayFormatter

        return (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) ?? now
            let tokens = events
                .filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
                .reduce(0) { $0 + $1.totalTokens }
            return DailyUsageBar(dayLabel: formatter.withLock { $0.string(from: date) }, tokens: tokens)
        }
    }

    private static let dayFormatter = OSAllocatedUnfairLock(initialState: {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "E"
        return formatter
    }())

    private func busiestHour(in events: [UsageEvent]) -> Int? {
        let counts = Dictionary(grouping: events) { event in
            Calendar.current.component(.hour, from: event.timestamp)
        }.mapValues { grouped in
            grouped.reduce(0) { $0 + $1.totalTokens }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    /// Builds a GitHub-style contribution grid for the trailing `days` (default 84 = 12 weeks).
    /// Cells are ordered newest-last; each day is bucketed into a 0...4 intensity level derived
    /// from its share of the busiest day so a single heavy day does not wash out quiet days.
    public func heatmapCells(from events: [UsageEvent], days: Int = 84, now: Date = Date()) -> [UsageHeatCell] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) ?? startOfToday

        let dailyTokens = (0..<days).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let tokens = events
                .filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
                .reduce(0) { $0 + $1.totalTokens }
            return (date, tokens)
        }

        let peak = max(dailyTokens.map(\.1).max() ?? 0, 1)
        let dateFormatter = Self.heatmapDateFormatter

        return dailyTokens.map { date, tokens in
            let level: Int
            if tokens <= 0 {
                level = 0
            } else {
                let ratio = Double(tokens) / Double(peak)
                if ratio > 0.75 { level = 4 }
                else if ratio > 0.5 { level = 3 }
                else if ratio > 0.25 { level = 2 }
                else { level = 1 }
            }
            return UsageHeatCell(
                dateKey: dateFormatter.withLock { $0.string(from: date) },
                tokens: tokens,
                level: level
            )
        }
    }

    private static let heatmapDateFormatter = OSAllocatedUnfairLock(initialState: {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }())
}
