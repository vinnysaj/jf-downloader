#if os(iOS) || os(visionOS)
import AVFoundation
import CryptoKit
import Foundation
import Observation
import OSLog

/// Keep Downloads Running: audio that keeps the app running in the background while downloads go
/// on, for people who want to know they'll finish. The system suspends an app soon after it leaves
/// the screen, and the downloads then go on in its daemon at its discretion; an app playing audio
/// isn't suspended. It loops the sound from Settings (`KeepAwakeSound`), or silence, alongside
/// `BackgroundDownloads`, which says so on the downloads' Live Activity.
///
/// - The person starts it, with the app in front: turning the switch on with downloads unfinished,
///   or starting downloads with it on. A background app can't start audio. Once playing it carries
///   on as the app leaves the screen and the screen locks (`KeepAwakePlan`).
/// - It stops once nothing is left to download, what's left all paused or failed, unless Keep
///   Playing After Downloads Finish is on; when the person stops it in Downloads or turns the switch
///   off; and on sign-out. Swiping the app away ends it, as it ends everything.
/// - It steps aside while a playback holds the downloads (`DownloadManager.isPausedForPlayback`,
///   Picture in Picture included): the playback keeps the app running and the downloads wait
///   anyway. It hands the audio session back as the player declares it (`KeepAwakePlayer`), and
///   starts again once the hold lets go with the app in front.
/// - Calls, Siri and alarms interrupt it, and it resumes when the system says they're over. A media
///   services reset, or a change of output that stops the engine, rebuilds it. When the output it
///   plays to goes away (headphones out), the sound gives way to silence until another comes, so it
///   doesn't carry on out loud.
///
/// It mixes with other apps' audio, sound or silence, so the person's music or another app's video
/// and this go on together, and none of them interrupts the others. A mixable app can't be the Now
/// Playing app, and a sound doesn't change that: Now Playing controls would offer play and pause
/// for something whose point is to keep going, and a session that isn't mixable would be stopped
/// for good by the next app that plays, taking the downloads' time in the background with it.
@Observable
final class KeepAwakeAudio {
    private(set) var plan = KeepAwakePlan()
    private(set) var sound = KeepAwakeSound.silence
    /// The audio plays now. False until it has started, while a call or the like interrupts it,
    /// and when it couldn't start (`problem` says why).
    private(set) var isRunning = false
    /// The output the sound played to went away, so it plays silence until another comes.
    private(set) var isMuted = false
    /// Why the audio couldn't play or hand the session back, to show until dismissed.
    var problem: String?

    /// Where the fetched sound is kept, named for its address.
    static let soundDirectory = URL.applicationSupportDirectory.appending(path: "KeepAwakeSound", directoryHint: .isDirectory)
    /// How long the address in Settings has to stay put before it's fetched, so typing one
    /// doesn't fetch every prefix.
    static let addressSettleDelay: Duration = .seconds(1)
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "keep-awake")

    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let player = KeepAwakePlayer()
    /// Numbers each instruction to `player`, which drops any older than one it has carried out.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var wasInFront = false
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var fetching: Task<Void, Never>?
    @ObservationIgnored private var sessionObservations: [any NSObjectProtocol] = []
    @ObservationIgnored private var sessionMessages: [NotificationCenter.ObservationToken] = []

    init(downloads: DownloadManager, settings: AppSettings, accounts: AccountStore) {
        self.downloads = downloads
        self.settings = settings
        self.accounts = accounts
    }

    /// Follows the downloads, Settings and the audio session for the life of the app.
    func run() async {
        followSession()
        await withDiscardingTaskGroup { group in
            group.addTask { await self.followDownloads() }
            group.addTask { await self.followSoundAddress() }
            group.addTask { await self.followPlayerFailures() }
        }
    }

    /// The person turned the switch on.
    func switchedOn() {
        var next = plan
        let inputs = Self.inputs(downloads, settings, accounts)
        next.switchedOn(inputs)
        update(to: next, inputs: inputs)
    }

    /// The person stopped it from Downloads.
    func stop() {
        var next = plan
        next.stop()
        update(to: next, inputs: Self.inputs(downloads, settings, accounts))
    }

    /// Plays the sound on whatever output there is now, after its own went away.
    func unmute() {
        guard isMuted else { return }
        isMuted = false
        if plan.isPlaying { playAudio() }
    }

    // MARK: Following

    @MainActor private static func inputs(_ downloads: DownloadManager, _ settings: AppSettings, _ accounts: AccountStore) -> KeepAwakePlan.Inputs {
        KeepAwakePlan.Inputs(
            isOn: settings.keepDownloadsRunning,
            keepsPlayingAfterDownloads: settings.keepPlayingAfterDownloads,
            isSignedIn: accounts.account != nil,
            hasDownloads: !DownloadJob.queue(downloads.jobs).isEmpty,
            isPausedForPlayback: downloads.isPausedForPlayback,
            isInFront: downloads.isInFront,
            userStartCount: downloads.userStartCount
        )
    }

    private func followDownloads() async {
        let downloads = downloads
        let settings = settings
        let accounts = accounts
        for await inputs in Observations({ Self.inputs(downloads, settings, accounts) }) {
            var next = plan
            next.update(inputs)
            update(to: next, inputs: inputs)
        }
    }

    private func update(to next: KeepAwakePlan, inputs: KeepAwakePlan.Inputs) {
        let previous = plan
        let cameToFront = inputs.isInFront && !wasInFront
        wasInFront = inputs.isInFront
        if next != previous {
            plan = next
            Self.log.info("Started \(next.isStarted), playing \(next.isPlaying) (downloads \(inputs.hasDownloads), held \(inputs.isPausedForPlayback), in front \(inputs.isInFront))")
        }
        if next.isStarted, !previous.isStarted {
            isMuted = false
            problem = nil
            resolveSound()
        }
        if next.isPlaying, !previous.isPlaying {
            playAudio()
        } else if !next.isPlaying, previous.isPlaying {
            stopAudio(inputs.isPausedForPlayback ? .handOver : .done)
        } else if next.isPlaying, !isRunning, cameToFront {
            // An interruption the system never said was over, or audio that couldn't start: the
            // app in front again is the moment to try once more.
            playAudio()
        }
    }

    /// Fetches the sound once the address in Settings stays put, while the switch is on.
    private func followSoundAddress() async {
        let settings = settings
        for await _ in Observations({ (settings.keepDownloadsRunning, settings.keepDownloadsRunningSound) }) {
            settling?.cancel()
            settling = Task {
                try? await Task.sleep(for: Self.addressSettleDelay)
                guard !Task.isCancelled else { return }
                resolveSound()
            }
        }
    }

    /// A long sound's file that stopped reading partway falls back to silence.
    private func followPlayerFailures() async {
        for await failure in player.failures {
            guard sound.file != nil else { continue }
            Self.log.error("The sound stopped playing: \(failure.logDescription, privacy: .public)")
            sound = .failed(failure)
            if plan.isPlaying { playAudio() }
        }
    }

    // MARK: Sound

    /// Brings the sound in line with the address in Settings: silence, a failure, the file kept for
    /// it, or a fetch. Once it's in line, does nothing, so a fetch that failed is tried again only
    /// when the address changes or the person starts the keep-alive. Only the sound for the address
    /// in Settings is kept.
    private func resolveSound() {
        guard settings.keepDownloadsRunning else { return }
        let step = KeepAwakeSound.step(for: settings.keepDownloadsRunningSound, current: sound, keptFile: Self.keptFile(for:))
        switch step {
        case .keep:
            return
        case .silence:
            fetching?.cancel()
            sound = .silence
            removeKeptSounds(except: nil)
        case .fail(let failure):
            fetching?.cancel()
            sound = .failed(failure)
            removeKeptSounds(except: nil)
        case .use(let address, let file):
            fetching?.cancel()
            sound = .ready(address, file: file)
        case .fetch(let address):
            fetching?.cancel()
            sound = .fetching(address)
            fetching = Task { await fetchSound(address) }
        }
        Self.log.info("Sound: \(self.sound.logDescription, privacy: .public)")
        if plan.isPlaying { playAudio() }
    }

    private func fetchSound(_ address: URL) async {
        let result: Result<URL, KeepAwakeSound.Failure>
        do {
            result = .success(try await KeepAwakeSound.fetch(address, into: Self.soundDirectory))
        } catch {
            result = .failure(error)
        }
        // Another address came along meanwhile.
        guard sound == .fetching(address) else { return }
        switch result {
        case .success(let file):
            sound = .ready(address, file: file)
            removeKeptSounds(except: file)
        case .failure(let failure):
            sound = .failed(failure)
            removeKeptSounds(except: nil)
        }
        Self.log.info("Sound: \(self.sound.logDescription, privacy: .public)")
        if plan.isPlaying { playAudio() }
    }

    /// Nil when nothing is kept for the address, and when the folder can't be read, in which case
    /// the sound is fetched again and that says what's wrong.
    private static func keptFile(for address: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: soundDirectory.path) else { return nil }
        let name = KeepAwakeSound.keptName(for: address)
        do {
            return try FileManager.default.contentsOfDirectory(at: soundDirectory, includingPropertiesForKeys: nil)
                .first { $0.deletingPathExtension().lastPathComponent == name }
        } catch {
            log.error("Couldn't look for the kept sound: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func removeKeptSounds(except kept: URL?) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: Self.soundDirectory.path) else { return }
        do {
            for file in try manager.contentsOfDirectory(at: Self.soundDirectory, includingPropertiesForKeys: nil)
            where file.standardizedFileURL != kept?.standardizedFileURL {
                try manager.removeItem(at: file)
            }
        } catch {
            problem = "Couldn't delete a sound Keep Downloads Running no longer uses: \(error.localizedDescription)"
        }
    }

    // MARK: Audio

    private func playAudio(rebuild: Bool = false) {
        revision += 1
        let revision = revision
        let target = KeepAwakePlayer.Target(file: sound.file, isMuted: isMuted)
        let player = player
        Task {
            do {
                let fallback = try await player.play(target, revision: revision, rebuild: rebuild)
                guard revision == self.revision else { return }
                isRunning = true
                if let fallback, sound.file == target.file {
                    Self.log.error("Playing silence: \(fallback.logDescription, privacy: .public)")
                    sound = .failed(fallback)
                }
            } catch {
                guard revision == self.revision else { return }
                isRunning = false
                Self.log.error("Couldn't play: \(String(describing: error), privacy: .public)")
                problem = "Keep Downloads Running couldn't play audio, so downloads may wait while vinnyfin is in the background: \(error.localizedDescription)"
            }
        }
    }

    private func stopAudio(_ ending: KeepAwakePlayer.Ending) {
        revision += 1
        let revision = revision
        isRunning = false
        let player = player
        Task {
            do {
                try await player.stop(ending, revision: revision)
            } catch {
                Self.log.error("Couldn't hand the session back: \(String(describing: error), privacy: .public)")
                problem = ending == .handOver
                    ? "Keep Downloads Running couldn't hand the audio back to the player, so it may play alongside other apps: \(error.localizedDescription)"
                    : "Keep Downloads Running couldn't let go of the audio, so other apps may stay quieter: \(error.localizedDescription)"
            }
        }
    }

    /// Interruptions, resets, changes of output and the engine stopping, from the audio session.
    private func followSession() {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        sessionMessages = [
            center.addObserver(of: session, for: .didBecomeInactive) { [weak self] message in
                guard case .systemInterruption = message.deactivationResult else { return }
                self?.interrupted()
            },
            center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] message in
                self?.interruptionEnded(shouldResume: message.recommendation == .shouldResume)
            },
        ]
        sessionObservations = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
                MainActor.assumeIsolated { self?.routeChanged(reason) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaServicesReset() }
            },
            // The engine stops when its output's format changes, as with a new route.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engineConfigurationChanged() }
            },
        ]
    }

    private func interrupted() {
        guard plan.isPlaying else { return }
        Self.log.notice("Interrupted")
        isRunning = false
    }

    /// Resumes whatever the system recommends: being mixable, it interrupts no one.
    private func interruptionEnded(shouldResume: Bool) {
        guard plan.isPlaying else { return }
        Self.log.notice("Interruption over (the system \(shouldResume ? "recommends" : "doesn't recommend", privacy: .public) resuming); resuming")
        playAudio()
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard plan.isStarted, let reason else { return }
        let muted = KeepAwakeSound.isMuted(after: reason, wasMuted: isMuted)
        guard muted != isMuted else { return }
        Self.log.info("Output \(reason == .oldDeviceUnavailable ? "went away" : "arrived", privacy: .public): \(muted ? "muting" : "unmuting", privacy: .public) the sound")
        isMuted = muted
        if plan.isPlaying { playAudio() }
    }

    private func mediaServicesReset() {
        guard plan.isPlaying else { return }
        Self.log.notice("Media services were reset; rebuilding")
        playAudio(rebuild: true)
    }

    private func engineConfigurationChanged() {
        guard plan.isPlaying, isRunning else { return }
        Self.log.info("The engine's configuration changed")
        playAudio()
    }
}

// MARK: Decisions

/// When Keep Downloads Running plays: the decisions, apart from the audio.
///
/// It's started by the person: turning the switch on with downloads unfinished, or starting
/// downloads (`DownloadManager.userStartCount`) with it on. It ends when the switch goes off, on
/// sign-out, when the person stops it, and once nothing is left to download, unless it keeps
/// playing after downloads finish. While started it plays, except while a playback holds the
/// downloads; it begins playing only with the app in front, as a background app can't start
/// audio, and carries on wherever the app goes. A paused player the app leaves lets the downloads
/// go on but doesn't bring it back: the app is no longer in front, and the player keeps the
/// session and its Lock Screen controls, which a mixable session would take away. It comes back
/// once the player closes with the app in front.
nonisolated struct KeepAwakePlan: Equatable, Sendable {
    struct Inputs: Equatable, Sendable {
        var isOn: Bool
        var keepsPlayingAfterDownloads: Bool
        var isSignedIn: Bool
        /// Downloads are left to do: not everything is done, paused or failed.
        var hasDownloads: Bool
        var isPausedForPlayback: Bool
        var isInFront: Bool
        var userStartCount: Int
    }

    /// The person started it, and nothing has ended it since.
    private(set) var isStarted = false
    /// Its audio plays.
    private(set) var isPlaying = false
    /// `DownloadManager.userStartCount` as last seen; it starts at zero with the app.
    private var seenUserStarts = 0

    /// The person turned the switch on.
    mutating func switchedOn(_ inputs: Inputs) {
        if inputs.hasDownloads { isStarted = true }
        update(inputs)
    }

    /// The person stopped it.
    mutating func stop() {
        isStarted = false
        isPlaying = false
    }

    mutating func update(_ inputs: Inputs) {
        if inputs.userStartCount != seenUserStarts {
            seenUserStarts = inputs.userStartCount
            if inputs.isOn, inputs.hasDownloads { isStarted = true }
        }
        if !inputs.isOn || !inputs.isSignedIn || !(inputs.hasDownloads || inputs.keepsPlayingAfterDownloads) {
            isStarted = false
        }
        if !isStarted || inputs.isPausedForPlayback {
            isPlaying = false
        } else if inputs.isInFront {
            isPlaying = true
        }
    }
}

// MARK: Sound

/// The sound Keep Downloads Running plays: silence, unless Settings has the web address of an
/// audio file, which is fetched once with an ordinary session, checked to play, and kept in
/// Application Support for as long as the address stays. Anything wrong with it is said, and
/// silence plays instead, so the downloads stay up regardless.
nonisolated enum KeepAwakeSound: Equatable, Sendable {
    /// No address in Settings.
    case silence
    /// Fetching the file at this address; silence plays meanwhile.
    case fetching(URL)
    /// The file fetched from this address, checked and kept.
    case ready(URL, file: URL)
    /// The address or its file can't be used; silence plays instead.
    case failed(Failure)

    /// The file to play; nil plays silence.
    var file: URL? {
        if case .ready(_, let file) = self { file } else { nil }
    }

    enum Failure: Error, Equatable, Sendable {
        case notAnAddress
        case unreachable(String)
        case refused(status: Int)
        case notAudio
        case notKept(String)
        case unplayable(String)
    }

    /// What it takes to bring the sound in line with the address in Settings.
    enum Step: Equatable, Sendable {
        /// It is already.
        case keep
        case silence
        case fail(Failure)
        /// The file kept for the address.
        case use(URL, file: URL)
        case fetch(URL)
    }

    /// The address typed in Settings: nil for none, as blank plays silence.
    static func address(from text: String) -> Result<URL?, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false
        else { return .failure(.notAnAddress) }
        return .success(url)
    }

    /// `keptFile` finds the file kept for an address, if there is one.
    static func step(for text: String, current: KeepAwakeSound, keptFile: (URL) -> URL?) -> Step {
        let address: URL
        switch Self.address(from: text) {
        case .failure(let failure): return current == .failed(failure) ? .keep : .fail(failure)
        case .success(nil): return current == .silence ? .keep : .silence
        case .success(let url?): address = url
        }
        switch current {
        case .fetching(address), .ready(address, _): return .keep
        default: break
        }
        if let file = keptFile(address) { return .use(address, file: file) }
        return .fetch(address)
    }

    /// The kept file's name, without its extension: the same for the same address, and another
    /// for another, so a changed address is fetched again.
    static func keptName(for address: URL) -> String {
        SHA256.hash(data: Data(address.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The sound gives way to silence when the output it plays to goes away (headphones out),
    /// rather than carrying on out loud, and plays again when one comes.
    static func isMuted(after reason: AVAudioSession.RouteChangeReason, wasMuted: Bool) -> Bool {
        switch reason {
        case .oldDeviceUnavailable: true
        case .newDeviceAvailable: false
        default: wasMuted
        }
    }

    /// Fetches the file at `address` into `directory`, named for the address with the extension
    /// its type has, and checks it's audio that plays. Replaces what was kept for the address.
    @concurrent static func fetch(_ address: URL, into directory: URL) async throws(Failure) -> URL {
        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await URLSession.shared.download(from: address)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        let manager = FileManager.default
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            do { try manager.removeItem(at: downloaded) } catch { throw .notKept(error.localizedDescription) }
            throw .refused(status: http.statusCode)
        }
        let suggested = response.suggestedFilename.map { URL(filePath: $0).pathExtension } ?? ""
        let fileExtension = suggested.isEmpty ? address.pathExtension : suggested
        var kept = directory.appending(path: keptName(for: address))
        if !fileExtension.isEmpty { kept.appendPathExtension(fileExtension) }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Fetched again if it's lost; keeping it out of iCloud backups saves the person's quota.
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var folder = directory
            try folder.setResourceValues(excluded)
            if manager.fileExists(atPath: kept.path) { try manager.removeItem(at: kept) }
            try manager.moveItem(at: downloaded, to: kept)
        } catch {
            throw .notKept(error.localizedDescription)
        }
        do {
            guard try AVAudioFile(forReading: kept).length > 0 else { throw Failure.notAudio }
        } catch {
            do { try manager.removeItem(at: kept) } catch { throw .notKept(error.localizedDescription) }
            throw .notAudio
        }
        return kept
    }

    var logDescription: String {
        switch self {
        case .silence: "silence"
        case .fetching(let address): "fetching \(address.absoluteString)"
        case .ready(let address, let file): "\(file.lastPathComponent) from \(address.absoluteString)"
        case .failed(let failure): "failed: \(failure.logDescription)"
        }
    }
}

nonisolated extension KeepAwakeSound.Failure {
    var logDescription: String { String(describing: self) }
}

extension KeepAwakeSound.Failure {
    /// In plain words, for Settings and Downloads.
    @MainActor var message: String {
        switch self {
        case .notAnAddress: "That isn't a web address vinnyfin can fetch. It needs to start with http:// or https://."
        case .unreachable(let reason): "vinnyfin couldn't fetch it: \(reason)"
        case .refused(let status): "The server answered \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))."
        case .notAudio: "It isn't an audio file vinnyfin can play."
        case .notKept(let reason): "vinnyfin couldn't keep it on this \(Device.name): \(reason)"
        case .unplayable(let reason): "It couldn't be played: \(reason)"
        }
    }
}

// MARK: Audio

/// Plays Keep Downloads Running's audio on a loop, off the main thread: the audio session's calls
/// and the engine's start are round trips to the media server that can block for a while.
///
/// Silence is a moment of zeros looped from memory, so there's nothing to hear at the seam and
/// nothing to decode; a sound up to `longestInMemory` long is decoded once and looped from memory
/// the same way, sample for sample. A longer one plays from its file, a copy always queued behind
/// the one playing, which the player node joins without a gap.
///
/// While it plays, the session is `.playback` mixed with others. Whenever it stops it leaves the
/// session as the player's engine declares it before its first load (`.playback` for movies,
/// not mixed), which the engine then keeps, as it does any `.playback` session it finds: so a
/// player that opens finds the session it would have made itself, whichever of the two gets to
/// the session first. Stopping for a playback leaves the session active for it; stopping for good
/// deactivates it first, so changing back to a category that isn't mixed doesn't interrupt other
/// apps on the way out.
actor KeepAwakePlayer {
    struct Target: Equatable, Sendable {
        /// The file to loop; nil loops silence.
        var file: URL?
        var isMuted: Bool
    }

    enum Ending: Equatable, Sendable {
        /// A playback takes the session over.
        case handOver
        case done
    }

    /// What the player node goes round.
    enum Loop {
        /// From memory: silence, or the whole sound.
        case buffer(AVAudioPCMBuffer)
        /// From the file, for a sound longer than `longestInMemory`: the first two copies to queue,
        /// opened, and how long one lasts.
        case file(URL, copies: [AVAudioFile], duration: TimeInterval)
    }

    /// Decoded, 30 seconds of stereo at 48 kHz take 11.5 MB.
    nonisolated static let longestInMemory: TimeInterval = 30
    /// Asked of the session while it plays: nothing here needs low latency, and longer buffers wake
    /// the audio thread less often. The system takes the nearest it can.
    nonisolated static let ioBufferDuration: TimeInterval = 0.1
    nonisolated static let silenceFrames: AVAudioFrameCount = 4096
    private nonisolated static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "keep-awake")

    /// A long sound's file that couldn't be queued again, as it stopped reading.
    nonisolated let failures: AsyncStream<KeepAwakeSound.Failure>
    private let failureContinuation: AsyncStream<KeepAwakeSound.Failure>.Continuation

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var playing: Target?
    private var lastRevision = 0
    /// Moves with each engine, so a torn-down one's callbacks are dropped.
    private var generation = 0
    /// How long one time round lasts, and how many times a long sound has been queued again.
    private var loopDuration: TimeInterval = 0
    private var requeued = 0
    /// The session's preferred I/O buffer duration before this changed it, to put back.
    private var savedIOBufferDuration: TimeInterval?
    /// The session is in this's category, until it's handed back.
    private var holdsSession = false

    init() {
        (failures, failureContinuation) = AsyncStream.makeStream()
    }

    /// Plays `target`. Builds the engine anew when nothing plays, the engine has stopped (as an
    /// interruption or a new output stops it), the file changed or `rebuild` asks, and otherwise
    /// only sets the volume. Returns why the file couldn't be played when it played silence
    /// instead. Drops the call when a later one has been carried out.
    func play(_ target: Target, revision: Int, rebuild: Bool) throws -> KeepAwakeSound.Failure? {
        guard revision > lastRevision else { return nil }
        lastRevision = revision
        if !rebuild, let engine, engine.isRunning, playing?.file == target.file {
            engine.mainMixerNode.outputVolume = target.isMuted ? 0 : 1
            playing = target
            return nil
        }
        tearDown()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .default, options: [.mixWithOthers])
        holdsSession = true
        if savedIOBufferDuration == nil { savedIOBufferDuration = session.preferredIOBufferDuration }
        try session.setPreferredIOBufferDuration(Self.ioBufferDuration)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        self.engine = engine
        self.node = node
        var failure: KeepAwakeSound.Failure?
        var loop: Loop?
        if let file = target.file {
            do {
                loop = try Self.loop(for: file)
            } catch {
                failure = .unplayable(error.localizedDescription)
            }
        }
        let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard let loop = loop ?? Self.silence(sampleRate: sampleRate > 0 ? sampleRate : 48_000).map(Loop.buffer) else {
            throw KeepAwakePlayerError.noSilence
        }
        try engine.connectNode(node, to: engine.mainMixerNode, format: loop.format)
        schedule(loop, on: node)
        engine.mainMixerNode.outputVolume = target.isMuted ? 0 : 1
        engine.prepare()
        try engine.start()
        try node.playAudio()
        playing = target
        let name = target.file?.lastPathComponent ?? "silence"
        let round = String(format: "%.1f", loopDuration)
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
        let buffer = String(format: "%.3f", session.ioBufferDuration)
        Self.log.info("Playing \(name, privacy: .public), \(round, privacy: .public) s a time round\(target.isMuted ? ", muted" : "", privacy: .public), to \(outputs, privacy: .public), I/O buffer \(buffer, privacy: .public) s")
        return failure
    }

    /// Stops playing, and leaves the session as the player declares it: active for a playback
    /// that takes it over, or deactivated for good, telling other apps they may carry on.
    func stop(_ ending: Ending, revision: Int) throws {
        guard revision > lastRevision else { return }
        lastRevision = revision
        tearDown()
        guard holdsSession else { return }
        let session = AVAudioSession.sharedInstance()
        if ending == .done { try session.setActive(false, options: .notifyOthersOnDeactivation) }
        try session.setCategory(.playback, mode: .moviePlayback, policy: .default, options: [])
        if let savedIOBufferDuration {
            try session.setPreferredIOBufferDuration(savedIOBufferDuration)
            self.savedIOBufferDuration = nil
        }
        holdsSession = false
        Self.log.info("Stopped: \(ending == .done ? "done" : "handed over to a playback", privacy: .public)")
    }

    private func tearDown() {
        generation += 1
        if let node, let engine {
            if let rendered = node.lastRenderTime, let time = node.playerTime(forNodeTime: rendered), time.sampleRate > 0 {
                let seconds = Double(time.sampleTime) / time.sampleRate
                let played = String(format: "%.1f", seconds)
                let rounds = String(format: "%.1f", loopDuration > 0 ? seconds / loopDuration : 0)
                Self.log.info("Played \(played, privacy: .public) s, \(rounds, privacy: .public) times round")
            }
            node.stop()
            engine.stop()
        }
        engine = nil
        node = nil
        playing = nil
        requeued = 0
    }

    private func schedule(_ loop: Loop, on node: AVAudioPlayerNode) {
        switch loop {
        case .buffer(let buffer):
            loopDuration = Double(buffer.frameLength) / buffer.format.sampleRate
            node.scheduleBuffer(buffer, at: nil, options: .loops)
        case .file(let file, let copies, let duration):
            loopDuration = duration
            for copy in copies { queue(copy, of: file, on: node) }
        }
    }

    /// Queues a copy of the file behind what's queued, and another once the node has read this
    /// one, so one is always waiting. Each copy is a file of its own, read from its start.
    private func queue(_ copy: AVAudioFile, of file: URL, on node: AVAudioPlayerNode) {
        let generation = generation
        node.scheduleFile(copy, at: nil, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { await self?.copyRead(of: file, generation: generation) }
        }
    }

    private func copyRead(of file: URL, generation: Int) {
        guard generation == self.generation, let node else { return }
        requeued += 1
        let name = file.lastPathComponent
        Self.log.info("Queued \(name, privacy: .public) again, time \(self.requeued)")
        do {
            queue(try AVAudioFile(forReading: file), of: file, on: node)
        } catch {
            failureContinuation.yield(.unplayable(error.localizedDescription))
        }
    }

    /// What the node loops for the file: all of it from memory, or a long one from the file.
    nonisolated static func loop(for file: URL) throws -> Loop {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let duration = Double(audio.length) / format.sampleRate
        guard audio.length > 0 else { throw KeepAwakePlayerError.empty }
        guard duration <= longestInMemory else {
            return .file(file, copies: [audio, try AVAudioFile(forReading: file)], duration: duration)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw KeepAwakePlayerError.noBuffer
        }
        try audio.read(into: buffer)
        return .buffer(buffer)
    }

    /// `silenceFrames` of mono zeros.
    nonisolated static func silence(sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: silenceFrames),
              let samples = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = silenceFrames
        samples[0].update(repeating: 0, count: Int(silenceFrames))
        return buffer
    }
}

extension KeepAwakePlayer.Loop {
    nonisolated var format: AVAudioFormat {
        switch self {
        case .buffer(let buffer): buffer.format
        case .file(_, let copies, _): copies[0].processingFormat
        }
    }
}

nonisolated enum KeepAwakePlayerError: LocalizedError {
    case noSilence
    case empty
    case noBuffer

    var errorDescription: String? {
        switch self {
        case .noSilence: "the audio output gave no format to play silence in."
        case .empty: "the file has no audio in it."
        case .noBuffer: "there wasn't memory to decode it."
        }
    }
}
#endif
