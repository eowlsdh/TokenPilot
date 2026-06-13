import SwiftUI
import TokenCore

struct HistoryScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.sectionSpacing) {
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

                if !model.limitHistorySamples.isEmpty {
                    HistoryLimitSignalCard(samples: model.limitHistorySamples, model: model)
                }

                if model.historyUsage.events.isEmpty {
                    HistoryEmptyState(hasLimitSignals: !model.limitHistorySamples.isEmpty, model: model)
                }

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
                        Text(model.t("Exports the selected History period only. Credentials, tokens, chat IDs, webhooks, and local file paths are not included."))
                            .font(.caption2)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                    }
                }

                SevenDayBarChart(bars: model.historyUsage.sevenDayBars)
                ProviderShareRow(shares: model.historyUsage.providerShare)
            }
            .padding(.bottom, 6)
        }
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

struct HistoryLimitSignalCard: View {
    let samples: [ProviderLimitSample]
    @ObservedObject var model: TokenPilotViewModel
    @State private var isExpanded = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Label(model.t("Latest limit signals"), systemImage: "waveform.path.ecg.rectangle")
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
                .accessibilityLabel(model.t(isExpanded ? "Hide latest limit signals" : "Show latest limit signals"))

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

                Text(model.t("Limit signals are recorded even when token event history is not available."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
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
                Text("\(model.t("Last updated")) · \(TokenPilotFormatters.clock(sample.timestamp)) · \(model.t(sample.confidence.label))")
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
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
                    Text(model.t("No token event history yet"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                    Text(model.t(hasLimitSignals ? "Showing limit signals until token events arrive." : "Connect Claude JSONL or Gemini telemetry to fill token charts."))
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
    }
}
