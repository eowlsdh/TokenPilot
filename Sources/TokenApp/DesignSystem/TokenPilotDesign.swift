import AppKit
import SwiftUI
import TokenCore

enum TokenPilotDesign {
    enum Surface: Equatable {
        case background
        case card
        case cardElevated
        case cardMuted
        case chip
        case badge
        case progressTrack
        case separator
    }

    enum TextRole {
        case primary
        case secondary
        case tertiary
    }

    enum StatusRole {
        case danger
        case warning
        case calm
        case goal
        case trust
        case neutral
    }
    struct SemanticPalette {
        let colorSchemeContrast: ColorSchemeContrast

        init(colorSchemeContrast: ColorSchemeContrast) {
            self.colorSchemeContrast = colorSchemeContrast
        }

        func surface(_ role: Surface) -> Color {
            TokenPilotDesign.surfaceColor(role, contrast: colorSchemeContrast)
        }

        func text(_ role: TextRole) -> Color {
            TokenPilotDesign.textColor(role, contrast: colorSchemeContrast)
        }

        func status(_ role: StatusRole) -> Color {
            TokenPilotDesign.statusColor(role, contrast: colorSchemeContrast)
        }

        func borderColor(emphasized: Bool = false) -> Color {
            TokenPilotDesign.borderColor(colorSchemeContrast, emphasized: emphasized)
        }

        func borderWidth(emphasized: Bool = false) -> CGFloat {
            TokenPilotDesign.borderWidth(colorSchemeContrast, emphasized: emphasized)
        }

        var separatorColor: Color {
            TokenPilotDesign.separatorColor(colorSchemeContrast)
        }

        var glassTint: Color {
            TokenPilotDesign.glassTintDefinition.color(contrast: colorSchemeContrast)
        }

        var glassHighlight: Color {
            TokenPilotDesign.glassHighlightDefinition.color(contrast: colorSchemeContrast)
        }

        func accent(for provider: Provider) -> Color {
            TokenPilotDesign.accent(for: provider, contrast: colorSchemeContrast)
        }

        func riskColor(_ percent: Int?) -> Color {
            TokenPilotDesign.riskColor(percent, contrast: colorSchemeContrast)
        }

        func quotaRiskColor(_ risk: CapacityRisk, eligibility: CapacityAlertEligibility) -> Color {
            TokenPilotDesign.quotaRiskColor(risk, eligibility: eligibility, contrast: colorSchemeContrast)
        }

        func confidenceColor(_ confidence: DataConfidence) -> Color {
            TokenPilotDesign.confidenceColor(confidence, contrast: colorSchemeContrast)
        }

        func freshnessColor(_ freshness: CapacityFreshness) -> Color {
            TokenPilotDesign.freshnessColor(freshness, contrast: colorSchemeContrast)
        }
    }

    private struct SemanticColorDefinition {
        let light: NSColor
        let dark: NSColor
        let lightHighContrast: NSColor?
        let darkHighContrast: NSColor?

        init(
            light: NSColor,
            dark: NSColor,
            lightHighContrast: NSColor? = nil,
            darkHighContrast: NSColor? = nil
        ) {
            self.light = light
            self.dark = dark
            self.lightHighContrast = lightHighContrast
            self.darkHighContrast = darkHighContrast
        }

        func color(contrast: ColorSchemeContrast? = nil) -> Color {
            TokenPilotDesign.semanticColor(
                light: light,
                dark: dark,
                lightHighContrast: lightHighContrast,
                darkHighContrast: darkHighContrast,
                contrast: contrast
            )
        }
    }

    enum Typography {
        static let appTitle = Font.system(size: 15, weight: .semibold, design: .rounded)
        static let sectionTitle = Font.system(size: 12, weight: .bold, design: .rounded)
        static let cardTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let label = Font.system(size: 11, weight: .medium)
        static let caption = Font.system(size: 10, weight: .medium)
        static let micro = Font.system(size: 9, weight: .semibold, design: .monospaced)
        static let metric = Font.system(size: 12, weight: .semibold, design: .monospaced)
        static let metricLarge = Font.system(size: 34, weight: .semibold, design: .monospaced)
        static let badge = Font.system(size: 10, weight: .bold, design: .monospaced)
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 3
        static let sm: CGFloat = 5
        static let md: CGFloat = 7
        static let lg: CGFloat = 9
        static let xl: CGFloat = 12
        static let section: CGFloat = 9
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let card: CGFloat = 10
        static let lg: CGFloat = 12
    }

    // Semantic, system-aware palette. Values are intentionally quiet; status is the only high-chroma layer.
    private static let backgroundDefinition = SemanticColorDefinition(
        light: rgb(0.965, 0.969, 0.980),
        dark: rgb(0.039, 0.039, 0.043),
        lightHighContrast: rgb(1.000, 1.000, 1.000),
        darkHighContrast: rgb(0.000, 0.000, 0.000)
    )
    static let background = backgroundDefinition.color()

    private static let cardDefinition = SemanticColorDefinition(
        light: rgb(1.000, 1.000, 1.000),
        dark: rgb(0.064, 0.067, 0.073),
        lightHighContrast: rgb(1.000, 1.000, 1.000),
        darkHighContrast: rgb(0.045, 0.047, 0.052)
    )
    static let card = cardDefinition.color()

    private static let cardElevatedDefinition = SemanticColorDefinition(
        light: rgb(0.988, 0.990, 1.000),
        dark: rgb(0.082, 0.086, 0.094),
        lightHighContrast: rgb(1.000, 1.000, 1.000),
        darkHighContrast: rgb(0.071, 0.075, 0.086)
    )
    static let cardElevated = cardElevatedDefinition.color()

    private static let cardMutedDefinition = SemanticColorDefinition(
        light: rgb(0.929, 0.937, 0.957),
        dark: rgb(0.102, 0.106, 0.118),
        lightHighContrast: rgb(0.902, 0.914, 0.945),
        darkHighContrast: rgb(0.125, 0.132, 0.149)
    )
    static let cardMuted = cardMutedDefinition.color()

    private static let borderDefinition = SemanticColorDefinition(
        light: rgb(0.800, 0.816, 0.855),
        dark: rgb(0.168, 0.176, 0.196),
        lightHighContrast: rgb(0.480, 0.512, 0.580),
        darkHighContrast: rgb(0.390, 0.415, 0.480)
    )
    static let border = borderDefinition.color()

    private static let borderStrongDefinition = SemanticColorDefinition(
        light: rgb(0.420, 0.455, 0.530),
        dark: rgb(0.480, 0.510, 0.590),
        lightHighContrast: rgb(0.245, 0.275, 0.345),
        darkHighContrast: rgb(0.620, 0.650, 0.730)
    )
    static let borderStrong = borderStrongDefinition.color()

    private static let borderMutedDefinition = SemanticColorDefinition(
        light: rgb(0.836, 0.850, 0.884),
        dark: rgb(0.145, 0.153, 0.173),
        lightHighContrast: rgb(0.480, 0.512, 0.580),
        darkHighContrast: rgb(0.390, 0.415, 0.480)
    )
    static let borderMuted = borderMutedDefinition.color()

    private static let borderElevatedDefinition = SemanticColorDefinition(
        light: rgb(0.590, 0.620, 0.680),
        dark: rgb(0.360, 0.385, 0.450),
        lightHighContrast: rgb(0.245, 0.275, 0.345),
        darkHighContrast: rgb(0.620, 0.650, 0.730)
    )
    static let borderElevated = borderElevatedDefinition.color()

    private static let separatorLineDefinition = SemanticColorDefinition(
        light: rgb(0.850, 0.862, 0.892),
        dark: rgb(0.132, 0.140, 0.158),
        lightHighContrast: rgb(0.420, 0.455, 0.530),
        darkHighContrast: rgb(0.560, 0.590, 0.670)
    )
    static let separatorLine = separatorLineDefinition.color()

    // Subtle surface layers.
    private static let glassTintDefinition = SemanticColorDefinition(
        light: rgb(1.000, 1.000, 1.000, alpha: 0.34),
        dark: rgb(0.000, 0.000, 0.000, alpha: 0.16),
        lightHighContrast: rgb(1.000, 1.000, 1.000, alpha: 0.42),
        darkHighContrast: rgb(0.000, 0.000, 0.000, alpha: 0.26)
    )
    static let glassTint = glassTintDefinition.color()

    private static let glassHighlightDefinition = SemanticColorDefinition(
        light: rgb(1.000, 1.000, 1.000, alpha: 0.72),
        dark: rgb(1.000, 1.000, 1.000, alpha: 0.07),
        lightHighContrast: rgb(1.000, 1.000, 1.000, alpha: 0.90),
        darkHighContrast: rgb(1.000, 1.000, 1.000, alpha: 0.12)
    )
    static let glassHighlight = glassHighlightDefinition.color()

    private static let neutralChipDefinition = SemanticColorDefinition(
        light: rgb(0.918, 0.926, 0.947),
        dark: rgb(0.125, 0.132, 0.150),
        lightHighContrast: rgb(0.870, 0.888, 0.925),
        darkHighContrast: rgb(0.175, 0.188, 0.220)
    )
    static let neutralChip = neutralChipDefinition.color()

    private static let progressTrackDefinition = SemanticColorDefinition(
        light: rgb(0.872, 0.886, 0.918),
        dark: rgb(0.145, 0.152, 0.172),
        lightHighContrast: rgb(0.805, 0.830, 0.885),
        darkHighContrast: rgb(0.210, 0.225, 0.260)
    )
    static let progressTrack = progressTrackDefinition.color()

    private static let textPrimaryDefinition = SemanticColorDefinition(
        light: rgb(0.110, 0.112, 0.125),
        dark: rgb(0.957, 0.957, 0.961),
        lightHighContrast: rgb(0.000, 0.000, 0.000),
        darkHighContrast: rgb(1.000, 1.000, 1.000)
    )
    static let textPrimary = textPrimaryDefinition.color()

    private static let textSecondaryDefinition = SemanticColorDefinition(
        light: rgb(0.365, 0.385, 0.430),
        dark: rgb(0.663, 0.663, 0.698),
        lightHighContrast: rgb(0.195, 0.215, 0.260),
        darkHighContrast: rgb(0.830, 0.835, 0.870)
    )
    static let textSecondary = textSecondaryDefinition.color()

    private static let textTertiaryDefinition = SemanticColorDefinition(
        light: rgb(0.520, 0.540, 0.590),
        dark: rgb(0.478, 0.478, 0.518),
        lightHighContrast: rgb(0.305, 0.330, 0.390),
        darkHighContrast: rgb(0.690, 0.700, 0.750)
    )
    static let textTertiary = textTertiaryDefinition.color()

    private static let dangerDefinition = SemanticColorDefinition(
        light: rgb(0.740, 0.045, 0.050),
        dark: rgb(1.000, 0.271, 0.227),
        lightHighContrast: rgb(0.540, 0.000, 0.000),
        darkHighContrast: rgb(1.000, 0.410, 0.360)
    )
    static let danger = dangerDefinition.color()

    private static let warningDefinition = SemanticColorDefinition(
        light: rgb(0.700, 0.355, 0.000),
        dark: rgb(0.961, 0.647, 0.141),
        lightHighContrast: rgb(0.500, 0.245, 0.000),
        darkHighContrast: rgb(1.000, 0.780, 0.250)
    )
    static let warning = warningDefinition.color()

    private static let calmDefinition = SemanticColorDefinition(
        light: rgb(0.000, 0.475, 0.180),
        dark: rgb(0.188, 0.820, 0.345),
        lightHighContrast: rgb(0.000, 0.350, 0.125),
        darkHighContrast: rgb(0.315, 0.930, 0.455)
    )
    static let calm = calmDefinition.color()

    private static let goalDefinition = SemanticColorDefinition(
        light: rgb(0.000, 0.390, 0.760),
        dark: rgb(0.361, 0.722, 1.000),
        lightHighContrast: rgb(0.000, 0.265, 0.610),
        darkHighContrast: rgb(0.550, 0.820, 1.000)
    )
    static let goal = goalDefinition.color()

    private static let trustDefinition = SemanticColorDefinition(
        light: rgb(0.345, 0.370, 0.435),
        dark: rgb(0.690, 0.706, 0.753),
        lightHighContrast: rgb(0.215, 0.240, 0.300),
        darkHighContrast: rgb(0.825, 0.840, 0.890)
    )
    static let trust = trustDefinition.color()

    static let cardRadius = Radius.card
    static let cardPadding = Spacing.xl
    static let rowSpacing = Spacing.md
    static let sectionSpacing = Spacing.section

    static func surface(_ role: Surface) -> Color {
        surfaceColor(role, contrast: nil)
    }

    private static func surfaceColor(_ role: Surface, contrast: ColorSchemeContrast?) -> Color {
        switch role {
        case .background: return backgroundDefinition.color(contrast: contrast)
        case .card: return cardDefinition.color(contrast: contrast)
        case .cardElevated: return cardElevatedDefinition.color(contrast: contrast)
        case .cardMuted: return cardMutedDefinition.color(contrast: contrast)
        case .chip: return neutralChipDefinition.color(contrast: contrast)
        case .badge: return neutralChipDefinition.color(contrast: contrast)
        case .progressTrack: return progressTrackDefinition.color(contrast: contrast)
        case .separator: return separatorLineDefinition.color(contrast: contrast)
        }
    }

    static func text(_ role: TextRole) -> Color {
        textColor(role, contrast: nil)
    }

    private static func textColor(_ role: TextRole, contrast: ColorSchemeContrast?) -> Color {
        switch role {
        case .primary: return textPrimaryDefinition.color(contrast: contrast)
        case .secondary: return textSecondaryDefinition.color(contrast: contrast)
        case .tertiary: return textTertiaryDefinition.color(contrast: contrast)
        }
    }

    static func status(_ role: StatusRole) -> Color {
        statusColor(role, contrast: nil)
    }

    private static func statusColor(_ role: StatusRole, contrast: ColorSchemeContrast?) -> Color {
        switch role {
        case .danger: return dangerDefinition.color(contrast: contrast)
        case .warning: return warningDefinition.color(contrast: contrast)
        case .calm: return calmDefinition.color(contrast: contrast)
        case .goal: return goalDefinition.color(contrast: contrast)
        case .trust: return trustDefinition.color(contrast: contrast)
        case .neutral: return textSecondaryDefinition.color(contrast: contrast)
        }
    }

    static func borderColor(_ contrast: ColorSchemeContrast, emphasized: Bool = false) -> Color {
        if contrast == .increased {
            return emphasized ? borderStrongDefinition.color(contrast: contrast) : borderDefinition.color(contrast: contrast)
        }
        return emphasized ? borderElevatedDefinition.color(contrast: contrast) : borderMutedDefinition.color(contrast: contrast)
    }

    static func borderWidth(_ contrast: ColorSchemeContrast, emphasized: Bool = false) -> CGFloat {
        if contrast == .increased {
            return emphasized ? 1.4 : 1.15
        }
        return emphasized ? 1.0 : 0.8
    }

    static func separatorColor(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? borderStrongDefinition.color(contrast: contrast) : separatorLineDefinition.color(contrast: contrast)
    }

    static func accent(for provider: Provider) -> Color {
        accent(for: provider, contrast: nil)
    }

    private static func accent(for provider: Provider, contrast: ColorSchemeContrast?) -> Color {
        switch provider {
        case .claude:
            return SemanticColorDefinition(
                light: rgb(0.780, 0.360, 0.040),
                dark: rgb(1.000, 0.640, 0.230),
                lightHighContrast: rgb(0.590, 0.235, 0.000),
                darkHighContrast: rgb(1.000, 0.720, 0.330)
            )
            .color(contrast: contrast)
        case .codex:
            return SemanticColorDefinition(
                light: rgb(0.000, 0.520, 0.230),
                dark: rgb(0.160, 0.740, 0.370),
                lightHighContrast: rgb(0.000, 0.380, 0.155),
                darkHighContrast: rgb(0.310, 0.880, 0.480)
            )
            .color(contrast: contrast)
        case .gemini:
            return SemanticColorDefinition(
                light: rgb(0.285, 0.285, 0.780),
                dark: rgb(0.480, 0.480, 0.950),
                lightHighContrast: rgb(0.170, 0.170, 0.640),
                darkHighContrast: rgb(0.650, 0.650, 1.000)
            )
            .color(contrast: contrast)
        case .deepseek:
            return SemanticColorDefinition(
                light: rgb(0.000, 0.455, 0.760),
                dark: rgb(0.250, 0.760, 1.000),
                lightHighContrast: rgb(0.000, 0.315, 0.620),
                darkHighContrast: rgb(0.440, 0.850, 1.000)
            )
            .color(contrast: contrast)
        }
    }

    static func riskColor(_ percent: Int?) -> Color {
        riskColor(percent, contrast: nil)
    }

    private static func riskColor(_ percent: Int?, contrast: ColorSchemeContrast?) -> Color {
        guard let percent else { return textSecondaryDefinition.color(contrast: contrast) }
        if percent >= 85 { return dangerDefinition.color(contrast: contrast) }
        if percent >= 70 { return warningDefinition.color(contrast: contrast) }
        return calmDefinition.color(contrast: contrast)
    }

    static func quotaRiskColor(_ risk: CapacityRisk, eligibility: CapacityAlertEligibility) -> Color {
        quotaRiskColor(risk, eligibility: eligibility, contrast: nil)
    }

    private static func quotaRiskColor(
        _ risk: CapacityRisk,
        eligibility: CapacityAlertEligibility,
        contrast: ColorSchemeContrast?
    ) -> Color {
        switch eligibility {
        case .percent:
            switch risk {
            case .critical: return dangerDefinition.color(contrast: contrast)
            case .warning: return warningDefinition.color(contrast: contrast)
            case .normal: return calmDefinition.color(contrast: contrast)
            case .informational: return textSecondaryDefinition.color(contrast: contrast)
            case .stale: return warningDefinition.color(contrast: contrast)
            case .unavailable: return textTertiaryDefinition.color(contrast: contrast)
            }
        case .balance, .ineligible:
            switch risk {
            case .critical, .warning, .stale:
                return warningDefinition.color(contrast: contrast)
            case .normal, .informational:
                return textSecondaryDefinition.color(contrast: contrast)
            case .unavailable:
                return textTertiaryDefinition.color(contrast: contrast)
            }
        }
    }

    static func confidenceColor(_ confidence: DataConfidence) -> Color {
        confidenceColor(confidence, contrast: nil)
    }

    private static func confidenceColor(_ confidence: DataConfidence, contrast: ColorSchemeContrast?) -> Color {
        switch confidence {
        case .high: return trustDefinition.color(contrast: contrast)
        case .medium: return textSecondaryDefinition.color(contrast: contrast)
        case .low, .manual: return textSecondaryDefinition.color(contrast: contrast)
        }
    }

    static func freshnessColor(_ freshness: CapacityFreshness) -> Color {
        freshnessColor(freshness, contrast: nil)
    }

    private static func freshnessColor(_ freshness: CapacityFreshness, contrast: ColorSchemeContrast?) -> Color {
        switch freshness {
        case .fresh: return trustDefinition.color(contrast: contrast)
        case .stale: return textSecondaryDefinition.color(contrast: contrast)
        case .unavailable: return textTertiaryDefinition.color(contrast: contrast)
        }
    }
    private static func semanticColor(
        light: NSColor,
        dark: NSColor,
        lightHighContrast: NSColor? = nil,
        darkHighContrast: NSColor? = nil,
        contrast: ColorSchemeContrast? = nil
    ) -> Color {
        Color(NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .darkAqua,
                .accessibilityHighContrastAqua,
                .aqua
            ])
            let nativeHighContrast: Bool
            switch match {
            case .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua:
                nativeHighContrast = true
            default:
                nativeHighContrast = false
            }
            let useHighContrast = contrast.map { $0 == .increased } ?? nativeHighContrast

            switch match {
            case .accessibilityHighContrastDarkAqua, .darkAqua:
                return useHighContrast ? (darkHighContrast ?? dark) : dark
            default:
                return useHighContrast ? (lightHighContrast ?? light) : light
            }
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

func localized(_ key: String, language: TokenPilotLanguage) -> String {
    TokenPilotLocalizer.localized(key, language: language)
}

struct TokenPilotLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: TokenPilotLanguage = .system
}
private struct TokenPilotReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct TokenPilotReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct TokenPilotContrastOverrideKey: EnvironmentKey {
    static let defaultValue: ColorSchemeContrast? = nil
}
private struct TokenPilotSemanticPaletteKey: EnvironmentKey {
    static let defaultValue = TokenPilotDesign.SemanticPalette(colorSchemeContrast: .standard)
}



extension EnvironmentValues {
    var tokenPilotLanguage: TokenPilotLanguage {
        get { self[TokenPilotLanguageEnvironmentKey.self] }
        set { self[TokenPilotLanguageEnvironmentKey.self] = newValue }
    }

    var tokenPilotReduceMotionOverride: Bool? {
        get { self[TokenPilotReduceMotionOverrideKey.self] }
        set { self[TokenPilotReduceMotionOverrideKey.self] = newValue }
    }

    var tokenPilotReduceTransparencyOverride: Bool? {
        get { self[TokenPilotReduceTransparencyOverrideKey.self] }
        set { self[TokenPilotReduceTransparencyOverrideKey.self] = newValue }
    }

    var tokenPilotContrastOverride: ColorSchemeContrast? {
        get { self[TokenPilotContrastOverrideKey.self] }
        set { self[TokenPilotContrastOverrideKey.self] = newValue }
    }

    var tokenPilotSemanticPalette: TokenPilotDesign.SemanticPalette {
        get { self[TokenPilotSemanticPaletteKey.self] }
        set { self[TokenPilotSemanticPaletteKey.self] = newValue }
    }
}

private struct TokenPilotSemanticPaletteModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var systemColorSchemeContrast
    @Environment(\.tokenPilotContrastOverride) private var contrastOverride

    func body(content: Content) -> some View {
        content.environment(
            \.tokenPilotSemanticPalette,
            TokenPilotDesign.SemanticPalette(colorSchemeContrast: contrastOverride ?? systemColorSchemeContrast)
        )
    }
}

extension View {
    func tokenPilotSemanticPalette() -> some View {
        modifier(TokenPilotSemanticPaletteModifier())
    }
}

// MARK: - Surface Components

/// NSVisualEffectView-backed frosted glass for macOS.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

/// Native utility surface with an opaque semantic fallback when Reduce Transparency is enabled.
struct LiquidGlassBackground: View {
    var cornerRadius: CGFloat = TokenPilotDesign.Radius.md
    var intensity: CGFloat = 1.0
    var surface: TokenPilotDesign.Surface = .card

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.tokenPilotReduceTransparencyOverride) private var reduceTransparencyOverride
    @Environment(\.tokenPilotSemanticPalette) private var palette

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape
                    .fill(palette.surface(surface))
            } else {
                shape
                    .fill(.regularMaterial)
                shape
                    .fill(palette.glassTint.opacity(Double(0.75 * clampedIntensity)))
                shape
                    .fill(palette.surface(surface).opacity(Double(surfaceOverlayOpacity)))
                shape
                    .fill(palette.glassHighlight.opacity(Double(highlightOpacity)))
            }

            shape
                .stroke(
                    palette.borderColor(emphasized: surface == .cardElevated),
                    lineWidth: palette.borderWidth(emphasized: surface == .cardElevated)
                )
                .padding(0.5)
        }
    }

    private var colorSchemeContrast: ColorSchemeContrast {
        palette.colorSchemeContrast
    }

    private var reduceTransparency: Bool {
        reduceTransparencyOverride ?? systemReduceTransparency
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var clampedIntensity: CGFloat {
        min(max(intensity, 0), 1)
    }

    private var surfaceOverlayOpacity: CGFloat {
        switch surface {
        case .background:
            return 0.18 + (0.16 * clampedIntensity)
        case .card:
            return 0.46 + (0.12 * clampedIntensity)
        case .cardElevated:
            return 0.50 + (0.14 * clampedIntensity)
        case .cardMuted:
            return 0.60 + (0.16 * clampedIntensity)
        case .chip, .badge, .progressTrack, .separator:
            return 0.68 + (0.12 * clampedIntensity)
        }
    }

    private var highlightOpacity: CGFloat {
        colorSchemeContrast == .increased ? 0.22 : 0.14
    }
}
