import Foundation

/// Where downloads live on disk.
///
/// - `Documents/` holds finished files; the Files app shows it as "On My iPhone › JF Downloader".
/// - `Library/Application Support/Downloads/` holds the job list and the partial files, out of
///   the Files app's sight and out of backups.
/// - `…/Downloads/Staging/` holds bodies the session delegate moved out of the system's
///   temporary location, until they are written into their partial file.
nonisolated struct DownloadStorage: Sendable {
    let documents: URL
    let root: URL

    var jobsFile: URL { root.appending(path: "jobs.json") }
    var partials: URL { root.appending(path: "Partials", directoryHint: .isDirectory) }
    var staging: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }

    static let standard = DownloadStorage(
        documents: URL.documentsDirectory,
        root: URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    )

    func prepare() throws {
        let manager = FileManager.default
        for directory in [documents, partials, staging] {
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

    func resumeDataFile(for jobId: UUID) -> URL {
        partials.appending(path: "\(jobId.uuidString).resume")
    }

    // MARK: Jobs

    func loadJobs() throws -> [DownloadJob] {
        guard FileManager.default.fileExists(atPath: jobsFile.path) else { return [] }
        return try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: jobsFile))
    }

    func saveJobs(_ jobs: [DownloadJob]) throws {
        try JSONEncoder().encode(jobs).write(to: jobsFile, options: .atomic)
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

    /// Moves the finished partial file into Documents and returns its path relative to Documents.
    /// A name already taken gets the version appended, then a number.
    func publish(_ job: DownloadJob) throws -> String {
        // A chunk written for a job that was restarted meanwhile can lie past the new end.
        if let totalBytes = job.totalBytes {
            let handle = try FileHandle(forWritingTo: partialFile(for: job.id))
            try handle.truncate(atOffset: UInt64(totalBytes))
            try handle.close()
        }
        var destination = freeDestination(for: job)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: partialFile(for: job.id), to: destination)
        // Re-downloadable media; keeping it out of iCloud backups saves the user's quota.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try destination.setResourceValues(excluded)
        if manager.fileExists(atPath: resumeDataFile(for: job.id).path) {
            try manager.removeItem(at: resumeDataFile(for: job.id))
        }
        return String(destination.path.dropFirst(documents.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func freeDestination(for job: DownloadJob) -> URL {
        let ext = job.fileExtension ?? "mkv"
        let stem = documents.appending(path: job.destinationStem).path
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

    /// Nil when the volume can't say; the caller then doesn't hold the download back.
    func availableCapacity() -> Int64? {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
