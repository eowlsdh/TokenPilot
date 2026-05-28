import Foundation

// MARK: - AppSettings Provider Helpers
// Extracted from AppSettings core struct for maintainability.

extension AppSettings {
    public var enabledProviders: [Provider] {
        let legacyEnabled = Set(Provider.allCases.filter { isLegacyProviderFlagEnabled($0) })
        let monitoredEnabled = monitoredProviders.enabledProviders
        let effective = monitoredEnabled.isEmpty ? legacyEnabled : legacyEnabled.intersection(monitoredEnabled)
        let fallback = !effective.isEmpty ? effective : (!legacyEnabled.isEmpty ? legacyEnabled : (!monitoredEnabled.isEmpty ? monitoredEnabled : Set(Provider.allCases)))
        return Provider.allCases.filter { fallback.contains($0) }
    }

    public func isProviderEnabled(_ provider: Provider) -> Bool {
        enabledProviders.contains(provider)
    }

    public func localSourceBookmarkData(for provider: Provider) -> Data? {
        switch provider {
        case .claude:
            return claudeStatusFileBookmarkData
        case .gemini:
            return geminiTelemetrySourceBookmarkData
        case .codex:
            return nil
        }
    }

    public mutating func setLocalSourceBookmarkData(_ data: Data?, for provider: Provider) {
        switch provider {
        case .claude:
            claudeStatusFileBookmarkData = data
        case .gemini:
            geminiTelemetrySourceBookmarkData = data
        case .codex:
            break
        }
    }

    @discardableResult
    public mutating func setProviderEnabled(_ provider: Provider, isEnabled: Bool) -> Bool {
        var next = Set(enabledProviders)
        if isEnabled {
            next.insert(provider)
        } else {
            guard next.count > 1 else { return false }
            next.remove(provider)
        }
        applyEnabledProviders(next)
        return true
    }

    public mutating func normalizeProviderEnablement() {
        applyEnabledProviders(Set(enabledProviders))
    }

    // MARK: - Private helpers

    private func isLegacyProviderFlagEnabled(_ provider: Provider) -> Bool {
        switch provider {
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        case .gemini: return geminiEnabled
        }
    }

    private mutating func applyEnabledProviders(_ providers: Set<Provider>) {
        let safeProviders = providers.isEmpty ? Set(Provider.allCases) : providers
        claudeEnabled = safeProviders.contains(.claude)
        codexEnabled = safeProviders.contains(.codex)
        geminiEnabled = safeProviders.contains(.gemini)
        monitoredProviders.enabledProviders = safeProviders
    }
}
