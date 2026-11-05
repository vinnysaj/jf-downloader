#if !os(tvOS)
import Foundation

/// Where downloads live on disk.
///
/// - `finished` holds finished files: `Documents/`, which the Files app shows as
///   "On My iPhone › vinnyfin", or on the Mac `~/Downloads/vinnyfin`.
/// - `Library/Application Support/Downloads/` holds the job list and the partial files, out of
///   the Files app's sight and out of backups.
/// - `…/Downloads/Artwork/` holds each downloaded item's pictures, for browsing offline.
/// - `…/Downloads/Extras/<job>/` holds a download's scrub previews and chapter pictures; its
///   subtitle files sit beside the finished file (`DownloadExtras`).
/// - `…/Downloads/Staging/` holds bodies the session delegate moved out of the system's
///   temporary location, until they are written into their partial file.
nonisolated struct DownloadStorage: Sendable {
    let finished: URL
    let root: URL

    var jobsFile: URL { root.appending(path: "jobs.json") }
    /// The transfers last handed to the session, by tag.
    var handedOutFile: URL { root.appending(path: "handed-out.json") }
    var partials: URL { root.appending(path: "Partials", directoryHint: .isDirectory) }
    var staging: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }
    var artwork: URL { root.appending(path: "Artwork", directoryHint: .isDirectory) }
    var extras: URL { root.appending(path: "Extras", directoryHint: .isDirectory) }
    /// Resume points of ranges set aside, one file per range. A whole-file transfer's sits beside
    /// its partial file (`resumeDataFile`).
    var held: URL { root.appending(path: "Held", directoryHint: .isDirectory) }

    static let standard = DownloadStorage(
        finished: finishedFolder,
        root: URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    )

    #if os(macOS)
    /// The real Downloads folder rather than the sandbox container's link to it, so Finder
    /// shows the path people know.
    private static let finishedFolder = URL.downloadsDirectory.resolvingSymlinksInPath()
        .appending(path: "vinnyfin", directoryHint: .isDirectory)
    #else
    private static let finishedFolder = URL.documentsDirectory
    #endif

    func prepare() throws {
        let manager = FileManager.default
        for directory in [finished, partials, staging, artwork, extras, held] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var root = root
        try root.setResourceValues(excluded)
    }

    func partialFile(for jobId: UUID) -> URL {
        partials.appending(path: "\(jobId.uuidString).part")
    }

    /// Gives back the room a job's partial file takes outside the ranges recorded in it as done
    /// (`kept`): what a chunk wrote before writing it failed partway, as when the device ran out
    /// of room or the app was killed. Those ranges are planned again, and the room downloads take
    /// is counted by the ranges recorded (`DownloadJob.bytesSoFar`), so that counts it right. Each
    /// stretch shrinks to whole blocks, as only those can be given back, so the bytes of the
    /// ranges either side stay.
    func releaseUnrecorded(in jobId: UUID, keeping kept: ByteRanges) throws {
        let partial = partialFile(for: jobId)
        guard FileManager.default.fileExists(atPath: partial.path) else { return }
        let handle = try FileHandle(forWritingTo: partial)
        let released = Result { try Self.punchHoles(in: handle.fileDescriptor, keeping: kept) }
        try handle.close()
        try released.get()
    }

    private static func punchHoles(in descriptor: Int32, keeping kept: ByteRanges) throws {
        func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw failure() }
        let block = Int64(status.st_blksize)
        let end = Int64(status.st_size)
        var start: Int64 = 0
        for range in kept.ranges + [end..<end] {
            let low = (start + block - 1) / block * block
            let high = min(range.lowerBound, end) / block * block
            start = max(start, range.upperBound)
            guard high > low else { continue }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(low), fp_length: off_t(high - low))
            guard fcntl(descriptor, F_PUNCHHOLE, &hole) == 0 else { throw failure() }
        }
    }

    func resumeDataFile(for jobId: UUID) -> URL {
        partials.appending(path: "\(jobId.uuidString).resume")
    }

    // MARK: Artwork

    func artworkFile(itemId: String, kind: JellyfinClient.ImageKind) -> URL {
        artwork.appending(path: "\(itemId)-\(kind.rawValue).jpg")
    }

    /// Deletes the saved artwork of every item and show but those `kept`: an item's own pictures
    /// and a show's poster are saved under their ids (`artworkFile`).
    func removeArtwork(keeping kept: Set<String>) throws {
        for file in try FileManager.default.contentsOfDirectory(at: artwork, includingPropertiesForKeys: nil) {
            let name = file.deletingPathExtension().lastPathComponent
            guard let separator = name.lastIndex(of: "-"), !kept.contains(String(name[..<separator])) else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Extras

    func extrasFolder(for jobId: UUID) -> URL {
        extras.appending(path: jobId.uuidString, directoryHint: .isDirectory)
    }

    /// Puts a fetched extra in place, over an older copy in one step, so that a copy is always
    /// there whole.
    func saveExtra(_ downloaded: URL, to file: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try manager.replaceItemAt(file, withItemAt: downloaded)
        #if !os(macOS)
        // Subtitles beside a finished file are in Documents, which backups would otherwise take.
        if file.path.hasPrefix(finished.path) {
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var saved = file
            try saved.setResourceValues(excluded)
        }
        #endif
    }

    /// Deletes a job's folder of extras and the files given, its subtitles beside the file.
    func removeExtras(for jobId: UUID, besideFile files: [URL]) throws {
        let manager = FileManager.default
        for file in files + [extrasFolder(for: jobId)] where manager.fileExists(atPath: file.path) {
            try manager.removeItem(at: file)
        }
    }

    /// What the files take on disk; ones that aren't there count as nothing.
    func size(of files: [URL]) -> Int64 {
        files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }

    // MARK: Jobs

    func loadJobs() throws -> [DownloadJob] {
        guard FileManager.default.fileExists(atPath: jobsFile.path) else { return [] }
        return try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: jobsFile))
    }

    func saveJobs(_ jobs: [DownloadJob]) throws {
        try JSONEncoder().encode(jobs).write(to: jobsFile, options: .atomic)
    }

    // MARK: Transfers

    func loadHandedOut() throws -> [TransferTag] {
        guard FileManager.default.fileExists(atPath: handedOutFile.path) else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: handedOutFile)).compactMap(TransferTag.init(encoded:))
    }

    func saveHandedOut(_ tags: some Sequence<TransferTag>) throws {
        try JSONEncoder().encode(tags.map(\.encoded)).write(to: handedOutFile, options: .atomic)
    }

    private func heldFile(for tag: TransferTag) -> URL {
        held.appending(path: tag.encoded.replacing(" ", with: "_") + ".resume")
    }

    func loadHeld() throws -> [TransferTag: ResumePoint] {
        var points: [TransferTag: ResumePoint] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: held, includingPropertiesForKeys: nil) {
            guard let tag = TransferTag(encoded: file.deletingPathExtension().lastPathComponent.replacing("_", with: " ")) else { continue }
            points[tag] = try ResumePoint(contentsOf: file)
        }
        return points
    }

    func saveHeld(_ point: ResumePoint, for tag: TransferTag) throws {
        try point.write(to: heldFile(for: tag))
    }

    /// The resume points of whole-file transfers, by job.
    func loadResumePoints() throws -> [UUID: ResumePoint] {
        var points: [UUID: ResumePoint] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: partials, includingPropertiesForKeys: nil)
        where file.pathExtension == "resume" {
            guard let jobId = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            points[jobId] = try ResumePoint(contentsOf: file)
        }
        return points
    }

    func saveResumePoint(_ point: ResumePoint, for jobId: UUID) throws {
        try point.write(to: resumeDataFile(for: jobId))
    }

    /// Removes the held resume data of the tags `matching` accepts.
    func removeHeld(where matching: (TransferTag) -> Bool) throws {
        for file in try FileManager.default.contentsOfDirectory(at: held, includingPropertiesForKeys: nil) {
            let tag = TransferTag(encoded: file.deletingPathExtension().lastPathComponent.replacing("_", with: " "))
            if tag.map(matching) ?? true { try FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: Files

    /// Removes leftovers of transfers whose completion the previous run never got to handle.
    /// Only safe before the background session exists, while no new transfer can be staged.
    func clearStaging() throws {
        let manager = FileManager.default
        for file in try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: file)
        }
    }

    func removePartial(for jobId: UUID) throws {
        for file in [partialFile(for: jobId), resumeDataFile(for: jobId)] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Writes a downloaded chunk into the partial file at its offset, then deletes the chunk.
    /// The partial file is sparse until every chunk is in.
    @concurrent
    func writeChunk(_ chunk: URL, into jobId: UUID, at offset: Int64) async throws {
        let partial = partialFile(for: jobId)
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
            }
        }
        let output = try FileHandle(forWritingTo: partial)
        let input = try FileHandle(forReadingFrom: chunk)
        try output.seek(toOffset: UInt64(offset))
        while let block = try input.read(upToCount: 4 << 20), !block.isEmpty {
            try output.write(contentsOf: block)
        }
        // On disk before the job records the range as done.
        try output.synchronize()
        try output.close()
        try input.close()
        try FileManager.default.removeItem(at: chunk)
    }

    /// Makes a whole-file response the partial file.
    func adoptWholeFile(_ file: URL, for jobId: UUID) throws {
        let partial = partialFile(for: jobId)
        if FileManager.default.fileExists(atPath: partial.path) {
            try FileManager.default.removeItem(at: partial)
        }
        try FileManager.default.moveItem(at: file, to: partial)
    }

    /// Moves the finished partial file into `finished` and returns its path relative to it.
    /// A name already taken gets the version appended, then a number.
    func publish(_ job: DownloadJob) throws -> String {
        // A chunk written for a job that was restarted meanwhile can lie past the new end.
        if let totalBytes = job.totalBytes {
            let handle = try FileHandle(forWritingTo: partialFile(for: job.id))
            try handle.truncate(atOffset: UInt64(totalBytes))
            try handle.close()
        }
        let destination = freeDestination(for: job)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: partialFile(for: job.id), to: destination)
        #if !os(macOS)
        // Re-downloadable media; keeping it out of iCloud backups saves the user's quota.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var published = destination
        try published.setResourceValues(excluded)
        #endif
        if manager.fileExists(atPath: resumeDataFile(for: job.id).path) {
            try manager.removeItem(at: resumeDataFile(for: job.id))
        }
        return String(destination.path.dropFirst(finished.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func freeDestination(for job: DownloadJob) -> URL {
        let ext = job.fileExtension ?? "mkv"
        let stem = finished.appending(path: job.destinationStem).path
        let version = DownloadJob.sanitize(job.versionName)
        let isFree = { (url: URL) in !FileManager.default.fileExists(atPath: url.path) }

        let plain = URL(filePath: stem).appendingPathExtension(ext)
        if isFree(plain) { return plain }
        let withVersion = URL(filePath: "\(stem) - \(version)").appendingPathExtension(ext)
        if !version.isEmpty, isFree(withVersion) { return withVersion }
        var counter = 2
        while true {
            let numbered = URL(filePath: "\(stem) \(counter)").appendingPathExtension(ext)
            if isFree(numbered) { return numbered }
            counter += 1
        }
    }

    /// The room on the volume for downloads: with `countingPurgeable`, what the system says it can
    /// make for something important by purging, which it does in its own time rather than as a
    /// write needs it; without, what's free now. Nil when the volume can't say; the caller then
    /// doesn't hold the download back.
    func availableCapacity(countingPurgeable: Bool = true) -> Int64? {
        if countingPurgeable {
            let values = try? finished.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
        let values = try? finished.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: Room made

    /// The watched downloads last deleted to make room, to say so.
    var freedFile: URL { root.appending(path: "freed.json") }

    func loadFreed() throws -> FreedSpace? {
        guard FileManager.default.fileExists(atPath: freedFile.path) else { return nil }
        return try JSONDecoder().decode(FreedSpace.self, from: Data(contentsOf: freedFile))
    }

    func saveFreed(_ freed: FreedSpace) throws {
        try JSONEncoder().encode(freed).write(to: freedFile, options: .atomic)
    }
}

/// Watched downloads deleted to make room (`StorageBudget`), to tell the user, whenever it
/// happened: in front, or in a background wake the app was killed after.
nonisolated struct FreedSpace: Codable, Equatable, Sendable {
    let titles: [String]
    let bytes: Int64
    let date: Date
}

/// A cancelled transfer's resume data, with how many bytes of its file it carries. Those bytes
/// are in the session's files rather than the partial file until a transfer carries on from
/// them, and they're the download's all the same: in its progress and in the room it takes.
nonisolated struct ResumePoint: Codable, Equatable, Sendable {
    let data: Data
    let bytes: Int64

    init(data: Data, bytes: Int64) {
        self.data = data
        self.bytes = bytes
    }

    /// A file of bare resume data, as builds that didn't count its bytes kept it, still carries
    /// on, counting no bytes until its transfer reports: refusing it would start those
    /// downloads over.
    init(contentsOf file: URL) throws {
        let contents = try Data(contentsOf: file)
        do {
            self = try PropertyListDecoder().decode(Self.self, from: contents)
        } catch is DecodingError {
            self.init(data: contents, bytes: 0)
        }
    }

    func write(to file: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
#endif
