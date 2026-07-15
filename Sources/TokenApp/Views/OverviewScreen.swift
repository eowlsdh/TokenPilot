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
                Group {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 24, height: 24)
                .background(TokenPilotDesign.cardMuted.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenPilotDesign.textSecondary)
            .disabled(model.isRefreshing)
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityLabel(model.t("Refresh"))
            .accessibilityValue(model.isRefreshing ? model.t("Refreshing") : model.t("Ready"))
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
                UsageSummaryCard(model: model)
                if model.overviewSnapshots.isEmpty && model.capacityPresentations.isEmpty && model.capacityRefreshErrors.isEmpty && !model.capacityRuntimeRecoveryRequired {
                    VStack(alignment: .leading, spacing: 8) {
                        EmptyStateCard(
                            icon: "tray",
                            title: model.t("No data"),
                            message: model.t("Run Provider Diagnostics in Settings to connect Claude, Codex, or Antigravity.")
                        )
                        Button(model.t("Settings")) {
                            model.selectedScreen = .settings
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TokenPilotDesign.trust)
                    }
                } else {
                    ProviderOverviewList(
                        snapshots: model.overviewSnapshots,
                        assessments: model.capacityAssessments,
                        presentations: model.capacityPresentations,
                        errors: model.capacityRefreshErrors,
                        runtimeRecoveryRequired: model.capacityRuntimeRecoveryRequired
                    )
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

struct CapacityDisplayItem: Identifiable {
    let assessment: CapacityAssessment
    let presentation: CapacityPresentation

    var id: String { assessment.transitionKey }
    var provider: Provider { assessment.observation.seriesID.provider }
    var valueKind: CapacityUnit { assessment.observation.value.kind }
    var remainingPercent: Int? { Int(presentation.data["remainingPercent"] ?? "") }
    var usedPercent: Int? { Int(presentation.data["usedPercent"] ?? "") }
    var count: Int? { Int(presentation.data["count"] ?? "") }
    var tokens: Int? { Int(presentation.data["tokens"] ?? "") }
    var resetAt: Date? { assessment.observation.resetAt }

    var progressPercent: Int? {
        valueKind == .percent ? remainingPercent : nil
    }

    var progressColor: Color {
        TokenPilotDesign.quotaRiskColor(assessment.risk, eligibility: assessment.alertEligibility)
    }

    func title(language: TokenPilotLanguage) -> String {
        "\(localized(provider.displayName, language: language)) · \(seriesLabel(language: language))"
    }

    func seriesLabel(language: TokenPilotLanguage) -> String {
        let series = assessment.observation.seriesID
        switch series.unit {
        case .percent:
            if let duration = series.durationMinutes {
                return durationLabel(duration, language: language)
            }
            switch series.providerWindowID {
            case "five-hour": return localized("5h", language: language)
            case "seven-day": return localized("Week", language: language)
            default: return localized("Limit", language: language)
            }
        case .currency:
            return localized("Balance", language: language)
        case .requestCount:
            return localized("Requests", language: language)
        case .tokens:
            return localized("Context", language: language)
        }
    }

    func primaryValue(language: TokenPilotLanguage) -> String {
        switch valueKind {
        case .percent:
            guard let remainingPercent else { return "—" }
            return "\(remainingPercent)%"
        case .currency:
            guard let amount = presentation.data["amount"],
                  let currency = presentation.data["currency"] else {
                return "—"
            }
            return formattedMoney(amount: amount, currency: currency)
        case .requestCount:
            guard let count else { return "—" }
            return "\(TokenPilotFormatters.compactNumber(count)) \(localized("Requests", language: language))"
        case .tokens:
            guard let tokens else { return "—" }
            return "\(TokenPilotFormatters.compactNumber(tokens)) \(localized("tok", language: language))"
        }
    }

    func statusLabel(language: TokenPilotLanguage) -> String {
        if assessment.alertEligibility == .percent {
            switch assessment.risk {
            case .critical: return localized("Critical", language: language)
            case .warning: return localized("Warning", language: language)
            case .normal: return localized("Stable", language: language)
            case .informational: return localized("Informational", language: language)
            case .stale: return localized("Stale", language: language)
            case .unavailable: return localized("Unavailable", language: language)
            }
        }
        return provenanceLabel(language: language)
    }

    func freshnessLabel(language: TokenPilotLanguage) -> String {
        switch assessment.freshness {
        case .fresh: return localized("Fresh", language: language)
        case .stale: return localized("Stale", language: language)
        case .unavailable: return localized("Unavailable", language: language)
        }
    }

    func provenanceLabel(language: TokenPilotLanguage) -> String {
        switch assessment.eligibilityReason {
        case .eligible:
            return localized("Provider reported", language: language)
        case .unsupportedSource:
            switch assessment.observation.stability {
            case .compatibilityBridge:
                return localized("Bridge", language: language)
            case .experimentalTransport:
                return localized("Experimental", language: language)
            case .manual:
                return localized("Manual source", language: language)
            case .unavailable:
                return localized("Unavailable", language: language)
            case .supported:
                return localized("Unsupported source", language: language)
            }
        case .manualSource:
            return localized("Manual source", language: language)
        case .staleEvidence:
            return localized("Stale evidence", language: language)
        case .activityOnly:
            return localized("Activity only", language: language)
        case .invalidEvidence:
            return localized("Unavailable", language: language)
        case .pendingBalanceBinding:
            return localized("Pending balance", language: language)
        }
    }

    func actionLabel(language: TokenPilotLanguage) -> String {
        switch assessment.actionKey {
        case .waitForReset: return localized("Wait for reset", language: language)
        case .refreshProvider: return localized("Refresh provider", language: language)
        case .reviewSource: return localized("Review source", language: language)
        case .reviewExperimentalConnector: return localized("Review experimental connector", language: language)
        case .enterManualValue: return localized("Enter manual value", language: language)
        case .reviewBalance: return localized("Review balance", language: language)
        case .openProviderDiagnostics: return localized("Open Provider Diagnostics", language: language)
        }
    }

    func resetText(language: TokenPilotLanguage) -> String {
        guard let resetAt else { return localized("No reset", language: language) }
        return "\(localized("Reset", language: language)) \(TokenPilotFormatters.remainingTime(until: resetAt))"
    }

    func observedText(language: TokenPilotLanguage) -> String {
        "\(localized("Last updated", language: language)) \(TokenPilotFormatters.clock(assessment.observation.observedAt))"
    }

    func detailText(language: TokenPilotLanguage) -> String {
        [
            resetText(language: language),
            provenanceLabel(language: language),
            freshnessLabel(language: language)
        ].joined(separator: " · ")
    }

    func progressAccessibilityValue(language: TokenPilotLanguage) -> String {
        if let remainingPercent, let usedPercent {
            return "\(localized("Remaining", language: language)) \(remainingPercent)%, \(localized("Used", language: language)) \(usedPercent)%"
        }
        if let remainingPercent {
            return "\(localized("Remaining", language: language)) \(remainingPercent)%"
        }
        return localized("Unavailable", language: language)
    }

    private func durationLabel(_ minutes: Int, language: TokenPilotLanguage) -> String {
        if minutes == 300 { return localized("5h", language: language) }
        if minutes == 10_080 { return localized("Week", language: language) }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1_440, minutes % 60 == 0 { return "\(minutes / 60)h" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        return "\(minutes)min"
    }

    private func formattedMoney(amount: String, currency: String) -> String {
        guard let decimal = Decimal(string: amount) else {
            return "\(currency.uppercased()) \(amount)"
        }
        let value = NSDecimalNumber(decimal: decimal).doubleValue
        if currency.uppercased() == "USD" {
            return String(format: "$%.2f", value)
        }
        return "\(currency.uppercased()) \(String(format: "%.2f", value))"
    }
}

private func capacityDisplayItems(
    assessments: [CapacityAssessment],
    presentations: [CapacityPresentation]
) -> [CapacityDisplayItem] {
    Array(zip(assessments, presentations)).map {
        CapacityDisplayItem(assessment: $0.0, presentation: $0.1)
    }
}

private func capacityDisplayRank(_ item: CapacityDisplayItem) -> Int {
    let eligibilityRank: Int
    switch item.assessment.alertEligibility {
    case .percent: eligibilityRank = 100
    case .balance: eligibilityRank = 70
    case .ineligible: eligibilityRank = 20
    }

    let riskRank: Int
    switch item.assessment.risk {
    case .critical: riskRank = 60
    case .warning: riskRank = 50
    case .normal: riskRank = 40
    case .informational: riskRank = 30
    case .stale: riskRank = 10
    case .unavailable: riskRank = 0
    }

    return eligibilityRank + riskRank
}

struct UsageSummaryCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 12) {
            if let primaryItem {
                summaryContent(for: primaryItem)
            } else {
                unavailableContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var items: [CapacityDisplayItem] {
        capacityDisplayItems(
            assessments: model.capacityAssessments,
            presentations: model.capacityPresentations
        )
    }

    private var primaryItem: CapacityDisplayItem? {
        items.sorted { capacityDisplayRank($0) > capacityDisplayRank($1) }.first
    }

    private var accessibilityLabel: String {
        guard let primaryItem else {
            return "\(localized("Capacity unavailable", language: language)). \(unavailableDetail)"
        }
        return [
            primaryItem.title(language: language),
            primaryItem.primaryValue(language: language),
            primaryItem.freshnessLabel(language: language),
            primaryItem.provenanceLabel(language: language),
            primaryItem.actionLabel(language: language)
        ].joined(separator: ", ")
    }

    @ViewBuilder
    private func summaryContent(for item: CapacityDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title(language: language))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                    Text(item.primaryValue(language: language))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.statusLabel(language: language))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.progressColor)
                        .lineLimit(1)
                    Text(item.resetText(language: language))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            if let progressPercent = item.progressPercent {
                ProgressLine(
                    percent: progressPercent,
                    color: item.progressColor,
                    accessibilityLabel: localized("Remaining capacity", language: language),
                    accessibilityValue: item.progressAccessibilityValue(language: language)
                )
            }

            HStack(spacing: 6) {
                SemanticChip(
                    label: item.freshnessLabel(language: language),
                    systemImage: item.assessment.freshness == .fresh ? "checkmark.seal" : "clock",
                    color: TokenPilotDesign.freshnessColor(item.assessment.freshness)
                )
                SemanticChip(
                    label: item.provenanceLabel(language: language),
                    systemImage: provenanceIcon(for: item),
                    color: TokenPilotDesign.trust
                )
                SemanticChip(
                    label: item.actionLabel(language: language),
                    systemImage: "arrow.forward.circle",
                    color: TokenPilotDesign.textSecondary
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                summaryMetric(
                    label: localized("Today tokens", language: language),
                    value: "\(TokenPilotFormatters.compactNumber(model.overviewUsage.metrics.totalTokens)) \(localized("tok", language: language))"
                )
                summaryMetric(
                    label: localized("Reset", language: language),
                    value: item.resetAt.map { TokenPilotFormatters.clock($0) } ?? "—"
                )
                summaryMetric(
                    label: localized("Action", language: language),
                    value: item.actionLabel(language: language)
                )
            }

            if let error = model.capacityRefreshErrors.first {
                CapacityErrorInline(error: error)
            }
        }
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Capacity unavailable", language: language))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                    Text("—")
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                }
                Spacer(minLength: 0)
                SemanticChip(
                    label: unavailableStatus,
                    systemImage: "exclamationmark.circle",
                    color: TokenPilotDesign.textSecondary
                )
            }

            Text(unavailableDetail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                SemanticChip(label: localized("Unavailable", language: language), systemImage: "slash.circle", color: TokenPilotDesign.textSecondary)
                SemanticChip(label: localized("Open Provider Diagnostics", language: language), systemImage: "wrench.and.screwdriver", color: TokenPilotDesign.textSecondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                summaryMetric(
                    label: localized("Today tokens", language: language),
                    value: "\(TokenPilotFormatters.compactNumber(model.overviewUsage.metrics.totalTokens)) \(localized("tok", language: language))"
                )
                summaryMetric(label: localized("Reset", language: language), value: "—")
                summaryMetric(label: localized("Action", language: language), value: localized("Connect providers in Settings", language: language))
            }
        }
    }

    private var unavailableStatus: String {
        if model.capacityRuntimeRecoveryRequired {
            return localized("Runtime recovery required", language: language)
        }
        if let error = model.capacityRefreshErrors.first {
            return error.category.localizedLabel(language: language)
        }
        return localized("No trusted capacity", language: language)
    }

    private var unavailableDetail: String {
        if model.capacityRuntimeRecoveryRequired {
            return localized("Capacity runtime recovery required", language: language)
        }
        if let error = model.capacityRefreshErrors.first {
            return error.redactedMessage
        }
        return localized("Connect providers in Settings", language: language)
    }

    private func provenanceIcon(for item: CapacityDisplayItem) -> String {
        switch item.assessment.eligibilityReason {
        case .manualSource:
            return "person.crop.circle"
        case .unsupportedSource:
            return item.assessment.observation.stability == .experimentalTransport ? "flask" : "link"
        case .eligible:
            return "checkmark.shield"
        case .staleEvidence:
            return "clock.arrow.circlepath"
        case .activityOnly:
            return "waveform.path.ecg"
        case .invalidEvidence:
            return "slash.circle"
        case .pendingBalanceBinding:
            return "creditcard"
        }
    }

    private func summaryMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderOverviewList: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshots: [ProviderSnapshot]
    let assessments: [CapacityAssessment]
    let presentations: [CapacityPresentation]
    let errors: [CapacityRefreshError]
    let runtimeRecoveryRequired: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(localized("Providers", language: language), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(TokenPilotDesign.textPrimary)

                if providerOrder.isEmpty {
                    EmptyInlineState(text: localized("No trusted capacity", language: language))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(providerOrder.enumerated()), id: \.element) { index, provider in
                            providerRow(provider)
                            if index < providerOrder.count - 1 {
                                Divider()
                                    .overlay(TokenPilotDesign.border.opacity(0.72))
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }
    }

    private var items: [CapacityDisplayItem] {
        capacityDisplayItems(assessments: assessments, presentations: presentations)
    }

    private var providerOrder: [Provider] {
        var ordered: [Provider] = []
        func append(_ provider: Provider) {
            if !ordered.contains(provider) {
                ordered.append(provider)
            }
        }

        for provider in snapshots.map(\.provider) {
            append(provider)
        }
        for provider in items.map(\.provider) {
            append(provider)
        }
        for provider in errors.map(\.provider) {
            append(provider)
        }
        return ordered
    }

    @ViewBuilder
    private func providerRow(_ provider: Provider) -> some View {
        let providerItems = items
            .filter { $0.provider == provider }
            .sorted { capacityDisplayRank($0) > capacityDisplayRank($1) }
        let providerErrors = errors.filter { $0.provider == provider }
        let snapshot = snapshots.first { $0.provider == provider }

        if providerItems.isEmpty {
            ProviderCapacityUnavailableRow(
                provider: provider,
                snapshot: snapshot,
                errors: providerErrors,
                runtimeRecoveryRequired: runtimeRecoveryRequired
            )
        } else {
            ProviderCapacityRow(
                provider: provider,
                items: providerItems,
                errors: providerErrors
            )
        }
    }
}

struct ProviderCapacityRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    let provider: Provider
    let items: [CapacityDisplayItem]
    let errors: [CapacityRefreshError]

    var body: some View {
        let primary = items[0]

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProviderSignatureMark(provider: provider)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(provider.displayName, language: language))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                    Text(primary.detailText(language: language))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                Text(primary.primaryValue(language: language))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(primary.progressColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            HStack(spacing: 5) {
                SemanticChip(
                    label: primary.freshnessLabel(language: language),
                    systemImage: primary.assessment.freshness == .fresh ? "checkmark.seal" : "clock",
                    color: TokenPilotDesign.freshnessColor(primary.assessment.freshness)
                )
                SemanticChip(
                    label: primary.provenanceLabel(language: language),
                    systemImage: provenanceIcon(for: primary),
                    color: TokenPilotDesign.trust
                )
                SemanticChip(
                    label: primary.actionLabel(language: language),
                    systemImage: "arrow.forward.circle",
                    color: TokenPilotDesign.textSecondary
                )
            }

            if let progressPercent = primary.progressPercent {
                ProgressLine(
                    percent: progressPercent,
                    color: primary.progressColor,
                    accessibilityLabel: "\(localized(provider.displayName, language: language)) \(localized("Remaining capacity", language: language))",
                    accessibilityValue: primary.progressAccessibilityValue(language: language)
                )
            }

            ForEach(Array(items.dropFirst())) { item in
                CapacitySignalLine(item: item)
            }

            if let error = errors.first {
                CapacityErrorInline(error: error)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(primary: primary))
    }

    private func accessibilityLabel(primary: CapacityDisplayItem) -> String {
        [
            localized(provider.displayName, language: language),
            primary.primaryValue(language: language),
            primary.freshnessLabel(language: language),
            primary.provenanceLabel(language: language),
            primary.actionLabel(language: language)
        ].joined(separator: ", ")
    }

    private func provenanceIcon(for item: CapacityDisplayItem) -> String {
        switch item.assessment.eligibilityReason {
        case .manualSource:
            return "person.crop.circle"
        case .unsupportedSource:
            return item.assessment.observation.stability == .experimentalTransport ? "flask" : "link"
        case .eligible:
            return "checkmark.shield"
        case .staleEvidence:
            return "clock.arrow.circlepath"
        case .activityOnly:
            return "waveform.path.ecg"
        case .invalidEvidence:
            return "slash.circle"
        case .pendingBalanceBinding:
            return "creditcard"
        }
    }
}

struct CapacitySignalLine: View {
    @Environment(\.tokenPilotLanguage) private var language
    let item: CapacityDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.seriesLabel(language: language))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .leading)

                Text(item.primaryValue(language: language))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(item.actionLabel(language: language))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(item.detailText(language: language))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.74)

            if let progressPercent = item.progressPercent {
                ProgressLine(
                    percent: progressPercent,
                    color: item.progressColor,
                    accessibilityLabel: item.title(language: language),
                    accessibilityValue: item.progressAccessibilityValue(language: language)
                )
            }
        }
    }
}

struct ProviderCapacityUnavailableRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    let provider: Provider
    let snapshot: ProviderSnapshot?
    let errors: [CapacityRefreshError]
    let runtimeRecoveryRequired: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProviderSignatureMark(provider: provider)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(provider.displayName, language: language))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                    Text(detailText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                Text(localized("Unavailable", language: language))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                SemanticChip(label: statusLabel, systemImage: statusIcon, color: TokenPilotDesign.textSecondary)
                SemanticChip(label: actionLabel, systemImage: "arrow.forward.circle", color: TokenPilotDesign.textSecondary)
            }

            if let error = errors.first {
                CapacityErrorInline(error: error)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(localized(provider.displayName, language: language)), \(statusLabel), \(actionLabel)")
    }

    private var statusLabel: String {
        if runtimeRecoveryRequired {
            return localized("Runtime recovery required", language: language)
        }
        if let error = errors.first {
            return error.category.localizedLabel(language: language)
        }
        if snapshot?.dataSource == .mock {
            return localized("Mock preview", language: language)
        }
        if snapshot?.dataSource == .manual || snapshot?.confidence == .manual {
            return localized("Manual source", language: language)
        }
        if snapshot?.isStale == true {
            return localized("Stale", language: language)
        }
        return localized("No trusted capacity", language: language)
    }

    private var statusIcon: String {
        if snapshot?.dataSource == .mock { return "eye" }
        if snapshot?.dataSource == .manual || snapshot?.confidence == .manual { return "person.crop.circle" }
        if snapshot?.isStale == true { return "clock" }
        return "slash.circle"
    }

    private var actionLabel: String {
        if runtimeRecoveryRequired {
            return localized("Open Provider Diagnostics", language: language)
        }
        if errors.isEmpty == false {
            return localized("Refresh provider", language: language)
        }
        return localized("Open Provider Diagnostics", language: language)
    }

    private var detailText: String {
        if runtimeRecoveryRequired {
            return localized("Capacity runtime recovery required", language: language)
        }
        if let error = errors.first {
            return error.redactedMessage
        }
        if snapshot?.dataSource == .mock {
            return localized("Sample data is not live capacity", language: language)
        }
        if snapshot?.dataSource == .manual || snapshot?.confidence == .manual {
            return localized("Manual values are not live quota", language: language)
        }
        return localized("No trusted capacity presentation", language: language)
    }
}

struct CapacityErrorInline: View {
    @Environment(\.tokenPilotLanguage) private var language
    let error: CapacityRefreshError

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TokenPilotDesign.textSecondary)
            Text(error.redactedMessage)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            SemanticChip(
                label: error.category.localizedLabel(language: language),
                systemImage: "info.circle",
                color: TokenPilotDesign.textSecondary
            )
        }
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
        let progressPercent = target > 0 ? min(100, Int((Double(today) / Double(target) * 100).rounded())) : 0

        Button {
            showTargetPicker = true
        } label: {
            GlassCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label(localized("Daily challenge", language: language), systemImage: "target")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(progressPercent)%")
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                            .foregroundStyle(TokenPilotDesign.goal)
                    }
                    HStack {
                        Text("\(TokenPilotFormatters.compactNumber(today)) / \(TokenPilotFormatters.compactNumber(target))")
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                        Spacer()
                        Text(localized("Today tokens", language: language))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                    }
                    ProgressLine(
                        percent: progressPercent,
                        color: TokenPilotDesign.goal,
                        accessibilityLabel: localized("Daily challenge progress", language: language),
                        accessibilityValue: "\(progressPercent)%"
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("g", modifiers: [.command])
        .accessibilityLabel(localized("Daily challenge target", language: language))
        .accessibilityValue("\(TokenPilotFormatters.compactNumber(today)) / \(TokenPilotFormatters.compactNumber(target)), \(progressPercent)%")
        .accessibilityHint(localized("Change daily challenge target", language: language))
        .confirmationDialog(
            localized("Daily challenge target", language: language),
            isPresented: $showTargetPicker,
            titleVisibility: .visible
        ) {
            ForEach(presetTargets, id: \.self) { preset in
                Button("\(TokenPilotFormatters.compactNumber(preset)) \(localized("tok", language: language))") {
                    onTargetChange?(preset)
                }
            }
            Button(localized("Cancel", language: language), role: .cancel) {}
        }
    }
}

private extension CapacityRefreshErrorCategory {
    func localizedLabel(language: TokenPilotLanguage) -> String {
        switch self {
        case .disabled: return localized("Disabled", language: language)
        case .sourceUnavailable: return localized("Source unavailable", language: language)
        case .authenticationRequired: return localized("Authentication required", language: language)
        case .processFailure: return localized("Process failure", language: language)
        case .timeout: return localized("Timeout", language: language)
        case .cancelled: return localized("Cancelled", language: language)
        case .malformedResponse: return localized("Malformed response", language: language)
        case .unsupportedSeries: return localized("Unsupported source", language: language)
        case .outputLimitExceeded: return localized("Output limit exceeded", language: language)
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
