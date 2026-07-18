import SwiftUI
import AppKit
import Combine
import TokenCore

@main
struct TokenMonitorApp: App {
    @NSApplicationDelegateAdaptor(TokenPilotAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class TokenPilotAppDelegate: NSObject, NSApplicationDelegate {
    private let model: TokenPilotViewModel
    private let popover = NSPopover()
    private var standardStatusItem: NSStatusItem?
    private var combinedMetricsView: ProviderMetricsMenuBarNSView?
    private var separateMetricItems: [Provider: MetricStatusItem] = [:]
    private var modelObservation: AnyCancellable?
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
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
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

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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
            x += width + Self.segmentSpacing
        }
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
