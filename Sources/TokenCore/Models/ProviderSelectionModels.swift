import Foundation

public enum ProviderMode: String, Codable, CaseIterable, Sendable {
    case auto
    case custom
    case disabled
}

public enum ProviderDataSourceStatus: String, Codable, CaseIterable, Sendable {
    case connected
    case notFound
    case permissionDenied
    case noUsableData
    case stale
    case invalidFormat
    case disabled
    case manual
    case estimated
}
public enum ProviderConnectionNextAction: String, Codable, CaseIterable, Sendable {
    case refreshWhenStale
    case chooseLocalSource
    case grantFileAccess
    case verifyTelemetry
    case runProviderAndRefresh
    case chooseValidSource
    case enableProvider
    case pasteCodexStatus
    case reviewManualEstimate
    case enterAPIKey

    public var localizationKey: String {
        switch self {
        case .refreshWhenStale:
            return "Refresh or re-check when usage looks stale."
        case .chooseLocalSource:
            return "Choose a local source or run Auto-detect."
        case .grantFileAccess:
            return "Grant macOS file access or choose the source again."
        case .verifyTelemetry:
            return "Verify the provider writes usage metadata, then check again."
        case .runProviderAndRefresh:
            return "Run the provider CLI, then refresh TokenPilot."
        case .chooseValidSource:
            return "Choose a valid metadata file or reset the configured source."
        case .enableProvider:
            return "Enable this provider if you want it on Overview."
        case .pasteCodexStatus:
            return "Paste /status or enter manual estimates."
        case .reviewManualEstimate:
            return "Review the manual estimate and confidence label."
        case .enterAPIKey:
            return "Save a provider API key in TokenPilot Keychain."
        }
    }
}

public struct ProviderConnectionDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public var id: Provider { provider }
    public let provider: Provider
    public let status: ProviderDataSourceStatus
    public let confidence: DataConfidence
    public let lastCheckedAt: Date?
    public let nextAction: ProviderConnectionNextAction
    public let redactedDetail: String

    public init(
        provider: Provider,
        status: ProviderDataSourceStatus,
        confidence: DataConfidence,
        lastCheckedAt: Date?,
        nextAction: ProviderConnectionNextAction,
        redactedDetail: String
    ) {
        self.provider = provider
        self.status = status
        self.confidence = confidence
        self.lastCheckedAt = lastCheckedAt
        self.nextAction = nextAction
        self.redactedDetail = redactedDetail
    }
}

public struct ProviderPathCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: Provider
    public let kind: String
    public let path: String
    public let source: String
    public let exists: Bool
    public let readable: Bool
    public let confidence: DataConfidence
    public let notes: String?

    public init(
        provider: Provider,
        kind: String,
        path: String,
        source: String,
        exists: Bool,
        readable: Bool,
        confidence: DataConfidence,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.provider = provider
        self.kind = kind
        self.path = path
        self.source = source
        self.exists = exists
        self.readable = readable
        self.confidence = confidence
        self.notes = notes
    }
}

public struct ProviderDataSource: Codable, Equatable, Identifiable, Sendable {
    public var id: Provider { provider }
    public let provider: Provider
    public var displayName: String { provider.displayName }
    public var isEnabled: Bool
    public var mode: ProviderMode
    public var detectedPaths: [ProviderPathCandidate]
    public var customPath: String?
    public var lastScanAt: Date?
    public var status: ProviderDataSourceStatus
    public var confidence: DataConfidence
    public var statusMessage: String?

    public init(
        provider: Provider,
        isEnabled: Bool = true,
        mode: ProviderMode = .auto,
        detectedPaths: [ProviderPathCandidate] = [],
        customPath: String? = nil,
        lastScanAt: Date? = nil,
        status: ProviderDataSourceStatus = .notFound,
        confidence: DataConfidence = .low,
        statusMessage: String? = nil
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.mode = mode
        self.detectedPaths = detectedPaths
        self.customPath = customPath
        self.lastScanAt = lastScanAt
        self.status = status
        self.confidence = confidence
        self.statusMessage = statusMessage
    }
}

public extension ProviderDataSource {
    func connectionDiagnostic() -> ProviderConnectionDiagnostic {
        ProviderConnectionDiagnostic(
            provider: provider,
            status: status,
            confidence: confidence,
            lastCheckedAt: lastScanAt,
            nextAction: nextAction,
            redactedDetail: redactedDiagnosticDetail
        )
    }

    private var nextAction: ProviderConnectionNextAction {
        switch status {
        case .connected:
            return .refreshWhenStale
        case .notFound:
            if provider == .deepseek || provider == .xai { return .enterAPIKey }
            return provider == .codex ? .pasteCodexStatus : .chooseLocalSource
        case .permissionDenied:
            return .grantFileAccess
        case .noUsableData:
            return .verifyTelemetry
        case .stale:
            return .runProviderAndRefresh
        case .invalidFormat:
            return .chooseValidSource
        case .disabled:
            return .enableProvider
        case .manual:
            return provider == .deepseek || provider == .xai ? .enterAPIKey : .pasteCodexStatus
        case .estimated:
            return .reviewManualEstimate
        }
    }

    private var redactedDiagnosticDetail: String {
        switch status {
        case .connected:
            return "Provider metadata is readable. Raw paths and events stay hidden from diagnostics."
        case .notFound:
            if provider == .xai { return "xAI management API is not configured. No local files are scanned." }
            return "No readable source was found in the configured/default locations."
        case .permissionDenied:
            return "A candidate source exists but macOS did not allow TokenPilot to read it."
        case .noUsableData:
            return "A source was found, but it did not contain usable usage metadata."
        case .stale:
            return "The latest usable metadata is older than expected."
        case .invalidFormat:
            return "The selected source exists but does not match the expected metadata format."
        case .disabled:
            return "This provider is disabled and skipped during refresh."
        case .manual:
            if provider == .deepseek { return "DeepSeek is waiting for an API key saved in TokenPilot Keychain or manual balance fallback." }
            if provider == .xai { return "xAI management API is waiting for a key saved in TokenPilot Keychain and explicit provider enablement." }
            return "Codex is waiting for pasted /status output or manual estimates."
        case .estimated:
            return "TokenPilot is using manual or unofficial estimate data."
        }
    }
}

public struct MonitoredProviderSettings: Codable, Equatable, Sendable {
    public var enabledProviders: Set<Provider>
    public var providerModes: [Provider: ProviderMode]
    public var customPaths: [Provider: String]
    public var scanDisabledProviders: Bool

    public init(
        enabledProviders: Set<Provider> = [.claude, .codex, .gemini, .deepseek],
        providerModes: [Provider: ProviderMode] = [:],
        customPaths: [Provider: String] = [:],
        scanDisabledProviders: Bool = false
    ) {
        self.enabledProviders = enabledProviders
        self.providerModes = providerModes
        self.customPaths = customPaths
        self.scanDisabledProviders = scanDisabledProviders
    }

    private enum CodingKeys: String, CodingKey {
        case enabledProviders
        case providerModes
        case customPaths
        case scanDisabledProviders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        enabledProviders = Self.decodeProviderSet(from: container, forKey: .enabledProviders) ?? defaults.enabledProviders
        providerModes = Self.decodeProviderMap(ProviderMode.self, from: container, forKey: .providerModes) ?? [:]
        customPaths = Self.decodeProviderMap(String.self, from: container, forKey: .customPaths) ?? [:]
        scanDisabledProviders = try container.decodeIfPresent(Bool.self, forKey: .scanDisabledProviders) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabledProviders, forKey: .enabledProviders)
        try container.encode(providerModes, forKey: .providerModes)
        try container.encode(customPaths, forKey: .customPaths)
        try container.encode(scanDisabledProviders, forKey: .scanDisabledProviders)
    }

    private static func decodeProviderSet(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Set<Provider>? {
        guard container.contains(key) else { return nil }
        if let rawValues = try? container.decode([String].self, forKey: key) {
            return Set(rawValues.compactMap(Provider.init(rawValue:)))
        }
        if let providers = try? container.decode([Provider].self, forKey: key) {
            return Set(providers)
        }
        return []
    }

    private static func decodeProviderMap<Value: Decodable>(
        _: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [Provider: Value]? {
        guard container.contains(key) else { return nil }
        if let decoded = try? container.decode([Provider: Value].self, forKey: key) {
            return decoded
        }
        if let rawKeyed = try? container.decode([String: Value].self, forKey: key) {
            return rawKeyed.reduce(into: [:]) { result, entry in
                if let provider = Provider(rawValue: entry.key) {
                    result[provider] = entry.value
                }
            }
        }
        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else { return [:] }

        var result: [Provider: Value] = [:]
        while !unkeyed.isAtEnd {
            guard let providerRawValue = try? unkeyed.decode(String.self) else {
                if (try? unkeyed.decode(IgnoredValue.self)) == nil { break }
                continue
            }
            guard !unkeyed.isAtEnd else { break }
            if let provider = Provider(rawValue: providerRawValue),
               let value = try? unkeyed.decode(Value.self) {
                result[provider] = value
            } else if (try? unkeyed.decode(IgnoredValue.self)) == nil {
                break
            }
        }
        return result
    }

    private struct IgnoredValue: Decodable {
        init(from decoder: Decoder) throws {
            if var unkeyed = try? decoder.unkeyedContainer() {
                while !unkeyed.isAtEnd {
                    if (try? unkeyed.decode(IgnoredValue.self)) == nil { break }
                }
                return
            }

            if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
                for key in keyed.allKeys {
                    _ = try? keyed.decode(IgnoredValue.self, forKey: key)
                }
                return
            }

            let single = try decoder.singleValueContainer()
            if single.decodeNil() { return }
            if (try? single.decode(Bool.self)) != nil { return }
            if (try? single.decode(Double.self)) != nil { return }
            if (try? single.decode(String.self)) != nil { return }
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported ignored value.")
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}