import SwiftUI
import TokenCore

struct HistoryScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    private var hasCapacitySignals: Bool {
        !model.capacityPresentations.isEmpty || !model.limitHistorySamples.isEmpty
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.sectionSpacing) {
                HistorySectionHeader(
                    title: model.t("Capacity signals"),
                    subtitle: model.t("Provider-reported/manual limit evidence; not token usage analytics.")
                )

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

                HistorySectionHeader(
                    title: model.t("Usage events"),
                    subtitle: model.t("Token totals come only from stored usage events.")
                )

                if model.historyUsage.events.isEmpty {
                    HistoryEmptyState(hasLimitSignals: hasCapacitySignals, model: model)
                } else {
                    GlassCard {
                        LazyVGrid(columns: [
                            GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible()), GridItem(.flexible())
                        ], alignment: .leading, spacing: 10) {
                            historyStat(label: model.t("Total tokens"), value: TokenPilotFormatters.compactNumber(model.historyUsage.metrics.totalTokens))
                            historyStat(label: model.t("Input"), value: TokenPilotFormatters.compactNumber(model.historyUsage.metrics.inputTokens))
                            historyStat(label: model.t("Output"), value: TokenPilotFormatters.compactNumber(model.historyUsage.metrics.outputTokens))
                            historyStat(label: model.t("Cache tokens"), value: TokenPilotFormatters.compactNumber(model.historyUsage.metrics.cacheTokens))
                            historyStat(label: model.t("Est. cost"), value: TokenPilotFormatters.cost(model.historyUsage.metrics.estimatedCostUSD))
                            historyStat(label: model.t("Requests"), value: "\(model.historyUsage.metrics.requestCount)")
                            historyStat(label: model.t("Most used"), value: model.historyUsage.metrics.mostUsedProvider.map { model.t($0.displayName) } ?? "—")
                            historyStat(label: model.t("Busiest hour"), value: model.historyUsage.metrics.busiestHour.map { "\($0):00" } ?? "—")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.t("Usage event summary"))
                    .accessibilityValue(usageSummaryAccessibility)

                    GlassCard {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Label(model.t("Export"), systemImage: "square.and.arrow.down")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Picker(model.t("Format"), selection: $model.exportFormat) {
                                    ForEach(UsageExportFormat.allCases) { format in
                                        Text(format.rawValue.uppercased()).tag(format)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 118)
                                Button(model.t("Save")) { model.exportHistory() }
                                    .buttonStyle(.borderedProminent)
                            }
                            Text(model.t("Exports selected usage events and provider summaries only. Credentials, secret tokens, chat IDs, webhooks, local file paths, prompts, and responses are not included."))
                                .font(.caption2)
                                .foregroundStyle(TokenPilotDesign.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.t("Export"))
                    .accessibilityValue(model.t("Exports selected usage events and provider summaries only. Credentials, secret tokens, chat IDs, webhooks, local file paths, prompts, and responses are not included."))
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var usageSummaryAccessibility: String {
        let metrics = model.historyUsage.metrics
        let mostUsed = metrics.mostUsedProvider.map { model.t($0.displayName) } ?? model.t("No data")
        let busiestHour = metrics.busiestHour.map { "\($0):00" } ?? model.t("No data")
        return [
            "\(model.t("Total tokens")) \(TokenPilotFormatters.compactNumber(metrics.totalTokens))",
            "\(model.t("Input")) \(TokenPilotFormatters.compactNumber(metrics.inputTokens))",
            "\(model.t("Output")) \(TokenPilotFormatters.compactNumber(metrics.outputTokens))",
            "\(model.t("Requests")) \(metrics.requestCount)",
            "\(model.t("Most used")) \(mostUsed)",
            "\(model.t("Busiest hour")) \(busiestHour)"
        ].joined(separator: ", ")
    }


    private func historyStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HistorySectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(TokenPilotDesign.textPrimary)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CurrentCapacitySignalCard: View {
    let assessments: [CapacityAssessment]
    let presentations: [CapacityPresentation]
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        let visibleItems = Array(items.prefix(5))

        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Label(model.t("Current capacity evidence"), systemImage: "checkmark.seal")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 6)
                    StatusBadge(label: "\(items.count)", color: TokenPilotDesign.textSecondary)
                }

                Text(model.t("Freshness and recovery actions are assessed by TokenCore capacity policy."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)

                if visibleItems.isEmpty {
                    EmptyInlineState(text: model.t("No trusted capacity presentation"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            capacitySignalRow(item)
                            if index < visibleItems.count - 1 {
                                Divider()
                                    .overlay(TokenPilotDesign.border.opacity(0.8))
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
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
        items.prefix(5)
            .map { accessibilityLabel(for: $0) }
            .joined(separator: "; ")
    }

    private func capacitySignalRow(_ item: CapacityDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                ProviderSignatureMark(provider: item.provider, size: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title(language: model.settings.localization.language))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Text(item.primaryValue(language: model.settings.localization.language))
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(item.progressColor)
                        .lineLimit(1)

                    Text("\(model.t("Provenance")): \(item.sourceTruthLabel(language: model.settings.localization.language))")
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text("\(item.resetText(language: model.settings.localization.language)) · \(item.observedText(language: model.settings.localization.language))")
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 5) {
                    StatusBadge(
                        label: item.freshnessLabel(language: model.settings.localization.language),
                        color: TokenPilotDesign.freshnessColor(item.assessment.freshness)
                    )
                    if actionIsButton(item) {
                        Button {
                            performAction(for: item)
                        } label: {
                            Text(actionTitle(for: item))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Text(actionTitle(for: item))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                    }
                }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: item))
    }

    private func accessibilityLabel(for item: CapacityDisplayItem) -> String {
        [
            item.title(language: model.settings.localization.language),
            item.primaryValue(language: model.settings.localization.language),
            "\(model.t("Provenance")): \(item.sourceTruthLabel(language: model.settings.localization.language))",
            "\(model.t("Freshness")): \(item.freshnessLabel(language: model.settings.localization.language))",
            item.resetText(language: model.settings.localization.language),
            "\(model.t("Action")): \(actionTitle(for: item))"
        ].joined(separator: ", ")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    toggleExpanded()
                } label: {
                    HStack {
                        Label(model.t("Recorded capacity signal history"), systemImage: "waveform.path.ecg.rectangle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TokenPilotDesign.textPrimary)
                        Spacer()
                        StatusBadge(label: "\(samples.count)", color: TokenPilotDesign.textSecondary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .frame(width: 18, height: 18)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.t(isExpanded ? "Hide recorded capacity signal history" : "Show recorded capacity signal history"))

                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(samples.prefix(8).enumerated()), id: \.element.id) { index, sample in
                            HistoryLimitSignalRow(sample: sample, model: model)
                            if index < min(samples.count, 8) - 1 {
                                Divider()
                                    .overlay(TokenPilotDesign.border.opacity(0.8))
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                }

                Text(model.t("Historical capacity signals are kept separate from usage event analytics."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }

    private func toggleExpanded() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        }
    }
}

struct HistoryLimitSignalRow: View {
    let sample: ProviderLimitSample
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        HStack(spacing: 9) {
            ProviderSignatureMark(provider: sample.provider, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.t(sample.provider.displayName)) · \(sample.window.localizedLabel(language: model.settings.localization.language))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(TokenPilotDesign.textPrimary)
                Text("\(model.t("Provenance")): \(sourceLabel(sample.source)) · \(model.t("Recorded")) \(TokenPilotFormatters.clock(sample.timestamp)) · \(sample.confidence.localizedLabel(language: model.settings.localization.language))")
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: model.t("Remaining %d%%"), sample.remainingPercent))
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.riskColor(sample.usedPercent))
                Text("\(model.t("Risk")) \(sample.usedPercent)%")
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        [
            model.t(sample.provider.displayName),
            sample.window.localizedLabel(language: model.settings.localization.language),
            String(format: model.t("Remaining %d%%"), sample.remainingPercent),
            "\(model.t("Provenance")): \(sourceLabel(sample.source))",
            "\(model.t("Recorded")) \(TokenPilotFormatters.clock(sample.timestamp))"
        ].joined(separator: ", ")
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "officialStatusline": return model.t("source.officialStatusline")
        case "officialTelemetry": return model.t("source.officialTelemetry")
        case "webUsage": return model.t("source.limitHints")
        case "localLog": return model.t("source.localLog")
        case "manual": return model.t("source.manual")
        case "estimated": return model.t("source.estimated")
        case "mock": return model.t("source.mock")
        default: return model.t("source.unknown")
        }
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
                    .background(TokenPilotDesign.cardMuted.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("No capacity signals yet"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                    Text(model.t("Run Auto-detect or Provider Diagnostics to recover source health."))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.t("Open Provider Diagnostics")) {
                        model.selectedScreen = .settings
                    }
                    .buttonStyle(.bordered)
                    .tint(TokenPilotDesign.calm)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.t("No capacity signals yet"))
        .accessibilityValue(model.t("Run Auto-detect or Provider Diagnostics to recover source health."))
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
                    .background(TokenPilotDesign.cardMuted.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("No usage events recorded"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                    Text(model.t(hasLimitSignals ? "Capacity signals are available above, but no token usage events are stored for this period." : "Token totals come only from stored usage events."))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.t("Open Provider Diagnostics")) {
                        model.selectedScreen = .settings
                    }
                    .buttonStyle(.bordered)
                    .tint(TokenPilotDesign.calm)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.t("No usage events recorded"))
        .accessibilityValue(model.t(hasLimitSignals ? "Capacity signals are available above, but no token usage events are stored for this period." : "Token totals come only from stored usage events."))
    }
}