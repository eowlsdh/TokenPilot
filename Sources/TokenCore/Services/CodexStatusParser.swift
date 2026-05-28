import Foundation

public enum CodexStatusParser {
    public static func parse(_ text: String, previous: CodexManualSettings) -> CodexManualSettings {
        safeParse(text, previous: previous)
    }

    public static func safeParse(_ text: String, previous: CodexManualSettings) -> CodexManualSettings {
        var result = previous
        result.pastedStatusOutput = text

        let fiveHourPatterns = [
            // "5h usage: 45%", "5-hour: 45%", "five hour usage: 45%", "session (5h): 45%"
            #"(?i)(?:5h|5[- ]?hour|five[- ]?hour|session\s*\(5h\)|5h\s*usage|primary\s*window)[^0-9%]{0,40}(\d{1,3})\s*%"#,
            // "5h: 45/100" or "5h 45 of 100" — ratio format without %
            #"(?i)(?:5h|5[- ]?hour|five[- ]?hour|session\s*\(5h\)|primary\s*window)\s*[:：]?\s*(\d{1,3})\s*/\s*\d+"#,
            // "Used 45% of 5h limit" — used before label
            #"(?i)used\s+(\d{1,3})\s*%[^0-9]{0,30}(?:5h|5[- ]?hour|five[- ]?hour|primary\s*window)"#,
            // "5h: 45" — bare number after label (no unit)
            #"(?i)(?:5h|5[- ]?hour|five[- ]?hour|session\s*\(5h\)|primary\s*window)\s*[:：]\s*(\d{1,3})(?:\s|$)"#
        ]
        let weeklyPatterns = [
            // "weekly usage: 45%", "week: 45%", "7-day: 45%", "secondary window: 45%"
            #"(?i)(?:weekly|week|7d|7[- ]?day|weekly\s*usage|secondary\s*window)[^0-9%]{0,40}(\d{1,3})\s*%"#,
            // "weekly: 45/100" — ratio format without %
            #"(?i)(?:weekly|week|7d|7[- ]?day|secondary\s*window)\s*[:：]?\s*(\d{1,3})\s*/\s*\d+"#,
            // "Used 45% of weekly limit" — used before label
            #"(?i)used\s+(\d{1,3})\s*%[^0-9]{0,30}(?:weekly|week|7d|7[- ]?day|secondary\s*window)"#,
            // "weekly: 45" — bare number after label
            #"(?i)(?:weekly|week|7d|7[- ]?day|secondary\s*window)\s*[:：]\s*(\d{1,3})(?:\s|$)"#
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
