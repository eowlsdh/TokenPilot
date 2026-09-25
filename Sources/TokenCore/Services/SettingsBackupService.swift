import Foundation
import os

public enum SettingsBackupError: Error, Equatable, Sendable, LocalizedError {
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "The settings backup file could not be read."
        }
    }
}

/// Exports/imports `AppSettings` as JSON for backup or machine migration.
///
/// Benchmarked against toktrack/codeburn settings-file workflows. Actual
/// credentials (bot tokens, webhooks, DeepSeek/xAI API keys) live in the
/// Keychain and are never part of `AppSettings`, so they are inherently
/// excluded from the backup. Fields that must never leave the device per the
/// export policy — such as the Telegram chat ID — are scrubbed on export.
public struct SettingsBackupService: Sendable {
    public init() {}

    /// Serializes settings for backup with export-policy scrubbing applied.
    ///
    /// The Telegram chat ID is blanked because it is an identifier that must
    /// not appear in export payloads; every other field round-trips.
    public func exportData(settings: AppSettings) throws -> Data {
        var scrubbed = settings
        scrubbed.telegram.chatID = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(scrubbed)
    }

    /// Decodes settings from a backup payload, normalizing legacy/missing
    /// fields through `AppSettings`'s own decoder.
    public func importSettings(from data: Data) throws -> AppSettings {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            throw SettingsBackupError.invalidPayload
        }
    }
}
