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
            guard isEnabled else { return false }
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                throw ApplyError.unregisterFailed(error.localizedDescription)
            }
            return true
        }
    }
}
