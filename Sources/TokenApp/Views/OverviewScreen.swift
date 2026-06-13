import SwiftUI
import TokenCore

struct TokenPilotRootView: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        VStack(spacing: 8) {
            header
            Picker(model.t("Screen"), selection: $model.selectedScreen) {
                ForEach(TokenPilotViewModel.Screen.allCases) { screen in
                    Text(model.t(screen.rawValue)).tag(screen)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let message = model.bannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message)
                        .lineLimit(2)
                    Spacer()
                    Button(model.t("Dismiss")) { model.bannerMessage = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(9)
                .background(TokenPilotDesign.cardMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous)
                        .stroke(TokenPilotDesign.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous))
            }

            Group {
                switch model.selectedScreen {
                case .overview:
                    OverviewScreen(model: model)
                case .history:
                    HistoryScreen(model: model)
                case .settings:
                    SettingsScreen(model: model)
                }
            }
        }
        .environment(\.tokenPilotLanguage, model.settings.localization.language)
        .environment(\.locale, Locale(identifier: model.settings.localization.language.localeIdentifier ?? Locale.current.identifier))
        .padding(12)
        .frame(width: 420, height: 620)
        .foregroundStyle(TokenPilotDesign.textPrimary)
        .background(
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            TokenPilotBrandMark()

            Text(model.t("TokenPilot"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(TokenPilotDesign.textPrimary)

            StatusBadge(
                label: model.t(model.dataSourceMode.displayLabel),
                color: TokenPilotDesign.modeColor(model.dataSourceMode)
            )

            Spacer(minLength: 0)

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(TokenPilotDesign.cardMuted.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenPilotDesign.textSecondary)
            .help(model.t("Refresh"))
        }
        .frame(height: 26)
    }
}

struct OverviewScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.sectionSpacing) {
                ResetHeroCard(model: model)
                BestToolCard(snapshot: model.bestToolSnapshot)

                if model.overviewSnapshots.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        EmptyStateCard(
                            icon: "tray",
                            title: model.t("No data"),
                            message: model.t("Run Provider Diagnostics in Settings to connect Claude, Codex, or Gemini.")
                        )
                        Button(model.t("Open Provider Diagnostics")) {
                            model.selectedScreen = .settings
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TokenPilotDesign.calm)
                    }
                } else {
                    ProviderOverviewList(snapshots: model.overviewSnapshots)
                }

                if model.overviewUsage.metrics.totalTokens > 0 {
                    SevenDayBarChart(bars: model.overviewUsage.sevenDayBars)
                    ProviderShareRow(shares: model.overviewUsage.providerShare)
                }

                ChallengeCard(
                    target: model.challengeTargetTokens,
                    today: model.overviewUsage.metrics.totalTokens,
                    onTargetChange: { model.updateChallengeTarget($0) }
                )
                AlertsStatusRow(text: model.alertStatusText)
            }
            .padding(.bottom, 6)
        }
    }
}

struct ResetHeroCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 15) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(heroEyebrow)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                        Text(heroValue)
                            .font(.system(size: 32, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(TokenPilotDesign.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(nextResetText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        StatusBadge(label: riskLabel, color: riskColor)
                        Text(percentText)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(riskColor)
                    }
                }

                ProgressLine(percent: usedPercent, color: riskColor)

                HStack(spacing: 8) {
                    HeroStatPill(
                        label: localized("Today tokens", language: language),
                        value: "\(TokenPilotFormatters.compactNumber(model.overviewUsage.metrics.totalTokens)) \(localized("tok", language: language))"
                    )
                    HeroStatPill(
                        label: localized("Highest risk", language: language),
                        value: highestRiskText,
                        color: TokenPilotDesign.riskColor(model.highestRiskProvider?.percent)
                    )
                    HeroStatPill(
                        label: localized("Last updated", language: language),
                        value: updatedText
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
    }

    private var snapshot: ProviderSnapshot? { model.menuBarSnapshot }
    private var window: LimitWindow? { model.menuBarDisplayWindow }
    private var usedPercent: Int? { window?.usedPercent ?? snapshot?.primaryUsedPercent }

    private var heroEyebrow: String {
        let limit = localized("Limit", language: language)
        guard let window else { return localized("No data", language: language) }
        return "\(localized(window.kind.label, language: language)) \(limit)"
    }

    private var heroValue: String {
        guard let resetAt = window?.resetAt, resetAt > Date() else {
            if let usedPercent { return "\(usedPercent)%" }
            return "—"
        }
        return TokenPilotFormatters.remainingTime(until: resetAt)
    }

    private var nextResetText: String {
        let label = localized("Next reset", language: language)
        guard let resetAt = window?.resetAt else { return "\(label) · \(localized("No reset", language: language))" }
        return "\(label) · \(TokenPilotFormatters.clock(resetAt))"
    }

    private var percentText: String {
        guard let usedPercent else { return "—" }
        return "\(usedPercent)%"
    }

    private var riskLabel: String {
        guard let usedPercent else { return localized(model.dataSourceMode.displayLabel, language: language) }
        if usedPercent >= 85 { return localized("Critical", language: language) }
        if usedPercent >= 70 { return localized("Warning", language: language) }
        return localized("Stable", language: language)
    }

    private var riskColor: Color {
        TokenPilotDesign.riskColor(usedPercent)
    }

    private var highestRiskText: String {
        guard let highest = model.highestRiskProvider else { return "—" }
        return "\(highest.provider.shortName) \(highest.percent)%"
    }

    private var updatedText: String {
        guard let snapshot else { return "—" }
        return TokenPilotFormatters.clock(snapshot.updatedAt)
    }
}

struct HeroStatPill: View {
    let label: String
    let value: String
    var color: Color = TokenPilotDesign.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ProviderOverviewList: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshots: [ProviderSnapshot]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                Label(localized("Providers", language: language), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(TokenPilotDesign.textPrimary)

                VStack(spacing: 0) {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        ProviderOverviewRow(snapshot: snapshot)
                        if index < snapshots.count - 1 {
                            Divider()
                                .overlay(TokenPilotDesign.border.opacity(0.8))
                                .padding(.vertical, 9)
                        }
                    }
                }
            }
        }
    }
}

struct ProviderOverviewRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProviderSignatureMark(provider: snapshot.provider)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(snapshot.provider.displayName, language: language))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                    Text(detailText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)

                Text(valueText)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.riskColor(usedPercent))
                    .lineLimit(1)
            }

            ProgressLine(percent: usedPercent, color: TokenPilotDesign.riskColor(usedPercent))
        }
    }

    private var usedPercent: Int? {
        [
            snapshot.fiveHour?.usedPercent,
            snapshot.weekly?.usedPercent,
            snapshot.dailyRequestsPercent,
            snapshot.primaryUsedPercent
        ]
        .compactMap { $0 }
        .max()
    }

    private var valueText: String {
        guard let usedPercent else {
            if snapshot.todayTokens > 0 { return TokenPilotFormatters.compactNumber(snapshot.todayTokens) }
            return "—"
        }
        if snapshot.provider == .codex || snapshot.confidence == .manual {
            return "\(usedPercent)% \(localized("est.", language: language))"
        }
        return "\(usedPercent)%"
    }

    private var detailText: String {
        let limits = limitSegments
        if !limits.isEmpty {
            return limits.joined(separator: " · ")
        }
        if snapshot.todayTokens > 0 {
            return "\(localized("Today", language: language)) · \(TokenPilotFormatters.compactNumber(snapshot.todayTokens)) \(localized("tok", language: language))"
        }
        return localized("No limits", language: language)
    }

    private var limitSegments: [String] {
        var segments: [String] = []
        if let fiveHour = snapshot.fiveHour {
            segments.append(limitText(for: fiveHour))
        }
        if let weekly = snapshot.weekly {
            segments.append(limitText(for: weekly))
        }
        if let dailyRequestsPercent = snapshot.dailyRequestsPercent {
            segments.append("\(localized(LimitWindowKind.dailyRequests.label, language: language)) \(dailyRequestsPercent)%")
        }
        return segments
    }

    private func limitText(for window: LimitWindow) -> String {
        let label = localized(window.kind.label, language: language)
        guard let used = window.usedPercent else { return "\(label) —" }
        let suffix = (snapshot.provider == .codex || window.confidence == .manual) ? " \(localized("est.", language: language))" : ""
        return "\(label) \(used)%\(suffix)"
    }
}

struct BestToolCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshot: ProviderSnapshot?

    var body: some View {
        GlassCard {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(accent.opacity(0.18), lineWidth: 1)
                        )
                    Image(systemName: snapshot == nil ? "sparkle.magnifyingglass" : "checkmark.seal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Lowest current usage", language: language))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    if let snapshot {
                        Text(bestToolTitle(for: snapshot))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenPilotDesign.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text(localized("Connect providers in Settings", language: language))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let pct = snapshot?.primaryUsedPercent {
                    StatusBadge(label: "\(pct)%", color: TokenPilotDesign.riskColor(pct))
                }
            }
        }
    }

    private var accent: Color {
        if let snapshot {
            return TokenPilotDesign.accent(for: snapshot.provider)
        }
        return TokenPilotDesign.textSecondary
    }

    private func bestToolTitle(for snapshot: ProviderSnapshot) -> String {
        if snapshot.confidence == .manual {
            return "\(localized(snapshot.provider.displayName, language: language)) · \(localized("est.", language: language))"
        }
        return localized(snapshot.provider.displayName, language: language)
    }
}

struct ChallengeCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    let target: Int
    let today: Int
    var onTargetChange: ((Int) -> Void)?

    @State private var showTargetPicker = false

    private let presetTargets = [5_000, 10_000, 25_000, 50_000, 100_000]

    var body: some View {
        let progress = target > 0 ? min(1, Double(today) / Double(target)) : 0
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(localized("Daily challenge", language: language), systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(TokenPilotDesign.riskColor(Int(progress * 100)))
                }
                HStack {
                    Text("\(TokenPilotFormatters.compactNumber(today)) / \(TokenPilotFormatters.compactNumber(target))")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                    Spacer()
                    Text(localized("Today tokens", language: language))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                ProgressLine(percent: Int(progress * 100), color: TokenPilotDesign.calm)
            }
        }
        .onTapGesture { showTargetPicker = true }
        .confirmationDialog(
            localized("Daily challenge target", language: language),
            isPresented: $showTargetPicker,
            titleVisibility: .visible
        ) {
            ForEach(presetTargets, id: \.self) { preset in
                Button("\(TokenPilotFormatters.compactNumber(preset)) tok") {
                    onTargetChange?(preset)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct AlertsStatusRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.badge")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TokenPilotDesign.textSecondary)
            Text(text)
                .font(.system(size: 10, design: .monospaced).weight(.medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous)
                .stroke(TokenPilotDesign.border.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous))
    }
}
