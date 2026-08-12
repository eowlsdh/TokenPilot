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

    private static let csvContractSource = "local_activity_contract"
    private static let csvLocalActivitySource = "local_activity_not_provider_quota"

    public init() {}

    public func export(
        usage: AggregatedUsage,
        snapshots: [ProviderSnapshot],
        dataMode: String,
        format: UsageExportFormat,
        generatedAt: Date = Date(),
        capacityAssessments: [CapacityAssessment] = [],
        includesCost: Bool = true
    ) throws -> Data {
        let exportUsage = sanitizedUsageForExport(usage)
        switch format {
        case .json:
            return try makeJSONData(usage: exportUsage, snapshots: snapshots, dataMode: dataMode, generatedAt: generatedAt, capacityAssessments: capacityAssessments, includesCost: includesCost)
        case .csv:
            return makeCSVData(usage: exportUsage, includesCost: includesCost)
        }
    }

    public func makeJSONData(
        usage: AggregatedUsage,
        snapshots: [ProviderSnapshot],
        dataMode: String,
        generatedAt: Date = Date(),
        capacityAssessments: [CapacityAssessment] = [],
        includesCost: Bool = true
    ) throws -> Data {
        let payload = makeJSONPayload(
            usage: usage,
            snapshots: snapshots,
            dataMode: dataMode,
            generatedAt: generatedAt,
            capacityAssessments: capacityAssessments,
            includesCost: includesCost
        )
        return try encodeJSONPayload(payload)
    }

    /// Encodes a pre-built payload struct, so callers can attach per-project groups
    /// (`--instances` style) before serializing without a decode/re-encode round trip.
    public func encodeJSONPayload(_ payload: UsageExportPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    /// Builds the JSON export payload struct so callers can assemble multi-period
    /// envelopes (`--sections` style) without decoding/re-encoding intermediate JSON.
    public func makeJSONPayload(
        usage: AggregatedUsage,
        snapshots: [ProviderSnapshot],
        dataMode: String,
        generatedAt: Date = Date(),
        capacityAssessments: [CapacityAssessment] = [],
        includesCost: Bool = true
    ) -> UsageExportPayload {
        let sanitized = sanitizedUsageForExport(usage)
        let exportUsage = includesCost ? sanitized : costStripped(sanitized)
        return UsageExportPayload(
            generatedAt: generatedAt,
            period: usage.period,
            dataMode: dataMode,
            metrics: exportUsage.metrics,
            sevenDayBars: exportUsage.sevenDayBars,
            providerShare: exportUsage.providerShare,
            snapshots: snapshots.map(SnapshotExport.init(snapshot:)),
            events: exportUsage.events.sorted(by: { $0.timestamp < $1.timestamp }).map(EventExport.init(event:)),
            capacity: capacityAssessments.isEmpty ? nil : CapacityExportSection(assessments: capacityAssessments),
            modelBreakdown: exportUsage.modelBreakdown.map { share in
                ModelUsageShare(
                    provider: share.provider,
                    model: TokenPilotPrivacyRedactor.redact(share.model),
                    tokens: share.tokens,
                    requestCount: share.requestCount,
                    estimatedCostUSD: share.estimatedCostUSD,
                    tokenPercent: share.tokenPercent
                )
            }
        )
    }

    /// Encodes one export payload per requested period in a single envelope with a
    /// totals object last (ccusage `--sections` style).
    public func makeSectionsJSON(
        payloads: [UsageExportPayload],
        generatedAt: Date = Date(),
        includesCost: Bool = true
    ) throws -> Data {
        let envelope = UsageExportEnvelope(
            generatedAt: generatedAt,
            sections: payloads,
            totals: UsageExportTotals(
                totalTokens: payloads.reduce(0) { $0 + $1.metrics.totalTokens },
                requestCount: payloads.reduce(0) { $0 + $1.metrics.requestCount },
                estimatedCostUSD: includesCost
                    ? payloads.compactMap { $0.metrics.estimatedCostUSD > 0 ? $0.metrics.estimatedCostUSD : nil }.reduce(Decimal(0), +)
                    : nil
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    private func sanitizedUsageForExport(_ usage: AggregatedUsage) -> AggregatedUsage {
        let events = usage.events.filter(\.isWebQuotaComparable)
        let snapshots = Provider.allCases.map { provider in
            ProviderSnapshot(provider: provider, events: events.filter { $0.provider == provider })
        }
        return AggregationService().aggregate(snapshots: snapshots, period: usage.period)
    }

    /// Returns a copy of the aggregated usage with every cost field blanked so
    /// `--no-cost` exports never leak estimated cost figures.
    private func costStripped(_ usage: AggregatedUsage) -> AggregatedUsage {
        AggregatedUsage(
            period: usage.period,
            metrics: UsageMetrics(
                totalTokens: usage.metrics.totalTokens,
                inputTokens: usage.metrics.inputTokens,
                outputTokens: usage.metrics.outputTokens,
                cacheTokens: usage.metrics.cacheTokens,
                requestCount: usage.metrics.requestCount,
                estimatedCostUSD: 0,
                mostUsedProvider: usage.metrics.mostUsedProvider,
                busiestHour: usage.metrics.busiestHour
            ),
            sevenDayBars: usage.sevenDayBars,
            providerShare: usage.providerShare.map { share in
                ProviderShare(
                    provider: share.provider,
                    tokens: share.tokens,
                    percent: share.percent,
                    requestCount: share.requestCount,
                    estimatedCostUSD: nil
                )
            },
            events: usage.events.map { event in
                var stripped = event
                stripped.estimatedCostUSD = nil
                return stripped
            },
            modelBreakdown: usage.modelBreakdown.map { share in
                ModelUsageShare(
                    provider: share.provider,
                    model: share.model,
                    tokens: share.tokens,
                    requestCount: share.requestCount,
                    estimatedCostUSD: nil,
                    tokenPercent: share.tokenPercent
                )
            },
            projectBreakdown: usage.projectBreakdown.map { share in
                ProjectUsageShare(
                    provider: share.provider,
                    label: share.label,
                    tokens: share.tokens,
                    requestCount: share.requestCount,
                    estimatedCostUSD: nil,
                    tokenPercent: share.tokenPercent
                )
            }
        )
    }

    public func makeCSVString(usage: AggregatedUsage, includesCost: Bool = true) -> String {
        let sanitized = sanitizedUsageForExport(usage)
        let exportUsage = includesCost ? sanitized : costStripped(sanitized)
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

        rows.append([
            "metadata",
            exportUsage.period.rawValue,
            "",
            "schema_version",
            "", "", "", "", "",
            "2",
            "",
            "",
            "",
            Self.csvContractSource,
            ""
        ])

        let metrics = exportUsage.metrics
        rows.append(summaryRow(period: exportUsage.period, label: "total", totalTokens: metrics.totalTokens, requestCount: metrics.requestCount, cost: metrics.estimatedCostUSD))
        rows.append(summaryRow(period: exportUsage.period, label: "input", inputTokens: metrics.inputTokens))
        rows.append(summaryRow(period: exportUsage.period, label: "output", outputTokens: metrics.outputTokens))
        rows.append(summaryRow(period: exportUsage.period, label: "cache", cacheTokens: metrics.cacheTokens))

        for share in exportUsage.providerShare {
            rows.append([
                "provider_share",
                exportUsage.period.rawValue,
                share.provider.rawValue,
                "",
                "", "", "", "", "",
                String(share.tokens),
                "",
                "",
                String(share.percent),
                Self.csvLocalActivitySource,
                ""
            ])
        }

        for bar in exportUsage.sevenDayBars {
            rows.append([
                "daily_bar",
                exportUsage.period.rawValue,
                "",
                bar.dayLabel,
                "", "", "", "", "",
                String(bar.tokens),
                "",
                "",
                "",
                Self.csvLocalActivitySource,
                ""
            ])
        }

        for event in exportUsage.events.sorted(by: { $0.timestamp < $1.timestamp }) {
            rows.append([
                "event",
                exportUsage.period.rawValue,
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
                TokenPilotPrivacyRedactor.redactExportField(event.source) ?? "unknown",
                ""
            ])
        }

        return rows.map { $0.map(Self.escapeCSV).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private func makeCSVData(usage: AggregatedUsage, includesCost: Bool = true) -> Data {
        Data(makeCSVString(usage: usage, includesCost: includesCost).utf8)
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
    public var schemaVersion: Int
    public var generatedAt: Date
    public var period: HistoryPeriod
    public var dataMode: String
    public var metrics: UsageMetrics
    public var localActivity: LocalActivityExport
    public var sevenDayBars: [DailyUsageBar]
    public var providerShare: [ProviderShare]
    public var snapshots: [SnapshotExport]
    public var events: [EventExport]
    public var capacity: CapacityExportSection?
    public var projects: [ExportProjectGroup]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case period
        case dataMode
        case metrics
        case localActivity
        case sevenDayBars
        case providerShare
        case snapshots
        case events
        case capacity
        case projects
    }

    public init(
        schemaVersion: Int = 2,
        generatedAt: Date,
        period: HistoryPeriod,
        dataMode: String,
        metrics: UsageMetrics,
        sevenDayBars: [DailyUsageBar],
        providerShare: [ProviderShare],
        snapshots: [SnapshotExport],
        events: [EventExport],
        capacity: CapacityExportSection? = nil,
        localActivity: LocalActivityExport? = nil,
        modelBreakdown: [ModelUsageShare] = [],
        projects: [ExportProjectGroup]? = nil
    ) {
        let resolvedLocalActivity = localActivity ?? LocalActivityExport(
            sevenDayBars: sevenDayBars,
            providerShare: providerShare,
            modelBreakdown: modelBreakdown
        )
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.period = period
        self.dataMode = dataMode
        self.metrics = metrics
        self.localActivity = resolvedLocalActivity
        self.sevenDayBars = resolvedLocalActivity.sevenDayBars
        self.providerShare = resolvedLocalActivity.providerShare
        self.snapshots = snapshots
        self.events = events
        self.capacity = capacity
        self.projects = projects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSevenDayBars = try container.decodeIfPresent([DailyUsageBar].self, forKey: .sevenDayBars) ?? []
        let decodedProviderShare = try container.decodeIfPresent([ProviderShare].self, forKey: .providerShare) ?? []
        let resolvedLocalActivity = try container.decodeIfPresent(LocalActivityExport.self, forKey: .localActivity)
            ?? LocalActivityExport(sevenDayBars: decodedSevenDayBars, providerShare: decodedProviderShare)

        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        period = try container.decode(HistoryPeriod.self, forKey: .period)
        dataMode = try container.decode(String.self, forKey: .dataMode)
        metrics = try container.decode(UsageMetrics.self, forKey: .metrics)
        localActivity = resolvedLocalActivity
        sevenDayBars = resolvedLocalActivity.sevenDayBars
        providerShare = resolvedLocalActivity.providerShare
        snapshots = try container.decodeIfPresent([SnapshotExport].self, forKey: .snapshots) ?? []
        events = try container.decodeIfPresent([EventExport].self, forKey: .events) ?? []
        capacity = try container.decodeIfPresent(CapacityExportSection.self, forKey: .capacity)
        projects = try container.decodeIfPresent([ExportProjectGroup].self, forKey: .projects)
    }
}

public struct ExportProjectGroup: Codable, Equatable, Sendable {
    public var project: String
    public var payload: UsageExportPayload

    public init(project: String, payload: UsageExportPayload) {
        self.project = project
        self.payload = payload
    }
}

public struct LocalActivityExport: Codable, Equatable, Sendable {
    public static let defaultScope = "export_eligible_local_activity_not_provider_quota"

    public var scope: String
    public var sevenDayBars: [DailyUsageBar]
    public var providerShare: [ProviderShare]
    public var modelBreakdown: [ModelUsageShare]
    public var quotaComparableOnly: Bool

    public init(
        scope: String = Self.defaultScope,
        sevenDayBars: [DailyUsageBar],
        providerShare: [ProviderShare],
        modelBreakdown: [ModelUsageShare] = [],
        quotaComparableOnly: Bool = true
    ) {
        self.scope = scope
        self.sevenDayBars = sevenDayBars
        self.providerShare = providerShare
        self.modelBreakdown = modelBreakdown
        self.quotaComparableOnly = quotaComparableOnly
    }
}

public struct CapacityExportSection: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var observations: [CapacityObservationExport]

    public init(schemaVersion: Int = 1, assessments: [CapacityAssessment]) {
        self.schemaVersion = schemaVersion
        self.observations = assessments
            .sorted {
                if $0.observation.observedAt != $1.observation.observedAt {
                    return $0.observation.observedAt < $1.observation.observedAt
                }
                return $0.observation.seriesID.canonicalID < $1.observation.seriesID.canonicalID
            }
            .map(CapacityObservationExport.init(assessment:))
    }
}

public struct CapacityObservationExport: Codable, Equatable, Sendable {
    public var provider: Provider
    public var seriesID: String
    public var providerWindowID: String
    public var kind: CapacitySeriesKind
    public var unit: CapacityUnit
    public var durationMinutes: Int?
    public var observedAt: Date
    public var resetAt: Date?
    public var usedPercent: Int?
    public var remainingPercent: Int?
    public var moneyAmount: Decimal?
    public var currency: String?
    public var count: Int?
    public var tokens: Int?
    public var authority: CapacityAuthority
    public var stability: CapacityStability
    public var consent: CapacityConsent
    public var freshness: CapacityFreshness
    public var comparability: CapacityComparability
    public var risk: CapacityRisk
    public var alertEligibility: CapacityAlertEligibility
    public var eligibilityReason: CapacityEligibilityReason
    public var actionKey: CapacityActionKey
    public var parserRevision: String

    public init(assessment: CapacityAssessment) {
        let observation = assessment.observation
        self.provider = observation.seriesID.provider
        self.seriesID = observation.seriesID.canonicalID
        self.providerWindowID = observation.seriesID.providerWindowID
        self.kind = observation.seriesID.kind
        self.unit = observation.seriesID.unit
        self.durationMinutes = observation.seriesID.durationMinutes
        self.observedAt = observation.observedAt
        self.resetAt = observation.resetAt
        self.usedPercent = observation.value.usedPercent
        self.remainingPercent = observation.value.usedPercent.map { min(max(100 - $0, 0), 100) }
        self.moneyAmount = observation.value.moneyAmount
        self.currency = observation.value.currency
        self.count = observation.value.count
        self.tokens = observation.value.tokens
        self.authority = observation.authority
        self.stability = observation.stability
        self.consent = observation.consent
        self.freshness = assessment.freshness
        self.comparability = observation.comparability
        self.risk = assessment.risk
        self.alertEligibility = assessment.alertEligibility
        self.eligibilityReason = assessment.eligibilityReason
        self.actionKey = assessment.actionKey
        self.parserRevision = observation.parserRevision
    }
}

public struct SnapshotExport: Codable, Equatable, Sendable {
    public var provider: Provider
    public var updatedAt: Date
    public var confidence: DataConfidence
    public var isStale: Bool
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
        self.timestamp = event.timestamp
        self.inputTokens = event.inputTokens
        self.outputTokens = event.outputTokens
        self.cacheTokens = event.cacheTokens
        self.reasoningTokens = event.reasoningTokens
        self.toolTokens = event.toolTokens
        self.requestCount = event.requestCount
        self.estimatedCostUSD = event.estimatedCostUSD
        self.source = TokenPilotPrivacyRedactor.redactExportField(event.source) ?? "unknown"
        self.durationMS = event.durationMS
        self.totalTokens = event.totalTokens
    }
}

private func decimalString(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
}

/// Multi-period export envelope (ccusage `--sections` style): one export payload per
/// requested period plus a totals object last, mirroring the report/stats envelopes.
public struct UsageExportEnvelope: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var sections: [UsageExportPayload]
    public var totals: UsageExportTotals

    public init(generatedAt: Date, sections: [UsageExportPayload], totals: UsageExportTotals) {
        self.generatedAt = generatedAt
        self.sections = sections
        self.totals = totals
    }
}

public struct UsageExportTotals: Codable, Equatable, Sendable {
    public var totalTokens: Int
    public var requestCount: Int
    public var estimatedCostUSD: Decimal?

    public init(totalTokens: Int, requestCount: Int, estimatedCostUSD: Decimal?) {
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.estimatedCostUSD = estimatedCostUSD
    }
}
