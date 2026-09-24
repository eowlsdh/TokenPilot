import Foundation
import ServiceManagement

/// Manages the TokenPilot login item through `SMAppService`.
///
/// The system registration is the source of truth; `AppSettings.launchAtLogin` is a
/// presentation cache that the ViewModel syncs from `isEnabled` on startup and writes
/// only after `apply(_:)` succeeds.
public enum LaunchAtLoginService: Sendable {
    /// True when TokenPilot is registered as a login item.
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registered, but macOS is waiting for the user to allow it in System Settings → Login Items.
    /// Registration succeeds into this state, so treating it as "off" flipped the toggle back on the
    /// next launch with no word about the approval that was needed.
    public static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public enum ApplyError: Error, Equatable, Sendable {
        case registerFailed(String)
        case unregisterFailed(String)
    }

    /// Registers or unregisters the login item. Returns `true` when the state changed.
    @discardableResult
    public static func apply(_ enabled: Bool) throws -> Bool {
        if enabled {
            guard !isEnabled else { return false }
            do {
                try SMAppService.mainApp.register()
            } catch {
                throw ApplyError.registerFailed(error.localizedDescription)
            }
            return true
        } else {
            // A pending registration is still a registration; leaving it would let it take effect
            // after the user asked for it off.
            guard isEnabled || needsApproval else { return false }
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                throw ApplyError.unregisterFailed(error.localizedDescription)
            }
            return true
        }
    }
}
