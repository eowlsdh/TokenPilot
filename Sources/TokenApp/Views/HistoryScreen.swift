import SwiftUI
import TokenCore

private enum HistorySourceLabelFormatter {
    static func localizationKey(for source: UsageDataSource) -> String {
        localizationKey(for: source.rawValue)
    }

    static func localizationKey(for source: String) -> String {
        switch source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "officialstatusline", "official statusline":
            return "source.officialStatusline"
        case "officialtelemetry", "official telemetry":
            return "source.officialTelemetry"
        case "webusage", "web usage", "limit hints":
            return "source.limitHints"
        case "locallog", "local log":
            return "source.localLog"
        case "manual", "manual entry":
            return "source.manual"
        case "estimated", "est.":
            return "source.estimated"
        case "mock", "debug-fixture", "debug fixture":
            return "source.mock"
        default:
            return "source.unknown"
        }
    }
}

struct HistoryScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    private var hasCapacitySignals: Bool {
        !model.capacityPresentations.isEmpty || !model.limitHistorySamples.isEmpty
    }

    private var capacitySignalCount: Int {
        model.capacityPresentations.count + model.limitHistorySamples.count
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: TokenPilotDesign.sectionSpacing) {
                TokenPilotSectionHeader(
                    title: model.t("Capacity signals"),
                    subtitle: model.t("Provider-reported/manual limit evidence; not token usage analytics."),
                    systemImage: "checkmark.seal"
                ) {
                    SemanticChip(
                        label: "\(capacitySignalCount)",
                        systemImage: "list.bullet",
                        role: .truth
                    )
                }
                .accessibilityAddTraits(.isHeader)

                if model.capacityPresentations.isEmpty && model.limitHistorySamples.isEmpty {
                    HistoryCapacityEmptyState(model: model)
                } else {
                    if !model.capacityPresentations.isEmpty {
                        CurrentCapacitySignalCard(
                            assessments: model.capacityAssessments,
                            presentations: model.capacityPresentations,
                            model: model
                        )
                    }
                    if !model.limitHistorySamples.isEmpty {
                        HistoryLimitSignalCard(samples: model.limitHistorySamples, model: model)
                    }
                }

                TokenPilotSectionHeader(
                    title: model.t("Usage events"),
                    subtitle: model.t("Token totals come only from stored usage events."),
                    systemImage: "doc.text.magnifyingglass"
                )
                .accessibilityAddTraits(.isHeader)

                if model.historyUsage.events.isEmpty {
                    HistoryEmptyState(hasLimitSignals: hasCapacitySignals, model: model)
                } else {
                    HistoryUsageSummaryCard(model: model)
                    if model.historyUsage.sevenDayBars.contains(where: { $0.tokens > 0 }) {
                        HistorySevenDayTrendCard(bars: model.historyUsage.sevenDayBars, model: model)
                    }
                    if !model.historyUsage.modelBreakdown.isEmpty {
                        HistoryModelBreakdownCard(shares: model.historyUsage.modelBreakdown, model: model)
                    }
                    HistoryUsageTimelineCard(events: model.historyUsage.events, model: model)
                    HistoryExportCard(model: model)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

struct CurrentCapacitySignalCard: View {
    let assessments: [CapacityAssessment]
    let presentations: [CapacityPresentation]
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        let visibleItems = Array(items.prefix(3))

        GlassCard(padding: 10, surface: .cardElevated) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Current capacity evidence"), systemImage: "checkmark.seal")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    StatusBadge(label: "\(items.count)", color: TokenPilotDesign.textSecondary)
                }

                if visibleItems.isEmpty {
                    EmptyInlineState(text: model.t("No trusted capacity presentation"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            capacitySignalRow(item)
                            if index < visibleItems.count - 1 {
                                TokenPilotSeparator()
                                    .padding(.vertical, TokenPilotDesign.Spacing.md)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.t("Capacity signals"))
        .accessibilityValue(accessibilitySummary)
    }

    private var items: [CapacityDisplayItem] {
        Array(zip(assessments, presentations))
            .map { CapacityDisplayItem(assessment: $0.0, presentation: $0.1) }
            .sorted {
                if $0.observedAt != $1.observedAt {
                    return $0.observedAt > $1.observedAt
                }
                return $0.title(language: model.settings.localization.language) < $1.title(language: model.settings.localization.language)
            }
    }

    private var accessibilitySummary: String {
        items.prefix(3)
            .map { accessibilityLabel(for: $0) }
            .joined(separator: "; ")
    }

    private func capacitySignalRow(_ item: CapacityDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.sm) {
            HStack(alignment: .top, spacing: TokenPilotDesign.Spacing.lg) {
                ProviderSignatureMark(provider: item.provider, size: 24)

                VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
                    Text(item.title(language: model.settings.localization.language))
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(item.primaryValue(language: model.settings.localization.language))
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(item.progressColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    capacityEvidenceLine(for: item)
                }

                Spacer(minLength: 0)

                capacityStatusCue(for: item)
            }

            if let progressPercent = item.progressPercent {
                ProgressLine(
                    percent: progressPercent,
                    color: item.progressColor,
                    accessibilityLabel: item.title(language: model.settings.localization.language),
                    accessibilityValue: item.progressAccessibilityValue(language: model.settings.localization.language)
                )
            }
        }
        .accessibilityElement(children: actionIsButton(item) ? .contain : .combine)
        .accessibilityLabel(accessibilityLabel(for: item))
    }

    @ViewBuilder
    private func capacityEvidenceLine(for item: CapacityDisplayItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.sm) {
                capacityEvidenceText(for: item)
                actionControl(for: item)
            }

            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
                capacityEvidenceText(for: item)
                actionControl(for: item)
            }
        }
    }

    private func capacityEvidenceText(for item: CapacityDisplayItem) -> some View {
        Text(capacityEvidenceDetails(for: item))
            .font(TokenPilotDesign.Typography.caption)
            .foregroundStyle(TokenPilotDesign.textSecondary)
            .lineLimit(2)
            .minimumScaleFactor(0.78)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func capacityEvidenceDetails(for item: CapacityDisplayItem) -> String {
        var details = [
            "\(model.t("Provenance")): \(item.provenanceLabel(language: model.settings.localization.language))",
            "\(model.t("Freshness")): \(item.freshnessLabel(language: model.settings.localization.language))",
            item.resetText(language: model.settings.localization.language)
        ]

        if !actionIsButton(item) {
            details.append("\(model.t("Action")): \(actionTitle(for: item))")
        }

        return details.joined(separator: " · ")
    }

    @ViewBuilder
    private func capacityStatusCue(for item: CapacityDisplayItem) -> some View {
        switch item.assessment.risk {
        case .critical, .warning:
            StatusBadge(
                label: item.statusLabel(language: model.settings.localization.language),
                color: item.statusColor,
                systemImage: capacityStatusIcon(for: item)
            )
        case .normal, .informational, .stale, .unavailable:
            EmptyView()
        }
    }

    private func capacityStatusIcon(for item: CapacityDisplayItem) -> String {
        switch item.assessment.risk {
        case .critical, .warning:
            return "exclamationmark.triangle"
        case .normal, .informational, .stale, .unavailable:
            return "info.circle"
        }
    }

    @ViewBuilder
    private func actionControl(for item: CapacityDisplayItem) -> some View {
        if actionIsButton(item) {
            Button {
                performAction(for: item)
            } label: {
                Label {
                    Text(actionTitle(for: item))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                } icon: {
                    Image(systemName: actionIcon(for: item))
                }
                .font(TokenPilotDesign.Typography.micro)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("\(model.t("Action")): \(actionTitle(for: item))")
            .focusable()
        }
    }

    private func accessibilityLabel(for item: CapacityDisplayItem) -> String {
        [
            item.title(language: model.settings.localization.language),
            item.primaryValue(language: model.settings.localization.language),
            "\(model.t("Provenance")): \(item.provenanceLabel(language: model.settings.localization.language))",
            "\(model.t("Freshness")): \(item.freshnessLabel(language: model.settings.localization.language))",
            item.resetText(language: model.settings.localization.language),
            item.observedText(language: model.settings.localization.language),
            "\(model.t("Action")): \(actionTitle(for: item))"
        ].joined(separator: ", ")
    }


    private func actionIcon(for item: CapacityDisplayItem) -> String {
        switch item.assessment.actionKey {
        case .waitForReset:
            return "clock"
        case .refreshProvider:
            return "arrow.clockwise"
        case .reviewSource, .openProviderDiagnostics:
            return "wrench.and.screwdriver"
        case .reviewExperimentalConnector:
            return "flask"
        case .enterManualValue:
            return "pencil"
        case .reviewBalance:
            return "creditcard"
        }
    }

    private func actionTitle(for item: CapacityDisplayItem) -> String {
        item.actionLabel(language: model.settings.localization.language)
    }

    private func actionIsButton(_ item: CapacityDisplayItem) -> Bool {
        item.assessment.actionKey != .waitForReset
    }

    private func performAction(for item: CapacityDisplayItem) {
        if item.assessment.actionKey == .refreshProvider {
            Task { await model.refresh() }
        } else {
            model.selectedScreen = .settings
        }
    }
}

struct HistoryLimitSignalCard: View {
    let samples: [ProviderLimitSample]
    @ObservedObject var model: TokenPilotViewModel

    private var sortedSamples: [ProviderLimitSample] {
        samples.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.id < rhs.id
        }
    }

    private var visibleSamples: [ProviderLimitSample] {
        Array(sortedSamples.prefix(2))
    }

    private var isPreviewingSamples: Bool {
        samples.count > visibleSamples.count
    }

    private var sampleStatusText: String {
        isPreviewingSamples ? "\(visibleSamples.count)/\(samples.count)" : "\(samples.count)"
    }

    private var samplePreviewText: String {
        "\(model.t("Latest limit signals")): \(visibleSamples.count)/\(samples.count)"
    }

    private var samplePreviewSubtitle: String {
        let base = model.t("Historical capacity signals are kept separate from usage event analytics.")
        guard isPreviewingSamples else { return base }
        return "\(samplePreviewText). \(base)"
    }

    private var sampleAccessibilityValue: String {
        guard isPreviewingSamples else {
            return "\(model.t("Capacity signals")) \(samples.count)"
        }
        return "\(samplePreviewText) · \(model.t("Capacity signals")) \(samples.count)"
    }

    var body: some View {
        DisclosureCard(
            padding: 10,
            initiallyExpanded: true,
            accessibilityLabel: model.t("Recorded capacity signal history"),
            accessibilityValue: sampleAccessibilityValue
        ) {
            DisclosureSummaryRow(
                title: model.t("Recorded capacity signal history"),
                subtitle: samplePreviewSubtitle,
                status: sampleStatusText,
                statusColor: TokenPilotDesign.textSecondary,
                systemImage: "waveform.path.ecg.rectangle"
            )
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(visibleSamples.enumerated()), id: \.element.id) { index, sample in
                    HistoryLimitSignalRow(sample: sample, model: model)
                    if index < visibleSamples.count - 1 {
                        TokenPilotSeparator()
                            .padding(.vertical, TokenPilotDesign.Spacing.md)
                    }
                }
            }
        }
    }
}

struct HistoryLimitSignalRow: View {
    let sample: ProviderLimitSample
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.sm) {
            HStack(alignment: .top, spacing: TokenPilotDesign.Spacing.lg) {
                ProviderSignatureMark(provider: sample.provider, size: 24)

                VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
                    Text(limitTitle)
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(limitEvidenceLine)
                        .font(TokenPilotDesign.Typography.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: TokenPilotDesign.Spacing.xs) {
                    Text(String(format: model.t("Remaining %d%%"), sample.remainingPercent))
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(TokenPilotDesign.riskColor(sample.usedPercent))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    limitStatusCue
                }
            }

            ProgressLine(
                percent: sample.remainingPercent,
                color: TokenPilotDesign.riskColor(sample.usedPercent),
                accessibilityLabel: limitTitle,
                accessibilityValue: progressAccessibilityValue
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var limitTitle: String {
        "\(model.t(sample.provider.displayName)) · \(sample.window.localizedLabel(language: model.settings.localization.language))"
    }

    private var limitEvidenceLine: String {
        [
            "\(model.t("Provenance")): \(sourceLabel)",
            "\(model.t("Confidence")): \(sample.confidence.localizedLabel(language: model.settings.localization.language))",
            "\(model.t("Recorded")) \(TokenPilotFormatters.clock(sample.timestamp, language: model.settings.localization.language))"
        ].joined(separator: " · ")
    }

    private var progressAccessibilityValue: String {
        "\(model.t("Remaining")) \(sample.remainingPercent)%, \(model.t("Used")) \(sample.usedPercent)%"
    }

    @ViewBuilder
    private var limitStatusCue: some View {
        if sample.usedPercent >= 70 {
            StatusBadge(
                label: "\(model.t("Risk")) \(sample.usedPercent)%",
                color: TokenPilotDesign.riskColor(sample.usedPercent),
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private var accessibilitySummary: String {
        [
            model.t(sample.provider.displayName),
            sample.window.localizedLabel(language: model.settings.localization.language),
            String(format: model.t("Remaining %d%%"), sample.remainingPercent),
            "\(model.t("Risk")) \(sample.usedPercent)%",
            "\(model.t("Provenance")): \(sourceLabel)",
            sample.confidence.localizedLabel(language: model.settings.localization.language),
            "\(model.t("Recorded")) \(TokenPilotFormatters.clock(sample.timestamp, language: model.settings.localization.language))"
        ].joined(separator: ", ")
    }

    private var sourceLabel: String {
        model.t(HistorySourceLabelFormatter.localizationKey(for: sample.source))
    }
}

struct HistorySevenDayTrendCard: View {
    let bars: [DailyUsageBar]
    @ObservedObject var model: TokenPilotViewModel

    private var peakTokens: Int {
        max(bars.map(\.tokens).max() ?? 0, 1)
    }

    private var total: Int {
        bars.reduce(0) { $0 + $1.tokens }
    }

    private var activeDays: Int {
        bars.filter { $0.tokens > 0 }.count
    }

    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.lg) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Last 7 days"), systemImage: "chart.bar")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    SemanticChip(
                        label: TokenPilotFormatters.compactNumber(total),
                        systemImage: "number",
                        role: .neutral
                    )
                }

                HStack(alignment: .bottom, spacing: TokenPilotDesign.Spacing.sm) {
                    ForEach(bars) { bar in
                        HistoryTrendBar(bar: bar, peakTokens: peakTokens, isPeak: bar.tokens == peakTokens && bar.tokens > 0)
                    }
                }
                .frame(height: 38)

                Text(summaryText)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var summaryText: String {
        "\(activeDays)/\(bars.count) \(model.t("active days")) · \(model.t("Local activity, not provider quota"))"
    }

    private var accessibilitySummary: String {
        let detail = bars
            .map { "\($0.dayLabel) \(TokenPilotFormatters.compactNumber($0.tokens))" }
            .joined(separator: ", ")
        return "\(model.t("Last 7 days")), \(TokenPilotFormatters.compactNumber(total)), \(detail)"
    }
}

private struct HistoryTrendBar: View {
    let bar: DailyUsageBar
    let peakTokens: Int
    let isPeak: Bool

    private var fillRatio: Double {
        // Keep a visible floor so an active-but-tiny day is never mistaken for an idle day.
        guard bar.tokens > 0 else { return 0 }
        return max(Double(bar.tokens) / Double(peakTokens), 0.06)
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isPeak ? TokenPilotDesign.calm : TokenPilotDesign.trust.opacity(0.55))
                        .frame(height: max(geometry.size.height * fillRatio, bar.tokens > 0 ? 2 : 1))
                }
                .frame(maxWidth: .infinity)
            }

            Text(bar.dayLabel)
                .font(TokenPilotDesign.Typography.micro)
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct HistoryModelBreakdownCard: View {
    let shares: [ModelUsageShare]
    @ObservedObject var model: TokenPilotViewModel

    @State private var isExpanded = false

    private var visibleShares: [ModelUsageShare] {
        isExpanded ? Array(shares.prefix(12)) : Array(shares.prefix(4))
    }

    private var hasMore: Bool { shares.count > 4 }

    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.lg) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Models"), systemImage: "cpu")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    SemanticChip(
                        label: "\(shares.count)",
                        systemImage: "list.number",
                        role: .neutral
                    )
                }

                VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.md) {
                    ForEach(visibleShares) { share in
                        HistoryModelRow(share: share, model: model)
                    }
                }

                if hasMore {
                    Button(isExpanded ? model.t("Show fewer models") : model.t("Show all models")) {
                        withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.calm)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.t("Models"))
    }
}

private struct HistoryModelRow: View {
    let share: ModelUsageShare
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.sm) {
                Circle()
                    .fill(TokenPilotDesign.accent(for: share.provider))
                    .frame(width: 7, height: 7)

                Text(share.model)
                    .font(TokenPilotDesign.Typography.label)
                    .foregroundStyle(TokenPilotDesign.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: TokenPilotDesign.Spacing.sm)

                Text(TokenPilotFormatters.compactNumber(share.tokens))
                    .font(TokenPilotDesign.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.textPrimary)
            }

            HStack(spacing: TokenPilotDesign.Spacing.sm) {
                ProgressView(value: Double(share.tokenPercent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(TokenPilotDesign.accent(for: share.provider))
                    .frame(height: 3)

                Text("\(share.tokenPercent)%")
                    .font(TokenPilotDesign.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .frame(width: 34, alignment: .trailing)
            }

            Text(detailText)
                .font(TokenPilotDesign.Typography.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(share.model), \(share.tokenPercent)%, \(detailText)")
    }

    private var detailText: String {
        var parts = [
            model.providerDisplayName(share.provider),
            "\(share.requestCount) \(model.t("Requests"))"
        ]
        if let cost = share.estimatedCostUSD, cost > 0 {
            parts.append("\(TokenPilotFormatters.cost(cost)) \(model.t("est."))")
        }
        return parts.joined(separator: " · ")
    }
}

struct HistoryUsageSummaryCard: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.lg) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Usage event summary"), systemImage: "number")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    SemanticChip(
                        label: model.t(model.selectedHistoryPeriod.label),
                        systemImage: "calendar",
                        role: .neutral
                    )
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: TokenPilotDesign.Spacing.md),
                        GridItem(.flexible(), spacing: TokenPilotDesign.Spacing.md)
                    ],
                    alignment: .leading,
                    spacing: TokenPilotDesign.Spacing.md
                ) {
                    HistoryUsageMetricTile(
                        label: model.t("Total tokens"),
                        value: TokenPilotFormatters.compactNumber(metrics.totalTokens)
                    )
                    HistoryUsageMetricTile(
                        label: model.t("Requests"),
                        value: "\(metrics.requestCount)"
                    )
                    HistoryUsageMetricTile(
                        label: model.t("Input"),
                        value: TokenPilotFormatters.compactNumber(metrics.inputTokens)
                    )
                    HistoryUsageMetricTile(
                        label: model.t("Output"),
                        value: TokenPilotFormatters.compactNumber(metrics.outputTokens)
                    )
                    HistoryUsageMetricTile(
                        label: model.t("Cache tokens"),
                        value: TokenPilotFormatters.compactNumber(metrics.cacheTokens)
                    )
                    HistoryUsageMetricTile(
                        label: model.t("Est. cost"),
                        value: TokenPilotFormatters.cost(metrics.estimatedCostUSD)
                    )
                    HistoryUsageMetricTile(
                        label: model.t("Most used"),
                        value: metrics.mostUsedProvider.map { model.t($0.displayName) } ?? "—"
                    )
                    HistoryUsageMetricTile(
                        label: model.t("Busiest hour"),
                        value: metrics.busiestHour.map { "\($0):00" } ?? "—"
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.t("Usage event summary"))
        .accessibilityValue(accessibilitySummary)
    }

    private var metrics: UsageMetrics {
        model.historyUsage.metrics
    }

    private var accessibilitySummary: String {
        let mostUsed = metrics.mostUsedProvider.map { model.t($0.displayName) } ?? model.t("No data")
        let busiestHour = metrics.busiestHour.map { "\($0):00" } ?? model.t("No data")
        return [
            "\(model.t("Period")) \(model.t(model.selectedHistoryPeriod.label))",
            "\(model.t("Total tokens")) \(TokenPilotFormatters.compactNumber(metrics.totalTokens))",
            "\(model.t("Input")) \(TokenPilotFormatters.compactNumber(metrics.inputTokens))",
            "\(model.t("Output")) \(TokenPilotFormatters.compactNumber(metrics.outputTokens))",
            "\(model.t("Cache tokens")) \(TokenPilotFormatters.compactNumber(metrics.cacheTokens))",
            "\(model.t("Requests")) \(metrics.requestCount)",
            "\(model.t("Most used")) \(mostUsed)",
            "\(model.t("Busiest hour")) \(busiestHour)"
        ].joined(separator: ", ")
    }
}

struct HistoryUsageMetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xxs) {
            Text(value)
                .font(TokenPilotDesign.Typography.metric)
                .monospacedDigit()
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(label)
                .font(TokenPilotDesign.Typography.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TokenPilotDesign.surface(.cardMuted))
        .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.Radius.sm, style: .continuous))
    }
}

struct HistoryUsageTimelineCard: View {
    let events: [UsageEvent]
    @ObservedObject var model: TokenPilotViewModel

    private var visibleEvents: [UsageEvent] {
        Array(events.sorted { $0.timestamp > $1.timestamp }.prefix(4))
    }

    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.lg) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Recent usage"), systemImage: "clock.arrow.circlepath")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    StatusBadge(label: "\(events.count)", color: TokenPilotDesign.textSecondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, event in
                        HistoryUsageEventRow(event: event, model: model)
                        if index < visibleEvents.count - 1 {
                            TokenPilotSeparator()
                                .padding(.vertical, TokenPilotDesign.Spacing.md)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.t("Usage events"))
    }
}

struct HistoryUsageEventRow: View {
    let event: UsageEvent
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.sm) {
            HStack(alignment: .top, spacing: TokenPilotDesign.Spacing.lg) {
                ProviderSignatureMark(provider: event.provider, size: 22)

                VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
                    Text(eventTitle)
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(eventEvidenceLine)
                        .font(TokenPilotDesign.Typography.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: TokenPilotDesign.Spacing.xxs) {
                    Text(TokenPilotFormatters.compactNumber(event.totalTokens))
                        .font(TokenPilotDesign.Typography.metric)
                        .monospacedDigit()
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(model.t("Total"))
                        .font(TokenPilotDesign.Typography.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                }
            }

        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var eventTitle: String {
        if let modelName = event.model, !modelName.isEmpty {
            return "\(model.t(event.provider.displayName)) · \(modelName)"
        }
        return model.t(event.provider.displayName)
    }

    private var eventDetail: String {
        [
            "\(model.t("Input")) \(TokenPilotFormatters.compactNumber(event.inputTokens))",
            "\(model.t("Output")) \(TokenPilotFormatters.compactNumber(event.outputTokens))",
            "\(model.t("Requests")) \(event.requestCount)"
        ].joined(separator: " · ")
    }

    private var eventEvidenceLine: String {
        [
            eventDetail,
            "\(model.t("Provenance")): \(sourceLabel)",
            "\(model.t("Recorded")) \(TokenPilotFormatters.clock(event.timestamp, language: model.settings.localization.language))",
            qualifierText
        ].joined(separator: " · ")
    }

    private var qualifierText: String {
        if event.isExperimental {
            return model.t("Experimental")
        }
        if event.isEstimated {
            return model.t("Estimated")
        }
        return model.t("Usage events only")
    }

    private var accessibilitySummary: String {
        [
            eventTitle,
            "\(model.t("Total")) \(TokenPilotFormatters.compactNumber(event.totalTokens))",
            eventDetail,
            "\(model.t("Provenance")): \(sourceLabel)",
            "\(model.t("Recorded")) \(TokenPilotFormatters.clock(event.timestamp, language: model.settings.localization.language))",
            qualifierText
        ].joined(separator: ", ")
    }

    private var sourceLabel: String {
        model.t(HistorySourceLabelFormatter.localizationKey(for: event.dataSource))
    }

}

struct HistoryExportCard: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 10, surface: .cardMuted) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.md) {
                HStack(alignment: .center, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Export"), systemImage: "square.and.arrow.down")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Picker(model.t("Format"), selection: $model.exportFormat) {
                        ForEach(UsageExportFormat.allCases) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                    .focusable()

                    Button(model.t("Save")) { model.exportHistory() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(TokenPilotDesign.trust)
                        .focusable()
                }

                Text(privacyCopy)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var privacyCopy: String {
        model.t("Exports selected usage events and provider summaries only. Credentials, secret tokens, chat IDs, webhooks, local file paths, prompts, and responses are not included.")
    }
}

struct HistoryCapacityEmptyState: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(TokenPilotDesign.surface(.cardMuted))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("No capacity signals yet"))
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                    Text(model.t("Run Auto-detect or Provider Diagnostics to recover source health."))
                        .font(TokenPilotDesign.Typography.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.t("Open Provider Diagnostics")) {
                        model.selectedScreen = .settings
                    }
                    .buttonStyle(.bordered)
                    .tint(TokenPilotDesign.calm)
                    .focusable()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct HistoryEmptyState: View {
    let hasLimitSignals: Bool
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: hasLimitSignals ? "doc.text.magnifyingglass" : "tray")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(hasLimitSignals ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(TokenPilotDesign.surface(.cardMuted))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("No usage events recorded"))
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                    Text(model.t(hasLimitSignals ? "Capacity signals are available above, but no token usage events are stored for this period." : "Token totals come only from stored usage events."))
                        .font(TokenPilotDesign.Typography.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.t("Open Provider Diagnostics")) {
                        model.selectedScreen = .settings
                    }
                    .buttonStyle(.bordered)
                    .tint(TokenPilotDesign.calm)
                    .focusable()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
