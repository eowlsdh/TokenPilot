import Foundation
import os
#if os(macOS)
import Darwin
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(Security)
import Security
#endif

public protocol ProviderAdapter: Sendable {
    var provider: Provider { get }
    func snapshot(settings: AppSettings) async -> ProviderSnapshot
}
public enum CapacityRefreshErrorCategory: String, Codable, Equatable, Sendable {
    case disabled
    case sourceUnavailable
    case authenticationRequired
    case processFailure
    case timeout
    case cancelled
    case malformedResponse
    case unsupportedSeries
    case outputLimitExceeded
}

public struct CapacityRefreshError: Codable, Equatable, Identifiable, Sendable {
    public var id: String { [provider.rawValue, category.rawValue, code].joined(separator: ":") }
    public let provider: Provider
    public let category: CapacityRefreshErrorCategory
    public let code: String
    public let redactedMessage: String

    public init(provider: Provider, category: CapacityRefreshErrorCategory, code: String, redactedMessage: String) {
        self.provider = provider
        self.category = category
        self.code = code
        self.redactedMessage = redactedMessage
    }
}

public struct ProviderRefreshResult: Sendable {
    public var snapshot: ProviderSnapshot
    public var capacityObservations: [CapacityObservation]
    public var typedErrors: [CapacityRefreshError]
    public var observedAt: Date

    public init(
        snapshot: ProviderSnapshot,
        capacityObservations: [CapacityObservation] = [],
        typedErrors: [CapacityRefreshError] = [],
        observedAt: Date
    ) {
        self.snapshot = snapshot
        self.capacityObservations = capacityObservations
        self.typedErrors = typedErrors
        self.observedAt = observedAt
    }
}
public enum TokenPilotPrivacyRedactor {
    private static let replacements: [(pattern: String, template: String)] = [
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "[REDACTED]"),
        (#"(?i)\b(?:x[-_])?(?:xai[-_])?team(?:[-_\s]?id|id)?\s*[:=]\s*["']?[^"',;\s]+"#, "[REDACTED_TEAM]"),
        (#"(?i)\b(?:organization|org)(?:[-_\s]?id|id)?\s*[:=]\s*["']?[^"',;\s]+"#, "[REDACTED_TEAM]"),
        (#"(?i)/(?:teams?|organizations?|orgs)/[A-Za-z0-9._~%+-]+"#, "/[REDACTED_TEAM_PATH]"),
        (#"(?i)\b(?:authorization|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|password)\s*[:=]\s*["']?[^"',;\s]+"#, "[REDACTED]"),
        (#"(?i)\b(?:prompt|response|completion|messages?|content)\s*[:=]\s*["']?[^"\n\r;]+"#, "[REDACTED]"),
        (#"\b[A-Za-z0-9_-]{32,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"#, "[REDACTED]"),
        (#"(?i)\b(?:sk|pk|api|key|token)[-_][A-Za-z0-9]{16,}\b"#, "[REDACTED]"),
        (#"\b[A-Za-z0-9_~+/=-]{48,}\b"#, "[REDACTED]"),
        (#"(?i)(?:~|/(?:Users|home|private/var|private/tmp|var/folders|tmp|Volumes|opt/homebrew|usr/local|etc))/[^\s"',;)]+["']?"#, "[REDACTED_PATH]"),
        (#"(?i)(?:^|[\s/])(?:auth\.json|credentials(?:\.json)?|\.env(?:\.[A-Za-z0-9_-]+)?|id_rsa|id_ed25519|token(?:s)?\.json|key(?:s)?\.json)(?=$|[\s"',;:)])"#, "[REDACTED_FILE]")
    ]

    public static func redact(_ text: String) -> String {
        replacements.reduce(text) { current, replacement in
            guard let regex = try? NSRegularExpression(pattern: replacement.pattern, options: []) else { return current }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(in: current, options: [], range: range, withTemplate: replacement.template)
        }
    }

    public static func redactExportField(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let redacted = redact(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? nil : redacted
    }
}

public protocol ProviderRefreshAdapter: Sendable {
    var provider: Provider { get }
    func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult
}
public extension ProviderRefreshAdapter where Self: ProviderAdapter {
    func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        let snapshot = await snapshot(settings: settings)
        let observedAt = snapshot.updatedAt
        return ProviderRefreshResult(
            snapshot: snapshot,
            capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: observedAt),
            typedErrors: CapacityObservationFactory.errors(from: snapshot, provider: provider),
            observedAt: observedAt
        )
    }
}

public struct LegacyProviderRefreshAdapter: ProviderRefreshAdapter {
    private let adapter: any ProviderAdapter

    public var provider: Provider { adapter.provider }

    public init(_ adapter: any ProviderAdapter) {
        self.adapter = adapter
    }

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        let snapshot = await adapter.snapshot(settings: settings)
        let observedAt = snapshot.updatedAt
        return ProviderRefreshResult(
            snapshot: snapshot,
            capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: observedAt),
            typedErrors: CapacityObservationFactory.errors(from: snapshot, provider: provider),
            observedAt: observedAt
        )
    }
}

public struct XAIManagementDiagnosticsAdapter: ProviderRefreshAdapter {
    public let provider: Provider = .xai

    public init() {}

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        ProviderRefreshResult(
            snapshot: Self.snapshot(settings: settings, now: now),
            capacityObservations: [],
            typedErrors: [],
            observedAt: now
        )
    }

    private static func snapshot(settings: AppSettings, now: Date) -> ProviderSnapshot {
        guard settings.xaiEnabled && settings.isProviderEnabled(.xai) else {
            return ProviderSnapshot(
                provider: .xai,
                updatedAt: now,
                confidence: .low,
                dataSource: .unknown,
                statusMessage: "Disabled"
            )
        }

        let hasManagementKey = settings.xAI.managementAPIKeyConfigured
        let hasTeamID = !settings.xAI.teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let message: String
        if hasManagementKey && hasTeamID {
            message = "Management authentication unconfirmed"
        } else if hasManagementKey {
            message = "Setup needed · local team ID required"
        } else if hasTeamID {
            message = "Setup needed · management key required in Keychain"
        } else {
            message = "Setup needed · save management key in Keychain and local team ID"
        }

        return ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            confidence: hasManagementKey && hasTeamID ? .low : .manual,
            dataSource: .manual,
            statusMessage: message
        )
    }
}
public struct GrokLocalSignalsAdapter: ProviderRefreshAdapter {
    public let provider: Provider = .xai

    private static let maximumFileBytes = 256 * 1_024
    private static let maximumDiscoveredFiles = 120
    /// Local context metadata is treated as stale when the newest valid signals file is older than this.
    private static let staleThreshold: TimeInterval = 15 * 60
    private let sessionRoots: [URL]

    public init(sessionRoots: [URL]? = nil) {
        self.sessionRoots = sessionRoots ?? [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        ]
    }

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        let snapshot = Self.newestSnapshot(in: sessionRoots, now: now) ?? Self.unavailableSnapshot(now: now)
        return ProviderRefreshResult(
            snapshot: snapshot,
            capacityObservations: [],
            typedErrors: [],
            observedAt: now
        )
    }

    private static func newestSnapshot(in roots: [URL], now: Date) -> ProviderSnapshot? {
        var signalFiles: [(url: URL, modifiedAt: Date)] = []
        for root in roots where signalFiles.count < maximumDiscoveredFiles {
            signalFiles.append(contentsOf: discoverSignalsFiles(in: root).prefix(maximumDiscoveredFiles - signalFiles.count))
        }

        let validSignals = signalFiles.compactMap { candidate -> (url: URL, modifiedAt: Date, usedPercent: Int)? in
            guard let usedPercent = usedPercent(from: candidate.url) else { return nil }
            return (candidate.url, candidate.modifiedAt, usedPercent)
        }

        guard let newestSignal = validSignals.max(by: { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return lhs.url.path < rhs.url.path
        }) else {
            return nil
        }

        // A newer Grok Build session without signals.json must not keep advertising an older percentage.
        if let newerActivity = newestSessionActivity(in: roots),
           newerActivity.modifiedAt > newestSignal.modifiedAt.addingTimeInterval(1),
           !sessionHasSignalsFile(newerActivity.sessionDirectory) {
            return unavailableSnapshot(
                now: now,
                statusMessage: "LOCAL · Grok Build context window unavailable · newer session has no signals"
            )
        }

        let age = now.timeIntervalSince(newestSignal.modifiedAt)
        let isStale = age > staleThreshold
        return ProviderSnapshot(
            provider: .xai,
            updatedAt: newestSignal.modifiedAt,
            confidence: .low,
            dataSource: .localLog,
            isStale: isStale,
            statusMessage: isStale
                ? "STALE · LOCAL · Grok Build context window"
                : "LOCAL · Grok Build context window",
            model: "Grok Build",
            contextWindowUsedPercent: newestSignal.usedPercent,
            events: []
        )
    }

    private static func discoverSignalsFiles(in root: URL) -> [(url: URL, modifiedAt: Date)] {
        guard !isSymbolicLink(root),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "signals.json",
                  !isSymbolicLink(url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size <= maximumFileBytes,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            files.append((url, modifiedAt))
            if files.count == maximumDiscoveredFiles { break }
        }
        return files
    }

    private static func newestSessionActivity(in roots: [URL]) -> (sessionDirectory: URL, modifiedAt: Date)? {
        var newest: (sessionDirectory: URL, modifiedAt: Date)?
        for root in roots {
            for sessionDirectory in discoverSessionDirectories(in: root) {
                guard let activity = sessionActivityDate(in: sessionDirectory) else { continue }
                if newest == nil || activity > newest!.modifiedAt ||
                    (activity == newest!.modifiedAt && sessionDirectory.path > newest!.sessionDirectory.path) {
                    newest = (sessionDirectory, activity)
                }
            }
        }
        return newest
    }

    private static func discoverSessionDirectories(in root: URL) -> [URL] {
        guard !isSymbolicLink(root),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard !isSymbolicLink(url),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                continue
            }
            // Grok session dirs contain summary.json and/or chat_history.jsonl.
            let hasSummary = FileManager.default.fileExists(atPath: url.appendingPathComponent("summary.json").path)
            let hasChat = FileManager.default.fileExists(atPath: url.appendingPathComponent("chat_history.jsonl").path)
            if hasSummary || hasChat {
                directories.append(url)
            }
        }
        return directories
    }

    private static func sessionActivityDate(in sessionDirectory: URL) -> Date? {
        let markers = [
            "signals.json",
            "summary.json",
            "chat_history.jsonl",
            "events.jsonl",
            "updates.jsonl"
        ]
        var newest: Date?
        for name in markers {
            let url = sessionDirectory.appendingPathComponent(name)
            guard !isSymbolicLink(url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            if newest == nil || modifiedAt > newest! {
                newest = modifiedAt
            }
        }
        return newest
    }

    private static func sessionHasSignalsFile(_ sessionDirectory: URL) -> Bool {
        let url = sessionDirectory.appendingPathComponent("signals.json")
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumFileBytes else {
            return false
        }
        return usedPercent(from: url) != nil
    }

    private static func usedPercent(from url: URL) -> Int? {
        guard !isSymbolicLink(url),
              let data = try? Data(contentsOf: url),
              data.count <= maximumFileBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return usedPercent(from: json)
    }

    private static func usedPercent(from json: [String: Any]) -> Int? {
        if let used = finiteNumber(json["contextTokensUsed"]),
           let window = finiteNumber(json["contextWindowTokens"]),
           window > 0 {
            return clampedPercent(used / window * 100)
        }
        guard let usage = finiteNumber(json["contextWindowUsage"]) else { return nil }
        return clampedPercent(usage <= 1 ? usage * 100 : usage)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return nil
        }
        return number.doubleValue
    }

    private static func clampedPercent(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), 100)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func unavailableSnapshot(
        now: Date,
        statusMessage: String = "LOCAL · Grok Build context window unavailable"
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            confidence: .low,
            dataSource: .localLog,
            statusMessage: statusMessage,
            model: "Grok Build",
            events: []
        )
    }
}
public struct XAIOpenCodeBarAdapter: ProviderRefreshAdapter {
    public let provider: Provider = .xai

    private static let maximumOutputBytes = 64 * 1_024
    private static let timeout: TimeInterval = 5
    private static let terminationGrace: TimeInterval = 0.25
    private static let terminationWait: TimeInterval = 1
    private let runner: @Sendable (ProcessLifecycle) throws -> Data

    public init() {
        runner = Self.runOpenCodeBar
    }

    init(runner: @escaping @Sendable () throws -> Data) {
        self.runner = { _ in try runner() }
    }

    public func refresh(settings: AppSettings, now: Date) async -> ProviderRefreshResult {
        guard settings.xaiEnabled,
              settings.isProviderEnabled(.xai),
              settings.xAI.usageSource == .experimentalOpenCodeBarCLI else {
            return await XAIManagementDiagnosticsAdapter().refresh(settings: settings, now: now)
        }

        let snapshot: ProviderSnapshot
        let lifecycle = ProcessLifecycle()
        do {
            let runner = self.runner
            let task = Task.detached(priority: .utility) {
                try runner(lifecycle)
            }
            let data = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                lifecycle.requestCancellation()
            })
            try Task.checkCancellation()
            snapshot = try Self.snapshot(from: data, now: now)
        } catch let error as OpenCodeBarError {
            snapshot = Self.unavailableSnapshot(now: now, message: error.message)
        } catch {
            snapshot = Self.unavailableSnapshot(now: now, message: "OpenCode Bar CLI unavailable")
        }

        return ProviderRefreshResult(
            snapshot: snapshot,
            capacityObservations: CapacityObservationFactory.observations(from: snapshot, settings: settings, observedAt: now),
            typedErrors: [],
            observedAt: now
        )
    }

    private static func runOpenCodeBar(lifecycle: ProcessLifecycle) throws -> Data {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = ["provider", "grok", "--json"]
        process.environment = minimalEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = OutputCollector(limit: maximumOutputBytes)
        let stdoutEOF = DispatchSemaphore(value: 0)
        let stderrEOF = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutEOF.signal()
            } else {
                collector.appendStdout(data)
                if collector.exceededLimit { lifecycle.requestTermination() }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrEOF.signal()
            } else {
                collector.appendStderr(data)
                if collector.exceededLimit { lifecycle.requestTermination() }
            }
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw OpenCodeBarError.unavailable
        }
        lifecycle.attach(process)

        let deadline = Date().addingTimeInterval(timeout)
        var result: OpenCodeBarError?
        var didTerminate = false
        while !didTerminate {
            if terminated.wait(timeout: .now()) == .success {
                didTerminate = true
                break
            }
            if collector.exceededLimit {
                result = .outputTooLarge
                lifecycle.requestTermination()
            } else if lifecycle.isCancellationRequested {
                result = .cancelled
                lifecycle.requestTermination()
            } else if Date() >= deadline {
                result = .timeout
                lifecycle.requestTermination()
            }

            if result != nil {
                guard terminated.wait(timeout: .now() + terminationGrace + terminationWait) == .success else {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    throw OpenCodeBarError.failed
                }
                didTerminate = true
                break
            }
            didTerminate = terminated.wait(timeout: .now() + 0.05) == .success
        }

        guard stdoutEOF.wait(timeout: .now() + terminationWait) == .success,
              stderrEOF.wait(timeout: .now() + terminationWait) == .success else {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw OpenCodeBarError.failed
        }

        if let result { throw result }
        guard !collector.exceededLimit else { throw OpenCodeBarError.outputTooLarge }
        guard process.terminationStatus == 0 else { throw OpenCodeBarError.failed }
        return collector.stdout
    }

    private static func executableURL() throws -> URL {
        let manager = FileManager.default
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("opencodebar", isDirectory: false)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard let attributes = try? manager.attributesOfItem(atPath: candidate.path),
                  let type = attributes[.type] as? FileAttributeType,
                  let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  isTrustedExecutable(
                    canonicalPath: candidate.path,
                    isRegularFile: type == .typeRegular,
                    isExecutable: manager.isExecutableFile(atPath: candidate.path),
                    ownerID: owner,
                    currentUserID: currentUserID(),
                    permissions: permissions
                  ) else {
                continue
            }
            return candidate
        }
        throw OpenCodeBarError.unavailable
    }

    internal static func isTrustedExecutable(
        canonicalPath: String,
        isRegularFile: Bool,
        isExecutable: Bool,
        ownerID: UInt32,
        currentUserID: UInt32,
        permissions: Int
    ) -> Bool {
        let roots = [
            "/opt/homebrew/Cellar/opencode-bar/",
            "/usr/local/Cellar/opencode-bar/"
        ]
        guard roots.contains(where: { canonicalPath.hasPrefix($0) }),
              canonicalPath.hasSuffix("/bin/opencodebar"),
              isRegularFile,
              isExecutable,
              ownerID == 0 || ownerID == currentUserID,
              permissions & 0o022 == 0 else {
            return false
        }
        return true
    }

    private static func currentUserID() -> UInt32 {
        UInt32(getuid())
    }

    private static func minimalEnvironment() -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
            environment["HOME"] = home
        }
        return environment
    }

    private static func snapshot(from data: Data, now: Date) throws -> ProviderSnapshot {
        guard data.count <= maximumOutputBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let grok = root["grok"] as? [String: Any],
              let percentage = percentage(from: grok["usagePercentage"]) else {
            throw data.count > maximumOutputBytes ? OpenCodeBarError.outputTooLarge : OpenCodeBarError.malformed
        }

        let resetAt = date(from: grok["monthlyResetsAt"]) ?? date(from: grok["primaryReset"])
        let quota = LimitWindow(
            kind: .monthly,
            name: "Grok monthly usage",
            usedPercent: percentage,
            resetAt: resetAt,
            label: "Grok monthly usage",
            confidence: .low
        )
        return ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            monthly: quota,
            confidence: .low,
            dataSource: .experimentalCLI,
            isExperimental: true,
            statusMessage: "EXPERIMENTAL · UNOFFICIAL · OpenCode Bar CLI · Monthly usage"
        )
    }

    private static func percentage(from value: Any?) -> Int? {
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return min(max(Int(number.rounded()), 0), 100)
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? NSNumber {
            return Date(timeIntervalSince1970: timestamp.doubleValue)
        }
        guard let string = value as? String else { return nil }
        let iso8601 = ISO8601DateFormatter()
        return iso8601.date(from: string)
    }

    private static func unavailableSnapshot(now: Date, message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            confidence: .low,
            dataSource: .experimentalCLI,
            isExperimental: true,
            statusMessage: "EXPERIMENTAL · UNOFFICIAL · \(message)"
        )
    }

    private enum OpenCodeBarError: Error {
        case unavailable
        case timeout
        case cancelled
        case outputTooLarge
        case failed
        case malformed

        var message: String {
            switch self {
            case .unavailable: return "Install OpenCode Bar CLI to enable usage refresh"
            case .timeout: return "OpenCode Bar CLI timed out; try again"
            case .cancelled: return "OpenCode Bar CLI refresh cancelled"
            case .outputTooLarge: return "OpenCode Bar CLI returned too much data"
            case .failed: return "OpenCode Bar CLI could not refresh usage"
            case .malformed: return "OpenCode Bar CLI returned an unsupported response"
            }
        }
    }

    private final class ProcessLifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancellationRequested = false
        private var terminationRequested = false

        var isCancellationRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationRequested
        }

        func attach(_ process: Process) {
            #if os(macOS)
            let processID = process.processIdentifier
            if processID > 0 { _ = setpgid(processID, processID) }
            #endif
            lock.lock()
            self.process = process
            let shouldTerminate = cancellationRequested || terminationRequested
            lock.unlock()
            if shouldTerminate { sendTerminationSignal(to: process) }
        }

        func requestCancellation() {
            lock.lock()
            cancellationRequested = true
            lock.unlock()
            requestTermination()
        }

        func requestTermination() {
            lock.lock()
            guard !terminationRequested else {
                lock.unlock()
                return
            }
            terminationRequested = true
            let process = self.process
            lock.unlock()

            guard let process else { return }
            sendTerminationSignal(to: process)
        }

        private func sendTerminationSignal(to process: Process) {
            #if os(macOS)
            let processID = process.processIdentifier
            if processID > 0 { _ = kill(-processID, SIGTERM) }
            #endif
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + XAIOpenCodeBarAdapter.terminationGrace) {
                guard process.isRunning else { return }
                #if os(macOS)
                let processID = process.processIdentifier
                if processID > 0 { _ = kill(-processID, SIGKILL) }
                if processID > 0 { _ = kill(processID, SIGKILL) }
                #endif
                if process.isRunning { process.terminate() }
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var stdoutData = Data()
        private var byteCount = 0
        private var didExceedLimit = false

        init(limit: Int) {
            self.limit = limit
        }

        var stdout: Data {
            lock.lock()
            defer { lock.unlock() }
            return stdoutData
        }

        var exceededLimit: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didExceedLimit
        }

        func appendStdout(_ data: Data) {
            append(data, includeInStdout: true)
        }

        func appendStderr(_ data: Data) {
            append(data, includeInStdout: false)
        }

        private func append(_ data: Data, includeInStdout: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !data.isEmpty else { return }
            let remaining = limit - byteCount
            if remaining > 0, includeInStdout {
                stdoutData.append(data.prefix(remaining))
            }
            byteCount += data.count
            if byteCount > limit {
                didExceedLimit = true
            }
        }
    }
}

public enum CapacityObservationFactory {
    public static func observations(from snapshot: ProviderSnapshot, settings: AppSettings, observedAt: Date) -> [CapacityObservation] {
        guard snapshot.dataSource != .mock else { return [] }
        var observations: [CapacityObservation] = []

        func appendPercent(
            provider: Provider,
            providerWindowID: String,
            kind: CapacitySeriesKind,
            durationMinutes: Int?,
            window: LimitWindow?,
            authority: CapacityAuthority,
            stability: CapacityStability,
            consent: CapacityConsent,
            maximumAge: TimeInterval,
            comparability: CapacityComparability,
            parserRevision: String
        ) {
            guard let window,
                  let used = window.usedPercent,
                  let series = try? CapacitySeriesID(provider: provider, providerWindowID: providerWindowID, kind: kind, unit: .percent, durationMinutes: durationMinutes),
                  let value = try? CapacityValue(usedPercent: used),
                  let observation = try? CapacityObservation(
                    seriesID: series,
                    observedAt: observedAt,
                    resetAt: window.resetAt,
                    value: value,
                    authority: authority,
                    stability: stability,
                    consent: consent,
                    freshnessPolicy: CapacityFreshnessPolicy(maximumAge: maximumAge),
                    comparability: comparability,
                    parserRevision: parserRevision,
                    now: observedAt
                  ) else {
                return
            }
            observations.append(observation)
        }

        func codexProviderWindowID(_ window: LimitWindow?, defaultID: String) -> String {
            window?.providerWindowID ?? defaultID
        }

        func codexDurationMinutes(_ window: LimitWindow?, defaultMinutes: Int) -> Int {
            window?.durationMinutes ?? defaultMinutes
        }

        switch snapshot.provider {
        case .claude:
            if snapshot.dataSource == .officialStatusline {
                appendPercent(
                    provider: .claude,
                    providerWindowID: "five-hour",
                    kind: .fixedReset,
                    durationMinutes: nil,
                    window: snapshot.fiveHour,
                    authority: .providerReported,
                    stability: .supported,
                    consent: .notRequired,
                    maximumAge: 15 * 60,
                    comparability: .comparable,
                    parserRevision: "claudeStatuslineV1"
                )
                appendPercent(
                    provider: .claude,
                    providerWindowID: "seven-day",
                    kind: .fixedReset,
                    durationMinutes: nil,
                    window: snapshot.weekly,
                    authority: .providerReported,
                    stability: .supported,
                    consent: .notRequired,
                    maximumAge: 15 * 60,
                    comparability: .comparable,
                    parserRevision: "claudeStatuslineV1"
                )
            }
        case .codex:
            if snapshot.dataSource == .webUsage, settings.codexManual.webConnectorEnabled {
                appendPercent(
                    provider: .codex,
                    providerWindowID: "primary",
                    kind: .rolling,
                    durationMinutes: codexDurationMinutes(snapshot.fiveHour, defaultMinutes: 300),
                    window: snapshot.fiveHour,
                    authority: .providerReported,
                    stability: .experimentalTransport,
                    consent: .granted,
                    maximumAge: 15 * 60,
                    comparability: .comparable,
                    parserRevision: "codexAppServerV1"
                )
                appendPercent(
                    provider: .codex,
                    providerWindowID: "secondary",
                    kind: .rolling,
                    durationMinutes: codexDurationMinutes(snapshot.weekly, defaultMinutes: 10_080),
                    window: snapshot.weekly,
                    authority: .providerReported,
                    stability: .experimentalTransport,
                    consent: .granted,
                    maximumAge: 15 * 60,
                    comparability: .comparable,
                    parserRevision: "codexAppServerV1"
                )
            } else if snapshot.dataSource == .manual || snapshot.dataSource == .estimated {
                appendPercent(
                    provider: .codex,
                    providerWindowID: "primary",
                    kind: .rolling,
                    durationMinutes: codexDurationMinutes(snapshot.fiveHour, defaultMinutes: 300),
                    window: snapshot.fiveHour,
                    authority: .userEntered,
                    stability: .manual,
                    consent: .granted,
                    maximumAge: 24 * 60 * 60,
                    comparability: .incomparable,
                    parserRevision: "codexManualV1"
                )
                appendPercent(
                    provider: .codex,
                    providerWindowID: "secondary",
                    kind: .rolling,
                    durationMinutes: codexDurationMinutes(snapshot.weekly, defaultMinutes: 10_080),
                    window: snapshot.weekly,
                    authority: .userEntered,
                    stability: .manual,
                    consent: .granted,
                    maximumAge: 24 * 60 * 60,
                    comparability: .incomparable,
                    parserRevision: "codexManualV1"
                )
            }
        case .gemini:
            if snapshot.dataSource == .officialStatusline,
               let used = snapshot.dailyRequestsUsed,
               let series = try? CapacitySeriesID(provider: .gemini, providerWindowID: "daily-requests", kind: .calendarCap, unit: .requestCount, durationMinutes: 1_440),
               let value = try? CapacityValue(count: used),
               let observation = try? CapacityObservation(
                seriesID: series,
                observedAt: observedAt,
                resetAt: nil,
                value: value,
                authority: .providerReported,
                stability: .compatibilityBridge,
                consent: .notRequired,
                freshnessPolicy: CapacityFreshnessPolicy(maximumAge: 15 * 60),
                comparability: .incomparable,
                parserRevision: "antigravityStatuslineV1",
                now: observedAt
               ) {
                observations.append(observation)
            }
        case .xai:
            break
        case .deepseek:
            guard let balance = snapshot.balance else { break }
            let authority: CapacityAuthority = snapshot.dataSource == .officialTelemetry ? .providerReported : .userEntered
            let stability: CapacityStability = snapshot.dataSource == .officialTelemetry ? .supported : .manual
            let comparability: CapacityComparability = snapshot.dataSource == .officialTelemetry ? .comparable : .incomparable
            if let series = try? CapacitySeriesID(provider: .deepseek, providerWindowID: "balance", kind: .balance, unit: .currency),
               let value = try? CapacityValue(money: balance.toppedUpBalance, currency: balance.currency),
               let observation = try? CapacityObservation(
                seriesID: series,
                observedAt: observedAt,
                value: value,
                authority: authority,
                stability: stability,
                consent: snapshot.dataSource == .officialTelemetry ? .granted : .notRequired,
                freshnessPolicy: CapacityFreshnessPolicy(maximumAge: snapshot.dataSource == .officialTelemetry ? 60 * 60 : 24 * 60 * 60),
                comparability: comparability,
                parserRevision: snapshot.dataSource == .officialTelemetry ? "deepseekBalanceV1" : "deepseekManualBalanceV1",
                now: observedAt
               ) {
                observations.append(observation)
            }
        }

        return observations
    }

    public static func errors(from snapshot: ProviderSnapshot, provider: Provider) -> [CapacityRefreshError] {
        guard provider != .xai else { return [] }
        guard snapshot.confidence == .low,
              snapshot.events.isEmpty,
              snapshot.primaryUsedPercent == nil,
              snapshot.dailyRequestsUsed == nil,
              snapshot.balance == nil else {
            return []
        }
        let message = snapshot.statusMessage ?? "Provider capacity unavailable"
        return [
            CapacityRefreshError(
                provider: provider,
                category: .sourceUnavailable,
                code: "capacityUnavailable",
                redactedMessage: redacted(message)
            )
        ]
    }

    public static func redacted(_ message: String) -> String {
        TokenPilotPrivacyRedactor.redact(message)
    }
}


public enum TokenPilotRefreshPolicy {
    public static func usageRefreshNeeded(from previous: AppSettings, to next: AppSettings) -> Bool {
        previous.enabledProviders != next.enabledProviders ||
        previous.claudeStatusFilePath != next.claudeStatusFilePath ||
        previous.claudeStatusFileBookmarkData != next.claudeStatusFileBookmarkData ||
        previous.geminiTelemetryLogPath != next.geminiTelemetryLogPath ||
        previous.geminiTelemetrySourceBookmarkData != next.geminiTelemetrySourceBookmarkData ||
        previous.geminiDailyRequestCap != next.geminiDailyRequestCap ||
        previous.codexManual != next.codexManual ||
        previous.deepseekAPIKeyConfigured != next.deepseekAPIKeyConfigured ||
        previous.deepSeekBalance != next.deepSeekBalance ||
        previous.xaiEnabled != next.xaiEnabled ||
        previous.xAI.managementAPIKeyConfigured != next.xAI.managementAPIKeyConfigured ||
        previous.xAI != next.xAI ||
        previous.showMockDataWhenDisconnected != next.showMockDataWhenDisconnected
    }
}

public final class TokenPilotSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = OSAllocatedUnfairLock()

    public init(defaults: UserDefaults = .standard, key: String = "tokenPilot.appSettings.v1") {
        self.defaults = defaults
        self.key = key
        encoder.outputFormatting = [.sortedKeys]
    }

    public func load() -> AppSettings {
        lock.withLock {
            guard let data = defaults.data(forKey: key), let decoded = try? decoder.decode(AppSettings.self, from: data) else {
                return AppSettings()
            }
            return normalize(decoded)
        }
    }

    public func save(_ settings: AppSettings) {
        lock.withLock {
            guard let data = try? encoder.encode(normalize(settings)) else { return }
            defaults.set(data, forKey: key)
        }
    }

    private func normalize(_ settings: AppSettings) -> AppSettings {
        var copy = settings
        let existingIDs = Set(copy.alertRules.map(\.id))
        for rule in AppSettings.defaultAlertRules where !existingIDs.contains(rule.id) {
            copy.alertRules.append(rule)
        }
        copy.geminiDailyRequestCap = max(copy.geminiDailyRequestCap, 1)
        copy.codexManual.fiveHourUsagePercentage = min(max(copy.codexManual.fiveHourUsagePercentage, 0), 100)
        copy.codexManual.weeklyUsagePercentage = min(max(copy.codexManual.weeklyUsagePercentage, 0), 100)
        copy.codexManual.webTodayTokens = max(copy.codexManual.webTodayTokens, 0)
        if !copy.codexManual.pastedStatusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.codexManual = CodexStatusParser.safeParse(copy.codexManual.pastedStatusOutput, previous: copy.codexManual)
            copy.codexManual.pastedStatusOutput = ""
        }
        copy.xAI.teamID = copy.xAI.teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.xAI.weeklyRemainingPercent = min(max(copy.xAI.weeklyRemainingPercent, 0), 100)
        copy.xAI.weeklyResetText = copy.xAI.weeklyResetText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.normalizeProviderEnablement()
        copy.normalizeMenuBarComposition()
        return copy
    }
}


public final class MockDataService: Sendable {
    public init() {}

    public func snapshots(referenceDate: Date = Date()) -> [ProviderSnapshot] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: referenceDate)

        func timestamp(dayOffset: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) ?? startOfToday
            return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
        }

        func event(
            provider: Provider,
            model: String,
            dayOffset: Int,
            hour: Int,
            input: Int,
            output: Int,
            cacheRead: Int = 0,
            cacheCreation: Int = 0,
            reasoning: Int = 0,
            requests: Int = 1
        ) -> UsageEvent {
            UsageEvent(
                provider: provider,
                model: model,
                timestamp: timestamp(dayOffset: dayOffset, hour: hour),
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation,
                reasoningTokens: reasoning,
                requestCount: requests,
                source: "mock",
                dataSource: .mock,
                isEstimated: true
            )
        }

        let claudeEvents = [
            event(provider: .claude, model: "Sample Sonnet", dayOffset: 0, hour: 10, input: 6_200, output: 3_100, cacheRead: 1_900, cacheCreation: 600),
            event(provider: .claude, model: "Sample Sonnet", dayOffset: -2, hour: 15, input: 4_300, output: 2_000, cacheRead: 1_200),
            event(provider: .claude, model: "Sample Sonnet", dayOffset: -8, hour: 11, input: 2_400, output: 1_100, cacheRead: 700),
            event(provider: .claude, model: "Sample Sonnet", dayOffset: -18, hour: 17, input: 3_100, output: 1_350, cacheCreation: 450)
        ]
        let codexEvents = [
            event(provider: .codex, model: "Sample Codex", dayOffset: 0, hour: 9, input: 3_300, output: 1_450, requests: 4),
            event(provider: .codex, model: "Sample Codex", dayOffset: -1, hour: 18, input: 2_200, output: 900, requests: 3),
            event(provider: .codex, model: "Sample Codex", dayOffset: -10, hour: 14, input: 1_700, output: 640, requests: 2),
            event(provider: .codex, model: "Sample Codex", dayOffset: -21, hour: 16, input: 2_900, output: 1_120, requests: 3)
        ]
        let geminiEvents = [
            event(provider: .gemini, model: "Sample Gemini", dayOffset: 0, hour: 13, input: 7_800, output: 2_700, cacheRead: 1_100, reasoning: 900, requests: 12),
            event(provider: .gemini, model: "Sample Gemini", dayOffset: -3, hour: 12, input: 4_600, output: 1_900, cacheRead: 800, reasoning: 400, requests: 8),
            event(provider: .gemini, model: "Sample Gemini", dayOffset: -6, hour: 20, input: 3_200, output: 1_200, cacheRead: 300, reasoning: 250, requests: 5),
            event(provider: .gemini, model: "Sample Gemini", dayOffset: -16, hour: 10, input: 5_400, output: 1_600, cacheRead: 600, reasoning: 300, requests: 7)
        ]

        func todayTotal(_ events: [UsageEvent]) -> Int {
            events
                .filter { calendar.isDate($0.timestamp, inSameDayAs: referenceDate) }
                .reduce(0) { $0 + $1.totalTokens }
        }

        return [
            ProviderSnapshot(
                provider: .claude,
                updatedAt: referenceDate,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 42, resetAt: referenceDate.addingTimeInterval(5_400), confidence: .manual),
                weekly: LimitWindow(kind: .weekly, usedPercent: 58, resetAt: referenceDate.addingTimeInterval(172_800), confidence: .manual),
                todayTokens: todayTotal(claudeEvents),
                confidence: .manual,
                dataSource: .mock,
                statusMessage: "MOCK · sample data",
                model: "Sample Sonnet",
                events: claudeEvents
            ),
            ProviderSnapshot(
                provider: .codex,
                updatedAt: referenceDate,
                fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 36, confidence: .manual),
                weekly: LimitWindow(kind: .weekly, usedPercent: 44, confidence: .manual),
                todayTokens: todayTotal(codexEvents),
                confidence: .manual,
                dataSource: .mock,
                statusMessage: "MOCK · manual estimate",
                model: "Sample Codex",
                events: codexEvents
            ),
            ProviderSnapshot(
                provider: .gemini,
                updatedAt: referenceDate,
                dailyRequestsUsed: 210,
                dailyRequestsLimit: 1_000,
                todayTokens: todayTotal(geminiEvents),
                confidence: .manual,
                dataSource: .mock,
                statusMessage: "MOCK · sample telemetry",
                model: "Sample Gemini",
                events: geminiEvents
            )
        ]
    }
}

public final class UsageStore: @unchecked Sendable {
    public struct Result: Sendable {
        public var snapshots: [ProviderSnapshot]
        public var hasConnectedData: Bool
        public var capacityObservations: [CapacityObservation]
        public var capacityErrors: [CapacityRefreshError]
        public var observedAt: Date
        /// Transient presentation-only experimental OAuth weekly result.
        /// Never converted into ProviderSnapshot/capacity/history/export/alerts sinks.
        public var xaiOAuthResult: XAIRefreshResult?

        public init(
            snapshots: [ProviderSnapshot],
            hasConnectedData: Bool,
            capacityObservations: [CapacityObservation] = [],
            capacityErrors: [CapacityRefreshError] = [],
            observedAt: Date = Date(),
            xaiOAuthResult: XAIRefreshResult? = nil
        ) {
            self.snapshots = snapshots
            self.hasConnectedData = hasConnectedData
            self.capacityObservations = capacityObservations
            self.capacityErrors = capacityErrors
            self.observedAt = observedAt
            self.xaiOAuthResult = xaiOAuthResult
        }
    }

    private let refreshAdapters: [any ProviderRefreshAdapter]
    private let mockDataService = MockDataService()
    /// Lazy factory; invoked only after eligibility (enabled + selected + consent v1 + not sandboxed).
    private let makeExperimentalWeeklyService: (@Sendable () -> any XAIExperimentalWeeklyService)?
    private let executionCapability: XAIExecutionCapability
    private let lock = OSAllocatedUnfairLock()
    private var experimentalWeeklyService: (any XAIExperimentalWeeklyService)?
    private var refreshGeneration: UInt64 = 0
    private var activeTicket: XAIRefreshTicket?

    public init(
        adapters: [any ProviderAdapter]? = nil,
        refreshAdapters: [any ProviderRefreshAdapter]? = nil,
        pathResolver: DefaultPathResolver = DefaultPathResolver(),
        makeExperimentalWeeklyService: (@Sendable () -> any XAIExperimentalWeeklyService)? = nil,
        executionCapability: XAIExecutionCapability = .current
    ) {
        self.makeExperimentalWeeklyService = makeExperimentalWeeklyService
        self.executionCapability = executionCapability
        if let refreshAdapters {
            self.refreshAdapters = refreshAdapters
        } else if let adapters {
            self.refreshAdapters = adapters.map(LegacyProviderRefreshAdapter.init)
        } else {
            self.refreshAdapters = Self.defaultAdapters(pathResolver: pathResolver)
        }
    }

    private static func defaultAdapters(pathResolver: DefaultPathResolver) -> [any ProviderRefreshAdapter] {
        let claudeProjectRoots = pathResolver.resolveDefaultPaths(for: .claude)
            .filter { ["projects", "config_projects"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let codexSessionRoots = pathResolver.resolveDefaultPaths(for: .codex)
            .filter { ["sessions", "archived_sessions"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let geminiSourceURLs = pathResolver.resolveDefaultPaths(for: .gemini)
            .filter { ["antigravity_statusline", "telemetry", "tmp", "history"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: ["tmp", "history"].contains($0.kind)) }

        return [
            ClaudeStatuslineAdapter(fallbackProjectRoots: claudeProjectRoots.isEmpty ? nil : claudeProjectRoots),
            GeminiTelemetryAdapter(logURLs: geminiSourceURLs),
            CodexLocalSessionAdapter(sessionRoots: codexSessionRoots.isEmpty ? nil : codexSessionRoots),
            DeepSeekBalanceAdapter(),
            GrokLocalSignalsAdapter()
        ]
    }

    public func refresh(
        settings: AppSettings,
        intent: UsageRefreshIntent = .automaticTimer
    ) async -> Result {
        let observedAt = Date()
        let enabledProviders = Set(settings.enabledProviders)
        var snapshots: [ProviderSnapshot] = []
        var capacityObservations: [CapacityObservation] = []
        var capacityErrors: [CapacityRefreshError] = []

        for adapter in refreshAdapters where enabledProviders.contains(adapter.provider) {
            if Task.isCancelled {
                capacityErrors.append(CapacityRefreshError(provider: adapter.provider, category: .cancelled, code: "refreshCancelled", redactedMessage: "Provider refresh cancelled."))
                continue
            }
            let result = await adapter.refresh(settings: settings, now: observedAt)
            var snapshot = result.snapshot
            snapshot.updatedAt = result.observedAt
            snapshots.append(snapshot)
            capacityObservations.append(contentsOf: result.capacityObservations)
            capacityErrors.append(contentsOf: result.typedErrors)
            if Task.isCancelled {
                capacityErrors.append(CapacityRefreshError(provider: adapter.provider, category: .cancelled, code: "refreshCancelled", redactedMessage: "Provider refresh cancelled."))
            }
        }

        // OAuth weekly is presentation-only: never merged into snapshots/capacity/history/export/alerts,
        // and never routed through OpenCode Bar.
        let xaiOAuthResult = await refreshXAIExperimentalWeeklyIfEligible(
            settings: settings,
            intent: intent,
            now: observedAt
        )

        let hasConnectedData = snapshots.contains { !$0.events.isEmpty || $0.primaryUsedPercent != nil || $0.dailyRequestsUsed != nil || $0.contextWindowUsedPercent != nil || $0.balance != nil }
        let ordered = snapshots.sorted { $0.provider.rawValue < $1.provider.rawValue }

        if settings.showMockDataWhenDisconnected && !hasConnectedData {
            let mock = mockDataService.snapshots(referenceDate: observedAt)
                .filter { enabledProviders.contains($0.provider) }
                .sorted { $0.provider.rawValue < $1.provider.rawValue }
            return Result(
                snapshots: mock,
                hasConnectedData: false,
                capacityObservations: [],
                capacityErrors: capacityErrors,
                observedAt: observedAt,
                xaiOAuthResult: xaiOAuthResult
            )
        }

        return Result(
            snapshots: ordered,
            hasConnectedData: hasConnectedData,
            capacityObservations: capacityObservations,
            capacityErrors: capacityErrors,
            observedAt: observedAt,
            xaiOAuthResult: xaiOAuthResult
        )
    }

    /// Invalidates the current generation and asks any constructed experimental weekly service to revoke.
    /// Call before persisting disabled provider/consent settings.
    public func revokeXAIExperimentalWeekly(ticket: XAIRefreshTicket? = nil) async {
        let serviceAndTicket: (service: (any XAIExperimentalWeeklyService)?, ticket: XAIRefreshTicket?) = lock.withLock {
            refreshGeneration &+= 1
            let revokeTicket = ticket ?? activeTicket
            activeTicket = nil
            return (experimentalWeeklyService, revokeTicket)
        }
        await serviceAndTicket.service?.revoke(ticket: serviceAndTicket.ticket)
    }

    /// Shuts down and drops any constructed experimental weekly service (app termination / teardown).
    public func shutdownXAIExperimentalWeekly() async {
        let service: (any XAIExperimentalWeeklyService)? = lock.withLock {
            refreshGeneration &+= 1
            activeTicket = nil
            let existing = experimentalWeeklyService
            experimentalWeeklyService = nil
            return existing
        }
        await service?.shutdown()
    }

    private func isXAIExperimentalWeeklyEligible(_ settings: AppSettings) -> Bool {
        settings.xaiEnabled
            && settings.isProviderEnabled(.xai)
            && settings.xAI.experimentalOAuthWeeklyConsentVersion
                == XAISettings.experimentalOAuthWeeklyConsentVersionCurrent
            && !executionCapability.isSandboxed
    }

    /// Constructs the experimental service only when fully eligible; otherwise returns nil with zero service work.
    /// Late results after revoke/shutdown generation invalidation are dropped (never published).
    private func refreshXAIExperimentalWeeklyIfEligible(
        settings: AppSettings,
        intent: UsageRefreshIntent,
        now: Date
    ) async -> XAIRefreshResult? {
        guard isXAIExperimentalWeeklyEligible(settings) else {
            return nil
        }
        guard let makeService = makeExperimentalWeeklyService else {
            return nil
        }

        let serviceAndTicket: (service: any XAIExperimentalWeeklyService, ticket: XAIRefreshTicket)? = lock.withLock {
            if experimentalWeeklyService == nil {
                experimentalWeeklyService = makeService()
            }
            guard let service = experimentalWeeklyService else { return nil }
            refreshGeneration &+= 1
            let ticket = XAIRefreshTicket(generation: refreshGeneration)
            activeTicket = ticket
            return (service, ticket)
        }
        guard let serviceAndTicket else { return nil }

        let input = XAIExperimentalWeeklyInput(
            settings: settings,
            intent: intent,
            ticket: serviceAndTicket.ticket,
            now: now
        )
        let result = await serviceAndTicket.service.refresh(input)

        // Generation/ticket commit gate: consent off, provider off, revoke, or shutdown
        // must prevent late OAuth publication even if the transport already finished.
        return lock.withLock {
            guard activeTicket == serviceAndTicket.ticket else {
                return nil
            }
            if result.oauthFailure == .staleResult || result.completion == .cancelledOrdinarily {
                activeTicket = nil
                return nil
            }
            activeTicket = nil
            return result
        }
    }
}


public final class AlertDeduplicationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = OSAllocatedUnfairLock()

    public init(defaults: UserDefaults = .standard, key: String = "tokenPilot.alertDeliveryState.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: AlertDeliveryState] {
        lock.withLock {
            guard let data = defaults.data(forKey: key), let decoded = try? decoder.decode([String: AlertDeliveryState].self, from: data) else { return [:] }
            return decoded
        }
    }

    public func save(_ states: [String: AlertDeliveryState]) {
        lock.withLock {
            guard let data = try? encoder.encode(states) else { return }
            defaults.set(data, forKey: key)
        }
    }

    public func clear() {
        lock.withLock {
            defaults.removeObject(forKey: key)
        }
    }
}

public final class NotificationRuleService: @unchecked Sendable {
    private let store: AlertDeduplicationStore

    public init(store: AlertDeduplicationStore = AlertDeduplicationStore()) {
        self.store = store
    }

    public func evaluate(
        snapshots: [XAIProvenancedSnapshot],
        settings: AppSettings,
        language: TokenPilotLanguage = .en
    ) -> NotificationRuleEvaluation {
        let admission = XAISinkAdmission.admitSnapshots(snapshots, sink: .notification)
        let events = evaluate(snapshots: admission.accepted, settings: settings, language: language)
        return NotificationRuleEvaluation(events: events, exclusions: admission.exclusions)
    }

    public func evaluate(snapshots: [ProviderSnapshot], settings: AppSettings, language: TokenPilotLanguage = .en) -> [AlertEvent] {
        guard settings.globalNotificationsEnabled else { return [] }
        var states = store.load()
        var events: [AlertEvent] = []
        let snapshotsByProvider = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })

        for rule in settings.alertRules {
            guard let snapshot = snapshotsByProvider[rule.provider], let current = windowValue(snapshot: snapshot, window: rule.window) else { continue }
            let resetAt = windowReset(snapshot: snapshot, window: rule.window)
            let cycleID = resetCycleId(provider: rule.provider, window: rule.window, resetAt: resetAt)
            let key = rule.id
            let previousState = states[key] ?? AlertDeliveryState(provider: rule.provider, window: rule.window, resetCycleId: cycleID)
            let isNewCycle = previousState.resetCycleId != cycleID
            var state = previousState
            if isNewCycle {
                state = AlertDeliveryState(
                    provider: rule.provider,
                    window: rule.window,
                    resetCycleId: cycleID,
                    lastUsedPercent: previousState.lastUsedPercent,
                    lastResetAt: resetAt
                )
            }

            if rule.resetEnabled, shouldSendReset(previous: previousState, current: current, resetAt: resetAt, isNewCycle: isNewCycle) {
                let event = makeEvent(provider: rule.provider, window: rule.window, threshold: .reset, usedPercent: current, resetAt: resetAt, cycleID: cycleID, language: language)
                events.append(event)
                state.sentReset = true
                state.lastSentAt = Date()
            }

            for threshold in [AlertThreshold.fifty, .eighty, .hundred] where rule.isEnabled(threshold) {
                guard let percent = threshold.percent else { continue }
                let wasBelow = (state.lastUsedPercent ?? current) < percent
                let isNowAtOrAbove = current >= percent
                let alreadySent: Bool
                switch threshold {
                case .fifty: alreadySent = state.sent50
                case .eighty: alreadySent = state.sent80
                case .hundred: alreadySent = state.sent100
                case .reset: alreadySent = true
                }
                if wasBelow && isNowAtOrAbove && !alreadySent {
                    let event = makeEvent(provider: rule.provider, window: rule.window, threshold: threshold, usedPercent: current, resetAt: resetAt, cycleID: cycleID, language: language)
                    events.append(event)
                    switch threshold {
                    case .fifty: state.sent50 = true
                    case .eighty: state.sent80 = true
                    case .hundred: state.sent100 = true
                    case .reset: break
                    }
                    state.lastSentAt = Date()
                }
            }
            state.lastUsedPercent = current
            state.lastResetAt = resetAt
            states[key] = state
        }
        appendDeepSeekLowBalanceEvents(snapshotsByProvider: snapshotsByProvider, settings: settings, language: language, states: &states, events: &events)
        store.save(states)
        return events
    }

    private func appendDeepSeekLowBalanceEvents(
        snapshotsByProvider: [Provider: ProviderSnapshot],
        settings: AppSettings,
        language: TokenPilotLanguage,
        states: inout [String: AlertDeliveryState],
        events: inout [AlertEvent]
    ) {
        guard settings.globalNotificationsEnabled,
              settings.deepseekEnabled,
              let snapshot = snapshotsByProvider[.deepseek],
              snapshot.dataSource == .officialTelemetry,
              let balance = snapshot.balance,
              balance.toppedUpBalance <= settings.deepSeekBalance.lowBalanceThreshold else {
            return
        }
        let cycleID = "deepseek-balance-\(Int(balance.capturedAt.timeIntervalSince1970 / 86_400))"
        let key = "deepseek.balance.low"
        var state = states[key] ?? AlertDeliveryState(provider: .deepseek, window: .dailyRequests, resetCycleId: cycleID)
        if state.resetCycleId != cycleID {
            state = AlertDeliveryState(provider: .deepseek, window: .dailyRequests, resetCycleId: cycleID)
        }
        guard !state.sent50 else { return }
        let display = DeepSeekBalanceFormatter.display(balance)
        let threshold = DeepSeekBalanceFormatter.display(ProviderBalance(currency: balance.currency, toppedUpBalance: settings.deepSeekBalance.lowBalanceThreshold))
        events.append(AlertEvent(
            provider: .deepseek,
            window: .dailyRequests,
            threshold: .fifty,
            resetCycleId: cycleID,
            title: TokenPilotLocalizer.localized("DeepSeek low balance", language: language),
            body: String(format: TokenPilotLocalizer.localized("DeepSeek topped-up balance is %@ (threshold %@).", language: language), display, threshold)
        ))
        state.sent50 = true
        state.lastSentAt = Date()
        states[key] = state
    }

    private func windowValue(snapshot: ProviderSnapshot, window: LimitWindowKind) -> Int? {
        switch window {
        case .fiveHour: return snapshot.fiveHour?.usedPercent
        case .monthly: return snapshot.monthly?.usedPercent
        case .weekly: return snapshot.weekly?.usedPercent
        case .dailyRequests: return snapshot.dailyRequestsPercent
        }
    }

    private func windowReset(snapshot: ProviderSnapshot, window: LimitWindowKind) -> Date? {
        switch window {
        case .fiveHour: return snapshot.fiveHour?.resetAt
        case .monthly: return snapshot.monthly?.resetAt
        case .weekly: return snapshot.weekly?.resetAt
        case .dailyRequests: return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        }
    }

    private func shouldSendReset(previous: AlertDeliveryState, current: Int, resetAt: Date?, isNewCycle: Bool) -> Bool {
        if previous.sentReset && !isNewCycle { return false }
        if let last = previous.lastUsedPercent, last > 10, current <= 3 { return true }
        if isNewCycle, current <= 3 { return true }
        if let resetAt, resetAt < Date(), current <= 3 { return true }
        return false
    }

    private func resetCycleId(provider: Provider, window: LimitWindowKind, resetAt: Date?) -> String {
        if let resetAt {
            return "\(provider.rawValue)-\(window.rawValue)-\(Int(resetAt.timeIntervalSince1970 / 60))"
        }
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return "\(provider.rawValue)-\(window.rawValue)-\(Int(day))"
    }

    private func makeEvent(provider: Provider, window: LimitWindowKind, threshold: AlertThreshold, usedPercent: Int?, resetAt: Date?, cycleID: String, language: TokenPilotLanguage) -> AlertEvent {
        let title = titleFor(threshold: threshold, language: language)
        let resetText = resetAt.map { TokenPilotFormatters.remainingTime(until: $0, language: language) } ?? "—"
        let providerWindowText = "\(TokenPilotLocalizer.localized(provider.displayName, language: language)) · \(TokenPilotLocalizer.localized(window.label, language: language))"
        let body: String
        switch threshold {
        case .reset:
            body = String(format: TokenPilotLocalizer.localized("alert.reset.body", language: language), providerWindowText)
        case .fifty:
            body = String(format: TokenPilotLocalizer.localized("alert.fifty.body", language: language), providerWindowText, resetText)
        case .eighty:
            body = String(format: TokenPilotLocalizer.localized("alert.eighty.body", language: language), providerWindowText, usedPercent ?? 0, resetText)
        case .hundred:
            body = String(format: TokenPilotLocalizer.localized("alert.hundred.body", language: language), providerWindowText, resetText)
        }
        return AlertEvent(provider: provider, window: window, threshold: threshold, usedPercent: usedPercent, resetAt: resetAt, resetCycleId: cycleID, title: title, body: body)
    }

    private func titleFor(threshold: AlertThreshold, language: TokenPilotLanguage) -> String {
        let key: String
        switch threshold {
        case .reset: key = "alert.reset.title"
        case .fifty: key = "alert.fifty.title"
        case .eighty: key = "alert.eighty.title"
        case .hundred: key = "alert.hundred.title"
        }
        return TokenPilotLocalizer.localized(key, language: language)
    }
}

public final class LocalNotificationService: @unchecked Sendable {
    public init() {}

    public func permissionStatus() async -> NotificationPermissionState {
        #if canImport(UserNotifications)
        guard canUseUserNotifications else { return .unknown }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notRequested
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        @unknown default: return .unknown
        }
        #else
        return .unknown
        #endif
    }

    public func requestPermission() async -> NotificationPermissionState {
        #if canImport(UserNotifications)
        guard canUseUserNotifications else { return .unknown }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .granted : .denied
        } catch {
            return .unknown
        }
        #else
        return .unknown
        #endif
    }

    public func send(title: String, body: String) async throws {
        #if canImport(UserNotifications)
        guard canUseUserNotifications else {
            try sendWithAppleScript(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
        #else
        try sendWithAppleScript(title: title, body: body)
        #endif
    }

    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func sendWithAppleScript(title: String, body: String) throws {
        let escapedTitle = title.appleScriptEscaped
        let escapedBody = body.appleScriptEscaped
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"Ping\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
    }
}

private extension String {
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

public final class TelegramNotificationService: @unchecked Sendable {
    public init() {}

    public func sendMessage(token: String, chatID: String, text: String, parseMode: String? = nil) async throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TelegramError.notConfigured }
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TelegramError.notConfigured }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { throw TelegramError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["chat_id": chatID, "text": text]
        if let parseMode { payload["parse_mode"] = parseMode }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TelegramError.requestFailed
        }
    }

    public func findChatID(token: String) async throws -> String {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TelegramError.notConfigured }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getUpdates") else { throw TelegramError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TelegramError.requestFailed
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [[String: Any]] else {
            throw TelegramError.noChatFound
        }
        for update in result.reversed() {
            if let message = update["message"] as? [String: Any],
               let chat = message["chat"] as? [String: Any],
               let id = chat["id"] {
                if let number = id as? NSNumber { return number.stringValue }
                if let string = id as? String { return string }
            }
        }
        throw TelegramError.noChatFound
    }
}

public enum TelegramError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case requestFailed
    case noChatFound

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Telegram is not configured."
        case .invalidURL: return "Telegram URL is invalid."
        case .requestFailed: return "Telegram request failed."
        case .noChatFound: return "No chat ID found. Send a message to the bot first."
        }
    }
}

public final class DiscordNotificationService: @unchecked Sendable {
    public init() {}

    public static func makeRequest(webhookURL: String, content: String) throws -> URLRequest {
        let trimmedURL = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw DiscordError.notConfigured }
        guard let url = URL(string: trimmedURL), isAllowedDiscordWebhookURL(url) else { throw DiscordError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let safeContent = content.count > 1900 ? String(content.prefix(1900)) + "…" : content
        let payload: [String: Any] = [
            "content": safeContent,
            "username": "TokenPilot"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    public func sendMessage(webhookURL: String, content: String) async throws {
        let request = try Self.makeRequest(webhookURL: webhookURL, content: content)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DiscordError.requestFailed
        }
    }

    private static func isAllowedDiscordWebhookURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["discord.com", "www.discord.com", "discordapp.com", "www.discordapp.com"].contains(host) else {
            return false
        }
        return url.path.contains("/api/webhooks/")
    }
}

public enum DiscordError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Discord webhook is not configured."
        case .invalidURL: return "Discord webhook URL is invalid."
        case .requestFailed: return "Discord request failed."
        }
    }
}

protocol KeychainBackend: Sendable {
    func saveSecret(_ secret: String, service: String, account: String) throws
    func readSecret(service: String, account: String) throws -> String?
    func deleteSecret(service: String, account: String, ignoreMissing: Bool) throws
}

private struct SecurityKeychainBackend: KeychainBackend {
    func saveSecret(_ secret: String, service: String, account: String) throws {
        let data = Data(secret.utf8)
        try deleteSecret(service: service, account: account, ignoreMissing: true)
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        #endif
    }

    func readSecret(service: String, account: String) throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return secret
        #else
        return nil
        #endif
    }

    func deleteSecret(service: String, account: String, ignoreMissing: Bool) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            if ignoreMissing { return }
            throw KeychainError.itemNotFound
        }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        #endif
    }
}

public final class KeychainService: @unchecked Sendable {
    public static let xaiManagementAPIKeyAccount = "xai.managementAPIKey"
    private let service: String
    private let backend: any KeychainBackend

    public convenience init(service: String = "com.tokenpilot.macos") {
        self.init(service: service, backend: SecurityKeychainBackend())
    }

    init(service: String, backend: any KeychainBackend) {
        self.service = service
        self.backend = backend
    }

    public func saveSecret(_ secret: String, account: String) throws {
        try backend.saveSecret(secret, service: service, account: account)
    }

    public func readSecret(account: String) throws -> String? {
        try backend.readSecret(service: service, account: account)
    }

    public func deleteSecret(account: String) throws {
        try backend.deleteSecret(service: service, account: account, ignoreMissing: false)
    }
}

public enum KeychainError: Error, Equatable, LocalizedError {
    case itemNotFound
    case unhandledStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "Requested keychain item was not found."
        case .unhandledStatus(let status): return "Keychain returned status \(status)."
        case .invalidData: return "Keychain item contained invalid data."
        }
    }
}

public enum TokenPilotFormatters {
    public static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K") }
        return "\(value)"
    }

    public static func cost(_ value: Decimal) -> String {
        String(format: "$%.4f", NSDecimalNumber(decimal: value).doubleValue)
    }

    public static func remainingTime(
        until date: Date,
        language: TokenPilotLanguage = .en,
        now: Date = Date()
    ) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let units: (hour: String, minute: String)
        switch TokenPilotLocalizer.effectiveLanguage(for: language) {
        case .system, .en:
            units = ("h", "m")
        case .ko:
            units = ("시간", "분")
        case .ja:
            units = ("時間", "分")
        case .zhHans:
            units = ("小时", "分钟")
        }
        if hours > 0 { return "\(hours)\(units.hour) \(minutes)\(units.minute)" }
        return "\(minutes)\(units.minute)"
    }

    public static func compactRemainingTime(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        if days > 0 { return "\(days)d" }
        let hours = seconds / 3_600
        if hours > 0 { return "\(hours)h" }
        let minutes = (seconds % 3_600) / 60
        return "\(minutes)m"
    }

    private static let clockFormatters = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())

    public static func clock(_ date: Date?, language: TokenPilotLanguage) -> String {
        guard let date else { return "—" }
        let localeIdentifier = clockLocaleIdentifier(for: language)

        return clockFormatters.withLock { formatters in
            if let formatter = formatters[localeIdentifier] {
                return formatter.string(from: date)
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            formatter.locale = Locale(identifier: localeIdentifier)
            formatters[localeIdentifier] = formatter
            return formatter.string(from: date)
        }
    }

    public static func clock(_ date: Date?) -> String {
        clock(date, language: .system)
    }

    private static func clockLocaleIdentifier(for language: TokenPilotLanguage) -> String {
        switch TokenPilotLocalizer.effectiveLanguage(for: language) {
        case .system, .en:
            return "en_US"
        case .ko:
            return "ko_KR"
        case .ja:
            return "ja_JP"
        case .zhHans:
            return "zh_Hans_CN"
        }
    }
}

