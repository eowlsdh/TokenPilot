import Foundation
import os

/// Which budget window a crossing notification describes.
public enum BudgetWindow: String, Codable, Equatable, Sendable {
    case daily
    case weekly
    case monthly
}

/// A budget window that has just crossed its configured alert threshold.
public struct BudgetAlertCandidate: Equatable, Sendable {
    public let window: BudgetWindow
    /// Stable identifier for the current cycle (day/week/month), used to dedupe.
    public let cycleID: String
    public let tokens: Int
    public let budgetTokens: Int
    public let percent: Int
    public let thresholdPercent: Int

    public init(window: BudgetWindow, cycleID: String, tokens: Int, budgetTokens: Int, percent: Int, thresholdPercent: Int) {
        self.window = window
        self.cycleID = cycleID
        self.tokens = tokens
        self.budgetTokens = budgetTokens
        self.percent = percent
        self.thresholdPercent = thresholdPercent
    }

    public var dedupeKey: String { "budget.\(window.rawValue).\(cycleID)" }
}

/// Persists which budget crossings were already delivered so a window alerts once per cycle.
public final class BudgetAlertDedupStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = OSAllocatedUnfairLock()

    public init(defaults: UserDefaults = .standard, key: String = "tokenPilot.budgetAlertDelivery.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func deliveredKeys() -> Set<String> {
        lock.withLock {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? decoder.decode(Set<String>.self, from: data) else {
                return []
            }
            return decoded
        }
    }

    public func markDelivered(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        lock.withLock {
            var delivered = self.deliveredKeysLocked()
            delivered.formUnion(keys)
            guard let data = try? encoder.encode(delivered) else { return }
            defaults.setIfChanged(data, forKey: key)
        }
    }

    private func deliveredKeysLocked() -> Set<String> {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode(Set<String>.self, from: data) else {
            return []
        }
        return decoded
    }
}

/// Evaluates local activity against configured budgets and reports windows that crossed the
/// alert threshold for the first time in the current cycle.
///
/// Budgets are local-activity guardrails, never provider quota. `crossingCandidates` returns
/// only windows whose progress reached the configured threshold AND that have not already
/// alerted in the current cycle; callers mark candidates delivered after sending.
public struct BudgetAlertService: Sendable {
    private let store: BudgetAlertDedupStore

    public init(store: BudgetAlertDedupStore = BudgetAlertDedupStore()) {
        self.store = store
    }

    public func crossingCandidates(
        events: [UsageEvent],
        settings: BudgetGuardrailSettings,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [BudgetAlertCandidate] {
        guard settings.hasAnyBudget else { return [] }
        let guardrails = BudgetGuardrailService()
        var candidates: [BudgetAlertCandidate] = []
        let delivered = store.deliveredKeys()

        let daily = guardrails.dailyProgress(events: events, settings: settings, now: now, calendar: calendar)
        appendIfCrossed(
            &candidates,
            delivered: delivered,
            window: .daily,
            progress: daily,
            thresholdPercent: settings.alertThresholdPercent,
            cycleID: cycleID(prefix: "day", from: now, calendar: calendar)
        )

        if settings.weeklyTokens > 0 {
            let weekly = guardrails.weeklyProgress(events: events, settings: settings, now: now, calendar: calendar)
            appendIfCrossed(
                &candidates,
                delivered: delivered,
                window: .weekly,
                progress: weekly,
                thresholdPercent: settings.alertThresholdPercent,
                cycleID: cycleID(prefix: "week", from: now, calendar: calendar)
            )
        }

        if settings.monthlyTokens > 0 {
            let monthly = guardrails.monthlyProgress(events: events, settings: settings, now: now, calendar: calendar)
            appendIfCrossed(
                &candidates,
                delivered: delivered,
                window: .monthly,
                progress: monthly,
                thresholdPercent: settings.alertThresholdPercent,
                cycleID: cycleID(prefix: "month", from: now, calendar: calendar)
            )
        }

        return candidates
    }

    public func markDelivered(_ candidates: [BudgetAlertCandidate]) {
        store.markDelivered(Set(candidates.map(\.dedupeKey)))
    }

    private func appendIfCrossed(
        _ candidates: inout [BudgetAlertCandidate],
        delivered: Set<String>,
        window: BudgetWindow,
        progress: BudgetGuardrailProgress,
        thresholdPercent: Int,
        cycleID: String
    ) {
        guard progress.budgetTokens > 0, progress.crossedThreshold else { return }
        let candidate = BudgetAlertCandidate(
            window: window,
            cycleID: cycleID,
            tokens: progress.tokens,
            budgetTokens: progress.budgetTokens,
            percent: progress.percent,
            thresholdPercent: thresholdPercent
        )
        if !delivered.contains(candidate.dedupeKey) {
            candidates.append(candidate)
        }
    }

    private func cycleID(prefix: String, from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        switch prefix {
        case "day":
            return String(format: "%04d-%02d-%02d", year, month, day)
        case "week":
            let week = calendar.component(.weekOfYear, from: date)
            return String(format: "%04d-W%02d", year, week)
        default:
            return String(format: "%04d-%02d", year, month)
        }
    }
}
