import Foundation

public final class DataSourceConnectionService: @unchecked Sendable {
    public struct AutoDetectionResult: Sendable {
        public var settings: AppSettings
        public var adoptedProviders: [Provider]

        public init(settings: AppSettings, adoptedProviders: [Provider]) {
            self.settings = settings
            self.adoptedProviders = adoptedProviders
        }
    }

    private let pathResolver: DefaultPathResolver
    private let fileManager: FileManager

    public init(pathResolver: DefaultPathResolver = DefaultPathResolver(), fileManager: FileManager = .default) {
        self.pathResolver = pathResolver
        self.fileManager = fileManager
    }

    public func checkAll(settings: AppSettings) async -> [ProviderDataSource] {
        var sources: [ProviderDataSource] = []
        for provider in Provider.allCases {
            sources.append(await check(settings: settings, provider: provider))
        }
        return sources
    }

    public func check(settings: AppSettings, provider: Provider) async -> ProviderDataSource {
        let candidates = pathCandidates(settings: settings, provider: provider)
        guard settings.isProviderEnabled(provider) else {
            return ProviderDataSource(
                provider: provider,
                isEnabled: false,
                mode: .disabled,
                detectedPaths: candidates,
                customPath: configuredPath(settings: settings, provider: provider),
                lastScanAt: Date(),
                status: .disabled,
                confidence: .low,
                statusMessage: "Disabled"
            )
        }

        switch provider {
        case .claude:
            let projectRoots = claudeProjectRoots(from: candidates)
            let useProjectFallback = shouldUseClaudeProjectFallback(settings: settings)
            let snapshot = await ClaudeStatuslineAdapter(
                fallbackProjectRoots: useProjectFallback && !projectRoots.isEmpty ? projectRoots : nil
            ).snapshot(settings: settings)
            return classifyFileBackedProvider(
                provider: provider,
                settings: settings,
                candidates: candidates,
                relevantKinds: useProjectFallback ? ["statusline", "projects", "config_projects"] : ["statusline"],
                snapshot: snapshot
            )
        case .gemini:
            let snapshot = await GeminiTelemetryAdapter().snapshot(settings: settings)
            return classifyFileBackedProvider(
                provider: provider,
                settings: settings,
                candidates: candidates,
                relevantKinds: ["telemetry", "tmp", "history"],
                snapshot: snapshot
            )
        case .codex:
            let roots = codexSessionRoots(from: candidates)
            let snapshot = await CodexLocalSessionAdapter(sessionRoots: roots.isEmpty ? nil : roots).snapshot(settings: settings)
            return classifyCodex(settings: settings, candidates: candidates, snapshot: snapshot)
        case .deepseek:
            return classifyDeepSeek(settings: settings)
        }
    }

    public func preferredUsablePath(in source: ProviderDataSource) -> String? {
        let preferredKinds: [String]
        switch source.provider {
        case .claude: preferredKinds = ["statusline", "projects", "config_projects"]
        case .gemini: preferredKinds = ["telemetry", "tmp", "history"]
        case .codex: preferredKinds = ["sessions", "archived_sessions", "history", "root"]
        case .deepseek: preferredKinds = []
        }

        return source.detectedPaths.first {
            preferredKinds.contains($0.kind) && $0.exists && $0.readable
        }?.path
    }

    public func applyingPreferredDetectedSources(settings: AppSettings, sources: [ProviderDataSource]) -> AutoDetectionResult {
        var next = settings
        var adopted: [Provider] = []

        for source in sources {
            guard source.isEnabled,
                  source.status != .disabled,
                  let path = preferredUsablePath(in: source) else { continue }

            switch source.provider {
            case .claude:
                if shouldAdoptDetectedPath(current: next.claudeStatusFilePath, defaultPath: AppSettings().claudeStatusFilePath, detected: path) {
                    next.claudeStatusFilePath = path
                    next.claudeStatusFileBookmarkData = nil
                    adopted.append(.claude)
                }
            case .gemini:
                if shouldAdoptDetectedPath(current: next.geminiTelemetryLogPath, defaultPath: AppSettings().geminiTelemetryLogPath, detected: path) {
                    next.geminiTelemetryLogPath = path
                    next.geminiTelemetrySourceBookmarkData = nil
                    adopted.append(.gemini)
                }
            case .codex, .deepseek:
                // Codex uses default session roots directly; DeepSeek uses Keychain/API instead of local token paths.
                continue
            }
        }

        return AutoDetectionResult(settings: next, adoptedProviders: adopted)
    }

    private func classifyFileBackedProvider(
        provider: Provider,
        settings: AppSettings,
        candidates: [ProviderPathCandidate],
        relevantKinds: Set<String>,
        snapshot: ProviderSnapshot
    ) -> ProviderDataSource {
        let configured = configuredPath(settings: settings, provider: provider)
        let fileCandidate = bestFileCandidate(provider: provider, configuredPath: configured, candidates: candidates, relevantKinds: relevantKinds)
        let now = Date()

        guard let fileCandidate, !fileCandidate.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ProviderDataSource(
                provider: provider,
                detectedPaths: candidates,
                customPath: configured,
                lastScanAt: now,
                status: .notFound,
                confidence: .low,
                statusMessage: provider == .claude ? "Claude status file not found" : "Gemini telemetry log not found"
            )
        }

        guard fileCandidate.exists else {
            return ProviderDataSource(
                provider: provider,
                detectedPaths: candidates,
                customPath: configured,
                lastScanAt: now,
                status: .notFound,
                confidence: .low,
                statusMessage: provider == .claude ? "Claude status file not found" : "Gemini telemetry log not found"
            )
        }

        guard fileCandidate.readable else {
            return ProviderDataSource(
                provider: provider,
                detectedPaths: candidates,
                customPath: configured,
                lastScanAt: now,
                status: .permissionDenied,
                confidence: .low,
                statusMessage: "File exists but cannot be read"
            )
        }

        let message = snapshot.statusMessage ?? "Connected"
        let lowered = message.lowercased()
        let status: ProviderDataSourceStatus
        if lowered.contains("invalid json") || lowered.contains("invalid format") {
            status = .invalidFormat
        } else if lowered.contains("could not be read") {
            status = .permissionDenied
        } else if lowered.contains("no rate limit data") || lowered.contains("no gemini_cli.api_response") || lowered.contains("no usable") {
            status = .noUsableData
        } else if snapshot.isStale {
            status = .stale
        } else if snapshotHasUsableData(snapshot) {
            status = .connected
        } else {
            status = .noUsableData
        }

        return ProviderDataSource(
            provider: provider,
            isEnabled: true,
            mode: configured == nil ? .auto : .custom,
            detectedPaths: candidates,
            customPath: configured,
            lastScanAt: now,
            status: status,
            confidence: snapshot.confidence,
            statusMessage: message
        )
    }

    private func classifyCodex(settings: AppSettings, candidates: [ProviderPathCandidate], snapshot: ProviderSnapshot) -> ProviderDataSource {
        let manual = settings.codexManual
        let hasPastedStatus = !manual.pastedStatusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasValues = manual.fiveHourUsagePercentage > 0 || manual.weeklyUsagePercentage > 0
        let hasReset = !manual.resetTimeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPlan = !manual.planLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && manual.planLabel.lowercased() != "manual"
        let hasNotes = !manual.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasManualData = manual.webConnectorEnabled || manual.webSnapshotEnabled || hasPastedStatus || hasValues || hasReset || hasPlan || hasNotes
        let detectedCodexPath = candidates.first { candidate in
            ["sessions", "archived_sessions", "history", "root"].contains(candidate.kind) && candidate.exists && candidate.readable
        }
        if snapshot.dataSource == .webUsage, snapshotHasUsableData(snapshot) {
            return ProviderDataSource(
                provider: .codex,
                isEnabled: settings.isProviderEnabled(.codex),
                mode: .auto,
                detectedPaths: candidates,
                customPath: nil,
                lastScanAt: Date(),
                status: .connected,
                confidence: snapshot.confidence,
                statusMessage: snapshot.statusMessage ?? "Connected · Codex limit hints"
            )
        }

        if snapshot.dataSource == .localLog, snapshotHasUsableData(snapshot) {
            return ProviderDataSource(
                provider: .codex,
                isEnabled: settings.isProviderEnabled(.codex),
                mode: .auto,
                detectedPaths: candidates,
                customPath: nil,
                lastScanAt: Date(),
                status: snapshot.isStale ? .stale : .connected,
                confidence: snapshot.confidence,
                statusMessage: snapshot.statusMessage ?? "Connected · local Codex usage"
            )
        }

        let statusMessage: String
        if hasManualData {
            statusMessage = snapshot.statusMessage ?? "Manual estimate ready (est.)"
        } else if detectedCodexPath != nil {
            statusMessage = "Codex local folder detected · no token_count rows yet"
        } else {
            statusMessage = "Manual mode · paste /status or enter estimates"
        }

        return ProviderDataSource(
            provider: .codex,
            isEnabled: settings.isProviderEnabled(.codex),
            mode: .custom,
            detectedPaths: candidates,
            customPath: nil,
            lastScanAt: Date(),
            status: hasManualData ? .estimated : (detectedCodexPath != nil ? .noUsableData : .manual),
            confidence: snapshot.confidence,
            statusMessage: statusMessage
        )
    }


    private func classifyDeepSeek(settings: AppSettings) -> ProviderDataSource {
        ProviderDataSource(
            provider: .deepseek,
            isEnabled: settings.deepseekEnabled,
            mode: settings.deepseekAPIKeyConfigured ? .auto : .custom,
            detectedPaths: [],
            customPath: nil,
            lastScanAt: Date(),
            status: settings.deepseekAPIKeyConfigured ? .connected : .manual,
            confidence: settings.deepseekAPIKeyConfigured ? .medium : .manual,
            statusMessage: settings.deepseekAPIKeyConfigured ? "API key saved in Keychain" : "API key required"
        )
    }

    private func codexSessionRoots(from candidates: [ProviderPathCandidate]) -> [URL] {
        candidates
            .filter { ["sessions", "archived_sessions"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    private func snapshotHasUsableData(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.primaryUsedPercent != nil ||
        snapshot.dailyRequestsUsed != nil ||
        snapshot.todayTokens > 0 ||
        snapshot.contextWindowUsedPercent != nil ||
        !snapshot.events.isEmpty
    }

    private func bestFileCandidate(
        provider: Provider,
        configuredPath: String?,
        candidates: [ProviderPathCandidate],
        relevantKinds: Set<String>
    ) -> ProviderPathCandidate? {
        let expandedConfigured = configuredPath.map(expandTilde)
        if let expandedConfigured,
           let configuredCandidate = candidates.first(where: { $0.path == expandedConfigured && relevantKinds.contains($0.kind) }) {
            if configuredCandidate.exists || !candidates.contains(where: { relevantKinds.contains($0.kind) && $0.exists }) {
                return configuredCandidate
            }
        }
        if let existing = candidates.first(where: { relevantKinds.contains($0.kind) && $0.exists }) {
            return existing
        }
        return candidates.first(where: { relevantKinds.contains($0.kind) })
    }

    private func pathCandidates(settings: AppSettings, provider: Provider) -> [ProviderPathCandidate] {
        var candidates: [ProviderPathCandidate] = []
        if let configured = configuredPath(settings: settings, provider: provider) {
            candidates.append(makeConfiguredCandidate(
                provider: provider,
                path: configured,
                bookmarkData: settings.localSourceBookmarkData(for: provider)
            ))
        }
        candidates.append(contentsOf: pathResolver.resolveDefaultPaths(for: provider))
        return deduplicated(candidates)
    }

    private func claudeProjectRoots(from candidates: [ProviderPathCandidate]) -> [URL] {
        candidates
            .filter { ["projects", "config_projects"].contains($0.kind) && $0.exists && $0.readable }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    private func shouldUseClaudeProjectFallback(settings: AppSettings) -> Bool {
        let configured = URL(fileURLWithPath: expandTilde(settings.claudeStatusFilePath)).standardizedFileURL.path
        let defaultPath = URL(fileURLWithPath: expandTilde(AppSettings().claudeStatusFilePath)).standardizedFileURL.path
        return configured == defaultPath || !fileManager.fileExists(atPath: configured)
    }

    private func shouldAdoptDetectedPath(current: String, defaultPath: String, detected: String) -> Bool {
        let currentTrimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let expandedCurrent = currentTrimmed.isEmpty ? "" : URL(fileURLWithPath: expandTilde(currentTrimmed)).standardizedFileURL.path
        let expandedDefault = URL(fileURLWithPath: expandTilde(defaultPath)).standardizedFileURL.path
        let expandedDetected = URL(fileURLWithPath: expandTilde(detected)).standardizedFileURL.path
        if expandedCurrent == expandedDetected { return false }
        if currentTrimmed.isEmpty { return true }
        if expandedCurrent == expandedDefault { return true }
        return !fileManager.fileExists(atPath: expandedCurrent)
    }

    private func configuredPath(settings: AppSettings, provider: Provider) -> String? {
        switch provider {
        case .claude:
            let path = settings.claudeStatusFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        case .gemini:
            let path = settings.geminiTelemetryLogPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        case .codex, .deepseek:
            return nil
        }
    }

    private func makeConfiguredCandidate(provider: Provider, path: String, bookmarkData: Data?) -> ProviderPathCandidate {
        let expanded = expandTilde(path)
        let fallbackURL = URL(fileURLWithPath: expanded)
        let scopedAccess = TokenPilotSecurityScopedBookmarks.resolveIfAvailable(bookmarkData: bookmarkData, fallbackURL: fallbackURL)
        defer { scopedAccess.stop() }
        let resolvedPath = scopedAccess.url.path
        let exists = fileManager.fileExists(atPath: resolvedPath)
        let kind: String
        switch provider {
        case .claude: kind = "statusline"
        case .gemini: kind = "telemetry"
        case .codex, .deepseek: kind = "manual"
        }
        return ProviderPathCandidate(
            provider: provider,
            kind: kind,
            path: resolvedPath,
            source: bookmarkData == nil ? "configured" : "configured-bookmark",
            exists: exists,
            readable: exists && fileManager.isReadableFile(atPath: resolvedPath),
            confidence: .high,
            notes: exists ? nil : "Configured file not found"
        )
    }

    private func deduplicated(_ candidates: [ProviderPathCandidate]) -> [ProviderPathCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = "\(candidate.provider.rawValue)|\(candidate.kind)|\(candidate.path)"
            return seen.insert(key).inserted
        }
    }
}

