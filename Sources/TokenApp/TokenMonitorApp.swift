import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox
import Darwin
import TokenCore

@main
enum TokenPilotEntry {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if TokenPilotCLIService.isCLIInvocation(arguments) {
            exit(await TokenPilotCLIRunner.run(arguments: arguments))
        }
        TokenMonitorApp.main()
    }
}

struct TokenMonitorApp: App {
    @NSApplicationDelegateAdaptor(TokenPilotAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private enum TokenPilotCLIRunner {
    static func run(arguments: [String]) async -> Int32 {
        switch TokenPilotCLIService.parse(arguments: arguments) {
        case .failure(let error):
            writeError("TokenPilot: \(error.localizedDescription)\n\n\(TokenPilotCLIService.helpText)")
            return 2
        case .success(.help):
            print(TokenPilotCLIService.helpText)
            return 0
        case .success(.summary(let period, let since, let until, let days, let timeZone, let includesBreakdown, let project, let sections, let weekStartDay, let includesCost, let includesJSON, let instances, let includesCSV, let includesMarkdown, let provider, let model, let sort)):
            let settings = TokenPilotSettingsStore().load()
            let events = UsageHistoryStore().loadEvents()
            let calendar = cliCalendar(for: timeZone)
            let effectiveSince = weekStartDay.map { TokenPilotCLIService.weekStartDate($0, calendar: calendar) } ?? since
            if includesCSV {
                print(
                    TokenPilotCLIService.summaryCSVText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        calendar: calendar
                    )
                )
            } else if includesMarkdown {
                print(
                    TokenPilotCLIService.summaryMarkdownText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        calendar: calendar
                    )
                )
            } else if includesJSON {
                do {
                    let data = try TokenPilotCLIService.summaryJSON(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        sections: sections,
                        instances: instances,
                        calendar: calendar
                    )
                    FileHandle.standardOutput.write(data)
                    if data.last != 0x0A {
                        FileHandle.standardOutput.write(Data([0x0A]))
                    }
                } catch {
                    writeError("TokenPilot: summary failed: \(error.localizedDescription)")
                    return 1
                }
            } else {
                print(
                    TokenPilotCLIService.summaryText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        language: settings.localization.language,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        calendar: calendar
                    )
                )
            }
            return 0
        case .success(.stats(let period, let since, let until, let days, let includesCost, let timeZone, let includesBreakdown, let project, let includesJSON, let weekStartDay, let sections, let instances, let includesCSV, let includesMarkdown, let provider, let model, let sort)):
            let settings = TokenPilotSettingsStore().load()
            let events = UsageHistoryStore().loadEvents()
            let calendar = cliCalendar(for: timeZone)
            let effectiveSince = weekStartDay.map { TokenPilotCLIService.weekStartDate($0, calendar: calendar) } ?? since
            if includesCSV {
                print(
                    TokenPilotCLIService.statsCSVText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        calendar: calendar
                    )
                )
            } else if includesMarkdown {
                print(
                    TokenPilotCLIService.statsMarkdownText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        calendar: calendar
                    )
                )
            } else if includesJSON {
                do {
                    let data = try TokenPilotCLIService.statsJSON(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sections: sections,
                        instances: instances,
                        calendar: calendar
                    )
                    FileHandle.standardOutput.write(data)
                    if data.last != 0x0A {
                        FileHandle.standardOutput.write(Data([0x0A]))
                    }
                } catch {
                    writeError("TokenPilot: stats failed: \(error.localizedDescription)")
                    return 1
                }
            } else {
                print(
                    TokenPilotCLIService.statsText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        language: settings.localization.language,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        calendar: calendar
                    )
                )
            }
            return 0
        case .success(.report(let period, let format, let since, let until, let days, let includesCost, let timeZone, let includesBreakdown, let project, let sections, let weekStartDay, let instances, let provider, let model, let sort)):
            let settings = TokenPilotSettingsStore().load()
            let events = UsageHistoryStore().loadEvents()
            let calendar = cliCalendar(for: timeZone)
            let effectiveSince = weekStartDay.map { TokenPilotCLIService.weekStartDate($0, calendar: calendar) } ?? since
            switch format {
            case .svg:
                print(
                    TokenPilotCLIService.reportSVGText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        calendar: calendar
                    )
                )
            case .markdown:
                print(
                    TokenPilotCLIService.reportMarkdownText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        calendar: calendar
                    )
                )
            case .text:
                print(
                    TokenPilotCLIService.reportText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        language: settings.localization.language,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        calendar: calendar
                    )
                )
            case .json:
                do {
                    let data = try TokenPilotCLIService.reportJSON(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
                        provider: provider,
                        model: model,
                        sort: sort,
                        sections: sections,
                        instances: instances,
                        calendar: calendar
                    )
                    FileHandle.standardOutput.write(data)
                    if data.last != 0x0A {
                        FileHandle.standardOutput.write(Data([0x0A]))
                    }
                } catch {
                    writeError("TokenPilot: report failed: \(error.localizedDescription)")
                    return 1
                }
            case .csv:
                print(
                    TokenPilotCLIService.reportCSVText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        project: project,
                        provider: provider,
                        model: model,
                        calendar: calendar
                    )
                )
            }
            return 0
        case .success(.audit(let includesJSON, let since, let until, let days, let timeZone, let project, let sections, let includesCSV, let instances, let includesMarkdown, let provider, let model)):
            let events = UsageHistoryStore().loadEvents()
            let calendar = cliCalendar(for: timeZone)
            let settings = TokenPilotSettingsStore().load()
            if includesCSV {
                print(
                    TokenPilotCLIService.auditCSVText(
                        events: events,
                        since: since,
                        until: until,
                        days: days,
                        project: project,
                        provider: provider,
                        model: model,
                        calendar: calendar
                    )
                )
            } else if includesMarkdown {
                print(
                    TokenPilotCLIService.auditMarkdownText(
                        events: events,
                        since: since,
                        until: until,
                        days: days,
                        project: project,
                        provider: provider,
                        model: model,
                        calendar: calendar
                    )
                )
            } else if includesJSON {
                do {
                    let data = try TokenPilotCLIService.auditJSON(
                        events: events,
                        since: since,
                        until: until,
                        days: days,
                        project: project,
                        provider: provider,
                        model: model,
                        sections: sections,
                        instances: instances,
                        calendar: calendar
                    )
                    FileHandle.standardOutput.write(data)
                    if data.last != 0x0A {
                        FileHandle.standardOutput.write(Data([0x0A]))
                    }
                } catch {
                    writeError("TokenPilot: audit failed: \(error.localizedDescription)")
                    return 1
                }
            } else {
                print(
                    TokenPilotCLIService.auditText(
                        events: events,
                        language: settings.localization.language,
                        since: since,
                        until: until,
                        days: days,
                        project: project,
                        provider: provider,
                        model: model,
                        calendar: calendar
                    )
                )
            }
            return 0
        case .success(.blocks(let includesJSON, let active, let recent, let timeZone, let since, let until, let days, let includesCSV, let includesMarkdown, let provider, let watch, let watchIntervalSeconds)):
            let calendar = cliCalendar(for: timeZone)
            let settings = TokenPilotSettingsStore().load()
            if watch {
                return await runBlocksWatch(
                    language: settings.localization.language,
                    active: active,
                    recent: recent,
                    since: since,
                    until: until,
                    days: days,
                    provider: provider,
                    calendar: calendar,
                    intervalSeconds: watchIntervalSeconds
                )
            }
            let assessments = await loadLatestCapacityAssessments()
            if includesJSON {
                do {
                    let data = try TokenPilotCLIService.blocksJSON(assessments: assessments, active: active, recent: recent, since: since, until: until, days: days, provider: provider, calendar: calendar)
                    FileHandle.standardOutput.write(data)
                    if data.last != 0x0A {
                        FileHandle.standardOutput.write(Data([0x0A]))
                    }
                } catch {
                    writeError("TokenPilot: blocks failed: \(error.localizedDescription)")
                    return 1
                }
            } else if includesCSV {
                print(TokenPilotCLIService.blocksCSVText(assessments: assessments, active: active, recent: recent, since: since, until: until, days: days, provider: provider, calendar: calendar))
            } else if includesMarkdown {
                print(TokenPilotCLIService.blocksMarkdownText(assessments: assessments, active: active, recent: recent, since: since, until: until, days: days, provider: provider, calendar: calendar))
            } else {
                print(TokenPilotCLIService.blocksText(assessments: assessments, language: settings.localization.language, active: active, recent: recent, since: since, until: until, days: days, provider: provider, calendar: calendar))
            }
            return 0
        case .success(.statusline(let components, let provider, let colorized, let timeZone)):
            let input = StatuslineService.parseInput(readPipedStandardInput())
            let events = UsageHistoryStore().loadEvents()
            let windows = await loadStatuslineWindows()
            print(
                StatuslineService.render(
                    input: input,
                    events: events,
                    windows: windows,
                    components: components,
                    provider: provider,
                    colorized: colorized && colorsAllowed(),
                    calendar: cliCalendar(for: timeZone)
                )
            )
            return 0
        case .success(.export(let format, let period, let outputPath, let includesCapacity, let since, let until, let days, let includesCost, let timeZone, let project, let weekStartDay, let sections, let instances, let provider, let model, let sort)):
            return await runExport(
                format: format,
                period: period,
                outputPath: outputPath,
                includesCapacity: includesCapacity,
                since: since,
                until: until,
                days: days,
                includesCost: includesCost,
                timeZone: timeZone,
                project: project,
                weekStartDay: weekStartDay,
                sections: sections,
                instances: instances,
                provider: provider,
                model: model,
                sort: sort
            )
        }
    }

    /// Reads stdin only when something is piped in.
    ///
    /// A status line command is also run by hand from a terminal, where stdin is
    /// the TTY and reading it would block until the user pressed Ctrl-D.
    private static func readPipedStandardInput() -> Data {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return Data() }
        return FileHandle.standardInput.readDataToEndOfFile()
    }

    /// Honors the NO_COLOR convention shared by ccusage and other status line tools.
    private static func colorsAllowed() -> Bool {
        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] ?? ""
        return noColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Calendar for CLI window math: the requested timezone, or the system one when unset.
    private static func cliCalendar(for timeZone: TimeZone?) -> Calendar {
        var calendar = Calendar.current
        if let timeZone {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    private static func runExport(
        format: UsageExportFormat,
        period: HistoryPeriod,
        outputPath: String?,
        includesCapacity: Bool,
        since: Date?,
        until: Date?,
        days: Int?,
        includesCost: Bool,
        timeZone: TimeZone?,
        project: String?,
        weekStartDay: WeekStartDay?,
        sections: [HistoryPeriod]?,
        instances: Bool,
        provider: Provider?,
        model: String?,
        sort: SortKind?
    ) async -> Int32 {
        let allEvents = UsageHistoryStore().loadEvents()
        let providerEvents = provider.map { p in allEvents.filter { $0.provider == p } } ?? allEvents
        let modelEvents = model.map { m in providerEvents.filter { $0.model == m } } ?? providerEvents
        let events = project.map { label in modelEvents.filter { $0.projectLabel == label } } ?? modelEvents
        let snapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: events.filter { $0.provider == provider }
            )
        }
        let calendar = cliCalendar(for: timeZone)
        let exporter = UsageExportService()
        do {
            let assessments = includesCapacity
                ? await loadLatestCapacityAssessments()
                : []
            let data: Data
            if let sections {
                // ccusage `--sections` style: one export payload per requested period
                // in an envelope with a totals object last.
                let payloads = sections.map { section in
                    var payload = exporter.makeJSONPayload(
                        usage: usageFor(events: events, period: section, since: nil, until: nil, days: nil, calendar: calendar),
                        snapshots: snapshots,
                        dataMode: "CLI",
                        capacityAssessments: assessments,
                        includesCost: includesCost,
                        sort: sort
                    )
                    if instances {
                        // ccusage `--instances` style: each project carries its own payload.
                        payload.projects = exportProjectGroups(
                            events: events,
                            period: section,
                            since: nil,
                            until: nil,
                            days: nil,
                            includesCost: includesCost,
                            calendar: calendar,
                            exporter: exporter,
                            capacityAssessments: assessments
                        )
                    }
                    return payload
                }
                data = try exporter.makeSectionsJSON(payloads: payloads, includesCost: includesCost)
            } else {
                let effectiveSince = weekStartDay.map { TokenPilotCLIService.weekStartDate($0, calendar: calendar) } ?? since
                let usage = usageFor(events: events, period: period, since: effectiveSince, until: until, days: days, calendar: calendar)
                if instances {
                    var payload = exporter.makeJSONPayload(
                        usage: usage,
                        snapshots: snapshots,
                        dataMode: "CLI",
                        capacityAssessments: assessments,
                        includesCost: includesCost,
                        sort: sort
                    )
                    // ccusage `--instances` style: group usage by project label, with each
                    // project carrying its own full payload alongside the combined row.
                    payload.projects = exportProjectGroups(
                        events: events,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        calendar: calendar,
                        exporter: exporter,
                        capacityAssessments: assessments
                    )
                    data = try exporter.encodeJSONPayload(payload)
                } else {
                    data = try exporter.export(
                        usage: usage,
                        snapshots: snapshots,
                        dataMode: "CLI",
                        format: format,
                        capacityAssessments: assessments,
                        includesCost: includesCost,
                        sort: sort
                    )
                }
            }
            if let outputPath {
                try data.write(to: URL(fileURLWithPath: outputPath))
            } else {
                FileHandle.standardOutput.write(data)
                if data.last != 0x0A {
                    FileHandle.standardOutput.write(Data([0x0A]))
                }
            }
            return 0
        } catch {
            writeError("TokenPilot: export failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Aggregates the given events over the requested window with provider snapshots.
    private static func usageFor(
        events: [UsageEvent],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        calendar: Calendar
    ) -> AggregatedUsage {
        let snapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: events.filter { $0.provider == provider }
            )
        }
        let window = TokenPilotCLIService.explicitDateRange(period: period, since: since, until: until, days: days, calendar: calendar)
        return AggregationService().aggregate(snapshots: snapshots, period: period, customRange: window)
    }

    /// ccusage `--instances` style: one full export payload per workspace label.
    private static func exportProjectGroups(
        events: [UsageEvent],
        period: HistoryPeriod,
        since: Date?,
        until: Date?,
        days: Int?,
        includesCost: Bool,
        calendar: Calendar,
        exporter: UsageExportService,
        capacityAssessments: [CapacityAssessment]
    ) -> [ExportProjectGroup] {
        let labels = Set(events.compactMap(\.projectLabel)).sorted()
        return labels.map { label in
            let scopedEvents = events.filter { $0.projectLabel == label }
            let payload = exporter.makeJSONPayload(
                usage: usageFor(events: scopedEvents, period: period, since: since, until: until, days: days, calendar: calendar),
                snapshots: Provider.allCases.map { provider in
                    ProviderSnapshot(provider: provider, events: scopedEvents.filter { $0.provider == provider })
                },
                dataMode: "CLI",
                capacityAssessments: capacityAssessments,
                includesCost: includesCost
            )
            return ExportProjectGroup(project: label, payload: payload)
        }
    }

    /// Capacity windows for the status line, cheapest source first.
    ///
    /// The snapshot the app writes after each refresh decodes in milliseconds;
    /// decoding the whole evidence store takes long enough to be felt on every
    /// editor prompt, so it is only used when no snapshot exists yet.
    private static func loadStatuslineWindows() async -> [StatuslineCapacityWindow] {
        if let snapshot = StatuslineSnapshotStore().load() {
            return snapshot.windows
        }
        return StatuslineService.windows(from: await loadLatestCapacityAssessments())
    }

    private static func loadLatestCapacityAssessments() async -> [CapacityAssessment] {
        let snapshot = await CapacityEvidenceStore().loadSnapshot()
        let now = Date()
        let observations = snapshot.records.compactMap { record in
            try? record.observationForAssessment(now: now)
        }
        let latestBySeries = Dictionary(grouping: observations) { $0.seriesID.canonicalID }
            .compactMapValues { seriesObservations in
                seriesObservations.max { $0.observedAt < $1.observedAt }
            }
            .values
        return latestBySeries.map { CapacityAssessmentService().assess($0, now: now) }
    }

    /// Re-renders the blocks view on an interval, the way a live tracker does.
    ///
    /// Each tick re-reads the same local sources a one-shot run would, so the interval is floored
    /// at two seconds — a sub-second loop would hammer every provider's files as fast as the disk
    /// allows, and this app has already shipped one runaway refresh.
    ///
    /// Only for a terminal: `--watch` with `--json`/`--csv`/`--md` is rejected at parse time,
    /// because a repeating stream gives its reader no way to tell one render from the next. When
    /// stdout is not a terminal the screen is never cleared, so a redirected run stays readable.
    private static func runBlocksWatch(
        language: TokenPilotLanguage,
        active: Bool,
        recent: Bool,
        since: Date?,
        until: Date?,
        days: Int?,
        provider: Provider?,
        calendar: Calendar,
        intervalSeconds: Int
    ) async -> Int32 {
        let interactive = isatty(FileHandle.standardOutput.fileDescriptor) == 1
        let interval = min(max(intervalSeconds, TokenPilotCLIService.watchIntervalRange.lowerBound), TokenPilotCLIService.watchIntervalRange.upperBound)

        while true {
            let assessments = await loadLatestCapacityAssessments()
            let body = TokenPilotCLIService.blocksText(
                assessments: assessments,
                language: language,
                active: active,
                recent: recent,
                since: since,
                until: until,
                days: days,
                provider: provider,
                calendar: calendar
            )
            var frame = ""
            if interactive {
                // Home the cursor and clear, rather than printing screens that scroll away.
                frame += "\u{001B}[H\u{001B}[2J"
            }
            frame += body + "\n"
            if interactive {
                frame += "\nRefreshing every \(interval)s · Ctrl-C to stop\n"
            }
            // Written and flushed rather than printed: stdout is block-buffered when it is not a
            // terminal, so `--watch > log.txt` or `| less` showed nothing at all until the buffer
            // filled — and anything still buffered was lost when the user pressed Ctrl-C.
            FileHandle.standardOutput.write(Data(frame.utf8))
            fflush(stdout)
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }
    }

    private static func writeError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

@MainActor
private final class TokenPilotAppDelegate: NSObject, NSApplicationDelegate {
    private let model: TokenPilotViewModel
    private let popover = NSPopover()
    private var standardStatusItem: NSStatusItem?
    private var combinedMetricsView: ProviderMetricsMenuBarNSView?
    private var separateMetricItems: [Provider: MetricStatusItem] = [:]
    private var separateTitleItems: [NSStatusItem] = []
    private weak var contextMenuButton: NSStatusBarButton?
    private var modelObservation: AnyCancellable?
    private var wakeObservation: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandlerRef: EventHandlerRef?
    private static let hotKeySignature: OSType = 0x54504B50
    private static let hotKeyID: UInt32 = 1
#if DEBUG
    private let debugAccessibilityProfile: TokenPilotDebugAccessibilityProfile?
#endif

    override init() {
#if DEBUG
        let debugFixture = TokenPilotDebugFixture.resolve()
        model = TokenPilotViewModel(debugFixture: debugFixture)
        debugAccessibilityProfile = TokenPilotDebugAccessibilityProfile.resolve()
#else
        model = TokenPilotViewModel()
#endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        configurePopover()
        configureStatusItem()
        observeSystemWake()
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
    }

    /// Refreshes on wake so the menu bar never shows pre-sleep percentages or a reset countdown that already elapsed.
    private func observeSystemWake() {
        wakeObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.model.refreshAfterSystemWake()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdownExperimentalOAuthWeekly()
        unregisterGlobalHotkey()
        if let wakeObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObservation)
        }
        wakeObservation = nil
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: TokenPilotDesign.popoverWidth, height: TokenPilotDesign.popoverHeight)
#if DEBUG
        let root = TokenPilotRootView(model: model)
            .frame(width: TokenPilotDesign.popoverWidth, height: TokenPilotDesign.popoverHeight)
            .onAppear { Task { await self.model.refreshAfterPopoverOpen() } }
            .tokenPilotSemanticPalette()
            .tokenPilotDebugAccessibilityProfile(debugAccessibilityProfile)
        popover.contentViewController = NSHostingController(rootView: root)
#else
        let root = TokenPilotRootView(model: model)
            .frame(width: TokenPilotDesign.popoverWidth, height: TokenPilotDesign.popoverHeight)
            .onAppear { Task { await self.model.refreshAfterPopoverOpen() } }
            .tokenPilotSemanticPalette()
        popover.contentViewController = NSHostingController(rootView: root)
#endif
    }

    private func configureStatusItem() {
        updateStatusItem()
    }

    private func updateStatusItem() {
        syncGlobalHotkey()
        let style = model.settings.menuBarDisplayStyle
        let grouping = model.settings.menuBarProviderGrouping

        guard style == .providerMetrics else {
            removeSeparateMetricItems()
            // "Separate items" used to apply to the provider-metrics layout only, so the text
            // layouts always packed every provider into one wide item no matter what the setting
            // said. They now split on the same seams the title was already joined from.
            let titleSegments = (grouping == .separate && style != .iconOnly)
                ? model.menuBarTitleSegments
                : []
            if titleSegments.count > 1 {
                reconcileSeparateTitleItems(segments: titleSegments)
            } else {
                removeSeparateTitleItems()
                updateStandardStatusItem()
            }
            return
        }

        removeSeparateTitleItems()
        let segments = model.menuBarMetricSegments
        switch grouping {
        case .combined:
            removeSeparateMetricItems()
            updateCombinedMetricsStatusItem(segments: segments)
        case .separate:
            reconcileSeparateMetricItems(segments: segments)
        }
    }

    private static let menuBarTitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.labelColor
    ]

    private func updateStandardStatusItem() {
        let statusItem = standardStatusItem ?? makeStatusItem()
        standardStatusItem = statusItem
        guard let button = statusItem.button else { return }

        combinedMetricsView?.removeFromSuperview()
        combinedMetricsView = nil
        button.title = ""
        button.attributedTitle = NSAttributedString(
            string: model.menuBarTitle,
            attributes: Self.menuBarTitleAttributes
        )
        button.toolTip = model.menuBarAccessibilityLabel
        button.setAccessibilityLabel(model.menuBarAccessibilityLabel)
        statusItem.length = NSStatusItem.variableLength
    }

    /// One status item per title segment, so a two-provider menu bar reads as two small
    /// items instead of one long line. Items are reused by position: the segment order is
    /// stable (primary, then secondary), and recreating them would make the whole group
    /// jump to the right edge of the menu bar on every refresh.
    private func reconcileSeparateTitleItems(segments: [MenuBarTitleSegment]) {
        removeStandardStatusItem()
        while separateTitleItems.count > segments.count {
            NSStatusBar.system.removeStatusItem(separateTitleItems.removeLast())
        }
        while separateTitleItems.count < segments.count {
            separateTitleItems.append(makeStatusItem())
        }
        for (statusItem, segment) in zip(separateTitleItems, segments) {
            guard let button = statusItem.button else { continue }
            button.title = ""
            button.attributedTitle = NSAttributedString(
                string: segment.text,
                attributes: Self.menuBarTitleAttributes
            )
            button.toolTip = segment.accessibilityLabel
            button.setAccessibilityLabel(segment.accessibilityLabel)
            statusItem.length = NSStatusItem.variableLength
        }
    }

    private func removeSeparateTitleItems() {
        for statusItem in separateTitleItems {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        separateTitleItems.removeAll()
    }

    private func updateCombinedMetricsStatusItem(segments: [MenuBarProviderMetricSegment]) {
        let statusItem = standardStatusItem ?? makeStatusItem()
        standardStatusItem = statusItem
        guard let button = statusItem.button else { return }

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = model.menuBarAccessibilityLabel
        button.setAccessibilityLabel(model.menuBarAccessibilityLabel)

        let view: ProviderMetricsMenuBarNSView
        if let combinedMetricsView {
            view = combinedMetricsView
            view.update(
                segments: segments,
                accessibilityLabel: model.menuBarAccessibilityLabel,
                trendStyle: model.settings.menuBarTrendStyle
            )
        } else {
            view = ProviderMetricsMenuBarNSView(
                segments: segments,
                accessibilityLabel: model.menuBarAccessibilityLabel,
                trendStyle: model.settings.menuBarTrendStyle
            )
            view.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            combinedMetricsView = view
        }
        statusItem.length = view.intrinsicContentSize.width + 8
    }

    private func reconcileSeparateMetricItems(segments: [MenuBarProviderMetricSegment]) {
        // Only remove an item when the provider is no longer selected for the menu bar at all.
        // A segment can be momentarily absent during refresh (snapshot sets publish in stages),
        // and dropping the NSStatusItem then would leave the provider invisible until restart.
        let enabledProviders = Set(segments.compactMap(\.provider))
            .union(separateMetricItems.keys)
            .filter { model.settings.effectiveMenuBarMetricProviders.contains($0) }
        for provider in Array(separateMetricItems.keys) where !enabledProviders.contains(provider) {
            removeSeparateMetricItem(for: provider)
        }

        for segment in segments {
            guard let provider = segment.provider else { continue }
            if let metricItem = separateMetricItems[provider] {
                metricItem.update(segment: segment, trendStyle: model.settings.menuBarTrendStyle)
            } else {
                separateMetricItems[provider] = MetricStatusItem(
                    statusItem: makeStatusItem(),
                    segment: segment,
                    trendStyle: model.settings.menuBarTrendStyle
                )
            }
        }

        if separateMetricItems.isEmpty {
            updateStandardStatusItem()
        } else {
            removeStandardStatusItem()
        }
    }

    private func makeStatusItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return statusItem }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return statusItem
    }

    private func removeStandardStatusItem() {
        combinedMetricsView?.removeFromSuperview()
        combinedMetricsView = nil
        guard let standardStatusItem else { return }
        NSStatusBar.system.removeStatusItem(standardStatusItem)
        self.standardStatusItem = nil
    }

    private func removeSeparateMetricItems() {
        for provider in Array(separateMetricItems.keys) {
            removeSeparateMetricItem(for: provider)
        }
    }

    private func removeSeparateMetricItem(for provider: Provider) {
        guard let metricItem = separateMetricItems.removeValue(forKey: provider) else { return }
        metricItem.remove()
        NSStatusBar.system.removeStatusItem(metricItem.statusItem)
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        let eventType = NSApp.currentEvent?.type
        if eventType == .rightMouseUp || eventType == .rightMouseDown {
            showContextMenu(for: button)
        } else {
            togglePopover(button)
        }
    }

    private func showContextMenu(for button: NSStatusBarButton) {
        contextMenuButton = button
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: model.t("Open TokenPilot"), action: #selector(openPopoverAction(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: model.t("Refresh"), action: #selector(refreshNowAction(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let copyItem = NSMenuItem(title: model.t("Copy summary"), action: #selector(copySummaryAction(_:)), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: model.t("Quit"), action: #selector(quitAction(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openPopoverAction(_ sender: Any?) {
        guard let button = contextMenuButton else { return }
        togglePopover(button)
    }

    @objc private func refreshNowAction(_ sender: Any?) {
        Task { @MainActor in
            await model.refresh(reason: .manual)
        }
    }

    @objc private func copySummaryAction(_ sender: Any?) {
        model.copyUsageSummaryToPasteboard()
    }

    @objc private func quitAction(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        togglePopover(using: button)
    }

    private func togglePopover(using button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func togglePopoverFromHotkey() {
        guard let button = standardStatusItem?.button else { return }
        togglePopover(using: button)
    }

    private func syncGlobalHotkey() {
        if model.settings.menuBarHotkeyEnabled {
            if hotKeyRef == nil {
                registerGlobalHotkey()
            }
        } else if hotKeyRef != nil {
            unregisterGlobalHotkey()
        }
    }

    private func registerGlobalHotkey() {
        unregisterGlobalHotkey()

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<TokenPilotAppDelegate>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    delegate.togglePopoverFromHotkey()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &hotKeyEventHandlerRef
        )
        guard handlerStatus == noErr else {
            hotKeyEventHandlerRef = nil
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey) | UInt32(shiftKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            if let hotKeyEventHandlerRef {
                RemoveEventHandler(hotKeyEventHandlerRef)
            }
            hotKeyEventHandlerRef = nil
            hotKeyRef = nil
        }
    }

    private func unregisterGlobalHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let hotKeyEventHandlerRef {
            RemoveEventHandler(hotKeyEventHandlerRef)
        }
        hotKeyEventHandlerRef = nil
    }
}

@MainActor
private final class MetricStatusItem {
    let statusItem: NSStatusItem
    private let metricsView: ProviderMetricsMenuBarNSView

    init(statusItem: NSStatusItem, segment: MenuBarProviderMetricSegment, trendStyle: MenuBarTrendStyle) {
        self.statusItem = statusItem
        metricsView = ProviderMetricsMenuBarNSView(
            segments: [segment],
            accessibilityLabel: segment.accessibilityLabel,
            trendStyle: trendStyle
        )
        guard let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = segment.accessibilityLabel
        button.setAccessibilityLabel(segment.accessibilityLabel)
        metricsView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(metricsView)
        NSLayoutConstraint.activate([
            metricsView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            metricsView.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        statusItem.length = metricsView.intrinsicContentSize.width + 8
    }

    func update(segment: MenuBarProviderMetricSegment, trendStyle: MenuBarTrendStyle) {
        metricsView.update(segments: [segment], accessibilityLabel: segment.accessibilityLabel, trendStyle: trendStyle)
        statusItem.button?.toolTip = segment.accessibilityLabel
        statusItem.button?.setAccessibilityLabel(segment.accessibilityLabel)
        statusItem.length = metricsView.intrinsicContentSize.width + 8
    }

    func remove() {
        metricsView.removeFromSuperview()
    }
}
private final class ProviderMetricsMenuBarNSView: NSView {
    private static let titleFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    private static let horizontalPadding: CGFloat = 3
    private static let segmentSpacing: CGFloat = 5
    // The 7pt label the block used to draw was below the legibility floor for a menu bar. Provider
    // labels are uppercase, so the title row only needs the ascent; giving back the unused descender
    // space pays for an 8pt label and an 11pt value while the block stays under the 22pt bar.
    private static let titleRowHeight = ceil(titleFont.ascender)
    private static let valueRowHeight = ceil(valueFont.ascender - valueFont.descender + valueFont.leading)
    private static let viewHeight = titleRowHeight + valueRowHeight

    private var segments: [MenuBarProviderMetricSegment]
    private var spokenLabel: String
    private var trendStyle: MenuBarTrendStyle

    init(segments: [MenuBarProviderMetricSegment], accessibilityLabel: String, trendStyle: MenuBarTrendStyle) {
        self.segments = segments
        spokenLabel = accessibilityLabel
        self.trendStyle = trendStyle
        super.init(frame: .zero)
        setAccessibilityElement(false)
        frame.size = intrinsicContentSize
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let widths = segments.map(segmentWidth)
        let spacing = Self.segmentSpacing * CGFloat(max(0, widths.count - 1))
        return NSSize(width: widths.reduce(0, +) + spacing, height: Self.viewHeight)
    }

    func update(segments: [MenuBarProviderMetricSegment], accessibilityLabel: String, trendStyle: MenuBarTrendStyle) {
        guard self.segments != segments || spokenLabel != accessibilityLabel || self.trendStyle != trendStyle else { return }
        self.segments = segments
        spokenLabel = accessibilityLabel
        self.trendStyle = trendStyle
        invalidateIntrinsicContentSize()
        frame.size = intrinsicContentSize
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 0
        for segment in segments {
            let width = segmentWidth(segment)
            draw(
                segment.providerShortLabel,
                in: NSRect(x: x, y: 0, width: width, height: Self.titleRowHeight),
                font: Self.titleFont,
                color: .secondaryLabelColor
            )
            draw(
                segment.displayValue,
                in: NSRect(
                    x: x,
                    y: Self.titleRowHeight,
                    width: width,
                    height: Self.valueRowHeight
                ),
                font: Self.valueFont,
                color: valueColor(segment.displayValue)
            )
            let trendRect = NSRect(x: x, y: Self.viewHeight - 3, width: width, height: 3)
            switch trendStyle {
            case .sparkline:
                if segment.sparklineValues.count >= 2 {
                    drawSparkline(
                        segment.sparklineValues,
                        in: trendRect,
                        color: valueColor(segment.displayValue)
                    )
                }
            case .bar:
                if let fraction = MenuBarGaugeService.remainingFraction(displayValue: segment.displayValue) {
                    drawBar(fraction: fraction, in: trendRect, color: valueColor(segment.displayValue))
                }
            case .off:
                break
            }
            x += width + Self.segmentSpacing
        }
    }

    private func drawSparkline(_ values: [Double], in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        let step = rect.width / CGFloat(values.count - 1)
        let bottom = rect.maxY
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) * step
            let y = bottom - CGFloat(min(max(value, 0), 1)) * rect.height
            if index == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        path.lineWidth = 1
        color.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }

    /// Remaining-quota bar: a dim full-width track with the remaining share filled in.
    private func drawBar(fraction: Double, in rect: NSRect, color: NSColor) {
        let track = NSRect(x: rect.minX + 1, y: rect.minY + 1, width: max(rect.width - 2, 0), height: rect.height - 1)
        guard track.width > 0 else { return }
        color.withAlphaComponent(0.22).setFill()
        NSBezierPath(rect: track).fill()
        let filledWidth = track.width * CGFloat(min(max(fraction, 0), 1))
        guard filledWidth > 0 else { return }
        color.withAlphaComponent(0.9).setFill()
        NSBezierPath(rect: NSRect(x: track.minX, y: track.minY, width: filledWidth, height: track.height)).fill()
    }

    private func segmentWidth(_ segment: MenuBarProviderMetricSegment) -> CGFloat {
        max(
            textWidth(segment.providerShortLabel, font: Self.titleFont),
            textWidth(segment.displayValue, font: Self.valueFont),
            24
        ) + Self.horizontalPadding * 2
    }

    private func textWidth(_ value: String, font: NSFont) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: font]).width)
    }

    private func draw(_ value: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        (value as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    /// Menu bar value color: the app's shared risk thresholds and the app's own
    /// palette, so the block agrees with the popover both on when to warn and on
    /// which hue means "healthy", and follows Increase Contrast like everything else.
    private func valueColor(_ value: String) -> NSColor {
        guard let remaining = MenuBarGaugeService.remainingPercent(displayValue: value) else {
            return .secondaryLabelColor
        }
        return TokenPilotDesign.riskNSColor(CapacityRisk.forRemainingPercent(remaining))
    }
}

#if DEBUG
private enum TokenPilotDebugAccessibilityProfile: String {
    case standard
    case reduceMotion
    case reduceTransparency
    case increaseContrast

    var reduceMotion: Bool {
        self == .reduceMotion
    }

    var reduceTransparency: Bool {
        self == .reduceTransparency
    }

    var colorSchemeContrast: ColorSchemeContrast {
        self == .increaseContrast ? .increased : .standard
    }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard environment["TOKENPILOT_UI_TESTING"] == "1" else { return nil }

        guard let rawProfile = environment["TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE"] else {
            return .standard
        }

        guard let profile = Self(rawValue: rawProfile) else {
            preconditionFailure("Invalid DEBUG TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE '\(rawProfile)'. Valid values: \(validProfileList).")
        }
        return profile
    }

    private static var validProfileList: String {
        [Self.standard, .reduceMotion, .reduceTransparency, .increaseContrast]
            .map(\.rawValue)
            .joined(separator: ", ")
    }
}

private extension View {
    @ViewBuilder
    func tokenPilotDebugAccessibilityProfile(_ profile: TokenPilotDebugAccessibilityProfile?) -> some View {
        if let profile {
            self.environment(\.tokenPilotReduceMotionOverride, profile.reduceMotion)
                .environment(\.tokenPilotReduceTransparencyOverride, profile.reduceTransparency)
                .environment(\.tokenPilotContrastOverride, profile.colorSchemeContrast)
        } else {
            self
        }
    }
}
#endif
