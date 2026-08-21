import Foundation

/// One-line terminal status renderer for editor status lines.
///
/// Benchmarked against ccusage `statusline`, ccstatusline, and the terminal
/// statusline in Claude Usage Tracker: an AI CLI runs the command on every
/// prompt, optionally pipes its own session JSON in on stdin, and prints the
/// single line it returns.
///
/// Redaction rules are the same as every other TokenPilot output surface: the
/// line carries aggregates, provider quota percentages, and the model name the
/// caller itself supplied — never prompts, responses, local paths, project
/// labels, session identifiers, or credentials.
public enum StatuslineComponent: String, CaseIterable, Equatable, Sendable {
    /// Model display name, taken from the caller's stdin payload.
    case model
    /// Tightest eligible provider quota window: remaining percent and reset countdown.
    case capacity
    /// Today's local token total.
    case today
    /// Today's local estimated cost.
    case cost
    /// Current 5-hour local activity block: tokens and time left in the block.
    case block
    /// Local token burn rate over the trailing hour.
    case burn
    /// Session cost, taken from the caller's stdin payload.
    case session

    public static let defaultComponents: [StatuslineComponent] = [.model, .capacity, .today, .cost]
}

/// The subset of the Claude Code `statusLine` stdin contract TokenPilot reads.
///
/// Everything else in the payload (session id, workspace paths, transcript
/// path, git branch) is deliberately ignored so no path or identifier can reach
/// the rendered line.
public struct StatuslineInput: Equatable, Sendable {
    public let modelName: String?
    public let sessionCostUSD: Decimal?
    public let exceedsLargeContext: Bool

    public init(modelName: String? = nil, sessionCostUSD: Decimal? = nil, exceedsLargeContext: Bool = false) {
        self.modelName = modelName
        self.sessionCostUSD = sessionCostUSD
        self.exceedsLargeContext = exceedsLargeContext
    }

    public static let empty = StatuslineInput()
}

/// One quota window, reduced to what a status line needs.
///
/// The full capacity evidence store is megabytes of history; decoding it costs
/// about half a second, which an editor pays on every prompt. The app writes
/// these few fields after each refresh instead (see `StatuslineSnapshotStore`),
/// and freshness is re-evaluated at render time so a status line never reports a
/// value as current just because the app was running when it was captured.
public struct StatuslineCapacityWindow: Codable, Equatable, Sendable {
    public let provider: Provider
    public let windowID: String
    public let durationMinutes: Int?
    public let usedPercent: Int
    public let resetAt: Date?
    public let observedAt: Date
    public let maximumAgeSeconds: TimeInterval

    public init(
        provider: Provider,
        windowID: String,
        durationMinutes: Int?,
        usedPercent: Int,
        resetAt: Date?,
        observedAt: Date,
        maximumAgeSeconds: TimeInterval
    ) {
        self.provider = provider
        self.windowID = windowID
        self.durationMinutes = durationMinutes
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetAt = resetAt
        self.observedAt = observedAt
        self.maximumAgeSeconds = max(maximumAgeSeconds, 0)
    }

    public var remainingPercent: Int { 100 - usedPercent }

    public func isFresh(now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= maximumAgeSeconds
    }

    /// Sort key that keeps the rendered choice stable when two windows tie.
    var canonicalID: String {
        [provider.rawValue, windowID, durationMinutes.map(String.init)].compactMap { $0 }.joined(separator: "/")
    }
}

public enum StatuslineService {
    /// Longest model name kept, so a verbose caller cannot push the quota out of a narrow status line.
    private static let maxModelNameLength = 28

    // MARK: - Input

    /// Parses the caller's stdin payload, tolerating an empty or malformed body.
    ///
    /// A status line must still render when the caller pipes nothing (a manual
    /// terminal run) or pipes something unexpected, so every failure degrades to
    /// `.empty` instead of throwing.
    public static func parseInput(_ data: Data) -> StatuslineInput {
        guard !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .empty
        }

        var modelName: String?
        if let model = root["model"] as? [String: Any] {
            let raw = (model["display_name"] as? String) ?? (model["id"] as? String)
            modelName = sanitizedModelName(raw)
        } else {
            modelName = sanitizedModelName(root["model"] as? String)
        }

        var sessionCost: Decimal?
        if let cost = root["cost"] as? [String: Any],
           let total = decimalValue(cost["total_cost_usd"]), total >= 0 {
            sessionCost = total
        }

        let exceeds = (root["exceeds_200k_tokens"] as? Bool) ?? false
        return StatuslineInput(modelName: modelName, sessionCostUSD: sessionCost, exceedsLargeContext: exceeds)
    }

    /// Keeps a model label printable: single line, trimmed, length-capped.
    private static func sanitizedModelName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxModelNameLength else { return collapsed }
        return String(collapsed.prefix(maxModelNameLength - 1)) + "…"
    }

    /// Parses a `--components` list, rejecting unknown names so typos surface instead of silently rendering less.
    public static func parseComponents(_ raw: String) -> [StatuslineComponent]? {
        let names = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        var seen = Set<StatuslineComponent>()
        var components: [StatuslineComponent] = []
        for name in names {
            guard let component = StatuslineComponent(rawValue: name) else { return nil }
            guard seen.insert(component).inserted else { continue }
            components.append(component)
        }
        return components
    }

    // MARK: - Rendering

    /// Reduces stored capacity assessments to status line windows.
    ///
    /// Only provider-reported, comparable percentage windows survive: manual
    /// entries, activity-only sources, and unsupported windows must never be
    /// printed as quota. Stale entries are kept here and marked at render time.
    public static func windows(from assessments: [CapacityAssessment]) -> [StatuslineCapacityWindow] {
        assessments.compactMap { assessment in
            let observation = assessment.observation
            guard let usedPercent = observation.value.usedPercent,
                  observation.authority == .providerReported,
                  observation.comparability == .comparable,
                  observation.stability == .supported,
                  observation.consent != .denied,
                  observation.consent != .unavailable else {
                return nil
            }
            return StatuslineCapacityWindow(
                provider: observation.seriesID.provider,
                windowID: observation.seriesID.providerWindowID,
                durationMinutes: observation.seriesID.durationMinutes,
                usedPercent: usedPercent,
                resetAt: observation.resetAt,
                observedAt: observation.observedAt,
                maximumAgeSeconds: observation.freshnessPolicy.maximumAge
            )
        }
    }

    /// Renders the status line.
    ///
    /// Only windows that are still within their freshness policy are shown as
    /// current quota; older ones carry the stale marker, and local activity is
    /// always labeled as tokens or cost, never as a limit.
    public static func render(
        input: StatuslineInput = .empty,
        events: [UsageEvent],
        windows: [StatuslineCapacityWindow],
        components: [StatuslineComponent] = StatuslineComponent.defaultComponents,
        provider: Provider? = nil,
        colorized: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let scopedEvents = provider.map { p in events.filter { $0.provider == p } } ?? events
        var segments: [String] = []

        for component in components {
            switch component {
            case .model:
                if let modelName = input.modelName {
                    segments.append(input.exceedsLargeContext ? "\(modelName) ⚠" : modelName)
                }
            case .capacity:
                if let text = capacitySegment(windows: windows, provider: provider, colorized: colorized, now: now) {
                    segments.append(text)
                }
            case .today:
                let tokens = todayTokens(events: scopedEvents, now: now, calendar: calendar)
                if tokens > 0 {
                    segments.append("\(TokenPilotFormatters.compactNumber(tokens)) tok")
                }
            case .cost:
                if let cost = todayCost(events: scopedEvents, now: now, calendar: calendar), cost > 0 {
                    segments.append(moneyText(cost))
                }
            case .block:
                if let text = blockSegment(events: scopedEvents, now: now, calendar: calendar) {
                    segments.append(text)
                }
            case .burn:
                let reading = ThroughputService().reading(events: scopedEvents, windowMinutes: 60, now: now)
                if reading.hasActivity {
                    let perMinute = Int(reading.tokensPerMinute.rounded())
                    segments.append("\(TokenPilotFormatters.compactNumber(perMinute))/min")
                }
            case .session:
                if let cost = input.sessionCostUSD, cost > 0 {
                    segments.append("ses \(moneyText(cost))")
                }
            }
        }

        guard !segments.isEmpty else { return "TokenPilot: no local usage yet" }
        return segments.joined(separator: " | ")
    }

    // MARK: - Segments

    /// The tightest quota window worth warning about: lowest remaining percent wins.
    private static func capacitySegment(
        windows: [StatuslineCapacityWindow],
        provider: Provider?,
        colorized: Bool,
        now: Date
    ) -> String? {
        let scoped = provider.map { p in windows.filter { $0.provider == p } } ?? windows
        let fresh = scoped.filter { $0.isFresh(now: now) }
        // TokenPilot only runs the adapters while the app is open, so a status line
        // called from a terminal can outlive the newest evidence. Rather than hiding
        // the window (which reads as "no quota") the last provider-reported value is
        // shown with the app's stale marker, never as a current number.
        let isStale = fresh.isEmpty
        let pool = isStale ? scoped : fresh

        let tightest = pool.min { lhs, rhs in
            if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent > rhs.usedPercent }
            return lhs.canonicalID < rhs.canonicalID
        }

        guard let tightest else { return nil }
        let remaining = tightest.remainingPercent
        var text = "\(tightest.provider.shortName) \(windowLabel(for: tightest)) \(remaining)%"
        if isStale {
            text += "·S"
        }
        if let resetAt = tightest.resetAt, resetAt > now {
            text += " \(countdownText(until: resetAt, now: now))"
        }
        return colorized ? colorize(text, remainingPercent: remaining) : text
    }

    /// Local 5-hour activity block: tokens burned in it and how long it still runs.
    ///
    /// Labeled `blk` and always aggregates-only — these buckets are local
    /// activity, never a provider billing window.
    private static func blockSegment(events: [UsageEvent], now: Date, calendar: Calendar) -> String? {
        let start = FiveHourBlocksService.blockStart(of: now, calendar: calendar)
        let end = FiveHourBlocksService.blockEnd(of: start, calendar: calendar)
        let tokens = events
            .filter { $0.timestamp >= start && $0.timestamp <= now }
            .reduce(0) { $0 + $1.totalTokens }
        guard tokens > 0 else { return nil }
        return "blk \(TokenPilotFormatters.compactNumber(tokens)) \(countdownText(until: end, now: now))"
    }

    /// Countdown sized for a status line: days past two days out, hours and minutes below that.
    ///
    /// `TokenPilotFormatters.remainingTime` is the popover's format and renders a
    /// monthly window as "106h 47m", which is too wide for one terminal line.
    static func countdownText(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 48 * 3600 { return "\(seconds / 86_400)d" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    private static func todayTokens(events: [UsageEvent], now: Date, calendar: Calendar) -> Int {
        todayEvents(events: events, now: now, calendar: calendar).reduce(0) { $0 + $1.workingTokens }
    }

    private static func todayCost(events: [UsageEvent], now: Date, calendar: Calendar) -> Decimal? {
        let costs = todayEvents(events: events, now: now, calendar: calendar).compactMap(\.estimatedCostUSD)
        guard !costs.isEmpty else { return nil }
        return costs.reduce(Decimal(0), +)
    }

    private static func todayEvents(events: [UsageEvent], now: Date, calendar: Calendar) -> [UsageEvent] {
        let start = calendar.startOfDay(for: now)
        return events.filter { $0.timestamp >= start && $0.timestamp <= now }
    }

    private static func moneyText(_ value: Decimal) -> String {
        String(format: "$%.2f", NSDecimalNumber(decimal: value).doubleValue)
    }

    /// Compact window label, preferring the window's own duration over its provider-specific id.
    static func windowLabel(for window: StatuslineCapacityWindow) -> String {
        if let minutes = window.durationMinutes, minutes > 0 {
            if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
            if minutes % 60 == 0 { return "\(minutes / 60)h" }
            return "\(minutes)m"
        }
        switch window.windowID {
        case "five-hour", "manual-five-hour":
            return "5h"
        case "seven-day", "manual-weekly":
            return "7d"
        case "monthly", "opencode-go-monthly":
            return "mo"
        case "daily-requests":
            return "req"
        case "rolling", "opencode-go-rolling":
            return "roll"
        // `rate-limit` is one id doing two jobs. opencode gives it to the *weekly* window, which was
        // reading "roll" on screen — a rolling window is the one thing it is not. Anywhere else the
        // id says only that a provider reported a quota, and naming a period would be a guess.
        case "rate-limit":
            return window.provider == .opencode ? "7d" : "quota"
        default:
            return "quota"
        }
    }

    /// Three-tier ANSI coloring on the app's shared risk thresholds, so a window
    /// that reads amber here reads amber in the menu bar and the popover too.
    private static func colorize(_ text: String, remainingPercent: Int) -> String {
        let code: String
        switch CapacityRisk.forRemainingPercent(remainingPercent) {
        case .critical:
            code = "31"
        case .warning:
            code = "33"
        default:
            code = "32"
        }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }
}
