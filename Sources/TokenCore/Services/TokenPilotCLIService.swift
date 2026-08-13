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
    case markdown
    case json
    case csv
}

public enum TokenPilotCLICommand: Equatable, Sendable {
    case export(format: UsageExportFormat, period: HistoryPeriod, outputPath: String?, includesCapacity: Bool, since: Date? = nil, until: Date? = nil, days: Int? = nil, includesCost: Bool = true, timeZone: TimeZone? = nil, project: String? = nil, weekStartDay: WeekStartDay? = nil, sections: [HistoryPeriod]? = nil, instances: Bool = false, provider: Provider? = nil)
    case summary(period: HistoryPeriod = .today, since: Date? = nil, until: Date? = nil, days: Int? = nil, timeZone: TimeZone? = nil, includesBreakdown: Bool = false, project: String? = nil, sections: [HistoryPeriod]? = nil, weekStartDay: WeekStartDay? = nil, includesCost: Bool = true, includesJSON: Bool = false, instances: Bool = false, includesCSV: Bool = false, includesMarkdown: Bool = false, provider: Provider? = nil, model: String? = nil)
    case stats(period: HistoryPeriod = .last7Days, since: Date? = nil, until: Date? = nil, days: Int? = nil, includesCost: Bool = true, timeZone: TimeZone? = nil, includesBreakdown: Bool = false, project: String? = nil, includesJSON: Bool = false, weekStartDay: WeekStartDay? = nil, sections: [HistoryPeriod]? = nil, instances: Bool = false, includesCSV: Bool = false, includesMarkdown: Bool = false, provider: Provider? = nil, model: String? = nil)
    case report(period: HistoryPeriod, format: TokenPilotReportFormat, since: Date? = nil, until: Date? = nil, days: Int? = nil, includesCost: Bool = true, timeZone: TimeZone? = nil, includesBreakdown: Bool = false, project: String? = nil, sections: [HistoryPeriod]? = nil, weekStartDay: WeekStartDay? = nil, instances: Bool = false, provider: Provider? = nil)
    case audit(includesJSON: Bool = false, since: Date? = nil, until: Date? = nil, days: Int? = nil, timeZone: TimeZone? = nil, project: String? = nil, sections: [HistoryPeriod]? = nil, includesCSV: Bool = false, instances: Bool = false, includesMarkdown: Bool = false, provider: Provider? = nil)
    case blocks(includesJSON: Bool = false, active: Bool = false, recent: Bool = false, timeZone: TimeZone? = nil, since: Date? = nil, until: Date? = nil, days: Int? = nil, includesCSV: Bool = false, includesMarkdown: Bool = false)
    case help
}

public enum TokenPilotCLIError: Error, Equatable, Sendable, LocalizedError {
    case unknownCommand(String)
    case invalidFormat(String)
    case invalidPeriod(String)
    case invalidProvider(String)
    case invalidDate(String)
    case invalidDays(String)
    case invalidTimezone(String)
    case invalidWeekStartDay(String)
    case invalidCombination(String)
    case missingValue(forFlag: String)

    public var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "Unknown command '\(command)'."
        case .invalidFormat(let format):
            return "Unsupported format '\(format)'. Use json or csv."
        case .invalidPeriod(let period):
            return "Unsupported period '\(period)'. Use today, last7Days, or thisMonth."
        case .invalidProvider(let provider):
            return "Unsupported provider '\(provider)'. Use claude, codex, gemini, deepseek, xai, opencode, or kiro."
        case .invalidDate(let date):
            return "Unsupported date '\(date)'. Use yyyy-MM-dd (for example 2026-08-13)."
        case .invalidDays(let days):
            return "Unsupported day count '\(days)'. Use a positive integer (for example --days 14)."
        case .invalidTimezone(let zone):
            return "Unsupported timezone '\(zone)'. Use an IANA identifier (for example UTC or Asia/Seoul)."
        case .invalidWeekStartDay(let day):
            return "Unsupported week start day '\(day)'. Use sunday, monday, tuesday, wednesday, thursday, friday, or saturday."
        case .invalidCombination(let message):
            return message
        case .missingValue(let flag):
            return "Missing value for '\(flag)'."
        }
    }
}

public enum TokenPilotCLIService {
    /// True when the first argument is a CLI command, so the app entry point can skip AppKit.
    public static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return first == "export" || first == "summary" || first == "stats" || first == "report" ||
            first == "audit" || first == "blocks" || first == "help" || first == "-h" || first == "--help"
    }

    public static func parse(arguments: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        guard let command = arguments.first, !command.isEmpty else {
            return .failure(.unknownCommand(""))
        }
        switch command {
        case "help", "-h", "--help":
            return .success(.help)
        case "summary":
            return parseSummary(Array(arguments.dropFirst()))
        case "stats":
            return parseStats(Array(arguments.dropFirst()))
        case "report":
            return parseReport(Array(arguments.dropFirst()))
        case "audit":
            return parseAudit(Array(arguments.dropFirst()))
        case "blocks":
            return parseBlocks(Array(arguments.dropFirst()))
        case "export":
            return parseExport(Array(arguments.dropFirst()))
        default:
            return .failure(.unknownCommand(command))
        }
    }

    private static func parseAudit(_ flags: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        var includesJSON = false
        var since: Date?
        var until: Date?
        var days: Int?
        var timeZone: TimeZone?
        var project: String?
        var provider: Provider?
        var sections: [HistoryPeriod]?
        var includesCSV = false
        var instances = false
        var includesMarkdown = false
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            switch flag {
            case "--json":
                includesJSON = true
            case "--since":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                since = parsed
            case "--until":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                until = parsed
            case "--days":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Int(flags[index]), parsed > 0 else {
                    return .failure(.invalidDays(flags[index]))
                }
                days = parsed
            case "--timezone":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = TimeZone(identifier: flags[index]) else {
                    return .failure(.invalidTimezone(flags[index]))
                }
                timeZone = parsed
            case "--project":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                project = flags[index]
            case "--provider":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Provider(rawValue: flags[index]) else {
                    return .failure(.invalidProvider(flags[index]))
                }
                provider = parsed
            case "--sections":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                let names = flags[index].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let parsed = names.map { HistoryPeriod(rawValue: $0) }
                guard !parsed.contains(nil) else {
                    let invalid = names.enumerated().first { parsed[$0.offset] == nil }?.element ?? flags[index]
                    return .failure(.invalidPeriod(invalid))
                }
                sections = parsed.compactMap { $0 }
            case "--csv":
                includesCSV = true
            case "--instances":
                instances = true
            case "--md":
                includesMarkdown = true
            default:
                return .failure(.unknownCommand(flag))
            }
            index += 1
        }
        if days != nil, since != nil || until != nil {
            return .failure(.invalidCombination("--days cannot be combined with --since or --until."))
        }
        if sections != nil, since != nil || until != nil || days != nil {
            return .failure(.invalidCombination("--sections cannot be combined with --since, --until, or --days."))
        }
        if sections != nil, !includesJSON {
            return .failure(.invalidCombination("--sections requires --json output."))
        }
        if instances, !includesJSON {
            return .failure(.invalidCombination("--instances requires --json output."))
        }
        if instances, project != nil {
            return .failure(.invalidCombination("--instances cannot be combined with --project."))
        }
        if includesCSV, includesJSON {
            return .failure(.invalidCombination("--csv cannot be combined with --json."))
        }
        if includesMarkdown, includesJSON || includesCSV {
            return .failure(.invalidCombination("--md cannot be combined with --json or --csv."))
        }
        return .success(.audit(includesJSON: includesJSON, since: since, until: until, days: days, timeZone: timeZone, project: project, sections: sections, includesCSV: includesCSV, instances: instances, includesMarkdown: includesMarkdown, provider: provider))
    }

    private static func parseSummary(_ flags: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        var period = HistoryPeriod.today
        var since: Date?
        var until: Date?
        var days: Int?
        var timeZone: TimeZone?
        var includesBreakdown = false
        var project: String?
        var provider: Provider?
        var model: String?
        var sections: [HistoryPeriod]?
        var weekStartDay: WeekStartDay?
        var includesCost = true
        var includesJSON = false
        var instances = false
        var includesCSV = false
        var includesMarkdown = false
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
            case "--since":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                since = parsed
            case "--until":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                until = parsed
            case "--days":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Int(flags[index]), parsed > 0 else {
                    return .failure(.invalidDays(flags[index]))
                }
                days = parsed
            case "--timezone":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = TimeZone(identifier: flags[index]) else {
                    return .failure(.invalidTimezone(flags[index]))
                }
                timeZone = parsed
            case "--project":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                project = flags[index]
            case "--provider":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Provider(rawValue: flags[index]) else {
                    return .failure(.invalidProvider(flags[index]))
                }
                provider = parsed
            case "--model":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                model = flags[index]
            case "--sections":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                let names = flags[index].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let parsed = names.map { HistoryPeriod(rawValue: $0) }
                guard !parsed.contains(nil) else {
                    let invalid = names.enumerated().first { parsed[$0.offset] == nil }?.element ?? flags[index]
                    return .failure(.invalidPeriod(invalid))
                }
                sections = parsed.compactMap { $0 }
            case "--start-of-week":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseWeekStartDay(flags[index]) else {
                    return .failure(.invalidWeekStartDay(flags[index]))
                }
                weekStartDay = parsed
            case "--no-cost":
                includesCost = false
            case "--breakdown":
                includesBreakdown = true
            case "--instances":
                instances = true
            case "--json":
                includesJSON = true
            case "--csv":
                includesCSV = true
            case "--md":
                includesMarkdown = true
            default:
                return .failure(.unknownCommand(flag))
            }
            index += 1
        }
        if days != nil, since != nil || until != nil {
            return .failure(.invalidCombination("--days cannot be combined with --since or --until."))
        }
        if sections != nil, since != nil || until != nil || days != nil {
            return .failure(.invalidCombination("--sections cannot be combined with --since, --until, or --days."))
        }
        if sections != nil, !includesJSON {
            return .failure(.invalidCombination("--sections requires --json output."))
        }
        if weekStartDay != nil, since != nil || until != nil || days != nil || sections != nil {
            return .failure(.invalidCombination("--start-of-week cannot be combined with --since, --until, --days, or --sections."))
        }
        if instances, !includesJSON {
            return .failure(.invalidCombination("--instances requires --json output."))
        }
        if instances, project != nil {
            return .failure(.invalidCombination("--instances cannot be combined with --project."))
        }
        if includesCSV, includesJSON {
            return .failure(.invalidCombination("--csv cannot be combined with --json."))
        }
        if includesMarkdown, includesJSON || includesCSV {
            return .failure(.invalidCombination("--md cannot be combined with --json or --csv."))
        }
        return .success(.summary(period: period, since: since, until: until, days: days, timeZone: timeZone, includesBreakdown: includesBreakdown, project: project, sections: sections, weekStartDay: weekStartDay, includesCost: includesCost, includesJSON: includesJSON, instances: instances, includesCSV: includesCSV, includesMarkdown: includesMarkdown, provider: provider, model: model))
    }

    private static func parseBlocks(_ flags: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        var includesJSON = false
        var includesCSV = false
        var includesMarkdown = false
        var active = false
        var recent = false
        var timeZone: TimeZone?
        var since: Date?
        var until: Date?
        var days: Int?
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            switch flag {
            case "--json":
                includesJSON = true
            case "--csv":
                includesCSV = true
            case "--md":
                includesMarkdown = true
            case "--active":
                active = true
            case "--recent":
                recent = true
            case "--timezone":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = TimeZone(identifier: flags[index]) else {
                    return .failure(.invalidTimezone(flags[index]))
                }
                timeZone = parsed
            case "--since":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                since = parsed
            case "--until":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                until = parsed
            case "--days":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Int(flags[index]), parsed > 0 else {
                    return .failure(.invalidDays(flags[index]))
                }
                days = parsed
            default:
                return .failure(.unknownCommand(flag))
            }
            index += 1
        }
        if days != nil, since != nil || until != nil {
            return .failure(.invalidCombination("--days cannot be combined with --since or --until."))
        }
        if includesCSV, includesJSON {
            return .failure(.invalidCombination("--csv cannot be combined with --json."))
        }
        if includesMarkdown, includesJSON || includesCSV {
            return .failure(.invalidCombination("--md cannot be combined with --json or --csv."))
        }
        return .success(.blocks(includesJSON: includesJSON, active: active, recent: recent, timeZone: timeZone, since: since, until: until, days: days, includesCSV: includesCSV, includesMarkdown: includesMarkdown))
    }

    private static func parseReport(_ flags: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        var period = HistoryPeriod.last7Days
        var format = TokenPilotReportFormat.text
        var since: Date?
        var until: Date?
        var days: Int?
        var includesCost = true
        var timeZone: TimeZone?
        var includesBreakdown = false
        var project: String?
        var provider: Provider?
        var sections: [HistoryPeriod]?
        var weekStartDay: WeekStartDay?
        var instances = false
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
            case "--since":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                since = parsed
            case "--until":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                until = parsed
            case "--days":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Int(flags[index]), parsed > 0 else {
                    return .failure(.invalidDays(flags[index]))
                }
                days = parsed
            case "--timezone":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = TimeZone(identifier: flags[index]) else {
                    return .failure(.invalidTimezone(flags[index]))
                }
                timeZone = parsed
            case "--project":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                project = flags[index]
            case "--provider":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Provider(rawValue: flags[index]) else {
                    return .failure(.invalidProvider(flags[index]))
                }
                provider = parsed
            case "--sections":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                let names = flags[index].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let parsed = names.map { HistoryPeriod(rawValue: $0) }
                guard !parsed.contains(nil) else {
                    let invalid = names.enumerated().first { parsed[$0.offset] == nil }?.element ?? flags[index]
                    return .failure(.invalidPeriod(invalid))
                }
                sections = parsed.compactMap { $0 }
            case "--start-of-week":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseWeekStartDay(flags[index]) else {
                    return .failure(.invalidWeekStartDay(flags[index]))
                }
                weekStartDay = parsed
            case "--instances":
                instances = true
            case "--svg":
                format = .svg
            case "--md":
                format = .markdown
            case "--json":
                format = .json
            case "--csv":
                format = .csv
            case "--no-cost":
                includesCost = false
            case "--breakdown":
                includesBreakdown = true
            default:
                return .failure(.unknownCommand(flag))
            }
            index += 1
        }
        if sections != nil, since != nil || until != nil || days != nil {
            return .failure(.invalidCombination("--sections cannot be combined with --since, --until, or --days."))
        }
        if sections != nil, format != .json {
            return .failure(.invalidCombination("--sections requires --json output."))
        }
        if weekStartDay != nil, since != nil || until != nil || days != nil || sections != nil {
            return .failure(.invalidCombination("--start-of-week cannot be combined with --since, --until, --days, or --sections."))
        }
        if instances, format != .json {
            return .failure(.invalidCombination("--instances requires --json output."))
        }
        if instances, project != nil {
            return .failure(.invalidCombination("--instances cannot be combined with --project."))
        }
        return .success(.report(period: period, format: format, since: since, until: until, days: days, includesCost: includesCost, timeZone: timeZone, includesBreakdown: includesBreakdown, project: project, sections: sections, weekStartDay: weekStartDay, instances: instances, provider: provider))
    }

    private static func parseExport(_ flags: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        var format = UsageExportFormat.json
        var period = HistoryPeriod.last7Days
        var outputPath: String?
        var includesCapacity = false
        var since: Date?
        var until: Date?
        var days: Int?
        var includesCost = true
        var timeZone: TimeZone?
        var project: String?
        var provider: Provider?
        var weekStartDay: WeekStartDay?
        var sections: [HistoryPeriod]?
        var instances = false
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
            case "--since":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                since = parsed
            case "--until":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                until = parsed
            case "--days":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Int(flags[index]), parsed > 0 else {
                    return .failure(.invalidDays(flags[index]))
                }
                days = parsed
            case "--timezone":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = TimeZone(identifier: flags[index]) else {
                    return .failure(.invalidTimezone(flags[index]))
                }
                timeZone = parsed
            case "--project":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                project = flags[index]
            case "--provider":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Provider(rawValue: flags[index]) else {
                    return .failure(.invalidProvider(flags[index]))
                }
                provider = parsed
            case "--start-of-week":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseWeekStartDay(flags[index]) else {
                    return .failure(.invalidWeekStartDay(flags[index]))
                }
                weekStartDay = parsed
            case "--sections":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                let names = flags[index].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let parsed = names.map { HistoryPeriod(rawValue: $0) }
                guard !parsed.contains(nil) else {
                    let invalid = names.enumerated().first { parsed[$0.offset] == nil }?.element ?? flags[index]
                    return .failure(.invalidPeriod(invalid))
                }
                sections = parsed.compactMap { $0 }
            case "--out":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                outputPath = flags[index]
            case "--capacity":
                includesCapacity = true
            case "--no-cost":
                includesCost = false
            case "--instances":
                instances = true
            default:
                return .failure(.unknownCommand(flag))
            }
            index += 1
        }
        if sections != nil, since != nil || until != nil || days != nil {
            return .failure(.invalidCombination("--sections cannot be combined with --since, --until, or --days."))
        }
        if sections != nil, format != .json {
            return .failure(.invalidCombination("--sections requires --json output."))
        }
        if weekStartDay != nil, since != nil || until != nil || days != nil || sections != nil {
            return .failure(.invalidCombination("--start-of-week cannot be combined with --since, --until, --days, or --sections."))
        }
        if instances, format != .json {
            return .failure(.invalidCombination("--instances requires --json output."))
        }
        if instances, project != nil {
            return .failure(.invalidCombination("--instances cannot be combined with --project."))
        }
        return .success(.export(format: format, period: period, outputPath: outputPath, includesCapacity: includesCapacity, since: since, until: until, days: days, includesCost: includesCost, timeZone: timeZone, project: project, weekStartDay: weekStartDay, sections: sections, instances: instances, provider: provider))
    }

    private static func parseStats(_ flags: [String]) -> Result<TokenPilotCLICommand, TokenPilotCLIError> {
        var period = HistoryPeriod.last7Days
        var since: Date?
        var until: Date?
        var days: Int?
        var includesCost = true
        var timeZone: TimeZone?
        var includesBreakdown = false
        var project: String?
        var provider: Provider?
        var model: String?
        var includesJSON = false
        var weekStartDay: WeekStartDay?
        var sections: [HistoryPeriod]?
        var instances = false
        var includesCSV = false
        var includesMarkdown = false
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
            case "--since":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                since = parsed
            case "--until":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseDay(flags[index]) else {
                    return .failure(.invalidDate(flags[index]))
                }
                until = parsed
            case "--days":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Int(flags[index]), parsed > 0 else {
                    return .failure(.invalidDays(flags[index]))
                }
                days = parsed
            case "--timezone":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = TimeZone(identifier: flags[index]) else {
                    return .failure(.invalidTimezone(flags[index]))
                }
                timeZone = parsed
            case "--project":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                project = flags[index]
            case "--provider":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = Provider(rawValue: flags[index]) else {
                    return .failure(.invalidProvider(flags[index]))
                }
                provider = parsed
            case "--model":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                model = flags[index]
            case "--start-of-week":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                guard let parsed = parseWeekStartDay(flags[index]) else {
                    return .failure(.invalidWeekStartDay(flags[index]))
                }
                weekStartDay = parsed
            case "--sections":
                guard index + 1 < flags.count else { return .failure(.missingValue(forFlag: flag)) }
                index += 1
                let names = flags[index].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let parsed = names.map { HistoryPeriod(rawValue: $0) }
                guard !parsed.contains(nil) else {
                    let invalid = names.enumerated().first { parsed[$0.offset] == nil }?.element ?? flags[index]
                    return .failure(.invalidPeriod(invalid))
                }
                sections = parsed.compactMap { $0 }
            case "--no-cost":
                includesCost = false
            case "--breakdown":
                includesBreakdown = true
            case "--instances":
                instances = true
            case "--json":
                includesJSON = true
            case "--csv":
                includesCSV = true
            case "--md":
                includesMarkdown = true
            default:
                return .failure(.unknownCommand(flag))
            }
            index += 1
        }
        if weekStartDay != nil, since != nil || until != nil || days != nil {
            return .failure(.invalidCombination("--start-of-week cannot be combined with --since, --until, or --days."))
        }
        if sections != nil, since != nil || until != nil || days != nil {
            return .failure(.invalidCombination("--sections cannot be combined with --since, --until, or --days."))
        }
        if sections != nil, !includesJSON {
            return .failure(.invalidCombination("--sections requires --json output."))
        }
        if instances, !includesJSON {
            return .failure(.invalidCombination("--instances requires --json output."))
        }
        if instances, project != nil {
            return .failure(.invalidCombination("--instances cannot be combined with --project."))
        }
        if includesCSV, includesJSON {
            return .failure(.invalidCombination("--csv cannot be combined with --json."))
        }
        if includesMarkdown, includesJSON || includesCSV {
            return .failure(.invalidCombination("--md cannot be combined with --json or --csv."))
        }
        return .success(.stats(period: period, since: since, until: until, days: days, includesCost: includesCost, timeZone: timeZone, includesBreakdown: includesBreakdown, project: project, includesJSON: includesJSON, weekStartDay: weekStartDay, sections: sections, instances: instances, includesCSV: includesCSV, includesMarkdown: includesMarkdown, provider: provider, model: model))
    }

    public static var helpText: String {
        """
        TokenPilot - local-first AI usage monitor

        Usage:
          TokenPilot export [--format json|csv] [--period today|last7Days|thisMonth] [--since yyyy-MM-dd] [--until yyyy-MM-dd] [--days N] [--timezone <zone>] [--project <label>] [--provider <name>] [--start-of-week monday|sunday|...] [--out <path>] [--capacity] [--no-cost] [--sections today,last7Days,thisMonth] [--instances]
          TokenPilot summary [--period today|last7Days|thisMonth] [--start-of-week monday|sunday|...] [--no-cost] [--breakdown] [--json|--csv|--md] [--sections today,last7Days,thisMonth] [--instances] [--provider <name>] [--model <name>]
          TokenPilot stats [--period today|last7Days|thisMonth] [--since yyyy-MM-dd] [--until yyyy-MM-dd] [--days N] [--timezone <zone>] [--project <label>] [--provider <name>] [--model <name>] [--start-of-week monday|sunday|...] [--no-cost] [--breakdown] [--json|--csv|--md] [--sections today,last7Days,thisMonth] [--instances]
          TokenPilot report [--period today|last7Days|thisMonth] [--since yyyy-MM-dd] [--until yyyy-MM-dd] [--days N] [--timezone <zone>] [--project <label>] [--provider <name>] [--start-of-week monday|sunday|...] [--svg|--md|--json|--csv] [--no-cost] [--breakdown] [--sections today,last7Days,thisMonth] [--instances]
          TokenPilot audit [--json|--csv|--md] [--sections today,last7Days,thisMonth] [--instances] [--provider <name>]
          TokenPilot blocks [--json|--csv|--md] [--active] [--recent] [--timezone <zone>] [--since yyyy-MM-dd] [--until yyyy-MM-dd] [--days N]
          TokenPilot help

        export writes locally stored usage events as JSON (default) or CSV to stdout, or to <path>
        with --out. --capacity appends the latest stored capacity evidence per series.
        --sections (JSON only) emits one export payload per requested period in an envelope with a
        totals object last (ccusage --sections style), and --instances (JSON only) groups exports by
        workspace label with each project carrying its own payload (ccusage --instances style);
        --provider restricts the export to one provider (ccusage --provider style). summary
        prints local usage totals for the selected period (default today); --period selects
        today/last7Days/thisMonth, --since/--until/--days/--timezone/--project narrow the
        window like export, --provider restricts the summary to one provider (ccusage --provider style),
        --model restricts it to one model name (ccusage --model style),
        --start-of-week aligns last7Days/thisMonth to a week start,
        --no-cost omits estimated cost, --breakdown adds a per-day, per-model
        breakdown section (ccusage --breakdown style), --json emits the same summary as structured JSON for
        scripting (toktrack stats --json style), --csv emits the same summary as machine-readable
        rows for spreadsheets (toktrack stats --csv style), --md emits the same summary as a Markdown
        document for notes and PR descriptions (ccusage --markdown style), --sections (JSON only) emits summaries for
        several periods in one envelope, and --instances (JSON only) groups summaries by workspace
        label with each project carrying its own payload (ccusage --instances style). stats prints derived usage statistics for the window:
        active days, daily average, busiest day and hour, and most-used provider; --provider restricts
        the statistics to one provider (ccusage --provider style), --model restricts them to one model
        name (ccusage --model style), --json emits
        the same statistics as structured JSON for scripting (toktrack stats --json style) with a
        per-provider model breakdown (ccusage --by-agent style), --csv emits the same statistics as
        machine-readable rows for spreadsheets (toktrack stats --csv style), --md emits the same statistics as a Markdown
        document for notes and PR descriptions (ccusage --markdown style), --breakdown adds a per-day, per-model
        breakdown section (ccusage --breakdown style), --sections (JSON only) emits stats for several
        periods in one envelope, and --instances (JSON only) groups stats by workspace label with each
        project carrying its own payload (ccusage --instances style). report prints a
        shareable usage receipt with a
        per-day breakdown and cache efficiency; --svg emits the same receipt as a standalone
        SVG, --md emits a copy-pasteable Markdown table, --json emits the same receipt as a
        structured JSON payload for scripting (ccusage --json style), and --csv emits the same receipt
        as machine-readable rows for spreadsheets (ccusage --csv style), --provider restricts the receipt
        to one provider (ccusage --provider style). --breakdown adds a per-day, per-model
        breakdown section (ccusage --breakdown style). --sections (JSON only) emits the requested
        periods in one envelope with a totals object last (ccusage --sections style).
        --instances (JSON only) groups the payload by workspace label with each project carrying
        its own report alongside the combined row (ccusage --instances style); it combines with
        --sections so every period carries its own project grouping.
        --since/--until slice the window to
        explicit dates (yyyy-MM-dd) and --days N covers the last N days including today; both
        override --period. --start-of-week aligns the window start to the most recent matching
        weekday (monday, sunday, ...) instead of the system default, matching ccusage's
        --start-of-week option. --timezone groups dates by an IANA timezone (for example UTC or
        Asia/Seoul) instead of the system timezone. --project restricts the report/export to one
        workspace label (ccusage --project style; opencode workspace folder names today).
        --no-cost omits estimated cost from
        reports and blanks cost fields in exports. audit reports local history coverage so you can
        spot gaps left by providers that prune their own logs; --since/--until/--days/--timezone/--project
        scope the audited window and events, --provider restricts the audit to one provider (ccusage --provider style),
        --json emits the same coverage
        summary as structured JSON for scripting (toktrack audit --json style), --csv emits the same
        coverage as per-day rows for spreadsheets (toktrack audit --csv style), --md emits the same coverage as a Markdown
        document for notes and PR descriptions (ccusage --markdown style), and --sections (JSON only)
        emits coverage for several periods in one envelope; --instances (JSON only) groups coverage per
        project label (ccusage --instances style). blocks lists the
        current limit-window blocks (provider, window, used/remaining percent, reset time) from
        stored capacity evidence, mirroring ccusage's blocks command; --active keeps only blocks
        whose reset has not elapsed, --recent keeps only freshly observed blocks, --timezone
        localizes the reset times, and --since/--until/--days scope the observations. --json emits them as
        structured JSON, and --csv emits the same blocks as rows for spreadsheets, and --md emits them
        as a Markdown document for notes and PR descriptions. Exports, reports,
        and audits never
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
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let scopedEvents = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics

        var lines: [String] = []
        lines.append("TokenPilot")
        lines.append("\(localized("Period", language: language)): \(periodLabel(period, since: since, until: until, days: days, language: language, now: now, calendar: calendar))")
        lines.append("\(localized("Total tokens", language: language)): \(TokenPilotFormatters.compactNumber(metrics.totalTokens))")
        lines.append("\(localized("Requests", language: language)): \(TokenPilotFormatters.compactNumber(metrics.requestCount))")
        if includesCost && metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            lines.append("\(localized("Estimated cost", language: language)): \(String(format: "$%.2f", amount))")
        }
        for share in usage.providerShare where share.tokens > 0 {
            lines.append(providerShareLine(share, language: language, includesCost: includesCost))
        }
        if includesBreakdown {
            let breakdownLines = dailyModelBreakdownLines(events: scopedEvents.filter { enabledSet.contains($0.provider) }, period: period, since: since, until: until, days: days, now: now, calendar: calendar, includesCost: includesCost)
            if !breakdownLines.isEmpty {
                lines.append(localized("Daily breakdown", language: language))
                lines.append(contentsOf: breakdownLines)
            }
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

    /// Machine-readable compact summary CSV (toktrack `stats --csv` style).
    ///
    /// Emits the same aggregates as `summaryText` — period, totals, cost — as a
    /// single summary row plus one row per provider share, mirroring the export
    /// CSV column convention (`cost_usd`).
    public static func summaryCSVText(
        events: [UsageEvent],
        snapshots: [ProviderSnapshot] = [],
        enabledProviders: [Provider],
        period: HistoryPeriod = .today,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        project: String? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let scopedEvents = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodLabel = periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar)

        var lines: [String] = ["period,tokens,requests,cost_usd"]
        lines.append(csvRow(date: periodLabel, tokens: metrics.totalTokens, requests: metrics.requestCount, cost: includesCost ? metrics.estimatedCostUSD : 0))
        for share in usage.providerShare where share.tokens > 0 {
            lines.append(csvRow(date: localized(share.provider.displayName, language: .en), tokens: share.tokens, requests: share.requestCount, cost: includesCost ? (share.estimatedCostUSD ?? 0) : 0))
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown compact summary (ccusage `--markdown` style).
    ///
    /// Emits the same aggregates as `summaryText` — period, totals, cost,
    /// provider share, and capacity remaining per provider — as a Markdown
    /// document for notes and PR descriptions.
    public static func summaryMarkdownText(
        events: [UsageEvent],
        snapshots: [ProviderSnapshot] = [],
        enabledProviders: [Provider],
        period: HistoryPeriod = .today,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let scopedEvents = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics

        var lines: [String] = []
        lines.append("## TokenPilot · Summary")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|---|---|")
        lines.append("| Period | \(periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar)) |")
        lines.append("| Total tokens | \(TokenPilotFormatters.compactNumber(metrics.totalTokens)) |")
        lines.append("| Requests | \(TokenPilotFormatters.compactNumber(metrics.requestCount)) |")
        if includesCost && metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            lines.append("| Estimated cost | $\(String(format: "%.2f", amount)) |")
        }
        let shares = usage.providerShare.filter { $0.tokens > 0 }
        if !shares.isEmpty {
            lines.append("")
            lines.append("**Providers**")
            lines.append("")
            if includesCost {
                lines.append("| Provider | Tokens | Requests | Cost |")
                lines.append("|---|---|---|---|")
                for share in shares {
                    let cost = share.estimatedCostUSD.map { TokenPilotFormatters.cost($0) } ?? "—"
                    lines.append("| \(localized(share.provider.displayName, language: .en)) | \(TokenPilotFormatters.compactNumber(share.tokens)) | \(share.requestCount) | \(cost) |")
                }
            } else {
                lines.append("| Provider | Tokens | Requests |")
                lines.append("|---|---|---|")
                for share in shares {
                    lines.append("| \(localized(share.provider.displayName, language: .en)) | \(TokenPilotFormatters.compactNumber(share.tokens)) | \(share.requestCount) |")
                }
            }
        }
        if includesBreakdown {
            let breakdownLines = dailyModelBreakdownLines(
                events: scopedEvents.filter { enabledSet.contains($0.provider) },
                period: period,
                since: since,
                until: until,
                days: days,
                now: now,
                calendar: calendar,
                includesCost: includesCost
            )
            if !breakdownLines.isEmpty {
                lines.append("")
                lines.append("**Breakdown**")
                lines.append("")
                lines.append("```")
                lines.append(contentsOf: breakdownLines)
                lines.append("```")
            }
        }
        let menuBarService = MenuBarStatusService()
        let remainingLines = snapshots.compactMap { snapshot -> String? in
            guard enabledSet.contains(snapshot.provider),
                  let window = menuBarService.displayWindow(for: snapshot),
                  let remaining = window.remainingPercent else {
                return nil
            }
            return "| \(localized(snapshot.provider.displayName, language: .en)) | \(remaining)% |"
        }
        if !remainingLines.isEmpty {
            lines.append("")
            lines.append("**Remaining capacity**")
            lines.append("")
            lines.append("| Provider | Remaining |")
            lines.append("|---|---|")
            lines.append(contentsOf: remainingLines)
        }
        lines.append("")
        lines.append("_Local activity, not provider quota._")
        return lines.joined(separator: "\n")
    }

    /// Machine-readable compact summary payload (toktrack `stats --json` style).
    ///
    /// Emits the same aggregates as `summaryText` — period, totals, cost, provider
    /// share, and capacity remaining per provider — as structured JSON.
    public static func summaryJSON(
        events: [UsageEvent],
        snapshots: [ProviderSnapshot] = [],
        enabledProviders: [Provider],
        period: HistoryPeriod = .today,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        sections: [HistoryPeriod]? = nil,
        instances: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let sections {
            // ccusage `--sections` style: each requested period emitted in one envelope
            // with a totals object last, matching the report/stats/export envelopes.
            let sectionPayloads = sections.map { section in
                var payload = summaryPayload(
                    events: events,
                    snapshots: snapshots,
                    enabledProviders: enabledProviders,
                    period: section,
                    since: nil,
                    until: nil,
                    days: nil,
                    includesCost: includesCost,
                    includesBreakdown: includesBreakdown,
                    project: project,
                    provider: provider,
                    model: model,
                    now: now,
                    calendar: calendar
                )
                if instances {
                    // ccusage `--instances` style: each project carries its own payload.
                    payload.projects = summaryProjectGroups(
                        events: events,
                        snapshots: snapshots,
                        enabledProviders: enabledProviders,
                        period: section,
                        since: nil,
                        until: nil,
                        days: nil,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        provider: provider,
                        model: model,
                        now: now,
                        calendar: calendar
                    )
                }
                return payload
            }
            let envelope = SummarySectionsEnvelopeJSON(
                generatedAt: now,
                sections: sectionPayloads,
                totals: SummaryTotalsJSON(
                    totalTokens: sectionPayloads.reduce(0) { $0 + $1.totalTokens },
                    requestCount: sectionPayloads.reduce(0) { $0 + $1.requestCount },
                    estimatedCostUSD: includesCost
                        ? sectionPayloads.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)
                        : nil
                )
            )
            return try encoder.encode(envelope)
        }
        var payload = summaryPayload(
            events: events,
            snapshots: snapshots,
            enabledProviders: enabledProviders,
            period: period,
            since: since,
            until: until,
            days: days,
            includesCost: includesCost,
            includesBreakdown: includesBreakdown,
            project: project,
            provider: provider,
            model: model,
            now: now,
            calendar: calendar
        )
        if instances {
            // ccusage `--instances` style: group usage by project label, with each
            // project carrying its own full payload alongside the combined row.
            payload.projects = summaryProjectGroups(
                events: events,
                snapshots: snapshots,
                enabledProviders: enabledProviders,
                period: period,
                since: since,
                until: until,
                days: days,
                includesCost: includesCost,
                includesBreakdown: includesBreakdown,
                provider: provider,
                model: model,
                now: now,
                calendar: calendar
            )
        }
        return try encoder.encode(payload)
    }

    private static func summaryProjectGroups(
        events: [UsageEvent],
        snapshots: [ProviderSnapshot] = [],
        enabledProviders: [Provider],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        includesCost: Bool,
        includesBreakdown: Bool,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date,
        calendar: Calendar
    ) -> [SummaryProjectGroup] {
        let labels = Set(events.compactMap(\.projectLabel)).sorted()
        return labels.map { label in
            SummaryProjectGroup(
                project: label,
                payload: summaryPayload(
                    events: events,
                    snapshots: snapshots,
                    enabledProviders: enabledProviders,
                    period: period,
                    since: since,
                    until: until,
                    days: days,
                    includesCost: includesCost,
                    includesBreakdown: includesBreakdown,
                    project: label,
                    provider: provider,
                    model: model,
                    now: now,
                    calendar: calendar
                )
            )
        }
    }

    private static func summaryPayload(
        events: [UsageEvent],
        snapshots: [ProviderSnapshot] = [],
        enabledProviders: [Provider],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        includesCost: Bool,
        includesBreakdown: Bool,
        project: String?,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date,
        calendar: Calendar
    ) -> SummaryPayloadJSON {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let scopedEvents = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
        }
        let dayGroups = Dictionary(grouping: periodEvents) { calendar.startOfDay(for: $0.timestamp) }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "MM-dd"
        let dailyModelBreakdown: [ReportModelRow]?
        if includesBreakdown {
            dailyModelBreakdown = dayGroups.keys.sorted().map { day -> ReportModelRow in
                let dayEvents = dayGroups[day] ?? []
                let byModel = Dictionary(grouping: dayEvents) { event in
                    event.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                }
                let models = byModel.keys.sorted { lhs, rhs in
                    let lhsTokens = byModel[lhs]?.reduce(0) { $0 + $1.totalTokens } ?? 0
                    let rhsTokens = byModel[rhs]?.reduce(0) { $0 + $1.totalTokens } ?? 0
                    if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
                    return lhs < rhs
                }.map { model -> ReportModelEntry in
                    let modelEvents = byModel[model] ?? []
                    let cost = includesCost ? modelEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +) : nil
                    return ReportModelEntry(
                        model: model,
                        tokens: modelEvents.reduce(0) { $0 + $1.totalTokens },
                        estimatedCostUSD: cost
                    )
                }
                return ReportModelRow(date: dayFormatter.string(from: day), models: models)
            }
        } else {
            dailyModelBreakdown = nil
        }

        let menuBarService = MenuBarStatusService()
        let remainingCapacity = snapshots
            .filter { enabledSet.contains($0.provider) }
            .compactMap { snapshot -> SummaryRemainingJSON? in
                guard let window = menuBarService.displayWindow(for: snapshot),
                      let remaining = window.remainingPercent else {
                    return nil
                }
                return SummaryRemainingJSON(
                    provider: localized(snapshot.provider.displayName, language: .en),
                    window: windowLabel(window.kind, language: .en),
                    remainingPercent: remaining
                )
            }

        return SummaryPayloadJSON(
            generatedAt: now,
            period: periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar),
            totalTokens: metrics.totalTokens,
            requestCount: metrics.requestCount,
            estimatedCostUSD: includesCost && metrics.estimatedCostUSD > 0 ? metrics.estimatedCostUSD : nil,
            providerShare: usage.providerShare.filter { $0.tokens > 0 }.map { share in
                SummaryProviderShareJSON(
                    provider: localized(share.provider.displayName, language: .en),
                    tokens: share.tokens,
                    percent: share.percent,
                    requestCount: share.requestCount,
                    estimatedCostUSD: includesCost ? share.estimatedCostUSD : nil
                )
            },
            remainingCapacity: remainingCapacity,
            dailyModelBreakdown: dailyModelBreakdown
        )
    }

    /// Derived usage statistics over the window (toktrack-stats style).
    ///
    /// Reports active days, daily average, busiest day and hour, and
    /// most-used provider in addition to the same aggregates as `summaryText`.
    /// Only aggregates reach the output; raw event fields never appear.
    public static func statsText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        language: TokenPilotLanguage,
        period: HistoryPeriod = .last7Days,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let scopedEvents = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
        }
        let activeDayStarts = Set(periodEvents.map { calendar.startOfDay(for: $0.timestamp) })
        let activeDays = activeDayStarts.count
        let spanDays = max(Int((window.endExclusive.timeIntervalSince(window.start) / 86_400).rounded()), 1)
        let dailyAverage = metrics.totalTokens / spanDays
        let dayGroups = Dictionary(grouping: periodEvents) { calendar.startOfDay(for: $0.timestamp) }
        let busiestDay = dayGroups.max { lhs, rhs in
            lhs.value.reduce(0) { $0 + $1.totalTokens } < rhs.value.reduce(0) { $0 + $1.totalTokens }
        }

        var lines: [String] = []
        lines.append("TokenPilot · \(localized("Stats", language: language))")
        lines.append("\(localized("Period", language: language)): \(periodLabel(period, since: since, until: until, days: days, language: language, now: now, calendar: calendar))")
        lines.append("\(localized("Total tokens", language: language)): \(TokenPilotFormatters.compactNumber(metrics.totalTokens))")
        lines.append("\(localized("Requests", language: language)): \(TokenPilotFormatters.compactNumber(metrics.requestCount))")
        if includesCost && metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            lines.append("\(localized("Estimated cost", language: language)): \(String(format: "$%.2f", amount))")
        }
        lines.append("\(localized("Active days", language: language)): \(activeDays)")
        lines.append("\(localized("Daily average", language: language)): \(TokenPilotFormatters.compactNumber(dailyAverage)) \(localized("tok", language: language))")
        if let busiestDay, !busiestDay.value.isEmpty {
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.calendar = calendar
            dayFormatter.dateFormat = "MM-dd"
            let dayTokens = busiestDay.value.reduce(0) { $0 + $1.totalTokens }
            lines.append("\(localized("Busiest day", language: language)): \(dayFormatter.string(from: busiestDay.key)) (\(TokenPilotFormatters.compactNumber(dayTokens)) \(localized("tok", language: language)))")
        }
        if let busiestHour = metrics.busiestHour {
            lines.append("\(localized("Busiest hour", language: language)): \(String(format: "%02d:00", busiestHour))")
        }
        if let mostUsedProvider = metrics.mostUsedProvider {
            lines.append("\(localized("Most used provider", language: language)): \(localized(mostUsedProvider.displayName, language: language))")
        }
        if includesBreakdown {
            let breakdownLines = dailyModelBreakdownLines(events: scopedEvents.filter { enabledSet.contains($0.provider) }, period: period, since: since, until: until, days: days, now: now, calendar: calendar, includesCost: includesCost)
            if !breakdownLines.isEmpty {
                lines.append(localized("Daily breakdown", language: language))
                lines.append(contentsOf: breakdownLines)
            }
        }
        lines.append(localized("Local activity, not provider quota", language: language))
        return lines.joined(separator: "\n")
    }

    /// Machine-readable stats CSV over the window (toktrack `stats --csv` style).
    ///
    /// Emits the same aggregates as `statsText` — period, totals, cost, provider
    /// share — as a single summary row plus one row per provider share, mirroring
    /// the export CSV column convention (`cost_usd`).
    public static func statsCSVText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod = .last7Days,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        project: String? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let scopedEvents = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodLabel = periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar)

        var lines: [String] = ["period,tokens,requests,cost_usd"]
        lines.append(csvRow(date: periodLabel, tokens: metrics.totalTokens, requests: metrics.requestCount, cost: includesCost ? metrics.estimatedCostUSD : 0))
        for share in usage.providerShare where share.tokens > 0 {
            lines.append(csvRow(date: localized(share.provider.displayName, language: .en), tokens: share.tokens, requests: share.requestCount, cost: includesCost ? (share.estimatedCostUSD ?? 0) : 0))
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown stats over the window (ccusage `--markdown` style).
    ///
    /// Emits the same derived statistics as `statsText` — period, totals, cost,
    /// active days, daily average, busiest day/hour, and most-used provider — as
    /// a Markdown document for notes and PR descriptions.
    public static func statsMarkdownText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod = .last7Days,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let scopedEvents = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
        }
        let activeDayStarts = Set(periodEvents.map { calendar.startOfDay(for: $0.timestamp) })
        let activeDays = activeDayStarts.count
        let spanDays = max(Int((window.endExclusive.timeIntervalSince(window.start) / 86_400).rounded()), 1)
        let dailyAverage = metrics.totalTokens / spanDays
        let dayGroups = Dictionary(grouping: periodEvents) { calendar.startOfDay(for: $0.timestamp) }
        let busiestDay = dayGroups.max { lhs, rhs in
            lhs.value.reduce(0) { $0 + $1.totalTokens } < rhs.value.reduce(0) { $0 + $1.totalTokens }
        }

        var lines: [String] = []
        lines.append("## TokenPilot · Stats")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|---|---|")
        lines.append("| Period | \(periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar)) |")
        lines.append("| Total tokens | \(TokenPilotFormatters.compactNumber(metrics.totalTokens)) |")
        lines.append("| Requests | \(TokenPilotFormatters.compactNumber(metrics.requestCount)) |")
        if includesCost && metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            lines.append("| Estimated cost | $\(String(format: "%.2f", amount)) |")
        }
        lines.append("| Active days | \(activeDays) |")
        lines.append("| Daily average | \(TokenPilotFormatters.compactNumber(dailyAverage)) tok |")
        if let busiestDay, !busiestDay.value.isEmpty {
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.calendar = calendar
            dayFormatter.dateFormat = "MM-dd"
            let dayTokens = busiestDay.value.reduce(0) { $0 + $1.totalTokens }
            lines.append("| Busiest day | \(dayFormatter.string(from: busiestDay.key)) (\(TokenPilotFormatters.compactNumber(dayTokens)) tok) |")
        }
        if let busiestHour = metrics.busiestHour {
            lines.append("| Busiest hour | \(String(format: "%02d:00", busiestHour)) |")
        }
        if let mostUsedProvider = metrics.mostUsedProvider {
            lines.append("| Most used provider | \(localized(mostUsedProvider.displayName, language: .en)) |")
        }
        let shares = usage.providerShare.filter { $0.tokens > 0 }
        if !shares.isEmpty {
            lines.append("")
            lines.append("**Providers**")
            lines.append("")
            if includesCost {
                lines.append("| Provider | Tokens | Requests | Cost |")
                lines.append("|---|---|---|---|")
                for share in shares {
                    let cost = share.estimatedCostUSD.map { TokenPilotFormatters.cost($0) } ?? "—"
                    lines.append("| \(localized(share.provider.displayName, language: .en)) | \(TokenPilotFormatters.compactNumber(share.tokens)) | \(share.requestCount) | \(cost) |")
                }
            } else {
                lines.append("| Provider | Tokens | Requests |")
                lines.append("|---|---|---|")
                for share in shares {
                    lines.append("| \(localized(share.provider.displayName, language: .en)) | \(TokenPilotFormatters.compactNumber(share.tokens)) | \(share.requestCount) |")
                }
            }
        }
        if includesBreakdown {
            let breakdownLines = dailyModelBreakdownLines(
                events: scopedEvents.filter { enabledSet.contains($0.provider) },
                period: period,
                since: since,
                until: until,
                days: days,
                now: now,
                calendar: calendar,
                includesCost: includesCost
            )
            if !breakdownLines.isEmpty {
                lines.append("")
                lines.append("**Breakdown**")
                lines.append("")
                lines.append("```")
                lines.append(contentsOf: breakdownLines)
                lines.append("```")
            }
        }
        lines.append("")
        lines.append("_Local activity, not provider quota._")
        return lines.joined(separator: "\n")
    }

    /// Machine-readable stats payload over the window (toktrack `stats --json` style).
    ///
    /// Emits the same derived statistics as `statsText` as structured JSON so
    /// scripts can consume active days, daily average, busiest day/hour, and
    /// most-used provider. Cost is omitted when `includesCost` is false.
    public static func statsJSON(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod = .last7Days,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        sections: [HistoryPeriod]? = nil,
        instances: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let sections {
            // ccusage `--sections` style: each requested period emitted in one envelope
            // with a totals object last, matching the report JSON envelope.
            let sectionPayloads = sections.map { section in
                var payload = statsPayload(
                    events: events,
                    enabledProviders: enabledProviders,
                    period: section,
                    since: nil,
                    until: nil,
                    days: nil,
                    includesCost: includesCost,
                    includesBreakdown: includesBreakdown,
                    project: project,
                    provider: provider,
                    model: model,
                    now: now,
                    calendar: calendar
                )
                if instances {
                    // ccusage `--instances` style: each project carries its own payload.
                    payload.projects = statsProjectGroups(
                        events: events,
                        enabledProviders: enabledProviders,
                        period: section,
                        since: nil,
                        until: nil,
                        days: nil,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        provider: provider,
                        model: model,
                        now: now,
                        calendar: calendar
                    )
                }
                return payload
            }
            let envelope = StatsSectionsEnvelopeJSON(
                generatedAt: now,
                sections: sectionPayloads,
                totals: StatsTotalsJSON(
                    totalTokens: sectionPayloads.reduce(0) { $0 + $1.totalTokens },
                    requestCount: sectionPayloads.reduce(0) { $0 + $1.requestCount },
                    estimatedCostUSD: includesCost
                        ? sectionPayloads.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)
                        : nil
                )
            )
            return try encoder.encode(envelope)
        }
        var payload = statsPayload(
            events: events,
            enabledProviders: enabledProviders,
            period: period,
            since: since,
            until: until,
            days: days,
            includesCost: includesCost,
            includesBreakdown: includesBreakdown,
            project: project,
            provider: provider,
            model: model,
            now: now,
            calendar: calendar
        )
        if instances {
            // ccusage `--instances` style: group usage by project label, with each
            // project carrying its own full payload alongside the combined row.
            payload.projects = statsProjectGroups(
                events: events,
                enabledProviders: enabledProviders,
                period: period,
                since: since,
                until: until,
                days: days,
                includesCost: includesCost,
                includesBreakdown: includesBreakdown,
                provider: provider,
                model: model,
                now: now,
                calendar: calendar
            )
        }
        return try encoder.encode(payload)
    }

    private static func statsProjectGroups(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        includesCost: Bool,
        includesBreakdown: Bool,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date,
        calendar: Calendar
    ) -> [StatsProjectGroup] {
        let labels = Set(events.compactMap(\.projectLabel)).sorted()
        return labels.map { label in
            StatsProjectGroup(
                project: label,
                payload: statsPayload(
                    events: events,
                    enabledProviders: enabledProviders,
                    period: period,
                    since: since,
                    until: until,
                    days: days,
                    includesCost: includesCost,
                    includesBreakdown: includesBreakdown,
                    project: label,
                    provider: provider,
                    model: model,
                    now: now,
                    calendar: calendar
                )
            )
        }
    }

    private static func statsPayload(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        includesCost: Bool,
        includesBreakdown: Bool,
        project: String?,
        provider: Provider? = nil,
        model: String? = nil,
        now: Date,
        calendar: Calendar
    ) -> StatsPayloadJSON {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let scopedEvents = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
        }
        let activeDayStarts = Set(periodEvents.map { calendar.startOfDay(for: $0.timestamp) })
        let activeDays = activeDayStarts.count
        let spanDays = max(Int((window.endExclusive.timeIntervalSince(window.start) / 86_400).rounded()), 1)
        let dailyAverage = metrics.totalTokens / spanDays
        let dayGroups = Dictionary(grouping: periodEvents) { calendar.startOfDay(for: $0.timestamp) }
        let busiestDay = dayGroups.max { lhs, rhs in
            lhs.value.reduce(0) { $0 + $1.totalTokens } < rhs.value.reduce(0) { $0 + $1.totalTokens }
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "MM-dd"
        let dailyModelBreakdown: [ReportModelRow]?
        if includesBreakdown {
            dailyModelBreakdown = dayGroups.keys.sorted().map { day -> ReportModelRow in
                let dayEvents = dayGroups[day] ?? []
                let byModel = Dictionary(grouping: dayEvents) { event in
                    event.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                }
                let models = byModel.keys.sorted { lhs, rhs in
                    let lhsTokens = byModel[lhs]?.reduce(0) { $0 + $1.totalTokens } ?? 0
                    let rhsTokens = byModel[rhs]?.reduce(0) { $0 + $1.totalTokens } ?? 0
                    if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
                    return lhs < rhs
                }.map { model -> ReportModelEntry in
                    let modelEvents = byModel[model] ?? []
                    let cost = includesCost ? modelEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +) : nil
                    return ReportModelEntry(
                        model: model,
                        tokens: modelEvents.reduce(0) { $0 + $1.totalTokens },
                        estimatedCostUSD: cost
                    )
                }
                return ReportModelRow(date: dayFormatter.string(from: day), models: models)
            }
        } else {
            dailyModelBreakdown = nil
        }
        let modelSharesByProvider = Dictionary(grouping: usage.modelBreakdown.filter { $0.tokens > 0 }) { $0.provider }
        let providers = enabledSet.compactMap { provider -> StatsProviderBreakdownJSON? in
            let shares = modelSharesByProvider[provider] ?? []
            guard !shares.isEmpty else { return nil }
            let costs = shares.compactMap(\.estimatedCostUSD)
            return StatsProviderBreakdownJSON(
                provider: provider.displayName,
                tokens: shares.reduce(0) { $0 + $1.tokens },
                requestCount: shares.reduce(0) { $0 + $1.requestCount },
                estimatedCostUSD: includesCost && !costs.isEmpty ? costs.reduce(Decimal(0), +) : nil,
                models: shares.sorted { $0.tokens > $1.tokens }.map { share in
                    StatsModelEntryJSON(
                        model: share.model,
                        tokens: share.tokens,
                        estimatedCostUSD: includesCost ? share.estimatedCostUSD : nil
                    )
                }
            )
        }
        return StatsPayloadJSON(
            generatedAt: now,
            period: periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar),
            totalTokens: metrics.totalTokens,
            requestCount: metrics.requestCount,
            estimatedCostUSD: includesCost && metrics.estimatedCostUSD > 0 ? metrics.estimatedCostUSD : nil,
            activeDays: activeDays,
            dailyAverage: dailyAverage,
            busiestDay: busiestDay.flatMap { $0.value.isEmpty ? nil : dayFormatter.string(from: $0.key) },
            busiestHour: metrics.busiestHour,
            mostUsedProvider: metrics.mostUsedProvider?.displayName,
            dailyModelBreakdown: dailyModelBreakdown,
            providers: providers
        )
    }

    /// One provider share line, appending request count and recorded cost when present.
    private static func providerShareLine(_ share: ProviderShare, language: TokenPilotLanguage, includesCost: Bool = true) -> String {
        var line = "\(localized(share.provider.displayName, language: language)): " +
            "\(TokenPilotFormatters.compactNumber(share.tokens)) " +
            "\(localized("tok", language: language)) (\(share.percent)%)"
        if share.requestCount > 0 {
            line += " · \(TokenPilotFormatters.compactNumber(share.requestCount)) \(localized("req", language: language))"
        }
        if includesCost, let cost = share.estimatedCostUSD, cost > 0 {
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
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let scopedEvents = project.map { label in providerEvents.filter { $0.projectLabel == label } } ?? providerEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
        }
        let cache = CacheEfficiencyService.summary(events: periodEvents, now: now, calendar: calendar)

        var lines: [String] = []
        lines.append("TokenPilot · \(localized("Report", language: language))")
        lines.append("\(localized("Period", language: language)): \(periodLabel(period, since: since, until: until, days: days, language: language, now: now, calendar: calendar))")
        lines.append("\(localized("Total tokens", language: language)): \(TokenPilotFormatters.compactNumber(metrics.totalTokens))")
        lines.append("\(localized("Requests", language: language)): \(TokenPilotFormatters.compactNumber(metrics.requestCount))")
        if includesCost && metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            lines.append("\(localized("Estimated cost", language: language)): \(String(format: "$%.2f", amount))")
        }
        if cache.hasCacheActivity {
            let hitPercent = Int((cache.cacheHitRate * 100).rounded())
            lines.append("\(localized("Cache hit rate", language: language)): \(hitPercent)%")
        }
        for share in usage.providerShare where share.tokens > 0 {
            lines.append(providerShareLine(share, language: language, includesCost: includesCost))
        }
        let modelLines = modelRankingLines(usage.modelBreakdown, language: language, limit: 5, includesCost: includesCost)
        if !modelLines.isEmpty {
            lines.append(localized("Top models", language: language))
            lines.append(contentsOf: modelLines)
        }
        let projectLines = projectRankingLines(usage.projectBreakdown, language: language, limit: 5, includesCost: includesCost)
        if !projectLines.isEmpty {
            lines.append(localized("Top projects", language: language))
            lines.append(contentsOf: projectLines)
        }
        let dailyLines = dailyBreakdownLines(events: scopedEvents.filter { enabledSet.contains($0.provider) }, period: period, since: since, until: until, days: days, now: now, calendar: calendar, includesCost: includesCost)
        if !dailyLines.isEmpty {
            lines.append(localized("Daily breakdown", language: language))
            lines.append(contentsOf: dailyLines)
        }
        if includesBreakdown {
            let breakdownLines = dailyModelBreakdownLines(events: scopedEvents.filter { enabledSet.contains($0.provider) }, period: period, since: since, until: until, days: days, now: now, calendar: calendar, includesCost: includesCost)
            if !breakdownLines.isEmpty {
                lines.append(localized("Breakdown", language: language))
                lines.append(contentsOf: breakdownLines)
            }
        }
        lines.append(localized("Local activity, not provider quota", language: language))
        return lines.joined(separator: "\n")
    }

    /// Machine-readable CSV receipt over stored local activity (ccusage `report --csv` style).
    ///
    /// Emits one row per active day (date, tokens, requests, cost) followed by a
    /// totals row, mirroring the export CSV column convention (`cost_usd`).
    public static func reportCSVText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod = .last7Days,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        project: String? = nil,
        provider: Provider? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let scopedEvents = project.map { label in providerEvents.filter { $0.projectLabel == label } } ?? providerEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayGroups = Dictionary(grouping: periodEvents) { calendar.startOfDay(for: $0.timestamp) }

        var lines: [String] = ["date,tokens,requests,cost_usd"]
        for day in dayGroups.keys.sorted() {
            let dayEvents = dayGroups[day] ?? []
            let tokens = dayEvents.reduce(0) { $0 + $1.totalTokens }
            let requestCount = dayEvents.reduce(0) { $0 + $1.requestCount }
            let cost = includesCost ? dayEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +) : 0
            lines.append(csvRow(date: dayFormatter.string(from: day), tokens: tokens, requests: requestCount, cost: cost))
        }
        lines.append(csvRow(date: "total", tokens: metrics.totalTokens, requests: metrics.requestCount, cost: includesCost ? metrics.estimatedCostUSD : 0))
        return lines.joined(separator: "\n")
    }

    /// One CSV data row with the shared column convention.
    private static func csvRow(date: String, tokens: Int, requests: Int, cost: Decimal) -> String {
        let costString = cost > 0 ? NSDecimalNumber(decimal: cost).stringValue : ""
        return "\(csvEscape(date)),\(tokens),\(requests),\(costString)"
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
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
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let scopedEvents = project.map { label in providerEvents.filter { $0.projectLabel == label } } ?? providerEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
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
        addText("Period: \(periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar))", size: 13)
        addText("Total tokens: \(TokenPilotFormatters.compactNumber(metrics.totalTokens))", size: 13)
        addText("Requests: \(TokenPilotFormatters.compactNumber(metrics.requestCount))", size: 13)
        if includesCost && metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            addText("Estimated cost: $\(String(format: "%.2f", amount))", size: 13)
        }
        if cache.hasCacheActivity {
            let hitPercent = Int((cache.cacheHitRate * 100).rounded())
            addText("Cache hit rate: \(hitPercent)%", size: 13)
        }
        for share in usage.providerShare where share.tokens > 0 {
            addText(
                providerShareLine(share, language: .en, includesCost: includesCost),
                size: 13,
                fill: "#a5c8ff"
            )
        }
        let modelLines = modelRankingLines(usage.modelBreakdown, language: .en, limit: 5, includesCost: includesCost)
        if !modelLines.isEmpty {
            addText("Top models", size: 14, weight: "bold", fill: "#ffffff")
            for line in modelLines {
                addText(line, size: 12, fill: "#9b9b9b")
            }
        }
        let projectLines = projectRankingLines(usage.projectBreakdown, language: .en, limit: 5, includesCost: includesCost)
        if !projectLines.isEmpty {
            addText("Top projects", size: 14, weight: "bold", fill: "#ffffff")
            for line in projectLines {
                addText(line, size: 12, fill: "#9b9b9b")
            }
        }
        let dailyLines = dailyBreakdownLines(
            events: scopedEvents.filter { enabledSet.contains($0.provider) },
            period: period,
            since: since,
            until: until,
            days: days,
            now: now,
            calendar: calendar,
            includesCost: includesCost
        )
        if !dailyLines.isEmpty {
            addText("Daily breakdown", size: 14, weight: "bold", fill: "#ffffff")
            for line in dailyLines {
                addText(line, size: 12, fill: "#9b9b9b")
            }
        }
        if includesBreakdown {
            let breakdownLines = dailyModelBreakdownLines(
                events: scopedEvents.filter { enabledSet.contains($0.provider) },
                period: period,
                since: since,
                until: until,
                days: days,
                now: now,
                calendar: calendar,
                includesCost: includesCost
            )
            if !breakdownLines.isEmpty {
                addText("Breakdown", size: 14, weight: "bold", fill: "#ffffff")
                for line in breakdownLines {
                    addText(line, size: 12, fill: "#9b9b9b")
                }
            }
        }
        addText("Local activity, not provider quota", size: 11, fill: "#666666")
        lines.append("</svg>")
        return lines.joined(separator: "\n")
    }

    /// Copy-pasteable Markdown summary over stored local activity (CodeBurn-style).
    ///
    /// Emits a compact markdown table of totals, top models, and provider
    /// shares so the receipt can be pasted into a PR, doc, or chat. Only
    /// aggregates reach the output; raw event fields never appear.
    public static func reportMarkdownText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod = .last7Days,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let scopedEvents = project.map { label in providerEvents.filter { $0.projectLabel == label } } ?? providerEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
        }
        let cache = CacheEfficiencyService.summary(events: periodEvents, now: now, calendar: calendar)

        var lines: [String] = []
        lines.append("## TokenPilot · Report")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|---|---|")
        lines.append("| Period | \(periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar)) |")
        lines.append("| Total tokens | \(TokenPilotFormatters.compactNumber(metrics.totalTokens)) |")
        lines.append("| Requests | \(TokenPilotFormatters.compactNumber(metrics.requestCount)) |")
        if includesCost && metrics.estimatedCostUSD > 0 {
            let amount = NSDecimalNumber(decimal: metrics.estimatedCostUSD).doubleValue
            lines.append("| Estimated cost | $\(String(format: "%.2f", amount)) |")
        }
        if cache.hasCacheActivity {
            let hitPercent = Int((cache.cacheHitRate * 100).rounded())
            lines.append("| Cache hit rate | \(hitPercent)% |")
        }
        let topModels = usage.modelBreakdown.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }.prefix(3)
        if !topModels.isEmpty {
            lines.append("")
            lines.append("**Top models**")
            lines.append("")
            if includesCost {
                lines.append("| Model | Tokens | Cost |")
                lines.append("|---|---|---|")
                for share in topModels {
                    let cost = share.estimatedCostUSD.map { TokenPilotFormatters.cost($0) } ?? "—"
                    lines.append("| \(share.model) | \(TokenPilotFormatters.compactNumber(share.tokens)) | \(cost) |")
                }
            } else {
                lines.append("| Model | Tokens |")
                lines.append("|---|---|")
                for share in topModels {
                    lines.append("| \(share.model) | \(TokenPilotFormatters.compactNumber(share.tokens)) |")
                }
            }
        }
        let shares = usage.providerShare.filter { $0.tokens > 0 }
        if !shares.isEmpty {
            lines.append("")
            lines.append("**Providers**")
            lines.append("")
            if includesCost {
                lines.append("| Provider | Tokens | Requests | Cost |")
                lines.append("|---|---|---|---|")
                for share in shares {
                    let cost = share.estimatedCostUSD.map { TokenPilotFormatters.cost($0) } ?? "—"
                    lines.append("| \(share.provider.displayName) | \(TokenPilotFormatters.compactNumber(share.tokens)) | \(share.requestCount) | \(cost) |")
                }
            } else {
                lines.append("| Provider | Tokens | Requests |")
                lines.append("|---|---|---|")
                for share in shares {
                    lines.append("| \(share.provider.displayName) | \(TokenPilotFormatters.compactNumber(share.tokens)) | \(share.requestCount) |")
                }
            }
        }
        if includesBreakdown {
            let breakdownLines = dailyModelBreakdownLines(
                events: scopedEvents.filter { enabledSet.contains($0.provider) },
                period: period,
                since: since,
                until: until,
                days: days,
                now: now,
                calendar: calendar,
                includesCost: includesCost
            )
            if !breakdownLines.isEmpty {
                lines.append("")
                lines.append("**Breakdown**")
                lines.append("")
                lines.append("```")
                lines.append(contentsOf: breakdownLines)
                lines.append("```")
            }
        }
        lines.append("")
        lines.append("_Local activity, not provider quota._")
        return lines.joined(separator: "\n")
    }

    /// Machine-readable JSON report over stored local activity (ccusage `--json` style).
    ///
    /// Mirrors the text/SVG/Markdown receipt as a structured payload: period,
    /// totals, cache hit rate, provider shares, top models, and daily breakdown,
    /// plus a per-day per-model breakdown when `includesBreakdown` is set. Cost
    /// fields are omitted when `includesCost` is false, matching `--json --no-cost`.
    public static func reportJSON(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod = .last7Days,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        includesCost: Bool = true,
        includesBreakdown: Bool = false,
        project: String? = nil,
        provider: Provider? = nil,
        sections: [HistoryPeriod]? = nil,
        instances: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let sections {
            // ccusage `--sections` style: each requested period emitted in one envelope,
            // with a totals object last so dashboards fetch all granularities in one call.
            let sectionPayloads = sections.map { section in
                var payload = reportPayload(
                    events: events,
                    enabledProviders: enabledProviders,
                    period: section,
                    since: nil,
                    until: nil,
                    days: nil,
                    includesCost: includesCost,
                    includesBreakdown: includesBreakdown,
                    project: project,
                    provider: provider,
                    now: now,
                    calendar: calendar
                )
                if instances {
                    payload.projects = projectGroups(
                        events: events,
                        enabledProviders: enabledProviders,
                        period: section,
                        since: nil,
                        until: nil,
                        days: nil,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        provider: provider,
                        now: now,
                        calendar: calendar
                    )
                }
                return payload
            }
            let envelope = ReportSectionsEnvelopeJSON(
                generatedAt: now,
                sections: sectionPayloads,
                totals: ReportTotalsJSON(
                    totalTokens: sectionPayloads.reduce(0) { $0 + $1.totalTokens },
                    requestCount: sectionPayloads.reduce(0) { $0 + $1.requestCount },
                    estimatedCostUSD: includesCost
                        ? sectionPayloads.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)
                        : nil
                )
            )
            return try encoder.encode(envelope)
        }
        let payload = reportPayload(
            events: events,
            enabledProviders: enabledProviders,
            period: period,
            since: since,
            until: until,
            days: days,
            includesCost: includesCost,
            includesBreakdown: includesBreakdown,
            project: project,
            provider: provider,
            now: now,
            calendar: calendar
        )
        if instances {
            // ccusage `--instances` style: group usage by project label, with each
            // project carrying its own full payload alongside the combined row.
            var enriched = payload
            enriched.projects = projectGroups(
                events: events,
                enabledProviders: enabledProviders,
                period: period,
                since: since,
                until: until,
                days: days,
                includesCost: includesCost,
                includesBreakdown: includesBreakdown,
                provider: provider,
                now: now,
                calendar: calendar
            )
            return try encoder.encode(enriched)
        }
        return try encoder.encode(payload)
    }

    /// Per-project group payloads for `--instances` (ccusage `--by-agent` style).
    private static func projectGroups(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        includesCost: Bool,
        includesBreakdown: Bool,
        provider: Provider? = nil,
        now: Date,
        calendar: Calendar
    ) -> [ReportProjectGroup] {
        let labels = Set(events.compactMap(\.projectLabel)).sorted()
        return labels.map { label in
            ReportProjectGroup(
                project: label,
                payload: reportPayload(
                    events: events,
                    enabledProviders: enabledProviders,
                    period: period,
                    since: since,
                    until: until,
                    days: days,
                    includesCost: includesCost,
                    includesBreakdown: includesBreakdown,
                    project: label,
                    provider: provider,
                    now: now,
                    calendar: calendar
                )
            )
        }
    }

    private static func reportPayload(
        events: [UsageEvent],
        enabledProviders: [Provider],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        includesCost: Bool,
        includesBreakdown: Bool,
        project: String?,
        provider: Provider? = nil,
        now: Date,
        calendar: Calendar
    ) -> TokenPilotReportJSON {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let enabledSet = Set(enabledProviders)
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let scopedEvents = project.map { label in providerEvents.filter { $0.projectLabel == label } } ?? providerEvents
        let providerSnapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: scopedEvents.filter { $0.provider == provider }
            )
        }
        let usage = AggregationService().aggregate(snapshots: providerSnapshots, period: period, customRange: range(from: window), now: now)
        let metrics = usage.metrics
        let periodEvents = scopedEvents.filter { event in
            enabledSet.contains(event.provider) && event.timestamp >= window.start && event.timestamp < window.endExclusive
        }
        let cache = CacheEfficiencyService.summary(events: periodEvents, now: now, calendar: calendar)

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "MM-dd"

        let dailyGroups = Dictionary(grouping: periodEvents) { calendar.startOfDay(for: $0.timestamp) }
        let dailyBreakdown = dailyGroups.keys.sorted().map { day -> ReportDailyRow in
            let dayEvents = dailyGroups[day] ?? []
            let cost = includesCost ? dayEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +) : nil
            return ReportDailyRow(
                date: dayFormatter.string(from: day),
                tokens: dayEvents.reduce(0) { $0 + $1.totalTokens },
                estimatedCostUSD: cost
            )
        }

        let modelBreakdown: [ReportModelRow]?
        if includesBreakdown {
            modelBreakdown = dailyGroups.keys.sorted().map { day -> ReportModelRow in
                let dayEvents = dailyGroups[day] ?? []
                let byModel = Dictionary(grouping: dayEvents) { event in
                    event.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                }
                let models = byModel.keys.sorted { lhs, rhs in
                    let lhsTokens = byModel[lhs]?.reduce(0) { $0 + $1.totalTokens } ?? 0
                    let rhsTokens = byModel[rhs]?.reduce(0) { $0 + $1.totalTokens } ?? 0
                    if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
                    return lhs < rhs
                }.map { model -> ReportModelEntry in
                    let modelEvents = byModel[model] ?? []
                    let cost = includesCost ? modelEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +) : nil
                    return ReportModelEntry(
                        model: model,
                        tokens: modelEvents.reduce(0) { $0 + $1.totalTokens },
                        estimatedCostUSD: cost
                    )
                }
                return ReportModelRow(date: dayFormatter.string(from: day), models: models)
            }
        } else {
            modelBreakdown = nil
        }

        // Per-provider model breakdown (ccusage `--by-agent` style): each provider lists
        // its models and per-provider totals sum exactly to the combined row.
        let modelSharesByProvider = Dictionary(grouping: usage.modelBreakdown.filter { $0.tokens > 0 }) { $0.provider }
        let providerBreakdown = enabledSet.compactMap { provider -> ReportProviderBreakdownRow? in
            let shares = modelSharesByProvider[provider] ?? []
            guard !shares.isEmpty else { return nil }
            let costs = shares.compactMap(\.estimatedCostUSD)
            return ReportProviderBreakdownRow(
                provider: provider.displayName,
                tokens: shares.reduce(0) { $0 + $1.tokens },
                requestCount: shares.reduce(0) { $0 + $1.requestCount },
                estimatedCostUSD: includesCost && !costs.isEmpty ? costs.reduce(Decimal(0), +) : nil,
                models: shares.sorted { $0.tokens > $1.tokens }.map { share in
                    ReportModelEntry(
                        model: share.model,
                        tokens: share.tokens,
                        estimatedCostUSD: includesCost ? share.estimatedCostUSD : nil
                    )
                }
            )
        }

        return TokenPilotReportJSON(
            generatedAt: now,
            period: periodLabel(period, since: since, until: until, days: days, language: .en, now: now, calendar: calendar),
            totalTokens: metrics.totalTokens,
            requestCount: metrics.requestCount,
            estimatedCostUSD: includesCost && metrics.estimatedCostUSD > 0 ? metrics.estimatedCostUSD : nil,
            cacheHitRate: cache.hasCacheActivity ? Int((cache.cacheHitRate * 100).rounded()) : nil,
            providerShare: usage.providerShare.filter { $0.tokens > 0 }.map { share in
                ReportProviderRow(
                    provider: share.provider.displayName,
                    tokens: share.tokens,
                    percent: share.percent,
                    requestCount: share.requestCount,
                    estimatedCostUSD: includesCost ? share.estimatedCostUSD : nil
                )
            },
            topModels: usage.modelBreakdown.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }.prefix(5).map { share in
                ReportModelShare(
                    model: share.model,
                    tokens: share.tokens,
                    requestCount: share.requestCount,
                    estimatedCostUSD: includesCost ? share.estimatedCostUSD : nil
                )
            },
            dailyBreakdown: dailyBreakdown,
            dailyModelBreakdown: modelBreakdown,
            providerBreakdown: providerBreakdown
        )
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
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        project: String? = nil,
        provider: Provider? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let scopedEvents = project.map { label in providerEvents.filter { $0.projectLabel == label } } ?? providerEvents
        let coverage: UsageCoverageSummary
        if since != nil || until != nil || days != nil {
            let window = reportWindow(period: .last7Days, since: since, until: until, days: days, now: now, calendar: calendar)
            let spanDays = max(Int((window.endExclusive.timeIntervalSince(window.start) / 86_400).rounded()), 1)
            let inWindowEvents = scopedEvents.filter { $0.timestamp >= window.start && $0.timestamp < window.endExclusive }
            coverage = UsageCoverageService.coverage(events: inWindowEvents, windowDays: spanDays, now: window.endExclusive.addingTimeInterval(-1), calendar: calendar)
        } else {
            coverage = UsageCoverageService.coverage(events: scopedEvents, windowDays: windowDays, now: now, calendar: calendar)
        }
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

    /// Machine-readable audit CSV over stored local history (toktrack `audit --csv` style).
    ///
    /// Emits the same per-day coverage breakdown as `auditJSON` — one row per
    /// window day with whether activity was recorded and how many tokens that day
    /// carried. Aggregates only; no raw events.
    public static func auditCSVText(
        events: [UsageEvent],
        windowDays: Int = 45,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        project: String? = nil,
        provider: Provider? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let payload = auditPayload(
            events: events,
            project: project,
            provider: provider,
            windowDays: windowDays,
            period: nil,
            since: since,
            until: until,
            days: days,
            now: now,
            calendar: calendar
        )
        var lines: [String] = ["date,active,tokens"]
        for row in payload.days {
            lines.append("\(csvEscape(row.date)),\(row.active ? 1 : 0),\(row.tokens)")
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown audit over stored local history (ccusage `--markdown` style).
    ///
    /// Emits the same coverage summary as `auditText` — coverage percent, active
    /// days, stored span, and gap statistics — as a Markdown document for notes
    /// and PR descriptions.
    public static func auditMarkdownText(
        events: [UsageEvent],
        windowDays: Int = 45,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        project: String? = nil,
        provider: Provider? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let scopedEvents = project.map { label in providerEvents.filter { $0.projectLabel == label } } ?? providerEvents
        let coverage: UsageCoverageSummary
        if since != nil || until != nil || days != nil {
            let window = reportWindow(period: .last7Days, since: since, until: until, days: days, now: now, calendar: calendar)
            let spanDays = max(Int((window.endExclusive.timeIntervalSince(window.start) / 86_400).rounded()), 1)
            let inWindowEvents = scopedEvents.filter { $0.timestamp >= window.start && $0.timestamp < window.endExclusive }
            coverage = UsageCoverageService.coverage(events: inWindowEvents, windowDays: spanDays, now: window.endExclusive.addingTimeInterval(-1), calendar: calendar)
        } else {
            coverage = UsageCoverageService.coverage(events: scopedEvents, windowDays: windowDays, now: now, calendar: calendar)
        }
        let percent = Int((coverage.coverageRatio * 100).rounded())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        lines.append("## TokenPilot · Audit")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|---|---|")
        lines.append("| Coverage | \(percent)% of last \(coverage.windowDays) days |")
        lines.append("| Active days | \(coverage.activeDays) |")
        if let oldest = coverage.oldestEventDay, let newest = coverage.newestEventDay {
            lines.append("| Oldest stored | \(formatter.string(from: oldest)) |")
            lines.append("| Newest stored | \(formatter.string(from: newest)) |")
        } else {
            lines.append("| Stored activity | None |")
        }
        lines.append("| Gap runs | \(coverage.gapRunCount) |")
        lines.append("| Longest gap | \(coverage.longestGapDays) days |")
        lines.append("")
        lines.append("_Local activity, not provider quota._")
        return lines.joined(separator: "\n")
    }

    /// Machine-readable audit payload over stored local history (toktrack `audit --json` style).
    ///
    /// Emits the same coverage summary as `auditText` as structured JSON so
    /// scripts can diff coverage over time. Aggregates only; no raw events.
    public static func auditJSON(
        events: [UsageEvent],
        windowDays: Int = 45,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        project: String? = nil,
        provider: Provider? = nil,
        sections: [HistoryPeriod]? = nil,
        instances: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let sections {
            // ccusage `--sections` style: each requested period emitted in one envelope
            // with a totals object last, matching the report/stats/export/summary envelopes.
            let sectionPayloads = sections.map { section in
                var payload = auditPayload(
                    events: events,
                    project: project,
                    provider: provider,
                    windowDays: windowDays,
                    period: section,
                    since: nil,
                    until: nil,
                    days: nil,
                    now: now,
                    calendar: calendar
                )
                if instances {
                    // ccusage `--instances` style: each project carries its own payload.
                    payload.projects = auditProjectGroups(
                        events: events,
                        provider: provider,
                        windowDays: windowDays,
                        period: section,
                        since: nil,
                        until: nil,
                        days: nil,
                        now: now,
                        calendar: calendar
                    )
                }
                return payload
            }
            let envelope = AuditSectionsEnvelopeJSON(
                generatedAt: now,
                sections: sectionPayloads,
                totals: AuditTotalsJSON(
                    totalActiveDays: sectionPayloads.reduce(0) { $0 + $1.activeDays },
                    totalWindowDays: sectionPayloads.reduce(0) { $0 + $1.windowDays }
                )
            )
            return try encoder.encode(envelope)
        }
        var payload = auditPayload(
            events: events,
            project: project,
            provider: provider,
            windowDays: windowDays,
            period: nil,
            since: since,
            until: until,
            days: days,
            now: now,
            calendar: calendar
        )
        if instances {
            // ccusage `--instances` style: group coverage by project label, with each
            // project carrying its own payload alongside the combined coverage.
            payload.projects = auditProjectGroups(
                events: events,
                provider: provider,
                windowDays: windowDays,
                period: nil,
                since: since,
                until: until,
                days: days,
                now: now,
                calendar: calendar
            )
        }
        return try encoder.encode(payload)
    }

    private static func auditProjectGroups(
        events: [UsageEvent],
        provider: Provider? = nil,
        windowDays: Int,
        period: HistoryPeriod?,
        since: Date?,
        until: Date?,
        days: Int?,
        now: Date,
        calendar: Calendar
    ) -> [AuditProjectGroup] {
        let labels = Set(events.compactMap(\.projectLabel)).sorted()
        return labels.map { label in
            AuditProjectGroup(
                project: label,
                payload: auditPayload(
                    events: events,
                    project: label,
                    provider: provider,
                    windowDays: windowDays,
                    period: period,
                    since: since,
                    until: until,
                    days: days,
                    now: now,
                    calendar: calendar
                )
            )
        }
    }

    private static func auditPayload(
        events: [UsageEvent],
        project: String?,
        provider: Provider? = nil,
        windowDays: Int,
        period: HistoryPeriod?,
        since: Date?,
        until: Date?,
        days: Int?,
        now: Date,
        calendar: Calendar
    ) -> AuditCoverageJSON {
        let providerEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        let scopedEvents = project.map { label in providerEvents.filter { $0.projectLabel == label } } ?? providerEvents
        let coverage: UsageCoverageSummary
        let anchor: Date
        let auditedEvents: [UsageEvent]
        if let period {
            // Section window: the period's own bounds bound the audited window.
            let window = reportWindow(period: period, since: nil, until: nil, days: nil, now: now, calendar: calendar)
            let spanDays = max(Int((window.endExclusive.timeIntervalSince(window.start) / 86_400).rounded()), 1)
            auditedEvents = scopedEvents.filter { $0.timestamp >= window.start && $0.timestamp < window.endExclusive }
            anchor = window.endExclusive.addingTimeInterval(-1)
            coverage = UsageCoverageService.coverage(events: auditedEvents, windowDays: spanDays, now: anchor, calendar: calendar)
        } else if since != nil || until != nil || days != nil {
            let window = reportWindow(period: .last7Days, since: since, until: until, days: days, now: now, calendar: calendar)
            let spanDays = max(Int((window.endExclusive.timeIntervalSince(window.start) / 86_400).rounded()), 1)
            auditedEvents = scopedEvents.filter { $0.timestamp >= window.start && $0.timestamp < window.endExclusive }
            anchor = window.endExclusive.addingTimeInterval(-1)
            coverage = UsageCoverageService.coverage(events: auditedEvents, windowDays: spanDays, now: anchor, calendar: calendar)
        } else {
            auditedEvents = scopedEvents
            anchor = now
            coverage = UsageCoverageService.coverage(events: auditedEvents, windowDays: windowDays, now: now, calendar: calendar)
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let startOfToday = calendar.startOfDay(for: anchor)
        let windowStart = calendar.date(byAdding: .day, value: -(coverage.windowDays - 1), to: startOfToday) ?? startOfToday
        let activeDays = Set(auditedEvents.map { calendar.startOfDay(for: $0.timestamp) })
        // toktrack `audit --json` per-day breakdown: one row per window day with
        // whether activity was recorded and how many tokens that day carried.
        let days = (0..<coverage.windowDays).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: windowStart) ?? startOfToday
            let dayEvents = auditedEvents.filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
            return AuditDayRow(
                date: dayFormatter.string(from: day),
                active: activeDays.contains(day),
                tokens: dayEvents.reduce(0) { $0 + $1.totalTokens }
            )
        }
        return AuditCoverageJSON(
            generatedAt: now,
            windowDays: coverage.windowDays,
            coveragePercent: Int((coverage.coverageRatio * 100).rounded()),
            activeDays: coverage.activeDays,
            oldestEventDay: coverage.oldestEventDay.map { dayFormatter.string(from: $0) },
            newestEventDay: coverage.newestEventDay.map { dayFormatter.string(from: $0) },
            gapRunCount: coverage.gapRunCount,
            longestGapDays: coverage.longestGapDays,
            days: days
        )
    }

    /// Current limit-window blocks over stored capacity evidence (ccusage `blocks` style).
    ///
    /// Renders each series as a provider + window block with used/remaining
    /// percent and the reset time, so users can see at a glance which billing
    /// window is closest to exhaustion. `active` keeps only blocks whose reset
    /// has not elapsed; `recent` keeps only freshly observed blocks. Aggregates only.
    public static func blocksText(
        assessments: [CapacityAssessment],
        active: Bool = false,
        recent: Bool = false,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let blocks = filteredBlocks(assessments, active: active, recent: recent, since: since, until: until, days: days, now: now, calendar: calendar)
        var lines: [String] = []
        lines.append("TokenPilot · \(localized("Blocks", language: .en))")
        for assessment in blocks {
            let observation = assessment.observation
            let series = observation.seriesID
            guard let usedPercent = observation.value.usedPercent else { continue }
            let remaining = min(max(100 - usedPercent, 0), 100)
            var line = "\(localized(series.provider.displayName, language: .en)) (\(series.providerWindowID)): " +
                "\(usedPercent)% \(localized("used", language: .en)) · \(remaining)% \(localized("remaining", language: .en))"
            if let resetAt = observation.resetAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = calendar
                formatter.dateFormat = "HH:mm"
                line += " · \(localized("resets", language: .en)) \(formatter.string(from: resetAt))"
            }
            lines.append(line)
        }
        lines.append(localized("Local activity, not provider quota", language: .en))
        return lines.joined(separator: "\n")
    }

    /// Machine-readable limit-window blocks payload (ccusage `blocks --json` style).
    ///
    /// Emits the same blocks as `blocksText` as structured JSON so scripts can
    /// watch window exhaustion. Cost and credentials never appear.
    public static func blocksJSON(
        assessments: [CapacityAssessment],
        active: Bool = false,
        recent: Bool = false,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Data {
        let blocks = filteredBlocks(assessments, active: active, recent: recent, since: since, until: until, days: days, now: now, calendar: calendar)
        let payload = BlocksPayloadJSON(
            generatedAt: now,
            blocks: blocks.compactMap { assessment -> BlocksRowJSON? in
                let observation = assessment.observation
                let series = observation.seriesID
                guard let usedPercent = observation.value.usedPercent else { return nil }
                return BlocksRowJSON(
                    provider: series.provider.displayName,
                    windowID: series.providerWindowID,
                    usedPercent: usedPercent,
                    remainingPercent: min(max(100 - usedPercent, 0), 100),
                    resetAt: observation.resetAt
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    /// Machine-readable limit-window blocks rows (ccusage `blocks --csv` style).
    ///
    /// Emits the same blocks as `blocksText` as CSV rows so scripts can watch
    /// window exhaustion in spreadsheet tooling. Cost and credentials never appear.
    public static func blocksCSVText(
        assessments: [CapacityAssessment],
        active: Bool = false,
        recent: Bool = false,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let blocks = filteredBlocks(assessments, active: active, recent: recent, since: since, until: until, days: days, now: now, calendar: calendar)
        var lines: [String] = ["provider,window,usedPercent,remainingPercent,resetAt"]
        let formatter = ISO8601DateFormatter()
        for assessment in blocks {
            let observation = assessment.observation
            let series = observation.seriesID
            guard let usedPercent = observation.value.usedPercent else { continue }
            let remaining = min(max(100 - usedPercent, 0), 100)
            let reset = observation.resetAt.map { formatter.string(from: $0) } ?? ""
            lines.append("\(csvEscape(series.provider.displayName)),\(csvEscape(series.providerWindowID)),\(usedPercent),\(remaining),\(csvEscape(reset))")
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown limit-window blocks over stored capacity evidence (ccusage `--markdown` style).
    ///
    /// Emits the same blocks as `blocksText` — provider, window, used/remaining
    /// percent, and reset time — as a Markdown document for notes and PR
    /// descriptions. Cost and credentials never appear.
    public static func blocksMarkdownText(
        assessments: [CapacityAssessment],
        active: Bool = false,
        recent: Bool = false,
        since: Date? = nil,
        until: Date? = nil,
        days: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let blocks = filteredBlocks(assessments, active: active, recent: recent, since: since, until: until, days: days, now: now, calendar: calendar)
        var lines: [String] = []
        lines.append("## TokenPilot · Blocks")
        lines.append("")
        lines.append("| Provider | Window | Used | Remaining | Resets |")
        lines.append("|---|---|---|---|---|")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "HH:mm"
        for assessment in blocks {
            let observation = assessment.observation
            let series = observation.seriesID
            guard let usedPercent = observation.value.usedPercent else { continue }
            let remaining = min(max(100 - usedPercent, 0), 100)
            let reset = observation.resetAt.map { formatter.string(from: $0) } ?? "—"
            lines.append("| \(localized(series.provider.displayName, language: .en)) | \(series.providerWindowID) | \(usedPercent)% | \(remaining)% | \(reset) |")
        }
        lines.append("")
        lines.append("_Local activity, not provider quota._")
        return lines.joined(separator: "\n")
    }

    /// Applies the `--active`/`--recent` block filters and the explicit observation
    /// window shared by text and JSON output.
    private static func filteredBlocks(
        _ assessments: [CapacityAssessment],
        active: Bool,
        recent: Bool,
        since: Date?,
        until: Date?,
        days: Int?,
        now: Date,
        calendar: Calendar
    ) -> [CapacityAssessment] {
        let window = since != nil || until != nil || days != nil
            ? reportWindow(period: .last7Days, since: since, until: until, days: days, now: now, calendar: calendar)
            : nil
        return assessments.filter { assessment in
            if let window, assessment.observation.observedAt < window.start || assessment.observation.observedAt >= window.endExclusive {
                return false
            }
            if active {
                if let resetAt = assessment.observation.resetAt, resetAt <= now {
                    return false
                }
            }
            if recent {
                let age = now.timeIntervalSince(assessment.observation.observedAt)
                if age > assessment.observation.freshnessPolicy.maximumAge {
                    return false
                }
            }
            return true
        }
    }

    private static func dailyBreakdownLines(
        events: [UsageEvent],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        now: Date,
        calendar: Calendar,
        includesCost: Bool = true
    ) -> [String] {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "MM-dd"
        let inWindow = events.filter { $0.timestamp >= window.start && $0.timestamp < window.endExclusive }
        let grouped = Dictionary(grouping: inWindow) { event in
            calendar.startOfDay(for: event.timestamp)
        }
        let dayTokens = grouped.mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
        let dayCosts = grouped.compactMapValues { events -> Decimal? in
            let costs = events.compactMap(\.estimatedCostUSD)
            guard !costs.isEmpty else { return nil }
            return costs.reduce(Decimal(0), +)
        }
        return dayTokens.keys.sorted().map { day in
            var line = "\(dayFormatter.string(from: day)): \(TokenPilotFormatters.compactNumber(dayTokens[day] ?? 0)) " + localized("tok", language: .en)
            if includesCost, let cost = dayCosts[day], cost > 0 {
                let amount = NSDecimalNumber(decimal: cost).doubleValue
                line += " · $\(String(format: "%.2f", amount))"
            }
            return line
        }
    }

    /// Per-day, per-model token/cost lines for the `--breakdown` report section
    /// (ccusage `--breakdown` style). Each active day lists its models, heaviest first.
    private static func dailyModelBreakdownLines(
        events: [UsageEvent],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        now: Date,
        calendar: Calendar,
        includesCost: Bool = true
    ) -> [String] {
        let window = reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "MM-dd"
        let inWindow = events.filter { $0.timestamp >= window.start && $0.timestamp < window.endExclusive }
        let byDay = Dictionary(grouping: inWindow) { calendar.startOfDay(for: $0.timestamp) }

        var lines: [String] = []
        for day in byDay.keys.sorted() {
            let dayEvents = byDay[day] ?? []
            let dayTokens = dayEvents.reduce(0) { $0 + $1.totalTokens }
            var dayLine = "\(dayFormatter.string(from: day)): \(TokenPilotFormatters.compactNumber(dayTokens)) " + localized("tok", language: .en)
            if includesCost {
                let dayCost = dayEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)
                if dayCost > 0 {
                    let amount = NSDecimalNumber(decimal: dayCost).doubleValue
                    dayLine += " · $\(String(format: "%.2f", amount))"
                }
            }
            lines.append(dayLine)
            let byModel = Dictionary(grouping: dayEvents) { event in
                event.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            }
            let modelLines = byModel.keys.sorted { lhs, rhs in
                let lhsTokens = byModel[lhs]?.reduce(0) { $0 + $1.totalTokens } ?? 0
                let rhsTokens = byModel[rhs]?.reduce(0) { $0 + $1.totalTokens } ?? 0
                if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
                return lhs < rhs
            }.map { model -> String in
                let modelEvents = byModel[model] ?? []
                let tokens = modelEvents.reduce(0) { $0 + $1.totalTokens }
                var modelLine = "  \(model): \(TokenPilotFormatters.compactNumber(tokens)) \(localized("tok", language: .en))"
                if includesCost {
                    let cost = modelEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)
                    if cost > 0 {
                        let amount = NSDecimalNumber(decimal: cost).doubleValue
                        modelLine += " · $\(String(format: "%.2f", amount))"
                    }
                }
                return modelLine
            }
            lines.append(contentsOf: modelLines)
        }
        return lines
    }

    /// Ranks models by token share and returns the top `limit` as plain lines.
    /// Mirrors the History per-model breakdown; cost is appended when recorded.
    private static func modelRankingLines(
        _ shares: [ModelUsageShare],
        language: TokenPilotLanguage,
        limit: Int = 5,
        includesCost: Bool = true
    ) -> [String] {
        let top = shares
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
            .prefix(limit)
        return top.map { share in
            var line = "\(share.model): \(TokenPilotFormatters.compactNumber(share.tokens)) \(localized("tok", language: language)) (\(share.tokenPercent)%)"
            if includesCost, let cost = share.estimatedCostUSD, cost > 0 {
                let amount = NSDecimalNumber(decimal: cost).doubleValue
                line += " · $\(String(format: "%.2f", amount))"
            }
            return line
        }
    }

    /// Ranks projects by token share and returns the top `limit` as plain lines.
    /// Mirrors the History per-project breakdown; cost is appended when recorded.
    private static func projectRankingLines(
        _ shares: [ProjectUsageShare],
        language: TokenPilotLanguage,
        limit: Int = 5,
        includesCost: Bool = true
    ) -> [String] {
        let top = shares
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
            .prefix(limit)
        return top.map { share in
            var line = "\(share.label): \(TokenPilotFormatters.compactNumber(share.tokens)) \(localized("tok", language: language)) (\(share.tokenPercent)%)"
            if includesCost, let cost = share.estimatedCostUSD, cost > 0 {
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

    /// Parses a strict `yyyy-MM-dd` date (CLI `--since`/`--until` values).
    private static func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    /// Parses a CLI `--start-of-week` day name (sunday...saturday) into `WeekStartDay`.
    private static func parseWeekStartDay(_ value: String) -> WeekStartDay? {
        WeekStartDay.allCases.first { $0.label.lowercased() == value.lowercased() }
    }

    /// Start of the current week aligned to the requested weekday, used to convert
    /// CLI `--start-of-week` into the `since` bound for report/export/stats windows.
    public static func weekStartDate(
        _ day: WeekStartDay,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let target = day.calendarWeekday
        let today = calendar.startOfDay(for: now)
        let currentWeekday = calendar.component(.weekday, from: today)
        let daysBack = (currentWeekday - target + 7) % 7
        return calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
    }

    /// Effective window bounds for a report/export. Explicit `--since`/`--until` dates take
    /// precedence over `--days`, which takes precedence over the named period; `endExclusive`
    /// is the day after `until` so the whole `until` day is included.
    private static func reportWindow(
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, endExclusive: Date) {
        let start: Date
        if let since {
            start = calendar.startOfDay(for: since)
        } else if let days {
            start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? calendar.startOfDay(for: now)
        } else {
            start = periodStart(period, now: now, calendar: calendar) ?? now
        }
        let endExclusive: Date
        if let until {
            endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: until)) ?? now.addingTimeInterval(1)
        } else {
            endExclusive = now.addingTimeInterval(1)
        }
        return (start, endExclusive)
    }

    /// Converts the report window bounds into a closed range for aggregation filtering.
    private static func range(from window: (start: Date, endExclusive: Date)) -> ClosedRange<Date> {
        window.start...(window.endExclusive.addingTimeInterval(-0.001))
    }

    /// Closed date range implied by CLI `--since`/`--until`/`--days` values, or nil when none is set.
    /// The app entry point uses this to apply the same window to `export` aggregation.
    public static func explicitDateRange(
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ClosedRange<Date>? {
        guard since != nil || until != nil || days != nil else { return nil }
        return range(from: reportWindow(period: period, since: since, until: until, days: days, now: now, calendar: calendar))
    }

    private static func periodLabel(
        _ period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        language: TokenPilotLanguage,
        now: Date,
        calendar: Calendar
    ) -> String {
        if since != nil || until != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.dateFormat = "yyyy-MM-dd"
            let sinceText = since.map { formatter.string(from: $0) } ?? "…"
            let untilText = until.map { formatter.string(from: $0) } ?? "…"
            return "\(sinceText) → \(untilText)"
        }
        if let days {
            return "Last \(days) days"
        }
        return periodLabel(period, language: language)
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

private struct TokenPilotReportJSON: Codable {
    var generatedAt: Date
    var period: String
    var totalTokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
    var cacheHitRate: Int?
    var providerShare: [ReportProviderRow]
    var topModels: [ReportModelShare]
    var dailyBreakdown: [ReportDailyRow]
    var dailyModelBreakdown: [ReportModelRow]?
    var providerBreakdown: [ReportProviderBreakdownRow]
    var projects: [ReportProjectGroup]?
}

private struct ReportProjectGroup: Codable {
    var project: String
    var payload: TokenPilotReportJSON
}

private struct ReportProviderBreakdownRow: Codable {
    var provider: String
    var tokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
    var models: [ReportModelEntry]
}

private struct ReportProviderRow: Codable {
    var provider: String
    var tokens: Int
    var percent: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
}

private struct ReportModelShare: Codable {
    var model: String
    var tokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
}

private struct ReportDailyRow: Codable {
    var date: String
    var tokens: Int
    var estimatedCostUSD: Decimal?
}

private struct ReportModelRow: Codable {
    var date: String
    var models: [ReportModelEntry]
}

private struct ReportModelEntry: Codable {
    var model: String
    var tokens: Int
    var estimatedCostUSD: Decimal?
}

private struct AuditCoverageJSON: Codable {
    var generatedAt: Date
    var windowDays: Int
    var coveragePercent: Int
    var activeDays: Int
    var oldestEventDay: String?
    var newestEventDay: String?
    var gapRunCount: Int
    var longestGapDays: Int
    var days: [AuditDayRow]
    var projects: [AuditProjectGroup]?
}

private struct AuditProjectGroup: Codable {
    var project: String
    var payload: AuditCoverageJSON
}

private struct AuditDayRow: Codable {
    var date: String
    var active: Bool
    var tokens: Int
}

private struct AuditSectionsEnvelopeJSON: Codable {
    var generatedAt: Date
    var sections: [AuditCoverageJSON]
    var totals: AuditTotalsJSON
}

private struct AuditTotalsJSON: Codable {
    var totalActiveDays: Int
    var totalWindowDays: Int
}

private struct BlocksPayloadJSON: Codable {
    var generatedAt: Date
    var blocks: [BlocksRowJSON]
}

private struct BlocksRowJSON: Codable {
    var provider: String
    var windowID: String
    var usedPercent: Int
    var remainingPercent: Int
    var resetAt: Date?
}

private struct StatsPayloadJSON: Codable {
    var generatedAt: Date
    var period: String
    var totalTokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
    var activeDays: Int
    var dailyAverage: Int
    var busiestDay: String?
    var busiestHour: Int?
    var mostUsedProvider: String?
    var dailyModelBreakdown: [ReportModelRow]?
    var providers: [StatsProviderBreakdownJSON]
    var projects: [StatsProjectGroup]?
}

private struct StatsProjectGroup: Codable {
    var project: String
    var payload: StatsPayloadJSON
}

private struct StatsProviderBreakdownJSON: Codable {
    var provider: String
    var tokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
    var models: [StatsModelEntryJSON]
}

private struct StatsModelEntryJSON: Codable {
    var model: String
    var tokens: Int
    var estimatedCostUSD: Decimal?
}

private struct StatsSectionsEnvelopeJSON: Codable {
    var generatedAt: Date
    var sections: [StatsPayloadJSON]
    var totals: StatsTotalsJSON
}

private struct StatsTotalsJSON: Codable {
    var totalTokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
}

private struct SummaryPayloadJSON: Codable {
    var generatedAt: Date
    var period: String
    var totalTokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
    var providerShare: [SummaryProviderShareJSON]
    var remainingCapacity: [SummaryRemainingJSON]
    var dailyModelBreakdown: [ReportModelRow]?
    var projects: [SummaryProjectGroup]?
}

private struct SummaryProjectGroup: Codable {
    var project: String
    var payload: SummaryPayloadJSON
}

private struct SummaryProviderShareJSON: Codable {
    var provider: String
    var tokens: Int
    var percent: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
}

private struct SummaryRemainingJSON: Codable {
    var provider: String
    var window: String
    var remainingPercent: Int
}

private struct SummarySectionsEnvelopeJSON: Codable {
    var generatedAt: Date
    var sections: [SummaryPayloadJSON]
    var totals: SummaryTotalsJSON
}

private struct SummaryTotalsJSON: Codable {
    var totalTokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
}

private struct ReportSectionsEnvelopeJSON: Codable {
    var generatedAt: Date
    var sections: [TokenPilotReportJSON]
    var totals: ReportTotalsJSON
}

private struct ReportTotalsJSON: Codable {
    var totalTokens: Int
    var requestCount: Int
    var estimatedCostUSD: Decimal?
}
