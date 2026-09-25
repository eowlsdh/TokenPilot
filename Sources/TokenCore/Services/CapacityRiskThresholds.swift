import Foundation

/// The one place quota percentages become a risk level.
///
/// Before this existed the thresholds were written out at five call sites, and
/// two of them disagreed: the popover and the accessibility status level warned
/// from 70% used, while the menu bar drawing and the status line warned from 50%
/// used (remaining <= 50). The same window therefore read amber in the menu bar
/// and calm in the popover between 50% and 70% used. Every surface now resolves
/// its color through these two entry points.
public extension CapacityRisk {
    /// Percent of the window already consumed at which a window becomes `.warning`.
    static let warningUsedPercent = 70

    /// Percent of the window already consumed at which a window becomes `.critical`.
    static let criticalUsedPercent = 85

    /// Risk for a window that reports how much has been used.
    static func forUsedPercent(_ used: Int) -> CapacityRisk {
        if used >= criticalUsedPercent { return .critical }
        if used >= warningUsedPercent { return .warning }
        return .normal
    }

    /// Risk for a window that reports how much is left.
    ///
    /// Menu bar blocks and the status line render remaining percent, so they
    /// would otherwise have to invert the thresholds by hand — which is exactly
    /// how the two threshold sets drifted apart.
    static func forRemainingPercent(_ remaining: Int) -> CapacityRisk {
        forUsedPercent(100 - min(max(remaining, 0), 100))
    }
}
