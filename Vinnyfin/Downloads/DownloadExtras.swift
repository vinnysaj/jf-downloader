#if !os(tvOS)
import Foundation

/// What a download keeps besides its file, so that it plays offline as it streams: the item's
/// details (overview, chapters, which scrub previews the server made), the skippable segments,
/// the artwork, the server's subtitle files, the scrub previews at the player's width and the
/// chapters' pictures.
///
/// - The details and segments live in the job (`DownloadJob.item`, `segments`).
/// - Subtitle files go beside the finished file once it's published, named the way media players
///   look for them ("Movie (2024).eng.forced.srt"), so the file plays with them elsewhere too.
/// - Scrub previews and chapter pictures go in the job's folder under `DownloadStorage.extras`.
/// - Artwork goes under `DownloadStorage.artwork` by item, as offline lists find it there.
///
/// Only subtitles the server keeps as files of their own count: the ones it extracts from the
/// media are tracks the downloaded file already has, with their styling and pictures intact. A
/// transcoded download's file has none, so its text subtitles all come as files, the server
/// extracting those in the media; picture-based ones are burned into its picture or left out
/// (`TranscodeRequest`). `DownloadManager` fetches what's missing; this works out what that is.
nonisolated enum DownloadExtras {
    /// One file a download keeps, where it comes from and where it goes.
    struct File: Equatable, Sendable {
        enum Remote: Equatable, Sendable {
            case subtitle(itemId: String, mediaSourceId: String, streamIndex: Int, format: String)
            case trickplaySheet(itemId: String, mediaSourceId: String, width: Int, index: Int)
            case chapterImage(itemId: String, index: Int, tag: String)
            case artwork(itemId: String, kind: JellyfinClient.ImageKind, tag: String, width: Int)
        }

        let remote: Remote
        let local: URL

        /// Counted in the download's size and deleted with it. A show's poster, which its
        /// episodes share, isn't.
        var isOwn = true

        func url(using client: JellyfinClient) -> URL {
            switch remote {
            case .subtitle(let itemId, let mediaSourceId, let streamIndex, let format):
                client.externalSubtitleURL(itemId: itemId, mediaSourceId: mediaSourceId, streamIndex: streamIndex, format: format)
            case .trickplaySheet(let itemId, let mediaSourceId, let width, let index):
                client.trickplaySheetURL(itemId: itemId, mediaSourceId: mediaSourceId, width: width, index: index)
            case .chapterImage(let itemId, let index, let tag):
                client.chapterImageURL(itemId: itemId, index: index, tag: tag, maxWidth: ChapterMark.imageWidth)
            case .artwork(let itemId, let kind, let tag, let width):
                client.imageURL(itemId: itemId, kind: kind, tag: tag, maxWidth: width)
            }
        }

        /// What it is, for a message about it.
        var description: String {
            switch remote {
            case .subtitle: "subtitles"
            case .trickplaySheet: "scrub previews"
            case .chapterImage: "chapter pictures"
            case .artwork: "artwork"
            }
        }
    }

    /// What a download fetches next.
    enum Step: Equatable, Sendable {
        /// The item's details, with the downloaded version's chapters and segments: once, and
        /// again while the server may still make previews or chapter pictures.
        case lookUp
        case file(File)
    }

    /// The server makes previews and chapter pictures in a scheduled task, so for a week after a
    /// download is queued, the item's details are asked for again once a day while they lack them.
    static let lookUpInterval: TimeInterval = 24 * 60 * 60
    static let lookUpPeriod: TimeInterval = 7 * 24 * 60 * 60

    /// The next thing the job lacks, or nil once it has everything. `exists` says whether a file
    /// is on disk.
    static func nextStep(for job: DownloadJob, storage: DownloadStorage, exists: (URL) -> Bool, now: Date) -> Step? {
        if needsLookUp(job, now: now) { return .lookUp }
        return files(for: job, storage: storage).first { !exists($0.local) }.map(Step.file)
    }

    static func needsLookUp(_ job: DownloadJob, now: Date) -> Bool {
        guard let checked = job.extrasCheckedAt, job.segments != nil, job.extrasItemId == job.versionItemId else { return true }
        guard now.timeIntervalSince(job.createdAt) < lookUpPeriod, now.timeIntervalSince(checked) >= lookUpInterval else { return false }
        guard let item = job.item else { return true }
        let lacksPreviews = TrickplayTiles.info(of: item, sourceId: job.mediaSourceId) == nil
        let lacksPictures = item.chapters?.contains { $0.imageTag == nil } ?? false
        return lacksPreviews || lacksPictures
    }

    /// Every file the job keeps: artwork, scrub previews and chapter pictures from the start,
    /// subtitles once the file is published beside them.
    static func files(for job: DownloadJob, storage: DownloadStorage) -> [File] {
        guard let item = job.item else { return [] }
        var files = artwork(for: item, storage: storage)
        let folder = storage.extrasFolder(for: job.id)
        if let info = TrickplayTiles.info(of: item, sourceId: job.mediaSourceId) {
            for index in 0..<info.sheetCount {
                files.append(File(remote: .trickplaySheet(itemId: item.id, mediaSourceId: job.mediaSourceId, width: info.width, index: index),
                                  local: trickplaySheet(index, width: info.width, in: folder)))
            }
        }
        for (index, chapter) in (item.chapters ?? []).enumerated() {
            guard let tag = chapter.imageTag else { continue }
            files.append(File(remote: .chapterImage(itemId: job.versionItemId, index: index, tag: tag),
                              local: folder.appending(path: "Chapters/\(index)-\(tag).jpg")))
        }
        if let savedPath = job.savedPath, let source = item.mediaSources?.first {
            let video = storage.finished.appending(path: savedPath)
            for (stream, file) in subtitleFiles(of: source, beside: video, includingEmbedded: job.transcode != nil) {
                files.append(File(remote: .subtitle(itemId: item.id, mediaSourceId: source.id, streamIndex: stream.index ?? 0,
                                                    format: PlaybackResolver.subtitleFormat(for: stream.codec)),
                                  local: file))
            }
        }
        return files
    }

    static func trickplaySheet(_ index: Int, width: Int, in folder: URL) -> URL {
        folder.appending(path: "Trickplay/\(width)/\(index).jpg")
    }

    /// The pictures offline lists and pages show: the item's own (its poster or still, backdrop
    /// and logo, a parent's when it has none) and an episode's show's poster.
    static func artwork(for item: JellyfinItem, storage: DownloadStorage) -> [File] {
        var files: [File] = []
        func add(_ id: String, _ kind: JellyfinClient.ImageKind, _ tag: String?, width: Int, savedAs savedId: String) {
            guard let tag else { return }
            files.append(File(remote: .artwork(itemId: id, kind: kind, tag: tag, width: width),
                              local: storage.artworkFile(itemId: savedId, kind: kind), isOwn: savedId == item.id))
        }
        add(item.id, .primary, item.primaryImageTag, width: 600, savedAs: item.id)
        if let tag = item.backdropImageTags?.first {
            add(item.id, .backdrop, tag, width: 1280, savedAs: item.id)
        } else if let parent = item.parentBackdropItemId {
            add(parent, .backdrop, item.parentBackdropImageTags?.first, width: 1280, savedAs: item.id)
        }
        if let tag = item.imageTags?["Logo"] {
            add(item.id, .logo, tag, width: 900, savedAs: item.id)
        } else if let parent = item.parentLogoItemId {
            add(parent, .logo, item.parentLogoImageTag, width: 900, savedAs: item.id)
        }
        if let seriesId = item.seriesId {
            add(seriesId, .primary, item.seriesPrimaryImageTag, width: 600, savedAs: seriesId)
        }
        return files
    }

    /// Where the version's external subtitle files go beside `video`: its name, the language
    /// ("und" when the server doesn't know it), whether it's forced or for the hard of hearing,
    /// the stream's number when two would otherwise share a name, and the format.
    /// `includingEmbedded` adds the text subtitles in the media, which the server extracts, for
    /// a transcoded download: its file carries none.
    static func subtitleFiles(of source: MediaSource, beside video: URL, includingEmbedded: Bool = false)
        -> [(stream: MediaStream, file: URL)] {
        let streams = source.subtitleStreams.filter { stream in
            stream.index != nil && (stream.isExternal == true || (includingEmbedded && !TranscodeRequest.isPictureBased(stream)))
        }
        let stem = video.deletingPathExtension().lastPathComponent
        let folder = video.deletingLastPathComponent()
        func kind(_ stream: MediaStream) -> String {
            let language = (stream.language ?? "").lowercased().filter { $0.isLetter || $0 == "-" }
            var parts = [language.isEmpty ? "und" : language]
            if stream.isForced == true { parts.append("forced") }
            if stream.isHearingImpaired == true { parts.append("sdh") }
            return parts.joined(separator: ".")
        }
        let names = streams.map { "\(kind($0)).\(PlaybackResolver.subtitleFormat(for: $0.codec))" }
        return zip(streams, names).map { stream, name in
            let shared = names.count { $0 == name } > 1
            let format = PlaybackResolver.subtitleFormat(for: stream.codec)
            let file = shared ? "\(stem).\(kind(stream)).\(stream.index ?? 0).\(format)" : "\(stem).\(name)"
            return (stream, folder.appending(path: file))
        }
    }

    /// The saved files a playback uses, as `PlaybackResolver` takes them: subtitle files by
    /// stream index, preview sheets by number and chapter pictures by chapter. Only files that
    /// are on disk.
    static func saved(for job: DownloadJob, storage: DownloadStorage, exists: (URL) -> Bool)
        -> (subtitles: [Int: URL], trickplaySheets: [Int: URL], chapterImages: [Int: URL]) {
        var subtitles: [Int: URL] = [:]
        var sheets: [Int: URL] = [:]
        var chapters: [Int: URL] = [:]
        for file in files(for: job, storage: storage) where exists(file.local) {
            switch file.remote {
            case .subtitle(_, _, let streamIndex, _): subtitles[streamIndex] = file.local
            case .trickplaySheet(_, _, _, let index): sheets[index] = file.local
            case .chapterImage(_, let index, _): chapters[index] = file.local
            case .artwork: break
            }
        }
        return (subtitles, sheets, chapters)
    }
}
#endif
