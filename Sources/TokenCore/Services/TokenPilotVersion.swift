import Foundation

/// Formats TokenPilot's bundle version for display. Kept in `TokenCore` so the
/// formatting contract is testable without a real app bundle.
public enum TokenPilotVersion {
    /// Compact "1.0.0 (1)" display string. Falls back to whichever value exists,
    /// and to "--" when neither does.
    public static func displayString(version: String?, build: String?) -> String {
        switch (version?.trimmingCharacters(in: .whitespacesAndNewlines), build?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty:
            return "\(version) (\(build))"
        case let (version?, _) where !version.isEmpty:
            return version
        case let (_, build?) where !build.isEmpty:
            return "(\(build))"
        default:
            return "--"
        }
    }

    /// Reads the running bundle's short version and build number.
    public static func current(bundle: Bundle = .main) -> String {
        displayString(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}
