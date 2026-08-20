import Foundation

/// The capacity series an alert can meaningfully watch, declared once.
///
/// Alert rules used to exist for Claude's two windows and DeepSeek's balance, and nothing else —
/// the legacy migration filtered on `provider == .claude`. So a user watching opencode, Kiro,
/// Codex, JetBrains, MiniMax, Z.ai, or OpenRouter got a remaining percentage on screen and no
/// warning when it ran down, which is the one thing a limit monitor exists to do.
///
/// Only quota-shaped series are listed. A balance, a context window, or local activity is not a
/// quota: alerting on them would either fire constantly or claim a limit the provider never stated.
/// DeepSeek's balance is alerted separately, through its own condition, because "below $5" is a
/// different question from "past 80% of a window".
public enum CapacityAlertCatalogue {
    public struct AlertableSeries: Equatable, Sendable {
        public let provider: Provider
        public let providerWindowID: String
        public let kind: CapacitySeriesKind
        public let unit: CapacityUnit
        public let durationMinutes: Int?

        public init(
            provider: Provider,
            providerWindowID: String,
            kind: CapacitySeriesKind,
            unit: CapacityUnit,
            durationMinutes: Int? = nil
        ) {
            self.provider = provider
            self.providerWindowID = providerWindowID
            self.kind = kind
            self.unit = unit
            self.durationMinutes = durationMinutes
        }

        public var seriesID: CapacitySeriesID? {
            try? CapacitySeriesID(
                provider: provider,
                providerWindowID: providerWindowID,
                kind: kind,
                unit: unit,
                durationMinutes: durationMinutes
            )
        }
    }

    /// Kept in step with `CapacityObservationFactory` by a test that reads the factory's source, so
    /// a new provider window cannot ship alertable-on-screen but unalertable in fact.
    public static let alertableSeries: [AlertableSeries] = [
        AlertableSeries(provider: .claude, providerWindowID: "five-hour", kind: .fixedReset, unit: .percent),
        AlertableSeries(provider: .claude, providerWindowID: "seven-day", kind: .fixedReset, unit: .percent),
        // Codex reports its own window durations, so the duration is part of the series identity and
        // cannot be stated here; rules for these are created from what was actually observed.
        AlertableSeries(provider: .gemini, providerWindowID: "daily-requests", kind: .calendarCap, unit: .requestCount, durationMinutes: 1_440),
        AlertableSeries(provider: .opencode, providerWindowID: "opencode-go-rolling", kind: .fixedReset, unit: .percent, durationMinutes: 300),
        AlertableSeries(provider: .opencode, providerWindowID: "rate-limit", kind: .fixedReset, unit: .percent),
        AlertableSeries(provider: .opencode, providerWindowID: "opencode-go-monthly", kind: .fixedReset, unit: .percent, durationMinutes: 43_200),
        AlertableSeries(provider: .kiro, providerWindowID: "usage-limits", kind: .fixedReset, unit: .percent),
        AlertableSeries(provider: .jetbrains, providerWindowID: "jetbrains-quota", kind: .fixedReset, unit: .percent),
        AlertableSeries(provider: .minimax, providerWindowID: "minimax-token-plan", kind: .fixedReset, unit: .percent),
        AlertableSeries(provider: .zai, providerWindowID: "zai-tokens-limit", kind: .fixedReset, unit: .percent),
        AlertableSeries(provider: .openrouter, providerWindowID: "openrouter-credits", kind: .fixedReset, unit: .percent)
    ]

    /// Series that should alert but whose identity is only known once observed.
    ///
    /// Codex reports its own window durations, and the duration is part of a series identity, so
    /// there is no fixed `CapacitySeriesID` to write down here. Rules for these have to be created
    /// from what the evidence store actually saw — which is the same mechanism the other providers
    /// will need, and the reason this is recorded as a third category rather than filed under
    /// "not alertable", which would be false.
    public static let alertableOnlyFromObservedSeries: [String: String] = [
        "codex/primary": "Codex sets the window duration, so the series identity is not fixed",
        "codex/secondary": "Codex sets the window duration, so the series identity is not fixed"
    ]

    /// Series the factory produces that are deliberately **not** alertable, with the reason. Listed
    /// so the parity test can tell "we decided against this" from "we forgot this".
    public static let deliberatelyNotAlertable: [String: String] = [
        "opencode/session-cost": "A running cost, not a quota window",
        "opencode/context": "Context window, not subscription quota",
        "kiro/credits-used": "Credits spent, not a percentage of a limit",
        "kiro/context-percent": "Context window, not subscription quota",
        "kiro/credit-usage": "Kiro states the percentage but not the period it covers",
        "commandcode/session-cost": "A running cost, not a quota window",
        "commandcode/context": "Context window, not subscription quota",
        "deepseek/balance": "Alerted through its own below-threshold condition"
    ]

    /// What a freshly created rule watches, before the user changes it.
    ///
    /// 80 and 100 match what the app already shipped for Claude. 50 is left off by default because a
    /// notification at half a window is noise for most people; it stays one click away.
    public static let defaultThresholds = CapacityAlertCondition.percentThresholds(
        reset: true,
        percents: [80, 100]
    )

    public static func alertableSeries(for provider: Provider) -> [AlertableSeries] {
        alertableSeries.filter { $0.provider == provider }
    }
}
