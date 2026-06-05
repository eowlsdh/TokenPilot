import Foundation

public enum TokenPilotSecurityScopedBookmarkError: LocalizedError, Equatable, Sendable {
    case missingBookmarkData
    case staleBookmark

    public var errorDescription: String? {
        switch self {
        case .missingBookmarkData:
            return "Security-scoped bookmark data is missing."
        case .staleBookmark:
            return "Security-scoped bookmark is stale; choose the file or folder again."
        }
    }
}

public struct TokenPilotSecurityScopedResourceAccess: Sendable {
    public let url: URL
    private let didStartAccessing: Bool
    public let isStale: Bool

    public init(url: URL, didStartAccessing: Bool, isStale: Bool = false) {
        self.url = url
        self.didStartAccessing = didStartAccessing
        self.isStale = isStale
    }

    public func stop() {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public enum TokenPilotSecurityScopedBookmarks {
    public static func makeReadOnlyBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public static func resolve(bookmarkData: Data, fallbackPath: String? = nil) throws -> TokenPilotSecurityScopedResourceAccess {
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale, let fallbackPath {
            let fallback = URL(fileURLWithPath: fallbackPath)
            if fallback == resolvedURL {
                // Same path; stale flag is informational only.
            } else {
                return TokenPilotSecurityScopedResourceAccess(url: fallback, didStartAccessing: false, isStale: true)
            }
        }
        let didStart = resolvedURL.startAccessingSecurityScopedResource()
        return TokenPilotSecurityScopedResourceAccess(url: resolvedURL, didStartAccessing: didStart, isStale: isStale)
    }

    public static func resolveIfAvailable(bookmarkData: Data?, fallbackURL: URL) -> TokenPilotSecurityScopedResourceAccess {
        guard let bookmarkData else {
            return TokenPilotSecurityScopedResourceAccess(url: fallbackURL, didStartAccessing: false)
        }
        return (try? resolve(bookmarkData: bookmarkData, fallbackPath: fallbackURL.path))
            ?? TokenPilotSecurityScopedResourceAccess(url: fallbackURL, didStartAccessing: false)
    }
}
