#if !os(tvOS)
import Foundation

/// One file to download: an item's chosen version, and how far it has got.
nonisolated struct DownloadJob: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Transferring, or waiting: to retry, or for what the rules or room hold it back for.
        /// Only `pause` or a give-up moves it elsewhere.
        case active
        case paused
        case completed
        /// Gave up; `lastError` says why. Retry puts it back to active.
        case failed
    }

    /// Whether the server answers byte-range requests for this file. Learned from the first response.
    enum RangeSupport: String, Codable, Sendable {
        case unknown
        /// Downloaded in chunks; every response's Content-Range total has to match `totalBytes`.
        case supported
        /// Downloaded in one request; a dropped connection starts it over unless the system has resume data.
        case unsupported
    }

    let id: UUID
    let itemId: String
    let mediaSourceId: String
    let title: String
    let subtitle: String?
    let versionName: String
    /// Path under Documents without the extension, e.g. "Show/Season 01/Show - S01E02 - Title".
    let destinationStem: String
    var fileExtension: String?
    /// The size Jellyfin listed for the source, shown until the server confirms the real one.
    let sizeHint: Int64?
    let createdAt: Date
    /// The item as it was when queued or its extras last looked it up, with only the chosen
    /// version, for browsing and playing it offline.
    var item: JellyfinItem?
    /// The server's marked intro, credits and the like, for skipping them offline. Nil until
    /// fetched.
    var segments: [MediaSegment]?
    /// When `item` was last taken from the server's details. Nil until it has been once.
    var extrasCheckedAt: Date?
    /// The item `item`'s chapters and `segments` were taken from, which is the downloaded
    /// version's own (`versionItemId`). Nil for downloads saved before they were, whose next
    /// look-up takes them again.
    var extrasItemId: String?
    /// What its extras take on disk, as of the last time it had them all.
    var extrasBytes: Int64?

    var status = Status.active
    var rangeSupport = RangeSupport.unknown
    var totalBytes: Int64?
    var completed = ByteRanges()
    var chunkSize = DownloadJob.initialChunkSize
    /// When a dropped connection last halved `chunkSize`.
    var lastCutAt: Date?
    /// Failures in a row that never reached the server or were cut off. Never makes the job give up.
    var networkFailures = 0
    /// Error answers from the server in a row. The job gives up after `maxServerFailures`.
    var serverFailures = 0
    var lastError: String?
    /// Transfers started before this date are scheduled to begin at it.
    var retryAt: Date?
    /// Since when transfers have failed to reach the server, without one coming through since.
    var serverUnreachableSince: Date?
    /// When someone chose Download Now for it: the network and schedule rules don't hold it back.
    var downloadNowAt: Date?
    /// Where the finished file is, relative to Documents.
    var savedPath: String?
    var completedAt: Date?

    init(item: JellyfinItem, source: MediaSource, now: Date = .now) {
        id = UUID()
        itemId = item.id
        mediaSourceId = source.id
        title = item.titleWithYear
        subtitle = item.isEpisode ? [item.seriesName, item.episodeCode].compactMap(\.self).joined(separator: " · ") : nil
        versionName = source.name ?? "Default"
        destinationStem = Self.destinationStem(for: item)
        fileExtension = source.fileExtension
        sizeHint = source.plausibleSize
        createdAt = now
        self.item = Self.snapshot(of: item, keeping: source)
    }

    /// The item the downloaded version is, whose segments and chapters are its own (see
    /// `MediaSource.versionItemId`).
    var versionItemId: String { mediaSourceId }

    /// The item's details with `source` as its only version. The chapters listed are the item's
    /// own version's, so another version's go until its extras look them up.
    static func snapshot(of item: JellyfinItem, keeping source: MediaSource) -> JellyfinItem {
        var snapshot = item
        snapshot.mediaSources = [source]
        snapshot.people = nil
        if source.versionItemId != item.id { snapshot.chapters = nil }
        return snapshot
    }

    var seriesId: String? { item?.seriesId }
    var isEpisode: Bool { item?.isEpisode ?? (subtitle != nil) }
    var ignoresRules: Bool { downloadNowAt != nil }

    /// A short name for notifications and the system's UI: "Show S01E02" for an episode, else the title.
    var shortName: String {
        guard isEpisode, let series = item?.seriesName else { return title }
        return [series, item?.episodeCode].compactMap(\.self).joined(separator: " ")
    }

    var displayTotalBytes: Int64? { totalBytes ?? sizeHint }

    /// The file and its extras, as far as they're known.
    var storedBytes: Int64 { (totalBytes ?? 0) + (extrasBytes ?? 0) }

    var isTransferComplete: Bool {
        guard let totalBytes else { return false }
        return completed.covers(0..<totalBytes)
    }

    // MARK: Naming

    /// Names media players such as Infuse recognize: "Movie (2024)" and "Show/Season 01/Show - S01E02 - Title".
    static func destinationStem(for item: JellyfinItem) -> String {
        guard item.isEpisode else { return sanitize(item.titleWithYear) }
        let series = sanitize(item.seriesName ?? "Unknown Series")
        let season = String(format: "Season %02d", item.parentIndexNumber ?? 0)
        var parts = [series]
        if let code = item.episodeCode { parts.append(code) }
        let episodeName = sanitize(item.name)
        if !episodeName.isEmpty, episodeName != series { parts.append(episodeName) }
        return "\(series)/\(season)/\(parts.joined(separator: " - "))"
    }

    /// Makes a string safe as one path component.
    static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(trimmed.prefix(150))
    }
}

nonisolated extension DownloadJob {
    static let initialChunkSize: Int64 = 16 << 20
    static let minimumChunkSize: Int64 = 1 << 20
    static let maximumChunkSize: Int64 = 64 << 20
    static let maxServerFailures = 20
}
#endif
