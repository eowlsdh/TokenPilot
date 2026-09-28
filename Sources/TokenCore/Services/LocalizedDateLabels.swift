import Foundation

/// Date text that is shown to the user, in the language the app is running in.
///
/// The History charts used to format their labels with `en_US_POSIX` and a hard
/// `"MMM"` / `"MMM d HH:mm"` pattern, so a Korean, Japanese, or Chinese user read
/// "Aug" and "Aug 19 14:00". `en_US_POSIX` is the right locale for parsing and for
/// stable storage keys — it is the wrong one for anything on screen, and the
/// fixed `HH` also overrode the 12-hour clock preference.
///
/// Patterns come from `dateFormat(fromTemplate:)`, so each locale decides both the
/// field order and the hour cycle (`j`), rather than inheriting a US layout.
public enum LocalizedDateLabels {
    /// Abbreviated month for a date ("Aug", "8월", "8月").
    public static func monthAbbreviation(
        for date: Date,
        language: TokenPilotLanguage,
        calendar: Calendar = .current
    ) -> String {
        formatter(template: "MMM", language: language, calendar: calendar).string(from: date)
    }

    /// Abbreviated month for a 1...12 month number; empty for anything outside that range.
    public static func monthAbbreviation(
        monthNumber: Int?,
        language: TokenPilotLanguage,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        guard let monthNumber, (1...12).contains(monthNumber) else { return "" }
        var components = DateComponents()
        components.year = 2000
        components.month = monthNumber
        components.day = 1
        guard let date = calendar.date(from: components) else { return "" }
        return monthAbbreviation(for: date, language: language, calendar: calendar)
    }

    /// Month, day, and time of day for a usage block ("Aug 19, 2:00 PM", "8월 19일 14:00").
    ///
    /// The `j` skeleton resolves to the locale's own hour cycle, so a 12-hour locale
    /// no longer sees a forced 24-hour clock.
    public static func dayAndTime(
        for date: Date,
        language: TokenPilotLanguage,
        calendar: Calendar = .current
    ) -> String {
        formatter(template: "MMMdjmm", language: language, calendar: calendar).string(from: date)
    }

    /// Locale the app's own language setting resolves to.
    ///
    /// `.system` deliberately stays on `Locale.autoupdatingCurrent` rather than
    /// resolving to a language code, so the Mac's region — its date order and its
    /// 12/24-hour preference — keeps deciding.
    public static func locale(for language: TokenPilotLanguage) -> Locale {
        guard let identifier = language.localeIdentifier else { return Locale.autoupdatingCurrent }
        return Locale(identifier: identifier)
    }

    // MARK: - Formatter cache

    /// Chart labels re-format on every redraw, and building a `DateFormatter` per
    /// label is the expensive part; the pattern only depends on template + locale.
    private static let cache = FormatterCache()

    private static func formatter(template: String, language: TokenPilotLanguage, calendar: Calendar) -> DateFormatter {
        cache.formatter(template: template, locale: locale(for: language), calendar: calendar)
    }

    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: DateFormatter] = [:]

        func formatter(template: String, locale: Locale, calendar: Calendar) -> DateFormatter {
            let key = "\(template)|\(locale.identifier)|\(calendar.timeZone.identifier)"
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[key] { return cached }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? template
            storage[key] = formatter
            return formatter
        }
    }
}
