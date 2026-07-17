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

    public func selectedSnapshot(from snapshots: [ProviderSnapshot], settings: AppSettings) -> ProviderSnapshot? {
        selectedCandidate(from: snapshots, settings: settings, now: Date())?.snapshot
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
        now: Date = Date()
    ) -> String {
        let candidates = allCandidates(from: snapshots, settings: settings)
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

    public func statusLevel(snapshots: [ProviderSnapshot], settings: AppSettings) -> MenuBarStatusLevel {
        guard let candidate = selectedCandidate(from: snapshots, settings: settings, now: Date()),
              candidate.kind == .percent,
              candidate.rank < 8,
              let percent = candidate.usedPercent else {
            return .normal
        }
        if percent >= 85 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }

    public func shouldShowStatusDot(snapshots: [ProviderSnapshot], settings: AppSettings) -> Bool {
        statusLevel(snapshots: snapshots, settings: settings) != .normal
    }

    public func lowestRemainingSummary(snapshots: [ProviderSnapshot], settings: AppSettings) -> MenuBarLowestRemainingSummary? {
        allCandidates(from: snapshots, settings: settings)
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
        now: Date = Date()
    ) -> String {
        let language = settings.localization.language
        if settings.menuBarDisplayTarget == .xai, settings.isProviderEnabled(.xai) {
            return "TokenPilot, \(targetedXAIStatusTitle(settings: settings, language: language))"
        }

        let visualTitle = accessibilityTitle(
            title(snapshots: snapshots, settings: settings, modeLabel: modeLabel, now: now),
            modeLabel: modeLabel,
            language: language
        )
        guard let candidate = selectedCandidate(from: snapshots, settings: settings, now: now) else {
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

    private func selectedCandidate(from snapshots: [ProviderSnapshot], settings: AppSettings, now: Date) -> Candidate? {
        selectedCandidate(from: allCandidates(from: snapshots, settings: settings), settings: settings, now: now)
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

    private func allCandidates(from snapshots: [ProviderSnapshot], settings: AppSettings) -> [Candidate] {
        presentationSnapshots(from: snapshots, settings: settings)
            .flatMap { candidates(for: $0) }
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