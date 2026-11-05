import AetherEngine
import AVFoundation
import Combine
import Foundation
import MediaPlayer
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// The playhead, ten times a second. Kept apart from `PlayerModel` so only the views that show
/// time redraw that often.
@Observable
final class PlaybackClock {
    var time: Double = 0
    /// The media's own timestamp of the frame on screen, which subtitle cues are timed against.
    var sourceTime: Double = 0
    var buffered: Double = 0
}

/// Which playback holds the shared engine. A player that is closing stops the engine only if it
/// still holds it, so it can't stop the playback that replaced it.
final class EngineLease {
    var holder: UUID?
}

/// One audio or subtitle choice in the player's menus.
struct TrackOption: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String?
}

/// The audio and subtitles chosen in a playback, described so that another version of the
/// title, whose tracks are numbered differently, can choose the same.
struct TrackSelection {
    var audio: TrackChooser.Candidate?
    /// Nil when subtitles are off.
    var subtitle: TrackChooser.Candidate?
}

/// A playback on screen: what it is, how it's going, and the commands for it. Drives the shared
/// engine, tells the server how far playback got, and keeps the position for offline use.
@Observable
final class PlayerModel: Identifiable {
    let id = UUID()

    enum Status: Equatable {
        case preparing
        case loading
        case playing
        case paused
        case buffering
        case ended
        case failed(String)

        /// Getting ready to play or playing: the picture needs the connection.
        var isUnderway: Bool {
            switch self {
            case .preparing, .loading, .playing, .buffering: true
            case .paused, .ended, .failed: false
            }
        }
    }

    private(set) var status = Status.preparing {
        didSet {
            if status.isUnderway != oldValue.isUnderway { onUnderwayChanged?(status.isUnderway) }
        }
    }
    private(set) var title: String
    private(set) var subtitle: String?
    private(set) var current: ResolvedPlayback?
    private(set) var duration: Double = 0
    private(set) var videoFormat = VideoFormat.sdr
    /// The picture's shape in display pixels, for placing picture subtitles.
    private(set) var videoSize: CGSize?
    private(set) var audioOptions: [TrackOption] = []
    private(set) var subtitleOptions: [TrackOption] = []
    private(set) var selectedAudio: Int?
    private(set) var selectedSubtitle: Int?
    private(set) var cues: [SubtitleCue] = []
    private(set) var nextEpisode: JellyfinItem?
    private(set) var segments: [MediaSegment] = []
    private(set) var rate: Float = 1
    /// Seconds left before the next episode starts by itself; nil when it isn't counting down.
    private(set) var upNextCountdown: Int?
    /// A word about the playback, such as a move to a lower quality, shown for a few seconds.
    private(set) var notice: String?
    var upNextDismissed = false
    let clock = PlaybackClock()
    let engine: AetherEngine

    @ObservationIgnored private let resolver: PlaybackResolver
    @ObservationIgnored private let lease: EngineLease
    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private let settings: AppSettings
    /// Finds a downloaded episode to play next when the server can't be reached.
    @ObservationIgnored private let downloadedEpisode: (_ after: JellyfinItem) -> JellyfinItem?
    /// Told when playback starts or stops being underway; a new model starts out underway.
    @ObservationIgnored var onUnderwayChanged: ((Bool) -> Void)?
    /// Told once, when the player closes for good.
    @ObservationIgnored var onClose: (() -> Void)?
    /// The group watching this together, through SharePlay, which the viewer's changes go through.
    @ObservationIgnored weak var sharing: (any PlaybackSharing)?

    @ObservationIgnored private var request: PlaybackRequest
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var appliedSubtitlePreference = false
    /// The engine's load returned, so its track lists are complete.
    @ObservationIgnored private var isLoaded = false
    /// The stream's first frame is on screen, or it has none to show. Until then a playing engine
    /// reads as loading: its clock and sound can run for seconds ahead of the picture, as when a
    /// start far from a keyframe is decoded in software.
    @ObservationIgnored private var isPresenting = false
    @ObservationIgnored private var lastReportedPaused: Bool?
    @ObservationIgnored private var startedReporting = false
    /// Telling the server that the last session stopped, and giving the title its position.
    @ObservationIgnored private(set) var stopReport: Task<Void, Never>?
    /// The server's titles played here, and the shows of the episodes among them, whose watch
    /// state the playback changed.
    @ObservationIgnored private(set) var playedTitleIds: Set<String> = []
    /// The title whose next episode was asked for, and the version whose segments and chapters.
    @ObservationIgnored private var extrasRequestedFor: ExtrasKey?
    /// The audio and subtitles chosen in the version this one stands in for.
    @ObservationIgnored private var carriedTracks: TrackSelection?
    @ObservationIgnored private var connectionWatch = ConnectionWatch()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    /// The streams the request asks to start with, until the playback it started has them.
    @ObservationIgnored private var askedStreams: PlaybackRequest.StartingPoint?

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")
    static let skipInterval: Double = 10

    init(
        request: PlaybackRequest,
        engine: AetherEngine,
        lease: EngineLease,
        resolver: PlaybackResolver,
        accounts: AccountStore,
        history: WatchHistory,
        settings: AppSettings,
        downloadedEpisode: @escaping (JellyfinItem) -> JellyfinItem?
    ) {
        self.request = request
        self.engine = engine
        self.lease = lease
        self.resolver = resolver
        self.accounts = accounts
        self.history = history
        self.settings = settings
        self.downloadedEpisode = downloadedEpisode
        title = request.title
    }

    var isTranscoding: Bool { current?.isTranscode ?? false }
    var isPlaying: Bool { status == .playing || status == .buffering }
    var item: JellyfinItem? { current?.item }
    /// The scrub previews, from the server for a stream and from the saved files for a download.
    var trickplay: TrickplayTiles? { current?.trickplay }
    var chapters: [ChapterMark] { current?.chapters ?? [] }

    /// The intro, recap, preview or credits being played, which the player offers to skip.
    func skippableSegment(at time: Double) -> MediaSegment? {
        guard settings.showSkipButtons else { return nil }
        return segments.first { $0.skipTitle != nil && time >= $0.start && time < $0.end - 1 }
    }

    /// Whether the up-next card belongs on screen at `time`: in the credits, or the last 30 seconds.
    func showsUpNext(at time: Double) -> Bool {
        guard nextEpisode != nil, !upNextDismissed, duration > 120 else { return false }
        if status == .ended { return true }
        if let outro = segments.first(where: { $0.type == "Outro" }), time >= outro.start { return true }
        return duration - time <= 30
    }

    // MARK: Starting

    func start() async {
        await load(request)
    }

    /// Plays another episode, such as the next one, in place of this one.
    func play(_ episode: JellyfinItem) async {
        countdownTask?.cancel()
        upNextCountdown = nil
        await switchTo(episode)
    }

    private func switchTo(_ episode: JellyfinItem) async {
        finishSession(reachedEnd: status == .ended)
        await load(.item(episode))
    }

    func retry() async {
        await load(request)
    }

    /// Rebuilds the picture after the system took the video pipeline away in the background.
    func restoreAfterBackground() async {
        guard current != nil, engine.needsForegroundVideoRestore else { return }
        do {
            try await engine.reloadAtCurrentPosition()
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    /// Plays the same version again through the server's transcoder, for a file this device
    /// can't play directly.
    func retryTranscoded() async {
        guard let current, let item = current.item, let source = current.mediaSource, !current.isTranscode else { return }
        let position = clock.time > 0 ? clock.time : current.startPosition
        finishSession(reachedEnd: false)
        status = .loading
        do {
            let quality = settings.streamingQuality == .original ? VideoQuality.fullHD : settings.streamingQuality
            let resolved = try await resolver.transcode(item: item, source: source, quality: quality,
                                                        audioIndex: nil, subtitleIndex: nil, start: position)
            await begin(resolved)
        } catch {
            fail(error)
        }
    }

    private func load(_ request: PlaybackRequest) async {
        self.request = request
        askedStreams = request.startingPoint
        status = .preparing
        title = request.title
        subtitle = nil
        nextEpisode = nil
        segments = []
        upNextDismissed = false
        upNextCountdown = nil
        extrasRequestedFor = nil
        do {
            let resolved = try await resolver.resolve(request)
            // A download's own copy, until the server's arrive.
            segments = resolved.segments
            await begin(resolved)
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    /// Starts a stream of the title `load` resolved: the version it chose, or one standing in
    /// for it, which keeps the audio and subtitles `tracks` describe.
    private func begin(_ resolved: ResolvedPlayback, carrying tracks: TrackSelection? = nil) async {
        guard !isClosed else { return }
        current = resolved
        title = resolved.title
        subtitle = resolved.subtitle
        duration = resolved.duration ?? 0
        videoFormat = .sdr
        videoSize = nil
        audioOptions = []
        subtitleOptions = []
        selectedAudio = nil
        selectedSubtitle = nil
        cues = []
        clock.time = resolved.startPosition ?? 0
        clock.sourceTime = resolved.startPosition ?? 0
        clock.buffered = 0
        carriedTracks = tracks
        // A version standing in for another keeps that one's tracks, whatever the request asked.
        if tracks != nil { askedStreams = nil }
        appliedSubtitlePreference = false
        isLoaded = false
        isPresenting = false
        startedReporting = false
        lastReportedPaused = nil
        watchTask?.cancel()
        status = .loading
        observeEngine()

        var options = LoadOptions()
        options.externalSubtitles = resolved.externalSubtitles
        options.matchContentEnabled = settings.matchContent
        options.autoplay = sharing?.startsByItself(resolved.item?.id) ?? true
        var audioStreamIndex: Int32?
        if let asked = askedStreams?.audioStreamIndex, !resolved.isTranscode {
            // An audio stream's index in the file is the server's.
            audioStreamIndex = Int32(asked)
        } else if let audio = tracks?.audio, !resolved.isTranscode {
            // By the server's list of the version's streams when it has one, else by language.
            let streams = resolved.mediaSource?.audioStreams.compactMap(TrackChooser.Candidate.init) ?? []
            audioStreamIndex = TrackChooser.same(as: audio, in: streams).map(Int32.init)
            options.preferredAudioLanguages = [audio.language, settings.audioLanguage].compactMap { $0 }.filter { !$0.isEmpty }
        } else if !settings.audioLanguage.isEmpty {
            options.preferredAudioLanguages = [settings.audioLanguage]
        }
        if resolved.isTranscode {
            options.nativeRemoteHLS = true
        }
        setNowPlaying(resolved)
        lease.holder = id
        do {
            try await engine.load(url: resolved.url, startPosition: resolved.startPosition, options: options,
                                  audioSourceStreamIndex: audioStreamIndex)
        } catch is CancellationError {
            return
        } catch {
            fail(error)
            return
        }
        guard !isClosed else { return }
        isLoaded = true
        // A speed picked for one episode carries on to the next.
        if rate != 1 { engine.setRate(rate) }
        applySubtitlePreference(engine.subtitleTracks)
        registerRemoteCommands()
        Self.keepScreenAwake(true)
        startReporting()
        if resolved.isStream { watchConnection() }
        let extras = ExtrasKey(title: resolved.historyKey, version: resolved.mediaSource?.versionItemId)
        if extrasRequestedFor != extras {
            let isNewTitle = extrasRequestedFor?.title != extras.title
            // Another version's skip markers don't fit this one's timeline.
            if !isNewTitle { segments = resolved.segments }
            extrasRequestedFor = extras
            Task { await loadExtras(for: resolved, includingNextEpisode: isNewTitle) }
        }
    }

    private struct ExtrasKey: Equatable {
        let title: String
        let version: String?
    }

    /// Whether `resolved` is still the version playing.
    private func isPlaying(_ resolved: ResolvedPlayback) -> Bool {
        current?.historyKey == resolved.historyKey && current?.mediaSource?.id == resolved.mediaSource?.id
    }

    /// What playback doesn't wait for: the skippable segments of the version playing, its
    /// chapters when it isn't the item's own version, and once for the title, the next episode.
    /// A download falls back on its saved segments and on the next episode downloaded. What the
    /// server can't give is logged, and for a stream, where the skip buttons, chapters or next
    /// episode would be missed, the player says so once for the title.
    private func loadExtras(for resolved: ResolvedPlayback, includingNextEpisode: Bool) async {
        guard let item = resolved.item else { return }
        let version = resolved.mediaSource?.versionItemId ?? item.id
        var missing: [String] = []
        var lastError: (any Error)?
        var foundNext = false
        var nextFailed = false
        if let client = accounts.client, let account = accounts.account {
            do {
                let found = try await client.mediaSegments(itemId: version)
                if isPlaying(resolved) { segments = found }
            } catch JellyfinError.http(let status, _) where status == 404 {
                // The server keeps no segments for it.
            } catch is CancellationError {
                return
            } catch {
                Self.log.notice("Couldn't load the segments to skip: \(error.localizedDescription, privacy: .public)")
                if resolved.segments.isEmpty { missing.append("the buttons to skip intros and credits") }
                lastError = error
            }
            if resolved.isStream, let source = resolved.mediaSource, version != item.id {
                do {
                    let detail = try await client.item(id: version, userId: account.userId)
                    if isPlaying(resolved) { current?.chapters = PlaybackResolver.chapters(of: detail, playing: source, client: client) }
                } catch JellyfinError.http(let status, _) where status == 404 {
                    // A version that isn't an item of its own has no chapters.
                } catch is CancellationError {
                    return
                } catch {
                    Self.log.notice("Couldn't load the version's chapters: \(error.localizedDescription, privacy: .public)")
                    missing.append("the chapters")
                    lastError = error
                }
            }
            if includingNextEpisode, item.isEpisode, let seriesId = item.seriesId {
                do {
                    let next = try await client.episode(after: item.id, seriesId: seriesId, userId: account.userId)
                    if current?.historyKey == resolved.historyKey { nextEpisode = next }
                    foundNext = true
                } catch is CancellationError {
                    return
                } catch {
                    Self.log.notice("Couldn't find the next episode: \(error.localizedDescription, privacy: .public)")
                    nextFailed = true
                    lastError = error
                }
            }
        }
        guard isPlaying(resolved), includingNextEpisode else { return }
        if item.isEpisode, !foundNext {
            nextEpisode = downloadedEpisode(item)
            if nextEpisode == nil, nextFailed { missing.append("the next episode") }
        }
        if resolved.isStream, !missing.isEmpty, let lastError {
            show("Couldn't load \(missing.formatted(.list(type: .and))): \(lastError.localizedDescription)", for: 6)
        }
    }

    private func fail(_ error: any Error) {
        Self.log.error("Playback failed: \(String(describing: error), privacy: .public)")
        status = .failed(error.localizedDescription)
        Self.keepScreenAwake(false)
    }

    // MARK: Engine state

    /// Follows the engine from here on. Its publishers replay their current values on
    /// subscription, which belong to whatever played last (its ending, its duration), so the
    /// replay is dropped: taking it marked a next episode watched as it started.
    private func observeEngine() {
        subscriptions.removeAll()
        engine.$state.dropFirst().receive(on: RunLoop.main).sink { [weak self] state in self?.engineStateChanged(state) }
            .store(in: &subscriptions)
        engine.$playbackPhase.dropFirst().receive(on: RunLoop.main).sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &subscriptions)
        engine.$startupProgress.dropFirst().receive(on: RunLoop.main).sink { [weak self] progress in self?.startupChanged(progress) }
            .store(in: &subscriptions)
        engine.$duration.dropFirst().receive(on: RunLoop.main).sink { [weak self] duration in
            if duration > 0 { self?.duration = duration }
        }
        .store(in: &subscriptions)
        engine.$videoFormat.dropFirst().receive(on: RunLoop.main).sink { [weak self] format in self?.videoFormat = format }
            .store(in: &subscriptions)
        engine.$sourceVideoWidth.combineLatest(engine.$sourceVideoHeight).dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] width, height in
                guard let self else { return }
                self.videoSize = width > 0 && height > 0
                    ? CGSize(width: Double(width) * self.engine.sourceVideoPixelAspectRatio, height: Double(height))
                    : nil
            }
            .store(in: &subscriptions)
        engine.$subtitleCues.dropFirst().receive(on: RunLoop.main).sink { [weak self] cues in self?.cues = cues }
            .store(in: &subscriptions)
        engine.$audioTracks.combineLatest(engine.$activeAudioTrackIndex).dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] tracks, active in self?.audioTracksChanged(tracks, active: active) }
            .store(in: &subscriptions)
        engine.$subtitleTracks.combineLatest(engine.$activeSubtitleTrackIndex).dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] tracks, active in self?.subtitleTracksChanged(tracks, active: active) }
            .store(in: &subscriptions)
        // The engine sets its clock to zero as it loads, before seeking to the start position;
        // until the load is done the timeline keeps the start position `begin` gave it.
        engine.clock.$currentTime.dropFirst().receive(on: RunLoop.main).sink { [weak self] time in
            guard let self, self.isLoaded else { return }
            self.clock.time = time
        }
        .store(in: &subscriptions)
        engine.clock.$sourceTime.dropFirst().receive(on: RunLoop.main).sink { [weak self] time in
            guard let self, self.isLoaded else { return }
            self.clock.sourceTime = time
        }
        .store(in: &subscriptions)
        engine.clock.$bufferedPosition.dropFirst().receive(on: RunLoop.main).sink { [weak self] position in self?.clock.buffered = position }
            .store(in: &subscriptions)
    }

    private func engineStateChanged(_ state: PlaybackState) {
        defer { nowPlayingChanged() }
        switch state {
        case .ended:
            guard status != .ended else { return }
            status = .ended
            Self.keepScreenAwake(false)
            Task { await reachedEnd() }
        case .error(let message):
            status = .failed(message)
            Self.keepScreenAwake(false)
        case .paused:
            if status != .ended { status = .paused }
            reportPauseChange(paused: true)
        case .playing:
            status = isPresenting ? .playing : .loading
            reportPauseChange(paused: false)
        case .loading, .seeking, .idle:
            break
        }
    }

    private func phaseChanged(_ phase: PlaybackPhase) {
        switch phase {
        case .rebuffering, .stalled, .seeking:
            if status == .playing { status = .buffering }
        case .playing:
            if isPresenting, status == .buffering || status == .loading { status = .playing }
        default:
            break
        }
    }

    /// A picture that comes up after the engine started playing turns loading into playing.
    private func startupChanged(_ progress: StartupProgress?) {
        isPresenting = progress?.isComplete == true
        guard isPresenting, status == .loading, engine.state == .playing else { return }
        status = .playing
        phaseChanged(engine.playbackPhase)
        nowPlayingChanged()
    }

    private func audioTracksChanged(_ tracks: [TrackInfo], active: Int?) {
        if let transcode = current?.transcode, let source = current?.mediaSource {
            audioOptions = source.audioStreams.compactMap { stream in
                stream.index.map { TrackOption(id: $0, title: Self.streamTitle(stream), detail: stream.displayTitle) }
            }
            selectedAudio = transcode.audioIndex ?? source.defaultAudioStreamIndex ?? audioOptions.first?.id
            return
        }
        audioOptions = tracks.map { TrackOption(id: $0.id, title: Self.trackTitle($0), detail: Self.audioDetail($0)) }
        let previous = selectedAudio
        selectedAudio = active
        if isLoaded, previous != active { reportProgressNow() }
    }

    private func subtitleTracksChanged(_ tracks: [TrackInfo], active: Int?) {
        if let transcode = current?.transcode, let source = current?.mediaSource {
            subtitleOptions = source.subtitleStreams.compactMap { stream in
                stream.index.map { TrackOption(id: $0, title: Self.streamTitle(stream), detail: stream.codec?.uppercased()) }
            }
            selectedSubtitle = transcode.subtitleIndex
            // The server lists its text subtitles as HLS renditions; turn on the one asked for.
            if let index = transcode.subtitleIndex,
               let asked = source.subtitleStreams.first(where: { $0.index == index }).flatMap(TrackChooser.Candidate.init),
               let rendition = TrackChooser.same(as: asked, in: tracks.map(TrackChooser.Candidate.init)), active != rendition {
                engine.selectSubtitleTrack(index: rendition)
            }
            return
        }
        subtitleOptions = tracks.map { TrackOption(id: $0.id, title: Self.trackTitle($0), detail: Self.subtitleDetail($0)) }
        let previous = selectedSubtitle
        selectedSubtitle = active
        if isLoaded {
            applySubtitlePreference(tracks)
            if previous != active { reportProgressNow() }
        }
    }

    /// Turns on the subtitle track the subtitle setting asks for, once per playback, after the
    /// load has listed the tracks. A version standing in for another keeps that one's choice,
    /// subtitles off included, when it has the same.
    private func applySubtitlePreference(_ tracks: [TrackInfo]) {
        guard !appliedSubtitlePreference, !isTranscoding, !tracks.isEmpty else { return }
        appliedSubtitlePreference = true
        let candidates = tracks.map(TrackChooser.Candidate.init)
        let choice: Int?
        if let asked = askedStreams?.subtitleStreamIndex {
            choice = asked < 0 ? nil : streamMap.trackId(forStream: asked) ?? preferredSubtitle(from: candidates)
            askedStreams = nil
        } else if let carried = carriedTracks, let subtitle = carried.subtitle {
            choice = TrackChooser.same(as: subtitle, in: candidates) ?? preferredSubtitle(from: candidates)
        } else if carriedTracks != nil {
            choice = nil
        } else {
            choice = preferredSubtitle(from: candidates)
        }
        if let choice {
            engine.selectSubtitleTrack(index: choice)
        } else if engine.activeSubtitleTrackIndex != nil {
            engine.clearSubtitle()
        }
    }

    private func preferredSubtitle(from candidates: [TrackChooser.Candidate]) -> Int? {
        let audioLanguage = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }?.language
        return TrackChooser.subtitle(from: candidates, audioLanguage: audioLanguage,
                                     mode: settings.subtitleMode, language: settings.subtitleLanguage)
    }

    // MARK: Commands

    // The viewer's commands, from the controls, the system's remote commands and other devices.
    // Watched together, the transport goes to the group, which applies it everywhere through the
    // group commands below.

    func togglePlayPause() {
        switch status {
        case .ended:
            // The group starts over together; a stream that ended plays again from a new load.
            if sharing?.share(.seek(0)) == true { return }
            Task { await load(PlaybackRequest(source: request.source, title: request.title, startFromBeginning: true)) }
        case .failed:
            return
        default:
            if sharing?.share(.rate(isPlaying ? 0 : rate)) == true { return }
            engine.togglePlayPause()
        }
    }

    func play() {
        guard status != .ended else { return }
        if sharing?.share(.rate(rate)) == true { return }
        engine.play()
    }

    func pause() {
        if sharing?.share(.rate(0)) == true { return }
        engine.pause()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        clock.time = target
        if sharing?.share(.seek(target)) == true { return }
        connectionWatch.restart()
        nowPlayingChanged()
        Task {
            await engine.seek(to: target)
            reportProgressNow()
        }
    }

    func skip(by seconds: Double) {
        seek(to: clock.time + seconds)
    }

    /// Paused, the speed waits for the next play, here and in a group.
    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying, sharing?.share(.rate(newRate)) == true { return }
        engine.setRate(newRate)
        nowPlayingChanged()
    }

    func chooseAudio(_ id: Int) {
        if let transcode = current?.transcode {
            selectedAudio = id
            Task { await reloadTranscode(audioIndex: id, subtitleIndex: transcode.subtitleIndex) }
        } else {
            engine.selectAudioTrack(index: id)
        }
    }

    /// Nil turns subtitles off.
    func chooseSubtitle(_ id: Int?) {
        if let transcode = current?.transcode {
            selectedSubtitle = id
            Task { await reloadTranscode(audioIndex: transcode.audioIndex, subtitleIndex: id) }
        } else if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
    }

    func cancelUpNext() {
        countdownTask?.cancel()
        upNextCountdown = nil
        upNextDismissed = true
    }

    func playNextEpisode() async {
        guard let nextEpisode else { return }
        await play(nextEpisode)
    }

    /// The episode before this one; the start of this one when there's none before it.
    func playPreviousEpisode() async {
        guard let item, item.isEpisode, let seriesId = item.seriesId, let client = accounts.client,
              let account = accounts.account else {
            seek(to: 0)
            return
        }
        do {
            if let previous = try await client.episode(before: item.id, seriesId: seriesId, userId: account.userId) {
                await play(previous)
            } else {
                seek(to: 0)
            }
        } catch {
            guard !error.isCancellation else { return }
            show("Couldn't find the episode before this one: \(error.localizedDescription)", for: 6)
        }
    }

    // MARK: Streams by the server's numbers

    /// The server's index of the audio stream playing; nil for a file of this device's.
    var audioStreamIndex: Int? {
        guard let current, current.reporting != nil, let selectedAudio else { return nil }
        return current.isTranscode ? selectedAudio : streamMap.streamIndex(forTrack: selectedAudio)
    }

    /// The server's index of the subtitle stream showing, -1 with subtitles off; nil for a file of
    /// this device's.
    var subtitleStreamIndex: Int? {
        guard let current, current.reporting != nil else { return nil }
        guard let selectedSubtitle else { return -1 }
        return current.isTranscode ? selectedSubtitle : streamMap.streamIndex(forTrack: selectedSubtitle)
    }

    /// Plays the audio stream the server numbers `index`, as another device asks.
    func chooseAudio(streamIndex index: Int) {
        if isTranscoding {
            chooseAudio(index)
        } else if let track = streamMap.trackId(forStream: index) {
            chooseAudio(track)
        } else {
            show("This version has no audio track \(index), which another device asked for.", for: 4)
        }
    }

    /// Shows the subtitle stream the server numbers `index`, or none, as another device asks.
    func chooseSubtitle(streamIndex index: Int?) {
        guard let index else {
            chooseSubtitle(nil)
            return
        }
        if isTranscoding {
            chooseSubtitle(index)
        } else if let track = streamMap.trackId(forStream: index) {
            chooseSubtitle(track)
        } else {
            show("These subtitles, which another device asked for, didn't load here.", for: 4)
        }
    }

    private var streamMap: StreamIndexMap {
        StreamIndexMap(streams: current?.mediaSource?.mediaStreams ?? [], tracks: engine.audioTracks + engine.subtitleTracks)
    }

    // MARK: Group commands

    /// The server item asked for, while it loads and once it plays.
    var requestedItemId: String? {
        if case .item(let id, _) = request.source { id } else { nil }
    }
    /// Plays at `rate`, or pauses at 0, as the group watching together asks.
    func applyRate(_ newRate: Float) {
        guard newRate != 0 else {
            engine.pause()
            return
        }
        if rate != newRate {
            rate = newRate
            engine.setRate(newRate)
        }
        engine.play()
        nowPlayingChanged()
    }

    /// Moves to `seconds` exactly, as the group asks. A stream that ended plays again from there.
    func applySeek(to seconds: Double) async {
        if status == .ended {
            await load(PlaybackRequest(source: request.source, title: request.title, startingPoint: .init(position: seconds)))
            return
        }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        clock.time = target
        connectionWatch.restart()
        nowPlayingChanged()
        await engine.seek(to: target, exact: true)
        reportProgressNow()
    }

    /// A transcode carries its audio and subtitles in the stream, so changing them asks the
    /// server for a new one at the same spot and quality.
    private func reloadTranscode(audioIndex: Int?, subtitleIndex: Int?) async {
        guard let current, let item = current.item, let source = current.mediaSource, let transcode = current.transcode else { return }
        let position = clock.time
        finishSession(reachedEnd: false)
        status = .loading
        do {
            let resolved = try await resolver.transcode(item: item, source: source, quality: transcode.quality,
                                                        audioIndex: audioIndex, subtitleIndex: subtitleIndex, start: position)
            await begin(resolved)
        } catch {
            fail(error)
        }
    }

    // MARK: Adaptive quality

    /// Samples the playback once a second for `ConnectionWatch`, and moves to a cheaper stream of
    /// the title when it says the connection can't keep up. The watch starts over with each
    /// stream, and nothing moves back up: the next playback starts at the streaming quality again.
    private func watchConnection() {
        connectionWatch = ConnectionWatch(isTranscode: current?.isTranscode ?? false)
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.settings.adaptiveQuality else {
                    self.connectionWatch.restart()
                    continue
                }
                if let reason = self.connectionWatch.observe(self.connectionSample()) {
                    // In a task of its own: starting the new stream cancels this one.
                    Task { await self.stepDown(because: reason) }
                    return
                }
            }
        }
    }

    private func connectionSample() -> ConnectionWatch.Sample {
        let telemetry = engine.diagnostics.liveTelemetry
        // A stream still starting is wanted, though `status` can read loading or paused until it
        // rolls. A source that's gone, and reconnecting, isn't slow: a cheaper version wouldn't get
        // through either.
        let isWanted = switch engine.playbackPhase {
        case .playing, .loading: true
        case .rebuffering: engine.state != .paused
        default: false
        }
        let declaredBitrate = current?.transcode.map(\.quality.transcodeBitrate)
            ?? current?.mediaSource.flatMap { VersionTraits($0).bitrate }
        return ConnectionWatch.Sample(
            time: ProcessInfo.processInfo.systemUptime,
            isWanted: isWanted,
            position: engine.clock.currentTime,
            rate: Double(rate),
            bufferedAhead: max(0, engine.clock.bufferedPosition - engine.clock.currentTime),
            throughput: telemetry?.networkThroughputMbps.map { $0 * 1_000_000 },
            bitrate: telemetry?.averageBitrateMbps.map { $0 * 1_000_000 } ?? declaredBitrate.map(Double.init)
        )
    }

    /// Moves to a cheaper version of the title, or to a transcode, from the same spot and with
    /// the same audio and subtitles.
    private func stepDown(because reason: ConnectionWatch.Reason) async {
        guard let playing = current, let item = playing.item, let plan = playing.plan else { return }
        let bitrate = engine.diagnostics.liveTelemetry?.averageBitrateMbps.map { Int($0 * 1_000_000) }
        let throughput = connectionWatch.throughput.map { Int($0) }
        guard let target = VersionChooser.planStepDown(from: plan, bitrate: bitrate, throughput: throughput,
                                                       sources: item.mediaSources ?? [], allowTranscoding: settings.allowTranscoding)
        else {
            Self.log.notice("The connection can't keep up (\(String(describing: reason), privacy: .public)), and nothing is cheaper")
            return
        }
        let quality = target.label ?? "a lower quality"
        let kind = if case .transcode = target { "a transcode" } else { "the version" }
        Self.log.notice("""
            The connection can't keep up (\(String(describing: reason), privacy: .public), \(throughput ?? 0) b/s for \
            \(bitrate ?? 0) b/s): moving to \(kind, privacy: .public) at \(quality, privacy: .public)
            """)
        let tracks = currentTrackSelection()
        var resolved: ResolvedPlayback
        do {
            switch target {
            case .direct(let source):
                resolved = try resolver.direct(item: item, source: source, start: nil)
            case .transcode(let source, let quality):
                resolved = try await resolver.transcode(
                    item: item, source: source, quality: quality,
                    audioIndex: tracks.audio.flatMap { TrackChooser.same(as: $0, in: source.audioStreams.compactMap(TrackChooser.Candidate.init)) },
                    subtitleIndex: tracks.subtitle.flatMap { TrackChooser.same(as: $0, in: source.subtitleStreams.compactMap(TrackChooser.Candidate.init)) },
                    start: engine.clock.currentTime)
            }
        } catch {
            // The stream playing goes on as it is, and stays for this playback.
            Self.log.error("Couldn't switch: \(String(describing: error), privacy: .public)")
            show("Couldn't switch to \(quality): \(error.localizedDescription)", for: 8)
            return
        }
        guard !isClosed, current?.reporting?.playSessionId == playing.reporting?.playSessionId else { return }
        // Where the old stream got to while the new one was being asked for.
        resolved.startPosition = engine.clock.currentTime
        // Holds the picture until the new stream's first frame, where the engine can.
        engine.prepareForItemReplacement()
        finishSession(reachedEnd: false)
        await begin(resolved, carrying: tracks)
        if isLoaded { show("Switched to \(quality) to keep playing", for: 4) }
    }

    /// The audio and subtitles playing, described so another version can find its own.
    private func currentTrackSelection() -> TrackSelection {
        if let transcode = current?.transcode, let source = current?.mediaSource {
            let audioIndex = transcode.audioIndex ?? source.defaultAudioStreamIndex
            return TrackSelection(
                audio: (source.audioStreams.first { $0.index == audioIndex } ?? source.audioStreams.first).flatMap(TrackChooser.Candidate.init),
                subtitle: transcode.subtitleIndex.flatMap { index in source.subtitleStreams.first { $0.index == index } }
                    .flatMap(TrackChooser.Candidate.init)
            )
        }
        return TrackSelection(
            audio: engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }.map(TrackChooser.Candidate.init),
            subtitle: engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }.map(TrackChooser.Candidate.init)
        )
    }

    /// Shows `text` over the picture for `seconds` of playback, so a stream slow to start keeps
    /// saying why the picture went.
    private func show(_ text: String, for seconds: Double) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            for await status in Observations({ self.status }) where ![.preparing, .loading, .buffering, .paused].contains(status) {
                break
            }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: Ending

    private func reachedEnd() async {
        finishSession(reachedEnd: true)
        guard nextEpisode != nil, settings.autoplayNextEpisode, !upNextDismissed else { return }
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: 5, through: 1, by: -1) {
                upNextCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            upNextCountdown = nil
            if let next = nextEpisode { await switchTo(next) }
        }
    }

    /// Ends the session for good, as the player is dismissed.
    func close() async {
        guard !isClosed else { return }
        countdownTask?.cancel()
        noticeTask?.cancel()
        finishSession(reachedEnd: status == .ended)
        isClosed = true
        subscriptions.removeAll()
        if lease.holder == id {
            lease.holder = nil
            engine.stop()
        }
        onClose?()
    }

    /// Lets go of the session's resources and tells the server where playback stopped. The
    /// telling doesn't hold up what plays next, as on a slow connection it can take seconds; the
    /// next session's start waits for it instead, so the server hears them in order. Safe to
    /// call twice.
    private func finishSession(reachedEnd: Bool) {
        // The stop waits for the periodic report in flight, and the title's position it gives, so
        // nothing lands after the stop that finished the title and marked it watched.
        let progress = reportTask
        reportTask?.cancel()
        reportTask = nil
        watchTask?.cancel()
        watchTask = nil
        unregisterRemoteCommands()
        Self.keepScreenAwake(false)
        guard let current else { return }
        self.current = nil
        nowPlayingChanged()
        current.scopedURL?.stopAccessingSecurityScopedResource()
        let position = reachedEnd ? (duration > 0 ? duration : clock.time) : clock.time
        let previousReport = stopReport
        // Immediate: the report reads this session's length and pause before the next one starts.
        stopReport = Task.immediate {
            if await self.report(.stopped, for: current, position: position, after: [previousReport, progress]) {
                await self.giveTitleThePosition(of: current)
            }
            guard current.isTranscode, let reporting = current.reporting, let client = self.accounts.client else { return }
            do {
                try await client.stopTranscoding(playSessionId: reporting.playSessionId)
            } catch {
                Self.log.notice("Couldn't stop the server's transcode: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Reporting

    private enum ReportKind { case started, progress, stopped }

    private func startReporting() {
        reportTask?.cancel()
        guard let current else { return }
        if let reporting = current.reporting {
            playedTitleIds.insert(reporting.itemId)
            if let seriesId = current.item?.seriesId { playedTitleIds.insert(seriesId) }
        }
        // Read now: the stop `finishSession` makes for this session waits for this task, which
        // would then wait for it in turn and never report again.
        let previousStop = stopReport
        reportTask = Task { [weak self] in
            await self?.report(.started, for: current, position: current.startPosition ?? 0, after: [previousStop])
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if self.status == .playing || self.status == .paused || self.status == .buffering,
                   await self.report(.progress, for: current, position: self.clock.time), !Task.isCancelled {
                    await self.giveTitleThePosition(of: current)
                }
            }
        }
    }

    private func reportPauseChange(paused: Bool) {
        guard startedReporting, lastReportedPaused != paused else { return }
        lastReportedPaused = paused
        reportProgressNow()
    }

    /// Tells the server at once, for a remote following this playback: after a pause, a seek or
    /// a change of track.
    private func reportProgressNow() {
        guard let current, startedReporting else { return }
        Task { await report(.progress, for: current, position: clock.time) }
    }

    /// Tells the server, once the `earlier` reports have, and keeps the position here. A server
    /// that can't be reached is told later, by `WatchHistory.syncPending`. Says whether the server
    /// was told.
    @discardableResult
    private func report(_ kind: ReportKind, for playback: ResolvedPlayback, position: Double,
                        after earlier: [Task<Void, Never>?] = []) async -> Bool {
        let total = duration > 0 ? duration : playback.duration
        let isPaused = status == .paused
        let isCurrent = current?.reporting?.playSessionId == playback.reporting?.playSessionId
        let audioStream = isCurrent ? audioStreamIndex : nil
        let subtitleStream = isCurrent ? subtitleStreamIndex : nil
        for report in earlier { await report?.value }
        var delivered = false
        if let reporting = playback.reporting, let client = accounts.client {
            let report = PlaybackReport(
                ItemId: reporting.itemId,
                MediaSourceId: reporting.mediaSourceId,
                PlaySessionId: reporting.playSessionId,
                PlayMethod: reporting.playMethod,
                PositionTicks: Int64(max(0, position) * 10_000_000),
                IsPaused: isPaused,
                AudioStreamIndex: audioStream,
                SubtitleStreamIndex: subtitleStream
            )
            do {
                switch kind {
                case .started:
                    try await client.reportPlaybackStart(report)
                    startedReporting = true
                case .progress: try await client.reportPlaybackProgress(report)
                case .stopped: try await client.reportPlaybackStopped(report)
                }
                delivered = true
            } catch {
                Self.log.notice("Couldn't report playback: \(error.localizedDescription, privacy: .public)")
            }
        }
        // A start says nothing new about the position.
        guard kind != .started else { return delivered }
        let isServerItem = playback.reporting != nil
        history.record(key: playback.historyKey, position: position, duration: total, needsSync: isServerItem && !delivered)
        return delivered
    }

    /// Gives the title the position the server keeps for the version playing, when that isn't the
    /// title's own (after a step down, for a version picked, for one of Gelato's other streams),
    /// so lists, Smart Downloads and other clients see where the title got to. Playback goes on
    /// as it is when the server doesn't take it.
    private func giveTitleThePosition(of playback: ResolvedPlayback) async {
        guard let reporting = playback.reporting, let versionId = reporting.mediaSourceId, versionId != reporting.itemId,
              let client = accounts.client, let account = accounts.account else { return }
        do {
            try await client.givePosition(ofVersion: versionId, toItem: reporting.itemId, userId: account.userId)
        } catch {
            guard !error.isCancellation else { return }
            Self.log.notice("""
                Couldn't give \(reporting.itemId, privacy: .public) the position of its version \(versionId, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: Now Playing

    /// On iPhone, iPad and Apple TV the engine's Now Playing session carries the card and the
    /// remote commands; on the Mac and Vision Pro they go to the shared system centers.
    private var commandCenter: MPRemoteCommandCenter? {
        #if os(iOS) || os(tvOS)
        engine.videoNowPlayingSession?.remoteCommandCenter
        #else
        MPRemoteCommandCenter.shared()
        #endif
    }

    private func setNowPlaying(_ playback: ResolvedPlayback) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: playback.title]
        if let subtitle = playback.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        #if os(iOS) || os(tvOS)
        engine.setVideoNowPlayingInfo(info)
        #else
        nowPlayingIdentity = info
        publishNowPlaying()
        #endif
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = playback.title as NSString
        titleItem.extendedLanguageTag = "und"
        engine.setExternalMetadata([titleItem])
    }

    #if !(os(iOS) || os(tvOS))
    @ObservationIgnored private var nowPlayingIdentity: [String: Any] = [:]

    /// The system keeps the clock running from the elapsed time and rate given here, so it is
    /// republished whenever either changes.
    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard current != nil else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info = nowPlayingIdentity
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clock.time
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
    #endif

    private func nowPlayingChanged() {
        #if !(os(iOS) || os(tvOS))
        publishNowPlaying()
        #endif
    }

    private func registerRemoteCommands() {
        unregisterRemoteCommands()
        guard let center = commandCenter else { return }
        func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: handler)))
        }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        add(center.playCommand) { [weak self] _ in self?.play(); return .success }
        add(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.skipForwardCommand) { [weak self] _ in self?.skip(by: Self.skipInterval); return .success }
        add(center.skipBackwardCommand) { [weak self] _ in self?.skip(by: -Self.skipInterval); return .success }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func unregisterRemoteCommands() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
    }

    // MARK: Helpers

    static func keepScreenAwake(_ awake: Bool) {
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static func trackTitle(_ track: TrackInfo) -> String {
        let language = languageName(track.language)
        let name = TrackChooser.ownName(of: track) ?? ""
        var title = language ?? (name.isEmpty ? "Track \(track.id)" : name)
        if let language, !name.isEmpty, name.lowercased() != language.lowercased(), !name.lowercased().hasPrefix(language.lowercased()) {
            title += " (\(name))"
        }
        if track.isForced { title += " · Forced" }
        if track.isHearingImpaired { title += " · SDH" }
        if track.isCommentary { title += " · Commentary" }
        return title
    }

    static func audioDetail(_ track: TrackInfo) -> String {
        var parts = [codecName(track.codec, profile: track.profile)]
        if let layout = channelLayoutName(track.channels) { parts.append(layout) }
        if track.isAtmos { parts.append("Atmos") }
        if track.isDTSX { parts.append("DTS:X") }
        return parts.joined(separator: " ")
    }

    static func subtitleDetail(_ track: TrackInfo) -> String {
        var parts = [codecName(track.codec, profile: nil)]
        if track.isExternal { parts.append("External") }
        return parts.joined(separator: " · ")
    }

    static func streamTitle(_ stream: MediaStream) -> String {
        var title = languageName(stream.language) ?? stream.title ?? stream.displayTitle ?? "Track \(stream.index ?? 0)"
        if stream.isForced == true { title += " · Forced" }
        if stream.isHearingImpaired == true { title += " · SDH" }
        return title
    }

    static func codecName(_ codec: String, profile: String?) -> String {
        if let profile, profile.contains("Atmos") || profile.contains("DTS:X") || profile.contains("DTS-HD") { return profile }
        switch codec.lowercased() {
        case "eac3": return "Dolby Digital Plus"
        case "ac3": return "Dolby Digital"
        case "truehd": return "Dolby TrueHD"
        // FFmpeg calls DTS "dca", after its Coherent Acoustics core.
        case "dts", "dca": return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "mp2": return "MP2"
        case "vorbis": return "Vorbis"
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "webvtt", "vtt": return "WebVTT"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvd_subtitle", "dvdsub": return "VobSub"
        case "dvb_subtitle", "dvbsub": return "DVB"
        case "mov_text": return "Text"
        case let pcm where pcm.hasPrefix("pcm_"): return "PCM"
        default: return codec.uppercased()
        }
    }

    static func channelLayoutName(_ channels: Int) -> String? {
        switch channels {
        case 0: nil
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }
}
