import Foundation
import os

public enum UsageExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json
    case csv

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    private static let filenameFormatter = OSAllocatedUnfairLock(initialState: {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }())

    public var defaultFilename: String {
        let stamp = Self.filenameFormatter.withLock { $0.string(from: Date()) }
        return "TokenPilot-usage-\(stamp).\(fileExtension)"
    }
}

public final class UsageExportService {
    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public init() {}

    public func export(
        usage: AggregatedUsage,
        snapshots: [ProviderSnapshot],
        dataMode: String,
        format: UsageExportFormat,
        generatedAt: Date = Date()
    ) throws -> Data {
        switch format {
        case .json:
            return try makeJSONData(usage: usage, snapshots: snapshots, dataMode: dataMode, generatedAt: generatedAt)
        case .csv:
            return makeCSVData(usage: usage)
        }
    }

    public func makeJSONData(
        usage: AggregatedUsage,
        snapshots: [ProviderSnapshot],
        dataMode: String,
        generatedAt: Date = Date()
    ) throws -> Data {
        let payload = UsageExportPayload(
            generatedAt: generatedAt,
            period: usage.period,
            dataMode: dataMode,
            metrics: usage.metrics,
            sevenDayBars: usage.sevenDayBars,
            providerShare: usage.providerShare,
            snapshots: snapshots.map(SnapshotExport.init(snapshot:)),
            events: usage.events.sorted(by: { $0.timestamp < $1.timestamp }).map(EventExport.init(event:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    public func makeCSVString(usage: AggregatedUsage) -> String {
        var rows: [[String]] = [[
            "row_type",
            "period",
            "provider",
            "timestamp_or_label",
            "input_tokens",
            "output_tokens",
            "cache_tokens",
            "reasoning_tokens",
            "tool_tokens",
            "total_tokens",
            "request_count",
            "cost_usd",
            "percent",
            "source",
            "model"
        ]]

        let metrics = usage.metrics
        rows.append(summaryRow(period: usage.period, label: "total", totalTokens: metrics.totalTokens, requestCount: metrics.requestCount, cost: metrics.estimatedCostUSD))
        rows.append(summaryRow(period: usage.period, label: "input", inputTokens: metrics.inputTokens))
        rows.append(summaryRow(period: usage.period, label: "output", outputTokens: metrics.outputTokens))
        rows.append(summaryRow(period: usage.period, label: "cache", cacheTokens: metrics.cacheTokens))

        for share in usage.providerShare {
            rows.append([
                "provider_share",
                usage.period.rawValue,
                share.provider.rawValue,
                "",
                "", "", "", "", "",
                String(share.tokens),
                "",
                "",
                String(share.percent),
                "",
                ""
            ])
        }

        for bar in usage.sevenDayBars {
            rows.append([
                "daily_bar",
                usage.period.rawValue,
                "",
                bar.dayLabel,
                "", "", "", "", "",
                String(bar.tokens),
                "",
                "",
                "",
                "",
                ""
            ])
        }

        for event in usage.events.sorted(by: { $0.timestamp < $1.timestamp }) {
            rows.append([
                "event",
                usage.period.rawValue,
                event.provider.rawValue,
                Self.isoString(from: event.timestamp),
                String(event.inputTokens),
                String(event.outputTokens),
                String(event.cacheTokens),
                String(event.reasoningTokens),
                String(event.toolTokens),
                String(event.totalTokens),
                String(event.requestCount),
                event.estimatedCostUSD.map(decimalString) ?? "",
                "",
                event.source,
                event.model ?? ""
            ])
        }

        return rows.map { $0.map(Self.escapeCSV).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private func makeCSVData(usage: AggregatedUsage) -> Data {
        Data(makeCSVString(usage: usage).utf8)
    }

    private func summaryRow(
        period: HistoryPeriod,
        label: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheTokens: Int? = nil,
        totalTokens: Int? = nil,
        requestCount: Int? = nil,
        cost: Decimal? = nil
    ) -> [String] {
        [
            "summary",
            period.rawValue,
            "",
            label,
            inputTokens.map(String.init) ?? "",
            outputTokens.map(String.init) ?? "",
            cacheTokens.map(String.init) ?? "",
            "",
            "",
            totalTokens.map(String.init) ?? "",
            requestCount.map(String.init) ?? "",
            cost.map(decimalString) ?? "",
            "",
            "",
            ""
        ]
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

public struct UsageExportPayload: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var period: HistoryPeriod
    public var dataMode: String
    public var metrics: UsageMetrics
    public var sevenDayBars: [DailyUsageBar]
    public var providerShare: [ProviderShare]
    public var snapshots: [SnapshotExport]
    public var events: [EventExport]
}

public struct SnapshotExport: Codable, Equatable, Sendable {
    public var provider: Provider
    public var updatedAt: Date
    public var confidence: DataConfidence
    public var isStale: Bool
    public var statusMessage: String?
    public var model: String?
    public var todayTokens: Int
    public var todayCostUSD: Decimal?
    public var fiveHourUsedPercent: Int?
    public var fiveHourResetAt: Date?
    public var weeklyUsedPercent: Int?
    public var weeklyResetAt: Date?
    public var dailyRequestsUsed: Int?
    public var dailyRequestsLimit: Int?
    public var contextWindowUsedPercent: Int?

    public init(snapshot: ProviderSnapshot) {
        self.provider = snapshot.provider
        self.updatedAt = snapshot.updatedAt
        self.confidence = snapshot.confidence
        self.isStale = snapshot.isStale
        self.statusMessage = snapshot.statusMessage
        self.model = snapshot.model
        self.todayTokens = snapshot.isCodexLocalLogOnly ? 0 : snapshot.todayTokens
        self.todayCostUSD = snapshot.todayCostUSD
        self.fiveHourUsedPercent = snapshot.fiveHour?.usedPercent
        self.fiveHourResetAt = snapshot.fiveHour?.resetAt
        self.weeklyUsedPercent = snapshot.weekly?.usedPercent
        self.weeklyResetAt = snapshot.weekly?.resetAt
        self.dailyRequestsUsed = snapshot.dailyRequestsUsed
        self.dailyRequestsLimit = snapshot.dailyRequestsLimit
        self.contextWindowUsedPercent = snapshot.contextWindowUsedPercent
    }
}

public struct EventExport: Codable, Equatable, Sendable {
    public var provider: Provider
    public var model: String?
    public var timestamp: Date
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheTokens: Int
    public var reasoningTokens: Int
    public var toolTokens: Int
    public var requestCount: Int
    public var estimatedCostUSD: Decimal?
    public var source: String
    public var durationMS: Int?
    public var totalTokens: Int

    public init(event: UsageEvent) {
        self.provider = event.provider
        self.model = event.model
        self.timestamp = event.timestamp
        self.inputTokens = event.inputTokens
        self.outputTokens = event.outputTokens
        self.cacheTokens = event.cacheTokens
        self.reasoningTokens = event.reasoningTokens
        self.toolTokens = event.toolTokens
        self.requestCount = event.requestCount
        self.estimatedCostUSD = event.estimatedCostUSD
        self.source = event.source
        self.durationMS = event.durationMS
        self.totalTokens = event.totalTokens
    }
}

private func decimalString(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
}
