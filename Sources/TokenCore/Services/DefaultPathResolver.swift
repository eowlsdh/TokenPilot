import Foundation

public final class DefaultPathResolver: Sendable {
    private let environment: [String: String]
    private let currentHomeDirectory: URL
    private let additionalHomeDirectories: [URL]

    public init() {
        self.environment = ProcessInfo.processInfo.environment
        self.currentHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        self.additionalHomeDirectories = Self.uniqueURLs(Self.discoverAdditionalHomeDirectories(
            environment: ProcessInfo.processInfo.environment,
            currentHomeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ))
    }

    public init(
        environment: [String: String],
        currentHomeDirectory: URL,
        additionalHomeDirectories: [URL]? = nil
    ) {
        self.environment = environment
        self.currentHomeDirectory = currentHomeDirectory.standardizedFileURL
        self.additionalHomeDirectories = Self.uniqueURLs(
            additionalHomeDirectories ?? Self.discoverAdditionalHomeDirectories(
                environment: environment,
                currentHomeDirectory: currentHomeDirectory
            )
        )
    }

    public func resolveDefaultPaths(for provider: Provider) -> [ProviderPathCandidate] {
        switch provider {
        case .claude:
            return resolveClaudePaths()
        case .codex:
            return resolveCodexPaths()
        case .gemini:
            return resolveGeminiPaths()
        case .deepseek, .xai:
            return []
        }
    }

    // MARK: - Claude Code

    private func resolveClaudePaths() -> [ProviderPathCandidate] {
        var candidates: [ProviderPathCandidate] = []

        for entry in claudeHomeCandidates() {
            appendClaudeHomeCandidates(
                home: entry.home,
                source: entry.source,
                confidence: entry.confidence,
                to: &candidates
            )
        }

        if let configDir = environment["CLAUDE_CONFIG_DIR"], let configURL = urlFromPath(configDir) {
            let projects = configURL.appendingPathComponent("projects", isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: projects.path)
            candidates.append(ProviderPathCandidate(
                provider: .claude,
                kind: "config_projects",
                path: projects.path,
                source: "CLAUDE_CONFIG_DIR",
                exists: exists,
                readable: exists && isReadable(projects),
                confidence: .high,
                notes: exists ? "Claude JSONL project logs" : "Claude config projects folder not found"
            ))
        }

        return deduplicated(candidates)
    }

    private func appendClaudeHomeCandidates(
        home: URL,
        source: String,
        confidence: DataConfidence,
        to candidates: inout [ProviderPathCandidate]
    ) {
        let claudeRoot = home.appendingPathComponent(".claude")
        let claudeExists = FileManager.default.fileExists(atPath: claudeRoot.path)

        candidates.append(ProviderPathCandidate(
            provider: .claude,
            kind: "root",
            path: claudeRoot.path,
            source: "default",
            exists: claudeExists,
            readable: claudeExists && isReadable(claudeRoot),
            confidence: .high,
            notes: claudeExists ? nil : "Claude Code folder not found"
        ))

        let projects = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        let projectsExists = FileManager.default.fileExists(atPath: projects.path)
        candidates.append(ProviderPathCandidate(
            provider: .claude,
            kind: "projects",
            path: projects.path,
            source: source,
            exists: projectsExists,
            readable: projectsExists && isReadable(projects),
            confidence: confidence,
            notes: projectsExists ? "Claude JSONL project logs" : "Claude projects folder not found"
        ))

        // Optional TokenPilot statusline file
        let statuslinePath = home.appendingPathComponent("Library/Application Support/TokenPilot/claude-statusline.json")
        let statuslineExists = FileManager.default.fileExists(atPath: statuslinePath.path)
        candidates.append(ProviderPathCandidate(
            provider: .claude,
            kind: "statusline",
            path: statuslinePath.path,
            source: "TokenPilot",
            exists: statuslineExists,
            readable: statuslineExists && isReadable(statuslinePath),
            confidence: .medium,
            notes: statuslineExists ? "Statusline data available" : nil
        ))
    }

    private func claudeHomeCandidates() -> [(home: URL, source: String, confidence: DataConfidence)] {
        var entries: [(URL, String, DataConfidence)] = []
        if let home = environment["HOME"], let homeURL = urlFromPath(home) {
            entries.append((homeURL, "HOME", .medium))
        }
        entries.append((currentHomeDirectory, "current user home", .medium))
        for home in additionalHomeDirectories {
            entries.append((home, claudeFallbackSource(for: home), .medium))
        }

        var seen = Set<String>()
        return entries.compactMap { home, source, confidence in
            let normalized = home.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { return nil }
            return (normalized, source, confidence)
        }
    }

    private func claudeFallbackSource(for home: URL) -> String {
        if home.path.hasPrefix("/Users/") {
            return "macOS user home fallback"
        }
        return "home fallback"
    }

    // MARK: - Codex

    private func resolveCodexPaths() -> [ProviderPathCandidate] {
        var candidates: [ProviderPathCandidate] = []

        // Highest priority: explicit CODEX_HOME. This is the only supported custom
        // Codex root signal we can safely consume without reading credentials.
        if let codexHome = environment["CODEX_HOME"], let codexRoot = urlFromPath(codexHome) {
            appendCodexRootCandidates(
                root: codexRoot,
                source: "CODEX_HOME",
                confidence: .high,
                to: &candidates
            )
        }

        // Process HOME can be a Hermes/profile sandbox (for example
        // ~/.hermes/profiles/dev/home). Keep it visible in diagnostics, but do not
        // stop there: Codex CLI usually writes to the real macOS user home.
        for entry in codexHomeCandidates() {
            appendCodexRootCandidates(
                root: entry.home.appendingPathComponent(".codex", isDirectory: true),
                source: entry.source,
                confidence: entry.confidence,
                to: &candidates
            )
        }

        return deduplicated(candidates)
    }

    private func appendCodexRootCandidates(
        root: URL,
        source: String,
        confidence: DataConfidence,
        to candidates: inout [ProviderPathCandidate]
    ) {
        let normalizedRoot = root.standardizedFileURL
        let rootExists = FileManager.default.fileExists(atPath: normalizedRoot.path)
        candidates.append(ProviderPathCandidate(
            provider: .codex,
            kind: "root",
            path: normalizedRoot.path,
            source: source,
            exists: rootExists,
            readable: rootExists && isReadable(normalizedRoot),
            confidence: confidence,
            notes: rootExists ? nil : "Codex folder not found"
        ))

        let sessionDirectories: [(kind: String, folder: String, missingNote: String)] = [
            ("sessions", "sessions", "Codex sessions folder not found"),
            ("archived_sessions", "archived_sessions", "Codex archived_sessions folder not found")
        ]
        for directory in sessionDirectories {
            let url = normalizedRoot.appendingPathComponent(directory.folder, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: url.path)
            candidates.append(ProviderPathCandidate(
                provider: .codex,
                kind: directory.kind,
                path: url.path,
                source: source,
                exists: exists,
                readable: exists && isReadable(url),
                confidence: confidence == .high ? .medium : confidence,
                notes: exists ? "Local JSONL token_count rows only · experimental" : directory.missingNote
            ))
        }
    }

    private func codexHomeCandidates() -> [(home: URL, source: String, confidence: DataConfidence)] {
        var entries: [(URL, String, DataConfidence)] = []

        if let home = environment["HOME"], let homeURL = urlFromPath(home) {
            entries.append((homeURL, "HOME", .medium))
        }
        entries.append((currentHomeDirectory, "current user home", .medium))

        for home in additionalHomeDirectories {
            entries.append((home, codexFallbackSource(for: home), .medium))
        }

        var seen = Set<String>()
        return entries.compactMap { home, source, confidence in
            let normalized = home.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { return nil }
            return (normalized, source, confidence)
        }
    }

    private func codexFallbackSource(for home: URL) -> String {
        if home.path.hasPrefix("/Users/") {
            return "macOS user home fallback"
        }
        return "home fallback"
    }

    // MARK: - Antigravity CLI / Gemini CLI

    private func resolveGeminiPaths() -> [ProviderPathCandidate] {
        let home = currentHomeDirectory
        var candidates: [ProviderPathCandidate] = []

        let antigravityStatusline = home.appendingPathComponent("Library/Application Support/TokenPilot/antigravity-statusline.json")
        candidates.append(ProviderPathCandidate(
            provider: .gemini,
            kind: "antigravity_statusline",
            path: antigravityStatusline.path,
            source: "default",
            exists: FileManager.default.fileExists(atPath: antigravityStatusline.path),
            readable: isReadable(antigravityStatusline),
            confidence: .high,
            notes: "Antigravity CLI statusLine JSON exported for TokenPilot"
        ))


        let geminiRoot = home.appendingPathComponent(".gemini")
        let geminiExists = FileManager.default.fileExists(atPath: geminiRoot.path)

        candidates.append(ProviderPathCandidate(
            provider: .gemini,
            kind: "root",
            path: geminiRoot.path,
            source: "default",
            exists: geminiExists,
            readable: geminiExists && isReadable(geminiRoot),
            confidence: .high,
            notes: geminiExists ? "Legacy Gemini CLI folder" : "Legacy Gemini CLI folder not found"
        ))

        if geminiExists {
            // telemetry.log
            let telemetry = geminiRoot.appendingPathComponent("telemetry.log")
            candidates.append(ProviderPathCandidate(
                provider: .gemini,
                kind: "telemetry",
                path: telemetry.path,
                source: "default",
                exists: FileManager.default.fileExists(atPath: telemetry.path),
                readable: isReadable(telemetry),
                confidence: .high
            ))

            // session folders (safe local logs; oauth credentials are intentionally ignored)
            for subpath in ["tmp", "history"] {
                let folder = geminiRoot.appendingPathComponent(subpath, isDirectory: true)
                candidates.append(ProviderPathCandidate(
                    provider: .gemini,
                    kind: subpath,
                    path: folder.path,
                    source: "default",
                    exists: FileManager.default.fileExists(atPath: folder.path),
                    readable: isReadable(folder),
                    confidence: .medium,
                    notes: "Session JSON/JSONL token rows"
                ))
            }

        }

        return candidates
    }

    private func isReadable(_ url: URL) -> Bool {
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    // MARK: - Home discovery helpers

    private static func discoverAdditionalHomeDirectories(environment: [String: String], currentHomeDirectory: URL) -> [URL] {
        var homes: [URL] = []

        if let nsHome = urlFromPath(NSHomeDirectory()) {
            homes.append(nsHome)
        }

        let names = [environment["LOGNAME"], environment["USER"], environment["SUDO_USER"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "root" }
        for name in names {
            homes.append(URL(fileURLWithPath: "/Users").appendingPathComponent(name, isDirectory: true))
        }

        var possibleHermesHomes: [String] = [currentHomeDirectory.path]
        if let home = environment["HOME"] {
            possibleHermesHomes.append(home)
        }
        for path in possibleHermesHomes {
            if let realHome = homeBeforeHermesProfile(in: path) {
                homes.append(realHome)
            }
        }

        let current = currentHomeDirectory.standardizedFileURL.path
        return uniqueURLs(homes).filter { $0.standardizedFileURL.path != current }
    }

    private static func homeBeforeHermesProfile(in path: String) -> URL? {
        guard let range = path.range(of: "/.hermes/profiles/") else { return nil }
        let prefix = String(path[..<range.lowerBound])
        guard !prefix.isEmpty else { return nil }
        return URL(fileURLWithPath: prefix, isDirectory: true)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func urlFromPath(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    private func urlFromPath(_ path: String) -> URL? {
        Self.urlFromPath(path)
    }

    private func deduplicated(_ candidates: [ProviderPathCandidate]) -> [ProviderPathCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            seen.insert("\(candidate.kind)|\(candidate.path)").inserted
        }
    }
}
