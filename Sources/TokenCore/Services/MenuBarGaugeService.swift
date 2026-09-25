import Foundation

/// Fill math for the menu bar quota bar.
///
/// The bar draws the same number the block already shows, so the fraction is
/// read back out of the rendered value instead of being threaded through every
/// segment branch. Values that are not a leading percentage (money, "Setup",
/// "—", token counts) have no bar, which keeps activity-only readouts from
/// looking like a quota gauge.
public enum MenuBarGaugeService {
    /// Remaining fraction (0...1) for a rendered segment value, or nil when the value is not a percentage.
    ///
    /// Accepts the decorated forms the menu bar uses for stability and freshness
    /// markers ("63%", "63%·E", "63%·ES", "63%·M").
    public static func remainingFraction(displayValue: String) -> Double? {
        guard let percent = remainingPercent(displayValue: displayValue) else { return nil }
        return Double(percent) / 100.0
    }

    /// Leading percentage of a rendered segment value, clamped to 0...100.
    public static func remainingPercent(displayValue: String) -> Int? {
        let trimmed = displayValue.trimmingCharacters(in: .whitespaces)
        guard let percentIndex = trimmed.firstIndex(of: "%") else { return nil }
        let head = trimmed[trimmed.startIndex..<percentIndex]
        guard !head.isEmpty, head.allSatisfy({ $0.isNumber }), let percent = Int(head) else { return nil }
        return min(max(percent, 0), 100)
    }

    /// True for a segment that stands in for a missing value ("—", "— STALE", "—·E", "Setup").
    /// Only these are drawn dimmed; a real balance, token count or cost was drawn in the same grey
    /// and read as "nothing here" at menu bar size.
    public static func isPlaceholder(displayValue: String) -> Bool {
        let trimmed = displayValue.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("—") || trimmed == "Setup"
    }
}
