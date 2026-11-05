#if os(iOS) || os(macOS)
import Foundation
import Observation
import OSLog

/// How a playback sent to another device is going, from that device's session.
nonisolated enum RemotePhase: Equatable, Sendable {
    /// Asked to play the item at `since`; not playing it yet.
    case starting(itemId: String, since: Date)
    /// Playing, or between episodes; last seen playing at `lastSeen`.
    case playing(lastSeen: Date)
    /// Gone, with why.
    case lost(String)

    /// How long a device has to start what it was sent. vinnyfin asks its server for the title
    /// and opens the stream in a few seconds; more means the app isn't there to take it.
    static let startTimeout: TimeInterval = 25
    /// How long a device may play nothing, as between episodes, before it has stopped.
    static let idleTimeout: TimeInterval = 8

    /// The phase after the device's session was last seen as `session`, nil when the server no
    /// longer lists it.
    func next(session: RemoteSession?, targetName: String, now: Date) -> RemotePhase {
        guard let session else { return .lost("\(targetName) isn't connected anymore.") }
        let isPlaying = session.nowPlayingItem != nil
        switch self {
        case .starting(let itemId, let since):
            // What it played before doesn't count.
            if session.nowPlayingItem?.id == itemId { return .playing(lastSeen: now) }
            return now.timeIntervalSince(since) > Self.startTimeout
                ? .lost("\(targetName) didn't start playing. The app there may have closed or gone to the background.")
                : self
        case .playing(let lastSeen):
            if isPlaying { return .playing(lastSeen: now) }
            return now.timeIntervalSince(lastSeen) > Self.idleTimeout ? .lost("\(targetName) stopped playing.") : self
        case .lost:
            return self
        }
    }
}

/// This device as a remote for another: a playback sent there through Jellyfin's remote control,
/// followed from that device's session, and the commands that drive it.
@Observable
final class RemoteControl {
    struct Target: Equatable {
        let sessionId: String
        let name: String
        let supportedCommands: [String]
    }

    private(set) var target: Target?
    /// The device's session as last seen.
    private(set) var session: RemoteSession?
    private(set) var phase = RemotePhase.lost("") {
        didSet {
            switch (oldValue, phase) {
            case (.lost, _): break
            case (_, .lost): playbackEnded()
            default: break
            }
        }
    }
    /// When `session` was seen, which the position counts on from while it plays.
    private(set) var seenAt = Date()
    /// What plays there is the last episode of its show, as the server says, so there's no
    /// next one to skip to. False until the server has said, and for anything not an episode.
    private(set) var isLastEpisode = false
    /// Why the last command didn't get through.
    var error: String?
    /// The remote's screen is up, over the app.
    var showsScreen = false

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let socket: SessionSocket
    @ObservationIgnored private let player: PlayerCoordinator
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var lastPush = Date.distantPast
    /// The episode whose place in its show was asked about, and the asking.
    @ObservationIgnored private var nextEpisodeLookup: (itemId: String, task: Task<Void, Never>)?

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "remote")

    init(accounts: AccountStore, socket: SessionSocket, player: PlayerCoordinator, defaults: UserDefaults = .standard) {
        self.accounts = accounts
        self.socket = socket
        self.player = player
        self.defaults = defaults
    }

    var isActive: Bool { target != nil }

    // MARK: Devices

    /// The vinnyfin devices on this server that the Play On list has shown.
    var knownDevices: [KnownDevice] {
        guard let key = knownDevicesKey, let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([KnownDevice].self, from: data)
        } catch {
            Self.log.error("Couldn't read the known devices: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Remembers the vinnyfin devices the list shows now.
    func noteTargets(_ targets: [PlayTarget]) {
        guard let key = knownDevicesKey else { return }
        let known = KnownDevice.remembering(targets, in: knownDevices)
        do {
            defaults.set(try JSONEncoder().encode(known), forKey: key)
        } catch {
            Self.log.error("Couldn't save the known devices: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The devices are the server's: each signs in to it on its own.
    private var knownDevicesKey: String? {
        accounts.account.map { "knownDevices.\($0.serverId)" }
    }

    var isStarting: Bool {
        if case .starting = phase { true } else { false }
    }

    var isLost: Bool {
        if case .lost = phase { true } else { false }
    }

    /// What plays there: what was sent, until the device reports it.
    var item: JellyfinItem? { isStarting ? sent?.item : session?.nowPlayingItem }

    var isPaused: Bool { isStarting || session?.playState.isPaused != false }

    /// Where the device's playback is at `date`, counting on from the last report while it plays.
    func position(at date: Date) -> Double {
        if isStarting { return sent?.start ?? 0 }
        guard let session else { return 0 }
        var position = session.position
        if session.nowPlayingItem != nil, !session.playState.isPaused {
            position += max(0, date.timeIntervalSince(seenAt))
        }
        if duration > 0 { position = min(position, duration) }
        return position
    }

    var duration: Double { item?.runtimeSeconds ?? 0 }

    // MARK: Sending

    /// Plays what plays here on the device from the same second, in the same version and with
    /// the same streams. The caller stops it here once this returns.
    func handOver(_ model: PlayerModel, to target: PlayTarget) async throws {
        guard let client = accounts.client, let item = model.item else { throw RemoteError.nothingToSend }
        let start = model.clock.time
        try await client.play(itemId: item.id, onSession: target.id, start: start,
                              mediaSourceId: model.current?.mediaSource?.id, audioStreamIndex: model.audioStreamIndex,
                              subtitleStreamIndex: model.subtitleStreamIndex)
        follow(target, sent: Sent(item: item, start: start))
    }

    /// Plays a title on the device from `start` seconds, in a version when one was picked.
    func send(_ item: JellyfinItem, mediaSourceId: String?, from start: Double, to target: PlayTarget) async throws {
        guard let client = accounts.client else { throw RemoteError.nothingToSend }
        try await client.play(itemId: item.id, onSession: target.id, start: start, mediaSourceId: mediaSourceId,
                              audioStreamIndex: nil, subtitleStreamIndex: nil)
        follow(target, sent: Sent(item: item, start: start))
    }

    // MARK: Commands

    func togglePause() {
        guard let session, !isStarting else { return }
        let pausing = !session.playState.isPaused
        command(pausing ? .pause : .unpause) {
            $0.playState.positionTicks = Int64(self.position(at: .now) * 10_000_000)
            $0.playState.isPaused = pausing
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        command(.seek, seekTo: target) { $0.playState.positionTicks = Int64(target * 10_000_000) }
    }

    func skip(by seconds: Double) {
        seek(to: position(at: .now) + seconds)
    }

    func nextEpisode() {
        command(.nextTrack)
    }

    func chooseAudio(_ index: Int) {
        general(GeneralCommand(.setAudioStreamIndex, arguments: ["Index": String(index)])) { $0.playState.audioStreamIndex = index }
    }

    /// Nil turns subtitles off.
    func chooseSubtitle(_ index: Int?) {
        general(GeneralCommand(.setSubtitleStreamIndex, arguments: ["Index": String(index ?? -1)])) {
            $0.playState.subtitleStreamIndex = index ?? -1
        }
    }

    /// Stops the playback there and stops being its remote.
    func stopPlayback() {
        disconnect(after: command(.stop))
    }

    /// Stops the playback there and plays it here from the same second.
    func playHere() {
        guard let session, let item = session.nowPlayingItem else { return }
        let start = position(at: .now)
        let stop = command(.stop)
        player.open(PlaybackRequest(source: .item(id: item.id, mediaSourceId: session.playState.mediaSourceId), title: item.name,
                                    startingPoint: .init(position: start, audioStreamIndex: session.playState.audioStreamIndex,
                                                         subtitleStreamIndex: session.playState.subtitleStreamIndex)))
        disconnect(after: stop)
    }

    /// Stops following the device, which plays on.
    func disconnect() {
        disconnect(after: nil)
    }

    private func disconnect(after command: Task<Void, Never>?) {
        followTask?.cancel()
        followTask = nil
        socket.followsSessions = false
        socket.onSessions = nil
        target = nil
        sent = nil
        session = nil
        error = nil
        showsScreen = false
        lookUpNextEpisode()
        playbackEnded(after: command)
    }

    /// Asks the server whether the episode playing there is its show's last, once for each
    /// episode. Until it says, and when it can't, Next Episode stays: the device there knows.
    private func lookUpNextEpisode() {
        let item = item
        guard item?.id != nextEpisodeLookup?.itemId else { return }
        nextEpisodeLookup?.task.cancel()
        nextEpisodeLookup = nil
        isLastEpisode = false
        guard let item, item.isEpisode, let seriesId = item.seriesId, let client = accounts.client,
              let userId = accounts.account?.userId
        else { return }
        let task = Task { [weak self] in
            do {
                let next = try await client.episode(after: item.id, seriesId: seriesId, userId: userId)
                guard !Task.isCancelled, let self, self.nextEpisodeLookup?.itemId == item.id else { return }
                self.isLastEpisode = next == nil
            } catch {
                guard !error.isCancellation else { return }
                Self.log.notice("Couldn't find the episode after \(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        nextEpisodeLookup = (item.id, task)
    }

    @discardableResult
    private func command(_ command: PlaystateCommand, seekTo seconds: Double? = nil,
                         expecting change: (inout RemoteSession) -> Void = { _ in }) -> Task<Void, Never>? {
        guard let client = accounts.client, let target else { return nil }
        expect(change)
        return Task {
            do {
                try await client.send(command, toSession: target.sessionId, seekTo: seconds)
                error = nil
            } catch {
                self.error = "\(target.name) didn't get that: \(error.localizedDescription)"
            }
        }
    }

    private func general(_ command: GeneralCommand, expecting change: (inout RemoteSession) -> Void) {
        guard let client = accounts.client, let target else { return }
        expect(change)
        Task {
            do {
                try await client.send(command, toSession: target.sessionId)
                error = nil
            } catch {
                self.error = "\(target.name) didn't get that: \(error.localizedDescription)"
            }
        }
    }

    /// Shows a command's effect at once; the device's next report confirms it.
    private func expect(_ change: (inout RemoteSession) -> Void) {
        guard var session else { return }
        change(&session)
        self.session = session
        seenAt = .now
    }

    // MARK: Following

    /// What was sent, and from where, which shows until the device reports it plays.
    private struct Sent {
        let item: JellyfinItem
        let start: Double
    }

    private var sent: Sent?

    private func follow(_ playTarget: PlayTarget, sent: Sent) {
        disconnect()
        target = Target(sessionId: playTarget.id, name: playTarget.name, supportedCommands: playTarget.session.supportedCommands)
        self.sent = sent
        session = playTarget.session
        seenAt = .now
        phase = .starting(itemId: sent.item.id, since: .now)
        lookUpNextEpisode()
        showsScreen = true
        socket.onSessions = { [weak self] sessions in self?.received(sessions) }
        socket.followsSessions = true
        followTask = Task { await watch() }
    }

    private func received(_ sessions: [RemoteSession]) {
        guard let target else { return }
        lastPush = .now
        if let found = sessions.first(where: { $0.id == target.sessionId }) {
            update(found)
        } else {
            // The server sends only the user's own sessions; another's, or one that's gone, is asked for.
            Task { await refresh() }
        }
    }

    /// Checks on the device every second: the server sends nothing while nothing changes, so a
    /// device that never starts, or stops, is noticed here.
    private func watch() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let target else { return }
            if Date.now.timeIntervalSince(lastPush) > 3 { await refresh() }
            phase = phase.next(session: session, targetName: target.name, now: .now)
        }
    }

    private func refresh() async {
        guard let client = accounts.client, let account = accounts.account, let target else { return }
        do {
            let sessions = try await client.controllableSessions(userId: account.userId)
            guard self.target == target else { return }
            if let found = sessions.first(where: { $0.id == target.sessionId }) {
                update(found)
            } else {
                session = nil
                phase = phase.next(session: nil, targetName: target.name, now: .now)
            }
        } catch {
            guard !error.isCancellation else { return }
            Self.log.notice("Couldn't check on \(target.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't reach the server to check on \(target.name): \(error.localizedDescription)"
        }
    }

    private func update(_ found: RemoteSession) {
        session = found
        seenAt = .now
        if let item = found.nowPlayingItem {
            playedTitleIds.insert(item.id)
            if let seriesId = item.seriesId { playedTitleIds.insert(seriesId) }
        }
        if let target { phase = phase.next(session: found, targetName: target.name, now: .now) }
        lookUpNextEpisode()
    }

    /// The titles the device played while this followed it, and the shows of its episodes.
    @ObservationIgnored private var playedTitleIds: Set<String> = []

    /// Has the app's lists and pages load the watch state of what played there, as when a player
    /// here closes: once the device stopped, or once `command` got to it.
    private func playbackEnded(after command: Task<Void, Never>? = nil) {
        let played = playedTitleIds
        playedTitleIds = []
        guard !played.isEmpty else { return }
        Task {
            await command?.value
            await player.endPlayback(of: played)
        }
    }
}

nonisolated enum RemoteError: LocalizedError {
    case nothingToSend

    var errorDescription: String? {
        switch self {
        case .nothingToSend: "Only titles from your server can play on another device."
        }
    }
}
#endif
