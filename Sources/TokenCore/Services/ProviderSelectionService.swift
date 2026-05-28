import Foundation

public final class ProviderSelectionService: Sendable {
    public static let shared = ProviderSelectionService()

    private init() {}

    public func isProviderEnabled(_ provider: Provider, in settings: AppSettings) -> Bool {
        settings.monitoredProviders.enabledProviders.contains(provider)
    }

    public func enabledProviders(in settings: AppSettings) -> [Provider] {
        Provider.allCases.filter { isProviderEnabled($0, in: settings) }
    }

    public func toggleProvider(_ provider: Provider, in settings: inout AppSettings) {
        var enabled = settings.monitoredProviders.enabledProviders

        if enabled.contains(provider) {
            if enabled.count > 1 {
                enabled.remove(provider)
            }
            // Prevent deselecting all
        } else {
            enabled.insert(provider)
        }

        settings.monitoredProviders.enabledProviders = enabled
    }

    public func selectAll(in settings: inout AppSettings) {
        settings.monitoredProviders.enabledProviders = Set(Provider.allCases)
    }

    public func deselectAll(in settings: inout AppSettings) {
        // Do nothing — at least one must remain
    }

    public func canDeselect(_ provider: Provider, in settings: AppSettings) -> Bool {
        settings.monitoredProviders.enabledProviders.count > 1
    }
}