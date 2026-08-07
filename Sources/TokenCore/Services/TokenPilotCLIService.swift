import Foundation

/// Commands accepted by the `TokenPilot export|summary|help` CLI surface.
///
/// The CLI is intentionally a read-only view over locally stored usage events: it never reads
/// provider credentials, never starts the AppKit app, and every exported payload goes through
/// the same redaction pipeline as GUI export.
public enum TokenPilotCLICommand: Equatable, Sendable {
    case export(format: UsageExportFormat, period: HistoryPeriod, outputPath: String?, includesCapacity: Bool)
    case summary
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
        return first == "export" || first == "summary" || first == "help" ||
            first == "-h" || first == "--help"
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
        case "export":
            return parseExport(Array(arguments.dropFirst()))
        default:
            return .failure(.unknownCommand(command))
        }
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
          TokenPilot help

        export writes locally stored usage events as JSON (default) or CSV to stdout, or to <path>
        with --out. --capacity appends the latest stored capacity evidence per series. summary
        prints today's local usage totals. Exports never include prompts, responses, local paths,
        chat IDs, webhooks, or provider credentials.
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
            lines.append(
                "\(localized(share.provider.displayName, language: language)): " +
                "\(TokenPilotFormatters.compactNumber(share.tokens)) " +
                "\(localized("tok", language: language)) (\(share.percent)%)"
            )
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
