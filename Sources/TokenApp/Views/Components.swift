import SwiftUI
import TokenCore

struct TokenPilotSectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    private let accessory: Accessory
    @Environment(\.tokenPilotSemanticPalette) private var palette

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
                titleView
                    .font(TokenPilotDesign.Typography.sectionTitle)
                    .foregroundStyle(palette.text(.primary))
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TokenPilotDesign.Typography.caption)
                        .foregroundStyle(palette.text(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: TokenPilotDesign.Spacing.sm)
            accessory
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleView: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

extension TokenPilotSectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) {
            EmptyView()
        }
    }
}

struct CompactProviderStatusRow<Trailing: View>: View {
    let provider: Provider
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueColor: Color? = nil
    var providerMarkDecorative = true
    var providerMarkSize: CGFloat = 28
    private let trailing: Trailing
    @Environment(\.tokenPilotSemanticPalette) private var palette

    init(
        provider: Provider,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        valueColor: Color? = nil,
        providerMarkDecorative: Bool = true,
        providerMarkSize: CGFloat = 28,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.provider = provider
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.valueColor = valueColor
        self.providerMarkDecorative = providerMarkDecorative
        self.providerMarkSize = providerMarkSize
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: TokenPilotDesign.Spacing.lg) {
            ProviderSignatureMark(provider: provider, size: providerMarkSize, decorative: providerMarkDecorative)

            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xxs) {
                Text(title)
                    .font(TokenPilotDesign.Typography.cardTitle)
                    .foregroundStyle(palette.text(.primary))
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TokenPilotDesign.Typography.caption)
                        .foregroundStyle(palette.text(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if let value, !value.isEmpty {
                Text(value)
                    .font(TokenPilotDesign.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(valueColor ?? palette.text(.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

extension CompactProviderStatusRow where Trailing == EmptyView {
    init(
        provider: Provider,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        valueColor: Color? = nil,
        providerMarkDecorative: Bool = true,
        providerMarkSize: CGFloat = 28
    ) {
        self.init(
            provider: provider,
            title: title,
            subtitle: subtitle,
            value: value,
            valueColor: valueColor,
            providerMarkDecorative: providerMarkDecorative,
            providerMarkSize: providerMarkSize
        ) {
            EmptyView()
        }
    }
}

struct DisclosureSummaryRow: View {
    var provider: Provider? = nil
    let title: String
    var subtitle: String? = nil
    var status: String? = nil
    var statusColor: Color? = nil
    var systemImage: String? = nil
    var providerMarkDecorative = true
    var providerMarkSize: CGFloat = 28
    @Environment(\.tokenPilotSemanticPalette) private var palette

    var body: some View {
        if let provider {
            CompactProviderStatusRow(
                provider: provider,
                title: title,
                subtitle: subtitle,
                providerMarkDecorative: providerMarkDecorative,
                providerMarkSize: providerMarkSize
            ) {
                statusBadge
            }
        } else {
            HStack(alignment: .center, spacing: TokenPilotDesign.Spacing.md) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.text(.secondary))
                        .frame(width: 24, height: 24)
                        .background(palette.surface(.cardMuted))
                        .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.Radius.sm, style: .continuous))
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xxs) {
                    Text(title)
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(palette.text(.primary))
                        .lineLimit(1)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(TokenPilotDesign.Typography.caption)
                            .foregroundStyle(palette.text(.secondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)
                statusBadge
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status, !status.isEmpty {
            StatusBadge(label: status, color: statusColor)
        }
    }
}

struct DisclosureCard<Summary: View, Content: View>: View {
    var padding: CGFloat = TokenPilotDesign.cardPadding
    var surface: TokenPilotDesign.Surface = .card
    var initiallyExpanded = false
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    private let summary: () -> Summary
    private let content: Content

    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.tokenPilotReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.tokenPilotLanguage) private var language
    @Environment(\.tokenPilotSemanticPalette) private var palette

    init(
        padding: CGFloat = TokenPilotDesign.cardPadding,
        surface: TokenPilotDesign.Surface = .card,
        initiallyExpanded: Bool = false,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        @ViewBuilder summary: @escaping () -> Summary,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.surface = surface
        self.initiallyExpanded = initiallyExpanded
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.summary = summary
        self.content = content()
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        GlassCard(padding: padding, surface: surface) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.lg) {
                disclosureButton

                if isExpanded {
                    content
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var disclosureButton: some View {
        let button = Button {
            toggleExpanded()
        } label: {
            HStack(alignment: .center, spacing: TokenPilotDesign.Spacing.md) {
                summary()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.text(.secondary))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()

        let stateValue = localized(isExpanded ? "Expanded" : "Collapsed", language: language)
        if let accessibilityLabel, let accessibilityValue {
            button
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue("\(accessibilityValue), \(stateValue)")
        } else if let accessibilityLabel {
            button
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(stateValue)
        } else {
            button
                .accessibilityElement(children: .combine)
                .accessibilityValue(stateValue)
        }
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private func toggleExpanded() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }
}


struct TokenPilotSeparator: View {
    var axis: Axis = .horizontal
    var length: CGFloat? = nil

    @Environment(\.tokenPilotSemanticPalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.separatorColor)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }


    private var width: CGFloat? {
        switch axis {
        case .horizontal:
            return length
        case .vertical:
            return palette.borderWidth()
        }
    }

    private var height: CGFloat? {
        switch axis {
        case .horizontal:
            return palette.borderWidth()
        case .vertical:
            return length
        }
    }
}


struct ProviderSignatureMark: View {
    let provider: Provider
    var size: CGFloat = 28
    var decorative: Bool = true
    @State private var isVisible = false
    @Environment(\.tokenPilotLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.tokenPilotReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.tokenPilotSemanticPalette) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(palette.surface(.cardElevated))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                        .stroke(
                            palette.borderColor(),
                            lineWidth: palette.borderWidth()
                        )
                )

            providerGlyph
                .scaleEffect(isRevealed ? 1 : 0.78)
        }
        .frame(width: size, height: size)
        .scaleEffect(isRevealed ? 1 : 0.92)
        .onAppear {
            reveal()
        }
        .accessibilityHidden(decorative)
        .accessibilityLabel(TokenPilotLocalizer.localized(provider.displayName, language: language))
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }


    private var isRevealed: Bool {
        reduceMotion || isVisible
    }

    private func reveal() {
        if reduceMotion {
            isVisible = true
        } else {
            withAnimation(.spring(response: 0.72, dampingFraction: 0.78).delay(provider.startupDelay)) {
                isVisible = true
            }
        }
    }

    private var providerGlyph: some View {
        Image(systemName: provider.iconName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(palette.accent(for: provider))
            .frame(width: size * 0.62, height: size * 0.62)
    }
}

struct TokenPilotBrandMark: View {
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.tokenPilotReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.tokenPilotSemanticPalette) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.surface(.cardElevated))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            palette.borderColor(),
                            lineWidth: palette.borderWidth()
                        )
                )
            Text("TP")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(palette.text(.primary))
            Circle()
                .fill(palette.status(.calm))
                .frame(width: 4, height: 4)
                .offset(x: isRevealed ? 7 : -7, y: -7)
        }
        .frame(width: 24, height: 24)
        .onAppear {
            if reduceMotion {
                isVisible = true
            } else {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.74)) {
                    isVisible = true
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private var isRevealed: Bool {
        reduceMotion || isVisible
    }
}


private extension Provider {
    var startupDelay: Double {
        switch self {
        case .claude: return 0.04
        case .codex: return 0.10
        case .gemini: return 0.16
        case .deepseek: return 0.22
        case .xai: return 0.28
        }
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var detail: String? = nil
    var labelWidth: CGFloat = 58
    @Environment(\.tokenPilotSemanticPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
            Text(label)
                .font(TokenPilotDesign.Typography.label)
                .foregroundStyle(palette.text(.secondary))
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)

            Text(value)
                .font(TokenPilotDesign.Typography.metric)
                .foregroundStyle(palette.text(.primary))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let detail, !detail.isEmpty {
                Spacer(minLength: TokenPilotDesign.Spacing.md)
                Text(detail)
                    .font(TokenPilotDesign.Typography.label)
                    .foregroundStyle(palette.text(.secondary))
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
    @Environment(\.tokenPilotLanguage) private var language
    @Environment(\.tokenPilotSemanticPalette) private var palette

    let percent: Int?
    let color: Color?
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    var isDecorative: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ProgressTrack(palette: palette)
                ProgressFill(
                    color: color ?? palette.status(.neutral),
                    width: progressWidth(in: geo.size.width)
                )
            }
        }
        .frame(height: progressHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? localized("Progress", language: language))
        .accessibilityValue(accessibilityValue ?? progressAssistiveText)
        .accessibilityHidden(isDecorative)
    }


    private var progressAssistiveText: String {
        guard let percent else { return localized("Unavailable", language: language) }
        return "\(clampedPercent(percent))%"
    }

    private var progressHeight: CGFloat {
        palette.colorSchemeContrast == .increased ? 5 : 4
    }

    private var minimumVisibleWidth: CGFloat {
        progressHeight
    }

    private func progressWidth(in width: CGFloat) -> CGFloat {
        guard let percent else { return 0 }
        let clamped = clampedPercent(percent)
        return max(clamped == 0 ? 0 : minimumVisibleWidth, width * CGFloat(Double(clamped) / 100.0))
    }

    private func clampedPercent(_ percent: Int) -> Int {
        min(max(percent, 0), 100)
    }

    private struct ProgressTrack: View {
        let palette: TokenPilotDesign.SemanticPalette

        var body: some View {
            Capsule()
                .fill(palette.surface(.progressTrack))
                .overlay(ProgressBorder(palette: palette))
        }
    }

    private struct ProgressBorder: View {
        let palette: TokenPilotDesign.SemanticPalette

        var body: some View {
            Capsule()
                .stroke(
                    palette.borderColor(),
                    lineWidth: palette.borderWidth()
                )
        }
    }

    private struct ProgressFill: View {
        let color: Color
        let width: CGFloat

        var body: some View {
            Capsule()
                .fill(color)
                .frame(width: width)
        }
    }
}

struct EmptyInlineState: View {
    let text: String
    @Environment(\.tokenPilotSemanticPalette) private var palette

    var body: some View {
        Text(text)
            .font(TokenPilotDesign.Typography.caption)
            .foregroundStyle(palette.text(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, TokenPilotDesign.Spacing.xxs)
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String
    @Environment(\.tokenPilotSemanticPalette) private var palette

    var body: some View {
        GlassCard {
            HStack(spacing: TokenPilotDesign.Spacing.lg) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text(.secondary))
                    .frame(width: 24, height: 24)
                    .background(palette.surface(.cardMuted))
                    .clipShape(RoundedRectangle(cornerRadius: TokenPilotDesign.Radius.sm, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xxs) {
                    Text(title)
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(palette.text(.primary))
                    Text(message)
                        .font(TokenPilotDesign.Typography.caption)
                        .foregroundStyle(palette.text(.secondary))
                }

                Spacer(minLength: 0)
            }
        }
    }
}

struct StatusBadge: View {
    let label: String
    let color: Color?
    var systemImage: String? = nil

    @Environment(\.tokenPilotSemanticPalette) private var palette

    init(label: String, color: Color? = nil, systemImage: String? = nil) {
        self.label = label
        self.color = color
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: TokenPilotDesign.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }

            Text(label)
        }
        .font(TokenPilotDesign.Typography.badge)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(color ?? palette.status(.trust))
        .background {
            Capsule()
                .fill(palette.surface(.badge))
        }
        .overlay {
            Capsule()
                .stroke(
                    palette.borderColor(),
                    lineWidth: palette.borderWidth()
                )
        }
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

}

struct SemanticChip: View {
    enum Role {
        case neutral
        case truth
        case action
        case success
        case warning
        case danger

        var statusRole: TokenPilotDesign.StatusRole {
            switch self {
            case .neutral: return .neutral
            case .truth: return .trust
            case .action: return .goal
            case .success: return .calm
            case .warning: return .warning
            case .danger: return .danger
            }
        }
    }

    let label: String
    var systemImage: String? = nil
    private let color: Color?
    private let role: Role?

    @Environment(\.tokenPilotSemanticPalette) private var palette

    init(label: String, systemImage: String? = nil, color: Color? = nil) {
        self.label = label
        self.systemImage = systemImage
        self.color = color
        self.role = nil
    }

    init(label: String, systemImage: String? = nil, role: Role) {
        self.label = label
        self.systemImage = systemImage
        self.color = nil
        self.role = role
    }

    var body: some View {
        HStack(spacing: TokenPilotDesign.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }

            Text(label)
                .font(TokenPilotDesign.Typography.micro)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(foregroundColor)
        .background {
            Capsule()
                .fill(palette.surface(.chip))
        }
        .overlay {
            Capsule()
                .stroke(
                    palette.borderColor(),
                    lineWidth: palette.borderWidth()
                )
        }
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var foregroundColor: Color {
        if let color {
            return color
        }
        return palette.status(role?.statusRole ?? .trust)
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = TokenPilotDesign.cardPadding
    var surface: TokenPilotDesign.Surface = .card
    var cornerRadius: CGFloat = TokenPilotDesign.cardRadius
    var intensity: CGFloat = 1.0
    private let content: Content

    init(
        padding: CGFloat = TokenPilotDesign.cardPadding,
        surface: TokenPilotDesign.Surface = .card,
        cornerRadius: CGFloat = TokenPilotDesign.cardRadius,
        intensity: CGFloat = 1.0,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.surface = surface
        self.cornerRadius = cornerRadius
        self.intensity = intensity
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LiquidGlassBackground(cornerRadius: cornerRadius, intensity: intensity, surface: surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
