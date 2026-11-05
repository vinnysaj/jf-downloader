#if !os(tvOS)
import Foundation

/// Where a transcoded download's pieces are kept and how they become one file.
///
/// The file being built is the job's partial file, as for any download: the init segment, then
/// the pieces appended in order. `Transcodes/<job>/` beside it holds the server's playlist, a
/// copy of the init segment to compare a restarted transcode's with, and pieces that arrived
/// before the ones ahead of them. Once every piece is in, the partial file is indexed in place
/// as an ordinary MP4 (`FlattenedMP4`), which is what's published; a check that fails takes the
/// index out again, leaving the pieces as they came.
nonisolated extension DownloadStorage {
    var transcodes: URL { root.appending(path: "Transcodes", directoryHint: .isDirectory) }

    func transcodeFolder(for jobId: UUID) -> URL {
        transcodes.appending(path: jobId.uuidString, directoryHint: .isDirectory)
    }

    func playlistFile(for jobId: UUID) -> URL { transcodeFolder(for: jobId).appending(path: "main.m3u8") }
    func initFile(for jobId: UUID) -> URL { transcodeFolder(for: jobId).appending(path: "init.mp4") }

    func segmentFile(_ index: Int, for jobId: UUID) -> URL {
        transcodeFolder(for: jobId).appending(path: "\(index).m4s")
    }

    /// The pieces in the file's first `length` bytes, from their box and fragment headers
    /// alone, for their timing.
    func transcodedPieces(for jobId: UUID, header: FragmentedMP4.Header, length: Int64) throws -> [FragmentedMP4.Piece] {
        let handle = try FileHandle(forReadingFrom: partialFile(for: jobId))
        defer { try? handle.close() }
        return try FragmentedMP4.outlines(count: Int(length), from: Int(header.length), header: header) { range in
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let data = try handle.read(upToCount: range.count) ?? Data()
            guard data.count == range.count else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
    }

    /// Cuts the file back to its first `length` bytes.
    func truncateTranscodedFile(for jobId: UUID, to length: Int64) throws {
        let handle = try FileHandle(forWritingTo: partialFile(for: jobId))
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
        try handle.synchronize()
    }

    func savePlaylist(_ text: String, for jobId: UUID) throws {
        try FileManager.default.createDirectory(at: transcodeFolder(for: jobId), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: playlistFile(for: jobId), options: .atomic)
    }

    func loadPlaylist(for jobId: UUID) throws -> HLSPlaylist {
        HLSPlaylist(try String(contentsOf: playlistFile(for: jobId), encoding: .utf8))
    }

    /// Starts the file with the init segment, keeping a copy to compare later ones with.
    func beginTranscodedFile(header: Data, for jobId: UUID) throws {
        try FileManager.default.createDirectory(at: transcodeFolder(for: jobId), withIntermediateDirectories: true)
        try header.write(to: initFile(for: jobId), options: .atomic)
        try header.write(to: partialFile(for: jobId), options: .atomic)
    }

    func savedHeader(for jobId: UUID) throws -> Data {
        try Data(contentsOf: initFile(for: jobId))
    }

    /// Keeps a piece that came early beside the file, over any older copy.
    func keepSegment(_ staged: URL, _ index: Int, for jobId: UUID) throws {
        let file = segmentFile(index, for: jobId)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: staged, to: file)
    }

    func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Appends pieces kept beside the file, in the order given, to the file, which first loses
    /// anything past `length`, the bytes it's known to hold: a piece appended by a run that ended
    /// before it could say so goes again. Returns the file's new length. The pieces stay until
    /// the job records them as appended (`removeSegments`).
    @concurrent
    func appendSegments(_ indices: [Int], for jobId: UUID, after length: Int64) async throws -> Int64 {
        let handle = try FileHandle(forWritingTo: partialFile(for: jobId))
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
        try handle.seekToEnd()
        for index in indices {
            let input = try FileHandle(forReadingFrom: segmentFile(index, for: jobId))
            defer { try? input.close() }
            while let block = try input.read(upToCount: 4 << 20), !block.isEmpty {
                try handle.write(contentsOf: block)
            }
        }
        try handle.synchronize()
        return Int64(try handle.offset())
    }

    /// Deletes pieces kept beside the file.
    func removeSegments(_ indices: some Sequence<Int>, for jobId: UUID) throws {
        for index in indices {
            let file = segmentFile(index, for: jobId)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    /// Puts a piece fetched again in place of the bytes `range` of the file, by writing the file
    /// anew: the part before, the piece, the part after. Returns the file's new length.
    @concurrent
    func replaceSegment(_ index: Int, for jobId: UUID, at range: Range<Int64>) async throws -> Int64 {
        let file = partialFile(for: jobId)
        let rebuilt = transcodeFolder(for: jobId).appending(path: "rebuilt.part")
        let manager = FileManager.default
        if manager.fileExists(atPath: rebuilt.path) { try manager.removeItem(at: rebuilt) }
        guard manager.createFile(atPath: rebuilt.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: rebuilt.path])
        }
        let output = try FileHandle(forWritingTo: rebuilt)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        func copy(from handle: FileHandle, count: Int64?) throws {
            var left = count ?? .max
            while left > 0, let block = try handle.read(upToCount: Int(min(left, 4 << 20))), !block.isEmpty {
                try output.write(contentsOf: block)
                left -= Int64(block.count)
            }
        }
        try copy(from: input, count: range.lowerBound)
        let piece = try FileHandle(forReadingFrom: segmentFile(index, for: jobId))
        defer { try? piece.close() }
        try copy(from: piece, count: nil)
        try input.seek(toOffset: UInt64(range.upperBound))
        try copy(from: input, count: nil)
        try output.synchronize()
        let length = Int64(try output.offset())
        _ = try manager.replaceItemAt(file, withItemAt: rebuilt)
        return length
    }

    /// The bytes a transcoded download holds beside its file: the init copy and the early pieces.
    func transcodeSideBytes(for jobId: UUID) -> Int64 {
        let folder = transcodeFolder(for: jobId)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "m4s" || $0.lastPathComponent == "init.mp4" }.reduce(0) { $0 + size(of: $1) }
    }

    func removeTranscodeFiles(for jobId: UUID) throws {
        let folder = transcodeFolder(for: jobId)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}
#endif
