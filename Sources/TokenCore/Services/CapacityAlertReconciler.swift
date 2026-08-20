import Foundation

/// Gives every provider the user watches the alerts it should have had all along.
///
/// Alert rules had one source: a legacy migration filtering on `provider == .claude`, plus a
/// DeepSeek balance rule. Every other provider showed a remaining percentage and never warned when
/// it ran down — including opencode, Kiro, and Codex, whose quota windows only recently started
/// reporting at all.
///
/// This deliberately does **not** go through that migration. `mergeRules` overwrites migrated rules
/// by ID, so a rule created there would reset thresholds the user had changed, and the migration's
/// digest hashes only Claude's rules, so enabling a new provider would never re-run it. Instead this
/// only ever *adds* a rule whose identity is absent. `CapacityAlertRule.id` is derived from the
/// provider, series, condition kind, authority, and stability, so the same series always maps to the
/// same identity: adding is idempotent, and an existing rule — default or hand-edited — is never
/// read, replaced, or reordered.
///
/// Nothing seeds delivery state either. The transition engine already records a first sighting
/// without firing: with no prior state it stores the current usage and returns, so alerts begin at
/// the next crossing rather than retroactively for a window the user is already inside. Writing a
/// seeding step here would have duplicated that, and could have contradicted it.
public enum CapacityAlertReconciler {
    public struct Result: Equatable, Sendable {
        public let rules: [CapacityAlertRule]
        /// Identities added by this pass. Empty means there was nothing to do.
        public let createdRuleIDs: [String]

        public var didChange: Bool { !createdRuleIDs.isEmpty }
    }

    /// - Parameters:
    ///   - enabledProviders: only providers the user actually watches get rules, so turning a
    ///     provider off and on again does not accumulate duplicates and an unused provider does not
    ///     carry alerting machinery.
    ///   - routing: the channels a newly created rule delivers on. Existing rules keep their own.
    public static func reconcile(
        existing: [CapacityAlertRule],
        enabledProviders: Set<Provider>,
        routing: CapacityAlertRouting
    ) -> Result {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var created: [String] = []

        for entry in CapacityAlertCatalogue.alertableSeries where enabledProviders.contains(entry.provider) {
            guard let seriesID = entry.seriesID,
                  let rule = try? CapacityAlertRule(
                      provider: entry.provider,
                      seriesID: seriesID,
                      authority: .providerReported,
                      stability: .supported,
                      enabled: true,
                      routing: routing,
                      condition: CapacityAlertCatalogue.defaultThresholds
                  ) else { continue }

            guard byID[rule.id] == nil else { continue }
            byID[rule.id] = rule
            created.append(rule.id)
        }

        return Result(
            rules: byID.values.sorted { $0.id < $1.id },
            createdRuleIDs: created.sorted()
        )
    }
}
