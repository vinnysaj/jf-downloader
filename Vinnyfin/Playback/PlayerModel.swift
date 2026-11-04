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

    @ObservationIgnored private var request: PlaybackRequest
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var appliedSubtitlePreference = false
    /// The engine's load returned, so its track lists are complete.
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var lastReportedPaused: Bool?
    @ObservationIgnored private var transcodeAudioIndex: Int?
    @ObservationIgnored private var transcodeSubtitleIndex: Int?
    @ObservationIgnored private var startedReporting = false
    @ObservationIgnored private var isClosed = false

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
        await finishSession(reachedEnd: status == .ended)
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
        await finishSession(reachedEnd: false)
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
        status = .preparing
        title = request.title
        subtitle = nil
        nextEpisode = nil
        segments = []
        upNextDismissed = false
        upNextCountdown = nil
        do {
            let resolved = try await resolver.resolve(request)
            await begin(resolved)
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    private func begin(_ resolved: ResolvedPlayback) async {
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
        nextEpisode = nil
        // A download's own copy, until the server's arrive.
        segments = resolved.segments
        upNextCountdown = nil
        upNextDismissed = false
        clock.time = resolved.startPosition ?? 0
        clock.sourceTime = resolved.startPosition ?? 0
        clock.buffered = 0
        transcodeAudioIndex = nil
        transcodeSubtitleIndex = nil
        appliedSubtitlePreference = false
        isLoaded = false
        startedReporting = false
        lastReportedPaused = nil
        status = .loading
        observeEngine()

        var options = LoadOptions()
        options.externalSubtitles = resolved.externalSubtitles
        options.matchContentEnabled = settings.matchContent
        if !settings.audioLanguage.isEmpty {
            options.preferredAudioLanguages = [settings.audioLanguage]
        }
        if resolved.isTranscode {
            options.nativeRemoteHLS = true
        }
        setNowPlaying(resolved)
        lease.holder = id
        do {
            try await engine.load(url: resolved.url, startPosition: resolved.startPosition, options: options)
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
        Task { await loadExtras(for: resolved) }
    }

    /// The next episode and the skippable segments, which playback doesn't wait for.
    private func loadExtras(for resolved: ResolvedPlayback) async {
        guard let item = resolved.item else { return }
        if let client = accounts.client, let account = accounts.account {
            if let found = try? await client.mediaSegments(itemId: item.id), current?.historyKey == resolved.historyKey {
                segments = found
            }
            if item.isEpisode, let seriesId = item.seriesId {
                if let next = try? await client.episode(after: item.id, seriesId: seriesId, userId: account.userId) {
                    if current?.historyKey == resolved.historyKey { nextEpisode = next }
                    return
                }
            }
        }
        if item.isEpisode, current?.historyKey == resolved.historyKey {
            nextEpisode = downloadedEpisode(item)
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
        engine.clock.$currentTime.dropFirst().receive(on: RunLoop.main).sink { [weak self] time in self?.clock.time = time }
            .store(in: &subscriptions)
        engine.clock.$sourceTime.dropFirst().receive(on: RunLoop.main).sink { [weak self] time in self?.clock.sourceTime = time }
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
            status = .playing
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
            if status == .buffering || status == .loading { status = .playing }
        default:
            break
        }
    }

    private func audioTracksChanged(_ tracks: [TrackInfo], active: Int?) {
        if isTranscoding, let source = current?.mediaSource {
            audioOptions = source.audioStreams.compactMap { stream in
                stream.index.map { TrackOption(id: $0, title: Self.streamTitle(stream), detail: stream.displayTitle) }
            }
            selectedAudio = transcodeAudioIndex ?? source.defaultAudioStreamIndex ?? audioOptions.first?.id
            return
        }
        audioOptions = tracks.map { TrackOption(id: $0.id, title: Self.trackTitle($0), detail: Self.audioDetail($0)) }
        selectedAudio = active
    }

    private func subtitleTracksChanged(_ tracks: [TrackInfo], active: Int?) {
        if isTranscoding, let source = current?.mediaSource {
            subtitleOptions = source.subtitleStreams.compactMap { stream in
                stream.index.map { TrackOption(id: $0, title: Self.streamTitle(stream), detail: stream.codec?.uppercased()) }
            }
            selectedSubtitle = transcodeSubtitleIndex
            // The server adds a text subtitle as an HLS rendition; turn it on.
            if transcodeSubtitleIndex != nil, let rendition = tracks.first, active == nil {
                engine.selectSubtitleTrack(index: rendition.id)
            }
            return
        }
        subtitleOptions = tracks.map { TrackOption(id: $0.id, title: Self.trackTitle($0), detail: Self.subtitleDetail($0)) }
        selectedSubtitle = active
        if isLoaded { applySubtitlePreference(tracks) }
    }

    /// Turns on the subtitle track the subtitle setting asks for, once per playback, after the
    /// load has listed the tracks.
    private func applySubtitlePreference(_ tracks: [TrackInfo]) {
        guard !appliedSubtitlePreference, !isTranscoding, !tracks.isEmpty else { return }
        appliedSubtitlePreference = true
        let audioLanguage = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }?.language
        let candidates = tracks.map {
            TrackChooser.Candidate(id: $0.id, language: $0.language, isForced: $0.isForced,
                                   isHearingImpaired: $0.isHearingImpaired, isDefault: $0.isDefault)
        }
        if let choice = TrackChooser.subtitle(from: candidates, audioLanguage: audioLanguage,
                                              mode: settings.subtitleMode, language: settings.subtitleLanguage) {
            engine.selectSubtitleTrack(index: choice)
        } else if engine.activeSubtitleTrackIndex != nil {
            engine.clearSubtitle()
        }
    }

    // MARK: Commands

    func togglePlayPause() {
        switch status {
        case .ended:
            Task { await load(PlaybackRequest(source: request.source, title: request.title, startFromBeginning: true)) }
        case .failed:
            return
        default:
            engine.togglePlayPause()
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        clock.time = target
        nowPlayingChanged()
        Task { await engine.seek(to: target) }
    }

    func skip(by seconds: Double) {
        seek(to: clock.time + seconds)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        engine.setRate(newRate)
        nowPlayingChanged()
    }

    func chooseAudio(_ id: Int) {
        if isTranscoding {
            transcodeAudioIndex = id
            Task { await reloadTranscode() }
        } else {
            engine.selectAudioTrack(index: id)
        }
    }

    /// Nil turns subtitles off.
    func chooseSubtitle(_ id: Int?) {
        if isTranscoding {
            transcodeSubtitleIndex = id
            Task { await reloadTranscode() }
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

    /// A transcode carries its audio and subtitles in the stream, so changing them asks the
    /// server for a new one at the same spot.
    private func reloadTranscode() async {
        guard let current, let item = current.item, let source = current.mediaSource else { return }
        let audio = transcodeAudioIndex
        let subtitles = transcodeSubtitleIndex
        let position = clock.time
        await finishSession(reachedEnd: false)
        status = .loading
        do {
            let quality = settings.streamingQuality == .original ? VideoQuality.fullHD : settings.streamingQuality
            let resolved = try await resolver.transcode(item: item, source: source, quality: quality,
                                                        audioIndex: audio, subtitleIndex: subtitles, start: position)
            await begin(resolved)
            transcodeAudioIndex = audio
            transcodeSubtitleIndex = subtitles
        } catch {
            fail(error)
        }
    }

    // MARK: Ending

    private func reachedEnd() async {
        await finishSession(reachedEnd: true)
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
        await finishSession(reachedEnd: status == .ended)
        isClosed = true
        subscriptions.removeAll()
        if lease.holder == id {
            lease.holder = nil
            engine.stop()
        }
        onClose?()
    }

    /// Reports where playback stopped and lets go of the session's resources. Safe to call twice.
    private func finishSession(reachedEnd: Bool) async {
        reportTask?.cancel()
        reportTask = nil
        unregisterRemoteCommands()
        Self.keepScreenAwake(false)
        guard let current else { return }
        self.current = nil
        nowPlayingChanged()
        let position = reachedEnd ? (duration > 0 ? duration : clock.time) : clock.time
        await report(.stopped, for: current, position: position)
        if current.isTranscode, let reporting = current.reporting, let client = accounts.client {
            try? await client.stopTranscoding(playSessionId: reporting.playSessionId)
        }
        current.scopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: Reporting

    private enum ReportKind { case started, progress, stopped }

    private func startReporting() {
        reportTask?.cancel()
        guard let current else { return }
        reportTask = Task { [weak self] in
            await self?.report(.started, for: current, position: current.startPosition ?? 0)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if self.status == .playing || self.status == .paused || self.status == .buffering {
                    await self.report(.progress, for: current, position: self.clock.time)
                }
            }
        }
    }

    private func reportPauseChange(paused: Bool) {
        guard let current, startedReporting, lastReportedPaused != paused else { return }
        lastReportedPaused = paused
        Task { await report(.progress, for: current, position: clock.time) }
    }

    /// Tells the server, and keeps the position here. A server that can't be reached is told
    /// later, by `WatchHistory.syncPending`.
    private func report(_ kind: ReportKind, for playback: ResolvedPlayback, position: Double) async {
        let total = duration > 0 ? duration : playback.duration
        var delivered = false
        if let reporting = playback.reporting, let client = accounts.client {
            let report = PlaybackReport(
                ItemId: reporting.itemId,
                MediaSourceId: reporting.mediaSourceId,
                PlaySessionId: reporting.playSessionId,
                PlayMethod: reporting.playMethod,
                PositionTicks: Int64(max(0, position) * 10_000_000),
                IsPaused: status == .paused
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
        guard kind != .started else { return }
        let isServerItem = playback.reporting != nil
        history.record(key: playback.historyKey, position: position, duration: total, needsSync: isServerItem && !delivered)
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
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.engine.togglePlayPause(); return .success }
        add(center.playCommand) { [weak self] _ in self?.engine.play(); return .success }
        add(center.pauseCommand) { [weak self] _ in self?.engine.pause(); return .success }
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
        var name = track.name.trimmingCharacters(in: .whitespaces)
        // Untitled streams get a made-up "ENG (srt)" or "Track 3 (srt)" from the engine, which
        // only repeats the language and the format shown beside it.
        if name.hasSuffix("(\(track.codec))") { name = "" }
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
