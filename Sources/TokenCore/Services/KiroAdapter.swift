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

        let roots = sessionRoots ?? Self.defaultSessionRoots()
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
        let contextPercent = readLatestContextPercent(roots: roots)
        var snapshot = Self.makeSnapshot(
            creditEntries: ideUsage,
            contextPercent: contextPercent,
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

    public static func makeSnapshot(
        creditEntries: [CreditEntry],
        contextPercent: (percent: Int, timestamp: Date)?,
        staleThreshold: TimeInterval,
        now: Date = Date()
    ) -> ProviderSnapshot {
        let calendar = Calendar.current
        let todayEntries = creditEntries.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        let todayCredits = todayEntries.reduce(Decimal(0)) { $0 + $1.credits }
        let newestCredit = creditEntries.map(\.timestamp).max()
        let newest = [newestCredit, contextPercent?.timestamp].compactMap { $0 }.max()

        guard let newest else {
            return ProviderSnapshot(
                provider: .kiro,
                confidence: .low,
                dataSource: .localLog,
                statusMessage: "No Kiro usage recorded yet"
            )
        }

        let isStale = now.timeIntervalSince(newest) > staleThreshold
        // Credits are the metered unit, so requestCount carries turns and tokens stay zero.
        let events = creditEntries
            .filter { $0.timestamp >= (calendar.date(byAdding: .day, value: -44, to: calendar.startOfDay(for: now)) ?? now) }
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
            .sorted { $0.timestamp < $1.timestamp }

        return ProviderSnapshot(
            provider: .kiro,
            updatedAt: newest,
            confidence: isStale ? .medium : .high,
            dataSource: .localLog,
            isStale: isStale,
            statusMessage: isStale
                ? "STALE · no Kiro activity in 15 minutes"
                : "Local sessions · credits metered, no quota window",
            contextWindowUsedPercent: contextPercent?.percent,
            events: events,
            creditsUsed: todayCredits > 0 ? todayCredits : nil
        )
    }

    // MARK: - IDE transcripts

    private func readIDEUsage(roots: [URL]) -> [CreditEntry] {
        var entries: [CreditEntry] = []
        for transcript in transcriptURLs(in: roots) {
            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { continue }
            entries.append(contentsOf: Self.parseUsageSummaries(jsonl: text, fallbackTimestamp: kiroModificationDate(transcript)))
        }
        return entries
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

    private func readLatestContextPercent(roots: [URL]) -> (percent: Int, timestamp: Date)? {
        var best: (percent: Int, timestamp: Date)?
        for file in cliSessionURLs(in: roots) {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parsed = Self.parseContextPercent(sessionJSON: root, fallbackTimestamp: kiroModificationDate(file)) else { continue }
            if best == nil || parsed.timestamp > best!.timestamp {
                best = parsed
            }
        }
        return best
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

    private func collect(in roots: [URL], matching predicate: (URL) -> Bool) -> [URL] {
        var found: [URL] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard found.count < maxFiles * 4 else { break }
                guard !isForbiddenKiroPath(url), predicate(url) else { continue }
                found.append(url)
            }
        }
        return found
            .sorted { (kiroModificationDate($0) ?? .distantPast) > (kiroModificationDate($1) ?? .distantPast) }
            .prefix(maxFiles)
            .map { $0 }
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
