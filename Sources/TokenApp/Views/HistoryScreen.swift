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
                        CurrentCapacitySignalCard(presentations: model.capacityPresentations, model: model)
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

                    HistoryUsageVolumeChart(bars: model.historyUsage.sevenDayBars, model: model)
                    ProviderShareRow(shares: model.historyUsage.providerShare)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(model.t("Provider share"))
                        .accessibilityValue(providerShareAccessibility)
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

    private var providerShareAccessibility: String {
        guard !model.historyUsage.providerShare.isEmpty else { return model.t("No data") }
        return model.historyUsage.providerShare
            .map { "\(model.t($0.provider.displayName)) \($0.percent)% \(TokenPilotFormatters.compactNumber($0.tokens))" }
            .joined(separator: ", ")
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
    let presentations: [CapacityPresentation]
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Label(model.t("Current capacity evidence"), systemImage: "checkmark.seal")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 6)
                    StatusBadge(label: "\(presentations.count)", color: TokenPilotDesign.textSecondary)
                }

                Text(model.t("Freshness and recovery actions are assessed by TokenCore capacity policy."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)

                ForEach(Array(presentations.prefix(4).enumerated()), id: \.offset) { index, presentation in
                    capacitySignalRow(presentation)
                    if index < min(presentations.count, 4) - 1 {
                        Divider()
                            .overlay(TokenPilotDesign.border.opacity(0.8))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.t("Capacity signals"))
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        presentations.prefix(4)
            .map { presentation in
                [
                    providerTitle(for: presentation),
                    titleText(for: presentation),
                    freshnessTitle(for: presentation.data["freshness"]),
                    actionTitle(for: presentation)
                ].joined(separator: ", ")
            }
            .joined(separator: "; ")
    }

    private func capacitySignalRow(_ presentation: CapacityPresentation) -> some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(providerTitle(for: presentation))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(TokenPilotDesign.textPrimary)
                Text(titleText(for: presentation))
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.textPrimary)
                Text("\(model.t("Provenance")): \(authorityTitle(for: presentation.data["authority"])) · \(stabilityTitle(for: presentation.data["stability"]))")
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
                Text("\(model.t("Freshness")): \(freshnessTitle(for: presentation.data["freshness"]))")
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 5) {
                StatusBadge(label: freshnessTitle(for: presentation.data["freshness"]), color: freshnessColor(for: presentation.data["freshness"]))
                if actionIsButton(presentation) {
                    Button(actionTitle(for: presentation)) {
                        performAction(for: presentation)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text(actionTitle(for: presentation))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: presentation))
    }

    private func accessibilityLabel(for presentation: CapacityPresentation) -> String {
        [
            providerTitle(for: presentation),
            titleText(for: presentation),
            "\(model.t("Provenance")): \(authorityTitle(for: presentation.data["authority"]))",
            "\(model.t("Freshness")): \(freshnessTitle(for: presentation.data["freshness"]))",
            "\(model.t("Action")): \(actionTitle(for: presentation))"
        ].joined(separator: ", ")
    }

    private func providerTitle(for presentation: CapacityPresentation) -> String {
        guard let rawProvider = presentation.data["provider"], let provider = Provider(rawValue: rawProvider) else {
            return model.t("Unknown")
        }
        return model.t(provider.displayName)
    }

    private func titleText(for presentation: CapacityPresentation) -> String {
        switch presentation.titleKey {
        case "capacity.remaining.percent":
            let remaining = Int(presentation.data["remainingPercent"] ?? "") ?? 0
            return String(format: model.t("Capacity remaining %d%%"), remaining)
        case "capacity.balance.money":
            return String(format: model.t("Balance %@ %@"), presentation.data["amount"] ?? "—", presentation.data["currency"] ?? "")
        case "capacity.count":
            return String(format: model.t("Request count %@"), presentation.data["count"] ?? "—")
        case "capacity.tokens":
            return String(format: model.t("Tokens %@"), presentation.data["tokens"] ?? "—")
        default:
            return model.t("Capacity signal")
        }
    }

    private func authorityTitle(for raw: String?) -> String {
        switch raw {
        case "providerReported": return model.t("Provider reported")
        case "localDerived": return model.t("Local derived")
        case "userEntered": return model.t("User entered")
        case "synthetic": return model.t("Synthetic")
        default: return model.t("Unavailable")
        }
    }

    private func stabilityTitle(for raw: String?) -> String {
        switch raw {
        case "supported": return model.t("Supported")
        case "compatibilityBridge": return model.t("Compatibility bridge")
        case "experimentalTransport": return model.t("Experimental connector")
        case "manual": return model.t("Manual entry")
        default: return model.t("Unavailable")
        }
    }

    private func freshnessTitle(for raw: String?) -> String {
        switch raw {
        case "fresh": return model.t("Fresh")
        case "stale": return model.t("Stale")
        default: return model.t("Freshness unavailable")
        }
    }

    private func freshnessColor(for raw: String?) -> Color {
        switch raw {
        case "fresh": return TokenPilotDesign.calm
        case "stale": return TokenPilotDesign.warning
        default: return TokenPilotDesign.textSecondary
        }
    }

    private func actionTitle(for presentation: CapacityPresentation) -> String {
        switch presentation.data["action"] {
        case "waitForReset": return model.t("Wait for reset")
        case "refreshProvider": return model.t("Refresh provider")
        case "reviewSource": return model.t("Review source")
        case "reviewExperimentalConnector": return model.t("Review experimental connector")
        case "enterManualValue": return model.t("Enter manual value")
        case "reviewBalance": return model.t("Review balance")
        default: return model.t("Open Provider Diagnostics")
        }
    }

    private func actionIsButton(_ presentation: CapacityPresentation) -> Bool {
        presentation.data["action"] != "waitForReset"
    }

    private func performAction(for presentation: CapacityPresentation) {
        if presentation.data["action"] == "refreshProvider" {
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
    @State private var isExpanded = false

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
                Image(systemName: hasLimitSignals ? "chart.line.uptrend.xyaxis" : "tray")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(hasLimitSignals ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(TokenPilotDesign.cardMuted.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("No usage events recorded"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                    Text(model.t(hasLimitSignals ? "Capacity signals are available above, but no token usage events are stored for this period." : "Connect a usage event source to fill token charts."))
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
        .accessibilityValue(model.t(hasLimitSignals ? "Capacity signals are available above, but no token usage events are stored for this period." : "Connect a usage event source to fill token charts."))
    }
}

struct HistoryUsageVolumeChart: View {
    let bars: [DailyUsageBar]
    @ObservedObject var model: TokenPilotViewModel

    private let barTrackHeight: CGFloat = 64

    private var highest: Int {
        max(1, bars.map(\.tokens).max() ?? 1)
    }

    private var totalTokens: Int {
        bars.reduce(0) { $0 + $1.tokens }
    }

    private var averageTokens: Int {
        guard !bars.isEmpty else { return 0 }
        return totalTokens / bars.count
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(model.t("Usage event volume"), systemImage: "chart.bar.xaxis")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer(minLength: 6)
                    chartMetric(TokenPilotFormatters.compactNumber(totalTokens), model.t("Total"))
                    chartMetric(TokenPilotFormatters.compactNumber(averageTokens), model.t("Avg/day"))
                }

                ZStack {
                    VStack(spacing: 0) {
                        ForEach([75, 50, 25, 0], id: \.self) { tick in
                            Divider()
                                .overlay(TokenPilotDesign.border.opacity(0.32))
                            if tick < 75 {
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(bars) { bar in
                            VStack(spacing: 6) {
                                if bar.tokens > 0 {
                                    Text(TokenPilotFormatters.compactNumber(bar.tokens))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(TokenPilotDesign.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                } else {
                                    Color.clear.frame(height: 10)
                                }

                                Capsule()
                                    .fill(TokenPilotDesign.glassTint)
                                    .frame(height: barTrackHeight)
                                    .overlay(
                                        Capsule()
                                            .fill(barGradient(for: bar))
                                            .frame(height: barHeight(for: bar), alignment: .bottom)
                                            .frame(maxHeight: barTrackHeight, alignment: .bottom)
                                            .frame(maxWidth: .infinity, alignment: .bottom),
                                        alignment: .bottom
                                    )

                                Text(bar.dayLabel)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(TokenPilotDesign.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                }

                HStack {
                    Text(model.t("Usage events only"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    Spacer()
                    Text("\(model.t("Peak")) \(TokenPilotFormatters.compactNumber(highest))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.t("Usage event volume"))
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        [
            "\(model.t("Total")) \(TokenPilotFormatters.compactNumber(totalTokens))",
            "\(model.t("Avg/day")) \(TokenPilotFormatters.compactNumber(averageTokens))",
            "\(model.t("Peak")) \(TokenPilotFormatters.compactNumber(highest))",
            model.t("Usage events only")
        ].joined(separator: ", ")
    }

    private func chartMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
        }
    }

    private func barGradient(for bar: DailyUsageBar) -> LinearGradient {
        let ratio = ratio(for: bar)
        return LinearGradient(
            colors: [
                TokenPilotDesign.calm.opacity(0.36 + 0.32 * ratio),
                TokenPilotDesign.glassTint.opacity(0.78)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func barHeight(for bar: DailyUsageBar) -> CGFloat {
        max(5, barTrackHeight * ratio(for: bar))
    }

    private func ratio(for bar: DailyUsageBar) -> CGFloat {
        CGFloat(Double(bar.tokens) / Double(highest))
    }
}
