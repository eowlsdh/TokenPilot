import Foundation

// MARK: - Static Formatters (reused across calls)
// nonisolated(unsafe) — formatters are thread-safe for reading (no mutable state after init).

private nonisolated(unsafe) let isoFractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private nonisolated(unsafe) let isoFormatter = ISO8601DateFormatter()

// MARK: - Shared JSON Value Extractors
// Used by both TokenPilotServices and DataSourceAdapters.
// Kept as internal free functions for simple call-site syntax.

func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func nestedDictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func value(_ object: [String: Any], path: String) -> Any? {
    let keys = path.split(separator: ".").map(String.init)
    var current: Any? = object
    for key in keys {
        guard let dict = current as? [String: Any] else { return nil }
        current = dict[key]
    }
    return current
}

func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let int64 = value as? Int64 { return Int(int64) }
    if let number = value as? NSNumber { return number.intValue }
    if let double = value as? Double { return Int(double.rounded()) }
    if let string = value as? String {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
        return Int(cleaned)
    }
    return nil
}

func int64Value(_ value: Any?) -> Int64? {
    if let int64 = value as? Int64 { return int64 }
    if let int = value as? Int { return Int64(int) }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

func decimalValue(_ value: Any?) -> Decimal? {
    if let decimal = value as? Decimal { return decimal }
    if let number = value as? NSNumber { return number.decimalValue }
    if let double = value as? Double { return Decimal(double) }
    if let string = value as? String { return Decimal(string: string) }
    return nil
}

func stringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func dateValue(_ value: Any?) -> Date? {
    if let date = value as? Date { return date }
    if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
    if let double = value as? Double { return Date(timeIntervalSince1970: double) }
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = TimeInterval(trimmed), seconds > 1_000_000 { return Date(timeIntervalSince1970: seconds) }
    if let date = isoFractionalFormatter.date(from: trimmed) { return date }
    return isoFormatter.date(from: trimmed)
}

// MARK: - Shared String Helpers

func firstDictionary(in dictionary: [String: Any]?, keys: [String]) -> [String: Any]? {
    guard let dictionary else { return nil }
    for key in keys {
        if let val = dictionary[key] as? [String: Any] { return val }
    }
    return nil
}

func containsString(_ needle: String, in value: Any?) -> Bool {
    if let string = value as? String { return string == needle }
    if let dict = value as? [String: Any] {
        return dict.values.contains { containsString(needle, in: $0) }
    }
    if let array = value as? [Any] {
        return array.contains { containsString(needle, in: $0) }
    }
    return false
}

func firstCapture(in text: String, pattern: String) -> String? {
    allCaptures(in: text, pattern: pattern).first
}

func allCaptures(in text: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }
}

func jsonObject(fromLine line: String) -> [String: Any]? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let data = trimmed.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return json
    }
    return nil
}
