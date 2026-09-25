import Foundation
import os

/// Reads append-only JSONL files incrementally: each file is streamed once, and later refreshes
/// read only the bytes appended since.
///
/// Claude Code session files were read through a 4 MB tail. On a real machine four of nine recent
/// sessions were larger than that — the largest 117 MB — so most of a long session never counted,
/// and the menu bar's Claude "today" figure, which reads the adapter directly, undercounted any day
/// that wrote more than 4 MB. Re-reading 117 MB on every refresh would trade that for a CPU problem;
/// remembering where each file was read to trades it for nothing.
final class IncrementalJSONLReader<Parsed: Sendable>: @unchecked Sendable {
    private struct FileState {
        var inode: UInt64
        var offset: UInt64
        var parsed: [Parsed]
    }

    private let lock = OSAllocatedUnfairLock()
    private var states: [URL: FileState] = [:]
    /// Lines without this fragment are skipped before any JSON decoding. Most bytes in a Claude
    /// session are tool output on lines that carry no usage.
    private let requiredFragment: Data
    private let maxLineBytes: Int

    init(requiredFragment: String, maxLineBytes: Int = 4 * 1_024 * 1_024) {
        self.requiredFragment = Data(requiredFragment.utf8)
        self.maxLineBytes = maxLineBytes
    }

    /// Everything parsed from `file` so far, after reading whatever was appended since last time.
    /// A file that was replaced (a new inode) or truncated (smaller than what was read) is read
    /// again from the start.
    func parsed(
        _ file: URL,
        keep: (Parsed) -> Bool,
        parse: (String) -> Parsed?
    ) -> [Parsed] {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: file.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var state = lock.withLock { states[file] } ?? FileState(inode: inode, offset: 0, parsed: [])
        if size < state.offset || inode != state.inode {
            state = FileState(inode: inode, offset: 0, parsed: [])
        }
        if size > state.offset, let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            state.offset = readCompleteLines(from: handle, startingAt: state.offset) { line in
                if let value = parse(line) { state.parsed.append(value) }
            }
        }
        state.parsed.removeAll { !keep($0) }
        let settled = state
        lock.withLock { states[file] = settled }
        return settled.parsed
    }

    /// Drops files that are no longer candidates, so memory follows the scanned set.
    func retainOnly(_ files: Set<URL>) {
        lock.withLock { states = states.filter { files.contains($0.key) } }
    }

    /// Streams from `offset` in chunks and hands over each complete line. Returns the offset just
    /// past the last newline, so a line still being written is picked up whole next time.
    private func readCompleteLines(from handle: FileHandle, startingAt offset: UInt64, _ handleLine: (String) -> Void) -> UInt64 {
        guard (try? handle.seek(toOffset: offset)) != nil else { return offset }
        let newline = UInt8(ascii: "\n")
        var consumed = offset
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newlineIndex = buffer[lineStart...].firstIndex(of: newline) {
                let line = buffer[lineStart..<newlineIndex]
                if line.count <= maxLineBytes, line.range(of: requiredFragment) != nil,
                   let text = String(data: line, encoding: .utf8) {
                    handleLine(text)
                }
                consumed += UInt64(newlineIndex - lineStart + 1)
                lineStart = buffer.index(after: newlineIndex)
            }
            buffer = Data(buffer[lineStart...])
        }
        // A last line with no newline yet is either still being written or simply unterminated.
        // A partial write cannot be a complete JSON object, so one that parses is taken now;
        // anything else waits for the rest of its bytes.
        if !buffer.isEmpty, buffer.count <= maxLineBytes,
           (try? JSONSerialization.jsonObject(with: buffer)) != nil {
            if buffer.range(of: requiredFragment) != nil, let text = String(data: buffer, encoding: .utf8) {
                handleLine(text)
            }
            consumed += UInt64(buffer.count)
        }
        return consumed
    }
}
