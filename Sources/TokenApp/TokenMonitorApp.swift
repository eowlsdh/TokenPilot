import SwiftUI
import AppKit

@main
struct TokenMonitorApp: App {
    @StateObject private var model: TokenPilotViewModel
#if DEBUG
    private let debugAccessibilityProfile: TokenPilotDebugAccessibilityProfile?
#endif

    init() {
#if DEBUG
        let debugFixture = TokenPilotDebugFixture.resolve()
        _model = StateObject(wrappedValue: TokenPilotViewModel(debugFixture: debugFixture))
        debugAccessibilityProfile = TokenPilotDebugAccessibilityProfile.resolve()
#else
        _model = StateObject(wrappedValue: TokenPilotViewModel())
#endif
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            productionRootView(model: model)
        } label: {
            productionMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private func productionRootView(model: TokenPilotViewModel) -> some View {
#if DEBUG
        TokenPilotRootView(model: model)
            .frame(width: 420, height: 620)
            .onAppear {
                Task { await model.refreshAfterPopoverOpen() }
            }
            .tokenPilotSemanticPalette()
            .tokenPilotDebugAccessibilityProfile(debugAccessibilityProfile)
#else
        TokenPilotRootView(model: model)
            .frame(width: 420, height: 620)
            .onAppear {
                Task { await model.refreshAfterPopoverOpen() }
            }
            .tokenPilotSemanticPalette()
#endif
    }

    @ViewBuilder
    private func productionMenuBarLabel(model: TokenPilotViewModel) -> some View {
        if model.settings.menuBarDisplayStyle == .providerMetrics {
            HStack(alignment: .center, spacing: 6) {
                ForEach(Array(model.menuBarMetricSegments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .center, spacing: -2) {
                        Text(segment.providerShortLabel)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                        Text(segment.displayValue)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(menuBarMetricColor(segment.displayValue))
                    }
                    .lineLimit(1)
                    .frame(minWidth: 28, alignment: .center)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(height: 20)
            .help(model.menuBarAccessibilityLabel)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.menuBarAccessibilityLabel)
        } else {
            Text(model.menuBarTitle)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false)
                .help(model.menuBarAccessibilityLabel)
                .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
    }

    private func menuBarMetricColor(_ value: String) -> Color {
        guard let percentText = value.split(separator: "%").first,
              let percent = Int(percentText.filter(\.isNumber)) else {
            return TokenPilotDesign.textSecondary
        }
        if percent <= 20 { return TokenPilotDesign.danger }
        if percent <= 50 { return TokenPilotDesign.warning }
        return TokenPilotDesign.calm
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
