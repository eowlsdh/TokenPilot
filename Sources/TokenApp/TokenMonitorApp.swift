import SwiftUI
import AppKit

@main
struct TokenMonitorApp: App {
    @StateObject private var model: TokenPilotViewModel

    init() {
#if DEBUG
        _model = StateObject(wrappedValue: TokenPilotViewModel(debugFixture: TokenPilotDebugFixture.resolve()))
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
        TokenPilotRootView(model: model)
            .frame(width: 420, height: 620)
            .onAppear {
                Task { await model.refreshAfterPopoverOpen() }
            }
    }

    @ViewBuilder
    private func productionMenuBarLabel(model: TokenPilotViewModel) -> some View {
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
