import Foundation

/// Reads Kiro usage from its local session files.
///
/// Kiro meters work in credits, not tokens, and reports a context-window percentage. Both values
/// come straight from Kiro's own records, so they are measured. Because Kiro publishes no token
/// counts here, this adapter deliberately does not estimate tokens from transcript text: a guessed
/// token number must never appear next to provider-reported ones.
public struct KiroLocalSessionAdapter: ProviderAdapter, Sendable {
    public var provider: Provider { .kiro }

    private let sessionRoots: [URL]?
    private let staleThreshold: TimeInterval
    private let maxFiles: Int
    /// Lazy so the consent-gated credential read and network call are never constructed for a
    /// default configuration.
    private let makeUsageObserver: (@Sendable () -> KiroUsageLimitsObserver)?

    public init(
        sessionRoots: [URL]? = nil,
        staleThreshold: TimeInterval = 900,
        maxFiles: Int = 200,
        makeUsageObserver: (@Sendable () -> KiroUsageLimitsObserver)? = { KiroUsageLimitsObserver() }
    ) {
        self.sessionRoots = sessionRoots
        self.staleThreshold = staleThreshold
        self.maxFiles = max(maxFiles, 1)
        self.makeUsageObserver = makeUsageObserver
    }

    public func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        guard settings.isProviderEnabled(.kiro) else {
            return ProviderSnapshot(provider: .kiro, confidence: .low, statusMessage: "Disabled")
        }

        let resolution = ProviderSourceAccess.resolve(
            provider: .kiro,
            settings: settings,
            defaults: sessionRoots ?? Self.defaultSessionRoots()
        )
        defer { resolution.release() }

        guard !resolution.needsUserGrant else {
            return ProviderSnapshot(
                provider: .kiro,
                confidence: .low,
                dataSource: .unknown,
                statusMessage: "Choose the Kiro folder to grant access"
            )
        }

        let roots = resolution.roots
        let rootExists = roots.contains { FileManager.default.fileExists(atPath: $0.path) }
        guard rootExists else {
            return ProviderSnapshot(
                provider: .kiro,
                confidence: .low,
                dataSource: .unknown,
                statusMessage: "Kiro session folder not found"
            )
        }

        let ideUsage = readIDEUsage(roots: roots)
        let cli = readCLISessions(roots: roots)
        var snapshot = Self.makeSnapshot(
            creditEntries: ideUsage.credits,
            contextPercent: cli.contextPercent,
            creditUsage: ideUsage.creditUsage,
            cliEvents: cli.events,
            staleThreshold: staleThreshold
        )

        if settings.kiro.usageLimitsEnabled,
           let observer = makeUsageObserver?(),
           case .success(let limits) = await observer.observe(settings: settings) {
            snapshot = Self.applyingUsageLimits(limits, to: snapshot)
        }
        return snapshot
    }

    /// Merges provider-reported quota into a local-activity snapshot. The window carries high
    /// confidence because it comes from Kiro's own usage API rather than local inference.
    public static func applyingUsageLimits(_ limits: KiroUsageLimits, to snapshot: ProviderSnapshot) -> ProviderSnapshot {
        var updated = snapshot
        updated.weekly = LimitWindow(
            kind: .weekly,
            usedPercent: limits.usedPercent,
            resetAt: limits.resetAt,
            confidence: .high,
            providerWindowID: "usage-limits"
        )
        updated.confidence = .high
        updated.isStale = false
        updated.updatedAt = limits.observedAt
        updated.statusMessage = "Provider-reported usage limits"
        return updated
    }

    public struct CreditEntry: Sendable, Equatable {
        public var credits: Decimal
        public var timestamp: Date
        public var toolCalls: Int
        public var status: String?

        public init(credits: Decimal, timestamp: Date, toolCalls: Int, status: String? = nil) {
            self.credits = credits
            self.timestamp = timestamp
            self.toolCalls = toolCalls
            self.status = status
        }
    }

    /// The running credit-usage percentage Kiro writes into its own transcript.
    public struct CreditUsageSample: Sendable, Equatable {
        public var usedPercent: Int
        public var timestamp: Date

        public init(usedPercent: Int, timestamp: Date) {
            self.usedPercent = min(max(usedPercent, 0), 100)
            self.timestamp = timestamp
        }
    }

    public static func makeSnapshot(
        creditEntries: [CreditEntry],
        contextPercent: (percent: Int, timestamp: Date)?,
        creditUsage: CreditUsageSample? = nil,
        cliEvents: [UsageEvent] = [],
        staleThreshold: TimeInterval,
        now: Date = Date()
    ) -> ProviderSnapshot {
        let calendar = Calendar.current
        let todayEntries = creditEntries.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        let todayCredits = todayEntries.reduce(Decimal(0)) { $0 + $1.credits }
        let newestCredit = creditEntries.map(\.timestamp).max()
        let newestCLI = cliEvents.map(\.timestamp).max()
        let newest = [newestCredit, contextPercent?.timestamp, creditUsage?.timestamp, newestCLI]
            .compactMap { $0 }
            .max()

        guard let newest else {
            return ProviderSnapshot(
                provider: .kiro,
                confidence: .low,
                dataSource: .localLog,
                statusMessage: "No Kiro usage recorded yet"
            )
        }

        let isStale = now.timeIntervalSince(newest) > staleThreshold
        let retainedStart = calendar.date(byAdding: .day, value: -44, to: calendar.startOfDay(for: now)) ?? now
        // The IDE transcript meters in credits, so requestCount carries turns and tokens stay zero.
        // The CLI sessions are the only half of Kiro that reports tokens at all.
        let creditEvents = creditEntries
            .filter { $0.timestamp >= retainedStart }
            .map { entry in
                UsageEvent(
                    provider: .kiro,
                    model: nil,
                    timestamp: entry.timestamp,
                    inputTokens: 0,
                    outputTokens: 0,
                    requestCount: max(entry.toolCalls, 1),
                    estimatedCostUSD: nil,
                    source: "kiro-usage-summary",
                    dataSource: .localLog,
                    isEstimated: false,
                    isExperimental: false
                )
            }
        let events = (creditEvents + cliEvents.filter { $0.timestamp >= retainedStart })
            .sorted { $0.timestamp < $1.timestamp }
        let todayEvents = events.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        let todayTokens = todayEvents.reduce(0) { $0 + $1.totalTokens }
        let todayCacheReadTokens = todayEvents.reduce(0) { $0 + $1.cacheReadTokens }

        // Kiro publishes its own credit-usage percentage in the transcript. The period it covers is
        // undocumented, so it is carried as a credit window with no reset time and medium
        // confidence: the number is the provider's, the window it belongs to is not stated. It goes
        // in the monthly slot so `applyingUsageLimits` — Kiro's opt-in usage API, which is the
        // authoritative source — keeps the weekly slot to itself.
        let creditWindow = creditUsage.map { sample in
            LimitWindow(
                kind: .monthly,
                name: "Credits",
                usedPercent: sample.usedPercent,
                label: "cr",
                confidence: .medium,
                providerWindowID: "credit-usage"
            )
        }

        let liveStatus = creditWindow == nil
            ? "Local sessions · credits metered, no quota window"
            : "Local sessions · Kiro-reported credit usage"

        return ProviderSnapshot(
            provider: .kiro,
            updatedAt: newest,
            monthly: creditWindow,
            todayTokens: todayTokens,
            todayCacheReadTokens: todayCacheReadTokens,
            confidence: isStale ? .medium : .high,
            dataSource: .localLog,
            isStale: isStale,
            statusMessage: isStale ? "STALE · no Kiro activity in 15 minutes" : liveStatus,
            contextWindowUsedPercent: contextPercent?.percent,
            events: events,
            creditsUsed: todayCredits > 0 ? todayCredits : nil
        )
    }

    // MARK: - IDE transcripts

    private func readIDEUsage(roots: [URL]) -> (credits: [CreditEntry], creditUsage: CreditUsageSample?) {
        var entries: [CreditEntry] = []
        var newestUsage: CreditUsageSample?
        for transcript in transcriptURLs(in: roots) {
            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { continue }
            let fallback = kiroModificationDate(transcript)
            entries.append(contentsOf: Self.parseUsageSummaries(jsonl: text, fallbackTimestamp: fallback))
            if let sample = Self.parseCreditUsagePercent(jsonl: text, fallbackTimestamp: fallback),
               newestUsage == nil || sample.timestamp > newestUsage!.timestamp {
                newestUsage = sample
            }
        }
        return (entries, newestUsage)
    }

    /// Kiro writes a running credit-usage percentage into its transcript as
    /// `payload.type == "session_metadata"` → `payload.value.usagePercentage`. It is the only
    /// quota-shaped number Kiro publishes without an API call, and the adapter used to drop it —
    /// the snapshot said "no quota window" while the number sat in the file it was already reading.
    ///
    /// Returns the newest sample, not the largest: the value climbs through a session, but a
    /// reset would make the largest one stale and wrong.
    public static func parseCreditUsagePercent(jsonl: String, fallbackTimestamp: Date?) -> CreditUsageSample? {
        var newest: CreditUsageSample?
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.contains("session_metadata"), let data = trimmed.data(using: .utf8) else { continue }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "session_metadata",
                  let value = payload["value"] as? [String: Any],
                  let rawPercent = kiroDouble(value["usagePercentage"]),
                  (0...100).contains(rawPercent) else { continue }

            let timestamp = kiroDate(root["timestamp"]) ?? kiroDate(root["updated_at"]) ?? fallbackTimestamp
            guard let timestamp else { continue }
            guard newest == nil || timestamp > newest!.timestamp else { continue }
            newest = CreditUsageSample(usedPercent: Int(rawPercent.rounded()), timestamp: timestamp)
        }
        return newest
    }

    public static func parseUsageSummaries(jsonl: String, fallbackTimestamp: Date?) -> [CreditEntry] {
        var entries: [CreditEntry] = []
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.contains("usage_summary"), let data = trimmed.data(using: .utf8) else { continue }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "usage_summary" else { continue }

            let summaries = payload["promptTurnSummaries"] as? [[String: Any]] ?? []
            var credits = Decimal(0)
            var toolCalls = 0
            for summary in summaries {
                // Only credit-denominated turns count; a future unit change must not be summed blindly.
                let unit = (summary["unit"] as? String)?.lowercased()
                guard unit == nil || unit == "credit" || unit == "credits" else { continue }
                if let usage = kiroDecimal(summary["usage"]), usage > 0 {
                    credits += usage
                }
                toolCalls += (summary["usedTools"] as? [Any])?.count ?? 0
            }
            guard credits > 0 else { continue }

            let timestamp = kiroDate(root["timestamp"]) ?? fallbackTimestamp
            guard let timestamp else { continue }
            entries.append(CreditEntry(
                credits: credits,
                timestamp: timestamp,
                toolCalls: toolCalls,
                status: payload["status"] as? String
            ))
        }
        return entries
    }

    // MARK: - CLI session state

    /// One pass over the CLI session files for both signals they carry, rather than reading each
    /// file twice.
    private func readCLISessions(roots: [URL]) -> (contextPercent: (percent: Int, timestamp: Date)?, events: [UsageEvent]) {
        var best: (percent: Int, timestamp: Date)?
        var events: [UsageEvent] = []
        for file in cliSessionURLs(in: roots) {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let fallback = kiroModificationDate(file)
            if let parsed = Self.parseContextPercent(sessionJSON: root, fallbackTimestamp: fallback),
               best == nil || parsed.timestamp > best!.timestamp {
                best = parsed
            }
            events.append(contentsOf: Self.parseCLITurns(sessionJSON: root, fallbackTimestamp: fallback))
        }
        return (best, events.sorted { $0.timestamp < $1.timestamp })
    }

    /// Per-turn token counts from a Kiro CLI session file.
    ///
    /// The IDE transcript meters in credits and reports no tokens, so before this the CLI half of
    /// Kiro contributed no usage at all. **The field names here are read from real session files but
    /// every count on the development machine is zero**, so the shape is verified and the values are
    /// not — the parser therefore drops anything it cannot read rather than inventing a total.
    public static func parseCLITurns(sessionJSON root: [String: Any], fallbackTimestamp: Date?) -> [UsageEvent] {
        guard let state = root["session_state"] as? [String: Any],
              let metadata = state["conversation_metadata"] as? [String: Any],
              let turns = metadata["user_turn_metadatas"] as? [[String: Any]] else {
            return []
        }

        return turns.compactMap { turn in
            let input = kiroInt(turn["input_token_count"])
            let output = kiroInt(turn["output_token_count"])
            let cacheRead = kiroInt(turn["cache_read_input_token_count"])
            let cacheWrite = kiroInt(turn["cache_write_input_token_count"])
            let requests = max(kiroInt(turn["total_request_count"]), 0)
            // A turn with neither tokens nor a request is bookkeeping, not usage.
            guard input + output + cacheRead + cacheWrite > 0 || requests > 0 else { return nil }

            let result = (turn["result"] as? [String: Any])?["Ok"] as? [String: Any]
            let meta = result?["meta"] as? [String: Any]
            guard let timestamp = kiroDate(meta?["timestamp"]) ?? fallbackTimestamp else { return nil }

            let model = (turn["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return UsageEvent(
                provider: .kiro,
                model: model,
                timestamp: timestamp,
                inputTokens: max(input, 0),
                outputTokens: max(output, 0),
                cacheReadTokens: max(cacheRead, 0),
                cacheCreationTokens: max(cacheWrite, 0),
                requestCount: max(requests, 1),
                source: "kiro-cli-turn",
                dataSource: .localLog
            )
        }
    }

    public static func parseContextPercent(sessionJSON root: [String: Any], fallbackTimestamp: Date?) -> (percent: Int, timestamp: Date)? {
        guard let state = root["session_state"] as? [String: Any],
              let modelState = state["rts_model_state"] as? [String: Any],
              let rawPercent = kiroDouble(modelState["context_usage_percentage"]) else {
            return nil
        }
        let percent = Int(rawPercent.rounded())
        guard (0...100).contains(percent) else { return nil }
        let timestamp = kiroDate(root["updated_at"]) ?? kiroDate(root["created_at"]) ?? fallbackTimestamp
        guard let timestamp else { return nil }
        return (percent, timestamp)
    }

    // MARK: - File discovery

    private func transcriptURLs(in roots: [URL]) -> [URL] {
        collect(in: roots, matching: { $0.lastPathComponent == "messages.jsonl" })
    }

    private func cliSessionURLs(in roots: [URL]) -> [URL] {
        collect(in: roots) { url in
            url.pathExtension.lowercased() == "json" && url.deletingLastPathComponent().lastPathComponent == "cli"
        }
    }

    /// The newest `maxFiles` matching files, newest first.
    ///
    /// This used to stop walking after `maxFiles * 4` entries and sort those by modification date,
    /// which ranks an arbitrary slice of the tree rather than the tree — see ``NewestFileScan``.
    private func collect(in roots: [URL], matching predicate: (URL) -> Bool) -> [URL] {
        NewestFileScan.newestFiles(in: roots, limit: maxFiles) { url in
            !isForbiddenKiroPath(url) && predicate(url)
        }
        .files
    }

    static func defaultSessionRoots() -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/sessions", isDirectory: true)]
    }
}

// MARK: - Local helpers

private func kiroDecimal(_ value: Any?) -> Decimal? {
    if let decimal = value as? Decimal { return decimal }
    if let number = value as? NSNumber { return number.decimalValue }
    if let string = value as? String { return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) }
    return nil
}

private func kiroInt(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String, let parsed = Int(string) { return parsed }
    return 0
}

private func kiroDouble(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

private nonisolated(unsafe) let kiroISOFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private nonisolated(unsafe) let kiroISOPlain = ISO8601DateFormatter()

private func kiroDate(_ value: Any?) -> Date? {
    if let number = value as? NSNumber {
        let raw = number.doubleValue
        guard raw > 0 else { return nil }
        // Kiro writes both second and millisecond epochs depending on the record.
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1_000 : raw)
    }
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = Double(trimmed), seconds > 1_000_000 {
        return Date(timeIntervalSince1970: seconds > 1_000_000_000_000 ? seconds / 1_000 : seconds)
    }
    if let date = kiroISOFractional.date(from: trimmed) { return date }
    return kiroISOPlain.date(from: trimmed)
}

private func kiroModificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
}

private func isForbiddenKiroPath(_ url: URL) -> Bool {
    let lower = url.path.lowercased()
    return ["auth", "credential", "token.json", "secret", "cookie", "keychain", "oauth"].contains { lower.contains($0) }
}

extension KiroLocalSessionAdapter: ProviderRefreshAdapter {}
