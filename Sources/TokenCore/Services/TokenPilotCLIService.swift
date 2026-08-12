import Foundation

/// Commands accepted by the `TokenPilot export|summary|help` CLI surface.
///
/// The CLI is intentionally a read-only view over locally stored usage events: it never reads
/// provider credentials, never starts the AppKit app, and every exported payload goes through
/// the same redaction pipeline as GUI export.
/// Output format for the `report` command.
public enum TokenPilotReportFormat: String, Equatable, Sendable {
    case text
    case svg
}

public enum TokenPilotCLICommand: Equatable, Sendable {
    case export(format: UsageExportFormat, period: HistoryPeriod, outputPath: String?, includesCapacity: Bool)
    case summary
    case report(period: HistoryPeriod, format: TokenPilotReportFormat)
    case audit
    case help
}

public enum TokenPilotCLIError: Error, Equatable, Sendable, LocalizedError {
    case unknownCommand(String)
    case invalidFormat(String)
    case invalidPeriod(String)
    case missingValue(forFlag: String)

    public var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "Unknown command '\(command)'."
        case .invalidFormat(let format):
            return "Unsupported format '\(format)'. Use json or csv."
        case .invalidPeriod(let period):
            return "Unsupported period '\(period)'. Use today, last7Days, or thisMonth."
        case .missingValue(let flag):
            return "Missing value for '\(flag)'."
        }
    }
}

public enum TokenPilotCLIService {
    /// True when the first argument is a CLI command, so the app entry point can skip AppKit.
    public static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return first == "export" || first == "summary" || first == "report" ||
            first == "audit" || first == "help" || first == "-h" || first == "--help"
    }

    public static func parse(arguments: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        guard let command = arguments.first, !command.isEmpty else {
            return .failure(.unknownCommand(""))
        }
        switch command {
        case "help", "-h", "--help":
            return .success(.help)
        case "summary":
            return .success(.summary)
        case "report":
            return parseReport(Array(arguments.dropFirst()))
        case "audit":
            return .success(.audit)
        case "export":
            return parseExport(Array(arguments.dropFirst()))
        default:
            return .failure(.unknownCommand(command))
        }
    }

    private static func parseReport(_ flags: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        var period = HistoryPeriod.last7Days
        var format = TokenPilotReportFormat.text
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            switch flag {
            case "--period":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = HistoryPeriod(rawValue: flags[index]) else {
                    return .failure(.invalidPeriod(flags[index]))
                }
                period = parsed
            case "--svg":
                format = .svg
            default:
                return .failure(.unknownCommand(flag))
            }
            index += 1
        }
        return .success(.report(period: period, format: format))
    }

    private static func parseExport(_ flags: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        var format = UsageExportFormat.json
        var period = HistoryPeriod.last7Days
        var outputPath: String?
        var includesCapacity = false
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            switch flag {
            case "--format":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = UsageExportFormat(rawValue: flags[index]) else {
                    return .failure(.invalidFormat(flags[index]))
                }
                format = parsed
            case "--period":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = HistoryPeriod(rawValue: flags[index]) else {
                    return .failure(.invalidPeriod(flags[index]))
                }
                period = parsed
            case "--out":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                outputPath = flags[index]
            case "--capacity":
                includesCapacity = true
            default:
                return .failure(.unknownCommand(flag))
            }
            index += 1
        }
        return .success(.export(format: format, period: period, outputPath: outputPath, includesCapacity: includesCapacity))
    }

    public static var helpText: String {
        """
        TokenPilot - local-first AI usage monitor

        Usage:
          TokenPilot export [--format json|csv] [--period today|last7Days|thisMonth] [--out <path>] [--capacity]
          TokenPilot summary
          TokenPilot report [--period today|last7Days|thisMonth] [--svg]
          TokenPilot audit
          TokenPilot help

        export writes locally stored usage events as JSON (default) or CSV to stdout, or to <path>
        with --out. --capacity appends the latest stored capacity evidence per series. summary
        prints today's local usage totals. report prints a shareable usage receipt with a
        per-day breakdown and cache efficiency; --svg emits the same receipt as a standalone
        SVG. audit reports local history coverage so you can
        spot gaps left by providers that prune their own logs. Exports, reports, and audits never
        include prompts, responses, local paths, chat IDs, webhooks, or provider credentials.
        """
    }

    /// Compact usage summary used by both the `summary` command and the GUI "Copy summary" action.
    ///
    /// Only aggregates (totals, request count, cost, provider share, capacity remaining percent)
    /// are included; raw event fields never reach the output.
    public static func summaryText(
        events: [UsageEvent],
        snapshots: [ProviderSnapshot] = [],
        enabledProviders: [Provider],
        language: TokenPilotLanguage,
        period: HistoryPeriod = .today,
        now: Date = Date()
    ) -> String {
        let enabledSet = Set(enabledProviders)
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: events.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, now: now)
        let metrics = usage.metrics

        var lines: [String] = []
        lines.append("TokenPilot")
        lines.append("\(localized("Period", language: language)): \(periodLabel(period, language: language))")
        lines.append("\(localized("Total tokens", language: language)): \(TokenPilotFormatters.compactNumber(metrics.totalTokens))")
        lines.append("\(localized("Requests", language: language)): \(TokenPilotFormatters.compactNumber(metrics.requestCount))")
        if metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            lines.append("\(localized("Estimated cost", language: language)): \(String(format: "$%.2f", amount))")
        }
        for share in usage.providerShare where share.tokens > 0 {
            lines.append(providerShareLine(share, language: language))
        }

        let menuBarService = MenuBarStatusService()
        for snapshot in snapshots
        where enabledSet.contains(snapshot.provider) {
            guard let window = menuBarService.displayWindow(for: snapshot),
                  let remaining = window.remainingPercent else {
                continue
            }
            let providerName = localized(snapshot.provider.displayName, language: language)
            let windowLabel = windowLabel(window.kind, language: language)
            lines.append(
                "\(providerName) (\(windowLabel)): \(remaining)% " +
                localized("Remaining", language: language)
            )
        }

        lines.append(localized("Local activity, not provider quota", language: language))
        return lines.joined(separator: "\n")
    }

    /// One provider share line, appending request count and recorded cost when present.
    private static func providerShareLine(_ share: ProviderShare, language: TokenPilotLanguage) -> String {
        var line = "\(localized(share.provider.displayName, language: language)): " +
            "\(TokenPilotFormatters.compactNumber(share.tokens)) " +
            "\(localized("tok", language: language)) (\(share.percent)%)"
        if share.requestCount > 0 {
            line += " · \(TokenPilotFormatters.compactNumber(share.requestCount)) \(localized("req", language: language))"
        }
        if let cost = share.estimatedCostUSD, cost > 0 {
            let amount = NSDecimalNumber(decimal: cost).doubleValue
            line += " · $\(String(format: "%.2f", amount))"
        }
        return line
    }

    /// Shareable plain-text receipt over stored local activity (toktrack-report style).
    ///
    /// Unlike `summaryText`, the receipt adds a per-day breakdown and cache
    /// efficiency so it reads as a standalone usage report. Only aggregates
    /// reach the output; raw event fields never appear.
    public static func reportText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        language: TokenPilotLanguage,
        period: HistoryPeriod = .last7Days,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let enabledSet = Set(enabledProviders)
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: events.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, now: now)
        let metrics = usage.metrics
        let periodEvents = events.filter { event in
            enabledSet.contains(event.provider) && isInPeriod(event.timestamp, period: period, now: now, calendar: calendar)
        }
        let cache = CacheEfficiencyService.summary(events: periodEvents, now: now, calendar: calendar)

        var lines: [String] = []
        lines.append("TokenPilot · \(localized("Report", language: language))")
        lines.append("\(localized("Period", language: language)): \(periodLabel(period, language: language))")
        lines.append("\(localized("Total tokens", language: language)): \(TokenPilotFormatters.compactNumber(metrics.totalTokens))")
        lines.append("\(localized("Requests", language: language)): \(TokenPilotFormatters.compactNumber(metrics.requestCount))")
        if metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            lines.append("\(localized("Estimated cost", language: language)): \(String(format: "$%.2f", amount))")
        }
        if cache.hasCacheActivity {
            let hitPercent = Int((cache.cacheHitRate * 100).rounded())
            lines.append("\(localized("Cache hit rate", language: language)): \(hitPercent)%")
        }
        for share in usage.providerShare where share.tokens > 0 {
            lines.append(providerShareLine(share, language: language))
        }
        let modelLines = modelRankingLines(usage.modelBreakdown, language: language, limit: 5)
        if !modelLines.isEmpty {
            lines.append(localized("Top models", language: language))
            lines.append(contentsOf: modelLines)
        }
        let dailyLines = dailyBreakdownLines(events: events.filter { enabledSet.contains($0.provider) }, period: period, now: now, calendar: calendar)
        if !dailyLines.isEmpty {
            lines.append(localized("Daily breakdown", language: language))
            lines.append(contentsOf: dailyLines)
        }
        lines.append(localized("Local activity, not provider quota", language: language))
        return lines.joined(separator: "\n")
    }

    /// Shareable SVG receipt over stored local activity (toktrack `report --svg` style).
    ///
    /// Renders the same aggregates as `reportText` (period, totals, cost, cache
    /// hit rate, provider shares, daily breakdown) as a standalone dark SVG.
    /// Only aggregates reach the markup; raw event fields never appear.
    public static func reportSVGText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod = .last7Days,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let enabledSet = Set(enabledProviders)
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: events.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, now: now)
        let metrics = usage.metrics
        let periodEvents = events.filter { event in
            enabledSet.contains(event.provider) && isInPeriod(event.timestamp, period: period, now: now, calendar: calendar)
        }
        let cache = CacheEfficiencyService.summary(events: periodEvents, now: now, calendar: calendar)

        let width = 640
        let rowHeight = 24
        var y = 48
        var lines: [String] = []

        func addText(_ text: String, size: Int, weight: String = "normal", fill: String = "#e6e6e6") {
            let escaped = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            lines.append("<text x=\"24\" y=\"\(y)\" font-family=\"-apple-system, sans-serif\" font-size=\"\(size)\" font-weight=\"\(weight)\" fill=\"\(fill)\">\(escaped)</text>")
            y += rowHeight
        }

        lines.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(y + 40)\" viewBox=\"0 0 \(width) \(y + 40)\">")
        lines.append("<rect width=\"100%\" height=\"100%\" fill=\"#1c1c1e\"/>")
        addText("TokenPilot · Report", size: 18, weight: "bold", fill: "#ffffff")
        addText("Period: \(periodLabel(period, language: .en))", size: 13)
        addText("Total tokens: \(TokenPilotFormatters.compactNumber(metrics.totalTokens))", size: 13)
        addText("Requests: \(TokenPilotFormatters.compactNumber(metrics.requestCount))", size: 13)
        if metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            addText("Estimated cost: $\(String(format: "%.2f", amount))", size: 13)
        }
        if cache.hasCacheActivity {
            let hitPercent = Int((cache.cacheHitRate * 100).rounded())
            addText("Cache hit rate: \(hitPercent)%", size: 13)
        }
        for share in usage.providerShare where share.tokens > 0 {
            addText(
                providerShareLine(share, language: .en),
                size: 13,
                fill: "#a5c8ff"
            )
        }
        let modelLines = modelRankingLines(usage.modelBreakdown, language: .en, limit: 5)
        if !modelLines.isEmpty {
            addText("Top models", size: 14, weight: "bold", fill: "#ffffff")
            for line in modelLines {
                addText(line, size: 12, fill: "#9b9b9b")
            }
        }
        let dailyLines = dailyBreakdownLines(
            events: events.filter { enabledSet.contains($0.provider) },
            period: period,
            now: now,
            calendar: calendar
        )
        if !dailyLines.isEmpty {
            addText("Daily breakdown", size: 14, weight: "bold", fill: "#ffffff")
            for line in dailyLines {
                addText(line, size: 12, fill: "#9b9b9b")
            }
        }
        addText("Local activity, not provider quota", size: 11, fill: "#666666")
        lines.append("</svg>")
        return lines.joined(separator: "\n")
    }

    /// Plain-text local-history coverage report (toktrack-audit style).
    ///
    /// Reports how much of the trailing retention window has recorded activity,
    /// the oldest/newest stored days, and gap statistics so users can spot data
    /// holes left by providers that prune their own logs. Aggregates only.
    public static func auditText(
        events: [UsageEvent],
        language: TokenPilotLanguage,
        windowDays: Int = 45,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let coverage = UsageCoverageService.coverage(events: events, windowDays: windowDays, now: now, calendar: calendar)
        let percent = Int((coverage.coverageRatio * 100).rounded())

        var lines: [String] = []
        lines.append("TokenPilot · \(localized("Audit", language: language))")
        lines.append(
            "\(localized("Coverage", language: language)): \(percent)% " +
            "\(localized("of last %d days", language: language).replacingOccurrences(of: "%d", with: "\(coverage.windowDays)"))"
        )
        lines.append("\(localized("Active days", language: language)): \(coverage.activeDays)")
        if let oldest = coverage.oldestEventDay, let newest = coverage.newestEventDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.dateFormat = "yyyy-MM-dd"
            lines.append("\(localized("Oldest stored", language: language)): \(formatter.string(from: oldest))")
            lines.append("\(localized("Newest stored", language: language)): \(formatter.string(from: newest))")
        } else {
            lines.append(localized("No stored local activity", language: language))
        }
        lines.append("\(localized("Gap runs", language: language)): \(coverage.gapRunCount)")
        lines.append("\(localized("Longest gap", language: language)): \(coverage.longestGapDays) \(localized("days", language: language))")
        lines.append(localized("Local activity, not provider quota", language: language))
        return lines.joined(separator: "\n")
    }

    private static func dailyBreakdownLines(
        events: [UsageEvent],
        period: HistoryPeriod,
        now: Date,
        calendar: Calendar
    ) -> [String] {
        guard let start = periodStart(period, now: now, calendar: calendar) else { return [] }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "MM-dd"
        let inWindow = events.filter { $0.timestamp >= start && $0.timestamp <= now }
        let dayTokens = Dictionary(grouping: inWindow) { event in
            calendar.startOfDay(for: event.timestamp)
        }.mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
        return dayTokens.keys.sorted().map { day in
            let tokens = dayTokens[day] ?? 0
            return "\(dayFormatter.string(from: day)): \(TokenPilotFormatters.compactNumber(tokens)) " + localized("tok", language: .en)
        }
    }

    private static func isInPeriod(_ date: Date, period: HistoryPeriod, now: Date, calendar: Calendar) -> Bool {
        guard let start = periodStart(period, now: now, calendar: calendar) else { return false }
        return date >= start && date <= now
    }

    /// Ranks models by token share and returns the top `limit` as plain lines.
    /// Mirrors the History per-model breakdown; cost is appended when recorded.
    private static func modelRankingLines(
        _ shares: [ModelUsageShare],
        language: TokenPilotLanguage,
        limit: Int = 5
    ) -> [String] {
        let top = shares
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
            .prefix(limit)
        return top.map { share in
            var line = "\(share.model): \(TokenPilotFormatters.compactNumber(share.tokens)) \(localized("tok", language: language)) (\(share.tokenPercent)%)"
            if let cost = share.estimatedCostUSD, cost > 0 {
                let amount = NSDecimalNumber(decimal: cost).doubleValue
                line += " · $\(String(format: "%.2f", amount))"
            }
            return line
        }
    }

    private static func periodStart(_ period: HistoryPeriod, now: Date, calendar: Calendar) -> Date? {
        switch period {
        case .today:
            return calendar.startOfDay(for: now)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)?.start
        }
    }

    private static func periodLabel(_ period: HistoryPeriod, language: TokenPilotLanguage) -> String {
        switch period {
        case .today:
            return localized("Today", language: language)
        case .last7Days:
            return localized("Last 7 days", language: language)
        case .thisMonth:
            return localized("This month", language: language)
        }
    }

    private static func windowLabel(_ kind: LimitWindowKind, language: TokenPilotLanguage) -> String {
        switch kind {
        case .fiveHour:
            return localized("5h window", language: language)
        case .weekly:
            return localized("Weekly window", language: language)
        case .monthly:
            return localized("Monthly window", language: language)
        case .dailyRequests:
            return localized("Daily requests", language: language)
        }
    }

    private static func localized(_ key: String, language: TokenPilotLanguage) -> String {
        TokenPilotLocalizer.localized(key, language: language)
    }
}
