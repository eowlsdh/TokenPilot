import Foundation

public final class ProviderSelectionService: Sendable {
    public static let shared = ProviderSelectionService()

    private init() {}

    public func isProviderEnabled(_ provider: Provider, in settings: AppSettings) -> Bool {
        settings.isProviderEnabled(provider)
    }

    public func enabledProviders(in settings: AppSettings) -> [Provider] {
        settings.enabledProviders
    }

    public func toggleProvider(_ provider: Provider, in settings: inout AppSettings) {
        let shouldEnable = !settings.isProviderEnabled(provider)
        _ = settings.setProviderEnabled(provider, isEnabled: shouldEnable)
    }

    public func selectAll(in settings: inout AppSettings) {
        for provider in Provider.allCases {
            _ = settings.setProviderEnabled(provider, isEnabled: true)
        }
    }

    public func deselectAll(in settings: inout AppSettings) {
        guard let fallback = Provider.allCases.first else { return }
        _ = settings.setProviderEnabled(fallback, isEnabled: true)
        for provider in Provider.allCases where provider != fallback {
            _ = settings.setProviderEnabled(provider, isEnabled: false)
        }
    }

    public func canDeselect(_ provider: Provider, in settings: AppSettings) -> Bool {
        settings.enabledProviders.count > 1
    }
}