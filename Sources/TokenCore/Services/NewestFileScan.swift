import Foundation

/// Picks the most recently modified files under a set of roots.
///
/// The obvious shape — walk until a cap, then sort what you collected by modification date —
/// sorts an arbitrary slice of the tree instead of the tree. Codex partitions its sessions as
/// `sessions/YYYY/MM/DD`, so on a machine with 456 session files the walk filled its 96-entry cap
/// with April and June, never examined the 188 files from July and August, and the adapter then
/// discarded everything it had held for being older than its 45-day retention window. Codex
/// reported no usage at all, and nothing on screen said why.
///
/// Knowing which files are newest means looking at every candidate, so this examines them all and
/// keeps only `limit` of them in memory.
enum NewestFileScan {
    /// Ceiling on directory entries examined per scan. Far above what any assistant writes; it
    /// exists so a pathological tree cannot stall a refresh. `Result.truncated` reports when it was
    /// reached, so a caller can say so rather than quietly under-report.
    static let examinationCeiling = 50_000

    struct Result {
        let files: [URL]
        /// True when the examination ceiling cut the scan short, so `files` may not be the newest.
        let truncated: Bool
    }

    /// - Parameters:
    ///   - limit: how many files to return, newest first.
    ///   - isEligible: called for every regular file found; return false to skip it. Credential
    ///     filters belong here so a rejected file is never opened, stat'd for ranking, or returned.
    static func newestFiles(
        in roots: [URL],
        limit: Int,
        isEligible: (URL) -> Bool
    ) -> Result {
        let limit = max(limit, 1)
        // Kept sorted newest-first and never longer than `limit`, so memory is bounded by the
        // caller's appetite rather than by the size of the tree.
        var newest: [(url: URL, modified: Date)] = []
        var examined = 0
        var truncated = false

        func consider(_ url: URL, modified: Date) {
            if newest.count >= limit, let oldestKept = newest.last, modified <= oldestKept.modified {
                return
            }
            let insertionIndex = newest.firstIndex { modified > $0.modified } ?? newest.count
            newest.insert((url, modified), at: insertionIndex)
            if newest.count > limit {
                newest.removeLast()
            }
        }

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }

            if !isDirectory(root) {
                guard isEligible(root) else { continue }
                consider(root, modified: modificationDate(of: root))
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                examined += 1
                if examined > examinationCeiling {
                    truncated = true
                    break
                }
                guard isRegularFile(url), isEligible(url) else { continue }
                consider(url, modified: modificationDate(of: url))
            }
        }

        return Result(files: newest.map(\.url), truncated: truncated)
    }

    /// Reads the date the enumerator already prefetched, so ranking costs no extra stat per file.
    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
