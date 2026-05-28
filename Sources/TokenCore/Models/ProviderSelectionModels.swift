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

public struct MonitoredProviderSettings: Codable, Equatable, Sendable {
    public var enabledProviders: Set<Provider>
    public var providerModes: [Provider: ProviderMode]
    public var customPaths: [Provider: String]
    public var scanDisabledProviders: Bool

    public init(
        enabledProviders: Set<Provider> = [.claude, .codex, .gemini],
        providerModes: [Provider: ProviderMode] = [:],
        customPaths: [Provider: String] = [:],
        scanDisabledProviders: Bool = false
    ) {
        self.enabledProviders = enabledProviders
        self.providerModes = providerModes
        self.customPaths = customPaths
        self.scanDisabledProviders = scanDisabledProviders
    }
}