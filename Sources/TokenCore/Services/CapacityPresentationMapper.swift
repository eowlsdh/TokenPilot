import Foundation

public struct CapacityPresentation: Equatable, Sendable {
    public let titleKey: String
    public let detailKey: String
    public let accessibilityKey: String
    public let data: [String: String]

    public init(titleKey: String, detailKey: String, accessibilityKey: String, data: [String: String]) {
        self.titleKey = titleKey
        self.detailKey = detailKey
        self.accessibilityKey = accessibilityKey
        self.data = data
    }
}

public struct CapacityPresentationMapper: Sendable {
    public init() {}

    public func map(_ assessment: CapacityAssessment) -> CapacityPresentation {
        let observation = assessment.observation
        var data = [
            "provider": observation.seriesID.provider.rawValue,
            "series": observation.seriesID.canonicalID,
            "freshness": assessment.freshness.rawValue,
            "authority": observation.authority.rawValue,
            "stability": observation.stability.rawValue,
            "risk": assessment.risk.rawValue,
            "action": assessment.actionKey.rawValue
        ]
        let titleKey: String
        switch observation.value.kind {
        case .percent:
            titleKey = "capacity.remaining.percent"
            if let used = observation.value.usedPercent {
                data["usedPercent"] = String(used)
                data["remainingPercent"] = String(100 - used)
            }
        case .currency:
            titleKey = "capacity.balance.money"
            if let amount = observation.value.moneyAmount,
               let currency = observation.value.currency {
                data["amount"] = NSDecimalNumber(decimal: amount).stringValue
                data["currency"] = currency
            }
        case .requestCount:
            titleKey = "capacity.count"
            if let count = observation.value.count {
                data["count"] = String(count)
            }
        case .tokens:
            titleKey = "capacity.tokens"
            if let tokens = observation.value.tokens {
                data["tokens"] = String(tokens)
            }
        case .credits:
            titleKey = "capacity.credits"
            if let credits = observation.value.credits {
                data["credits"] = CapacityCanonical.decimalString(credits)
            }
        }
        return CapacityPresentation(titleKey: titleKey, detailKey: "capacity.\(assessment.freshness.rawValue).detail", accessibilityKey: "capacity.accessibility", data: data)
    }
}
