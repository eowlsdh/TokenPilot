import Foundation

/// Small, fast-to-read capacity snapshot for the `statusline` command.
///
/// An editor status line runs on every prompt, so it cannot afford to decode the
/// capacity evidence store (megabytes of retained history, roughly half a second
/// on a real machine). The app writes the handful of fields a status line needs
/// after each refresh; the CLI reads this file and only falls back to the full
/// evidence store when the file is missing, unreadable, or from a newer schema.
///
/// The payload holds provider ids, window ids, percentages, and timestamps —
/// no paths, project labels, session identifiers, or credentials.
public struct StatuslineSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let windows: [StatuslineCapacityWindow]

    public init(generatedAt: Date, windows: [StatuslineCapacityWindow], schemaVersion: Int = StatuslineSnapshot.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.windows = windows
    }
}

public struct StatuslineSnapshotStore: Sendable {
    private let fileURL: URL

    public init(directory: URL? = nil, fileName: String = "statusline-snapshot-v1.json") {
        let directory = directory ?? StatuslineSnapshotStore.defaultDirectory()
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("TokenPilot", isDirectory: true)
    }

    /// Writes the snapshot atomically. Best effort: a status line hint is never worth failing a refresh over.
    @discardableResult
    public func save(_ snapshot: StatuslineSnapshot) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Returns the stored snapshot, or nil when it is absent, unreadable, or written by a newer schema.
    public func load() -> StatuslineSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(StatuslineSnapshot.self, from: data) else { return nil }
        guard snapshot.schemaVersion == StatuslineSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }
}
