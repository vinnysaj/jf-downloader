import AetherEngine
import Foundation

/// Something to play, as handed to the player (and, on the Mac, to the player window).
nonisolated struct PlaybackRequest: Codable, Hashable, Identifiable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        /// A server item, from a downloaded copy when there is one. A nil version lets the
        /// player choose one for the streaming quality.
        case item(id: String, mediaSourceId: String?)
        /// A file on this device, as a bookmark so it stays reachable after a relaunch.
        case file(bookmark: Data, name: String)
    }

    var id = UUID()
    let source: Source
    /// Shown while the player gets ready.
    var title: String
    var startFromBeginning = false

    static func item(_ item: JellyfinItem, mediaSourceId: String? = nil, fromBeginning: Bool = false) -> PlaybackRequest {
        PlaybackRequest(source: .item(id: item.id, mediaSourceId: mediaSourceId), title: item.name, startFromBeginning: fromBeginning)
    }

    /// Bookmarks a file the user picked. The caller holds access to it while this runs.
    static func file(_ url: URL) throws -> PlaybackRequest {
        #if os(macOS)
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        return PlaybackRequest(source: .file(bookmark: bookmark, name: url.lastPathComponent), title: url.deletingPathExtension().lastPathComponent)
    }
}

/// Everything the player needs to start a playback, worked out from a request.
struct ResolvedPlayback {
    /// What the server is told about the playback. Nil for files that aren't the server's.
    struct Reporting {
        let itemId: String
        let mediaSourceId: String?
        let playSessionId: String
        let playMethod: String
    }

    var url: URL
    var title: String
    var subtitle: String?
    var item: JellyfinItem?
    var mediaSource: MediaSource?
    var startPosition: Double?
    var duration: Double?
    var externalSubtitles: [ExternalSubtitleTrack] = []
    /// The key the position is kept under in `WatchHistory`.
    var historyKey: String
    var reporting: Reporting?
    var isTranscode = false
    /// A downloaded copy of a server item.
    var isDownload = false
    /// The skippable stretches saved with a download.
    var segments: [MediaSegment] = []
    /// A security-scoped URL to stop accessing when playback ends.
    var scopedURL: URL?
}

nonisolated enum PlaybackError: LocalizedError {
    case notSignedIn
    case noVersions
    case transcodeRefused(String?)
    case fileUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to a server to play this."
        case .noVersions: "The server lists no versions of this title."
        case .transcodeRefused(let code): "The server couldn't prepare a stream\(code.map { " (\($0))" } ?? "")."
        case .fileUnavailable(let name): "\(name) can't be opened. It may have been moved or deleted."
        }
    }
}

/// Turns a request into a URL and the details around it.
@MainActor
struct PlaybackResolver {
    let accounts: AccountStore
    let settings: AppSettings
    let history: WatchHistory
    /// A finished download of the item (and version, when given), with the item and its segments
    /// as they were saved.
    let downloadedCopy: (_ itemId: String, _ mediaSourceId: String?) -> DownloadedCopy?

    struct DownloadedCopy {
        let url: URL
        let item: JellyfinItem?
        let segments: [MediaSegment]
    }

    func resolve(_ request: PlaybackRequest) async throws -> ResolvedPlayback {
        switch request.source {
        case .file(let bookmark, let name):
            return try resolveFile(bookmark: bookmark, name: name, request: request)
        case .item(let id, let mediaSourceId):
            if let copy = downloadedCopy(id, mediaSourceId) {
                return resolveDownload(copy, itemId: id, request: request)
            }
            return try await resolveStream(itemId: id, mediaSourceId: mediaSourceId, request: request)
        }
    }

    // MARK: Files

    private func resolveFile(bookmark: Data, name: String, request: PlaybackRequest) throws -> ResolvedPlayback {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw PlaybackError.fileUnavailable(name)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        let key = WatchHistory.fileKey(name: url.lastPathComponent, size: size)
        let externalSubtitles = Self.sidecarSubtitles(for: url)
        return ResolvedPlayback(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            startPosition: request.startFromBeginning ? nil : history.resumePosition(for: key),
            duration: history.entry(for: key)?.duration,
            externalSubtitles: externalSubtitles,
            historyKey: key,
            scopedURL: scoped ? url : nil
        )
    }

    /// Subtitle files next to a video that share its name: "Movie.en.srt" for "Movie.mkv".
    static func sidecarSubtitles(for video: URL) -> [ExternalSubtitleTrack] {
        let folder = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let formats: Set<String> = ["srt", "ass", "ssa", "vtt", "sup"]
        return files.filter { file in
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            return formats.contains(file.pathExtension.lowercased()) && (name == stem || name.hasPrefix(stem + "."))
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { file in
            // "Movie.en.forced.srt": the parts between the name and the format.
            let middle = file.deletingPathExtension().lastPathComponent.dropFirst(stem.count)
                .split(separator: ".").map { $0.lowercased() }
            let language = middle.first { $0.count == 2 || $0.count == 3 }
            return ExternalSubtitleTrack(
                url: file,
                name: file.lastPathComponent,
                language: language,
                isForced: middle.contains("forced"),
                isHearingImpaired: middle.contains("sdh") || middle.contains("hi")
            )
        }
    }

    // MARK: Downloads

    private func resolveDownload(_ copy: DownloadedCopy, itemId: String, request: PlaybackRequest) -> ResolvedPlayback {
        let item = copy.item
        // The server's position when it was last seen, unless this device has a newer one.
        var start = item?.resumeSeconds
        if let local = history.entry(for: itemId) {
            let serverDate = item?.lastPlayedDate ?? .distantPast
            if local.updatedAt > serverDate { start = local.played ? nil : (local.position > 0 ? local.position : nil) }
        }
        let reporting = accounts.client.map { _ in
            ResolvedPlayback.Reporting(itemId: itemId, mediaSourceId: item?.mediaSources?.first?.id,
                                       playSessionId: Self.newPlaySessionId(), playMethod: "DirectPlay")
        }
        let length = item?.mediaSources?.first?.runtimeSeconds ?? item?.runtimeSeconds
        return ResolvedPlayback(
            url: copy.url,
            title: item.map(Self.title) ?? request.title,
            subtitle: item.flatMap(Self.subtitle),
            item: item,
            mediaSource: item?.mediaSources?.first,
            startPosition: request.startFromBeginning ? nil : Self.resumable(start, length: length),
            duration: length,
            externalSubtitles: Self.sidecarSubtitles(for: copy.url),
            historyKey: itemId,
            reporting: reporting,
            isDownload: true,
            segments: copy.segments
        )
    }

    // MARK: Streaming

    private func resolveStream(itemId: String, mediaSourceId: String?, request: PlaybackRequest) async throws -> ResolvedPlayback {
        guard let client = accounts.client, let account = accounts.account else { throw PlaybackError.notSignedIn }
        let item = try await client.item(id: itemId, userId: account.userId)
        let sources = item.mediaSources ?? []
        let preferred = mediaSourceId.flatMap { id in sources.first { $0.id == id } }
        guard let plan = VersionChooser.planStreaming(
            sources: sources, preferred: preferred,
            quality: settings.streamingQuality, allowTranscoding: settings.allowTranscoding
        ) else { throw PlaybackError.noVersions }

        var start = request.startFromBeginning ? nil : item.resumeSeconds
        if !request.startFromBeginning, let local = history.entry(for: itemId), local.needsSync, !local.played {
            start = local.position > 0 ? local.position : start
        }

        switch plan {
        case .direct(let source):
            let length = source.runtimeSeconds ?? item.runtimeSeconds
            return ResolvedPlayback(
                url: client.streamURL(itemId: itemId, mediaSourceId: source.id),
                title: Self.title(item),
                subtitle: Self.subtitle(item),
                item: item,
                mediaSource: source,
                startPosition: Self.resumable(start, length: length),
                duration: length,
                externalSubtitles: externalSubtitles(of: source, itemId: itemId, client: client),
                historyKey: itemId,
                reporting: .init(itemId: itemId, mediaSourceId: source.id, playSessionId: Self.newPlaySessionId(), playMethod: "DirectPlay")
            )
        case .transcode(let source, let quality):
            let audioIndex = Self.preferredAudioIndex(in: source, language: settings.audioLanguage)
            let subtitleIndex = Self.preferredSubtitleIndex(in: source, audioIndex: audioIndex, settings: settings)
            return try await transcode(item: item, source: source, quality: quality, audioIndex: audioIndex,
                                       subtitleIndex: subtitleIndex, start: Self.resumable(start, length: source.runtimeSeconds ?? item.runtimeSeconds))
        }
    }

    /// Has the server scale `source` down to `quality`, with the audio and subtitle streams
    /// burned or muxed into the stream.
    func transcode(item: JellyfinItem, source: MediaSource, quality: VideoQuality,
                   audioIndex: Int?, subtitleIndex: Int?, start: Double?) async throws -> ResolvedPlayback {
        guard let client = accounts.client, let account = accounts.account else { throw PlaybackError.notSignedIn }
        let info = try await client.playbackInfo(itemId: item.id, userId: account.userId, request: PlaybackInfoRequest(
            UserId: account.userId,
            MediaSourceId: source.id,
            MaxStreamingBitrate: quality.transcodeBitrate,
            StartTimeTicks: Int64((start ?? 0) * 10_000_000),
            AudioStreamIndex: audioIndex,
            SubtitleStreamIndex: subtitleIndex,
            DeviceProfile: .transcoding(maxHeight: quality.maxHeight, maxBitrate: quality.transcodeBitrate)
        ))
        let served = info.mediaSources.first { $0.id == source.id } ?? info.mediaSources.first
        guard let path = served?.transcodingUrl, let url = client.absoluteURL(serverPath: path) else {
            throw PlaybackError.transcodeRefused(info.errorCode)
        }
        return ResolvedPlayback(
            url: url,
            title: Self.title(item),
            subtitle: Self.subtitle(item),
            item: item,
            mediaSource: source,
            startPosition: start,
            duration: item.runtimeSeconds,
            historyKey: item.id,
            reporting: .init(itemId: item.id, mediaSourceId: source.id,
                             playSessionId: info.playSessionId ?? Self.newPlaySessionId(), playMethod: "Transcode"),
            isTranscode: true
        )
    }

    /// Subtitle files the server keeps next to the media; embedded ones come with the stream.
    private func externalSubtitles(of source: MediaSource, itemId: String, client: JellyfinClient) -> [ExternalSubtitleTrack] {
        source.subtitleStreams.compactMap { stream in
            guard stream.isExternal == true, let index = stream.index else { return nil }
            let format = Self.subtitleFormat(for: stream.codec)
            return ExternalSubtitleTrack(
                url: client.externalSubtitleURL(itemId: itemId, mediaSourceId: source.id, streamIndex: index, format: format),
                name: stream.title ?? stream.displayTitle,
                language: stream.language,
                isForced: stream.isForced ?? false,
                isHearingImpaired: stream.isHearingImpaired ?? false,
                isDefault: stream.isDefault ?? false,
                formatHint: format
            )
        }
    }

    /// A resume position, unless it's at or past the end of this version, which happens when the
    /// position was left in a longer one: the server keeps one position per title.
    static func resumable(_ start: Double?, length: Double?) -> Double? {
        guard let start, start > 0 else { return nil }
        guard let length, length > 0 else { return start }
        return start < length * WatchHistory.playedFraction ? start : nil
    }

    static func subtitleFormat(for codec: String?) -> String {
        switch codec?.lowercased() {
        case "subrip", "srt", nil: "srt"
        case "ass": "ass"
        case "ssa": "ssa"
        case "webvtt", "vtt": "vtt"
        case "pgssub", "pgs", "sup": "sup"
        case let other?: other
        }
    }

    static func preferredAudioIndex(in source: MediaSource, language: String) -> Int? {
        guard !language.isEmpty else { return nil }
        return source.audioStreams.first { AppSettings.sameLanguage($0.language, language) }?.index
    }

    /// The subtitle stream the subtitle setting asks for, from the server's list of streams.
    static func preferredSubtitleIndex(in source: MediaSource, audioIndex: Int?, settings: AppSettings) -> Int? {
        let audio = source.audioStreams.first { $0.index == (audioIndex ?? source.defaultAudioStreamIndex) } ?? source.audioStreams.first
        let candidates = source.subtitleStreams.map {
            TrackChooser.Candidate(id: $0.index ?? -1, language: $0.language, isForced: $0.isForced ?? false,
                                   isHearingImpaired: $0.isHearingImpaired ?? false, isDefault: $0.isDefault ?? false)
        }
        return TrackChooser.subtitle(from: candidates, audioLanguage: audio?.language,
                                     mode: settings.subtitleMode, language: settings.subtitleLanguage)
    }

    static func title(_ item: JellyfinItem) -> String {
        item.isEpisode ? item.name : (item.productionYear.map { "\(item.name) (\($0))" } ?? item.name)
    }

    static func subtitle(_ item: JellyfinItem) -> String? {
        guard item.isEpisode else { return nil }
        return [item.seriesName, item.episodeCode].compactMap(\.self).joined(separator: " · ")
    }

    static func newPlaySessionId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Picks subtitle tracks for the subtitle setting. Works on the server's streams and on the
/// player's tracks alike.
nonisolated enum TrackChooser {
    struct Candidate: Equatable, Sendable {
        let id: Int
        let language: String?
        let isForced: Bool
        let isHearingImpaired: Bool
        let isDefault: Bool
    }

    static func subtitle(from candidates: [Candidate], audioLanguage: String?, mode: AppSettings.SubtitleMode, language: String) -> Int? {
        let inLanguage = candidates.filter { AppSettings.sameLanguage($0.language, language) }
        let forced = inLanguage.first { $0.isForced }
            ?? candidates.first { $0.isForced && AppSettings.sameLanguage($0.language, audioLanguage) }
        let full = inLanguage.first { !$0.isForced && !$0.isHearingImpaired } ?? inLanguage.first { !$0.isForced }
        switch mode {
        case .off:
            return nil
        case .forcedOnly:
            return forced?.id
        case .smart:
            // Audio of unknown language is taken to be understood.
            let audioIsUnknown = audioLanguage == nil || audioLanguage == "und" || audioLanguage?.isEmpty == true
            let audioMatches = audioIsUnknown || AppSettings.sameLanguage(audioLanguage, language)
            return audioMatches ? forced?.id : (full ?? forced)?.id
        case .always:
            return (full ?? forced)?.id
        }
    }
}
