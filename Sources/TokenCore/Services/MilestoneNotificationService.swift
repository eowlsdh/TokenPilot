import Foundation
import os

/// Persists which milestone thresholds have already been notified so each
/// achievement alerts exactly once.
public final class MilestoneNotificationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = OSAllocatedUnfairLock()

    public init(defaults: UserDefaults = .standard, key: String = "tokenPilot.milestoneNotifications.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func notifiedIDs() -> Set<String> {
        lock.withLock {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? decoder.decode(Set<String>.self, from: data) else {
                return []
            }
            return decoded
        }
    }

    public func markNotified(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            var notified = self.notifiedIDsLocked()
            notified.formUnion(ids)
            guard let data = try? encoder.encode(notified) else { return }
            defaults.set(data, forKey: key)
        }
    }

    private func notifiedIDsLocked() -> Set<String> {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode(Set<String>.self, from: data) else {
            return []
        }
        return decoded
    }
}

/// Detects milestones that were newly achieved since the last notification.
///
/// Benchmarked against TokenTracker's achievement tracks surfaced as
/// notifications. Milestones are local-activity aggregates, never provider
/// quota; the store keeps them from re-alerting every refresh.
public struct MilestoneNotificationService: Sendable {
    private let store: MilestoneNotificationStore

    public init(store: MilestoneNotificationStore = MilestoneNotificationStore()) {
        self.store = store
    }

    /// Returns achieved milestones that have not been notified yet.
    public func newlyAchieved(
        milestones: [ActivityMilestone]
    ) -> [ActivityMilestone] {
        let notified = store.notifiedIDs()
        return milestones.filter { !notified.contains($0.id) }
    }

    public func markNotified(_ milestones: [ActivityMilestone]) {
        store.markNotified(Set(milestones.map(\.id)))
    }
}
