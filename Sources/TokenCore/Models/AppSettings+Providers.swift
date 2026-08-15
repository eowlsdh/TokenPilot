import Foundation

// MARK: - AppSettings Provider Helpers
// Extracted from AppSettings core struct for maintainability.

extension AppSettings {
    public var enabledProviders: [Provider] {
        let legacyEnabled = Set(Provider.allCases.filter { isLegacyProviderFlagEnabled($0) })
        let monitoredEnabled = monitoredProviders.enabledProviders
        let effective = monitoredEnabled.isEmpty ? legacyEnabled : legacyEnabled.intersection(monitoredEnabled)
        var fallback = !effective.isEmpty ? effective : (!legacyEnabled.isEmpty ? legacyEnabled : (!monitoredEnabled.isEmpty ? monitoredEnabled : Self.defaultEnabledProviders))
        // Default-on migration for provider sets persisted before DeepSeek existed:
        // old monitoredProviders can contain every legacy provider but not the new case.
        if deepseekEnabled,
           !fallback.contains(.deepseek),
           monitoredEnabled.isSuperset(of: Set([Provider.claude, .codex, .gemini])) {
            fallback.insert(.deepseek)
        }
        // Default-on migration for provider sets persisted before opencode/Kiro existed. Such a set
        // cannot mention them at all, so absence carries no user intent and the explicit flag decides.
        // This must not require any other provider to be monitored: a user who had disabled Gemini or
        // monitored only one provider would otherwise never receive the new providers.
        for provider in [Provider.opencode, .kiro]
        where isLegacyProviderFlagEnabled(provider) && !fallback.contains(provider) && !monitoredEnabled.contains(provider) {
            fallback.insert(provider)
        }
        // xAI requires an explicit local selection and must never arrive through defaults.
        if xaiEnabled || monitoredEnabled.contains(.xai) {
            fallback.insert(.xai)
        } else {
            fallback.remove(.xai)
        }
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
        case .codex, .deepseek, .xai, .opencode, .kiro, .jetbrains, .minimax, .zai, .openrouter:
            return nil
        }
    }

    public mutating func setLocalSourceBookmarkData(_ data: Data?, for provider: Provider) {
        switch provider {
        case .claude:
            claudeStatusFileBookmarkData = data
        case .gemini:
            geminiTelemetrySourceBookmarkData = data
        case .codex, .deepseek, .xai, .opencode, .kiro, .jetbrains, .minimax, .zai, .openrouter:
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

    private static var defaultEnabledProviders: Set<Provider> {
        [.claude, .codex, .gemini, .deepseek]
    }


    private func isLegacyProviderFlagEnabled(_ provider: Provider) -> Bool {
        switch provider {
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        case .gemini: return geminiEnabled
        case .deepseek: return deepseekEnabled
        case .xai: return xaiEnabled
        case .opencode: return opencodeEnabled
        case .kiro: return kiroEnabled
        case .jetbrains: return jetbrainsEnabled
        case .minimax: return minimaxEnabled
        case .zai: return zaiEnabled
        case .openrouter: return openrouterEnabled
        }
    }

    private mutating func applyEnabledProviders(_ providers: Set<Provider>) {
        let safeProviders = providers.isEmpty ? Self.defaultEnabledProviders : providers
        claudeEnabled = safeProviders.contains(.claude)
        codexEnabled = safeProviders.contains(.codex)
        geminiEnabled = safeProviders.contains(.gemini)
        deepseekEnabled = safeProviders.contains(.deepseek)
        xaiEnabled = safeProviders.contains(.xai)
        opencodeEnabled = safeProviders.contains(.opencode)
        kiroEnabled = safeProviders.contains(.kiro)
        jetbrainsEnabled = safeProviders.contains(.jetbrains)
        minimaxEnabled = safeProviders.contains(.minimax)
        zaiEnabled = safeProviders.contains(.zai)
        openrouterEnabled = safeProviders.contains(.openrouter)
        monitoredProviders.enabledProviders = safeProviders
    }
}

extension AppSettings {
    public var claudeUsageProbeEnabled: Bool {
        experimentalUsage.claudeProbeEnabled
    }

    public var codexUsageProbeEnabled: Bool {
        experimentalUsage.codexProbeEnabled
    }

    public var grokTierProbeEnabled: Bool {
        experimentalUsage.grokTierProbeEnabled
    }
}
