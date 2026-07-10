import SwiftUI
import TokenCore

struct ProviderSetupCard<Content: View>: View {
    let provider: Provider
    let title: String
    let status: String
    let statusColor: Color
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    ProviderSignatureMark(provider: provider, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenPilotDesign.textPrimary)
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    StatusBadge(label: status, color: statusColor)
                }

                content
            }
        }
    }
}

struct ProviderSnapshotCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshot: ProviderSnapshot

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                header
                rows
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ProviderSignatureMark(provider: snapshot.provider)

            Text(localized(snapshot.provider.displayName, language: language))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if snapshot.isStale {
                StatusBadge(label: localized("STALE", language: language), color: TokenPilotDesign.warning)
            }

            StatusBadge(
                label: snapshot.confidence.localizedLabel(language: language),
                color: TokenPilotDesign.confidenceColor(snapshot.confidence)
            )
        }
    }

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let fiveHour = snapshot.fiveHour {
                progressMetric(window: fiveHour)
            }

            if let weekly = snapshot.weekly {
                progressMetric(window: weekly)
            }

            if snapshot.provider == .gemini,
               let used = snapshot.dailyRequestsUsed,
               let limit = snapshot.dailyRequestsLimit {
                requestMetric(used: used, limit: limit)
            }

            MetricRow(
                label: localized("Today", language: language),
                value: todayValue,
                detail: todayDetail
            )

            if snapshot.provider == .gemini, let avgTokensPerRequest {
                MetricRow(
                    label: localized("Avg/request", language: language),
                    value: "\(TokenPilotFormatters.compactNumber(avgTokensPerRequest)) \(localized("tok", language: language))",
                    detail: dailyCapText
                )
            }

            if snapshot.fiveHour == nil,
               snapshot.weekly == nil,
               snapshot.dailyRequestsUsed == nil,
               snapshot.todayTokens == 0 {
                EmptyInlineState(text: localized("No limits", language: language))
            }
        }
    }

    private func progressMetric(window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            MetricRow(
                label: localized(window.label, language: language),
                value: remainingPercentText(window.remainingPercent),
                detail: limitDetail(window)
            )
            ProgressLine(percent: window.remainingPercent, color: TokenPilotDesign.riskColor(window.usedPercent))
        }
    }

    private func requestMetric(used: Int, limit: Int) -> some View {
        let usedPercent = snapshot.dailyRequestsPercent ?? 0
        let remaining = max(limit - used, 0)
        let remainingPercent = min(max(100 - usedPercent, 0), 100)
        return VStack(alignment: .leading, spacing: 5) {
            MetricRow(
                label: localized("Daily", language: language),
                value: "\(TokenPilotFormatters.compactNumber(remaining)) / \(TokenPilotFormatters.compactNumber(limit))",
                detail: String(format: localized("Remaining %d%%", language: language), remainingPercent)
            )
            ProgressLine(percent: remainingPercent, color: TokenPilotDesign.riskColor(usedPercent))
        }
    }

    private var todayValue: String {
        if showsCodexLocalLogOnly {
            return localized("Local log", language: language)
        }
        return "\(TokenPilotFormatters.compactNumber(snapshot.todayTokens)) \(localized("tok", language: language))"
    }

    private var todayDetail: String? {
        if showsCodexLocalLogOnly {
            return localized("Not web quota", language: language)
        }
        var parts: [String] = []
        if let cost = snapshot.todayCostUSD {
            parts.append(TokenPilotFormatters.cost(cost))
        }
        if shouldShowEstimatedLabel {
            parts.append(localized("est.", language: language))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var dailyCapText: String? {
        guard let cap = snapshot.dailyRequestsLimit else { return nil }
        return "\(localized("Daily cap", language: language)) \(TokenPilotFormatters.compactNumber(cap))"
    }

    private func remainingPercentText(_ percent: Int?) -> String {
        guard let percent else { return "—" }
        if shouldShowEstimatedLabel {
            return "\(percent)% \(localized("est.", language: language))"
        }
        return "\(percent)%"
    }

    private var shouldShowEstimatedLabel: Bool {
        snapshot.provider == .codex || snapshot.confidence == .manual
    }

    private var showsCodexLocalLogOnly: Bool {
        snapshot.isCodexLocalLogOnly
    }

    private func limitDetail(_ window: LimitWindow) -> String? {
        var parts: [String] = []
        if let reset = resetText(window.resetAt) {
            parts.append(reset)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resetText(_ resetAt: Date?) -> String? {
        guard let resetAt else { return nil }
        return "\(localized("Reset", language: language)) \(TokenPilotFormatters.remainingTime(until: resetAt))"
    }

    private var requestCount: Int {
        snapshot.events.reduce(0) { $0 + $1.requestCount }
    }

    private var avgTokensPerRequest: Int? {
        guard requestCount > 0 else { return nil }
        return max(0, snapshot.todayTokens / requestCount)
    }
}

struct ProviderSignatureMark: View {
    let provider: Provider
    var size: CGFloat = 28
    @State private var isVisible = false
    @Environment(\.tokenPilotLanguage) private var language

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            TokenPilotDesign.accent(for: provider).opacity(0.24),
                            TokenPilotDesign.cardElevated.opacity(0.96)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                        .stroke(TokenPilotDesign.accent(for: provider).opacity(isVisible ? 0.56 : 0.24), lineWidth: 1)
                )

            providerGlyph
                .scaleEffect(isVisible ? 1 : 0.78)
                .opacity(isVisible ? 1 : 0.35)
        }
        .frame(width: size, height: size)
        .scaleEffect(isVisible ? 1 : 0.92)
        .onAppear {
            withAnimation(.spring(response: 0.72, dampingFraction: 0.78).delay(provider.startupDelay)) {
                isVisible = true
            }
        }
        .accessibilityLabel(TokenPilotLocalizer.localized(provider.displayName, language: language))
    }

    @ViewBuilder
    private var providerGlyph: some View {
        switch provider {
        case .claude:
            ZStack {
                Circle()
                    .trim(from: 0.12, to: 0.88)
                    .stroke(TokenPilotDesign.accent(for: provider), style: StrokeStyle(lineWidth: size * 0.095, lineCap: .round))
                    .rotationEffect(.degrees(isVisible ? 20 : -70))
                Circle()
                    .fill(TokenPilotDesign.accent(for: provider).opacity(0.85))
                    .frame(width: size * 0.16, height: size * 0.16)
                    .offset(x: size * 0.13, y: -size * 0.10)
            }
            .padding(size * 0.24)
        case .codex:
            VStack(alignment: .leading, spacing: size * 0.10) {
                HStack(spacing: size * 0.07) {
                    Capsule()
                        .fill(TokenPilotDesign.accent(for: provider))
                        .frame(width: size * 0.24, height: size * 0.07)
                    Capsule()
                        .fill(TokenPilotDesign.accent(for: provider).opacity(0.62))
                        .frame(width: size * 0.13, height: size * 0.07)
                }
                Capsule()
                    .fill(TokenPilotDesign.accent(for: provider))
                    .frame(width: size * 0.40, height: size * 0.07)
                Capsule()
                    .fill(TokenPilotDesign.textPrimary.opacity(isVisible ? 0.86 : 0.25))
                    .frame(width: size * 0.16, height: size * 0.07)
                    .offset(x: isVisible ? size * 0.18 : 0)
            }
            .padding(size * 0.27)
        case .gemini:
            ZStack {
                Diamond()
                    .fill(TokenPilotDesign.accent(for: provider))
                    .frame(width: size * 0.36, height: size * 0.36)
                    .rotationEffect(.degrees(isVisible ? 45 : 10))
                Diamond()
                    .fill(TokenPilotDesign.textPrimary.opacity(0.86))
                    .frame(width: size * 0.14, height: size * 0.14)
                    .offset(x: size * 0.17, y: -size * 0.16)
                    .scaleEffect(isVisible ? 1 : 0.4)
            }
        case .deepseek:
            ZStack {
                Circle()
                    .stroke(TokenPilotDesign.accent(for: provider).opacity(0.95), lineWidth: size * 0.08)
                    .frame(width: size * 0.42, height: size * 0.42)
                Text("$")
                    .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                    .foregroundStyle(TokenPilotDesign.accent(for: provider))
                    .scaleEffect(isVisible ? 1 : 0.7)
            }
            .padding(size * 0.22)
        }
    }
}

struct TokenPilotBrandMark: View {
    @State private var isVisible = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(TokenPilotDesign.cardElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(TokenPilotDesign.calm.opacity(0.35), lineWidth: 1)
                )
            Text("TP")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(TokenPilotDesign.textPrimary)
            Circle()
                .fill(TokenPilotDesign.calm)
                .frame(width: 4, height: 4)
                .offset(x: isVisible ? 7 : -7, y: -7)
        }
        .frame(width: 24, height: 24)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.74)) {
                isVisible = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private extension Provider {
    var startupDelay: Double {
        switch self {
        case .claude: return 0.04
        case .codex: return 0.10
        case .gemini: return 0.16
        case .deepseek: return 0.22
        }
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(TokenPilotDesign.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let detail, !detail.isEmpty {
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProgressLine: View {
    let percent: Int?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.07))
                Capsule()
                    .fill(color.opacity(0.86))
                    .frame(width: progressWidth(in: geo.size.width))
            }
        }
        .frame(height: 4)
        .accessibilityLabel(progressAssistiveText)
        .accessibilityValue(progressAssistiveText)
    }

    private var progressAssistiveText: String {
        guard let percent else { return "--" }
        return "\(percent)%"
    }

    private func progressWidth(in width: CGFloat) -> CGFloat {
        guard let percent else { return 0 }
        return max(percent == 0 ? 0 : 4, width * CGFloat(Double(percent) / 100.0))
    }
}

struct EmptyInlineState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(TokenPilotDesign.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        GlassCard {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(message)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .overlay(
                Capsule().stroke(color.opacity(0.22), lineWidth: 1)
            )
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct SevenDayBarChart: View {
    @Environment(\.tokenPilotLanguage) private var language
    let bars: [DailyUsageBar]

    private let barTrackHeight: CGFloat = 72

    private var orderedBars: [DailyUsageBar] {
        bars
    }

    private var highest: Int {
        max(1, orderedBars.map(\.tokens).max() ?? 1)
    }

    private var totalTokens: Int {
        orderedBars.reduce(0) { $0 + $1.tokens }
    }

    private var averageTokens: Int {
        guard !orderedBars.isEmpty else { return 0 }
        return totalTokens / orderedBars.count
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(localized("7-day usage", language: language), systemImage: "chart.bar.xaxis")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(TokenPilotFormatters.compactNumber(totalTokens))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text(localized("Total", language: language))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(TokenPilotFormatters.compactNumber(averageTokens))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text(localized("Avg/day", language: language))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                    }
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
                        ForEach(orderedBars) { bar in
                            VStack(spacing: 6) {
                                if bar.tokens > 0 {
                                    Text(TokenPilotFormatters.compactNumber(bar.tokens))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(TokenPilotDesign.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                } else {
                                    Color.clear
                                        .frame(height: 10)
                                }

                                VStack {
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
                                }
                                .frame(height: barTrackHeight)

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
                    Text(summaryText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    Spacer()
                    Text("\(localized("Peak", language: language)) \(TokenPilotFormatters.compactNumber(highest))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: orderedBars)
    }

    private var summaryText: String {
        if totalTokens == 0 {
            return localized("No usage", language: language)
        }
        return String(format: localized("Latest 7 days", language: language))
    }

    private func barGradient(for bar: DailyUsageBar) -> LinearGradient {
        let ratio = ratio(for: bar)
        let tint = TokenPilotDesign.calm.opacity(0.5 + 0.45 * ratio)
        return LinearGradient(
            colors: [
                tint,
                TokenPilotDesign.riskColor(Int(ratio * 100)).opacity(0.85)
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

struct ProviderShareRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    let shares: [ProviderShare]

    private var sortedShares: [ProviderShare] {
        shares.sorted { $0.percent > $1.percent }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(localized("Provider share", language: language), systemImage: "circle.grid.cross")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(localized("total", language: language))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }

                ForEach(sortedShares) { share in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            HStack(spacing: 3) {
                                ProviderSignatureMark(provider: share.provider, size: 12)
                                Text(localized(share.provider.displayName, language: language))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Spacer()
                            HStack(spacing: 3) {
                                Text("\(share.percent)%")
                                    .font(.system(size: 11, design: .monospaced).weight(.bold))
                                Text("•")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(TokenPilotDesign.textSecondary)
                                Text(TokenPilotFormatters.compactNumber(share.tokens))
                                    .font(.system(size: 10, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(TokenPilotDesign.textSecondary)
                            }
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.06))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [TokenPilotDesign.accent(for: share.provider).opacity(0.26), TokenPilotDesign.accent(for: share.provider)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(6, geo.size.width * CGFloat(Double(share.percent) / 100.0)))
                            }
                            .frame(height: 7)
                        }
                        .frame(height: 7)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = TokenPilotDesign.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LiquidGlassBackground(cornerRadius: TokenPilotDesign.cardRadius, intensity: 1.0)
            }
            .overlay(
                RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous)
                    .stroke(TokenPilotDesign.border.opacity(0.72), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.cardRadius, style: .continuous))
    }
}
