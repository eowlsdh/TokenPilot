import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func tokenPilotBoundedTextContents(of file: URL, maxBytes: UInt64 = 4 * 1_024 * 1_024) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }

    let size = tokenPilotFileByteSize(file)
    let start = size > maxBytes ? size - maxBytes : 0
    if start > 0 {
        try handle.seek(toOffset: start)
    }
    let data = try handle.readToEnd() ?? Data()
    let text = String(data: data, encoding: .utf8) ?? ""
    guard start > 0, let newlineIndex = text.firstIndex(of: "\n") else {
        return text
    }
    return String(text[text.index(after: newlineIndex)...])
}

private func tokenPilotFileByteSize(_ file: URL) -> UInt64 {
    guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber else { return 0 }
    return size.uint64Value
}

public protocol CodexWebUsageHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCodexWebUsageHTTPClient: CodexWebUsageHTTPClient {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexWebUsageError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

public enum CodexWebUsageError: Error, Sendable {
    case invalidHTTPResponse
}

public protocol CodexAppServerRateLimitClient: Sendable {
    func readRateLimits() async throws -> Data
}

public enum CodexAppServerRateLimitError: Error, Sendable {
    case launchFailed
    case timeout
    case noResponse
}

public struct CodexAppServerRateLimitProcessClient: CodexAppServerRateLimitClient, Sendable {
    private let codexExecutablePath: String
    private let environment: [String: String]
    private let timeoutSeconds: TimeInterval
    private let clientName: String
    private let clientTitle: String
    private let clientVersion: String

    public init(
        codexExecutablePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: TimeInterval = 8,
        clientName: String = "tokenpilot",
        clientTitle: String = "TokenPilot",
        clientVersion: String = "1.0"
    ) {
        self.environment = environment
        self.codexExecutablePath = codexExecutablePath
            ?? environment["TOKENPILOT_CODEX_PATH"]
            ?? environment["CODEX_CLI_PATH"]
            ?? "codex"
        self.timeoutSeconds = max(timeoutSeconds, 1)
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion
    }

    public func readRateLimits() async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Self.runAppServerAndReadRateLimits(
                codexExecutablePath: codexExecutablePath,
                environment: environment,
                timeoutSeconds: timeoutSeconds,
                clientName: clientName,
                clientTitle: clientTitle,
                clientVersion: clientVersion
            )
        }.value
    }

    internal static func makeRequestLinesForTesting(clientName: String, clientTitle: String, clientVersion: String) -> [String] {
        makeRequestLines(clientName: clientName, clientTitle: clientTitle, clientVersion: clientVersion)
    }

    private static func makeRequestLines(clientName: String, clientTitle: String, clientVersion: String) -> [String] {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": clientName,
                    "title": clientTitle,
                    "version": clientVersion
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        ]
        let read: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "account/rateLimits/read"
        ]
        return [initialize, read].compactMap { object in
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        }
    }

    private static func runAppServerAndReadRateLimits(
        codexExecutablePath: String,
        environment: [String: String],
        timeoutSeconds: TimeInterval,
        clientName: String,
        clientTitle: String,
        clientVersion: String
    ) throws -> Data {
        let process = Process()
        let command = codexExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
            process.arguments = ["app-server"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command.isEmpty ? "codex" : command, "app-server"]
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ResponseCollector()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(data)
        }
        // Drain stderr so a noisy CLI cannot block while the JSON-RPC response is pending.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerRateLimitError.launchFailed
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinPipe.fileHandleForWriting.close()
            terminateProcessIfNeeded(process)
        }

        let request = makeRequestLines(clientName: clientName, clientTitle: clientTitle, clientVersion: clientVersion)
            .map { $0 + "\n" }
            .joined()
        if let data = request.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }

        let timeout = DispatchTime.now() + .milliseconds(Int(timeoutSeconds * 1_000))
        guard collector.wait(timeout: timeout) else {
            throw CodexAppServerRateLimitError.timeout
        }

        guard let finalResponse = collector.responseData() else { throw CodexAppServerRateLimitError.noResponse }
        return finalResponse
    }

    private static func terminateProcessIfNeeded(_ process: Process, graceSeconds: TimeInterval = 0.25) {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(max(graceSeconds, 0.05))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        guard process.isRunning else { return }
        forceKill(process)
        process.waitUntilExit()
    }

    private static func forceKill(_ process: Process) {
        #if canImport(Darwin)
        Darwin.kill(process.processIdentifier, SIGKILL)
        #elseif canImport(Glibc)
        Glibc.kill(process.processIdentifier, SIGKILL)
        #else
        process.interrupt()
        #endif
    }

    private final class ResponseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var buffer = Data()
        private var response: Data?

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            let newline = Data([0x0A])
            while let range = buffer.firstRange(of: newline) {
                let line = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                if CodexAppServerRateLimitProcessClient.isTargetRateLimitResponse(line) {
                    response = line
                    semaphore.signal()
                    break
                }
            }
        }

        func wait(timeout: DispatchTime) -> Bool {
            semaphore.wait(timeout: timeout) == .success
        }

        func responseData() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return response
        }
    }

    private static func isTargetRateLimitResponse(_ data: Data) -> Bool {
        let trimmed = Data(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).utf8 ?? "".utf8)
        guard !trimmed.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any],
              let id = intValue(object["id"]),
              id == 2 else { return false }
        return true
    }
}

// MARK: - Claude Statusline Adapter

public final class ClaudeStatuslineAdapter: ProviderAdapter, Sendable {
    public let provider: Provider = .claude
    private let overrideFileURL: URL?
    private let fallbackProjectRoots: [URL]?
    private let staleThreshold: TimeInterval

    public init(fileURL: URL? = nil, fallbackProjectRoots: [URL]? = nil, staleThreshold: TimeInterval = 300) {
        self.overrideFileURL = fileURL
        self.fallbackProjectRoots = fallbackProjectRoots
        self.staleThreshold = staleThreshold
    }

    public func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        guard settings.claudeEnabled else {
            return ProviderSnapshot(provider: .claude, confidence: .low, statusMessage: "Disabled")
        }

        let fileURL = overrideFileURL ?? URL(fileURLWithPath: expandTilde(settings.claudeStatusFilePath))
        let bookmarkData = overrideFileURL == nil ? settings.claudeStatusFileBookmarkData : nil
        if FileManager.default.fileExists(atPath: fileURL.path) || bookmarkData != nil {
            if isDirectory(fileURL) {
                if let fallback = parseLocalJSONLFallback(roots: [fileURL]) {
                    return fallback
                }
                return ProviderSnapshot(
                    provider: .claude,
                    confidence: .low,
                    dataSource: .localLog,
                    statusMessage: "No Claude JSONL usage rows yet"
                )
            }
            return parseStatuslineFile(fileURL, bookmarkData: bookmarkData)
        }

        if shouldUseLocalJSONLFallback(fileURL: fileURL, settings: settings), let fallback = parseLocalJSONLFallback() {
            return fallback
        }

        return ProviderSnapshot(
            provider: .claude,
            confidence: .low,
            dataSource: .unknown,
            isStale: false,
            statusMessage: "Connect Claude statusline"
        )
    }

    private func shouldUseLocalJSONLFallback(fileURL: URL, settings: AppSettings) -> Bool {
        // Avoid surprising tests/users by reading ~/.claude when a custom missing statusline path was selected.
        // Fallback is allowed for the default TokenPilot statusline path or when tests inject explicit roots.
        if fallbackProjectRoots != nil { return true }
        if overrideFileURL != nil { return false }
        let configured = URL(fileURLWithPath: expandTilde(settings.claudeStatusFilePath)).standardizedFileURL.path
        let defaultPath = URL(fileURLWithPath: expandTilde(AppSettings().claudeStatusFilePath)).standardizedFileURL.path
        return configured == defaultPath && fileURL.standardizedFileURL.path == defaultPath
    }

    private func parseStatuslineFile(_ fileURL: URL, bookmarkData: Data?) -> ProviderSnapshot {
        let scopedAccess = TokenPilotSecurityScopedBookmarks.resolveIfAvailable(bookmarkData: bookmarkData, fallbackURL: fileURL)
        defer { scopedAccess.stop() }
        let readableURL = scopedAccess.url

        do {
            let data = try Data(contentsOf: readableURL)
            let rawObject: Any
            do {
                rawObject = try JSONSerialization.jsonObject(with: data)
            } catch {
                return ProviderSnapshot(provider: .claude, confidence: .low, dataSource: .officialStatusline, isStale: true, statusMessage: "Invalid JSON")
            }
            guard let json = rawObject as? [String: Any] else {
                return ProviderSnapshot(provider: .claude, confidence: .low, dataSource: .officialStatusline, isStale: true, statusMessage: "Invalid JSON")
            }

            let modDate = fileModificationDate(readableURL) ?? Date.distantPast
            let isStale = Date().timeIntervalSince(modDate) > staleThreshold

            let rateLimits = dictionary(json["rate_limits"])
            let fiveHour = parseWindow(from: firstDictionary(in: rateLimits, keys: ["five_hour", "fiveHour", "5h", "primary"]), kind: .fiveHour, stale: isStale)
            let weekly = parseWindow(from: firstDictionary(in: rateLimits, keys: ["seven_day", "weekly", "week", "7d", "secondary"]), kind: .weekly, stale: isStale)

            let contextWindow = dictionary(json["context_window"])
            let contextWindowUsedPercent = intValue(contextWindow?["used_percentage"] ?? contextWindow?["used_percent"] ?? contextWindow?["usage_percent"])
            let currentUsage = dictionary(contextWindow?["current_usage"]) ?? dictionary(value(json, path: "usage"))
            let inputTokens = intValue(currentUsage?["input_tokens"] ?? currentUsage?["inputTokens"] ?? currentUsage?["base_input_tokens"]) ?? 0
            let outputTokens = intValue(currentUsage?["output_tokens"] ?? currentUsage?["outputTokens"]) ?? 0
            let cacheCreation = intValue(currentUsage?["cache_creation_input_tokens"] ?? currentUsage?["cacheWriteInputTokens"] ?? currentUsage?["cache_write_input_tokens"]) ?? 0
            let cacheRead = intValue(currentUsage?["cache_read_input_tokens"] ?? currentUsage?["cacheReadInputTokens"]) ?? 0
            let totalTokens = inputTokens + outputTokens + cacheCreation + cacheRead

            let modelName = stringValue(value(json, path: "model.display_name")) ?? stringValue(json["model"])
            let totalCost = decimalValue(value(json, path: "cost.total_cost_usd") ?? json["total_cost_usd"])
            let hasRateData = fiveHour != nil || weekly != nil
            let hasTokenData = totalTokens > 0
            let hasContextData = contextWindowUsedPercent != nil

            guard hasRateData || hasTokenData || hasContextData else {
                return ProviderSnapshot(
                    provider: .claude,
                    updatedAt: modDate,
                    confidence: .low,
                    dataSource: .officialStatusline,
                    isStale: false,
                    statusMessage: "No rate limit data yet",
                    model: modelName,
                    contextWindowUsedPercent: contextWindowUsedPercent
                )
            }

            let confidence: DataConfidence = isStale ? .medium : .high
            let event = hasTokenData ? UsageEvent(
                provider: .claude,
                model: modelName,
                timestamp: modDate,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation,
                source: "claude-statusline",
                dataSource: .officialStatusline
            ) : nil

            return ProviderSnapshot(
                provider: .claude,
                updatedAt: modDate,
                fiveHour: fiveHour,
                weekly: weekly,
                todayTokens: totalTokens,
                todayCostUSD: totalCost,
                confidence: confidence,
                dataSource: .officialStatusline,
                isStale: isStale,
                statusMessage: isStale ? "STALE · older than 5 minutes" : "Connected",
                model: modelName,
                contextWindowUsedPercent: contextWindowUsedPercent,
                events: event.map { [$0] } ?? []
            )
        } catch {
            return ProviderSnapshot(provider: .claude, confidence: .low, dataSource: .officialStatusline, isStale: true, statusMessage: "Claude statusline could not be read")
        }
    }

    private func parseLocalJSONLFallback(roots overrideRoots: [URL]? = nil) -> ProviderSnapshot? {
        let roots = overrideRoots ?? fallbackProjectRoots ?? defaultClaudeProjectRoots()
        let files = candidateFiles(in: roots, allowedExtensions: ["jsonl"], maxFiles: 80)
        guard !files.isEmpty else { return nil }

        var events: [UsageEvent] = []
        var eventsByCanonicalKey: [String: UsageEvent] = [:]
        var canonicalKeyByAlias: [String: String] = [:]
        for file in files where !isForbiddenCredentialPath(file) {
            guard let content = try? tokenPilotBoundedTextContents(of: file) else { continue }
            let fileDate = fileModificationDate(file) ?? Date()
            for line in content.components(separatedBy: .newlines) {
                guard let json = jsonObject(fromLine: line), let parsed = parseClaudeJSONLEvent(json, fallbackTimestamp: fileDate) else { continue }
                let aliases = parsed.dedupeKeys
                if aliases.isEmpty {
                    events.append(parsed.event)
                    continue
                }

                let mappedCanonicals = aliases.compactMap { canonicalKeyByAlias[$0] }
                let canonical = mappedCanonicals.first ?? aliases[0]
                let canonicalGroup = Set(mappedCanonicals + [canonical])
                var richest = parsed.event
                for key in canonicalGroup {
                    if let existing = eventsByCanonicalKey[key], isRicherClaudeEvent(existing, than: richest) {
                        richest = existing
                    }
                }
                for key in canonicalGroup where key != canonical {
                    eventsByCanonicalKey.removeValue(forKey: key)
                }
                eventsByCanonicalKey[canonical] = richest
                for (alias, mappedCanonical) in canonicalKeyByAlias where canonicalGroup.contains(mappedCanonical) {
                    canonicalKeyByAlias[alias] = canonical
                }
                for alias in aliases {
                    canonicalKeyByAlias[alias] = canonical
                }
            }
        }
        events.append(contentsOf: eventsByCanonicalKey.values)

        guard !events.isEmpty else { return nil }
        events.sort { $0.timestamp < $1.timestamp }
        let calendar = Calendar.current
        let now = Date()
        let todayEvents = events.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        let todayTokens = todayEvents.reduce(0) { $0 + $1.totalTokens }
        let newest = events.map(\.timestamp).max() ?? Date()
        let isStale = Date().timeIntervalSince(newest) > staleThreshold
        let retainedStart = calendar.date(byAdding: .day, value: -31, to: calendar.startOfDay(for: now)) ?? now
        let retained = events.filter { $0.timestamp >= retainedStart }
        let model = retained.reversed().first { $0.model?.isEmpty == false }?.model
        let cost = todayEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)

        return ProviderSnapshot(
            provider: .claude,
            updatedAt: newest,
            todayTokens: todayTokens,
            todayCostUSD: cost > 0 ? cost : nil,
            confidence: .medium,
            dataSource: .localLog,
            isStale: isStale,
            statusMessage: isStale ? "STALE · local JSONL older than 5 minutes" : "Local JSONL · rate limits unavailable",
            model: model,
            events: retained
        )
    }

    private func parseClaudeJSONLEvent(_ json: [String: Any], fallbackTimestamp: Date) -> (dedupeKeys: [String], event: UsageEvent)? {
        let message = dictionary(json["message"])
        let usage = dictionary(message?["usage"]) ?? dictionary(json["usage"])
        guard let usage else { return nil }

        let inputTokens = intValue(usage["input_tokens"] ?? usage["inputTokens"]) ?? 0
        let outputTokens = intValue(usage["output_tokens"] ?? usage["outputTokens"]) ?? 0
        let cacheCreation = intValue(usage["cache_creation_input_tokens"] ?? usage["cacheWriteInputTokens"] ?? usage["cache_write_input_tokens"]) ?? 0
        let cacheRead = intValue(usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"]) ?? 0
        guard inputTokens + outputTokens + cacheCreation + cacheRead > 0 else { return nil }

        let event = UsageEvent(
            provider: .claude,
            model: stringValue(message?["model"] ?? json["model"]),
            timestamp: dateValue(json["timestamp"] ?? json["created_at"] ?? message?["created_at"]) ?? fallbackTimestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            estimatedCostUSD: decimalValue(json["costUSD"] ?? json["cost_usd"] ?? value(json, path: "cost.total_cost_usd")),
            source: "claude-jsonl",
            dataSource: .localLog
        )
        return (claudeJSONLDedupeKeys(from: json, message: message), event)
    }

    private func isRicherClaudeEvent(_ candidate: UsageEvent, than existing: UsageEvent) -> Bool {
        candidate.totalTokens > existing.totalTokens || (candidate.totalTokens == existing.totalTokens && candidate.timestamp >= existing.timestamp)
    }

    private func claudeJSONLDedupeKeys(from json: [String: Any], message: [String: Any]?) -> [String] {
        var keys: [String] = []
        if let messageID = stringValue(message?["id"] ?? json["message_id"] ?? json["messageId"]), !messageID.isEmpty {
            keys.append("message:\(messageID)")
        }
        if let requestID = stringValue(json["requestId"] ?? json["request_id"] ?? message?["requestId"] ?? message?["request_id"]), !requestID.isEmpty {
            keys.append("request:\(requestID)")
        }
        return keys
    }

    private func parseWindow(from dict: [String: Any]?, kind: LimitWindowKind, stale: Bool) -> LimitWindow? {
        guard let dict else { return nil }
        let used = intValue(dict["used_percentage"] ?? dict["used_percent"] ?? dict["percent"] ?? dict["usage_percent"] ?? dict["usedPercent"])
        let resetAt = dateValue(dict["resets_at"] ?? dict["reset_at"] ?? dict["resetAt"] ?? dict["resetsAt"] ?? dict["reset_at_time"] ?? dict["resetAtTime"])
        guard used != nil || resetAt != nil else { return nil }
        return LimitWindow(kind: kind, usedPercent: used, resetAt: resetAt, confidence: stale ? .medium : .high)
    }

    private func defaultClaudeProjectRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true)
        ]
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            roots.append(URL(fileURLWithPath: configDir).appendingPathComponent("projects", isDirectory: true))
        }
        return roots
    }
}

// MARK: - Gemini Telemetry Adapter

public final class GeminiTelemetryAdapter: ProviderAdapter, Sendable {
    public let provider: Provider = .gemini
    private let overrideLogURL: URL?
    private let staleThreshold: TimeInterval

    public init(logURL: URL? = nil, staleThreshold: TimeInterval = 300) {
        self.overrideLogURL = logURL
        self.staleThreshold = staleThreshold
    }

    public func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        guard settings.geminiEnabled else {
            return ProviderSnapshot(provider: .gemini, confidence: .low, statusMessage: "Disabled")
        }

        let path = settings.geminiTelemetryLogPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let logURL = overrideLogURL ?? (path.isEmpty ? nil : URL(fileURLWithPath: expandTilde(path)))
        let bookmarkData = overrideLogURL == nil ? settings.geminiTelemetrySourceBookmarkData : nil
        guard let logURL, FileManager.default.fileExists(atPath: logURL.path) || bookmarkData != nil else {
            return ProviderSnapshot(provider: .gemini, confidence: .low, statusMessage: "Select telemetry.log or session folder")
        }

        let scopedAccess = TokenPilotSecurityScopedBookmarks.resolveIfAvailable(
            bookmarkData: bookmarkData,
            fallbackURL: logURL
        )
        defer { scopedAccess.stop() }
        let readableLogURL = scopedAccess.url

        do {
            let files = geminiInputFiles(from: readableLogURL)
            let events = try files.flatMap { file -> [UsageEvent] in
                let content = try tokenPilotBoundedTextContents(of: file)
                return parseEvents(from: content, fileURL: file)
            }

            guard !events.isEmpty else {
                return ProviderSnapshot(provider: .gemini, confidence: .low, dataSource: .unknown, statusMessage: "No Gemini token events yet")
            }

            let calendar = Calendar.current
            let now = Date()
            let todayEvents = events.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
            let startOfToday = calendar.startOfDay(for: now)
            let startOfLast7Days = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfToday
            let retainedStart = min(startOfLast7Days, startOfMonth)
            let retainedEvents = events.filter { $0.timestamp >= retainedStart }
            let todayTokens = todayEvents.reduce(0) { $0 + $1.totalTokens }
            let todayRequests = todayEvents.reduce(0) { $0 + $1.requestCount }
            let newestTimestamp = events.map(\.timestamp).max() ?? Date.distantPast
            let isStale = Date().timeIntervalSince(newestTimestamp) > staleThreshold
            let confidence: DataConfidence = isStale ? .medium : .high
            let model = events.reversed().first { $0.model?.isEmpty == false }?.model
            let dataSource: UsageDataSource = retainedEvents.allSatisfy { $0.dataSource == .officialTelemetry } ? .officialTelemetry : .localLog

            return ProviderSnapshot(
                provider: .gemini,
                updatedAt: newestTimestamp,
                dailyRequestsUsed: todayRequests,
                dailyRequestsLimit: settings.geminiDailyRequestCap,
                todayTokens: todayTokens,
                confidence: confidence,
                dataSource: dataSource,
                isStale: isStale,
                statusMessage: isStale ? "STALE · older than 5 minutes" : "Connected",
                model: model,
                events: retainedEvents
            )
        } catch {
            return ProviderSnapshot(provider: .gemini, confidence: .low, isStale: true, statusMessage: "Gemini data could not be read")
        }
    }

    private func geminiInputFiles(from url: URL) -> [URL] {
        if isDirectory(url) {
            return candidateFiles(in: [url], allowedExtensions: ["jsonl", "json", "log"], maxFiles: 120)
                .filter { file in
                    let name = file.lastPathComponent.lowercased()
                    let path = file.path.lowercased()
                    return name.hasPrefix("session-")
                        || name.contains("telemetry")
                        || name.hasSuffix(".log")
                        || path.contains("/chats/")
                        || name.hasSuffix(".jsonl")
                }
        }
        return [url]
    }

    private func parseEvents(from content: String, fileURL: URL) -> [UsageEvent] {
        let fallbackTimestamp = fileModificationDate(fileURL) ?? Date()
        if let data = content.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) {
            return parseGeminiJSONValue(root, fallbackTimestamp: fallbackTimestamp)
        }

        return content.components(separatedBy: .newlines).flatMap { line -> [UsageEvent] in
            guard let json = jsonObject(fromLine: line) else { return [] }
            return parseGeminiJSONDictionary(json, fallbackTimestamp: fallbackTimestamp)
        }
    }

    private func parseGeminiJSONValue(_ value: Any, fallbackTimestamp: Date) -> [UsageEvent] {
        if let dictionary = value as? [String: Any] {
            return parseGeminiJSONDictionary(dictionary, fallbackTimestamp: fallbackTimestamp)
        }
        if let array = value as? [Any] {
            return array.flatMap { parseGeminiJSONValue($0, fallbackTimestamp: fallbackTimestamp) }
        }
        return []
    }

    private func parseGeminiJSONDictionary(_ json: [String: Any], fallbackTimestamp: Date) -> [UsageEvent] {
        let effectiveFallback = timestampValue(from: json, candidates: [json]) ?? fallbackTimestamp
        var events: [UsageEvent] = []
        let messageEvents = (json["messages"] as? [Any])?.flatMap { parseGeminiJSONValue($0, fallbackTimestamp: effectiveFallback) } ?? []
        if let telemetry = parseTelemetryEvent(from: json) {
            events.append(telemetry)
        } else if messageEvents.isEmpty, let session = parseSessionTokenEvent(from: json, fallbackTimestamp: effectiveFallback) {
            events.append(session)
        }
        events.append(contentsOf: messageEvents)
        if messageEvents.isEmpty, let stats = dictionary(json["stats"]) {
            events.append(contentsOf: parseGeminiStatsEvents(from: stats, rootJSON: json, fallbackTimestamp: effectiveFallback))
        }
        return events
    }

    private func parseGeminiStatsEvents(from stats: [String: Any], rootJSON: [String: Any], fallbackTimestamp: Date) -> [UsageEvent] {
        var events: [UsageEvent] = []
        if let models = dictionary(stats["models"]), !models.isEmpty {
            for (modelName, rawModelValue) in models {
                let modelDictionary = dictionary(rawModelValue) ?? [:]
                let tokens = dictionary(modelDictionary["tokens"]) ?? modelDictionary
                var modelCandidate = modelDictionary
                modelCandidate["model"] = modelName
                if let event = makeGeminiEvent(
                    from: [tokens, modelCandidate, stats, rootJSON],
                    rootJSON: rootJSON,
                    fallbackTimestamp: fallbackTimestamp,
                    source: "gemini-session-log",
                    dataSource: .localLog
                ) {
                    events.append(event)
                }
            }
            return events
        }
        if let tokens = dictionary(stats["tokens"]),
           let event = makeGeminiEvent(
                from: [tokens, stats, rootJSON],
                rootJSON: rootJSON,
                fallbackTimestamp: fallbackTimestamp,
                source: "gemini-session-log",
                dataSource: .localLog
           ) {
            events.append(event)
        }
        return events
    }

    private func parseTelemetryEvent(from json: [String: Any]) -> UsageEvent? {
        let eventName = stringValue(json["name"] ?? json["event"] ?? value(json, path: "attributes.event.name") ?? value(json, path: "metadata.event.name"))
        guard eventName == "gemini_cli.api_response" || containsString("gemini_cli.api_response", in: json) else { return nil }

        let candidates = [
            dictionary(json["payload"]),
            dictionary(json["attributes"]),
            dictionary(json["metadata"]),
            dictionary(value(json, path: "resource.attributes")),
            dictionary(value(json, path: "body")),
            json
        ].compactMap { $0 }

        return makeGeminiEvent(from: candidates, rootJSON: json, source: "gemini-telemetry", dataSource: .officialTelemetry)
    }

    private func parseSessionTokenEvent(from json: [String: Any], fallbackTimestamp: Date) -> UsageEvent? {
        let tokenCandidate = dictionary(json["tokens"])
            ?? dictionary(json["token_usage"])
            ?? dictionary(json["usage"])
            ?? dictionary(value(json, path: "metadata.tokens"))
            ?? dictionary(value(json, path: "payload.tokens"))
        guard let tokenCandidate else { return nil }
        let candidates = [tokenCandidate, dictionary(json["metadata"]), dictionary(json["payload"]), json].compactMap { $0 }
        return makeGeminiEvent(from: candidates, rootJSON: json, fallbackTimestamp: fallbackTimestamp, source: "gemini-session-log", dataSource: .localLog)
    }

    private func makeGeminiEvent(
        from candidates: [[String: Any]],
        rootJSON: [String: Any],
        fallbackTimestamp: Date? = nil,
        source: String,
        dataSource: UsageDataSource
    ) -> UsageEvent? {
        func firstInt(_ keys: [String]) -> Int? {
            for candidate in candidates {
                for key in keys {
                    if let value = intValue(candidate[key]) { return value }
                }
            }
            return nil
        }

        func firstString(_ keys: [String]) -> String? {
            for candidate in candidates {
                for key in keys {
                    if let value = stringValue(candidate[key]), !value.isEmpty { return value }
                }
            }
            return nil
        }

        let total = firstInt(["total_token_count", "totalTokens", "total_tokens", "total"])
        var inputTokens = firstInt(["input_token_count", "input_tokens", "prompt_tokens", "prompt", "input"] ) ?? 0
        let outputTokens = firstInt(["output_token_count", "output_tokens", "completion_tokens", "candidate_tokens", "candidates_token_count", "candidates", "output"] ) ?? 0
        let cacheRead = firstInt(["cached_content_token_count", "cache_read_tokens", "cached_tokens", "cached", "cache"] ) ?? 0
        let reasoning = firstInt(["thoughts_token_count", "reasoning_tokens", "thought_tokens", "thoughts"] ) ?? 0
        let tool = firstInt(["tool_token_count", "tool_tokens", "tool"] ) ?? 0
        let componentTotal = inputTokens + outputTokens + cacheRead + reasoning + tool
        if componentTotal == 0, let total, total > 0 {
            inputTokens = total
        }

        guard inputTokens + outputTokens + cacheRead + reasoning + tool > 0 || (total ?? 0) > 0 else { return nil }

        let timestamp = timestampValue(from: rootJSON, candidates: candidates) ?? fallbackTimestamp ?? Date()
        let totalOverride: Int?
        if let total, total > 0, dataSource == .officialTelemetry || total >= componentTotal || componentTotal == 0 {
            totalOverride = total
        } else {
            totalOverride = nil
        }
        return UsageEvent(
            provider: .gemini,
            model: firstString(["model", "model_name"]),
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            toolTokens: tool,
            requestCount: 1,
            source: source,
            dataSource: dataSource,
            authType: firstString(["auth_type", "authType"]),
            durationMS: firstInt(["duration_ms", "durationMS"]),
            totalTokensOverride: totalOverride
        )
    }

    private func timestampValue(from json: [String: Any], candidates: [[String: Any]]) -> Date? {
        if let direct = dateValue(json["timestamp"] ?? json["time"] ?? json["observedTimestamp"] ?? json["startTime"] ?? json["start_time"] ?? json["createdAt"] ?? json["created_at"]) { return direct }
        for candidate in candidates {
            if let date = dateValue(candidate["timestamp"] ?? candidate["time"] ?? candidate["observedTimestamp"] ?? candidate["startTime"] ?? candidate["start_time"] ?? candidate["createdAt"] ?? candidate["created_at"]) { return date }
            if let nanos = int64Value(candidate["time_unix_nano"] ?? candidate["timeUnixNano"] ?? candidate["observed_time_unix_nano"]), nanos > 0 {
                return Date(timeIntervalSince1970: TimeInterval(nanos) / 1_000_000_000)
            }
        }
        return nil
    }
}

// MARK: - Codex Limit Hints Adapter

public final class CodexWebUsageAdapter: ProviderAdapter, @unchecked Sendable {
    public let provider: Provider = .codex
    private let authFileURL: URL?
    private let httpClient: any CodexWebUsageHTTPClient
    private let appServerClient: (any CodexAppServerRateLimitClient)?
    private let endpointURL: URL
    private let allowLegacyDirectHTTP: Bool
    private let environment: [String: String]
    private let currentHomeDirectory: URL
    private let now: @Sendable () -> Date

    public init(
        authFileURL: URL? = nil,
        httpClient: any CodexWebUsageHTTPClient = URLSessionCodexWebUsageHTTPClient(),
        appServerClient: (any CodexAppServerRateLimitClient)? = CodexAppServerRateLimitProcessClient(),
        endpointURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage") ?? URL(fileURLWithPath: "/dev/null"),
        // Legacy compatibility/test-only path. Keep false for production so TokenPilot never
        // reads Codex auth files or calls credentialed web endpoints by default.
        allowLegacyDirectHTTP: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authFileURL = authFileURL
        self.httpClient = httpClient
        self.appServerClient = appServerClient
        self.endpointURL = endpointURL
        self.allowLegacyDirectHTTP = allowLegacyDirectHTTP
        self.environment = environment
        self.currentHomeDirectory = currentHomeDirectory.standardizedFileURL
        self.now = now
    }

    public func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        guard settings.codexEnabled else {
            return ProviderSnapshot(provider: .codex, confidence: .low, statusMessage: "Disabled")
        }
        guard settings.codexManual.webConnectorEnabled else {
            return ProviderSnapshot(
                provider: .codex,
                confidence: .low,
                dataSource: .unknown,
                statusMessage: "Codex limit hints connector off"
            )
        }

        if let appServerClient {
            do {
                let data = try await appServerClient.readRateLimits()
                return codexAppServerSnapshot(from: data)
            } catch {
                return codexWebErrorSnapshot("Codex app-server limit hints unavailable")
            }
        }

        guard allowLegacyDirectHTTP else {
            return codexWebErrorSnapshot("Codex app-server limit hints unavailable · direct HTTP disabled")
        }

        return await directHTTPSnapshot()
    }

    private func directHTTPSnapshot() async -> ProviderSnapshot {
        codexWebErrorSnapshot("Codex app-server limit hints unavailable · direct HTTP disabled")
    }

    private func codexAppServerSnapshot(from data: Data) -> ProviderSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return codexWebErrorSnapshot("Codex app-server limit hints parse error")
        }

        if let error = dictionary(object["error"]) {
            let rawMessage = stringValue(error["message"]) ?? "request failed"
            let lowerMessage = rawMessage.lowercased()
            if lowerMessage.contains("authentication required") || lowerMessage.contains("not_logged_in") || lowerMessage.contains("not logged in") {
                return codexWebErrorSnapshot("Codex app-server auth required · run codex login")
            }
            return codexWebErrorSnapshot("Codex app-server limit hints error · \(redactedCodexStatusDetail(rawMessage))")
        }

        let payload = dictionary(object["result"]) ?? dictionary(object["params"]) ?? object
        let windows = codexAppServerRateLimitWindows(from: payload)
        guard windows.fiveHour != nil || windows.weekly != nil else {
            return codexWebErrorSnapshot("Codex app-server limit hints rate limits unavailable")
        }

        let planKeys = ["planType", "plan_type", "plan", "chatgptPlanType", "account_plan"]
        let plan = firstString(in: payload, keys: planKeys)
            ?? firstString(in: dictionary(payload["rateLimits"]) ?? [:], keys: planKeys)
            ?? firstStringRecursively(in: payload, keys: planKeys)
        return ProviderSnapshot(
            provider: .codex,
            updatedAt: now(),
            fiveHour: windows.fiveHour,
            weekly: windows.weekly,
            confidence: .high,
            dataSource: .webUsage,
            isExperimental: true,
            isStale: false,
            statusMessage: "UNOFFICIAL · Codex app-server limit hints · token handled by Codex CLI",
            model: plan,
            events: []
        )
    }

    private struct CodexAppServerWindowEntry {
        var path: String
        var dictionary: [String: Any]
    }

    private func codexAppServerRateLimitWindows(from object: [String: Any]) -> (fiveHour: LimitWindow?, weekly: LimitWindow?) {
        let containers = [
            dictionary(object["rateLimits"]),
            dictionary(object["rate_limits"]),
            dictionary(object["rate_limit"]),
            dictionary(object["rateLimitsByLimitId"]),
            dictionary(object["limits"]),
            dictionary(object["windows"]),
            dictionary(object["quota"]),
            dictionary(object["quotas"]),
            dictionary(value(object, path: "account.rateLimits")),
            dictionary(value(object, path: "account.rate_limits")),
            dictionary(value(object, path: "status.rateLimits")),
            dictionary(value(object, path: "result.rateLimits")),
            dictionary(value(object, path: "result.rate_limits")),
            dictionary(value(object, path: "params.rateLimits")),
            dictionary(value(object, path: "params.rate_limits")),
            object
        ].compactMap { $0 }

        for container in containers {
            let fiveHourDictionary = firstDictionary(in: container, keys: [
                "primary", "primary_window", "primaryWindow",
                "five_hour", "fiveHour", "fivehour", "5h",
                "short", "session", "session_window", "sessionWindow",
                "hourly", "hour_5", "fiveHourWindow"
            ])
            let weeklyDictionary = firstDictionary(in: container, keys: [
                "secondary", "secondary_window", "secondaryWindow",
                "weekly", "week", "seven_day", "sevenDay", "7d",
                "long", "week_window", "weekWindow",
                "daily", "daily_window", "dailyWindow"
            ])
            let fiveHour = codexWebWindow(from: fiveHourDictionary, kind: .fiveHour, confidence: .high)
            let weekly = codexWebWindow(from: weeklyDictionary, kind: .weekly, confidence: .high)
            if fiveHour != nil || weekly != nil {
                return (fiveHour, weekly)
            }
        }

        var entries: [CodexAppServerWindowEntry] = []
        for container in containers {
            collectCodexAppServerWindowEntries(from: container, path: "", entries: &entries)
        }

        var fiveHour = bestCodexAppServerWindow(from: entries, kind: .fiveHour)
            .flatMap { codexWebWindow(from: $0.dictionary, kind: .fiveHour, confidence: .high) }
        var weekly = bestCodexAppServerWindow(from: entries, kind: .weekly)
            .flatMap { codexWebWindow(from: $0.dictionary, kind: .weekly, confidence: .high) }

        let entriesWithMinutes = entries.compactMap { entry -> (Int, CodexAppServerWindowEntry)? in
            guard let minutes = intValue(entry.dictionary["window_minutes"] ?? entry.dictionary["windowMinutes"] ?? entry.dictionary["limit_window_minutes"]) else { return nil }
            return (minutes, entry)
        }.sorted { $0.0 < $1.0 }
        if fiveHour == nil, let entry = entriesWithMinutes.first(where: { $0.0 <= 6 * 60 })?.1 {
            fiveHour = codexWebWindow(from: entry.dictionary, kind: .fiveHour, confidence: .high)
        }
        if weekly == nil, let entry = entriesWithMinutes.last(where: { $0.0 >= 24 * 60 })?.1 {
            weekly = codexWebWindow(from: entry.dictionary, kind: .weekly, confidence: .high)
        }
        if fiveHour == nil, entries.count == 1 {
            fiveHour = codexWebWindow(from: entries[0].dictionary, kind: .fiveHour, confidence: .high)
        }
        if weekly == nil, entries.count >= 2 {
            weekly = codexWebWindow(from: entries[entries.count - 1].dictionary, kind: .weekly, confidence: .high)
        }
        return (fiveHour, weekly)
    }

    private func collectCodexAppServerWindowEntries(from value: Any?, path: String, entries: inout [CodexAppServerWindowEntry]) {
        if let dictionary = dictionary(value) {
            let keys = Set(dictionary.keys.map { $0.lowercased() })
            let hasWindowFields = !keys.intersection([
                "used_percent", "used_percentage", "usedpercent", "used",
                "remaining_percent", "remaining_percentage", "remainingpercent", "remaining",
                "window_minutes", "windowminutes", "limit_window_minutes",
                "resets_at", "reset_at", "resetat", "reset_after_seconds",
                "used_requests", "usedrequests", "max_requests", "maxrequests",
                "used_tokens", "usedtokens", "max_tokens", "maxtokens",
                "request_count", "requestcount", "consumed", "consumed_requests",
                "current_usage", "used_count", "current"
            ]).isEmpty
            if hasWindowFields {
                entries.append(CodexAppServerWindowEntry(path: path, dictionary: dictionary))
            }
            for (key, child) in dictionary {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                collectCodexAppServerWindowEntries(from: child, path: childPath, entries: &entries)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collectCodexAppServerWindowEntries(from: child, path: "\(path)[\(index)]", entries: &entries)
            }
        }
    }

    private func bestCodexAppServerWindow(from entries: [CodexAppServerWindowEntry], kind: LimitWindowKind) -> CodexAppServerWindowEntry? {
        entries
            .map { entry -> (score: Int, entry: CodexAppServerWindowEntry) in
                let path = entry.path.lowercased()
                let minutes = intValue(entry.dictionary["window_minutes"] ?? entry.dictionary["windowMinutes"] ?? entry.dictionary["limit_window_minutes"])
                var score = 0
                switch kind {
                case .fiveHour:
                    if ["primary", "5h", "five", "short", "session"].contains(where: { path.contains($0) }) { score += 100 }
                    if let minutes, minutes <= 6 * 60 { score += 50 }
                case .weekly:
                    if ["secondary", "week", "weekly", "7d", "seven", "long"].contains(where: { path.contains($0) }) { score += 100 }
                    if let minutes, minutes >= 24 * 60 { score += 50 }
                case .dailyRequests:
                    if path.contains("daily") { score += 100 }
                }
                return (score, entry)
            }
            .filter { $0.score > 0 }
            .max { $0.score < $1.score }?
            .entry
    }

    private func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private func firstStringRecursively(in object: Any, keys: [String]) -> String? {
        let normalizedKeys = Set(keys.map { $0.lowercased() })
        if let dictionary = dictionary(object) {
            for (key, value) in dictionary where normalizedKeys.contains(key.lowercased()) {
                if let value = stringValue(value), !value.isEmpty { return value }
            }
            for value in dictionary.values {
                if let nested = firstStringRecursively(in: value, keys: keys) {
                    return nested
                }
            }
            return nil
        }
        if let array = object as? [Any] {
            for value in array {
                if let nested = firstStringRecursively(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func redactedCodexStatusDetail(_ message: String) -> String {
        var redacted = message
        let patterns = [
            #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(access[_-]?token|refresh[_-]?token|api[_-]?key|secret|password)\s*[:=]\s*[^\s,;]+"#,
            #"[A-Za-z0-9_-]{32,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,
            #"[A-Za-z0-9_~+/=-]{48,}"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = regex.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: "[REDACTED]")
        }
        return redacted
    }

    private func codexWebWindow(from value: Any?, kind: LimitWindowKind, confidence: DataConfidence) -> LimitWindow? {
        guard let dictionary = dictionary(value) else { return nil }
        let usedValue = codexWebPercentValue(
            dictionary["used_percent"]
                ?? dictionary["used_percentage"]
                ?? dictionary["usedPercent"]
                ?? dictionary["usedpercent"]
                ?? dictionary["percent"]
                ?? dictionary["usage_percent"]
                ?? dictionary["usagePercent"]
                ?? dictionary["consumed_percent"]
                ?? dictionary["consumedPercent"]
        )
        let remainingValue = codexWebPercentValue(
            dictionary["remaining_percent"]
                ?? dictionary["remaining_percentage"]
                ?? dictionary["remainingPercent"]
                ?? dictionary["remainingpercent"]
                ?? dictionary["remaining"]
        )
        let usedFromRawCounts = codexWebUsedPercent(
            dictionary: dictionary,
            usedKeys: [
                "used",
                "used_requests",
                "usedRequests",
                "used_tokens",
                "usedTokens",
                "requests_used",
                "requestsUsed",
                "request_count",
                "requestCount",
                "consumed",
                "consumed_requests",
                "consumedTokens",
                "current_usage",
                "currentUsage",
                "used_count",
                "usedCount",
                "current",
                "input_tokens",
                "inputTokens",
                "prompt_tokens",
                "promptTokens"
            ],
            limitKeys: [
                "limit",
                "max",
                "max_requests",
                "maxRequests",
                "max_tokens",
                "maxTokens",
                "request_limit",
                "requestLimit",
                "limit_requests",
                "limitRequests",
                "capacity",
                "quota",
                "total",
                "total_requests",
                "totalRequests",
                "total_tokens",
                "totalTokens",
                "max_input_tokens",
                "maxInputTokens"
            ]
        )
        let used = usedValue
            ?? remainingValue.map { min(max(100 - $0, 0), 100) }
            ?? usedFromRawCounts
        let resetAt = dateValue(dictionary["reset_at"] ?? dictionary["resets_at"] ?? dictionary["resetAt"] ?? dictionary["resetsAt"] ?? dictionary["reset_at_time"] ?? dictionary["resetAtTime"])
            ?? intValue(dictionary["reset_after_seconds"] ?? dictionary["resetAfterSeconds"]).map { now().addingTimeInterval(TimeInterval(max($0, 0))) }
        if let resetAt, resetAt <= now() {
            return nil
        }
        guard used != nil || resetAt != nil else { return nil }
        return LimitWindow(kind: kind, usedPercent: used, resetAt: resetAt, confidence: confidence)
    }

    private func codexWebUsedPercent(dictionary: [String: Any], usedKeys: [String], limitKeys: [String]) -> Int? {
        guard let used = codexWebRawValue(from: dictionary, keys: usedKeys),
              let limit = codexWebRawValue(from: dictionary, keys: limitKeys),
              limit > 0 else {
            return nil
        }
        return min(max(Int((used / limit * 100).rounded()), 0), 100)
    }

    private func codexWebRawValue(from dictionary: [String: Any], keys: [String]) -> Double? {
        let value: Any = dictionary
        return codexWebRawValue(from: value, keys: keys)
    }

    private func codexWebRawValue(from object: Any, keys: [String]) -> Double? {
        if let dictionary = object as? [String: Any] {
            let keySet = Set(keys.map { $0.lowercased() })
            for (key, value) in dictionary {
                if keySet.contains(key.lowercased()), let numeric = codexWebNumericValue(value) {
                    return numeric
                }
            }
            for value in dictionary.values {
                if let nested = codexWebRawValue(from: value, keys: keys) {
                    return nested
                }
            }
            return nil
        }
        if let array = object as? [Any] {
            for value in array {
                if let nested = codexWebRawValue(from: value, keys: keys) {
                    return nested
                }
            }
            return nil
        }
        return nil
    }

    private func codexWebNumericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let float = value as? Float { return Double(float) }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: ""))
        }
        return nil
    }

    private func codexWebPercentValue(_ value: Any?) -> Int? {
        let raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let double = value as? Double {
            raw = double
        } else if let int = value as? Int {
            raw = Double(int)
        } else if let string = value as? String {
            raw = Double(string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: ""))
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let percent = raw > 0 && raw <= 1 ? raw * 100 : raw
        return min(max(Int(percent.rounded()), 0), 100)
    }

    private func codexWebErrorSnapshot(_ message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .codex,
            confidence: .low,
            dataSource: .webUsage,
            isExperimental: true,
            statusMessage: message
        )
    }
}

// MARK: - Codex Local Session Adapter

public final class CodexLocalSessionAdapter: ProviderAdapter, Sendable {
    public let provider: Provider = .codex
    private let sessionRoots: [URL]?
    private let manualFallback: CodexManualAdapter
    private let webUsageAdapter: any ProviderAdapter
    private let environment: [String: String]
    private let currentHomeDirectory: URL
    private let additionalHomeDirectories: [URL]?
    private let maxSessionFiles: Int
    private let largeFileFullScanLimitBytes: UInt64
    private let largeFileTailBytes: UInt64

    public init(sessionRoots: [URL]? = nil, manualFallback: CodexManualAdapter = CodexManualAdapter(), webUsageAdapter: any ProviderAdapter = CodexWebUsageAdapter(appServerClient: CodexAppServerRateLimitProcessClient(), allowLegacyDirectHTTP: false)) {
        self.sessionRoots = sessionRoots
        self.manualFallback = manualFallback
        self.webUsageAdapter = webUsageAdapter
        self.environment = ProcessInfo.processInfo.environment
        self.currentHomeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.additionalHomeDirectories = nil
        self.maxSessionFiles = 8
        self.largeFileFullScanLimitBytes = 4 * 1_024 * 1_024
        self.largeFileTailBytes = 4 * 1_024 * 1_024
    }

    public init(
        sessionRoots: [URL]? = nil,
        manualFallback: CodexManualAdapter = CodexManualAdapter(),
        webUsageAdapter: any ProviderAdapter = CodexWebUsageAdapter(appServerClient: CodexAppServerRateLimitProcessClient(), allowLegacyDirectHTTP: false),
        environment: [String: String],
        currentHomeDirectory: URL,
        additionalHomeDirectories: [URL]? = nil,
        maxSessionFiles: Int = 8,
        largeFileFullScanLimitBytes: UInt64 = 4 * 1_024 * 1_024,
        largeFileTailBytes: UInt64 = 4 * 1_024 * 1_024
    ) {
        self.sessionRoots = sessionRoots
        self.manualFallback = manualFallback
        self.webUsageAdapter = webUsageAdapter
        self.environment = environment
        self.currentHomeDirectory = currentHomeDirectory
        self.additionalHomeDirectories = additionalHomeDirectories
        self.maxSessionFiles = max(maxSessionFiles, 1)
        self.largeFileFullScanLimitBytes = max(largeFileFullScanLimitBytes, 64 * 1_024)
        self.largeFileTailBytes = max(largeFileTailBytes, 64 * 1_024)
    }

    public func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        guard settings.codexEnabled else {
            return ProviderSnapshot(provider: .codex, confidence: .low, statusMessage: "Disabled")
        }

        if settings.codexManual.webConnectorEnabled {
            return await webUsageAdapter.snapshot(settings: settings)
        }

        if settings.codexManual.webSnapshotEnabled {
            return await manualFallback.snapshot(settings: settings)
        }

        let roots = sessionRoots ?? defaultCodexSessionRoots()
        let allFiles = candidateFiles(in: roots, allowedExtensions: ["jsonl"], maxFiles: maxSessionFiles * 3)
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let files = relevantCodexSessionFiles(from: allFiles, now: now)
        guard !files.isEmpty else {
            return await manualFallback.snapshot(settings: settings)
        }

        var events: [UsageEvent] = []
        var emittedGlobalEventKeys = Set<String>()
        var latestRateLimits: CodexRateLimitSnapshot?
        var latestModel: String?
        for file in files where !isForbiddenCredentialPath(file) {
            let parsed = parseSessionFile(file, eventCutoff: todayStart, now: now)
            for parsedEvent in parsed.usageEvents {
                guard emittedGlobalEventKeys.insert(parsedEvent.dedupeKey).inserted else { continue }
                events.append(parsedEvent.event)
            }
            if latestModel == nil, let model = parsed.latestModel {
                latestModel = model
            }
            if let candidate = parsed.latestRateLimits,
               latestRateLimits == nil || candidate.timestamp > latestRateLimits!.timestamp {
                latestRateLimits = candidate
            }
        }

        let manual = await manualFallback.snapshot(settings: settings)
        guard !events.isEmpty || latestRateLimits?.fiveHour != nil || latestRateLimits?.weekly != nil else {
            return manual
        }

        events.sort { $0.timestamp < $1.timestamp }
        let newestEvent = events.map(\.timestamp).max()
        let newest = [newestEvent, latestRateLimits?.timestamp].compactMap { $0 }.max() ?? now
        let model = events.reversed().first { $0.model?.isEmpty == false }?.model ?? latestModel ?? manual.model

        return ProviderSnapshot(
            provider: .codex,
            updatedAt: newest,
            fiveHour: latestRateLimits?.fiveHour ?? manual.fiveHour,
            weekly: latestRateLimits?.weekly ?? manual.weekly,
            todayTokens: events.reduce(0) { $0 + $1.totalTokens },
            confidence: .medium,
            dataSource: .localLog,
            isExperimental: true,
            isStale: false,
            statusMessage: "EXPERIMENTAL · local Codex log · not web quota",
            model: model,
            events: events
        )
    }

    private func codexLineDedupeKey(json: [String: Any], payload: [String: Any]?, info: [String: Any], rawLine: String) -> String {
        if let id = stringValue(json["id"] ?? json["event_id"] ?? json["eventId"] ?? payload?["id"] ?? payload?["event_id"] ?? info["id"] ?? info["event_id"]), !id.isEmpty {
            return "id:\(id)"
        }
        return "line:\(stableLineFingerprint(rawLine))"
    }

    private func stableLineFingerprint(_ rawLine: String) -> String {
        let seed: UInt64 = 1_461_168_601_842_738_7903
        let prime: UInt64 = 1_099_511_628_211
        var hash = seed
        for byte in rawLine.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    private func relevantCodexSessionFiles(from files: [URL], now: Date) -> [URL] {
        let cutoff = now.addingTimeInterval(-45 * 24 * 60 * 60)
        return files
            .filter { (fileModificationDate($0) ?? .distantPast) >= cutoff }
            .prefix(maxSessionFiles)
            .map { $0 }
    }

    private func parseSessionFile(_ file: URL, eventCutoff: Date, now: Date) -> CodexSessionParseResult {
        let fallbackRateLimitTimestamp = fileModificationDate(file)
        var result = CodexSessionParseResult()
        var currentModel: String?
        var previousTotalUsage: CodexTokenUsage?
        var emittedKeys = Set<String>()

        forEachRelevantSessionLine(in: file) { line in
            guard let json = jsonObject(fromLine: line) else { return }
            let payload = dictionary(json["payload"])
            let eventType = stringValue(json["type"])
            let payloadType = stringValue(payload?["type"])
            if eventType == "turn_context" || payloadType == "turn_context" {
                currentModel = codexModel(from: [payload, dictionary(json["turn_context"]), json]) ?? currentModel
                if let currentModel { result.latestModel = currentModel }
                return
            }

            let isNestedTokenCount = eventType == "event_msg" && payloadType == "token_count"
            let isTopLevelTokenCount = eventType == "token_count"
            guard isNestedTokenCount || isTopLevelTokenCount else { return }
            guard let info = dictionary(payload?["info"]) ?? dictionary(json["info"]) ?? dictionary(json["usage"]) else { return }

            let eventTimestamp = dateValue(json["timestamp"] ?? payload?["timestamp"] ?? info["timestamp"])
            if let rateLimitJSON = dictionary(info["rate_limits"]) ?? dictionary(payload?["rate_limits"]) ?? dictionary(json["rate_limits"]),
               let rateTimestamp = eventTimestamp ?? fallbackRateLimitTimestamp,
               let rateLimits = parseCodexRateLimits(rateLimitJSON, timestamp: rateTimestamp, now: now),
               result.latestRateLimits == nil || rateLimits.timestamp > result.latestRateLimits!.timestamp {
                result.latestRateLimits = rateLimits
            }

            let model = codexModel(from: [info, payload, json]) ?? currentModel
            let usage: CodexTokenUsage?
            if let last = dictionary(info["last_token_usage"]) {
                usage = CodexTokenUsage(last)
            } else if let total = dictionary(info["total_token_usage"]) {
                let current = CodexTokenUsage(total)
                if let previous = previousTotalUsage {
                    usage = current.delta(from: previous)
                } else {
                    usage = nil
                }
                previousTotalUsage = current
            } else {
                usage = nil
            }

            guard let timestamp = eventTimestamp,
                  timestamp >= eventCutoff,
                  timestamp <= now.addingTimeInterval(60),
                  let usage,
                  usage.totalTokens > 0 else { return }
            let key = codexLineDedupeKey(json: json, payload: payload, info: info, rawLine: line)
            guard emittedKeys.insert(key).inserted else { return }

            let event = UsageEvent(
                provider: .codex,
                model: model,
                timestamp: timestamp,
                inputTokens: usage.input,
                outputTokens: usage.output,
                cacheReadTokens: usage.cached,
                reasoningTokens: usage.reasoning,
                requestCount: 1,
                source: "codex-session-jsonl",
                dataSource: .localLog,
                isEstimated: true,
                isExperimental: true,
                totalTokensOverride: usage.total
            )
            result.usageEvents.append(CodexParsedUsageEvent(dedupeKey: key, event: event))
            result.latestModel = model
        }

        return result
    }

    private func forEachRelevantSessionLine(in file: URL, _ handleLine: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let size = fileByteSize(file)
        let startOffset = size > largeFileFullScanLimitBytes ? size > largeFileTailBytes ? size - largeFileTailBytes : 0 : 0
        var buffer = Data()
        var dropFirstPartialLine = false

        if startOffset > 0 {
            if startOffset < size {
                try? handle.seek(toOffset: max(0, startOffset - 1))
                if let previous = try? handle.read(upToCount: 1), let lastByte = previous.first {
                    dropFirstPartialLine = lastByte != 0x0A
                }
                try? handle.seek(toOffset: startOffset)
            }
        }

        let newline = Data([0x0A])
        let chunkSize = 64 * 1_024
        let maxLineBytes = 2 * 1_024 * 1_024

        func processLineData(_ lineData: Data) {
            if dropFirstPartialLine {
                dropFirstPartialLine = false
                return
            }
            guard lineData.count <= maxLineBytes, shouldDecodeCodexSessionLine(lineData) else { return }
            if let line = String(data: lineData, encoding: .utf8) {
                handleLine(line)
            }
        }

        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: chunkSize), !read.isEmpty else { break }
                chunk = read
            } catch {
                break
            }
            buffer.append(chunk)
            while let range = buffer.firstRange(of: newline) {
                let lineData = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                processLineData(lineData)
            }
            if buffer.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: true)
                dropFirstPartialLine = true
            }
        }

        if !buffer.isEmpty {
            processLineData(buffer)
        }
    }

    private func shouldDecodeCodexSessionLine(_ data: Data) -> Bool {
        data.range(of: Data(#""token_count""#.utf8)) != nil || data.range(of: Data(#""turn_context""#.utf8)) != nil
    }

    private func fileByteSize(_ file: URL) -> UInt64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    private func codexModel(from dictionaries: [[String: Any]?]) -> String? {
        for dictionary in dictionaries.compactMap({ $0 }) {
            if let model = stringValue(dictionary["model"] ?? dictionary["model_slug"] ?? dictionary["modelName"]), !model.isEmpty {
                return model
            }
            if let nested = dictionary["turn_context"] as? [String: Any],
               let model = stringValue(nested["model"]), !model.isEmpty {
                return model
            }
            if let nested = dictionary["context"] as? [String: Any],
               let model = stringValue(nested["model"]), !model.isEmpty {
                return model
            }
        }
        return nil
    }

    private func parseCodexRateLimits(_ dictionary: [String: Any], timestamp: Date, now: Date = Date()) -> CodexRateLimitSnapshot? {
        let primary = firstDictionary(in: dictionary, keys: [
            "primary", "primary_window", "primaryWindow",
            "five_hour_limit", "five_hour", "fiveHour", "fivehour", "5h",
            "short", "session", "session_window", "sessionWindow",
            "hourly", "hour_5", "fiveHourWindow"
        ])
        let secondary = firstDictionary(in: dictionary, keys: [
            "secondary", "secondary_window", "secondaryWindow",
            "weekly_limit", "weekly", "week", "seven_day", "sevenDay", "7d",
            "long", "week_window", "weekWindow",
            "daily", "daily_window", "dailyWindow"
        ])
        let fiveHour = codexLimitWindow(from: primary, fallbackKind: .fiveHour, now: now)
        let weekly = codexLimitWindow(from: secondary, fallbackKind: .weekly, now: now)
        guard fiveHour != nil || weekly != nil else { return nil }
        return CodexRateLimitSnapshot(timestamp: timestamp, fiveHour: fiveHour, weekly: weekly)
    }

    private func codexLimitWindow(from dictionary: [String: Any]?, fallbackKind: LimitWindowKind, now: Date = Date()) -> LimitWindow? {
        guard let dictionary else { return nil }
        let kind: LimitWindowKind
        if let minutes = intValue(dictionary["window_minutes"] ?? dictionary["windowMinutes"] ?? dictionary["limit_window_minutes"]) {
            kind = minutes >= 7 * 24 * 60 ? .weekly : .fiveHour
        } else {
            kind = fallbackKind
        }
        let usedValue = codexSessionPercentValue(
            dictionary["used_percent"]
                ?? dictionary["used_percentage"]
                ?? dictionary["usedPercent"]
                ?? dictionary["usedpercent"]
                ?? dictionary["percent"]
                ?? dictionary["usage_percent"]
                ?? dictionary["usagePercent"]
                ?? dictionary["consumed_percent"]
                ?? dictionary["consumedPercent"]
        )
        let remainingValue = codexSessionPercentValue(
            dictionary["remaining_percent"]
                ?? dictionary["remaining_percentage"]
                ?? dictionary["remainingPercent"]
                ?? dictionary["remainingpercent"]
                ?? dictionary["remaining"]
        )
        let usedFromRawCounts = codexSessionUsedPercent(
            dictionary: dictionary,
            usedKeys: [
                "used",
                "used_requests",
                "usedRequests",
                "used_tokens",
                "usedTokens",
                "requests_used",
                "requestsUsed",
                "request_count",
                "requestCount",
                "consumed",
                "consumed_requests",
                "consumedTokens",
                "current_usage",
                "currentUsage",
                "used_count",
                "usedCount",
                "current",
                "input_tokens",
                "inputTokens",
                "prompt_tokens",
                "promptTokens"
            ],
            limitKeys: [
                "limit",
                "max",
                "max_requests",
                "maxRequests",
                "max_tokens",
                "maxTokens",
                "request_limit",
                "requestLimit",
                "limit_requests",
                "limitRequests",
                "capacity",
                "quota",
                "total",
                "total_requests",
                "totalRequests",
                "total_tokens",
                "totalTokens",
                "max_input_tokens",
                "maxInputTokens"
            ]
        )
        let used = usedValue
            ?? remainingValue.map { min(max(100 - $0, 0), 100) }
            ?? usedFromRawCounts
        let resetAt = dateValue(
            dictionary["resets_at"]
                ?? dictionary["reset_at"]
                ?? dictionary["resetAt"]
                ?? dictionary["resetsAt"]
                ?? dictionary["reset_at_time"]
                ?? dictionary["resetAtTime"]
        ) ?? intValue(dictionary["reset_after_seconds"] ?? dictionary["resetAfterSeconds"])
            .map { now.addingTimeInterval(TimeInterval(max($0, 0))) }
        if let resetAt, resetAt <= now {
            return nil
        }
        guard used != nil || resetAt != nil else { return nil }
        return LimitWindow(kind: kind, usedPercent: used, resetAt: resetAt, confidence: .medium)
    }

    private func codexSessionUsedPercent(dictionary: [String: Any], usedKeys: [String], limitKeys: [String]) -> Int? {
        guard let used = codexSessionRawValue(from: dictionary, keys: usedKeys),
              let limit = codexSessionRawValue(from: dictionary, keys: limitKeys),
              limit > 0 else {
            return nil
        }
        return min(max(Int((used / limit * 100).rounded()), 0), 100)
    }

    private func codexSessionRawValue(from dictionary: [String: Any], keys: [String]) -> Double? {
        let keySet = Set(keys.map { $0.lowercased() })
        for (key, value) in dictionary {
            if keySet.contains(key.lowercased()), let numeric = codexSessionNumericValue(value) {
                return numeric
            }
        }
        for value in dictionary.values {
            if let nestedDictionary = value as? [String: Any],
               let nested = codexSessionRawValue(from: nestedDictionary, keys: keys) {
                return nested
            }
            if let array = value as? [Any] {
                for element in array {
                    guard let nestedDictionary = element as? [String: Any] else { continue }
                    if let nested = codexSessionRawValue(from: nestedDictionary, keys: keys) {
                        return nested
                    }
                }
            }
        }
        return nil
    }

    private func codexSessionPercentValue(_ value: Any?) -> Int? {
        guard let raw = value.flatMap(codexSessionNumericValue) else { return nil }
        let percent = raw > 0 && raw <= 1 ? raw * 100 : raw
        return min(max(Int(percent.rounded()), 0), 100)
    }

    private func codexSessionNumericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let float = value as? Float { return Double(float) }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: ""))
        }
        return nil
    }

    private func defaultCodexSessionRoots() -> [URL] {
        DefaultPathResolver(
            environment: environment,
            currentHomeDirectory: currentHomeDirectory,
            additionalHomeDirectories: additionalHomeDirectories
        )
        .resolveDefaultPaths(for: .codex)
        .filter { ["sessions", "archived_sessions"].contains($0.kind) }
        .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }
}

private struct CodexSessionParseResult {
    var usageEvents: [CodexParsedUsageEvent] = []
    var latestRateLimits: CodexRateLimitSnapshot?
    var latestModel: String?
}

private struct CodexParsedUsageEvent {
    var dedupeKey: String
    var event: UsageEvent
}

private struct CodexRateLimitSnapshot {
    var timestamp: Date
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?
}

private struct CodexTokenUsage: Equatable {
    var input: Int
    var output: Int
    var cached: Int
    var reasoning: Int
    var total: Int?

    init(_ dictionary: [String: Any]) {
        input = intValue(dictionary["input_tokens"] ?? dictionary["inputTokens"] ?? dictionary["prompt_tokens"]) ?? 0
        output = intValue(dictionary["output_tokens"] ?? dictionary["outputTokens"] ?? dictionary["completion_tokens"]) ?? 0
        cached = intValue(dictionary["cached_input_tokens"] ?? dictionary["cache_read_tokens"] ?? dictionary["cached_tokens"]) ?? 0
        reasoning = intValue(dictionary["reasoning_output_tokens"] ?? dictionary["reasoning_tokens"]) ?? 0
        total = intValue(dictionary["total_tokens"] ?? dictionary["totalTokens"])
    }

    private init(input: Int, output: Int, cached: Int, reasoning: Int, total: Int?) {
        self.input = max(input, 0)
        self.output = max(output, 0)
        self.cached = max(cached, 0)
        self.reasoning = max(reasoning, 0)
        self.total = total.map { max($0, 0) }
    }

    var totalTokens: Int {
        if let total { return total }
        return input + output + cached + reasoning
    }

    func delta(from previous: CodexTokenUsage) -> CodexTokenUsage? {
        let inputDelta = input - previous.input
        let outputDelta = output - previous.output
        let cachedDelta = cached - previous.cached
        let reasoningDelta = reasoning - previous.reasoning
        let totalDelta = total.flatMap { current in previous.total.map { current - $0 } }
        guard inputDelta >= 0, outputDelta >= 0, cachedDelta >= 0, reasoningDelta >= 0 else { return nil }
        if let totalDelta, totalDelta < 0 { return nil }
        return CodexTokenUsage(input: inputDelta, output: outputDelta, cached: cachedDelta, reasoning: reasoningDelta, total: totalDelta)
    }
}

// MARK: - Codex Manual Adapter

public final class CodexManualAdapter: ProviderAdapter, Sendable {
    public let provider: Provider = .codex

    public init() {}

    public func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        guard settings.codexEnabled else {
            return ProviderSnapshot(provider: .codex, confidence: .low, statusMessage: "Disabled")
        }

        let manual = settings.codexManual.pastedStatusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.codexManual
            : CodexStatusParser.safeParse(settings.codexManual.pastedStatusOutput, previous: settings.codexManual)

        let plan = manual.planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = manual.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPastedStatus = !manual.pastedStatusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPlan = !plan.isEmpty && plan.lowercased() != "manual"
        let hasValues = manual.fiveHourUsagePercentage > 0 || manual.weeklyUsagePercentage > 0
        let hasReset = !manual.resetTimeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasData = hasValues || hasPlan || hasReset || !notes.isEmpty || hasPastedStatus

        if manual.webSnapshotEnabled {
            let capturedAt = manual.webSnapshotCapturedAt ?? Date()
            let fiveHour = LimitWindow(kind: .fiveHour, usedPercent: manual.fiveHourUsagePercentage, confidence: .high)
            let weekly = LimitWindow(kind: .weekly, usedPercent: manual.weeklyUsagePercentage, confidence: .high)
            return ProviderSnapshot(
                provider: .codex,
                updatedAt: capturedAt,
                fiveHour: fiveHour,
                weekly: weekly,
                todayTokens: manual.webTodayTokens,
                confidence: .high,
                dataSource: .manual,
                isExperimental: false,
                isStale: false,
                statusMessage: "Manual web snapshot · user-entered Codex web values",
                model: hasPlan ? plan : nil,
                events: []
            )
        }

        guard hasData else {
            return ProviderSnapshot(
                provider: .codex,
                confidence: .manual,
                dataSource: .manual,
                statusMessage: "Manual mode · no data entered"
            )
        }

        let confidence = normalizedCodexConfidence(manual.confidence, hasPastedStatus: hasPastedStatus, hasValues: hasValues)
        let fiveHour = manual.fiveHourUsagePercentage > 0
            ? LimitWindow(kind: .fiveHour, usedPercent: manual.fiveHourUsagePercentage, confidence: confidence)
            : nil
        let weekly = manual.weeklyUsagePercentage > 0
            ? LimitWindow(kind: .weekly, usedPercent: manual.weeklyUsagePercentage, confidence: confidence)
            : nil
        let confidenceLabel = confidence == .low ? "Low" : "Medium"
        let mode = hasPastedStatus ? "Parsed /status" : "Manual"

        return ProviderSnapshot(
            provider: .codex,
            fiveHour: fiveHour,
            weekly: weekly,
            confidence: confidence,
            dataSource: .estimated,
            isStale: false,
            statusMessage: "\(mode) · \(confidenceLabel) confidence (est.)",
            model: hasPlan ? plan : nil,
            events: []
        )
    }

    public func parseStatusOutput(_ text: String) -> (fiveHour: LimitWindow?, weekly: LimitWindow?) {
        let parsed = CodexStatusParser.safeParse(text, previous: CodexManualSettings())
        return (
            parsed.fiveHourUsagePercentage > 0 ? LimitWindow(kind: .fiveHour, usedPercent: parsed.fiveHourUsagePercentage, confidence: parsed.confidence) : nil,
            parsed.weeklyUsagePercentage > 0 ? LimitWindow(kind: .weekly, usedPercent: parsed.weeklyUsagePercentage, confidence: parsed.confidence) : nil
        )
    }

    private func normalizedCodexConfidence(_ confidence: DataConfidence, hasPastedStatus: Bool, hasValues: Bool) -> DataConfidence {
        if confidence == .low { return .low }
        if hasPastedStatus || hasValues { return .medium }
        return .manual
    }
}

// MARK: - Private helpers

private func fileModificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

private func candidateFiles(in roots: [URL], allowedExtensions: Set<String>, maxFiles: Int) -> [URL] {
    var files: [URL] = []
    for root in roots {
        guard FileManager.default.fileExists(atPath: root.path), !isForbiddenCredentialPath(root) else { continue }
        if !isDirectory(root) {
            if allowedExtensions.contains(root.pathExtension.lowercased()) {
                files.append(root)
            }
            continue
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
        for case let file as URL in enumerator {
            guard files.count < maxFiles * 4 else { break }
            guard allowedExtensions.contains(file.pathExtension.lowercased()), !isForbiddenCredentialPath(file) else { continue }
            files.append(file)
        }
    }

    return files
        .sorted { (fileModificationDate($0) ?? Date.distantPast) > (fileModificationDate($1) ?? Date.distantPast) }
        .prefix(maxFiles)
        .map { $0 }
}

private func isForbiddenCredentialPath(_ url: URL) -> Bool {
    let lower = url.path.lowercased()
    let forbidden = [
        "auth.json",
        "credentials",
        "credential",
        "oauth",
        "token.json",
        "cookie",
        "keychain",
        "refresh_token",
        "secret",
        "api_key",
        ".env"
    ]
    return forbidden.contains { lower.contains($0) }
}
