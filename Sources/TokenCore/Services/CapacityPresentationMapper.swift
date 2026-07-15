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
            guard let used = observation.value.usedPercent else { preconditionFailure("Invalid capacity percent value") }
            titleKey = "capacity.remaining.percent"
            data["usedPercent"] = String(used)
            data["remainingPercent"] = String(100 - used)
        case .currency:
            guard let amount = observation.value.moneyAmount,
                  let currency = observation.value.currency else { preconditionFailure("Invalid capacity money value") }
            titleKey = "capacity.balance.money"
            data["amount"] = NSDecimalNumber(decimal: amount).stringValue
            data["currency"] = currency
        case .requestCount:
            guard let count = observation.value.count else { preconditionFailure("Invalid capacity count value") }
            titleKey = "capacity.count"
            data["count"] = String(count)
        case .tokens:
            guard let tokens = observation.value.tokens else { preconditionFailure("Invalid capacity token value") }
            titleKey = "capacity.tokens"
            data["tokens"] = String(tokens)
        }
        return CapacityPresentation(titleKey: titleKey, detailKey: "capacity.\(assessment.freshness.rawValue).detail", accessibilityKey: "capacity.accessibility", data: data)
    }
}
