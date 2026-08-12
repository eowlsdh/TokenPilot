import Foundation
import os

/// Schedule for the optional daily digest notification.
public struct DailyDigestSchedule: Equatable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int = 18, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
}

public enum DailyDigestGate {
    /// True only inside the daily fire window (default 18:00–19:00) and only when the
    /// digest has not already been sent today.
    public static func isInFireWindow(
        now: Date,
        lastSentAt: Date?,
        calendar: Calendar = .current,
        schedule: DailyDigestSchedule = DailyDigestSchedule()
    ) -> Bool {
        guard let fire = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: now) else {
            return false
        }
        guard now >= fire, now < fire.addingTimeInterval(3_600) else { return false }
        if let lastSentAt, calendar.isDate(lastSentAt, inSameDayAs: now) { return false }
        return true
    }
}

public enum DailyDigestService {
    /// Today-to-date summary over stored local activity. Only aggregates reach the
    /// text; raw event fields never appear.
    public static func digestText(
        events: [UsageEvent],
        enabledProviders: [Provider],
        language: TokenPilotLanguage,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let enabled = Set(enabledProviders)
        let startOfToday = calendar.startOfDay(for: now)
        let todayEvents = events.filter {
            enabled.contains($0.provider) && $0.timestamp >= startOfToday && $0.timestamp <= now
        }

        let totalTokens = todayEvents.reduce(0) { $0 + $1.totalTokens }
        let requests = todayEvents.reduce(0) { $0 + $1.requestCount }
        let cost = todayEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)

        var lines = [
            localized("Today", language: language),
            "\(localized("Total tokens", language: language)): \(TokenPilotFormatters.compactNumber(totalTokens))",
            "\(localized("Requests", language: language)): \(TokenPilotFormatters.compactNumber(requests))"
        ]
        if cost > 0 {
            let amount = NSDecimalNumber(decimal: cost).doubleValue
            lines.append("\(localized("Estimated cost", language: language)): \(String(format: "$%.2f", amount))")
        }
        if let topModel = topModel(in: todayEvents, totalTokens: totalTokens) {
            lines.append("\(localized("Top model", language: language)): \(topModel)")
        }
        lines.append(localized("Local activity, not provider quota", language: language))
        return lines.joined(separator: "\n")
    }

    /// The model with the most tokens today, as a display label with its share.
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

public final class DailyDigestStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "tokenPilot.dailyDigest.lastSent.v1") {
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
