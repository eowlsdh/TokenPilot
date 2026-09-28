import Foundation

/// Measures menu bar text the way the menu bar actually lays it out.
///
/// The status item draws with a monospaced-digit font, so width is proportional
/// to cell count rather than to point size — which makes a character budget an
/// honest unit for "how much menu bar am I taking".
///
/// CJK and Hangul glyphs occupy two cells in that font, so a Korean or Japanese
/// mode label ("설정 필요") costs twice what its character count suggests. Counting
/// those as two keeps the budget from being generous in English and useless in the
/// languages TokenPilot ships.
public enum MenuBarTextWidth {
    /// Width of `text` in monospaced character cells.
    public static func cells(_ text: String) -> Int {
        text.reduce(0) { $0 + cells(of: $1) }
    }

    private static func cells(of character: Character) -> Int {
        for scalar in character.unicodeScalars where isWide(scalar) {
            return 2
        }
        return 1
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,      // Hangul Jamo
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols and punctuation
             0x3041...0x33FF,      // Hiragana, Katakana, Hangul Compatibility Jamo, CJK compatibility
             0x3400...0x4DBF,      // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,      // CJK Unified Ideographs
             0xA960...0xA97F,      // Hangul Jamo Extended-A
             0xAC00...0xD7A3,      // Hangul Syllables
             0xF900...0xFAFF,      // CJK Compatibility Ideographs
             0xFE30...0xFE4F,      // CJK Compatibility Forms
             0xFF00...0xFF60,      // Fullwidth forms
             0xFFE0...0xFFE6,      // Fullwidth signs
             0x20000...0x3FFFD:    // CJK Extension B and beyond
            return true
        default:
            return false
        }
    }
}
