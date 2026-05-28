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
            HStack(spacing: 5) {
                if model.menuBarStatusLevel != .normal {
                    Circle()
                        .fill(model.menuBarStatusColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                if let provider = model.menuBarSnapshot?.provider {
                    MenuBarProviderMark(provider: provider)
                } else {
                    TokenPilotMenuBarMark()
                }
                Text(model.menuBarTitle)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .help(model.menuBarAccessibilityLabel)
            .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
