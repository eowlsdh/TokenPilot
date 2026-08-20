import Foundation

/// Reads Command Code usage from its local session transcripts.
///
/// Command Code (`cmd`) keeps an append-only transcript per session at
/// `~/.commandcode/projects/<project-slug>/<session-id>.jsonl`, where each entry
/// carries the model, its token usage, a cost, and a timestamp. Those are the
/// numbers Command Code recorded itself, so they are measured rather than
/// estimated — but they are local activity only.
///
/// Command Code meters its plans in **dollars over rolling windows** ($14 per 5
/// hours and $35 per 7 days on GOAT, for example) and publishes those meters
/// only through `/usage` in the CLI and the Studio usage page, behind the API
/// key in `~/.commandcode/auth.json`. This adapter never reads that file and
/// never derives a quota percentage from local spend: local cost is not a
/// subscription window, and presenting it as one would be a guess wearing a
/// provider's name.
public struct CommandCodeLocalSessionAdapter: ProviderAdapter, Sendable {
    public var provider: Provider { .commandcode }

    private let projectRoots: [URL]?
    private let staleThreshold: TimeInterval
    private let maxFiles: Int

    public init(
        projectRoots: [URL]? = nil,
        staleThreshold: TimeInterval = 900,
        maxFiles: Int = 200
    ) {
        self.projectRoots = projectRoots
        self.staleThreshold = staleThreshold
        self.maxFiles = max(maxFiles, 1)
    }

    /// `~/.commandcode/projects` holds one directory per project slug.
    public static func defaultProjectRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".commandcode/projects", isDirectory: true)]
    }

    public func snapshot(settings: AppSettings) async -> ProviderSnapshot {
        guard settings.isProviderEnabled(.commandcode) else {
            return ProviderSnapshot(provider: .commandcode, confidence: .low, statusMessage: "Disabled")
        }

        let resolution = ProviderSourceAccess.resolve(
            provider: .commandcode,
            settings: settings,
            defaults: projectRoots ?? Self.defaultProjectRoots()
        )
        defer { resolution.release() }

        guard !resolution.needsUserGrant else {
            return ProviderSnapshot(
                provider: .commandcode,
                confidence: .low,
                dataSource: .unknown,
                statusMessage: "Choose the Command Code folder to grant access"
            )
        }

        let roots = resolution.roots
        let rootExists = roots.contains { FileManager.default.fileExists(atPath: $0.path) }
        guard rootExists else {
            return ProviderSnapshot(
                provider: .commandcode,
                confidence: .low,
                dataSource: .unknown,
                statusMessage: "Command Code session folder not found"
            )
        }

        let events = readEvents(roots: roots)
        guard !events.isEmpty else {
            return ProviderSnapshot(
                provider: .commandcode,
                confidence: .low,
                dataSource: .localLog,
                statusMessage: "No Command Code usage recorded yet"
            )
        }
        return Self.makeSnapshot(from: events, staleThreshold: staleThreshold)
    }

    public static func makeSnapshot(
        from rawEvents: [UsageEvent],
        staleThreshold: TimeInterval,
        now: Date = Date()
    ) -> ProviderSnapshot {
        let events = rawEvents.sorted { $0.timestamp < $1.timestamp }
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
            provider: .commandcode,
            updatedAt: newest,
            todayTokens: todayTokens,
            todayCostUSD: todayCost > 0 ? todayCost : nil,
            confidence: isStale ? .medium : .high,
            dataSource: .localLog,
            isStale: isStale,
            statusMessage: isStale
                ? "STALE · no Command Code activity in 15 minutes"
                : "Local sessions · rolling dollar limits are not published locally",
            model: model,
            events: retained,
            balance: todayCost > 0 ? ProviderBalance(
                currency: "USD",
                toppedUpBalance: todayCost,
                capturedAt: newest
            ) : nil
        )
    }

    // MARK: - Transcript reading

    private func readEvents(roots: [URL]) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for transcript in Self.transcriptURLs(in: roots, maxFiles: maxFiles) {
            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { continue }
            events.append(
                contentsOf: Self.parseTranscript(
                    jsonl: text,
                    projectLabel: Self.projectLabel(forTranscript: transcript)
                )
            )
        }
        return events
    }

    /// Newest transcripts first, capped, skipping the sidecar files Command Code writes next to a
    /// transcript (`.meta.json`, `.prompts.jsonl`, `.checkpoints.jsonl`, `.share.json`) and anything
    /// whose name suggests credentials.
    static func transcriptURLs(in roots: [URL], maxFiles: Int) -> [URL] {
        var candidates: [(url: URL, modified: Date)] = []
        let manager = FileManager.default
        for root in roots {
            guard manager.fileExists(atPath: root.path),
                  let enumerator = manager.enumerator(
                      at: root,
                      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                      options: [.skipsHiddenFiles]
                  ) else {
                continue
            }
            for case let file as URL in enumerator {
                guard isTranscript(file), !isForbiddenCommandCodePath(file) else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                candidates.append((file, modified ?? .distantPast))
            }
        }
        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(maxFiles)
            .map(\.url)
    }

    static func isTranscript(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".jsonl") else { return false }
        return !name.hasSuffix(".prompts.jsonl") && !name.hasSuffix(".checkpoints.jsonl")
    }

    /// Folder name only, never a path.
    ///
    /// Project slugs encode the working directory (`-Users-me-dev-myapp`), so only the trailing
    /// segment is kept — the same rule opencode's workspace labels follow, and the reason no local
    /// path can reach an event, an export, or the History project breakdown.
    static func projectLabel(forTranscript url: URL) -> String? {
        projectLabel(fromSlug: url.deletingLastPathComponent().lastPathComponent)
    }

    static func projectLabel(fromSlug slug: String) -> String? {
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-_ /"))
        guard !trimmed.isEmpty else { return nil }
        let segments = trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "/" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let last = segments.last else { return nil }
        return String(last.prefix(64))
    }

    /// Parses one transcript into usage events.
    ///
    /// Entries without measured usage (the header line, prompts, model/effort switches, compaction
    /// summaries) carry no tokens and no cost, and are skipped rather than counted as empty turns.
    /// Field names are read in several spellings because the transcript schema is not published.
    public static func parseTranscript(jsonl: String, projectLabel: String?) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let root = jsonObject(fromLine: trimmed) else { continue }
            guard let event = parseEntry(root, projectLabel: projectLabel) else { continue }
            events.append(event)
        }
        return events
    }

    static func parseEntry(_ root: [String: Any], projectLabel: String?) -> UsageEvent? {
        let usage = firstDictionary(
            in: root,
            keys: ["usage", "token_usage", "tokenUsage", "tokens", "metrics"]
        ) ?? root

        let input = tokenCount(usage, keys: ["input_tokens", "inputTokens", "input", "prompt_tokens", "promptTokens"])
        let output = tokenCount(usage, keys: ["output_tokens", "outputTokens", "output", "completion_tokens", "completionTokens"])
        let cacheRead = tokenCount(usage, keys: ["cache_read_input_tokens", "cacheReadInputTokens", "cache_read_tokens", "cacheReadTokens", "cache_read", "cached_tokens"])
        let cacheWrite = tokenCount(usage, keys: ["cache_creation_input_tokens", "cacheCreationInputTokens", "cache_write_tokens", "cacheWriteTokens", "cache_creation", "cache_write"])
        let reasoning = tokenCount(usage, keys: ["reasoning_tokens", "reasoningTokens", "thinking_tokens", "thinkingTokens"])
        let cost = self.cost(root: root, usage: usage)

        // A turn with neither tokens nor cost is bookkeeping, not usage.
        guard input + output + cacheRead + cacheWrite + reasoning > 0 || (cost ?? 0) > 0 else { return nil }

        guard let timestamp = timestamp(root) else { return nil }
        let model = self.model(root)

        return UsageEvent(
            provider: .commandcode,
            model: model,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            reasoningTokens: reasoning,
            requestCount: 1,
            estimatedCostUSD: (cost ?? 0) > 0 ? cost : nil,
            source: "commandcode-session",
            dataSource: .localLog,
            isEstimated: false,
            isExperimental: false,
            projectLabel: projectLabel
        )
    }

    private static func tokenCount(_ container: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = intValue(container[key]), value >= 0 { return value }
        }
        return 0
    }

    private static func cost(root: [String: Any], usage: [String: Any]) -> Decimal? {
        for container in [usage, root] {
            for key in ["cost_usd", "costUSD", "costUsd", "total_cost_usd", "totalCostUSD", "usd", "price"] {
                if let value = decimalValue(container[key]), value >= 0 { return value }
            }
            if let nested = container["cost"] as? [String: Any] {
                for key in ["total_usd", "totalUSD", "usd", "total", "amount"] {
                    if let value = decimalValue(nested[key]), value >= 0 { return value }
                }
            } else if let value = decimalValue(container["cost"]), value >= 0 {
                return value
            }
        }
        return nil
    }

    private static func timestamp(_ root: [String: Any]) -> Date? {
        for key in ["timestamp", "ts", "time", "created_at", "createdAt", "started_at", "startedAt"] {
            if let date = dateValue(root[key]) { return date }
        }
        return nil
    }

    private static func model(_ root: [String: Any]) -> String? {
        if let model = stringValue(root["model"]), !model.isEmpty { return model }
        if let nested = root["model"] as? [String: Any] {
            for key in ["id", "name", "slug", "display_name", "displayName"] {
                if let model = stringValue(nested[key]), !model.isEmpty { return model }
            }
        }
        for key in ["model_id", "modelId", "model_name", "modelName"] {
            if let model = stringValue(root[key]), !model.isEmpty { return model }
        }
        return nil
    }
}

/// `~/.commandcode` also holds `auth.json` (the API key) and `config.json`. Transcript reading must
/// never touch them, so the name guard runs on every candidate file before it is opened.
private func isForbiddenCommandCodePath(_ url: URL) -> Bool {
    let lower = url.path.lowercased()
    return ["auth", "credential", "token.json", "secret", "cookie", "keychain", "oauth", "api_key", ".env"]
        .contains { lower.contains($0) }
}

extension CommandCodeLocalSessionAdapter: ProviderRefreshAdapter {}
