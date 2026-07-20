import Foundation

public enum MenuBarStatusLevel: String, Sendable {
    case normal
    case warning
    case critical
}

public struct MenuBarLowestRemainingSummary: Equatable, Sendable {
    public var provider: Provider
    public var remainingPercent: Int

    public var displayText: String {
        "\(provider.shortName) \(remainingPercent)%"
    }

    public init(provider: Provider, remainingPercent: Int) {
        self.provider = provider
        self.remainingPercent = min(max(remainingPercent, 0), 100)
    }
}
public struct MenuBarProviderMetricSegment: Equatable, Sendable {
    public let provider: Provider?
    public let providerShortLabel: String
    public let displayValue: String
    public let accessibilityLabel: String

    public init(provider: Provider?, providerShortLabel: String, displayValue: String, accessibilityLabel: String) {
        self.provider = provider
        self.providerShortLabel = providerShortLabel
        self.displayValue = displayValue
        self.accessibilityLabel = accessibilityLabel
    }
}


public final class MenuBarStatusService: @unchecked Sendable {
    private enum CandidateKind: Equatable, Sendable {
        case percent
        case money
        case info
    }

    private struct Candidate: Sendable {
        var snapshot: ProviderSnapshot
        var kind: CandidateKind
        var rank: Int
        var usedPercent: Int?
        var remainingPercent: Int?
        var resetAt: Date?
        var durationMinutes: Int?
        var seriesID: String
        var suffix: String
        var authority: String
        var stability: String
        var freshness: String
        var action: String
    }

    private struct SelectionMemory: Sendable {
        var provider: Provider
        var rank: Int
        var usedPercent: Int?
        var selectedAt: Date
    }

    private let memoryLock = NSLock()
    private var memory: SelectionMemory?

    public init() {}

    public func selectedSnapshot(
        from snapshots: [ProviderSnapshot],
        settings: AppSettings,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> ProviderSnapshot? {
        selectedCandidate(
            from: snapshots,
            settings: settings,
            now: Date(),
            xaiOAuthResult: xaiOAuthResult
        )?.snapshot
    }

    public func presentationSnapshots(from snapshots: [ProviderSnapshot], settings: AppSettings) -> [ProviderSnapshot] {
        var displaySnapshots = snapshots
            .filter { settings.isProviderEnabled($0.provider) }
            .map { snapshotWithCodexManualMenuBarFallback($0, settings: settings) ?? $0 }

        if settings.isProviderEnabled(.codex),
           !displaySnapshots.contains(where: { $0.provider == .codex }),
           let manual = codexManualMenuBarSnapshot(settings: settings) {
            displaySnapshots.append(manual)
        }

        return displaySnapshots.sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    public func displayWindow(for snapshot: ProviderSnapshot) -> LimitWindow? {
        if snapshot.provider == .xai {
            guard snapshot.isExperimental,
                  snapshot.dataSource == .experimentalCLI else {
                return nil
            }
            return snapshot.monthly
        }
        if let fiveHour = snapshot.fiveHour { return fiveHour }
        if let weekly = snapshot.weekly { return weekly }
        if let dailyRequestsPercent = snapshot.dailyRequestsPercent {
            return LimitWindow(kind: .dailyRequests, usedPercent: dailyRequestsPercent, confidence: snapshot.confidence)
        }
        return nil
    }

    public func title(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        modeLabel: String,
        now: Date = Date(),
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> String {
        switch settings.menuBarDisplayStyle {
        case .iconOnly:
            return "TP"
        case .providerMetrics:
            return providerMetricsTitle(
                snapshots: snapshots,
                settings: settings,
                now: now,
                xaiOAuthResult: xaiOAuthResult
            )
        case .detailed where !settings.menuBarShowsSecondaryProvider:
            return detailedTitle(
                snapshots: snapshots,
                settings: settings,
                modeLabel: modeLabel,
                now: now,
                xaiOAuthResult: xaiOAuthResult
            )
        case .detailed, .compact:
            return compactTitle(
                snapshots: snapshots,
                settings: settings,
                now: now,
                xaiOAuthResult: xaiOAuthResult
            )
        }
    }

    public func providerMetricsSegments(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        now: Date = Date(),
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> [MenuBarProviderMetricSegment] {
        let candidates = providerMetricsCandidates(
            from: snapshots,
            settings: settings,
            xaiOAuthResult: xaiOAuthResult
        )
        let providers = settings.effectiveMenuBarMetricProviders

        return providers.map { provider in
            let candidate = representativeCandidate(from: candidates.filter { $0.snapshot.provider == provider })
            return providerMetricSegment(provider: provider, candidate: candidate, settings: settings)
        }
    }

    private func detailedTitle(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        modeLabel: String,
        now: Date,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> String {
        let candidates = allCandidates(from: snapshots, settings: settings, xaiOAuthResult: xaiOAuthResult)
        if let target = settings.menuBarDisplayTarget,
           settings.isProviderEnabled(target),
           !candidates.contains(where: { $0.snapshot.provider == target }) {
            return targetedFallbackTitle(for: target, settings: settings, modeLabel: modeLabel)
        }
        guard let candidate = selectedCandidate(from: candidates, settings: settings, now: now) else {
            return "TP · \(modeLabel)"
        }

        switch candidate.kind {
        case .percent:
            let segments = percentRenderCandidates(for: candidate, in: candidates)
                .prefix(2)
                .map { percentSegment(for: $0) }
            guard !segments.isEmpty else { return "\(candidate.snapshot.provider.shortName) · \(modeLabel)" }
            return segments.joined(separator: " · ")
        case .money:
            let suffix = candidate.suffix.isEmpty ? "" : " \(candidate.suffix)"
            if let balance = candidate.snapshot.balance {
                return "\(candidate.snapshot.provider.shortName) \(DeepSeekBalanceFormatter.display(balance))\(suffix)"
            }
            return "\(candidate.snapshot.provider.shortName) · \(modeLabel)"
        case .info:
            if candidate.snapshot.provider == .codex {
                return "\(candidate.snapshot.provider.shortName) --%"
            }
            if candidate.snapshot.todayTokens > 0 {
                let tokenUnit = TokenPilotLocalizer.localized("tok", language: settings.localization.language)
                return "\(candidate.snapshot.provider.shortName) \(TokenPilotFormatters.compactNumber(candidate.snapshot.todayTokens))\(tokenUnit)"
            }
            if let used = candidate.snapshot.dailyRequestsUsed {
                return "\(candidate.snapshot.provider.shortName) \(TokenPilotFormatters.compactNumber(used))req"
            }
            return "\(candidate.snapshot.provider.shortName) · \(modeLabel)"
        }
    }

    private func compactTitle(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        now: Date,
        separator: String = " · ",
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> String {
        let candidates = allCandidates(from: snapshots, settings: settings, xaiOAuthResult: xaiOAuthResult)
        let selectedTarget = settings.menuBarDisplayTarget.flatMap { settings.isProviderEnabled($0) ? $0 : nil }
        let primaryCandidate = compactPrimaryCandidate(
            from: candidates,
            selectedTarget: selectedTarget,
            settings: settings,
            now: now
        )
        let primaryProvider = selectedTarget ?? primaryCandidate?.snapshot.provider
        var segments = [compactSegment(provider: primaryProvider, candidate: primaryCandidate, settings: settings)]

        if settings.menuBarShowsSecondaryProvider,
           let secondary = settings.menuBarSecondaryDisplayTarget,
           settings.isProviderEnabled(secondary),
           secondary != primaryProvider {
            let secondaryCandidate = representativeCandidate(from: candidates.filter { $0.snapshot.provider == secondary })
            segments.append(compactSegment(provider: secondary, candidate: secondaryCandidate, settings: settings))
        }
        return segments.joined(separator: separator)
    }

    private func providerMetricsTitle(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        now: Date,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> String {
        providerMetricsSegments(
            snapshots: snapshots,
            settings: settings,
            now: now,
            xaiOAuthResult: xaiOAuthResult
        )
            .map { "\($0.providerShortLabel) \($0.displayValue)" }
            .joined(separator: "  ")
    }

    private func providerMetricSegment(
        provider: Provider?,
        candidate: Candidate?,
        settings: AppSettings
    ) -> MenuBarProviderMetricSegment {
        guard let provider else {
            return MenuBarProviderMetricSegment(provider: nil, providerShortLabel: "TP", displayValue: "Setup", accessibilityLabel: "TokenPilot, \(localized("Setup", language: settings.localization.language))")
        }

        if provider == .xai {
            if let candidate,
               candidate.authority == "experimental-oauth-weekly",
               candidate.kind == .percent,
               let remaining = candidate.remainingPercent,
               let used = candidate.usedPercent {
                let isStale = candidate.freshness == "stale"
                var accessibilityParts = [
                    localized("Grok Build", language: settings.localization.language),
                    localized("xai.oauth.status.experimental_weekly", language: settings.localization.language),
                    "\(localized("Remaining", language: settings.localization.language)) \(remaining)%",
                    "\(localized("Used", language: settings.localization.language)) \(used)%",
                    localized("EXPERIMENTAL", language: settings.localization.language),
                    localized("Unofficial", language: settings.localization.language)
                ]
                if isStale {
                    accessibilityParts.append(localized("Stale", language: settings.localization.language))
                }
                return MenuBarProviderMetricSegment(
                    provider: provider,
                    providerShortLabel: "GROK",
                    displayValue: isStale ? "\(remaining)%·ES" : "\(remaining)%·E",
                    accessibilityLabel: accessibilityParts.joined(separator: ", ")
                )
            }
            if let candidate,
               candidate.authority == "user-entered",
               candidate.seriesID.hasSuffix("/weekly-manual"),
               let remaining = candidate.remainingPercent,
               let used = candidate.usedPercent {
                let isStale = candidate.freshness == "stale"
                var accessibilityParts = [
                    localized("Grok Build", language: settings.localization.language),
                    localized("Manual weekly limit", language: settings.localization.language),
                    "\(localized("Remaining", language: settings.localization.language)) \(remaining)%",
                    "\(localized("Used", language: settings.localization.language)) \(used)%",
                    localized("Not automatic Orca-style session import", language: settings.localization.language)
                ]
                if isStale {
                    accessibilityParts.append(localized("Stale", language: settings.localization.language))
                }
                return MenuBarProviderMetricSegment(
                    provider: provider,
                    providerShortLabel: "GROK",
                    displayValue: isStale ? "\(remaining)%·MS" : "\(remaining)%·M",
                    accessibilityLabel: accessibilityParts.joined(separator: ", ")
                )
            }
            if let candidate,
               candidate.authority == "local-context",
               let remaining = candidate.remainingPercent,
               let used = candidate.usedPercent {
                let isStale = candidate.freshness == "stale"
                var accessibilityParts = [
                    localized(provider.displayName, language: settings.localization.language),
                    localized("LOCAL · Grok Build context window", language: settings.localization.language),
                    localized("Not subscription quota", language: settings.localization.language),
                    "\(localized("Remaining", language: settings.localization.language)) \(remaining)%",
                    "\(localized("Used", language: settings.localization.language)) \(used)%"
                ]
                if isStale {
                    accessibilityParts.append(localized("Stale", language: settings.localization.language))
                }
                return MenuBarProviderMetricSegment(
                    provider: provider,
                    providerShortLabel: "GROK CTX",
                    displayValue: isStale ? "\(remaining)%·S" : "\(remaining)%",
                    accessibilityLabel: accessibilityParts.joined(separator: ", ")
                )
            }
            if let candidate,
               isExperimentalOpenCodeBarPercentage(candidate),
               let remaining = candidate.remainingPercent {
                return MenuBarProviderMetricSegment(
                    provider: provider,
                    providerShortLabel: providerMetricLabel(provider),
                    displayValue: "\(remaining)%·\(candidate.freshness == "stale" ? "ES" : "E")",
                    accessibilityLabel: [
                        localized(provider.displayName, language: settings.localization.language),
                        localizedRemaining(remaining, language: settings.localization.language),
                        localizedStability(candidate.stability, language: settings.localization.language),
                        localized("Unofficial", language: settings.localization.language),
                        localized("Monthly", language: settings.localization.language),
                        localizedFreshness(candidate.freshness, language: settings.localization.language)
                    ].joined(separator: ", ")
                )
            }
            if settings.xAI.usageSource == .experimentalOpenCodeBarCLI {
                return MenuBarProviderMetricSegment(
                    provider: provider,
                    providerShortLabel: providerMetricLabel(provider),
                    displayValue: "—·E",
                    accessibilityLabel: [
                        localized(provider.displayName, language: settings.localization.language),
                        localized("Experimental connector", language: settings.localization.language),
                        localized("Unofficial", language: settings.localization.language),
                        localized("Unavailable", language: settings.localization.language)
                    ].joined(separator: ", ")
                )
            }
            let marker = xAIManagementSetupConfigured(settings) ? "Setup" : "Unavailable"
            return MenuBarProviderMetricSegment(
                provider: provider,
                providerShortLabel: providerMetricLabel(provider),
                displayValue: "—",
                accessibilityLabel: "\(localized(provider.displayName, language: settings.localization.language)), \(localized(marker, language: settings.localization.language))"
            )
        }

        guard let candidate else {
            return MenuBarProviderMetricSegment(provider: provider, providerShortLabel: providerMetricLabel(provider), displayValue: "—", accessibilityLabel: "\(localized(provider.displayName, language: settings.localization.language)), \(localized("Setup", language: settings.localization.language))")
        }
        if candidate.kind == .percent, candidate.authority == "provider-reported",
           let remaining = candidate.remainingPercent {
            return MenuBarProviderMetricSegment(
                provider: provider,
                providerShortLabel: providerMetricLabel(provider),
                displayValue: "\(remaining)%",
                accessibilityLabel: [
                    localized(provider.displayName, language: settings.localization.language),
                    localizedRemaining(remaining, language: settings.localization.language),
                    localizedAuthority(candidate.authority, language: settings.localization.language),
                    localizedStability(candidate.stability, language: settings.localization.language),
                    localizedFreshness(candidate.freshness, language: settings.localization.language)
                ].joined(separator: ", ")
            )
        }
        if candidate.kind == .money, let balance = candidate.snapshot.balance {
            let value = DeepSeekBalanceFormatter.display(balance)
            return MenuBarProviderMetricSegment(
                provider: provider,
                providerShortLabel: providerMetricLabel(provider),
                displayValue: "\(value)\(candidate.suffix.isEmpty ? "" : " \(candidate.suffix)")",
                accessibilityLabel: [
                    localized(provider.displayName, language: settings.localization.language),
                    "\(localized("Balance", language: settings.localization.language)) \(value)",
                    localizedAuthority(candidate.authority, language: settings.localization.language),
                    localizedStability(candidate.stability, language: settings.localization.language),
                    localizedFreshness(candidate.freshness, language: settings.localization.language)
                ].joined(separator: ", ")
            )
        }
        let marker: String
        switch candidate.authority {
        case "user-entered":
            marker = "Manual"
        case "local-derived":
            marker = "Local"
        default:
            marker = "Unavailable"
        }
        return MenuBarProviderMetricSegment(
            provider: provider,
            providerShortLabel: providerMetricLabel(provider),
            displayValue: marker,
            accessibilityLabel: "\(localized(provider.displayName, language: settings.localization.language)), \(localized(marker, language: settings.localization.language))"
        )
    }

    private func providerMetricLabel(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "CLAUDE"
        case .codex: return "CODEX"
        case .gemini: return "ANTIGRAVITY"
        case .deepseek: return "DEEPSEEK"
        case .xai: return "GROK CTX"
        }
    }


    private func compactSegment(provider: Provider?, candidate: Candidate?, settings: AppSettings) -> String {
        guard let provider else { return "TP Setup" }
        if provider == .xai {
            if let candidate,
               candidate.authority == "experimental-oauth-weekly",
               let remaining = candidate.remainingPercent {
                let suffix = candidate.suffix.isEmpty ? "" : " \(candidate.suffix)"
                return "\(provider.shortName) \(remaining)%\(suffix)"
            }
            if let candidate,
               candidate.authority == "user-entered",
               let remaining = candidate.remainingPercent {
                let suffix = candidate.suffix.isEmpty ? "" : " \(candidate.suffix)"
                return "\(provider.shortName) \(remaining)%\(suffix)"
            }
            if let candidate,
               candidate.authority == "local-context",
               let remaining = candidate.remainingPercent {
                return "\(provider.shortName) \(remaining)%"
            }
            return xAIManagementSetupConfigured(settings) ? "xAI Setup" : "xAI Unavailable"
        }
        guard let candidate else { return "\(provider.shortName) Setup" }
        if candidate.kind == .percent, candidate.authority == "provider-reported",
           let remaining = candidate.remainingPercent {
            let suffix = candidate.suffix.isEmpty ? "" : " \(candidate.suffix)"
            return "\(provider.shortName) \(remaining)%\(suffix)"
        }
        if candidate.kind == .money, let balance = candidate.snapshot.balance {
            return "\(provider.shortName) \(DeepSeekBalanceFormatter.display(balance))"
        }
        switch candidate.authority {
        case "user-entered":
            return "\(provider.shortName) Manual"
        case "local-derived":
            return "\(provider.shortName) Local"
        default:
            return "\(provider.shortName) Unavailable"
        }
    }

    public func statusLevel(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> MenuBarStatusLevel {
        guard let candidate = selectedCandidate(
            from: snapshots,
            settings: settings,
            now: Date(),
            xaiOAuthResult: xaiOAuthResult
        ),
              candidate.kind == .percent,
              candidate.rank < 8,
              let percent = candidate.usedPercent else {
            return .normal
        }
        if percent >= 85 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }

    public func shouldShowStatusDot(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> Bool {
        statusLevel(snapshots: snapshots, settings: settings, xaiOAuthResult: xaiOAuthResult) != .normal
    }

    public func lowestRemainingSummary(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> MenuBarLowestRemainingSummary? {
        allCandidates(from: snapshots, settings: settings, xaiOAuthResult: xaiOAuthResult)
            .filter { $0.kind == .percent && $0.rank < 8 }
            .compactMap { candidate -> MenuBarLowestRemainingSummary? in
                candidate.remainingPercent.map {
                    MenuBarLowestRemainingSummary(provider: candidate.snapshot.provider, remainingPercent: $0)
                }
            }
            .min { lhs, rhs in lhs.remainingPercent < rhs.remainingPercent }
    }

    public func accessibilityLabel(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        modeLabel: String,
        now: Date = Date(),
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> String {
        let language = settings.localization.language
        if settings.menuBarDisplayStyle == .providerMetrics {
            let segments = providerMetricsSegments(
                snapshots: snapshots,
                settings: settings,
                now: now,
                xaiOAuthResult: xaiOAuthResult
            )
                .map(\.accessibilityLabel)
                .joined(separator: ", ")
            return "TokenPilot, \(segments)"
        }
        if settings.menuBarDisplayStyle != .detailed || settings.menuBarShowsSecondaryProvider {
            return compactAccessibilityLabel(
                snapshots: snapshots,
                settings: settings,
                now: now,
                language: language,
                xaiOAuthResult: xaiOAuthResult
            )
        }

        if settings.menuBarDisplayTarget == .xai,
           settings.isProviderEnabled(.xai),
           xaiOAuthResult == nil {
            return "TokenPilot, \(targetedXAIStatusTitle(settings: settings, language: language))"
        }

        let visualTitle = accessibilityTitle(
            title(
                snapshots: snapshots,
                settings: settings,
                modeLabel: modeLabel,
                now: now,
                xaiOAuthResult: xaiOAuthResult
            ),
            modeLabel: modeLabel,
            language: language
        )
        guard let candidate = selectedCandidate(
            from: snapshots,
            settings: settings,
            now: now,
            xaiOAuthResult: xaiOAuthResult
        ) else {
            return "TokenPilot, \(visualTitle)"
        }

        var parts = [
            "TokenPilot",
            localized(candidate.snapshot.provider.displayName, language: language),
            visualTitle
        ]
        if let remaining = candidate.remainingPercent {
            parts.append(localizedRemaining(remaining, language: language))
        }
        if let resetAt = candidate.resetAt, resetAt > now {
            parts.append(localizedReset(until: resetAt, now: now, language: language))
        }
        parts.append(localizedAuthority(candidate.authority, language: language))
        parts.append(localizedStability(candidate.stability, language: language))
        parts.append(localizedFreshness(candidate.freshness, language: language))
        parts.append(localizedAction(candidate.action, language: language))
        parts.append(localizedModeLabel(modeLabel, language: language))
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func compactAccessibilityLabel(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        now: Date,
        language: TokenPilotLanguage,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> String {
        let candidates = allCandidates(
            from: snapshots,
            settings: settings,
            xaiOAuthResult: xaiOAuthResult
        )
        let selectedTarget = settings.menuBarDisplayTarget.flatMap { settings.isProviderEnabled($0) ? $0 : nil }
        let primaryCandidate = compactPrimaryCandidate(
            from: candidates,
            selectedTarget: selectedTarget,
            settings: settings,
            now: now
        )
        let primaryProvider = selectedTarget ?? primaryCandidate?.snapshot.provider
        var parts = ["TokenPilot", compactAccessibilitySegment(provider: primaryProvider, candidate: primaryCandidate, settings: settings, language: language)]

        if settings.menuBarShowsSecondaryProvider,
           let secondary = settings.menuBarSecondaryDisplayTarget,
           settings.isProviderEnabled(secondary),
           secondary != primaryProvider {
            let secondaryCandidate = representativeCandidate(from: candidates.filter { $0.snapshot.provider == secondary })
            parts.append(compactAccessibilitySegment(provider: secondary, candidate: secondaryCandidate, settings: settings, language: language))
        }
        return parts.joined(separator: ", ")
    }

    private func compactAccessibilitySegment(
        provider: Provider?,
        candidate: Candidate?,
        settings: AppSettings,
        language: TokenPilotLanguage
    ) -> String {
        guard let provider else { return localized("Menu bar data unavailable", language: language) }
        let name = localized(provider.displayName, language: language)
        if provider == .xai, candidate == nil {
            return "\(name), \(targetedXAIStatusTitle(settings: settings, language: language))"
        }
        guard let candidate else { return "\(name), \(localized("Unavailable", language: language))" }
        if candidate.kind == .percent, candidate.authority == "provider-reported",
           let remaining = candidate.remainingPercent {
            return "\(name), \(localizedRemaining(remaining, language: language)), \(localizedAuthority(candidate.authority, language: language))"
        }
        if candidate.kind == .money, let balance = candidate.snapshot.balance {
            return "\(name), \(localized("Balance", language: language)) \(DeepSeekBalanceFormatter.display(balance)), \(localizedAuthority(candidate.authority, language: language))"
        }
        return "\(name), \(localizedAuthority(candidate.authority, language: language))"
    }
    private func compactPrimaryCandidate(
        from candidates: [Candidate],
        selectedTarget: Provider?,
        settings: AppSettings,
        now: Date
    ) -> Candidate? {
        if let selectedTarget {
            return representativeCandidate(from: candidates.filter { $0.snapshot.provider == selectedTarget })
        }

        let candidatesExcludingSecondary: [Candidate]
        if settings.menuBarShowsSecondaryProvider,
           let secondary = settings.menuBarSecondaryDisplayTarget,
           settings.isProviderEnabled(secondary) {
            candidatesExcludingSecondary = candidates.filter { $0.snapshot.provider != secondary }
        } else {
            candidatesExcludingSecondary = candidates
        }
        return selectedCandidate(
            from: candidatesExcludingSecondary.isEmpty ? candidates : candidatesExcludingSecondary,
            settings: settings,
            now: now
        )
    }

    private func localized(_ key: String, language: TokenPilotLanguage) -> String {
        TokenPilotLocalizer.localized(key, language: language)
    }

    private func targetedFallbackTitle(for target: Provider, settings: AppSettings, modeLabel: String) -> String {
        switch target {
        case .codex:
            return "\(target.shortName) --%"
        case .xai:
            return targetedXAIStatusTitle(settings: settings, language: settings.localization.language)
        case .claude, .gemini, .deepseek:
            return "\(target.shortName) · \(modeLabel)"
        }
    }

    private func targetedXAIStatusTitle(settings: AppSettings, language: TokenPilotLanguage) -> String {
        if xAIManagementSetupConfigured(settings) {
            return "\(Provider.xai.shortName) · \(localized("Management authentication unconfirmed", language: language))"
        }
        return localized("xAI not configured", language: language)
    }

    private func xAIManagementSetupConfigured(_ settings: AppSettings) -> Bool {
        settings.xAI.managementAPIKeyConfigured &&
            !settings.xAI.teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func localizedRemaining(_ remaining: Int, language: TokenPilotLanguage) -> String {
        let format = localized("Capacity remaining %d%%", language: language)
        return String(format: format, remaining)
    }

    private func localizedReset(until resetAt: Date, now: Date, language: TokenPilotLanguage) -> String {
        "\(localized("Reset", language: language)) \(TokenPilotFormatters.remainingTime(until: resetAt, language: language, now: now))"
    }

    private func localizedAuthority(_ authority: String, language: TokenPilotLanguage) -> String {
        switch authority {
        case "provider-reported", "providerReported":
            return localized("Provider reported", language: language)
        case "local-derived", "localDerived":
            return localized("Local derived", language: language)
        case "user-entered", "userEntered":
            return localized("User entered", language: language)
        case "synthetic":
            return localized("Synthetic", language: language)
        case "unavailable":
            return localized("Unavailable", language: language)
        default:
            return localized(authority, language: language)
        }
    }

    private func localizedStability(_ stability: String, language: TokenPilotLanguage) -> String {
        switch stability {
        case "supported":
            return localized("Supported", language: language)
        case "manual":
            return localized("Manual entry", language: language)
        case "bridge", "compatibilityBridge":
            return localized("Compatibility bridge", language: language)
        case "experimental", "experimentalTransport":
            return localized("Experimental connector", language: language)
        case "local":
            return localized("Local metadata only", language: language)
        case "unavailable":
            return localized("Unavailable", language: language)
        default:
            return localized(stability, language: language)
        }
    }

    private func localizedFreshness(_ freshness: String, language: TokenPilotLanguage) -> String {
        switch freshness {
        case "fresh":
            return localized("Fresh", language: language)
        case "stale":
            return localized("Stale", language: language)
        case "unavailable":
            return localized("Freshness unavailable", language: language)
        default:
            return localized(freshness, language: language)
        }
    }

    private func localizedAction(_ action: String, language: TokenPilotLanguage) -> String {
        switch action {
        case "waitForReset":
            return localized("Wait for reset", language: language)
        case "refreshProvider":
            return localized("Refresh provider", language: language)
        case "reviewSource":
            return localized("Review source", language: language)
        case "reviewExperimentalConnector":
            return localized("Review experimental connector", language: language)
        case "enterManualValue":
            return localized("Enter manual value", language: language)
        case "reviewBalance":
            return localized("Review balance", language: language)
        case "openProviderDiagnostics":
            return localized("Open Provider Diagnostics", language: language)
        default:
            return localized(action, language: language)
        }
    }

    private func localizedModeLabel(_ modeLabel: String, language: TokenPilotLanguage) -> String {
        switch modeLabel {
        case "LIVE":
            return localized("Live only", language: language)
        case "LOCAL":
            return localized("Local metadata only", language: language)
        case "MANUAL":
            return localized("Manual entry", language: language)
        case "EXPERIMENTAL":
            return localized("Experimental connector", language: language)
        case "BRIDGE":
            return localized("Compatibility bridge", language: language)
        case "MOCK":
            return localized("Mock preview", language: language)
        case "STALE":
            return localized("Stale", language: language)
        default:
            return localized(modeLabel, language: language)
        }
    }

    private func accessibilityTitle(_ visualTitle: String, modeLabel: String, language: TokenPilotLanguage) -> String {
        let replacements = [
            ("EST STALE", "\(localized("Estimated", language: language)) \(localized("Stale", language: language))"),
            ("EXP STALE", "\(localized("Experimental connector", language: language)) \(localized("Stale", language: language))"),
            ("EXPERIMENTAL", localizedModeLabel("EXPERIMENTAL", language: language)),
            ("MANUAL", localizedModeLabel("MANUAL", language: language)),
            ("BRIDGE", localizedModeLabel("BRIDGE", language: language)),
            ("LOCAL", localizedModeLabel("LOCAL", language: language)),
            ("LIVE", localizedModeLabel("LIVE", language: language)),
            ("MOCK", localizedModeLabel("MOCK", language: language)),
            ("STALE", localizedModeLabel("STALE", language: language)),
            ("EXP", localized("Experimental connector", language: language)),
            ("EST", localized("Estimated", language: language)),
            (modeLabel, localizedModeLabel(modeLabel, language: language))
        ]

        return replacements.reduce(visualTitle) { title, replacement in
            title.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    private func selectedCandidate(
        from snapshots: [ProviderSnapshot],
        settings: AppSettings,
        now: Date,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> Candidate? {
        selectedCandidate(
            from: allCandidates(
                from: snapshots,
                settings: settings,
                xaiOAuthResult: xaiOAuthResult
            ),
            settings: settings,
            now: now
        )
    }

    private func selectedCandidate(from candidates: [Candidate], settings: AppSettings, now: Date) -> Candidate? {
        guard !candidates.isEmpty else {
            clearMemory()
            return nil
        }

        if let target = settings.menuBarDisplayTarget, settings.isProviderEnabled(target) {
            let providerCandidates = candidates.filter { $0.snapshot.provider == target }
            if let selected = representativeCandidate(from: providerCandidates) {
                clearMemory()
                return selected
            }
            clearMemory()
            return automaticCandidate(from: candidates, now: now)
        }

        if settings.menuBarDisplayTarget != nil {
            clearMemory()
        }
        return automaticCandidate(from: candidates, now: now)
    }

    private func automaticCandidate(from candidates: [Candidate], now: Date) -> Candidate? {
        guard let winner = representativeCandidate(from: candidates) else {
            clearMemory()
            return nil
        }

        memoryLock.lock()
        defer { memoryLock.unlock() }

        guard let currentMemory = memory,
              let current = representativeCandidate(from: candidates.filter({ $0.snapshot.provider == currentMemory.provider })) else {
            memory = SelectionMemory(provider: winner.snapshot.provider, rank: winner.rank, usedPercent: winner.usedPercent, selectedAt: now)
            return winner
        }

        if current.snapshot.provider == winner.snapshot.provider {
            if current.rank != currentMemory.rank {
                memory = SelectionMemory(provider: current.snapshot.provider, rank: current.rank, usedPercent: current.usedPercent, selectedAt: now)
            }
            return current
        }

        if winner.rank < current.rank {
            memory = SelectionMemory(provider: winner.snapshot.provider, rank: winner.rank, usedPercent: winner.usedPercent, selectedAt: now)
            return winner
        }

        if winner.rank > current.rank {
            return current
        }

        let elapsed = now.timeIntervalSince(currentMemory.selectedAt)
        if isPercentRank(winner.rank) {
            let winnerUsed = winner.usedPercent ?? -1
            let currentUsed = current.usedPercent ?? -1
            if winnerUsed >= currentUsed + 2 || elapsed >= 60 {
                memory = SelectionMemory(provider: winner.snapshot.provider, rank: winner.rank, usedPercent: winner.usedPercent, selectedAt: now)
                return winner
            }
            return current
        }

        if elapsed >= 60 {
            memory = SelectionMemory(provider: winner.snapshot.provider, rank: winner.rank, usedPercent: winner.usedPercent, selectedAt: now)
            return winner
        }
        return current
    }

    private func clearMemory() {
        memoryLock.lock()
        memory = nil
        memoryLock.unlock()
    }

    private func allCandidates(
        from snapshots: [ProviderSnapshot],
        settings: AppSettings,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> [Candidate] {
        var result = presentationSnapshots(from: snapshots, settings: settings)
            .flatMap { candidates(for: $0) }
        if let oauthSnapshot = oauthSnapshot(from: xaiOAuthResult) {
            result.removeAll { $0.snapshot.provider == .xai }
            if let manual = grokWeeklyManualCandidate(settings: settings) {
                result.append(manual)
            } else if let candidate = oauthWeeklyCandidate(for: oauthSnapshot) {
                result.append(candidate)
            }
        }
        return result
    }
    private func providerMetricsCandidates(
        from snapshots: [ProviderSnapshot],
        settings: AppSettings,
        xaiOAuthResult: XAIRefreshResult? = nil
    ) -> [Candidate] {
        if let oauthSnapshot = oauthSnapshot(from: xaiOAuthResult) {
            let nonXAI = presentationSnapshots(from: snapshots, settings: settings)
                .filter { $0.provider != .xai }
                .flatMap { candidates(for: $0) }
            if let manual = grokWeeklyManualCandidate(settings: settings) {
                return nonXAI + [manual]
            }
            return nonXAI + [oauthWeeklyCandidate(for: oauthSnapshot)].compactMap { $0 }
        }

        var result: [Candidate] = []
        // Prefer explicit manual weekly limit (Grok TUI "Weekly limit") when the user opts in.
        // This is not Orca-style session scraping; values are user-entered only.
        let weeklyManual = grokWeeklyManualCandidate(settings: settings)
        if let weeklyManual {
            result.append(weeklyManual)
        }

        for snapshot in presentationSnapshots(from: snapshots, settings: settings) {
            if snapshot.provider == .xai {
                if weeklyManual != nil {
                    continue
                }
                if let localCandidate = localGrokContextCandidate(for: snapshot) {
                    result.append(localCandidate)
                    continue
                }
                if settings.xAI.usageSource == .experimentalOpenCodeBarCLI,
                   let experimental = experimentalOpenCodeBarCandidate(for: snapshot) {
                    result.append(experimental)
                }
                continue
            }
            result.append(contentsOf: candidates(for: snapshot))
        }
        return result
    }

    private func oauthSnapshot(from result: XAIRefreshResult?) -> ProviderSnapshot? {
        guard let result,
              result.selectedOutcome == .oauthWeekly,
              result.selectedSnapshot.provenance == .experimentalOAuthWeekly else {
            return nil
        }
        return result.selectedSnapshot.storage
    }
    private func oauthWeeklyCandidate(for snapshot: ProviderSnapshot) -> Candidate? {
        guard snapshot.provider == .xai,
              snapshot.isExperimental,
              snapshot.dataSource == .experimentalCLI,
              let weekly = snapshot.weekly,
              let reportedUsed = weekly.usedPercent else {
            return nil
        }
        let used = min(max(reportedUsed, 0), 100)
        return Candidate(
            snapshot: snapshot,
            kind: .percent,
            rank: snapshot.isStale ? 7 : 2,
            usedPercent: used,
            remainingPercent: 100 - used,
            resetAt: weekly.resetAt,
            durationMinutes: weekly.durationMinutes ?? 10_080,
            seriesID: "\(Provider.xai.rawValue)/oauth-weekly",
            suffix: snapshot.isStale ? "UNOFFICIAL STALE" : "UNOFFICIAL",
            authority: "experimental-oauth-weekly",
            stability: "experimental",
            freshness: snapshot.isStale ? "stale" : "fresh",
            action: "refresh"
        )
    }
    private func localGrokContextCandidate(for snapshot: ProviderSnapshot) -> Candidate? {
        guard snapshot.provider == .xai,
              snapshot.dataSource == .localLog,
              let used = snapshot.contextWindowUsedPercent else {
            return nil
        }
        return Candidate(
            snapshot: snapshot,
            kind: .percent,
            rank: 12,
            usedPercent: used,
            remainingPercent: min(max(100 - used, 0), 100),
            resetAt: nil,
            durationMinutes: nil,
            seriesID: "\(snapshot.provider.rawValue)/local-context",
            suffix: "",
            authority: "local-context",
            stability: "local",
            freshness: snapshot.isStale ? "stale" : "fresh",
            action: "openProviderDiagnostics"
        )
    }

    private func grokWeeklyManualCandidate(settings: AppSettings) -> Candidate? {
        guard settings.isProviderEnabled(.xai),
              settings.xAI.weeklySnapshotEnabled else {
            return nil
        }
        let remaining = min(max(settings.xAI.weeklyRemainingPercent, 0), 100)
        let capturedAt = settings.xAI.weeklySnapshotCapturedAt ?? Date()
        let isStale = Date().timeIntervalSince(capturedAt) > 12 * 60 * 60
        let snapshot = ProviderSnapshot(
            provider: .xai,
            updatedAt: capturedAt,
            weekly: LimitWindow(
                kind: .weekly,
                usedPercent: 100 - remaining,
                confidence: .manual,
                providerWindowID: "manual-weekly",
                durationMinutes: 10_080
            ),
            confidence: .manual,
            dataSource: .manual,
            isStale: isStale,
            statusMessage: isStale
                ? "STALE · MANUAL · Grok weekly limit"
                : "MANUAL · Grok weekly limit",
            model: "Grok Build"
        )
        return Candidate(
            snapshot: snapshot,
            kind: .percent,
            rank: isStale ? 7 : 3,
            usedPercent: 100 - remaining,
            remainingPercent: remaining,
            resetAt: nil,
            durationMinutes: 10_080,
            seriesID: "\(Provider.xai.rawValue)/weekly-manual",
            suffix: isStale ? "MANUAL STALE" : "MANUAL",
            authority: "user-entered",
            stability: "manual",
            freshness: isStale ? "stale" : "fresh",
            action: "enterManualValue"
        )
    }

    private func experimentalOpenCodeBarCandidate(for snapshot: ProviderSnapshot) -> Candidate? {
        guard snapshot.provider == .xai,
              snapshot.isExperimental,
              snapshot.dataSource == .experimentalCLI,
              snapshot.statusMessage?.contains("OpenCode Bar") == true,
              let window = snapshot.monthly,
              let used = window.usedPercent else {
            return nil
        }
        return Candidate(
            snapshot: snapshot,
            kind: .percent,
            rank: snapshot.isStale ? 6 : 2,
            usedPercent: used,
            remainingPercent: min(max(100 - used, 0), 100),
            resetAt: window.resetAt,
            durationMinutes: window.durationMinutes,
            seriesID: "\(snapshot.provider.rawValue)/opencodebar",
            suffix: snapshot.isStale ? "EXP STALE" : "EXP",
            authority: "provider-reported",
            stability: "experimental",
            freshness: snapshot.isStale ? "stale" : "fresh",
            action: snapshot.isStale ? "refreshProvider" : "reviewExperimentalConnector"
        )
    }

    private func isExperimentalOpenCodeBarPercentage(_ candidate: Candidate) -> Bool {
        candidate.snapshot.provider == .xai &&
            candidate.kind == .percent &&
            candidate.stability == "experimental" &&
            candidate.snapshot.statusMessage?.contains("OpenCode Bar") == true
    }

    private func candidates(for snapshot: ProviderSnapshot) -> [Candidate] {
        guard snapshot.dataSource != .mock else { return [] }
        if snapshot.provider == .xai {
            return []
        }
        var candidates: [Candidate] = []

        if let balance = snapshot.balance {
            let staleOffset = snapshot.isStale ? 1 : 0
            if snapshot.dataSource == .officialTelemetry {
                candidates.append(Candidate(
                    snapshot: snapshot,
                    kind: .money,
                    rank: 8 + staleOffset,
                    usedPercent: nil,
                    remainingPercent: nil,
                    resetAt: nil,
                    durationMinutes: nil,
                    seriesID: "\(snapshot.provider.rawValue)/balance",
                    suffix: snapshot.isStale ? "STALE" : "",
                    authority: "provider-reported",
                    stability: "supported",
                    freshness: snapshot.isStale ? "stale" : "fresh",
                    action: "reviewBalance"
                ))
            } else if snapshot.dataSource == .manual || snapshot.dataSource == .estimated || snapshot.confidence == .manual {
                candidates.append(Candidate(
                    snapshot: snapshot,
                    kind: .money,
                    rank: 10 + staleOffset,
                    usedPercent: nil,
                    remainingPercent: nil,
                    resetAt: nil,
                    durationMinutes: nil,
                    seriesID: "\(snapshot.provider.rawValue)/balance/manual",
                    suffix: snapshot.isStale ? "EST STALE" : "EST",
                    authority: "user-entered",
                    stability: "manual",
                    freshness: snapshot.isStale ? "stale" : "fresh",
                    action: "reviewBalance"
                ))
            }
            _ = balance
        }

        appendPercentCandidate(snapshot: snapshot, window: snapshot.fiveHour, defaultDurationMinutes: 300, defaultWindowID: "five-hour", into: &candidates)
        appendPercentCandidate(snapshot: snapshot, window: snapshot.weekly, defaultDurationMinutes: 10_080, defaultWindowID: "seven-day", into: &candidates)
        appendBridgeContextCandidate(snapshot: snapshot, into: &candidates)

        if candidates.isEmpty {
            if snapshot.todayTokens > 0 || snapshot.dailyRequestsUsed != nil || snapshot.contextWindowUsedPercent != nil {
                candidates.append(Candidate(
                    snapshot: snapshot,
                    kind: .info,
                    rank: 12,
                    usedPercent: nil,
                    remainingPercent: nil,
                    resetAt: nil,
                    durationMinutes: nil,
                    seriesID: "\(snapshot.provider.rawValue)/activity",
                    suffix: "",
                    authority: "local-derived",
                    stability: "local",
                    freshness: snapshot.isStale ? "stale" : "fresh",
                    action: "openProviderDiagnostics"
                ))
            }
        }

        return candidates
    }

    private func appendPercentCandidate(snapshot: ProviderSnapshot, window: LimitWindow?, defaultDurationMinutes: Int, defaultWindowID: String, into candidates: inout [Candidate]) {
        guard let window, let used = window.usedPercent else { return }
        guard let classification = percentClassification(for: snapshot) else { return }
        let remaining = min(max(100 - used, 0), 100)
        candidates.append(Candidate(
            snapshot: snapshot,
            kind: classification.rank == 12 ? .info : .percent,
            rank: classification.rank,
            usedPercent: classification.rank == 12 ? nil : used,
            remainingPercent: classification.rank == 12 ? nil : remaining,
            resetAt: window.resetAt,
            durationMinutes: window.durationMinutes ?? defaultDurationMinutes,
            seriesID: "\(snapshot.provider.rawValue)/\(window.providerWindowID ?? defaultWindowID)",
            suffix: classification.suffix,
            authority: classification.authority,
            stability: classification.stability,
            freshness: snapshot.isStale ? "stale" : "fresh",
            action: classification.action
        ))
    }

    private func appendBridgeContextCandidate(snapshot: ProviderSnapshot, into candidates: inout [Candidate]) {
        guard snapshot.provider == .gemini,
              snapshot.dataSource == .officialStatusline,
              let used = snapshot.contextWindowUsedPercent else {
            return
        }
        let staleOffset = snapshot.isStale ? 4 : 0
        candidates.append(Candidate(
            snapshot: snapshot,
            kind: .percent,
            rank: 1 + staleOffset,
            usedPercent: used,
            remainingPercent: min(max(100 - used, 0), 100),
            resetAt: nil,
            durationMinutes: nil,
            seriesID: "\(snapshot.provider.rawValue)/context",
            suffix: snapshot.isStale ? "STALE" : "",
            authority: "provider-reported",
            stability: "bridge",
            freshness: snapshot.isStale ? "stale" : "fresh",
            action: "reviewSource"
        ))
    }

    private func percentClassification(for snapshot: ProviderSnapshot) -> (rank: Int, suffix: String, authority: String, stability: String, action: String)? {
        let staleOffset = snapshot.isStale ? 4 : 0
        if snapshot.provider == .claude, snapshot.dataSource == .officialStatusline {
            return (0 + staleOffset, snapshot.isStale ? "STALE" : "", "provider-reported", "supported", snapshot.isStale ? "refreshProvider" : "waitForReset")
        }
        if snapshot.provider == .codex, snapshot.dataSource == .webUsage, snapshot.isExperimental {
            return (2 + staleOffset, snapshot.isStale ? "EXP STALE" : "EXP", "provider-reported", "experimental", snapshot.isStale ? "refreshProvider" : "reviewExperimentalConnector")
        }
        if snapshot.dataSource == .manual || snapshot.dataSource == .estimated || snapshot.confidence == .manual {
            return (3 + staleOffset, snapshot.isStale ? "EST STALE" : "EST", "user-entered", "manual", "enterManualValue")
        }
        if snapshot.provider == .gemini, snapshot.dataSource == .officialStatusline {
            return (1 + staleOffset, snapshot.isStale ? "STALE" : "", "provider-reported", "bridge", "reviewSource")
        }
        if snapshot.dataSource == .localLog || snapshot.isCodexLocalLogOnly {
            return (12, "", "local-derived", "local", "openProviderDiagnostics")
        }
        return nil
    }

    private func representativeCandidate(from candidates: [Candidate]) -> Candidate? {
        let byProvider = Dictionary(grouping: candidates, by: { $0.snapshot.provider })
            .compactMap { representativeForProvider($0.value) }
        return byProvider.sorted(by: isBetterCandidate).first
    }

    private func representativeForProvider(_ candidates: [Candidate]) -> Candidate? {
        candidates.sorted(by: isBetterCandidate).first
    }

    private func isBetterCandidate(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.kind == .percent, rhs.kind == .percent {
            if (lhs.usedPercent ?? -1) != (rhs.usedPercent ?? -1) {
                return (lhs.usedPercent ?? -1) > (rhs.usedPercent ?? -1)
            }
            let lhsReset = lhs.resetAt ?? .distantFuture
            let rhsReset = rhs.resetAt ?? .distantFuture
            if lhsReset != rhsReset { return lhsReset < rhsReset }
        }
        if lhs.seriesID != rhs.seriesID { return lhs.seriesID < rhs.seriesID }
        return lhs.snapshot.provider.rawValue < rhs.snapshot.provider.rawValue
    }

    private func percentRenderCandidates(for candidate: Candidate, in candidates: [Candidate]) -> [Candidate] {
        candidates
            .filter {
                $0.snapshot.provider == candidate.snapshot.provider &&
                    $0.kind == .percent &&
                    $0.rank == candidate.rank &&
                    $0.suffix == candidate.suffix &&
                    $0.authority == candidate.authority &&
                    $0.stability == candidate.stability &&
                    $0.freshness == candidate.freshness
            }
            .sorted {
                if ($0.durationMinutes ?? 0) != ($1.durationMinutes ?? 0) {
                    return ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0)
                }
                return isBetterCandidate($0, $1)
            }
    }

    private func percentSegment(for candidate: Candidate) -> String {
        let label = candidate.stability == "bridge" ? "BRIDGE" : durationLabel(minutes: candidate.durationMinutes)
        let remaining = candidate.remainingPercent ?? 0
        let suffix = candidate.suffix.isEmpty || candidate.suffix == label ? "" : " \(candidate.suffix)"
        return "\(label) \(remaining)%\(suffix)"
    }

    private func durationLabel(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "--" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1_440, minutes % 60 == 0 { return "\(minutes / 60)h" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        return "\(minutes)min"
    }

    private func durationText(until resetAt: Date, now: Date) -> String {
        let minutes = max(Int(resetAt.timeIntervalSince(now) / 60), 0)
        return durationLabel(minutes: minutes)
    }

    private func isPercentRank(_ rank: Int) -> Bool {
        (0...7).contains(rank)
    }

    private func snapshotWithCodexManualMenuBarFallback(_ snapshot: ProviderSnapshot?, settings: AppSettings) -> ProviderSnapshot? {
        guard var snapshot else {
            return codexManualMenuBarSnapshot(settings: settings)
        }
        guard snapshot.provider == .codex,
              snapshot.fiveHour == nil,
              snapshot.weekly == nil,
              snapshot.dailyRequestsPercent == nil,
              let manual = codexManualMenuBarSnapshot(settings: settings) else {
            return snapshot
        }
        snapshot.fiveHour = manual.fiveHour
        snapshot.weekly = manual.weekly
        if snapshot.todayTokens == 0 {
            snapshot.todayTokens = manual.todayTokens
        }
        snapshot.confidence = manual.confidence
        snapshot.dataSource = manual.dataSource
        snapshot.statusMessage = manual.statusMessage
        snapshot.model = snapshot.model ?? manual.model
        return snapshot
    }

    private func codexManualMenuBarSnapshot(settings: AppSettings) -> ProviderSnapshot? {
        guard settings.codexEnabled else { return nil }
        let manual = settings.codexManual
        let hasFiveHour = manual.webSnapshotEnabled || manual.fiveHourUsagePercentage > 0
        let hasWeekly = manual.webSnapshotEnabled || manual.weeklyUsagePercentage > 0
        guard hasFiveHour || hasWeekly else { return nil }

        let plan = manual.planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderSnapshot(
            provider: .codex,
            updatedAt: manual.webSnapshotCapturedAt ?? Date(),
            fiveHour: hasFiveHour ? LimitWindow(kind: .fiveHour, usedPercent: manual.fiveHourUsagePercentage, confidence: .manual) : nil,
            weekly: hasWeekly ? LimitWindow(kind: .weekly, usedPercent: manual.weeklyUsagePercentage, confidence: .manual) : nil,
            todayTokens: manual.webTodayTokens,
            confidence: .manual,
            dataSource: .manual,
            statusMessage: "Manual menu bar estimate",
            model: plan.isEmpty || plan.lowercased() == "manual" ? nil : plan
        )
    }
}