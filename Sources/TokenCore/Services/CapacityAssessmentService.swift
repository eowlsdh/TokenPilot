import Foundation

public struct CapacityAssessmentService: Sendable {
    public init() {}

    public func assess(_ observation: CapacityObservation, now: Date) -> CapacityAssessment {
        let age = now.timeIntervalSince(observation.observedAt)
        let freshness: CapacityFreshness = age >= 0 && age <= observation.freshnessPolicy.maximumAge ? .fresh : .stale
        let transitionKey = [
            observation.seriesID.canonicalID,
            observation.cycleID ?? "none",
            observation.authority.rawValue,
            observation.stability.rawValue,
            observation.value.kind.rawValue
        ].joined(separator: "/")

        guard freshness == .fresh else {
            return CapacityAssessment(observation: observation, freshness: .stale, eligibilityReason: .staleEvidence, risk: .stale, alertEligibility: .ineligible, forecast: .unavailableEvidence, actionKey: .refreshProvider, transitionKey: transitionKey)
        }

        if observation.authority == .unavailable || observation.authority == .synthetic || observation.stability == .unavailable || observation.consent == .denied || observation.consent == .unavailable {
            return CapacityAssessment(observation: observation, freshness: .unavailable, eligibilityReason: .invalidEvidence, risk: .unavailable, alertEligibility: .ineligible, forecast: .unavailableSource, actionKey: .openProviderDiagnostics, transitionKey: transitionKey)
        }

        if observation.authority == .userEntered {
            return CapacityAssessment(observation: observation, freshness: .fresh, eligibilityReason: .manualSource, risk: .informational, alertEligibility: .ineligible, forecast: .unavailableSource, actionKey: .enterManualValue, transitionKey: transitionKey)
        }

        if observation.value.kind == .currency {
            let eligible = observation.authority == .providerReported && observation.comparability == .comparable && observation.stability == .supported
            return CapacityAssessment(observation: observation, freshness: .fresh, eligibilityReason: eligible ? .eligible : .activityOnly, risk: .informational, alertEligibility: eligible ? .balance : .ineligible, forecast: .unavailableUnit, actionKey: .reviewBalance, transitionKey: transitionKey)
        }

        guard let used = observation.value.usedPercent,
              observation.comparability == .comparable,
              observation.authority == .providerReported else {
            return CapacityAssessment(observation: observation, freshness: .fresh, eligibilityReason: .activityOnly, risk: .informational, alertEligibility: .ineligible, forecast: .unavailableSource, actionKey: .openProviderDiagnostics, transitionKey: transitionKey)
        }

        let risk: CapacityRisk = used >= 85 ? .critical : (used >= 70 ? .warning : .normal)
        switch observation.stability {
        case .supported:
            return CapacityAssessment(observation: observation, freshness: .fresh, eligibilityReason: .eligible, risk: risk, alertEligibility: .percent, forecast: .unavailableEvidence, actionKey: .waitForReset, transitionKey: transitionKey)
        case .compatibilityBridge:
            return CapacityAssessment(observation: observation, freshness: .fresh, eligibilityReason: .unsupportedSource, risk: risk, alertEligibility: .ineligible, forecast: .unavailableUnsupportedSource, actionKey: .reviewSource, transitionKey: transitionKey)
        case .experimentalTransport:
            return CapacityAssessment(observation: observation, freshness: .fresh, eligibilityReason: .unsupportedSource, risk: risk, alertEligibility: .ineligible, forecast: .cohortOnly, actionKey: .reviewExperimentalConnector, transitionKey: transitionKey)
        case .manual, .unavailable:
            return CapacityAssessment(observation: observation, freshness: .fresh, eligibilityReason: .unsupportedSource, risk: .informational, alertEligibility: .ineligible, forecast: .unavailableSource, actionKey: .openProviderDiagnostics, transitionKey: transitionKey)
        }
    }

    public func eligibility(for rule: CapacityAlertRule, assessment: CapacityAssessment) -> CapacityAlertEligibility {
        guard rule.enabled, !rule.isPendingBalanceBinding else { return .ineligible }

        let observation = assessment.observation
        guard assessment.freshness == .fresh,
              assessment.eligibilityReason == .eligible,
              observation.seriesID == rule.seriesID,
              observation.seriesID.provider == rule.provider,
              observation.authority == rule.authority,
              observation.stability == rule.stability else {
            return .ineligible
        }

        switch rule.condition.kind {
        case .percentThresholds:
            guard assessment.alertEligibility == .percent,
                  observation.value.kind == .percent,
                  !rule.condition.enabledPercentThresholds.isEmpty else {
                return .ineligible
            }
            return .percent
        case .balanceBelow:
            guard assessment.alertEligibility == .balance,
                  let amount = observation.value.moneyAmount,
                  let currency = observation.value.currency,
                  let threshold = rule.condition.balanceThreshold,
                  let ruleCurrency = rule.condition.balanceCurrency,
                  currency == ruleCurrency,
                  amount < threshold else {
                return .ineligible
            }
            return .balance
        case .pendingBalanceCurrencyBinding:
            return .ineligible
        }
    }
}
