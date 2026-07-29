import Foundation
import SQLite3

/// Minimal read-only SQLite reader used by local-store adapters.
///
/// Opened with `SQLITE_OPEN_READONLY` plus immutable/URI mode so a live agent writing to its own
/// database is never blocked and its WAL is never modified by TokenPilot.
enum TokenPilotSQLite {
    static func query(
        databasePath: String,
        sql: String,
        maxRows: Int,
        columnCount: Int
    ) -> [[String?]] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }

        var handle: OpaquePointer?
        let uri = "file:\(databasePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databasePath)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return []
        }
        defer { sqlite3_close_v2(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[String?]] = []
        while rows.count < maxRows, sqlite3_step(statement) == SQLITE_ROW {
            var row: [String?] = []
            row.reserveCapacity(columnCount)
            for column in 0..<Int32(columnCount) {
                if let text = sqlite3_column_text(statement, column) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    static func tableExists(databasePath: String, table: String) -> Bool {
        let escaped = table.replacingOccurrences(of: "'", with: "''")
        let rows = query(
            databasePath: databasePath,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='\(escaped)' LIMIT 1",
            maxRows: 1,
            columnCount: 1
        )
        return !rows.isEmpty
    }
}

/// Reads opencode usage from its local session store.
///
/// opencode records exact per-message token counts and a cost value, so this is measured local
/// activity, not an estimate. It publishes no subscription window, so nothing produced here may be
/// presented as provider quota.
public struct OpenCodeSessionAdapter: ProviderAdapter, Sendable {
    public var provider: Provider { .opencode }

    private let databaseURLs: [URL]?
    private let legacyMessageRoots: [URL]?
    private let staleThreshold: TimeInterval
    private let maxMessages: Int
    /// Lazy so the consent-gated credential read and probe request are never constructed for a
    /// default configuration.
    private let makeRateLimitObserver: (@Sendable () -> OpenCodeRateLimitObserver)?

    public init(
        databaseURLs: [URL]? = nil,
        legacyMessageRoots: [URL]? = nil,
        staleThreshold: TimeInterval = 900,
        maxMessages: Int = 4_000,
        makeRateLimitObserver: (@Sendable () -> OpenCodeRateLimitObserver)? = { OpenCodeRateLimitObserver() }
    ) {
        self.databaseURLs = databaseURLs
        self.legacyMessageRoots = legacyMessageRoots
        self.staleThreshold = staleThreshold
        self.maxMessages = max(maxMessages, 1)
        self.makeRateLimitObserver = makeRateLimitObserver
    }

    public func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        guard settings.isProviderEnabled(.opencode) else {
            return ProviderSnapshot(provider: .opencode, confidence: .low, statusMessage: "Disabled")
        }

        let databases = databaseURLs ?? Self.defaultDatabaseURLs()
        var events = databases.flatMap { readDatabaseEvents(at: $0) }

        if events.isEmpty {
            let roots = legacyMessageRoots ?? Self.defaultLegacyMessageRoots()
            events = readLegacyEvents(roots: roots)
        }

        guard !events.isEmpty else {
            let anySourcePresent = databases.contains { FileManager.default.fileExists(atPath: $0.path) }
            return ProviderSnapshot(
                provider: .opencode,
                confidence: .low,
                dataSource: anySourcePresent ? .localLog : .unknown,
                statusMessage: anySourcePresent ? "No opencode usage recorded yet" : "opencode session store not found"
            )
        }

        var snapshot = Self.makeSnapshot(from: events, staleThreshold: staleThreshold)
        if settings.openCode.rateLimitProbeEnabled,
           let observer = makeRateLimitObserver?(),
           case .success(let limit) = await observer.observe(settings: settings) {
            snapshot = Self.applyingRateLimit(limit, to: snapshot)
        }
        return snapshot
    }

    /// Merges provider-reported quota from `ratelimit-*` headers into a local-activity snapshot.
    public static func applyingRateLimit(_ limit: OpenCodeRateLimit, to snapshot: ProviderSnapshot) -> ProviderSnapshot {
        var updated = snapshot
        updated.weekly = LimitWindow(
            kind: .weekly,
            usedPercent: limit.usedPercent,
            resetAt: limit.resetAt,
            confidence: .high,
            providerWindowID: "rate-limit"
        )
        updated.confidence = .high
        updated.isStale = false
        updated.updatedAt = limit.observedAt
        updated.statusMessage = "Provider-reported rate limit"
        return updated
    }

    public static func makeSnapshot(from rawEvents: [UsageEvent], staleThreshold: TimeInterval, now: Date = Date()) -> ProviderSnapshot {
        let events = deduplicated(rawEvents).sorted { $0.timestamp < $1.timestamp }
        let calendar = Calendar.current
        let todayEvents = events.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        let todayTokens = todayEvents.reduce(0) { $0 + $1.totalTokens }
        let todayCost = todayEvents.compactMap(\.estimatedCostUSD).reduce(Decimal(0), +)
        let newest = events.map(\.timestamp).max() ?? Date.distantPast
        let isStale = now.timeIntervalSince(newest) > staleThreshold
        let retainedStart = calendar.date(byAdding: .day, value: -44, to: calendar.startOfDay(for: now)) ?? now
        let retained = events.filter { $0.timestamp >= retainedStart }
        let model = retained.reversed().first { $0.model?.isEmpty == false }?.model

        return ProviderSnapshot(
            provider: .opencode,
            updatedAt: newest,
            todayTokens: todayTokens,
            todayCostUSD: todayCost > 0 ? todayCost : nil,
            confidence: isStale ? .medium : .high,
            dataSource: .localLog,
            isStale: isStale,
            statusMessage: isStale ? "STALE · no opencode activity in 15 minutes" : "Local session store · no quota window",
            model: model,
            events: retained,
            balance: todayCost > 0 ? ProviderBalance(
                currency: "USD",
                toppedUpBalance: todayCost,
                capturedAt: newest
            ) : nil
        )
    }

    // MARK: - SQLite sources

    private func readDatabaseEvents(at url: URL) -> [UsageEvent] {
        guard FileManager.default.fileExists(atPath: url.path), !isForbiddenOpenCodePath(url) else { return [] }

        // v2 (`opencode-next.db`) moved per-message rows into `session_message`; v1 keeps `message`.
        for table in ["session_message", "message"] where TokenPilotSQLite.tableExists(databasePath: url.path, table: table) {
            let rows = TokenPilotSQLite.query(
                databasePath: url.path,
                sql: "SELECT data, time_created FROM \(table) ORDER BY time_created DESC LIMIT \(maxMessages)",
                maxRows: maxMessages,
                columnCount: 2
            )
            let events = rows.compactMap { row -> UsageEvent? in
                guard let payload = row.first ?? nil else { return nil }
                let fallback = row.count > 1 ? Self.date(fromMilliseconds: row[1]) : nil
                return Self.parseMessage(json: payload, fallbackTimestamp: fallback)
            }
            if !events.isEmpty { return events }
        }
        return []
    }

    // MARK: - Legacy JSON sources

    private func readLegacyEvents(roots: [URL]) -> [UsageEvent] {
        let files = openCodeCandidateFiles(in: roots, maxFiles: maxMessages)
        return files.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return Self.parseMessage(json: text, fallbackTimestamp: fileModificationDateForOpenCode(file))
        }
    }

    // MARK: - Parsing

    public static func parseMessage(json: String, fallbackTimestamp: Date?) -> UsageEvent? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tokens = root["tokens"] as? [String: Any] else { return nil }

        let input = openCodeInt(tokens["input"])
        let output = openCodeInt(tokens["output"])
        let reasoning = openCodeInt(tokens["reasoning"])
        let cache = tokens["cache"] as? [String: Any]
        let cacheRead = openCodeInt(cache?["read"])
        let cacheWrite = openCodeInt(cache?["write"])
        guard input + output + reasoning + cacheRead + cacheWrite > 0 else { return nil }

        let timestamp = timestampFromOpenCodeTime(root["time"]) ?? fallbackTimestamp
        guard let timestamp else { return nil }

        let cost = openCodeDecimal(root["cost"])
        let modelID = root["modelID"] as? String
        let providerID = root["providerID"] as? String
        let model = [providerID, modelID].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "/")

        return UsageEvent(
            provider: .opencode,
            model: model.isEmpty ? nil : model,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            reasoningTokens: reasoning,
            requestCount: 1,
            estimatedCostUSD: (cost ?? 0) > 0 ? cost : nil,
            source: "opencode-session",
            dataSource: .localLog,
            isEstimated: false,
            isExperimental: false
        )
    }

    private static func timestampFromOpenCodeTime(_ value: Any?) -> Date? {
        guard let time = value as? [String: Any] else { return nil }
        for key in ["completed", "created"] {
            if let date = date(fromMilliseconds: time[key]) { return date }
        }
        return nil
    }

    private static func date(fromMilliseconds value: Any?) -> Date? {
        guard let milliseconds = openCodeDouble(value), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func deduplicated(_ events: [UsageEvent]) -> [UsageEvent] {
        var seen = Set<String>()
        var result: [UsageEvent] = []
        for event in events {
            let key = [
                String(Int(event.timestamp.timeIntervalSince1970.rounded())),
                event.model ?? "",
                String(event.inputTokens),
                String(event.outputTokens),
                String(event.reasoningTokens),
                String(event.cacheReadTokens),
                String(event.cacheCreationTokens)
            ].joined(separator: "|")
            if seen.insert(key).inserted {
                result.append(event)
            }
        }
        return result
    }

    // MARK: - Default locations

    static func defaultDatabaseURLs() -> [URL] {
        openCodeDataRoots().flatMap { root in
            ["opencode.db", "opencode-next.db"].map { root.appendingPathComponent($0) }
        }
    }

    static func defaultLegacyMessageRoots() -> [URL] {
        openCodeDataRoots().map { $0.appendingPathComponent("storage/message", isDirectory: true) }
    }

    private static func openCodeDataRoots() -> [URL] {
        var roots: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let xdgData = environment["XDG_DATA_HOME"], !xdgData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            roots.append(URL(fileURLWithPath: (xdgData as NSString).expandingTildeInPath).appendingPathComponent("opencode", isDirectory: true))
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode", isDirectory: true))
        return roots
    }
}

// MARK: - Local helpers

private func openCodeInt(_ value: Any?) -> Int {
    if let int = value as? Int { return max(int, 0) }
    if let number = value as? NSNumber { return max(number.intValue, 0) }
    if let string = value as? String, let parsed = Int(string) { return max(parsed, 0) }
    return 0
}

private func openCodeDouble(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

private func openCodeDecimal(_ value: Any?) -> Decimal? {
    if let decimal = value as? Decimal { return decimal }
    if let number = value as? NSNumber { return number.decimalValue }
    if let string = value as? String { return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) }
    return nil
}

private func fileModificationDateForOpenCode(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
}

private func isForbiddenOpenCodePath(_ url: URL) -> Bool {
    let lower = url.lastPathComponent.lowercased()
    return ["auth", "credential", "token", "secret", "cookie", "keychain"].contains { lower.contains($0) }
}

private func openCodeCandidateFiles(in roots: [URL], maxFiles: Int) -> [URL] {
    var files: [URL] = []
    for root in roots {
        guard FileManager.default.fileExists(atPath: root.path) else { continue }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for case let file as URL in enumerator {
            guard files.count < maxFiles * 4 else { break }
            guard file.pathExtension.lowercased() == "json", !isForbiddenOpenCodePath(file) else { continue }
            files.append(file)
        }
    }
    return files
        .sorted { (fileModificationDateForOpenCode($0) ?? .distantPast) > (fileModificationDateForOpenCode($1) ?? .distantPast) }
        .prefix(maxFiles)
        .map { $0 }
}

extension OpenCodeSessionAdapter: ProviderRefreshAdapter {}
