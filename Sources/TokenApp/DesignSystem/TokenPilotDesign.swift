import SwiftUI
import TokenCore

enum TokenPilotDesign {
    // Quiet premium macOS utility palette with status accents only.
    static let background = Color(red: 0.039, green: 0.039, blue: 0.043)       // #0a0a0b
    static let card = Color(red: 0.064, green: 0.067, blue: 0.073)             // #101113
    static let cardElevated = Color(red: 0.082, green: 0.086, blue: 0.094)     // #151618
    static let cardMuted = Color(red: 0.102, green: 0.106, blue: 0.118)        // #1a1b1e
    static let border = Color(red: 0.168, green: 0.176, blue: 0.196)           // #2b2d32

    // Subtle surface layers.
    static let glassTint = Color.black.opacity(0.16)
    static let glassHighlight = Color.white.opacity(0.07)
    static let neutralChip = Color.white.opacity(0.08)

    static let textPrimary = Color(red: 0.957, green: 0.957, blue: 0.961)      // #f4f4f5
    static let textSecondary = Color(red: 0.663, green: 0.663, blue: 0.698)    // #a9a9b2
    static let textTertiary = Color(red: 0.478, green: 0.478, blue: 0.518)     // #7a7a84
    static let danger = Color(red: 1.000, green: 0.271, blue: 0.227)           // #ff453a
    static let warning = Color(red: 0.961, green: 0.647, blue: 0.141)          // #f5a524
    static let calm = Color(red: 0.188, green: 0.820, blue: 0.345)             // #30d158
    static let goal = Color(red: 0.361, green: 0.722, blue: 1.000)             // #5cb8ff
    static let trust = Color(red: 0.690, green: 0.706, blue: 0.753)            // #b0b4c0

    static let cardRadius: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 7
    static let sectionSpacing: CGFloat = 9

    static func accent(for provider: Provider) -> Color {
        switch provider {
        case .claude: return Color(red: 1.0, green: 0.64, blue: 0.23)
        case .codex: return Color(red: 0.16, green: 0.74, blue: 0.37)
        case .gemini: return Color(red: 0.48, green: 0.48, blue: 0.95)
        case .deepseek: return Color(red: 0.25, green: 0.76, blue: 1.0)
        }
    }

    static func riskColor(_ percent: Int?) -> Color {
        guard let percent else { return textSecondary }
        if percent >= 85 { return danger }
        if percent >= 70 { return warning }
        return calm
    }

    static func quotaRiskColor(_ risk: CapacityRisk, eligibility: CapacityAlertEligibility) -> Color {
        guard eligibility == .percent else { return trust }
        switch risk {
        case .critical: return danger
        case .warning: return warning
        case .normal: return calm
        case .informational, .stale, .unavailable: return trust
        }
    }

    static func confidenceColor(_ confidence: DataConfidence) -> Color {
        switch confidence {
        case .high: return trust
        case .medium: return textSecondary
        case .low, .manual: return textSecondary
        }
    }

    static func freshnessColor(_ freshness: CapacityFreshness) -> Color {
        switch freshness {
        case .fresh: return trust
        case .stale: return textSecondary
        case .unavailable: return textTertiary
        }
    }

    static func modeColor(_ mode: TokenPilotViewModel.DataSourceMode) -> Color {
        switch mode {
        case .live: return trust
        case .stale: return textSecondary
        case .mock: return textTertiary
        case .disconnected: return textSecondary
        }
    }
}

func localized(_ key: String, language: TokenPilotLanguage) -> String {
    TokenPilotLocalizer.localized(key, language: language)
}

struct TokenPilotLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: TokenPilotLanguage = .system
}

extension EnvironmentValues {
    var tokenPilotLanguage: TokenPilotLanguage {
        get { self[TokenPilotLanguageEnvironmentKey.self] }
        set { self[TokenPilotLanguageEnvironmentKey.self] = newValue }
    }
}

// MARK: - Surface Components

/// NSVisualEffectView-backed frosted glass for macOS
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

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Frosted utility surface with restrained contrast.
struct LiquidGlassBackground: View {
    var cornerRadius: CGFloat = 8
    var intensity: CGFloat = 1.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.18 * intensity))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(TokenPilotDesign.card.opacity(0.58))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(TokenPilotDesign.border.opacity(0.9), lineWidth: 1.0)
                .padding(0.5)
        }
    }
}
