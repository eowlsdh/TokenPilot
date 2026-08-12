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
        case .success(.summary(let period, let includesJSON)):
            let settings = TokenPilotSettingsStore().load()
            let events = UsageHistoryStore().loadEvents()
            if includesJSON {
                do {
                    let data = try TokenPilotCLIService.summaryJSON(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period
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
                        language: .en,
                        period: period
                    )
                )
            }
            return 0
        case .success(.stats(let period, let since, let until, let days, let includesCost, let timeZone, let project, let includesJSON, let weekStartDay)):
            let settings = TokenPilotSettingsStore().load()
            let events = UsageHistoryStore().loadEvents()
            let calendar = cliCalendar(for: timeZone)
            let effectiveSince = weekStartDay.map { TokenPilotCLIService.weekStartDate($0, calendar: calendar) } ?? since
            if includesJSON {
                do {
                    let data = try TokenPilotCLIService.statsJSON(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        project: project,
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
                        language: .en,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        project: project,
                        calendar: calendar
                    )
                )
            }
            return 0
        case .success(.report(let period, let format, let since, let until, let days, let includesCost, let timeZone, let includesBreakdown, let project, let sections, let weekStartDay, let instances)):
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
                        calendar: calendar
                    )
                )
            case .text:
                print(
                    TokenPilotCLIService.reportText(
                        events: events,
                        enabledProviders: settings.enabledProviders,
                        language: .en,
                        period: period,
                        since: effectiveSince,
                        until: until,
                        days: days,
                        includesCost: includesCost,
                        includesBreakdown: includesBreakdown,
                        project: project,
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
            }
            return 0
        case .success(.audit(let includesJSON)):
            let events = UsageHistoryStore().loadEvents()
            if includesJSON {
                do {
                    let data = try TokenPilotCLIService.auditJSON(events: events)
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
                        language: .en
                    )
                )
            }
            return 0
        case .success(.blocks(let includesJSON, let active, let recent)):
            let assessments = await loadLatestCapacityAssessments()
            if includesJSON {
                do {
                    let data = try TokenPilotCLIService.blocksJSON(assessments: assessments, active: active, recent: recent)
                    FileHandle.standardOutput.write(data)
                    if data.last != 0x0A {
                        FileHandle.standardOutput.write(Data([0x0A]))
                    }
                } catch {
                    writeError("TokenPilot: blocks failed: \(error.localizedDescription)")
                    return 1
                }
            } else {
                print(TokenPilotCLIService.blocksText(assessments: assessments, active: active, recent: recent))
            }
            return 0
        case .success(.export(let format, let period, let outputPath, let includesCapacity, let since, let until, let days, let includesCost, let timeZone, let project, let weekStartDay)):
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
                weekStartDay: weekStartDay
            )
        }
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
        weekStartDay: WeekStartDay?
    ) async -> Int32 {
        let allEvents = UsageHistoryStore().loadEvents()
        let events = project.map { label in allEvents.filter { $0.projectLabel == label } } ?? allEvents
        let snapshots = Provider.allCases.map { provider in
            ProviderSnapshot(
                provider: provider,
                events: events.filter { $0.provider == provider }
            )
        }
        let calendar = cliCalendar(for: timeZone)
        let effectiveSince = weekStartDay.map { TokenPilotCLIService.weekStartDate($0, calendar: calendar) } ?? since
        let window = TokenPilotCLIService.explicitDateRange(period: period, since: effectiveSince, until: until, days: days, calendar: calendar)
        let usage = AggregationService().aggregate(
            snapshots: snapshots,
            period: period,
            customRange: window
        )
        do {
            let assessments = includesCapacity
                ? await loadLatestCapacityAssessments()
                : []
            let data = try UsageExportService().export(
                usage: usage,
                snapshots: snapshots,
                dataMode: "CLI",
                format: format,
                capacityAssessments: assessments,
                includesCost: includesCost
            )
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
    private weak var contextMenuButton: NSStatusBarButton?
    private var modelObservation: AnyCancellable?
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
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdownExperimentalOAuthWeekly()
        unregisterGlobalHotkey()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 620)
#if DEBUG
        let root = TokenPilotRootView(model: model)
            .frame(width: 420, height: 620)
            .onAppear { Task { await self.model.refreshAfterPopoverOpen() } }
            .tokenPilotSemanticPalette()
            .tokenPilotDebugAccessibilityProfile(debugAccessibilityProfile)
        popover.contentViewController = NSHostingController(rootView: root)
#else
        let root = TokenPilotRootView(model: model)
            .frame(width: 420, height: 620)
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
        let segments = model.menuBarMetricSegments
        guard model.settings.menuBarDisplayStyle == .providerMetrics else {
            removeSeparateMetricItems()
            updateStandardStatusItem()
            return
        }

        switch model.settings.menuBarProviderGrouping {
        case .combined:
            removeSeparateMetricItems()
            updateCombinedMetricsStatusItem(segments: segments)
        case .separate:
            reconcileSeparateMetricItems(segments: segments)
        }
    }

    private func updateStandardStatusItem() {
        let statusItem = standardStatusItem ?? makeStatusItem()
        standardStatusItem = statusItem
        guard let button = statusItem.button else { return }

        combinedMetricsView?.removeFromSuperview()
        combinedMetricsView = nil
        button.title = ""
        button.attributedTitle = NSAttributedString(
            string: model.menuBarTitle,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        button.toolTip = model.menuBarAccessibilityLabel
        button.setAccessibilityLabel(model.menuBarAccessibilityLabel)
        statusItem.length = NSStatusItem.variableLength
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
            view.update(segments: segments, accessibilityLabel: model.menuBarAccessibilityLabel)
        } else {
            view = ProviderMetricsMenuBarNSView(
                segments: segments,
                accessibilityLabel: model.menuBarAccessibilityLabel
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
        let providers = Set(segments.compactMap(\.provider))
        for provider in Array(separateMetricItems.keys) where !providers.contains(provider) {
            removeSeparateMetricItem(for: provider)
        }

        for segment in segments {
            guard let provider = segment.provider else { continue }
            if let metricItem = separateMetricItems[provider] {
                metricItem.update(segment: segment)
            } else {
                separateMetricItems[provider] = MetricStatusItem(
                    statusItem: makeStatusItem(),
                    segment: segment
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

    init(statusItem: NSStatusItem, segment: MenuBarProviderMetricSegment) {
        self.statusItem = statusItem
        metricsView = ProviderMetricsMenuBarNSView(
            segments: [segment],
            accessibilityLabel: segment.accessibilityLabel
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

    func update(segment: MenuBarProviderMetricSegment) {
        metricsView.update(segments: [segment], accessibilityLabel: segment.accessibilityLabel)
        statusItem.button?.toolTip = segment.accessibilityLabel
        statusItem.button?.setAccessibilityLabel(segment.accessibilityLabel)
        statusItem.length = metricsView.intrinsicContentSize.width + 8
    }

    func remove() {
        metricsView.removeFromSuperview()
    }
}
private final class ProviderMetricsMenuBarNSView: NSView {
    private static let titleFont = NSFont.monospacedSystemFont(ofSize: 7, weight: .medium)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
    private static let horizontalPadding: CGFloat = 3
    private static let segmentSpacing: CGFloat = 5
    private static let titleRowHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
    private static let valueRowHeight = ceil(valueFont.ascender - valueFont.descender + valueFont.leading)
    private static let viewHeight = titleRowHeight + valueRowHeight

    private var segments: [MenuBarProviderMetricSegment]
    private var spokenLabel: String

    init(segments: [MenuBarProviderMetricSegment], accessibilityLabel: String) {
        self.segments = segments
        spokenLabel = accessibilityLabel
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

    func update(segments: [MenuBarProviderMetricSegment], accessibilityLabel: String) {
        guard self.segments != segments || spokenLabel != accessibilityLabel else { return }
        self.segments = segments
        spokenLabel = accessibilityLabel
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
            if segment.sparklineValues.count >= 2 {
                drawSparkline(
                    segment.sparklineValues,
                    in: NSRect(x: x, y: Self.viewHeight - 3, width: width, height: 3),
                    color: valueColor(segment.displayValue)
                )
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

    private func valueColor(_ value: String) -> NSColor {
        guard let percentText = value.split(separator: "%").first,
              let percent = Int(percentText.filter(\.isNumber)) else {
            return .secondaryLabelColor
        }
        if percent <= 20 { return .systemRed }
        if percent <= 50 { return .systemOrange }
        return .systemBlue
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
