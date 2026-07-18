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
    private var statusItem: NSStatusItem?
    private var modelObservation: AnyCancellable?
    private var metricsView: ProviderMetricsMenuBarNSView?
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let statusItem, let button = statusItem.button else { return }
        button.toolTip = model.menuBarAccessibilityLabel
        button.setAccessibilityLabel(model.menuBarAccessibilityLabel)

        if model.settings.menuBarDisplayStyle == .providerMetrics {
            button.title = ""
            let view: ProviderMetricsMenuBarNSView
            if let metricsView {
                view = metricsView
                view.update(segments: model.menuBarMetricSegments, accessibilityLabel: model.menuBarAccessibilityLabel)
            } else {
                view = ProviderMetricsMenuBarNSView(
                    segments: model.menuBarMetricSegments,
                    accessibilityLabel: model.menuBarAccessibilityLabel
                )
                view.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(view)
                NSLayoutConstraint.activate([
                    view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                    view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    view.heightAnchor.constraint(equalToConstant: view.intrinsicContentSize.height),
                    view.widthAnchor.constraint(equalToConstant: view.intrinsicContentSize.width)
                ])
                metricsView = view
            }
            statusItem.length = view.intrinsicContentSize.width + 8
        } else {
            metricsView?.removeFromSuperview()
            metricsView = nil
            button.attributedTitle = NSAttributedString(
                string: model.menuBarTitle,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            statusItem.length = NSStatusItem.variableLength
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

private final class ProviderMetricsMenuBarNSView: NSView {
    private static let titleFont = NSFont.monospacedSystemFont(ofSize: 7, weight: .medium)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
    private static let horizontalPadding: CGFloat = 3
    private static let segmentSpacing: CGFloat = 5
    private static let viewHeight: CGFloat = 18

    private var segments: [MenuBarProviderMetricSegment]
    private var spokenLabel: String

    init(segments: [MenuBarProviderMetricSegment], accessibilityLabel: String) {
        self.segments = segments
        spokenLabel = accessibilityLabel
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityLabel)
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
        setAccessibilityLabel(accessibilityLabel)
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
                in: NSRect(x: x, y: 0, width: width, height: 8),
                font: Self.titleFont,
                color: .secondaryLabelColor
            )
            draw(
                segment.displayValue,
                in: NSRect(x: x, y: 8, width: width, height: 10),
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
