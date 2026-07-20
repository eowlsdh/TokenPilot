import Darwin
import Foundation

// MARK: - Injected seams

/// Loads the fixed Grok auth descriptor bytes. Production opens only `~/.grok/auth.json`.
public protocol GrokOAuthDescriptorLoading: Sendable {
    func loadDescriptorBytes() -> Result<Data, XAIUnavailableReason>
}

/// Performs the single fixed weekly billing GET with an ephemeral access token.
public protocol GrokOAuthBillingTransporting: Sendable {
    func fetchWeeklyBilling(accessToken: String) async -> Result<(statusCode: Int, body: Data), XAIUnavailableReason>
}

// MARK: - Adapter

/// Access-token-only experimental Grok weekly observer.
/// Eligibility (consent v1 + provider enabled + not sandboxed) is evaluated before any
/// descriptor loader or HTTP transport is constructed via the injected lazy factories.
/// Generation/ticket validity is checked around descriptor and transport boundaries so
/// revoke/shutdown cannot publish a late OAuth success.
public final class GrokOAuthWeeklyUsageAdapter: XAIExperimentalWeeklyService, @unchecked Sendable {
    public static let selectedScopeKey = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
    public static let billingURLString = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    public static let maximumDescriptorBytes = 64 * 1_024
    public static let maximumBillingBodyBytes = 256 * 1_024
    public static let requestTimeout: TimeInterval = 10

    private let executionCapability: XAIExecutionCapability
    private let makeDescriptorLoader: @Sendable () -> any GrokOAuthDescriptorLoading
    private let makeTransport: @Sendable () -> any GrokOAuthBillingTransporting
    private let lock = NSLock()
    private var isShutdown = false
    private var revokedTickets: [XAIRefreshTicket] = []
    private var revokeAllActive = false

    /// Integration call signature:
    /// `GrokOAuthWeeklyUsageAdapter(executionCapability:makeDescriptorLoader:makeTransport:)`
    /// Production: `GrokOAuthWeeklyUsageAdapter()`
    /// Tests: inject lazy loader/transport factories; they must not run before eligibility.
    public init(
        executionCapability: XAIExecutionCapability = .current,
        makeDescriptorLoader: (@Sendable () -> any GrokOAuthDescriptorLoading)? = nil,
        makeTransport: (@Sendable () -> any GrokOAuthBillingTransporting)? = nil
    ) {
        self.executionCapability = executionCapability
        self.makeDescriptorLoader = makeDescriptorLoader ?? { ProductionGrokOAuthDescriptorLoader() }
        self.makeTransport = makeTransport ?? { ProductionGrokOAuthBillingTransport() }
    }

    public func refresh(_ input: XAIExperimentalWeeklyInput) async -> XAIRefreshResult {
        let now = input.now
        let settings = input.settings

        // Eligibility must short-circuit before constructing loader/transport.
        if !settings.xaiEnabled || !settings.isProviderEnabled(.xai) {
            return Self.failureResult(reason: .consentNotGranted, settings: settings, now: now)
        }
        if settings.xAI.experimentalOAuthWeeklyConsentVersion
            != XAISettings.experimentalOAuthWeeklyConsentVersionCurrent {
            return Self.failureResult(reason: .consentNotGranted, settings: settings, now: now)
        }
        if executionCapability.isSandboxed {
            return Self.failureResult(reason: .appSandboxed, settings: settings, now: now)
        }
        if !isTicketCurrent(input.ticket) {
            return Self.failureResult(reason: .staleResult, settings: settings, now: now)
        }

        let loader = makeDescriptorLoader()
        let descriptorData: Data
        switch loader.loadDescriptorBytes() {
        case .success(let data):
            descriptorData = data
        case .failure(let reason):
            return Self.failureResult(reason: reason, settings: settings, now: now)
        }

        if !isTicketCurrent(input.ticket) {
            return Self.failureResult(reason: .staleResult, settings: settings, now: now)
        }

        let accessToken: String
        switch Self.parseAccessToken(from: descriptorData, now: now) {
        case .success(let token):
            accessToken = token
        case .failure(let reason):
            return Self.failureResult(reason: reason, settings: settings, now: now)
        }

        if !isTicketCurrent(input.ticket) {
            return Self.failureResult(reason: .staleResult, settings: settings, now: now)
        }

        let transport = makeTransport()
        let billingResult = await transport.fetchWeeklyBilling(accessToken: accessToken)

        if !isTicketCurrent(input.ticket) {
            return Self.failureResult(reason: .staleResult, settings: settings, now: now)
        }

        switch billingResult {
        case .success(let response):
            return Self.result(fromBilling: response, settings: settings, now: now)
        case .failure(let reason):
            return Self.failureResult(reason: reason, settings: settings, now: now)
        }
    }

    public func revoke(ticket: XAIRefreshTicket?) async {
        lock.withLock {
            if let ticket {
                if !revokedTickets.contains(ticket) {
                    revokedTickets.append(ticket)
                }
            } else {
                revokeAllActive = true
            }
        }
    }

    public func shutdown() async {
        lock.withLock {
            isShutdown = true
            revokeAllActive = true
            revokedTickets.removeAll(keepingCapacity: false)
        }
    }

    private func isTicketCurrent(_ ticket: XAIRefreshTicket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isShutdown || revokeAllActive { return false }
        return !revokedTickets.contains(ticket)
    }
}

// MARK: - Result mapping

extension GrokOAuthWeeklyUsageAdapter {
    fileprivate static func failureResult(
        reason: XAIUnavailableReason,
        settings: AppSettings,
        now: Date
    ) -> XAIRefreshResult {
        let keys = statusAndAction(for: reason)
        let selected = fallbackSnapshot(settings: settings, now: now)
        return XAIRefreshResult(
            selectedOutcome: selected.outcome,
            selectedSnapshot: XAIProvenancedSnapshot(standard: selected.snapshot),
            oauthFailure: reason,
            statusKey: keys.statusKey,
            actionKey: keys.actionKey,
            fetchedAt: nil,
            resolvedAt: now,
            origin: .fresh,
            completion: reason == .staleResult ? .cancelledOrdinarily : .completed
        )
    }

    fileprivate static func successResult(usedPercent: Int, resetAt: Date, now: Date) -> XAIRefreshResult {
        let weekly = LimitWindow(
            kind: .weekly,
            usedPercent: usedPercent,
            resetAt: resetAt,
            confidence: .low
        )
        let snapshot = ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            weekly: weekly,
            confidence: .low,
            dataSource: .experimentalCLI,
            isExperimental: true,
            isStale: false
        )
        return XAIRefreshResult(
            selectedOutcome: .oauthWeekly,
            selectedSnapshot: XAIProvenancedSnapshot(
                experimentalOAuthWeekly: snapshot,
                capability: .owned
            ),
            oauthFailure: nil,
            statusKey: "xai.oauth.status.experimental_weekly",
            actionKey: "xai.oauth.action.disable_or_refresh",
            fetchedAt: now,
            resolvedAt: now,
            origin: .fresh,
            completion: .completed
        )
    }

    /// Failure presentation precedence: manual weekly > neutral.
    /// Local signals remain owned by the standard GrokLocalSignalsAdapter path and are never
    /// merged into this OAuth presentation result (OAuth stays presentation-only).
    fileprivate static func fallbackSnapshot(
        settings: AppSettings,
        now: Date
    ) -> (outcome: XAISelectedOutcome, snapshot: ProviderSnapshot) {
        if settings.xAI.weeklySnapshotEnabled {
            let used = min(max(100 - settings.xAI.weeklyRemainingPercent, 0), 100)
            let weekly = LimitWindow(
                kind: .weekly,
                usedPercent: used,
                resetAt: nil,
                confidence: .manual
            )
            let snapshot = ProviderSnapshot(
                provider: .xai,
                updatedAt: now,
                weekly: weekly,
                confidence: .manual,
                dataSource: .manual,
                isExperimental: false,
                isStale: false
            )
            return (.manualWeekly, snapshot)
        }
        return (.neutral, neutralSnapshot(now: now))
    }

    fileprivate static func neutralSnapshot(now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .xai,
            updatedAt: now,
            confidence: .low,
            dataSource: .unknown,
            isExperimental: false,
            isStale: false
        )
    }

    fileprivate static func statusAndAction(for reason: XAIUnavailableReason) -> (statusKey: String, actionKey: String) {
        switch reason {
        case .consentNotGranted:
            return ("xai.oauth.status.consent_off", "xai.oauth.action.enable_consent")
        case .appSandboxed:
            return ("xai.oauth.status.sandbox_unavailable", "xai.oauth.action.use_manual_or_local")
        case .settingsPersistenceFailed:
            return ("xai.oauth.status.unavailable", "xai.oauth.action.refresh")
        case .descriptorNotFound:
            return ("xai.oauth.status.descriptor_unavailable", "xai.oauth.action.use_manual_or_local")
        case .descriptorPermissionDenied:
            return ("xai.oauth.status.descriptor_permission", "xai.oauth.action.review_local_permissions")
        case .descriptorUnsafe:
            return ("xai.oauth.status.descriptor_unsafe", "xai.oauth.action.review_local_permissions")
        case .descriptorRace:
            return ("xai.oauth.status.descriptor_changed", "xai.oauth.action.refresh")
        case .descriptorTooLarge:
            return ("xai.oauth.status.descriptor_invalid", "xai.oauth.action.use_manual_or_local")
        case .descriptorMalformed:
            return ("xai.oauth.status.descriptor_invalid", "xai.oauth.action.use_manual_or_local")
        case .selectedScopeMissing, .selectedScopeDuplicate, .selectedFieldDuplicate, .selectedFieldWrongType, .selectedAuthContractMismatch:
            return ("xai.oauth.status.schema_unavailable", "xai.oauth.action.use_manual_or_local")
        case .credentialExpired, .billingHTTP401, .billingHTTP403:
            return ("xai.oauth.status.login_required", "xai.oauth.action.run_grok_login")
        case .billingHTTP429:
            return ("xai.oauth.status.rate_limited", "xai.oauth.action.wait_and_refresh")
        case .billingHTTPOther:
            return ("xai.oauth.status.request_unavailable", "xai.oauth.action.refresh_later")
        case .billingTimeout:
            return ("xai.oauth.status.network_timeout", "xai.oauth.action.check_network_and_refresh")
        case .billingNetwork:
            return ("xai.oauth.status.network_unavailable", "xai.oauth.action.check_network_and_refresh")
        case .billingCancelled:
            return ("xai.oauth.status.cancelled", "xai.oauth.action.refresh")
        case .billingResponseTooLarge, .billingDTOInvalid:
            return ("xai.oauth.status.response_invalid", "xai.oauth.action.refresh_later")
        case .staleResult:
            return ("xai.oauth.status.unavailable", "xai.oauth.action.refresh")
        }
    }

    fileprivate static func result(
        fromBilling response: (statusCode: Int, body: Data),
        settings: AppSettings,
        now: Date
    ) -> XAIRefreshResult {
        switch response.statusCode {
        case 200:
            switch parseBillingDTO(response.body, now: now) {
            case .success(let parsed):
                return successResult(usedPercent: parsed.usedPercent, resetAt: parsed.resetAt, now: now)
            case .failure(let reason):
                return failureResult(reason: reason, settings: settings, now: now)
            }
        case 401:
            return failureResult(reason: .billingHTTP401, settings: settings, now: now)
        case 403:
            return failureResult(reason: .billingHTTP403, settings: settings, now: now)
        case 429:
            return failureResult(reason: .billingHTTP429, settings: settings, now: now)
        default:
            return failureResult(reason: .billingHTTPOther, settings: settings, now: now)
        }
    }
}

// MARK: - Descriptor parse (access token only)

extension GrokOAuthWeeklyUsageAdapter {
    /// Parses only the fixed scope entry. Refresh/identity members are ignored without materialization.
    fileprivate static func parseAccessToken(from data: Data, now: Date) -> Result<String, XAIUnavailableReason> {
        guard !data.isEmpty, data.count <= maximumDescriptorBytes else {
            return .failure(data.isEmpty ? .descriptorMalformed : .descriptorTooLarge)
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.descriptorMalformed)
        }

        guard let root = object as? [String: Any] else {
            return .failure(.descriptorMalformed)
        }
        guard root.count <= 32 else {
            return .failure(.descriptorMalformed)
        }
        for key in root.keys where key.count > 64 {
            return .failure(.descriptorMalformed)
        }

        guard let scopeValue = root[selectedScopeKey] else {
            return .failure(.selectedScopeMissing)
        }
        guard let scope = scopeValue as? [String: Any] else {
            return .failure(.selectedFieldWrongType)
        }
        if scope.keys.contains(where: { $0.count > 64 }) {
            return .failure(.descriptorMalformed)
        }

        // Access token field: `access_token` (assignment) or `key` (auth-map contract).
        let hasAccessToken = scope["access_token"] != nil
        let hasKey = scope["key"] != nil
        if hasAccessToken && hasKey {
            return .failure(.selectedFieldDuplicate)
        }
        let tokenRaw: Any?
        if hasAccessToken {
            tokenRaw = scope["access_token"]
        } else if hasKey {
            tokenRaw = scope["key"]
        } else {
            return .failure(.selectedAuthContractMismatch)
        }
        guard let tokenString = tokenRaw as? String else {
            return .failure(.selectedFieldWrongType)
        }
        let accessToken = tokenString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...8_192).contains(accessToken.utf8.count) else {
            return .failure(.selectedAuthContractMismatch)
        }

        guard let authMode = scope["auth_mode"] as? String,
              authMode == "oidc",
              let issuer = scope["oidc_issuer"] as? String,
              issuer == "https://auth.x.ai",
              let clientID = scope["oidc_client_id"] as? String,
              clientID == "b1a00492-073a-47ea-816f-4c329264a828" else {
            return .failure(.selectedAuthContractMismatch)
        }

        guard let expiresRaw = scope["expires_at"] else {
            return .failure(.credentialExpired)
        }
        guard let expiresString = expiresRaw as? String else {
            return .failure(.selectedFieldWrongType)
        }
        let trimmedExpiry = expiresString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(trimmedExpiry.utf8.count),
              let expiresAt = parseStrictFutureZTimestamp(trimmedExpiry),
              expiresAt > now else {
            return .failure(.credentialExpired)
        }

        // Intentionally ignore refresh_token, identity, principal, user, organization, profile.
        return .success(accessToken)
    }

    /// Strict RFC3339 / ISO-8601 timestamp ending with `Z` (UTC).
    fileprivate static func parseStrictFutureZTimestamp(_ value: String) -> Date? {
        guard value.hasSuffix("Z") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

// MARK: - Billing DTO

extension GrokOAuthWeeklyUsageAdapter {
    fileprivate struct ParsedWeeklyUsage: Sendable {
        let usedPercent: Int
        let resetAt: Date
    }

    fileprivate static func parseBillingDTO(_ data: Data, now: Date) -> Result<ParsedWeeklyUsage, XAIUnavailableReason> {
        guard data.count <= maximumBillingBodyBytes else {
            return .failure(.billingResponseTooLarge)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.billingDTOInvalid)
        }
        guard let root = object as? [String: Any] else {
            return .failure(.billingDTOInvalid)
        }

        guard let config = root["config"] as? [String: Any],
              let isUnified = boolValue(config["isUnifiedBillingUser"]),
              isUnified else {
            return .failure(.billingDTOInvalid)
        }

        guard let period = root["currentPeriod"] as? [String: Any] else {
            return .failure(.billingDTOInvalid)
        }
        guard let type = period["type"] as? String,
              type == "USAGE_PERIOD_TYPE_WEEKLY" else {
            return .failure(.billingDTOInvalid)
        }

        guard let startString = period["start"] as? String,
              let endString = period["end"] as? String,
              let start = parseStrictFutureZTimestamp(startString) ?? parseLooseISO8601(startString),
              let end = parseStrictFutureZTimestamp(endString) ?? parseLooseISO8601(endString),
              start < now,
              now < end else {
            return .failure(.billingDTOInvalid)
        }

        let duration = end.timeIntervalSince(start)
        let minDuration: TimeInterval = (6 * 24 * 60 * 60) + (23 * 60 * 60) // 6d23h
        let maxDuration: TimeInterval = (7 * 24 * 60 * 60) + (1 * 60 * 60)  // 7d1h
        guard duration >= minDuration, duration <= maxDuration else {
            return .failure(.billingDTOInvalid)
        }

        guard let percent = doubleValue(root["creditUsagePercent"] ?? period["creditUsagePercent"]),
              percent.isFinite,
              percent >= 0,
              percent <= 100 else {
            return .failure(.billingDTOInvalid)
        }
        let used = min(max(Int(percent.rounded(.toNearestOrAwayFromZero)), 0), 100)
        return .success(ParsedWeeklyUsage(usedPercent: used, resetAt: end))
    }

    fileprivate static func parseLooseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    fileprivate static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    fileprivate static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

// MARK: - Production descriptor loader

/// Opens only the fixed current-user-home path `~/.grok/auth.json`.
/// Rejects symlink / non-regular / wrong owner / group-or-other access bits / >64 KiB.
public struct ProductionGrokOAuthDescriptorLoader: GrokOAuthDescriptorLoading, Sendable {
    public init() {}

    public func loadDescriptorBytes() -> Result<Data, XAIUnavailableReason> {
        #if os(macOS)
        return loadViaDarwin()
        #else
        return .failure(.descriptorUnsafe)
        #endif
    }

    #if os(macOS)
    private func loadViaDarwin() -> Result<Data, XAIUnavailableReason> {
        let homePath = NSHomeDirectory()
        guard !homePath.isEmpty else { return .failure(.descriptorNotFound) }

        let homeFD = open(homePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard homeFD >= 0 else { return .failure(mapOpenErrno(errno)) }
        defer { close(homeFD) }

        if case let .failure(reason) = validateDirectoryFD(homeFD) {
            return .failure(reason)
        }

        let grokFD = openat(homeFD, ".grok", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard grokFD >= 0 else { return .failure(mapOpenErrno(errno)) }
        defer { close(grokFD) }

        if case let .failure(reason) = validateDirectoryFD(grokFD) {
            return .failure(reason)
        }

        var preStat = stat()
        guard fstatat(grokFD, "auth.json", &preStat, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .failure(mapOpenErrno(errno))
        }
        if (preStat.st_mode & S_IFMT) == S_IFLNK {
            return .failure(.descriptorUnsafe)
        }
        guard (preStat.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.descriptorUnsafe)
        }
        if preStat.st_uid != geteuid() {
            return .failure(.descriptorPermissionDenied)
        }
        if (preStat.st_mode & 0o077) != 0 {
            return .failure(.descriptorPermissionDenied)
        }
        if preStat.st_size < 0 || preStat.st_size > off_t(GrokOAuthWeeklyUsageAdapter.maximumDescriptorBytes) {
            return .failure(.descriptorTooLarge)
        }

        let leafFD = openat(grokFD, "auth.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard leafFD >= 0 else { return .failure(mapOpenErrno(errno)) }
        defer { close(leafFD) }

        var postStat = stat()
        guard fstat(leafFD, &postStat) == 0 else { return .failure(mapOpenErrno(errno)) }
        guard postStat.st_dev == preStat.st_dev, postStat.st_ino == preStat.st_ino else {
            return .failure(.descriptorRace)
        }
        guard (postStat.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.descriptorUnsafe)
        }
        if postStat.st_uid != geteuid() {
            return .failure(.descriptorPermissionDenied)
        }
        if (postStat.st_mode & 0o077) != 0 {
            return .failure(.descriptorPermissionDenied)
        }
        if postStat.st_size < 0 || postStat.st_size > off_t(GrokOAuthWeeklyUsageAdapter.maximumDescriptorBytes) {
            return .failure(.descriptorTooLarge)
        }

        let maxBytes = GrokOAuthWeeklyUsageAdapter.maximumDescriptorBytes
        if lseek(leafFD, off_t(maxBytes), SEEK_SET) == off_t(maxBytes) {
            var probe: UInt8 = 0
            let probeRead = read(leafFD, &probe, 1)
            if probeRead > 0 { return .failure(.descriptorTooLarge) }
            if probeRead < 0 { return .failure(mapOpenErrno(errno)) }
        }
        guard lseek(leafFD, 0, SEEK_SET) == 0 else { return .failure(mapOpenErrno(errno)) }

        var buffer = Data(count: maxBytes)
        let total: Int = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            var offset = 0
            while offset < maxBytes {
                let n = read(leafFD, base.advanced(by: offset), maxBytes - offset)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += n
            }
            if offset == maxBytes {
                var extra: UInt8 = 0
                let more = read(leafFD, &extra, 1)
                if more > 0 { return -2 }
            }
            return offset
        }
        if total == -2 { return .failure(.descriptorTooLarge) }
        if total < 0 { return .failure(mapOpenErrno(errno)) }
        if total == 0 { return .failure(.descriptorMalformed) }

        var finalStat = stat()
        guard fstat(leafFD, &finalStat) == 0 else { return .failure(mapOpenErrno(errno)) }
        guard finalStat.st_dev == preStat.st_dev, finalStat.st_ino == preStat.st_ino else {
            return .failure(.descriptorRace)
        }

        buffer.count = total
        return .success(buffer)
    }

    private func validateDirectoryFD(_ fd: Int32) -> Result<Void, XAIUnavailableReason> {
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return .failure(mapOpenErrno(errno))
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(.descriptorUnsafe)
        }
        if st.st_uid != geteuid() {
            return .failure(.descriptorPermissionDenied)
        }
        if (st.st_mode & 0o022) != 0 {
            return .failure(.descriptorPermissionDenied)
        }
        return .success(())
    }

    private func mapOpenErrno(_ code: Int32) -> XAIUnavailableReason {
        switch code {
        case ENOENT:
            return .descriptorNotFound
        case EACCES, EPERM:
            return .descriptorPermissionDenied
        case ELOOP, ENOTDIR:
            return .descriptorUnsafe
        default:
            return .descriptorPermissionDenied
        }
    }
    #endif
}

// MARK: - Production transport

/// One ephemeral GET to the fixed billing URL. No redirects, cookies, cache, credentials, or retry.
public struct ProductionGrokOAuthBillingTransport: GrokOAuthBillingTransporting, Sendable {
    public init() {}

    public func fetchWeeklyBilling(accessToken: String) async -> Result<(statusCode: Int, body: Data), XAIUnavailableReason> {
        guard let url = URL(string: GrokOAuthWeeklyUsageAdapter.billingURLString) else {
            return .failure(.billingNetwork)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForRequest = GrokOAuthWeeklyUsageAdapter.requestTimeout
        configuration.timeoutIntervalForResource = GrokOAuthWeeklyUsageAdapter.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = nil

        let delegate = GrokOAuthBillingSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: GrokOAuthWeeklyUsageAdapter.requestTimeout
        )
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.billingNetwork)
            }
            if http.expectedContentLength > Int64(GrokOAuthWeeklyUsageAdapter.maximumBillingBodyBytes) {
                return .failure(.billingResponseTooLarge)
            }

            var body = Data()
            body.reserveCapacity(min(GrokOAuthWeeklyUsageAdapter.maximumBillingBodyBytes, 4_096))
            for try await byte in bytes {
                body.append(byte)
                if body.count > GrokOAuthWeeklyUsageAdapter.maximumBillingBodyBytes {
                    return .failure(.billingResponseTooLarge)
                }
            }
            return .success((statusCode: http.statusCode, body: body))
        } catch is CancellationError {
            return .failure(.billingCancelled)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                return .failure(.billingTimeout)
            case .cancelled:
                return .failure(.billingCancelled)
            default:
                return .failure(.billingNetwork)
            }
        } catch {
            return .failure(.billingNetwork)
        }
    }
}

/// Cancels every redirect; accepts only default server-trust for the fixed host:443.
private final class GrokOAuthBillingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let fixedHost = "cli-chat-proxy.grok.com"

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.previousFailureCount == 0,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == Self.fixedHost,
              challenge.protectionSpace.port == 443,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
