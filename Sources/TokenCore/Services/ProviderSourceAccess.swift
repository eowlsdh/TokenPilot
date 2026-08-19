import Foundation

/// Resolves the folders an adapter may read, honoring App Sandbox rules.
///
/// Outside the sandbox (the Developer ID build) the default home-relative paths are readable and
/// this is a pass-through. Inside the sandbox (the App Store entitlements) nothing under the user's
/// home is readable unless the user selected it, so a provider only reads through the read-only
/// security-scoped bookmark stored when they picked its folder. Access is started here and must be
/// released by the caller once the read finishes.
public enum ProviderSourceAccess {
    public struct Resolution {
        public let roots: [URL]
        public let scopedAccesses: [TokenPilotSecurityScopedResourceAccess]
        /// True when the sandbox is on and the provider has no granted folder, so the caller can say
        /// "choose the folder once" instead of the misleading "folder not found".
        public let needsUserGrant: Bool

        public func release() {
            for access in scopedAccesses {
                access.stop()
            }
        }
    }

    /// True when this process runs under App Sandbox. Fails closed: an unreadable entitlement is
    /// treated as sandboxed, so the app never assumes access it may not have.
    public static var isSandboxed: Bool {
        XAIExecutionCapability.current.isSandboxed
    }

    public static func resolve(
        provider: Provider,
        settings: AppSettings,
        defaults: [URL],
        sandboxed: Bool? = nil
    ) -> Resolution {
        let sandboxed = sandboxed ?? isSandboxed
        var roots: [URL] = []
        var accesses: [TokenPilotSecurityScopedResourceAccess] = []

        if let bookmark = settings.monitoredProviders.customBookmarks[provider] {
            let fallbackPath = settings.monitoredProviders.customPaths[provider]
            if let access = try? TokenPilotSecurityScopedBookmarks.resolve(bookmarkData: bookmark, fallbackPath: fallbackPath) {
                accesses.append(access)
                roots.append(access.url)
            }
        } else if let path = settings.monitoredProviders.customPaths[provider], !path.isEmpty {
            roots.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        }

        // A granted folder is authoritative; the defaults only apply where the process can read them.
        if roots.isEmpty {
            guard !sandboxed else {
                return Resolution(roots: [], scopedAccesses: [], needsUserGrant: true)
            }
            roots = defaults
        }
        return Resolution(roots: roots, scopedAccesses: accesses, needsUserGrant: false)
    }
}
