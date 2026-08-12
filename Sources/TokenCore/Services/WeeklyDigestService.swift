import Foundation
import os

public struct WeeklyDigestSchedule: Equatable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int = 9, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
}

private func weeklyStart(of date: Date, calendar: Calendar, weekStartDay: WeekStartDay) -> Date? {
    let weekday = calendar.component(.weekday, from: date)
    let daysBack = weekStartDay.daysBefore(weekday)
    return calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: date))
}

public enum WeeklyDigestGate {
    /// True only inside the weekly fire window (09:00–10:00 on the configured week-start day by default)
    /// and only when the digest has not already been sent for the current week.
    public static func isInFireWindow(
        now: Date,
        lastSentAt: Date?,
        calendar: Calendar = .current,
        schedule: WeeklyDigestSchedule = WeeklyDigestSchedule(),
        weekStartDay: WeekStartDay = .monday
    ) -> Bool {
        guard let weekStart = weeklyStart(of: now, calendar: calendar, weekStartDay: weekStartDay),
              let fire = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: weekStart) else {
            return false
        }
        guard now >= fire, now < fire.addingTimeInterval(3_600) else { return false }
        if let lastSentAt, lastSentAt >= fire { return false }
        return true
    }
}

public enum WeeklyDigestService {
    /// Week-to-date summary over stored local activity. Only aggregates reach the text; raw
    /// event fields (source, model names, project labels) never appear.
    public static func digestText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        language: TokenPilotLanguage,
        now: Date = Date(),
        calendar: Calendar = .current,
        weekStartDay: WeekStartDay = .monday
    ) -> String {
        let enabled = Set(enabledProviders)
        let weekStart = weeklyStart(of: now, calendar: calendar, weekStartDay: weekStartDay) ?? calendar.startOfDay(for: now)
        let weekEvents = events.filter {
            enabled.contains($0.provider) && $0.timestamp >= weekStart && $0.timestamp <= now
        }

        let totalTokens = weekEvents.reduce(0) { $0 + $1.totalTokens }
        let requests = weekEvents.reduce(0) { $0 + $1.requestCount }
        let cost = weekEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)
        let tokensByProvider = Dictionary(grouping: weekEvents, by: \.provider)
            .mapValues { $0.reduce(0) { $0 + $1.totalTokens } }

        var lines = [
            localized("This week", language: language),
            "\(localized("Total tokens", language: language)): \(TokenPilotFormatters.compactNumber(totalTokens))",
            "\(localized("Requests", language: language)): \(TokenPilotFormatters.compactNumber(requests))"
        ]
        if cost > 0 {
            let amount = NSDecimalNumber(decimal: cost).doubleValue
            lines.append("\(localized("Estimated cost", language: language)): \(String(format: "$%.2f", amount))")
        }
        if let topProvider = tokensByProvider.max(by: { $0.value < $1.value })?.key,
           let topTokens = tokensByProvider[topProvider], topTokens > 0 {
            let percent = totalTokens > 0
                ? Int((Double(topTokens) / Double(totalTokens) * 100).rounded())
                : 0
            lines.append(
                "\(localized("Top provider", language: language)): " +
                "\(localized(topProvider.displayName, language: language)) (\(percent)%)"
            )
        }
        if let topModel = topModel(in: weekEvents, totalTokens: totalTokens) {
            lines.append("\(localized("Top model", language: language)): \(topModel)")
        }
        lines.append(localized("Local activity, not provider quota", language: language))
        return lines.joined(separator: "\n")
    }

    /// The model with the most tokens this week, as a display label with its share.
    private static func topModel(in events: [UsageEvent], totalTokens: Int) -> String? {
        let byModel = Dictionary(grouping: events.compactMap { event -> (String, Int)? in
            guard let model = event.model, !model.isEmpty else { return nil }
            return (model, event.totalTokens)
        }, by: \.0)
        let tokensByModel = byModel.mapValues { $0.reduce(0) { $0 + $1.1 } }
            .filter { $0.value > 0 }
        guard let top = tokensByModel.max(by: { $0.value < $1.value }) else { return nil }
        let percent = totalTokens > 0 ? Int((Double(top.value) / Double(totalTokens) * 100).rounded()) : 0
        return "\(top.key) (\(percent)%)"
    }

    private static func localized(_ key: String, language: TokenPilotLanguage) -> String {
        TokenPilotLocalizer.localized(key, language: language)
    }

}

public final class WeeklyDigestStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "tokenPilot.weeklyDigest.lastSent.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func loadLastSent() -> Date? {
        lock.withLock {
            defaults.object(forKey: key) as? Date
        }
    }

    public func saveLastSent(_ date: Date) {
        lock.withLock {
            defaults.set(date, forKey: key)
        }
    }
}
