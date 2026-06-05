import SwiftUI
import AppKit
import Combine
import TokenCore
import UniformTypeIdentifiers
import UserNotifications

@main
struct TokenMonitorApp: App {
    @StateObject private var model = TokenPilotViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            TokenPilotRootView(model: model)
                .frame(width: 420, height: 620)
                .onAppear {
                    Task { await model.refreshAfterPopoverOpen() }
                }
        } label: {
            Text(model.menuBarTitle)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false)
                .help(model.menuBarAccessibilityLabel)
                .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
