import Foundation

public enum MenuBarStatusLevel: String, Sendable {
    case normal
    case warning
    case critical
}

public struct MenuBarRemainingStatusBadge: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var remainingPercent: Int
    public var usedPercent: Int
    public var isEstimated: Bool

    public init(label: String, remainingPercent: Int, usedPercent: Int, isEstimated: Bool = false) {
        self.label = label
        self.remainingPercent = min(max(remainingPercent, 0), 100)
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.isEstimated = isEstimated
        self.id = "\(label)-\(self.remainingPercent)-\(self.usedPercent)-\(isEstimated)"
    }
}

public final class MenuBarStatusService: Sendable {
    public init() {}

    public func selectedSnapshot(from snapshots: [ProviderSnapshot], settings: AppSettings) -> ProviderSnapshot? {
        let enabled = snapshots.filter { settings.isProviderEnabled($0.provider) }
        if let target = settings.menuBarDisplayTarget,
           settings.isProviderEnabled(target),
           let selected = enabled.first(where: { $0.provider == target }) {
            return selected
        }
        return enabled.max { lhs, rhs in
            riskScore(lhs) < riskScore(rhs)
        }
    }

    public func displayWindow(for snapshot: ProviderSnapshot) -> LimitWindow? {
        if let weekly = snapshot.weekly { return weekly }
        if let fiveHour = snapshot.fiveHour { return fiveHour }
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
        guard let snapshot = selectedSnapshot(from: snapshots, settings: settings) else {
            return "TP · \(modeLabel)"
        }

        let language = settings.localization.language
        if let quotaTitle = quotaRemainingTitle(for: snapshot, language: language) {
            return quotaTitle + confidenceSuffix(for: snapshot, language: language)
        }

        if let window = displayWindow(for: snapshot) {
            let period = TokenPilotLocalizer.localized(window.kind.label, language: language)
            let base: String
            if let resetAt = window.resetAt, resetAt > now {
                base = "\(TokenPilotFormatters.compactRemainingTime(until: resetAt, now: now)) · \(period)"
            } else {
                base = "— · \(period)"
            }
            return base + confidenceSuffix(for: snapshot, language: language)
        }

        // When no rate limits are available, show provider abbreviation + today's tokens
        let providerAbbr = snapshot.provider.shortName
        if snapshot.todayTokens > 0 {
            let tokenUnit = TokenPilotLocalizer.localized("tok", language: language)
            return "\(providerAbbr) \(TokenPilotFormatters.compactNumber(snapshot.todayTokens))\(tokenUnit)" + confidenceSuffix(for: snapshot, language: language)
        }
        if snapshot.isStale {
            return "\(providerAbbr) \(TokenPilotLocalizer.localized("STALE", language: language))"
        }
        return "\(providerAbbr) · \(modeLabel)"
    }

    public func statusLevel(snapshots: [ProviderSnapshot], settings: AppSettings) -> MenuBarStatusLevel {
        guard let snapshot = selectedSnapshot(from: snapshots, settings: settings),
              let percent = maxUsedPercent(for: snapshot) else {
            return .normal
        }
        if percent >= 85 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }

    public func shouldShowStatusDot(snapshots: [ProviderSnapshot], settings: AppSettings) -> Bool {
        statusLevel(snapshots: snapshots, settings: settings) != .normal
    }

    public func remainingBadges(snapshots: [ProviderSnapshot], settings: AppSettings) -> [MenuBarRemainingStatusBadge] {
        guard let snapshot = selectedSnapshot(from: snapshots, settings: settings) else { return [] }
        return remainingBadges(for: snapshot)
    }

    public func remainingBadges(for snapshot: ProviderSnapshot) -> [MenuBarRemainingStatusBadge] {
        var badges: [MenuBarRemainingStatusBadge] = []
        if let badge = remainingBadge(for: snapshot.fiveHour, snapshot: snapshot) {
            badges.append(badge)
        }
        if let badge = remainingBadge(for: snapshot.weekly, snapshot: snapshot) {
            badges.append(badge)
        }
        if badges.isEmpty,
           let dailyRequestsPercent = snapshot.dailyRequestsPercent {
            badges.append(MenuBarRemainingStatusBadge(
                label: compactMenuLabel(for: .dailyRequests),
                remainingPercent: min(max(100 - dailyRequestsPercent, 0), 100),
                usedPercent: dailyRequestsPercent,
                isEstimated: snapshot.confidence == .manual || snapshot.dataSource == .manual || snapshot.dataSource == .estimated
            ))
        }
        return badges
    }

    public func accessibilityLabel(
        snapshots: [ProviderSnapshot],
        settings: AppSettings,
        modeLabel: String,
        now: Date = Date()
    ) -> String {
        let visualTitle = title(snapshots: snapshots, settings: settings, modeLabel: modeLabel, now: now)
        guard let snapshot = selectedSnapshot(from: snapshots, settings: settings) else {
            return "TokenPilot, \(visualTitle)"
        }

        var parts = ["TokenPilot", snapshot.provider.displayName, visualTitle]
        if let percent = snapshot.primaryUsedPercent {
            parts.append("\(percent)%")
        }
        parts.append(modeLabel)
        return parts.joined(separator: ", ")
    }

    private func confidenceSuffix(for snapshot: ProviderSnapshot, language: TokenPilotLanguage) -> String {
        guard snapshot.provider == .codex,
              snapshot.confidence == .manual || snapshot.dataSource == .manual || snapshot.dataSource == .estimated else {
            return ""
        }
        return " \(TokenPilotLocalizer.localized("est.", language: language))"
    }

    private func quotaRemainingTitle(for snapshot: ProviderSnapshot, language: TokenPilotLanguage) -> String? {
        var segments: [String] = []
        if let fiveHour = remainingSegment(for: snapshot.fiveHour, language: language) {
            segments.append(fiveHour)
        }
        if let weekly = remainingSegment(for: snapshot.weekly, language: language) {
            segments.append(weekly)
        }
        if segments.isEmpty,
           let dailyRequestsPercent = snapshot.dailyRequestsPercent {
            let daily = LimitWindow(kind: .dailyRequests, usedPercent: dailyRequestsPercent, confidence: snapshot.confidence)
            if let segment = remainingSegment(for: daily, language: language) {
                segments.append(segment)
            }
        }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: " · ")
    }

    private func remainingSegment(for window: LimitWindow?, language: TokenPilotLanguage) -> String? {
        guard let window else { return nil }
        let noData = TokenPilotLocalizer.localized("No data", language: language)
        if let remainingPercent = window.remainingPercent {
            return "\(compactMenuLabel(for: window.kind)) \(remainingPercent)"
        }
        return "\(compactMenuLabel(for: window.kind)) \(noData)"
    }

    private func remainingBadge(for window: LimitWindow?, snapshot: ProviderSnapshot) -> MenuBarRemainingStatusBadge? {
        guard let window,
              let remainingPercent = window.remainingPercent,
              let usedPercent = window.usedPercent else {
            return nil
        }
        return MenuBarRemainingStatusBadge(
            label: compactMenuLabel(for: window.kind),
            remainingPercent: remainingPercent,
            usedPercent: usedPercent,
            isEstimated: snapshot.confidence == .manual || window.confidence == .manual || snapshot.dataSource == .manual || snapshot.dataSource == .estimated
        )
    }

    private func compactMenuLabel(for kind: LimitWindowKind) -> String {
        switch kind {
        case .fiveHour:
            return "5h"
        case .weekly:
            return "W"
        case .dailyRequests:
            return "D"
        }
    }

    private func usefulResetText(for snapshot: ProviderSnapshot) -> String? {
        guard let percent = snapshot.primaryUsedPercent, percent >= 80 else { return nil }
        let resetAt = [snapshot.fiveHour?.resetAt, snapshot.weekly?.resetAt]
            .compactMap { $0 }
            .filter { $0.timeIntervalSinceNow > 0 }
            .min()
        guard let resetAt else { return nil }
        return "R \(TokenPilotFormatters.remainingTime(until: resetAt))"
    }

    private func riskScore(_ snapshot: ProviderSnapshot) -> Int {
        maxUsedPercent(for: snapshot) ?? (snapshot.todayTokens > 0 ? 1 : 0)
    }

    private func maxUsedPercent(for snapshot: ProviderSnapshot) -> Int? {
        [
            snapshot.fiveHour?.usedPercent,
            snapshot.weekly?.usedPercent,
            snapshot.dailyRequestsPercent
        ]
        .compactMap { $0 }
        .max()
    }
}
