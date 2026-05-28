import Foundation

public enum CodexStatusParser {
    public static func parse(_ text: String, previous: CodexManualSettings) -> CodexManualSettings {
        safeParse(text, previous: previous)
    }

    public static func safeParse(_ text: String, previous: CodexManualSettings) -> CodexManualSettings {
        var result = previous
        result.pastedStatusOutput = text

        let fiveHourPatterns = [
            #"(?i)(?:5h|5[- ]?hour|five[- ]?hour|session\s*\(5h\)|5h\s*usage)[^0-9%]{0,40}(\d{1,3})\s*%"#
        ]
        let weeklyPatterns = [
            #"(?i)(?:weekly|week|7d|7[- ]?day|weekly\s*usage)[^0-9%]{0,40}(\d{1,3})\s*%"#
        ]

        var matchedWindow = false
        if let percent = firstValidPercent(in: text, patterns: fiveHourPatterns) {
            result.fiveHourUsagePercentage = percent
            matchedWindow = true
        }
        if let percent = firstValidPercent(in: text, patterns: weeklyPatterns) {
            result.weeklyUsagePercentage = percent
            matchedWindow = true
        }
        if let plan = firstCapture(in: text, pattern: #"(?im)^\s*(?:plan|subscription)\s*[:：]\s*([A-Za-z0-9 _.+-]+)\s*$"#)?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            result.planLabel = plan
        }
        if let reset = firstCapture(in: text, pattern: #"(?im)\breset(?:s)?(?:\s+(?:at|in))?\s*[:：]?\s*([^\r\n]+)"#)?.trimmingCharacters(in: .whitespacesAndNewlines), !reset.isEmpty {
            result.resetTimeText = reset
        }

        let hasAnyPercent = firstValidPercent(in: text, patterns: [#"(?i)(\d{1,3})\s*%"#]) != nil
        if matchedWindow {
            result.confidence = .medium
        } else if hasAnyPercent {
            result.confidence = .low
        } else {
            result.confidence = .manual
        }
        return result
    }

    private static func firstValidPercent(in text: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            guard let capture = firstCapture(in: text, pattern: pattern), let value = Int(capture), (0...100).contains(value) else { continue }
            return value
        }
        return nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }
}
