#if !os(tvOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Network
import Observation
import OSLog

/// Runs the download queue on a background `URLSession`.
///
/// Transfers run in the system's download daemon, not in this process, so they continue while
/// the app is suspended or after the system has terminated it; the system relaunches the app in
/// the background to hand over finished transfers. Files are fetched in byte-range chunks that
/// are written into a sparse partial file as they arrive, so a dropped connection costs at most
/// one chunk, whatever the server sends. (Gelato's streams come through Jellyfin without ETag or
/// Last-Modified, which the system needs for its own resume data.)
///
/// Files download one at a time, in the order of the list, which people can rearrange (Download
/// Next moves one to the front), and none while something plays. Each file is asked for one
/// byte first, for its size and whether its stream takes ranges: that's a property of each
/// file, not of the server (`DownloadJob.needsProbe`). One that answers a range request with the
/// whole file gets that one transfer: the moment the first such answer arrives, the file's other
/// transfers come out. While the app is in front of the user, the session holds the chunks of
/// the file in hand only (`DownloadJob.plan`), the first in the queue that may download now, a
/// few at a time (`DownloadJob.transfersInHand`) so each is planned in the chunk size of the
/// moment, while the files after it are probed in turn, through an ordinary session so the
/// probes don't wait behind those chunks for a connection. The session runs
/// `connectionsPerHost` transfers at a time in no promised order (nor by task priority), so
/// that's what keeps the server on one file. When the file in hand changes (the list
/// rearranged, a file paused or held back, the app back in front), the other files' transfers
/// that haven't started come out; those under way finish, and only then do the new file's
/// chunks go in, so no bytes are lost and the server stays on one file. As the app resigns
/// active, while it's still in the foreground to the system, every file's chunks go in, up to
/// `maxQueuedTransfers`: the session then works through the queue by itself with the app
/// suspended or terminated, which it wouldn't promptly otherwise. Transfers created while the
/// app is in the background start only when the system sees fit, after a delay that grows with
/// every time the system wakes the app, in a connection pool of their own; it wakes the app only
/// once every transfer is done. Launched in the background, the app queues ahead the same way.
/// A file that keeps failing while other files come through lets the files behind it go ahead
/// while it waits out its retries (`DownloadJob.yields`); to tell, while the file in hand fails,
/// the file behind it gets one transfer. When everything fails, nothing yields.
///
/// Settings say when and where downloads may run (`DownloadRules`), and why each file waits is
/// in `waits`. Each transfer's request carries the networks it may use, so the system holds it
/// until the device is on one, whether or not the app runs: not cellular or a Personal Hotspot
/// unless Download Over Cellular is on, and not a network in Low Data Mode. In front, a file the
/// network holds back isn't planned. Only While Charging holds files back in the app, which a
/// suspended app can't react to, so with it on only the file in hand is queued ahead: unplugged
/// while the app is suspended, the system finishes that one at most. `BackgroundDownloads` books
/// the catch-up launch for when the device is on power. Room holds files back too
/// (`StorageBudget`): the queue has to fit under the storage limit and on the device, counting
/// every byte the downloads have on disk; downloads watched since they were queued are deleted
/// to make room, the one watched longest ago first, and what still doesn't fit waits. Near full,
/// chunks shrink to fit, and a download that runs out of room anyway halves its chunks and waits
/// for room rather than failing, counting only room actually free from then on; what a chunk
/// wrote before it ran out goes (`DownloadStorage.releaseUnrecorded`). Download Now lifts the
/// network rules and Only While Charging for one download. When the rules change, transfers that
/// haven't started and no longer fit them come out to be planned again; those under way finish,
/// unless they can't use the network the device is on while the rules now let their file use it.
///
/// Whenever the process runs, in front or kept running in the background (`BackgroundDownloads`,
/// `KeepAwakeAudio`), finished chunks go into place as they arrive, files are published, and
/// `trackProgress` replaces stalled transfers, by what their tasks say they've received
/// (`TransferActivity`) and what the session says of them. Whatever a transfer the app
/// cancelled delivers anyway, having finished first, is kept, unless its job started over.
/// Pausing cuts the transfers that can keep their bytes in resume data, and lets those that
/// can't finish once they've more behind than ahead (`DownloadJob.finishesWhenPaused`); a
/// playback holds them all but those that can't and are a moment from done, as it needs the
/// connection now. `DownloadNotifications` tells the user when files are ready to watch
/// offline and when one needs them. Swiping the app away in the app switcher
/// makes the system cancel every transfer and leave the app closed until it's opened again; the
/// reason comes with the cancellations then, and is kept in `systemCancellation` to tell the
/// user. Which downloads someone started, rather than smart downloads by themselves, is in
/// `userStartedJobIds`, and each time someone starts some moves `userStartCount`.
///
/// Every transfer's purpose is in its `taskDescription` (`TransferTag`), so the queue rebuilds
/// itself from the session after a relaunch. What was handed to the session is kept on disk as
/// well: transfers that ended while the app was dead report only after the relaunch, and their
/// ranges aren't planned again until they have, or `relaunchReportWait` has passed. So is the
/// resume data of ranges set aside, for a playback or a pause, or because their file is no
/// longer in hand: a kill meanwhile loses none of it, and each range carries on from its bytes
/// once its file is in the session again.
///
/// Each download's extras (`DownloadExtras`: subtitles, scrub previews, chapter pictures,
/// segments, artwork, details) come through `probeSession`, one request at a time, oldest
/// download first, whenever the process runs and nothing plays: they're small, and in the
/// background session each would wait behind the file in hand for a connection and cost the
/// daemon a task. A pass looks for what's missing as the app launches or is woken, as a
/// download is queued or published, and as the network or a playback lets go; one cut off by
/// a suspension carries on at the next. They count in the download's size and go with it.
@Observable
final class DownloadManager {
    static let sessionIdentifier = "net.vinnysaj.vinnyfin.transfers"
    /// Transfers handed to the system at once; the session runs `connectionsPerHost` of them at
    /// a time. 512 chunks are 8 GB at the starting chunk size and 32 GB at the largest, so a 4K
    /// file, or several files, are all in the session before the app leaves the screen, rather
    /// than waiting on background wakes to be topped up. Apple's guidance is that hundreds of
    /// tasks in a background session are fine and thousands start to cost the daemon; fewer,
    /// larger transfers are better.
    static let maxQueuedTransfers = 512
    static let connectionsPerHost = 4
    /// While the app runs, a transfer the session should be running that moved no bytes for
    /// this long is replaced. The daemon retries a dropped transfer by itself, doubling its wait
    /// each time up to many minutes; a new transfer starts over without that wait.
    static let stallLimit: TimeInterval = 45
    /// How long the free space last found stands, unless the queue, a size or the limit changes:
    /// the volume takes a moment to answer, counting what the system could purge.
    static let spaceCheckInterval: TimeInterval = 10
    /// Visible in Console.app (subsystem net.vinnysaj.vinnyfin) for following a download.
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "downloads")

    private(set) var jobs: [DownloadJob] = []
    /// What each unfinished download has so far, on disk in its partial file and in the session's
    /// files for its transfers, running or set aside (`bytesSoFar`). Refreshed by `trackProgress()`.
    private(set) var receivedBytes: [UUID: Int64] = [:]
    /// How fast each download's bytes arrive, smoothed, so it lingers a moment after they stop.
    private(set) var bytesPerSecond: [UUID: Double] = [:]
    /// The downloads with transfers under way: bytes arriving, or a response in. Refreshed by
    /// `trackProgress()`.
    private(set) var transferringJobIds: Set<UUID> = []
    /// The network the device is on.
    private(set) var network = NetworkConditions.unknown
    var isNetworkReachable: Bool { network.isReachable }
    /// Whether the device is on external power; nil when it can't say.
    private(set) var isOnPower: Bool?
    /// The job the session works on now: the first in the queue that nothing holds back and
    /// that doesn't yield. The other active jobs are queued behind it or wait.
    private(set) var downloadingJobId: UUID?
    /// In front, the files whose transfers under way the file in hand waits for before its own
    /// go in: the one it was moved ahead of, say.
    private(set) var fileInHandWaitsOn: Set<UUID> = []
    /// Why each active download that could otherwise go on waits: a rule, or room. Refreshed by `pump()`.
    private(set) var waits: [UUID: DownloadWait] = [:]
    /// Something is playing, or a player is open in front of the user, so transfers wait.
    private(set) var isPausedForPlayback = false
    /// The app is in front of the user and active.
    private(set) var isInFront = false
    /// Jobs someone started (downloaded, resumed, retried, started over, moved to the front, or
    /// queued by a smart download they set up), as opposed to smart downloads topping a show up
    /// by themselves. Only those start a continued-processing task on iPhone and iPad
    /// (`BackgroundDownloads`). Kept until `forgetUserStartedJobs()`.
    private(set) var userStartedJobIds: Set<UUID> = []
    /// Moves each time someone starts downloads, as `userStartedJobIds` records, even ones they
    /// had started before, so `KeepAwakeAudio` can start with them.
    private(set) var userStartCount = 0
    /// Why the system last cancelled transfers by itself, to tell the user until dismissed.
    var systemCancellation: URLError.BackgroundTaskCancelledReason?
    /// The watched downloads last deleted to make room, to say so. Kept on disk, so a deletion
    /// in a background wake is still told after a kill.
    private(set) var lastFreed: FreedSpace?
    /// Moves when saved artwork changes, so views showing it look again.
    private(set) var artworkRevision = 0
    /// A local problem (storage, the saved queue) to show until dismissed.
    var problem: String?
    /// The server's side of transcoded downloads, and how far each one's server has got.
    let transcodes: TranscodedDownloads

    private struct RunningTransfer {
        let tag: TransferTag
        let task: URLSessionDownloadTask
        /// The networks its request lets it use.
        let access: NetworkAccess
        /// What it has received as its progress events count it: none before the first, even
        /// carrying on from resume data, which tells a cut from a connection that never got going.
        var received: Int64
        /// The bytes of the file its resume data held.
        var carried: Int64 = 0
        /// The bytes its last progress event reported. Nil for a transfer adopted after a
        /// relaunch until its first event: what the task says it has received at adoption isn't
        /// on the same count, and can be more than that first event.
        var reported: Int64?
        /// How it has moved, for telling a stalled transfer from one waiting its turn.
        var activity: TransferActivity
        /// When the current attempt began: the app started or adopted the transfer, or the
        /// daemon started its range over.
        var attemptStart = Date.now
        /// Started from resume data: a stalled transfer's, or a range set aside.
        var resumed = false
        /// Its response has been looked at, for a whole file sent for a range.
        var isResponseChecked = false

        init(tag: TransferTag, task: URLSessionDownloadTask, access: NetworkAccess, received: Int64, carried: Int64 = 0,
             resumed: Bool = false) {
            self.tag = tag
            self.task = task
            self.access = access
            self.received = received
            self.carried = carried
            self.resumed = resumed
            // One timed for later is on the clock from when it may begin.
            activity = TransferActivity(bytes: task.countOfBytesReceived, resumed: resumed,
                                        now: max(.now, task.earliestBeginDate ?? .distantPast))
        }

        /// The daemon has a response for it, or bytes: it's under way rather than waiting its turn.
        var isUnderWay: Bool { task.response != nil || task.countOfBytesReceived > 0 }
        /// Taking it back would lose bytes: it's under way, or carries on from some.
        var carriesBytes: Bool { resumed || isUnderWay }
        /// The bytes of the file it holds in the session's files: as it last reported them, which
        /// count those it carried on from, and before its first report at least those.
        var bytes: Int64 { reported == nil ? max(received, carried) : received }
        /// Its bytes can be kept in resume data: it carries on from some, or the server sent a
        /// validator, ETag or Last-Modified, which resume data needs.
        var canResume: Bool {
            guard !resumed else { return true }
            let response = task.response as? HTTPURLResponse
            return response?.value(forHTTPHeaderField: "ETag") != nil || response?.value(forHTTPHeaderField: "Last-Modified") != nil
        }
    }

    /// After a relaunch, how long transfers that were handed to the session but that it no
    /// longer lists may take to report how they ended, before their ranges are planned again.
    static let relaunchReportWait: Duration = .seconds(30)

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private let notifications: DownloadNotifications
    @ObservationIgnored private let storage: DownloadStorage
    @ObservationIgnored private let delegate: TransferDelegate
    @ObservationIgnored private let session: URLSession
    /// For probes, which are a byte each, and extras, which are small: in the background session
    /// they would wait behind the file in hand for one of its connections, minutes on a slow link.
    @ObservationIgnored private let probeSession: URLSession
    @ObservationIgnored private var running: [Int: RunningTransfer] = [:]
    /// Probes under way through `probeSession`, by job, and the identifier their reports carry.
    @ObservationIgnored private var probes: [UUID: (identifier: Int, task: Task<Void, Never>)] = [:]
    /// Probes' reports carry identifiers below zero, which no session task has.
    @ObservationIgnored private var lastProbeIdentifier = 0
    /// The tags of `running` as last saved, so a relaunch knows what was handed to the session.
    @ObservationIgnored private var savedHandedOut: Set<TransferTag> = []
    /// Transfers handed to the session before a relaunch that it neither lists nor has reported
    /// on yet: their ranges stay claimed until they report, or `relaunchReportWait` passes.
    @ObservationIgnored private var awaitingReports: Set<TransferTag> = []
    /// Tasks this app cancelled (to set aside, take back, replace or drop): their cancellation
    /// isn't a failure, and a body one delivers anyway, having finished first, is kept.
    @ObservationIgnored private var cancelledByUs: Set<Int> = []
    /// Tasks of jobs started over or forgotten: whatever they deliver is dropped, being bytes of
    /// the file as it was.
    @ObservationIgnored private var discarded: Set<Int> = []
    /// Tasks whose report has been handled in this run: the system can report a task twice, the
    /// second time without its body.
    @ObservationIgnored private var handledTasks: Set<Int> = []
    /// Tasks cancelled as stalled, with the bytes they had and when their attempt began: cut
    /// partway, they say the link drops (`recordCut`); finished first, they say nothing.
    @ObservationIgnored private var cancelledAsStalled: [Int: (received: Int64, attemptStart: Date)] = [:]
    /// The session is being asked about transfers that look stalled.
    @ObservationIgnored private var isCheckingStalls = false
    /// Transfers that looked stalled that the session no longer lists, and since when: done in
    /// the daemon, their reports still to come.
    @ObservationIgnored private var unlistedSince: [Int: Date] = [:]
    /// Chunks on their way from staging into their partial file, with their size: their ranges
    /// stay claimed, and their bytes count as the download's, until they're in.
    @ObservationIgnored private var writing: [TransferTag: Int64] = [:]
    /// When a transfer last moved or reported, for telling that nothing at all moves.
    @ObservationIgnored private var lastActivity = Date.now
    /// Room the system could purge counts as room until the device has run out with it counted:
    /// from then on, only room that's free.
    @ObservationIgnored private var countsPurgeableSpace = true
    /// The largest chunk room on the device allows, as last checked (`StorageBudget`).
    @ObservationIgnored private var spaceChunkLimit: Int64?
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var backgroundEventsDelivered = false
    /// False until `run()` has adopted the session's existing transfers; scheduling before that
    /// would request ranges that are already in flight.
    private var hasAdoptedTransfers = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var appStateObservations: [NotificationCenter.ObservationToken] = []
    #if !os(macOS)
    /// Waits out `settleDelay` after the app becomes active.
    @ObservationIgnored private var settling: Task<Void, Never>?
    #endif
    @ObservationIgnored private var lastSample: (date: Date, bytes: [UUID: Int64])?
    /// When each download's bytes last grew, as `refreshLiveProgress` samples them, lately.
    @ObservationIgnored private var arrivedAt: [UUID: Date] = [:]
    /// A download whose bytes grew this recently counts as transferring.
    nonisolated static let arrivalLinger: TimeInterval = 3
    @ObservationIgnored private var lastStallCheck = Date.now
    /// The open players, by their model's id, and whether each is playing.
    @ObservationIgnored private var players: [UUID: Bool] = [:]
    /// The open players that stream a server transcode.
    @ObservationIgnored private var transcodingPlayers: Set<UUID> = []
    /// The app is off screen, so the session holds the next files' chunks as well.
    @ObservationIgnored private var isQueuingAhead = false
    /// Transfers cancelled to set them aside whose resume data hasn't come yet, with the bytes
    /// each had; they stay claimed. One dropped meanwhile (its job removed or restarted) leaves,
    /// and its resume data with it.
    @ObservationIgnored private var awaitingResumeData: [TransferTag: Int64] = [:]
    /// Resume points of ranges set aside, to carry on from once their file is in the session
    /// again. Kept on disk too, so a kill meanwhile loses none of it. Their ranges stay claimed.
    @ObservationIgnored private var heldResumeData: [TransferTag: ResumePoint] = [:]
    /// Resume points of whole-file transfers cancelled partway, by job, to carry on from when
    /// the job's file goes to the session again. Kept on disk too.
    @ObservationIgnored private var wholeFileResumeData: [UUID: ResumePoint] = [:]
    /// A pass over the downloads' extras is under way.
    private var isFetchingExtras = false
    @ObservationIgnored private var extrasPass: Task<Void, Never>?
    /// Something asked for a pass while one ran, so another follows.
    @ObservationIgnored private var extrasPassWanted = false
    /// Downloads this pass found with all their extras.
    @ObservationIgnored private var extrasDone: Set<UUID> = []
    /// Downloads whose extras failed, how often in a row, and when to try again.
    @ObservationIgnored private var extrasFailures: [UUID: (count: Int, retryAt: Date)] = [:]
    @ObservationIgnored private var extrasRetry: Task<Void, Never>?
    /// How many bytes more than there's room for each queued download needs, as last checked.
    @ObservationIgnored private var spaceShortfalls: [UUID: Int64] = [:]
    @ObservationIgnored private var spaceCheckedAt = Date.distantPast
    /// The queue, a size or the limit changed since room was last checked.
    @ObservationIgnored private var isSpaceCheckDue = true
    /// Downloads whose partial file still takes room for ranges not recorded in it
    /// (`releaseUnrecorded`).
    @ObservationIgnored private var unreleased: Set<UUID> = []

    init(accounts: AccountStore, settings: AppSettings, history: WatchHistory, notifications: DownloadNotifications,
         storage: DownloadStorage = .standard) {
        self.accounts = accounts
        self.settings = settings
        self.history = history
        self.notifications = notifications
        self.storage = storage
        do {
            try storage.prepare()
            try storage.clearStaging()
        } catch {
            problem = "Couldn't prepare the downloads folder: \(error.localizedDescription)"
        }
        var hasJobs = false
        do {
            jobs = try storage.loadJobs()
            hasJobs = true
        } catch {
            problem = Self.setAsideUnreadableJobs(storage, error: error)
        }
        do {
            awaitingReports = Set(try storage.loadHandedOut())
            heldResumeData = try storage.loadHeld()
            wholeFileResumeData = try storage.loadResumePoints()
        } catch {
            problem = "Couldn't read what the last run left with the system: \(error.localizedDescription). Some of it may download again."
        }
        do {
            lastFreed = try storage.loadFreed()
        } catch {
            problem = "Couldn't read which downloads were deleted to make room: \(error.localizedDescription)"
        }

        delegate = TransferDelegate(stagingDirectory: storage.staging)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Each request says which networks it may use (`DownloadRules`); the session allows them all.
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = Self.connectionsPerHost
        // A connection that delivers nothing for a minute is dropped and its chunk retried.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        let probing = URLSessionConfiguration.ephemeral
        probing.timeoutIntervalForRequest = 60
        probing.requestCachePolicy = .reloadIgnoringLocalCacheData
        probing.urlCache = nil
        probeSession = URLSession(configuration: probing)
        transcodes = TranscodedDownloads(accounts: accounts, storage: storage)
        transcodes.host = self
        // Artwork of items no download is left for, as earlier builds could leave behind.
        if hasJobs { removeUnusedArtwork() }
        // What a chunk wrote before the app was killed partway through writing it.
        for job in jobs where job.status != .completed { releaseUnrecorded(of: job.id) }
    }

    private static func setAsideUnreadableJobs(_ storage: DownloadStorage, error: any Error) -> String {
        let aside = storage.root.appending(path: "jobs-unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
        do {
            try FileManager.default.moveItem(at: storage.jobsFile, to: aside)
            return "The saved download list couldn't be read (\(error.localizedDescription)). It was kept as \(aside.lastPathComponent)."
        } catch let moveError {
            return "The saved download list couldn't be read (\(error.localizedDescription)) or set aside (\(moveError.localizedDescription))."
        }
    }

    private var rules: DownloadRules { DownloadRules(settings) }

    // MARK: Running

    /// Adopts the transfers the session still has, then handles its events for the life of the app.
    func run() async {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let conditions = NetworkConditions(path)
            Task { @MainActor in self?.networkChanged(conditions) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "net.vinnysaj.vinnyfin.path"))
        followAppState()
        followPower()
        followRules()
        followSignIns()

        for task in await session.allTasks {
            guard let download = task as? URLSessionDownloadTask,
                  let tag = TransferTag(encoded: task.taskDescription),
                  let job = jobs.first(where: { $0.id == tag.jobId }), job.status == .active
            else {
                Self.log.info("Cancelling task \(task.taskIdentifier) of no active job: \(task.taskDescription ?? "untagged")")
                cancelledByUs.insert(task.taskIdentifier)
                task.cancel()
                continue
            }
            Self.log.info("Adopted task \(task.taskIdentifier) [\(tag.encoded)] state \(task.state.rawValue), \(task.countOfBytesReceived) bytes in")
            running[task.taskIdentifier] = RunningTransfer(tag: tag, task: download, access: NetworkAccess(task.originalRequest),
                                                           received: task.countOfBytesReceived)
        }
        awaitingReports.subtract(running.values.map(\.tag))
        if !awaitingReports.isEmpty {
            Self.log.info("\(self.awaitingReports.count) transfers from before the relaunch haven't reported yet")
            Task { [weak self] in
                try? await Task.sleep(for: Self.relaunchReportWait)
                guard let self, !self.awaitingReports.isEmpty else { return }
                Self.log.notice("\(self.awaitingReports.count) transfers from before the relaunch never reported; planning their ranges again")
                self.awaitingReports = []
                self.pump()
            }
        }
        hasAdoptedTransfers = true
        // Opened to play a file, the player can be up before the session's tasks are adopted.
        // Otherwise `pump` takes out what the session shouldn't hold now (opened in front, the
        // later files' transfers queued ahead before the relaunch), and carries on with ranges
        // held for a playback the last run ended during.
        if isPausedForPlayback { holdTransfers() }
        pump()
        fetchExtrasSoon()

        for await event in delegate.events {
            switch event {
            case .progress(let taskIdentifier, let received):
                guard let transfer = running[taskIdentifier] else { continue }
                // An error page isn't the file's bytes; the report says what the server answered.
                if let status = (transfer.task.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) { continue }
                lastActivity = .now
                running[taskIdentifier]?.received = received
                running[taskIdentifier]?.reported = received
                running[taskIdentifier]?.activity.noteProgress(now: .now)
                if !transfer.isResponseChecked, let status = (transfer.task.response as? HTTPURLResponse)?.statusCode {
                    running[taskIdentifier]?.isResponseChecked = true
                    if status == 200, transfer.tag.range != nil { rangeIgnored(by: taskIdentifier) }
                }
                if let reported = transfer.reported, received < reported { restarted(taskIdentifier, after: reported) }
            case .finished(let finished):
                lastActivity = .now
                if let tag = finished.tag { awaitingReports.remove(tag) }
                await handle(finished)
                pump()
            case .backgroundEventsDelivered:
                if let completion = backgroundCompletion {
                    backgroundCompletion = nil
                    completion()
                } else {
                    backgroundEventsDelivered = true
                }
            }
        }
    }

    /// The system's handler for a background launch; called once the launch's events are handled.
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        if backgroundEventsDelivered {
            backgroundEventsDelivered = false
            completion()
        } else {
            backgroundCompletion = completion
        }
    }

    /// Publishes progress and speed twice a second for as long as the caller's task runs, and
    /// replaces stalled transfers meanwhile. Runs for the life of the app, so whenever the
    /// process runs: in front, or kept running in the background by a background task.
    func trackProgress() async {
        while !Task.isCancelled {
            refreshLiveProgress()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Hands the session what's next and looks for missing extras, then returns once the queue
    /// has settled (every active download done or waiting for what the rules or room hold it
    /// back for, and the extras pass over, or held for a playback) or the caller's task is
    /// cancelled, for a background task to keep the app running that long. Meanwhile the
    /// session's events and `trackProgress` keep the queue moving.
    func keepMoving() async {
        pump()
        fetchExtrasSoon()
        let settled = Observations { [weak self] in
            guard let self else { return true }
            return self.hasAdoptedTransfers
                && (self.isPausedForPlayback
                    || (DownloadJob.queue(self.jobs).allSatisfy { self.waits[$0] != nil } && !self.isFetchingExtras))
        }
        for await isSettled in settled where isSettled || Task.isCancelled { return }
    }

    /// Lets the jobs someone started go on without keeping the app running, as after the
    /// person or the system stopped the background task that did.
    func forgetUserStartedJobs() {
        if !userStartedJobIds.isEmpty { userStartedJobIds = [] }
    }

    /// Whether the system should wait for power before launching the app to catch up on the queue.
    var catchUpRequiresExternalPower: Bool {
        rules.catchUpRequiresExternalPower(for: DownloadJob.queued(jobs))
    }

    private func noteStartedByUser(_ ids: some Sequence<UUID>) {
        userStartedJobIds.formUnion(ids)
        userStartCount += 1
    }

    // MARK: Commands

    /// Queues what `plan` says of an item at the end of the list: a version as it is, or the
    /// server's transcode of one (`TranscodedDownloads`). `startedByUser` is false for downloads
    /// smart downloads add by themselves; the first one someone starts asks whether vinnyfin may
    /// notify them.
    func enqueue(_ item: JellyfinItem, plan: DownloadPlan, startedByUser: Bool) {
        let known = jobs.contains { $0.itemId == item.id && $0.mediaSourceId == plan.source.id }
        guard !known else { return }
        let job = DownloadJob(item: item, plan: plan)
        jobs.append(job)
        if startedByUser {
            noteStartedByUser([job.id])
            notifications.requestAuthorizationIfNeeded()
        }
        isSpaceCheckDue = true
        save()
        pump()
        fetchExtrasSoon()
    }

    func pause(_ id: UUID) {
        pause([id])
    }

    /// Pauses every active download.
    func pauseAll() {
        pause(jobs.filter { $0.status == .active }.map(\.id))
    }

    /// Sets the jobs' transfers aside with the bytes they have, to carry on from when the jobs
    /// are resumed, but for those under way that can't keep their bytes and are far enough
    /// along to finish (`DownloadJob.finishesWhenPaused`). Reports still to come from before a
    /// relaunch keep their ranges claimed.
    private func pause(_ ids: [UUID]) {
        let ids = Set(ids).filter { id in jobs.contains { $0.id == id && $0.status == .active } }
        guard !ids.isEmpty else { return }
        for index in jobs.indices where ids.contains(jobs[index].id) { jobs[index].status = .paused }
        let transfers = running.filter { ids.contains($0.value.tag.jobId) }
        let finishing = transfers.filter { _, transfer in
            DownloadJob.finishesWhenPaused(received: transfer.bytes, expected: expectedBytes(of: transfer), canResume: transfer.canResume)
        }
        if !finishing.isEmpty { Self.log.info("Pausing: \(finishing.count) transfers that can't keep their bytes finish first") }
        setAside(transfers.filter { finishing[$0.key] == nil })
        for id in ids { probes.removeValue(forKey: id)?.task.cancel() }
        save()
        pump()
    }

    /// Continues a paused job, or retries a failed one from where it got to.
    func resume(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status == .paused || jobs[index].status == .failed else { return }
        jobs[index].resume()
        noteStartedByUser([id])
        isSpaceCheckDue = true
        save()
        pump()
    }

    /// Continues every paused job and retries every failed one.
    func resumeAll() {
        let ids = jobs.filter { $0.status == .paused || $0.status == .failed }.map(\.id)
        guard !ids.isEmpty else { return }
        for index in jobs.indices where ids.contains(jobs[index].id) { jobs[index].resume() }
        noteStartedByUser(ids)
        isSpaceCheckDue = true
        save()
        pump()
    }

    /// Puts the unfinished downloads in this order, which is the order they download in; any it
    /// leaves out follow in theirs. Moving the file in hand down lets its transfers under way
    /// finish before the new first file's go in; the rest come out without losing a byte.
    func reorderUnfinished(_ order: [UUID]) {
        let position = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        let unfinished = jobs.filter { $0.status != .completed }
        let reordered = unfinished.enumerated().sorted {
            (position[$0.element.id] ?? order.count + $0.offset) < (position[$1.element.id] ?? order.count + $1.offset)
        }.map(\.element)
        guard reordered.map(\.id) != unfinished.map(\.id) else { return }
        jobs = reordered + jobs.filter { $0.status == .completed }
        save()
        pump()
    }

    /// Moves a download to the front of the queue, resuming it if it was paused or failed.
    func downloadNext(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status != .completed else { return }
        var job = jobs.remove(at: index)
        if job.status != .active { job.resume() }
        jobs.insert(job, at: 0)
        noteStartedByUser([id])
        isSpaceCheckDue = true
        save()
        pump()
    }

    /// Downloads it next whatever the network rules and Only While Charging say, for when someone
    /// needs it anyway. Its transfers waiting for a network the rules allowed come out to go in
    /// again on this one.
    func downloadNow(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status != .completed else { return }
        jobs[index].downloadNowAt = .now
        downloadNext(id)
    }

    /// A player opened, or started or stopped playing; `isTranscoding` when it streams a server
    /// transcode, which a transcoded download then leaves the server to.
    func playerChanged(_ player: UUID, isPlaying: Bool, isTranscoding: Bool = false) {
        players[player] = isPlaying
        if isTranscoding { transcodingPlayers.insert(player) } else { transcodingPlayers.remove(player) }
        updateHold()
    }

    func playerClosed(_ player: UUID) {
        players[player] = nil
        transcodingPlayers.remove(player)
        // Watched downloads can make room again.
        isSpaceCheckDue = true
        updateHold()
        pump()
    }

    /// Follows the app coming to the front and leaving it, from UIKit's own notifications.
    /// SwiftUI's scene phase arrives seconds after the system has stopped counting the app as in
    /// the foreground: transfers queued then wait at the system's discretion, in a pool of their
    /// own beside the foreground ones, and on the way back the daemon starts queued ones before
    /// they're taken back. The app resigns active before it leaves the foreground, and enters
    /// the foreground before it's active again.
    ///
    /// Only a move away from active queues ahead, or a launch into the background: launching
    /// in front, the app isn't active yet without having left. Becoming active again counts once
    /// the app has stayed active for `settleDelay`. A Mac app isn't suspended, so it never queues
    /// ahead, and there the front is any time the app isn't hidden.
    private func followAppState() {
        let center = NotificationCenter.default
        #if os(macOS)
        isInFront = !NSApplication.shared.isHidden
        appStateObservations = [
            center.addObserver(of: NSApplication.shared, for: .didUnhide) { [weak self] _ in self?.appStateChanged(isInFront: true) },
            center.addObserver(of: NSApplication.shared, for: .didHide) { [weak self] _ in self?.appStateChanged(isInFront: false) },
        ]
        #else
        isInFront = UIApplication.shared.applicationState == .active
        isQueuingAhead = UIApplication.shared.applicationState == .background
        appStateObservations = [
            center.addObserver(of: UIApplication.shared, for: .didBecomeActive) { [weak self] _ in self?.becameActive() },
            center.addObserver(of: UIApplication.shared, for: .willResignActive) { [weak self] _ in self?.appStateChanged(isInFront: false) },
            center.addObserver(of: UIApplication.shared, for: .didEnterBackground) { [weak self] _ in self?.appStateChanged(isInFront: false) },
            center.addObserver(of: UIApplication.shared, for: .willEnterForeground) { [weak self] _ in self?.stopQueuingAhead() },
        ]
        #endif
    }

    #if !os(macOS)
    /// How long the app stays active before it's back in front. Locking the screen can make it
    /// active for a fraction of a second on the way (it does in the simulator): taking the queued
    /// transfers back then and queuing them again a moment later, with the app no longer in the
    /// foreground to the system, would leave them all at the system's discretion.
    static let settleDelay: Duration = .seconds(1)

    private func becameActive() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.appStateChanged(isInFront: true)
        }
    }

    /// Back to one file in the session: `pump` takes out the later files' transfers that haven't
    /// started, those queued ahead before a relaunch too. Ones under way finish.
    private func stopQueuingAhead() {
        isQueuingAhead = false
        pump()
    }
    #endif

    private func appStateChanged(isInFront: Bool) {
        #if !os(macOS)
        settling?.cancel()
        settling = nil
        isQueuingAhead = !isInFront
        #endif
        if isInFront != self.isInFront {
            self.isInFront = isInFront
            Self.log.info("App \(isInFront ? "in front" : "leaving the front")")
            updateHold()
            // The server's administrator may have taken downloads away meanwhile.
            if isInFront { Task { await transcodes.recheckPolicy() } }
        }
        pump()
    }

    /// Follows the device being plugged in and unplugged, for Only While Charging.
    private func followPower() {
        let changes = PowerSource.changes()
        isOnPower = PowerSource.isExternal
        Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                let isOnPower = PowerSource.isExternal
                guard isOnPower != self.isOnPower else { continue }
                self.isOnPower = isOnPower
                Self.log.info("On power: \(isOnPower.map { $0 ? "yes" : "no" } ?? "unknown", privacy: .public)")
                self.pump()
                self.fetchExtrasSoon()
            }
            guard !Task.isCancelled else { return }
            self?.problem = "vinnyfin can't tell when this \(Device.name) is plugged in, so Only While Charging may hold downloads back."
        }
    }

    /// Looks at the queue again, and for missing extras, whenever someone signs in: both need
    /// the server, so downloads queued while nobody was (a sign-in that ran out, say) wait for it.
    private func followSignIns() {
        let accounts = accounts
        Task { [weak self] in
            for await account in Observations({ accounts.client == nil ? nil : accounts.account }) where account != nil {
                guard let self else { return }
                self.pump()
                self.fetchExtrasSoon()
            }
        }
    }

    /// Looks at the queue again whenever Settings change what the rules allow.
    private func followRules() {
        let settings = settings
        Task { [weak self] in
            for await rules in Observations({ DownloadRules(settings) }) {
                guard let self else { return }
                Self.log.info("""
                    Rules: cellular \(rules.downloadsOverCellular), charging only \(rules.onlyWhileCharging), \
                    limit \(rules.storageLimit ?? -1)
                    """)
                self.isSpaceCheckDue = true
                self.pump()
            }
        }
    }

    /// Downloads leave the connection and the server to the picture while something plays, and
    /// while a player is open in front of the user, paused or between episodes, so pausing
    /// doesn't stop and start them. A paused player the app leaves lets them go on: they're let
    /// go as it resigns active, while it's still in the foreground, so the system starts them
    /// right away, carrying on from the bytes they had.
    private func updateHold() {
        let hold = players.values.contains(true) || (!players.isEmpty && isInFront)
        guard hold != isPausedForPlayback else { return }
        isPausedForPlayback = hold
        if hold { holdTransfers() } else { pump() }
    }

    /// Sets every transfer aside with its bytes, but for those that can't keep them and are
    /// close enough to done that finishing costs the playback less than cutting them would lose
    /// (`DownloadJob.finishesWhenPaused`, `playbackFinishLimit`).
    private func holdTransfers() {
        let finishing = running.filter { _, transfer in
            DownloadJob.finishesWhenPaused(received: transfer.bytes, expected: expectedBytes(of: transfer), canResume: transfer.canResume,
                                           limit: DownloadJob.playbackFinishLimit)
        }
        Self.log.info("Holding \(self.running.count - finishing.count) transfers for a playback; \(finishing.count) that can't keep their bytes finish first")
        setAside(running.filter { finishing[$0.key] == nil })
    }

    /// What a transfer is to fetch: its range, or the whole file.
    private func expectedBytes(of transfer: RunningTransfer) -> Int64? {
        transfer.tag.range?.count64 ?? jobs.first { $0.id == transfer.tag.jobId }?.totalBytes
    }

    /// Cancels the transfers keeping any resume data, to carry on from later, those waiting
    /// their turn first: the daemon fills a connection freed by one under way from the waiting
    /// ones. Suspending would keep them in place, but a suspended transfer loses its connection
    /// after a minute or so and starts its range over, and one suspended when the app dies stays
    /// that way until the app opens again.
    private func setAside(_ transfers: [Int: RunningTransfer]) {
        for (identifier, transfer) in Self.cancellationOrder(transfers) {
            cancelledByUs.insert(identifier)
            running[identifier] = nil
            awaitingResumeData[transfer.tag] = transfer.bytes
            transfer.task.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor in self?.setAside(data, for: transfer.tag) }
            })
        }
        saveHandedOut()
    }

    /// The transfers in the order to cancel them in: those waiting their turn first, as the
    /// daemon gives a connection freed by one under way to one waiting.
    private static func cancellationOrder(_ transfers: [Int: RunningTransfer]) -> [(key: Int, value: RunningTransfer)] {
        transfers.sorted { !$0.value.isUnderWay && $1.value.isUnderWay }
    }

    /// The range stayed claimed until now, so it wasn't planned again meanwhile; with no data
    /// (it hadn't started), it's planned afresh.
    private func setAside(_ data: Data?, for tag: TransferTag) {
        guard let bytes = awaitingResumeData.removeValue(forKey: tag) else { return }
        if let data {
            let point = ResumePoint(data: data, bytes: bytes)
            if tag.isWholeFile {
                keepResumeData(point, of: tag.jobId)
            } else {
                keepHeld(point, for: tag)
            }
        }
        pump()
        fetchExtrasSoon()
    }

    private func keepHeld(_ point: ResumePoint, for tag: TransferTag) {
        heldResumeData[tag] = point
        do {
            try storage.saveHeld(point, for: tag)
        } catch {
            problem = "Couldn't keep a held download's progress: \(error.localizedDescription)"
        }
    }

    private func forgetHeld(_ tags: Set<TransferTag>) {
        guard !tags.isEmpty else { return }
        for tag in tags { heldResumeData[tag] = nil }
        do {
            try storage.removeHeld(where: tags.contains)
        } catch {
            problem = "Couldn't clear a held download's progress: \(error.localizedDescription)"
        }
    }

    /// Whether a transfer handed to the session, or one that may still report from before a
    /// relaunch, covers some of the tag's range.
    private func isClaimed(_ tag: TransferTag) -> Bool {
        running.values.contains { tag.overlaps($0.tag) } || awaitingReports.contains(where: tag.overlaps)
    }

    /// Starts over from the first byte, for a source that changed on the server.
    func restart(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status != .completed else { return }
        transcodes.leave(jobs[index])
        cancelTransfers(of: id, discarding: true)
        removePartial(of: id)
        jobs[index].resetProgress()
        noteStartedByUser([id])
        isSpaceCheckDue = true
        save()
        pump()
    }

    /// Stops and forgets a job, with its extras, and the item's artwork once no other job of it
    /// is left. `deletingFile` deletes the finished file and the subtitles beside it too.
    func remove(_ id: UUID, deletingFile: Bool = false) {
        guard forget(id, deletingFile: deletingFile) else { return }
        removeUnusedArtwork()
        save()
        pump()
    }

    /// Stops a job and drops it from the list with its extras, deleting its file if asked.
    /// False when there's no such job.
    @discardableResult
    private func forget(_ id: UUID, deletingFile: Bool) -> Bool {
        guard let index = index(of: id) else { return false }
        let job = jobs[index]
        transcodes.leave(job)
        cancelTransfers(of: id)
        removePartial(of: id)
        if deletingFile, let savedPath = job.savedPath {
            let file = storage.finished.appending(path: savedPath)
            do {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            } catch {
                problem = "Couldn't delete \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }
        removeExtras(of: job, besideFile: deletingFile)
        jobs.remove(at: index)
        isSpaceCheckDue = true
        return true
    }

    /// Stops and forgets every unfinished job, with the artwork of items no finished one is
    /// left for, for signing out. Finished files stay.
    func removeUnfinished() {
        for job in jobs where job.status != .completed {
            transcodes.leave(job)
            cancelTransfers(of: job.id)
            removePartial(of: job.id)
            removeExtras(of: job, besideFile: false)
        }
        jobs.removeAll { $0.status != .completed }
        removeUnusedArtwork()
        isSpaceCheckDue = true
        save()
    }

    func savedFileURL(of job: DownloadJob) -> URL? {
        job.savedPath.map { storage.finished.appending(path: $0) }
    }

    /// A finished download of the item (of that version, when one is given) whose file is still
    /// there, with the extras it has saved.
    func playableFile(itemId: String, mediaSourceId: String?) -> PlaybackResolver.DownloadedCopy? {
        let candidates = jobs.filter {
            $0.itemId == itemId && $0.status == .completed && (mediaSourceId == nil || $0.mediaSourceId == mediaSourceId)
        }
        for job in candidates {
            if let url = savedFileURL(of: job), FileManager.default.fileExists(atPath: url.path) {
                let saved = DownloadExtras.saved(for: job, storage: storage) { FileManager.default.fileExists(atPath: $0.path) }
                // A transcoded file's streams are the transcode's, numbered as it has them.
                let (item, subtitles) = job.transcode?.playback(of: job.item, subtitleFiles: saved.subtitles) ?? (job.item, saved.subtitles)
                return PlaybackResolver.DownloadedCopy(url: url, item: item, segments: job.segments ?? [],
                                                       subtitleFiles: subtitles, trickplaySheets: saved.trickplaySheets,
                                                       chapterImages: saved.chapterImages)
            }
        }
        return nil
    }

    /// Jobs for the item in any state.
    func jobs(forItem itemId: String) -> [DownloadJob] {
        jobs.filter { $0.itemId == itemId }
    }

    func isDownloaded(_ itemId: String) -> Bool {
        jobs.contains { $0.itemId == itemId && $0.status == .completed }
    }

    /// Removes every download of the item and deletes its files.
    func deleteDownloads(ofItem itemId: String) {
        let ids = jobs.filter { $0.itemId == itemId }.map(\.id)
        for id in ids { forget(id, deletingFile: true) }
        removeUnusedArtwork()
        save()
        pump()
    }

    /// Deletes the downloaded episodes watched since they were queued, here or, as far as the
    /// server last said, anywhere: what Delete Watched Episodes asks. Never while a player is
    /// open, since the episode in it could be one of them.
    func deleteWatchedEpisodes() {
        guard players.isEmpty else { return }
        let watched = watchedDownloads().filter(\.isEpisode)
        guard !watched.isEmpty else { return }
        for job in watched {
            Self.log.info("Deleting watched episode \(job.shortName, privacy: .public)")
            forget(job.id, deletingFile: true)
        }
        removeUnusedArtwork()
        save()
        pump()
    }

    /// Drops the unfinished downloads of these shows' episodes watched since they were queued,
    /// here or anywhere, for smart downloads, which keep shows downloaded ahead of where they're
    /// watched. Never while a player is open.
    func dropWatchedEpisodes(ofShows seriesIds: Set<String>) {
        guard players.isEmpty else { return }
        let watched = DownloadJob.watchedWhileQueued(jobs, ofShows: seriesIds) { history.entry(for: $0) }
        guard !watched.isEmpty else { return }
        for job in watched {
            Self.log.info("Dropping \(job.shortName, privacy: .public), watched while it was queued")
            forget(job.id, deletingFile: false)
        }
        removeUnusedArtwork()
        save()
        pump()
    }

    /// Keeps what the server says about how downloads were watched, finished or not, so what
    /// counts as watched holds offline and in the background too.
    func recordWatchState(from items: [JellyfinItem]) {
        let server = Dictionary(items.map { ($0.id, $0.userData) }) { first, _ in first }
        var changed = false
        for index in jobs.indices where jobs[index].item != nil {
            guard let data = server[jobs[index].itemId], jobs[index].item?.userData != data else { continue }
            jobs[index].item?.userData = data
            changed = true
        }
        guard changed else { return }
        isSpaceCheckDue = true
        save()
    }

    /// The finished downloads watched since they were queued, the one watched longest ago
    /// first: what goes to make room, and for Delete Watched Episodes.
    private func watchedDownloads() -> [DownloadJob] {
        jobs.compactMap { job -> (job: DownloadJob, watchedAt: Date)? in
            guard job.status == .completed,
                  case .watched(let date) = job.watchState(local: history.entry(for: job.itemId))
            else { return nil }
            return (job, date)
        }
        .sorted { $0.watchedAt < $1.watchedAt }
        .map(\.job)
    }

    /// The items and shows whose artwork the downloads keep (`DownloadExtras.artwork`).
    private static func artworkIds(of jobs: [DownloadJob]) -> Set<String> {
        Set(jobs.flatMap { [$0.itemId] + ($0.seriesId.map { [$0] } ?? []) })
    }

    /// Deletes the saved artwork of items and shows no download is left for.
    private func removeUnusedArtwork() {
        do {
            try storage.removeArtwork(keeping: Self.artworkIds(of: jobs))
        } catch {
            problem = "Couldn't delete saved artwork: \(error.localizedDescription)"
        }
    }

    /// The downloaded episode that comes after `episode` in its show, for playing on offline.
    func downloadedEpisode(after episode: JellyfinItem) -> JellyfinItem? {
        guard let seriesId = episode.seriesId else { return nil }
        let current = Self.watchingOrder(episode)
        return downloadedEpisodes(seriesId: seriesId).first { Self.watchingOrder($0) > current }
    }

    /// A show's downloaded episodes, in watching order.
    func downloadedEpisodes(seriesId: String) -> [JellyfinItem] {
        jobs.compactMap { $0.status == .completed ? $0.item : nil }
            .filter { $0.seriesId == seriesId }
            .sorted { Self.watchingOrder($0) < Self.watchingOrder($1) }
    }

    private static func watchingOrder(_ episode: JellyfinItem) -> Int {
        (episode.parentIndexNumber ?? 0) * 10_000 + (episode.indexNumber ?? 0)
    }

    /// Bytes downloads take up: finished files with their extras, and what unfinished ones have
    /// so far (`bytesSoFar`) with theirs.
    var storageUsed: Int64 {
        storageUsed(bytesSoFar: bytesSoFar())
    }

    private func storageUsed(bytesSoFar: [UUID: Int64]) -> Int64 {
        jobs.reduce(0) { $0 + ($1.status == .completed ? $1.storedBytes : (bytesSoFar[$1.id] ?? 0) + ($1.extrasBytes ?? 0)) }
    }

    func availableCapacity() -> Int64? { storage.availableCapacity(countingPurgeable: countsPurgeableSpace) }

    /// The room the downloads already queued don't need, for new ones: on the device, and under
    /// the storage limit when there is one, whichever is less. Nil when neither can be told.
    func spaceForNewDownloads() -> Int64? {
        let bytesSoFar = bytesSoFar()
        let queuedNeed = DownloadJob.queued(jobs).reduce(0) { $0 + max(0, ($1.displayTotalBytes ?? 0) - (bytesSoFar[$1.id] ?? 0)) }
        let rooms = [availableCapacity(), rules.storageLimit.map { $0 - storageUsed(bytesSoFar: bytesSoFar) }].compactMap(\.self)
        return rooms.min().map { $0 - queuedNeed }
    }

    /// Saved artwork for an item, for showing it offline.
    func artworkURL(itemId: String, kind: JellyfinClient.ImageKind) -> URL? {
        _ = artworkRevision
        let file = storage.artworkFile(itemId: itemId, kind: kind)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    var finishedFolder: URL { storage.finished }

    // MARK: Scheduling

    /// Publishes finished files, works out what waits (making room where it can), takes out of
    /// the session what shouldn't wait there, then carries on with ranges set aside and hands
    /// it what `DownloadJob.plan` gives.
    private func pump() {
        guard hasAdoptedTransfers else { return }
        defer { saveHandedOut() }
        var published = false
        for index in jobs.indices where jobs[index].status == .active && jobs[index].isTransferComplete {
            publish(index)
            published = true
        }
        if published { save() }
        let now = Date.now
        updateWaits(now: now)
        notifications.attentionChanged(jobs: jobs, waits: waits, isNetworkReachable: network.isReachable,
                                       serverName: accounts.account?.serverName, now: now)
        guard !isPausedForPlayback else { return }
        let held = Set(waits.filter { !$0.value.isNetwork }.keys)
        let waitingForNetwork = Set(waits.filter(\.value.isNetwork).keys)
        let rules = rules
        // Only While Charging can't hold back what the session has once the app is suspended.
        let onlyInHand = Set(DownloadJob.queued(jobs).filter(rules.waitsForPower).map(\.id))
        let inSession = DownloadJob.sessionFiles(jobs, held: isQueuingAhead ? held : held.union(waitingForNetwork),
                                                 queuingAhead: isQueuingAhead, onlyInHand: onlyInHand, now: now)
        takeBack(keeping: inSession)
        // Transfers of other files on the wire hold the file in hand back in front, as for its
        // new chunks; one waiting for a network it may use isn't on the wire, and the single
        // transfer of a file that yields goes alongside.
        let yielding = Set(jobs.filter(\.yields).map(\.id))
        let finishing = Set(running.values.filter { $0.carriesBytes && $0.access.allows(network) }.map(\.tag.jobId))
            .subtracting(yielding)
        let waitsOn = isQueuingAhead ? [] : downloadingJobId.map { finishing.subtracting([$0]) } ?? []
        if fileInHandWaitsOn != waitsOn { fileInHandWaitsOn = waitsOn }
        guard let client = accounts.client else { return }
        let segmentWindows = transcodes.windows(for: jobs, claimed: running.values.map(\.tag) + awaitingReports + awaitingResumeData.keys,
                                                inSession: inSession, queuingAhead: isQueuingAhead, bytesPerSecond: bytesPerSecond, now: now)
        carryOnSetAside(in: inSession, finishing: finishing, segmentWindows: segmentWindows, client: client)
        let probing = probes.keys.map { TransferTag(jobId: $0, range: DownloadJob.probeRange) }
        let claimed = running.values.map(\.tag) + awaitingReports + probing + heldResumeData.keys + awaitingResumeData.keys
            + writing.keys
        let plan = DownloadJob.plan(jobs, running: claimed, finishing: finishing, held: held, waitingForNetwork: waitingForNetwork,
                                    onlyInHand: onlyInHand, chunkLimit: spaceChunkLimit, segmentWindows: segmentWindows,
                                    budget: Self.maxQueuedTransfers - running.count, queuingAhead: isQueuingAhead, now: now)
        for tag in plan {
            guard let job = jobs.first(where: { $0.id == tag.jobId }) else { continue }
            if job.rangeSupport == .unknown, tag.range == DownloadJob.probeRange {
                probe(job, client: client)
            } else {
                start(tag, for: job, client: client)
            }
        }
    }

    /// Works out what holds each queued download back: room first, then the rules.
    private func updateWaits(now: Date) {
        let rules = rules
        let queued = DownloadJob.queued(jobs)
        checkSpaceIfDue(queued, rules: rules, now: now)
        var waits: [UUID: DownloadWait] = [:]
        for job in queued {
            if let needed = spaceShortfalls[job.id] {
                waits[job.id] = .space(needed: needed)
            } else if let wait = rules.wait(for: job, network: network, isOnPower: isOnPower) {
                waits[job.id] = wait
            }
        }
        if waits != self.waits {
            Self.log.info("Waiting: \(waits.map { "\($0.key.uuidString.prefix(8)) \($0.value)" }.sorted().joined(separator: ", "), privacy: .public)")
            self.waits = waits
        }
        let fileInHand = DownloadJob.fileInHand(jobs, held: Set(waits.keys))
        if downloadingJobId != fileInHand { downloadingJobId = fileInHand }
    }

    /// Works out which queued downloads there's room for, under the limit and on the device,
    /// deleting watched downloads to make it (`StorageBudget`). Never while a player is open:
    /// the download in it could be one of them.
    private func checkSpaceIfDue(_ queued: [DownloadJob], rules: DownloadRules, now: Date) {
        guard isSpaceCheckDue || now.timeIntervalSince(spaceCheckedAt) > Self.spaceCheckInterval else { return }
        isSpaceCheckDue = false
        spaceCheckedAt = now
        for jobId in unreleased { releaseUnrecorded(of: jobId) }
        let available = availableCapacity()
        let bytesSoFar = bytesSoFar()
        let used = storageUsed(bytesSoFar: bytesSoFar)
        var outcome = StorageBudget.plan(queue: queued, bytesSoFar: bytesSoFar, used: used, available: available,
                                         limit: rules.storageLimit, deletable: [])
        if !outcome.shortfalls.isEmpty, players.isEmpty {
            let deletable = watchedDownloads().map { StorageBudget.Deletable(id: $0.id, bytes: $0.storedBytes) }
            if !deletable.isEmpty {
                outcome = StorageBudget.plan(queue: queued, bytesSoFar: bytesSoFar, used: used, available: available,
                                             limit: rules.storageLimit, deletable: deletable)
                makeRoom(deleting: outcome.deletions)
            }
        }
        if outcome.shortfalls != spaceShortfalls {
            Self.log.notice("Short of room: \(outcome.shortfalls.map { "\($0.key.uuidString.prefix(8)) \($0.value)" }.joined(separator: ", "), privacy: .public)")
        }
        if outcome.chunkLimit != spaceChunkLimit {
            Self.log.notice("Chunks limited by room on the device: \(outcome.chunkLimit.map(String.init) ?? "no longer", privacy: .public)")
        }
        spaceShortfalls = outcome.shortfalls
        spaceChunkLimit = outcome.chunkLimit
    }

    private func makeRoom(deleting ids: [UUID]) {
        let deleted = ids.compactMap { id in jobs.first { $0.id == id } }
        guard !deleted.isEmpty else { return }
        for job in deleted {
            Self.log.notice("Deleting \(job.shortName, privacy: .public), watched, to make room")
            forget(job.id, deletingFile: true)
        }
        removeUnusedArtwork()
        save()
        let freed = FreedSpace(titles: deleted.map(\.shortName), bytes: deleted.reduce(0) { $0 + ($1.totalBytes ?? 0) }, date: .now)
        lastFreed = freed
        do {
            try storage.saveFreed(freed)
        } catch {
            problem = "Couldn't note which downloads were deleted to make room: \(error.localizedDescription)"
        }
    }

    /// Takes back transfers that haven't started and shouldn't wait in the session now: those
    /// of files not in `inSession`, or made for networks the rules no longer give their file,
    /// timed for a retry their job no longer waits as long for, and pieces of a transcode that
    /// asking for now would start the server's transcode elsewhere. Ones with bytes, under way
    /// or carrying on from resume data, finish, unless they can't use the network the device is
    /// on while the rules now let their file use it: their bytes go, as resume data keeps the
    /// networks a transfer was made for, and their range is planned again for this one.
    private func takeBack(keeping inSession: Set<UUID>) {
        let rules = rules
        let byId = Dictionary(jobs.map { ($0.id, $0) }) { first, _ in first }
        var count = 0
        var stranded = 0
        for (identifier, transfer) in running {
            let job = byId[transfer.tag.jobId]
            if transfer.carriesBytes {
                guard let job, job.status == .active, transfer.access.isStranded(on: network, fileAccess: rules.access(for: job))
                else { continue }
                // Without its resume data, which would carry the old networks over.
                cancelledByUs.insert(identifier)
                running[identifier] = nil
                transfer.task.cancel()
                stranded += 1
            } else if let job, inSession.contains(job.id), transfer.access == rules.access(for: job),
                      !job.waitsPastRetry(beginningAt: transfer.task.earliestBeginDate, now: .now),
                      transfer.tag.segment.map({ transcodes.mayKeep($0, of: job) }) ?? true {
                continue
            } else {
                cancel(identifier, transfer)
            }
            count += 1
        }
        guard count > 0 else { return }
        Self.log.info("Took back \(count) transfers, \(stranded) of them stranded on networks this one isn't")
    }

    /// Starts the ranges set aside whose file is in the session again, from their bytes, in
    /// queue order: in front, once other files' transfers on the wire are done, as for new
    /// chunks. One whose range came in by other means, or whose job is gone, is dropped. A piece
    /// of a transcode carries on once `segmentWindows` has it.
    private func carryOnSetAside(in inSession: Set<UUID>, finishing: Set<UUID>, segmentWindows: [UUID: [Int]], client: JellyfinClient) {
        guard !heldResumeData.isEmpty else { return }
        let order = Dictionary(jobs.enumerated().map { ($1.id, $0) }) { first, _ in first }
        func place(_ tag: TransferTag) -> Int64 { tag.range?.lowerBound ?? Int64(tag.segment ?? 0) }
        let sorted = heldResumeData.sorted {
            (order[$0.key.jobId] ?? .max, place($0.key)) < (order[$1.key.jobId] ?? .max, place($1.key))
        }
        var done: Set<TransferTag> = []
        for (tag, point) in sorted {
            guard let job = jobs.first(where: { $0.id == tag.jobId }), job.status != .completed,
                  !tag.isWholeFile, !job.isDelivered(tag), !running.values.contains(where: { tag.overlaps($0.tag) })
            else {
                done.insert(tag)
                continue
            }
            guard job.status == .active, inSession.contains(job.id), isQueuingAhead || finishing.subtracting([job.id]).isEmpty,
                  !awaitingReports.contains(where: tag.overlaps), running.count < Self.maxQueuedTransfers,
                  tag.segment.map({ segmentWindows[job.id]?.contains($0) ?? false }) ?? true
            else { continue }
            start(tag, for: job, client: client, resumeData: point)
            done.insert(tag)
        }
        if !done.isEmpty { Self.log.info("Carried on with or dropped \(done.count) ranges set aside") }
        forgetHeld(done)
    }

    /// Asks the server for a file's first byte through `probeSession`, at the job's retry time
    /// if it has one, and hands the answer to `handle` like a transfer's. A server that ignores
    /// Range answers with the whole file: the probe stops at the headers, and the file comes
    /// through the background session in one request. The app asks for background time while
    /// the probe is out, so one sent just before the app leaves the front, or while Siri, a
    /// shortcut or a control runs it in the background, still hands its file to the background
    /// session. A probe the app is suspended or killed during all the same fails, or is never
    /// sent, and goes again the next time the app runs.
    private func probe(_ job: DownloadJob, client: JellyfinClient) {
        let tag = TransferTag(jobId: job.id, range: DownloadJob.probeRange)
        var request = URLRequest(url: client.streamURL(itemId: job.itemId, mediaSourceId: job.mediaSourceId))
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(tag.rangeHeader, forHTTPHeaderField: "Range")
        rules.access(for: job).apply(to: &request)
        lastProbeIdentifier -= 1
        let identifier = lastProbeIdentifier
        let retryAt = job.retryAt
        let staging = storage.staging
        let task = Task { [weak self, probeSession] in
            if let retryAt, retryAt > .now { try? await Task.sleep(for: .seconds(retryAt.timeIntervalSinceNow)) }
            guard !Task.isCancelled else { return }
            #if !os(macOS)
            let backgroundTime = BackgroundTime(named: "Download probe")
            defer { backgroundTime.end() }
            #endif
            Self.log.debug("Probing [\(tag.encoded)] as \(identifier)")
            let finished = await Self.fetchProbe(request, tag: tag, identifier: identifier, into: staging, using: probeSession)
            guard let self else { return }
            // Cancelled meanwhile, for a pause, removal or restart.
            guard self.probes[job.id]?.identifier == identifier else { return self.discard(finished.stagedFile) }
            self.probes[job.id] = nil
            if finished.response?.statusCode == 200, let index = self.index(of: job.id), self.jobs[index].status == .active,
               case .wholeFile = self.jobs[index].evaluate(finished.response, stagedSize: finished.response?.contentLength ?? 1, tag: tag)
            {
                Self.log.notice("[\(tag.encoded)] The server ignores Range: downloading the whole file in one request")
                self.jobs[index].rangeSupport = .unsupported
                self.jobs[index].recordSuccess()
                self.save()
            } else {
                await self.handle(finished)
            }
            self.pump()
        }
        probes[job.id] = (identifier, task)
    }

    /// The probe's answer as a transfer's report: the bytes asked for in staging for a 206,
    /// however much more the server goes on to send, which its Content-Range says; the headers
    /// alone otherwise.
    @concurrent
    private nonisolated static func fetchProbe(
        _ request: URLRequest, tag: TransferTag, identifier: Int, into staging: URL, using session: URLSession
    ) async -> TransferDelegate.Finished {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let info = (response as? HTTPURLResponse).map(ResponseInfo.init)
            guard info?.statusCode == 206 else {
                bytes.task.cancel()
                return TransferDelegate.Finished(taskIdentifier: identifier, tag: tag, response: info, stagedFile: nil,
                                                 stagedSize: 0, error: nil, resumeData: nil)
            }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= tag.range?.count ?? 1 { break }
            }
            bytes.task.cancel()
            let file = staging.appending(path: UUID().uuidString)
            try body.write(to: file)
            return TransferDelegate.Finished(taskIdentifier: identifier, tag: tag, response: info, stagedFile: file,
                                             stagedSize: Int64(body.count), error: nil, resumeData: nil)
        } catch {
            return TransferDelegate.Finished(taskIdentifier: identifier, tag: tag, response: nil, stagedFile: nil,
                                             stagedSize: nil, error: error, resumeData: nil)
        }
    }

    /// Starts a transfer, from `resumeData` when there is some: the bytes a cut-off or set-aside
    /// transfer already received (only servers that send ETag or Last-Modified allow it). A new
    /// request carries the networks the rules give its job; one from resume data keeps those it
    /// was made with.
    private func start(_ tag: TransferTag, for job: DownloadJob, client: JellyfinClient, resumeData: ResumePoint? = nil) {
        let task: URLSessionDownloadTask
        let resumePoint = resumeData ?? (tag.isWholeFile ? takeResumeData(of: job.id) : nil)
        if let resumePoint {
            task = session.downloadTask(withResumeData: resumePoint.data)
        } else if let segment = tag.segment {
            guard var request = transcodes.request(for: segment, of: job) else { return }
            rules.access(for: job).apply(to: &request)
            task = session.downloadTask(with: request)
            if let bytes = job.transcode?.expectedSegmentBytes { task.countOfBytesClientExpectsToReceive = bytes }
        } else {
            var request = URLRequest(url: client.streamURL(itemId: job.itemId, mediaSourceId: job.mediaSourceId))
            // Byte offsets have to be offsets into the file itself, not into a compressed body.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let header = tag.rangeHeader { request.setValue(header, forHTTPHeaderField: "Range") }
            rules.access(for: job).apply(to: &request)
            task = session.downloadTask(with: request)
            if let range = tag.range { task.countOfBytesClientExpectsToReceive = range.upperBound - range.lowerBound }
        }
        task.taskDescription = tag.encoded
        if let retryAt = job.retryAt, retryAt > .now { task.earliestBeginDate = retryAt }
        let access = NetworkAccess(task.originalRequest)
        running[task.taskIdentifier] = RunningTransfer(tag: tag, task: task, access: access, received: 0,
                                                       carried: resumePoint?.bytes ?? 0, resumed: resumePoint != nil)
        task.resume()
        Self.log.debug("""
            Started task \(task.taskIdentifier) [\(tag.encoded)] on \(access.summary, privacy: .public)\
            \(resumePoint.map { " from resume data of \($0.bytes) bytes" } ?? "")\(task.earliestBeginDate.map { " from \($0)" } ?? "")
            """)
    }

    /// Cancels the job's transfers, or only those whose range `matching` accepts, and forgets
    /// any set aside or awaiting a report. `discarding` drops whatever they deliver anyway, for a
    /// job that starts over.
    private func cancelTransfers(of jobId: UUID, discarding: Bool = false, matching: (Range<Int64>) -> Bool = { _ in true }) {
        // A whole-file transfer has no range and only goes with the whole job.
        func isMatch(_ tag: TransferTag) -> Bool { tag.jobId == jobId && (tag.range.map(matching) ?? true) }
        for (identifier, transfer) in Self.cancellationOrder(running) where isMatch(transfer.tag) {
            if discarding { discarded.insert(identifier) }
            cancel(identifier, transfer)
        }
        awaitingReports = awaitingReports.filter { !isMatch($0) }
        awaitingResumeData = awaitingResumeData.filter { !isMatch($0.key) }
        if isMatch(TransferTag(jobId: jobId, range: DownloadJob.probeRange)) { probes.removeValue(forKey: jobId)?.task.cancel() }
        forgetHeld(Set(heldResumeData.keys.filter(isMatch)))
    }

    private func cancel(_ identifier: Int, _ transfer: RunningTransfer) {
        cancelledByUs.insert(identifier)
        running[identifier] = nil
        if transfer.tag.isWholeFile, !discarded.contains(identifier) {
            // All a whole-file transfer has is its resume data: stopped, it carries on from there
            // when retried.
            let bytes = transfer.bytes
            transfer.task.cancel(byProducingResumeData: { [weak self] data in
                guard let data else { return }
                let point = ResumePoint(data: data, bytes: bytes)
                Task { @MainActor in self?.keepResumeData(point, of: transfer.tag.jobId) }
            })
        } else {
            transfer.task.cancel()
        }
    }

    /// A range request is being answered with the whole file: the file's stream ignores Range,
    /// so this transfer fetches the file, and its other transfers come out at once rather than
    /// each fetching it again. The ranges the file had go, as the whole file takes their place.
    private func rangeIgnored(by taskIdentifier: Int) {
        guard let transfer = running[taskIdentifier], let index = index(of: transfer.tag.jobId),
              jobs[index].rangeSupport != .unsupported
        else { return }
        let jobId = transfer.tag.jobId
        let others = running.filter { $0.key != taskIdentifier && $0.value.tag.jobId == jobId }
        Self.log.notice("Task \(taskIdentifier) [\(transfer.tag.encoded)] brings the whole file for a range: cancelling the file's \(others.count) other transfers")
        for (identifier, other) in Self.cancellationOrder(others) { cancel(identifier, other) }
        awaitingReports = awaitingReports.filter { $0.jobId != jobId }
        awaitingResumeData = awaitingResumeData.filter { $0.key.jobId != jobId }
        forgetHeld(Set(heldResumeData.keys.filter { $0.jobId == jobId }))
        probes.removeValue(forKey: jobId)?.task.cancel()
        jobs[index].rangeIgnored()
        removePartial(of: jobId)
        save()
        saveHandedOut()
    }

    /// The daemon retries a dropped transfer by itself, without telling the app. Where the server
    /// gives no validators to resume with (Gelato's streams), the retry starts the range over, and
    /// a link that drops more often than a chunk takes would never finish one. So a byte count
    /// going backwards counts as a dropped connection: the job's chunks shrink, and a transfer now
    /// far bigger than a chunk is replaced by smaller ones.
    private func restarted(_ taskIdentifier: Int, after lostBytes: Int64) {
        guard let transfer = running[taskIdentifier], let index = index(of: transfer.tag.jobId),
              jobs[index].status == .active
        else { return }
        jobs[index].recordCut(receivedBytes: lostBytes, attemptStart: transfer.attemptStart)
        running[taskIdentifier]?.attemptStart = .now
        Self.log.notice("Task \(taskIdentifier) [\(transfer.tag.encoded)] restarted after \(lostBytes) bytes; chunks now \(self.jobs[index].chunkSize)")
        if let range = transfer.tag.range, range.count64 > 2 * jobs[index].chunkSize {
            cancelledByUs.insert(taskIdentifier)
            transfer.task.cancel()
            running[taskIdentifier] = nil
        }
        save()
        pump()
    }

    /// Replaces the transfers that have moved nothing for `stallLimit` since they got under way,
    /// by what their tasks say they've received (`TransferActivity`): one waiting its turn, timed
    /// for later, or finished with its report still to handle isn't stalled; nor is one waiting
    /// for a network it may use. When nothing at all has moved or reported for that long while
    /// the app is in front, the oldest `connectionsPerHost` waiting count too: a transfer can
    /// stall before any answer. Off screen, transfers wait at the system's discretion, so nothing
    /// moving says nothing. The session is asked first (`replace(stalled:listed:now:)`).
    private func replaceStalledTransfers(now: Date) {
        for (identifier, transfer) in running {
            let before = transfer.activity.lastProgress
            running[identifier]?.activity.observe(bytes: transfer.task.countOfBytesReceived, hasResponse: transfer.task.response != nil,
                                                  now: now)
            if running[identifier]?.activity.lastProgress != before { lastActivity = now }
        }
        guard isNetworkReachable, !isPausedForPlayback, !isCheckingStalls else { return }
        let movable = running.filter { $0.value.access.allows(network) && ($0.value.task.earliestBeginDate ?? .distantPast) <= now }
        var due = Set(movable.filter { $0.value.activity.isStalled(state: $0.value.task.state, now: now, limit: Self.stallLimit) }.keys)
        if isInFront, now.timeIntervalSince(lastActivity) > Self.stallLimit {
            let waiting = movable.filter { _, transfer in
                !transfer.activity.isUnderWay && transfer.task.state == .running
                    && now.timeIntervalSince(transfer.activity.lastProgress) > Self.stallLimit
            }
            due.formUnion(waiting.keys.sorted().prefix(Self.connectionsPerHost))
        }
        guard !due.isEmpty else { return }
        isCheckingStalls = true
        Task { [weak self, session] in
            let tasks = await session.allTasks
            guard let self else { return }
            self.isCheckingStalls = false
            self.replace(stalled: due, listed: Dictionary(tasks.map { ($0.taskIdentifier, $0) }) { first, _ in first }, now: .now)
        }
    }

    /// A transfer the session no longer lists whose report hasn't come in this long is given
    /// up on, and its range planned again.
    static let unreportedLimit: TimeInterval = 5 * 60

    /// Replaces the transfers that looked stalled, but for those the session says otherwise of:
    /// one it no longer lists, or lists as completed, is done in the daemon, its report still to
    /// come (the system can hold reports back for a minute or more while the app is in the
    /// background). A replaced transfer carries on from the bytes it has, by its resume data,
    /// but for one resumed that never got going: the daemon can carry its wait over into the
    /// resume data, so its range is planned again. A paused download's transfer left to finish
    /// is set aside instead. Whether it was cut partway, which shrinks its job's chunks, its
    /// report tells (`handle`).
    private func replace(stalled identifiers: Set<Int>, listed: [Int: URLSessionTask], now: Date) {
        for identifier in identifiers {
            guard let transfer = running[identifier] else { continue }
            let state = listed[identifier]?.state
            switch TransferActivity.verdict(listed: state, unlistedSince: unlistedSince[identifier], now: now,
                                            reportLimit: Self.unreportedLimit) {
            case .replace:
                break
            case .leave:
                continue
            case .awaitReport:
                if unlistedSince[identifier] == nil { unlistedSince[identifier] = now }
                Self.log.info("Task \(identifier) [\(transfer.tag.encoded)] is done in the daemon; waiting for its report")
                continue
            case .forget:
                Self.log.notice("Task \(identifier) [\(transfer.tag.encoded)] never reported; planning its range again")
                unlistedSince[identifier] = nil
                running[identifier] = nil
                pump()
                continue
            }
            Self.log.notice("Task \(identifier) [\(transfer.tag.encoded)]: no bytes for \(Int(now.timeIntervalSince(transfer.activity.lastProgress)))s, replacing it")
            guard let index = index(of: transfer.tag.jobId), jobs[index].status == .active else {
                setAside([identifier: transfer])
                continue
            }
            cancelledAsStalled[identifier] = (transfer.received, transfer.attemptStart)
            cancelledByUs.insert(identifier)
            if !transfer.activity.carriesOnWhenReplaced {
                // Resuming didn't get it going: the range goes back to be planned again in
                // today's chunk size.
                transfer.task.cancel()
                running[identifier] = nil
                pump()
                continue
            }
            // The transfer keeps its range until the replacement starts, so nothing else claims it.
            running[identifier]?.activity.restartClock(now: now)
            transfer.task.cancel(byProducingResumeData: { [weak self] resumeData in
                Task { @MainActor in self?.replace(identifier, resumeData: resumeData) }
            })
        }
    }

    /// Carries a stalled transfer on from the bytes it has, as a range set aside that `pump`
    /// starts again at once while its file is in the session; without resume data, its range
    /// goes back to be planned again in today's chunk size.
    private func replace(_ identifier: Int, resumeData: Data?) {
        guard let transfer = running.removeValue(forKey: identifier) else { return }
        if let resumeData, let job = jobs.first(where: { $0.id == transfer.tag.jobId }), job.status == .active {
            let point = ResumePoint(data: resumeData, bytes: transfer.bytes)
            if transfer.tag.isWholeFile {
                keepResumeData(point, of: job.id)
            } else if !job.isDelivered(transfer.tag) {
                keepHeld(point, for: transfer.tag)
            }
        }
        pump()
    }

    private func networkChanged(_ conditions: NetworkConditions) {
        guard conditions != network else { return }
        network = conditions
        Self.log.info("""
            Network: \(conditions.isReachable ? "reachable" : "unreachable", privacy: .public)\
            \(conditions.usesCellular ? ", cellular" : "", privacy: .public)\(conditions.isExpensive ? ", expensive" : "", privacy: .public)\
            \(conditions.isConstrained ? ", Low Data Mode" : "", privacy: .public)
            """)
        pump()
        if conditions.isReachable { fetchExtrasSoon() }
    }

    // MARK: Finished transfers

    private func handle(_ finished: TransferDelegate.Finished) async {
        guard handledTasks.insert(finished.taskIdentifier).inserted else {
            Self.log.notice("Task \(finished.taskIdentifier) [\(finished.tag?.encoded ?? "untagged")] reported again; dropping the second report")
            discard(finished.stagedFile)
            return
        }
        let transfer = running.removeValue(forKey: finished.taskIdentifier)
        let cancelled = cancelledByUs.remove(finished.taskIdentifier) != nil
        let isDiscarded = discarded.remove(finished.taskIdentifier) != nil
        unlistedSince[finished.taskIdentifier] = nil
        if let stalled = cancelledAsStalled.removeValue(forKey: finished.taskIdentifier), finished.error != nil,
           let tag = transfer?.tag ?? finished.tag, let index = index(of: tag.jobId), jobs[index].status == .active {
            // Cut partway after it stalled: the link can't carry a chunk this big between drops.
            let chunkSize = jobs[index].chunkSize
            jobs[index].recordCut(receivedBytes: stalled.received, attemptStart: stalled.attemptStart)
            if jobs[index].chunkSize != chunkSize {
                Self.log.notice("Task \(finished.taskIdentifier) [\(tag.encoded)] was cut after it stalled; chunks now \(self.jobs[index].chunkSize)")
                save()
            }
        }
        // A transfer cancelled after it had finished delivers its body all the same: kept, but
        // for a job started over since.
        guard !isDiscarded, !(cancelled && finished.error != nil), let tag = transfer?.tag ?? finished.tag,
              let index = index(of: tag.jobId), jobs[index].status != .completed
        else {
            discard(finished.stagedFile)
            return
        }
        let received = transfer?.received ?? 0
        Self.log.info("""
            Task \(finished.taskIdentifier) [\(tag.encoded)] finished\(cancelled ? " though cancelled" : ""): \
            HTTP \(finished.response?.statusCode ?? 0), Content-Range \(finished.response?.contentRange ?? "none"), \
            \(finished.stagedSize ?? -1) bytes, error \(finished.error.map { String(describing: $0) } ?? "none")
            """)

        if let error = finished.error {
            discard(finished.stagedFile)
            // A transfer from before a relaunch that the session didn't list counts no bytes until
            // it carries on and reports.
            let resumePoint = finished.resumeData.map { ResumePoint(data: $0, bytes: transfer?.bytes ?? 0) }
            if tag.isWholeFile, let resumePoint { keepResumeData(resumePoint, of: tag.jobId) }
            guard jobs[index].status == .active else { return }
            if let reason = (error as? URLError)?.backgroundTaskCancelledReason, systemCancellation != reason {
                Self.log.notice("The system cancelled transfers: \(String(describing: reason), privacy: .public)")
                systemCancellation = reason
            }
            if StorageBudget.isOutOfSpace(error) {
                ranOutOfSpace(error, writing: tag.range, of: tag.jobId)
                save()
            } else if (error as? URLError)?.code != .cancelled {
                // Stopped by the system, e.g. when the app was force quit, says nothing about the
                // connection: no backoff, and the range is asked for again right away.
                jobs[index].recordFailure(.network(Self.describe(error)), receivedBytes: received,
                                          attemptStart: transfer?.attemptStart ?? .now, unreachable: Self.isUnreachable(error),
                                          otherArrival: otherArrival(than: tag.jobId))
                save()
                if tag.segment != nil, (error as? URLError)?.code == .cannotConnectToHost { transcodes.serverDown(tag.jobId) }
            }
            // A range that can resume carries on from its bytes, as one set aside, instead of
            // being planned again, unless it has been already: after a relaunch, the wait for
            // reports is bounded.
            if !tag.isWholeFile, let resumePoint, !jobs[index].isDelivered(tag), !isClaimed(tag) {
                keepHeld(resumePoint, for: tag)
            }
            return
        }

        if let segment = tag.segment {
            await acceptSegment(finished, segment: segment, of: jobs[index], received: received, attemptStart: transfer?.attemptStart)
            return
        }
        if tag.range != nil, jobs[index].isDelivered(tag) {
            // Another transfer brought it first: one that looked stalled, finishing after its
            // replacement started, or the replacement.
            Self.log.info("Task \(finished.taskIdentifier) [\(tag.encoded)] brought bytes already here")
            discard(finished.stagedFile)
            return
        }

        let outcome = jobs[index].evaluate(finished.response, stagedSize: finished.stagedSize, tag: tag)
        if case .chunk = outcome {} else { Self.log.notice("Task \(finished.taskIdentifier) [\(tag.encoded)]: \(String(describing: outcome))") }
        switch outcome {
        case .chunk(let range, let total):
            guard let file = finished.stagedFile else { return }
            await acceptChunk(file, range: range, total: total, jobId: tag.jobId, response: finished.response)

        case .wholeFile(let size):
            guard let file = finished.stagedFile else { return }
            do {
                try storage.adoptWholeFile(file, for: tag.jobId)
            } catch {
                discard(file)
                stop(index, because: "Couldn't save the download: \(error.localizedDescription)")
                return
            }
            jobs[index].rangeSupport = .unsupported
            jobs[index].totalBytes = size
            jobs[index].completed = ByteRanges([0..<size])
            noteFileExtension(from: finished.response, at: index)
            jobs[index].recordSuccess()
            publish(index)
            save()

        case .switchToWholeFile:
            discard(finished.stagedFile)
            jobs[index].rangeSupport = .unsupported
            save()

        case .retry(let failure):
            discard(finished.stagedFile)
            guard jobs[index].status == .active else { return }
            jobs[index].recordFailure(failure, receivedBytes: max(received, finished.stagedSize ?? 0),
                                      attemptStart: transfer?.attemptStart ?? .now, otherArrival: otherArrival(than: tag.jobId))
            if jobs[index].status == .failed { cancelTransfers(of: tag.jobId) }
            save()

        case .giveUp(let message):
            discard(finished.stagedFile)
            stop(index, because: message)
        }
    }

    private func acceptChunk(_ file: URL, range: Range<Int64>, total: Int64, jobId: UUID, response: ResponseInfo?) async {
        // A file that came whole for a range takes the place of its ranges.
        guard let index = index(of: jobId), jobs[index].rangeSupport != .unsupported else { return discard(file) }
        if jobs[index].rangeSupport == .unknown {
            jobs[index].rangeSupport = .supported
            jobs[index].totalBytes = total
            noteFileExtension(from: response, at: index)
            // Ranges planned from a listed size that was too big ask for bytes past the end.
            cancelTransfers(of: jobId) { $0.lowerBound >= total }
            // The size the server gives is what room is kept for from now on.
            isSpaceCheckDue = true
        }

        // Claimed and counted while it's written, which other work can interleave with.
        let tag = TransferTag(jobId: jobId, range: range)
        writing[tag] = range.count64
        do {
            try await storage.writeChunk(file, into: jobId, at: range.lowerBound)
            writing[tag] = nil
        } catch {
            // No longer claimed, so what it wrote goes.
            writing[tag] = nil
            discard(file)
            releaseUnrecorded(of: jobId)
            if StorageBudget.isOutOfSpace(error) {
                ranOutOfSpace(error, writing: range, of: jobId)
            } else if let index = self.index(of: jobId) {
                stop(index, because: "Couldn't write the download to storage: \(error.localizedDescription)")
            }
            return
        }

        // The job may have been removed or restarted while the chunk was being written.
        guard let index = self.index(of: jobId), jobs[index].totalBytes == total else {
            if self.index(of: jobId) == nil { removePartial(of: jobId) }
            return
        }
        jobs[index].completed.insert(range)
        cancelTransfers(of: jobId) { jobs[index].completed.covers($0) }
        if jobs[index].status == .active { jobs[index].recordSuccess(wholeChunkBytes: range.upperBound < total ? range.count64 : 0) }
        if jobs[index].isTransferComplete, jobs[index].status == .active { publish(index) }
        save()
    }

    /// A piece of a transcode came back: `TranscodedDownloads` takes it, and the job counts it
    /// as it counts a chunk.
    private func acceptSegment(_ finished: TransferDelegate.Finished, segment: Int, of job: DownloadJob, received: Int64,
                               attemptStart: Date?) async {
        let outcome = await transcodes.accept(finished, segment: segment, of: job)
        guard let index = index(of: job.id) else { return }
        switch outcome {
        case .collected:
            if jobs[index].status == .active { jobs[index].recordSuccess() }
            save()
        case .retry(let failure):
            Self.log.notice("[\(job.id.uuidString.prefix(8)) s\(segment)] \(String(describing: failure), privacy: .public)")
            guard jobs[index].status == .active else { return }
            jobs[index].recordFailure(failure, receivedBytes: max(received, finished.stagedSize ?? 0), attemptStart: attemptStart ?? .now,
                                      otherArrival: otherArrival(than: job.id))
            if jobs[index].status == .failed { cancelTransfers(of: job.id) }
            save()
        case .giveUp(let message):
            stop(index, because: message)
        case .dropped, .noRoom:
            break
        }
    }

    /// Moves the finished file into Documents, and tells the user it's ready.
    private func publish(_ index: Int) {
        // Ranges another transfer already delivered can still be in flight.
        cancelTransfers(of: jobs[index].id)
        do {
            jobs[index].savedPath = try storage.publish(jobs[index])
            transcodes.leave(jobs[index])
            // Publishing deleted it on disk.
            wholeFileResumeData[jobs[index].id] = nil
            jobs[index].status = .completed
            jobs[index].completedAt = .now
            jobs[index].lastError = nil
            jobs[index].retryAt = nil
            // Its subtitles go beside it now.
            extrasDone.remove(jobs[index].id)
            fetchExtrasSoon()
            notifications.ready(jobs[index])
        } catch {
            jobs[index].status = .failed
            jobs[index].lastError = "Couldn't move the finished file into place: \(error.localizedDescription)"
        }
    }

    /// The device ran out of room for a transfer, or for a chunk being written into place, though
    /// the budget found some: from now on only room that's free counts, and the next check holds
    /// the queue to that, so downloads wait for room and carry on once there is, rather than fail.
    /// The job's chunks halve from the `range` that didn't fit.
    private func ranOutOfSpace(_ error: any Error, writing range: Range<Int64>?, of jobId: UUID) {
        Self.log.notice("Out of room on the device: \(String(describing: error), privacy: .public)")
        countsPurgeableSpace = false
        isSpaceCheckDue = true
        if let range, let index = index(of: jobId) { jobs[index].ranOutOfSpace(writing: range.count64) }
    }

    /// Gives back the room the job's partial file takes outside the ranges recorded as done or
    /// being written, as a chunk whose writing failed, or was cut off by a kill, leaves behind.
    /// On a full device that can fail for want of room itself; the next room check tries again.
    private func releaseUnrecorded(of jobId: UUID) {
        guard let job = jobs.first(where: { $0.id == jobId }), job.rangeSupport == .supported else {
            unreleased.remove(jobId)
            return
        }
        var kept = job.completed
        for tag in writing.keys where tag.jobId == jobId {
            if let range = tag.range { kept.insert(range) }
        }
        do {
            try storage.releaseUnrecorded(in: jobId, keeping: kept)
            unreleased.remove(jobId)
        } catch {
            unreleased.insert(jobId)
            Self.log.error("Couldn't give back the room of \(job.shortName, privacy: .public)'s unwritten ranges: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// When a transfer of a file other than this one last came through.
    private func otherArrival(than jobId: UUID) -> Date? {
        jobs.filter { $0.id != jobId }.compactMap(\.cameThroughAt).max()
    }

    private func stop(_ index: Int, because message: String) {
        Self.log.error("Stopping \(self.jobs[index].title): \(message)")
        cancelTransfers(of: jobs[index].id)
        jobs[index].status = .failed
        jobs[index].lastError = message
        jobs[index].retryAt = nil
        save()
    }

    private func noteFileExtension(from response: ResponseInfo?, at index: Int) {
        guard jobs[index].fileExtension == nil, let response else { return }
        jobs[index].fileExtension = response.videoExtension
    }

    // MARK: Extras

    /// After this many failures in a row, a download's extras wait for the next launch, and the
    /// last failure shows as `problem`.
    static let extrasAttempts = 3

    /// Starts a pass over the downloads' extras, or another after the one under way.
    private func fetchExtrasSoon() {
        extrasPassWanted = true
        guard extrasPass == nil else { return }
        isFetchingExtras = true
        extrasPass = Task { [weak self] in
            while let self, self.extrasPassWanted {
                self.extrasPassWanted = false
                self.extrasDone = []
                await self.fetchExtras()
            }
            self?.extrasPass = nil
            self?.isFetchingExtras = false
        }
    }

    /// Fetches what downloads that are under way or finished lack, oldest first, one request at
    /// a time, while the server can be reached and nothing plays. A connection that fails ends
    /// the pass, until the network or the next launch starts another; other failures hold that
    /// download back for a while (`extrasFailures`).
    private func fetchExtras() async {
        while hasAdoptedTransfers, isNetworkReachable, !isPausedForPlayback, !Task.isCancelled,
              let client = accounts.client, let userId = accounts.account?.userId
        {
            guard let next = nextExtrasStep(now: .now) else {
                // Downloads held back by a failure go again once their wait is over.
                let waits = extrasFailures.values.map(\.retryAt).filter { $0 != .distantFuture }
                if let soonest = waits.min() { retryExtras(after: max(1, soonest.timeIntervalSinceNow)) }
                return
            }
            let (job, step) = next
            do {
                try await fetch(step, for: job, client: client, userId: userId)
                extrasFailures[job.id] = nil
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                if let code = (error as? URLError)?.code, Self.connectionFailures.contains(code) {
                    Self.log.notice("Extras wait for the connection: \(error.localizedDescription, privacy: .public)")
                    retryExtras(after: 60)
                    return
                }
                extrasFailed(job, step, error)
            }
        }
    }

    private static let connectionFailures: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
    ]

    /// The oldest download with something to fetch, and what. Records the size of those found
    /// with everything.
    private func nextExtrasStep(now: Date) -> (DownloadJob, DownloadExtras.Step)? {
        let exists = { (file: URL) in FileManager.default.fileExists(atPath: file.path) }
        let rules = rules
        for job in jobs.sorted(by: { $0.createdAt < $1.createdAt })
        where (job.status == .active || job.status == .completed) && !extrasDone.contains(job.id)
            && (extrasFailures[job.id]?.retryAt ?? .distantPast) <= now
            // A download's extras keep to its network and charging rules.
            && rules.wait(for: job, network: network, isOnPower: isOnPower) == nil
        {
            if let step = DownloadExtras.nextStep(for: job, storage: storage, exists: exists, now: now) { return (job, step) }
            extrasDone.insert(job.id)
            let size = storage.size(of: DownloadExtras.files(for: job, storage: storage).filter(\.isOwn).map(\.local))
            if job.extrasBytes != size, let index = index(of: job.id) {
                jobs[index].extrasBytes = size
                // They count against the storage limit.
                isSpaceCheckDue = true
                save()
            }
        }
        return nil
    }

    private func fetch(_ step: DownloadExtras.Step, for job: DownloadJob, client: JellyfinClient, userId: String) async throws {
        switch step {
        case .lookUp:
            let version = job.versionItemId
            let detail: JellyfinItem
            do {
                detail = try await client.item(id: job.itemId, userId: userId)
            } catch JellyfinError.http(let status, _) where status == 404 {
                // Gone from the server: what was saved with the download is all there is.
                Self.log.notice("\(job.title, privacy: .public) is gone from the server; keeping the details it was saved with")
                update(job.id) { saved in
                    saved.segments = saved.segments ?? []
                    saved.extrasItemId = version
                    saved.extrasCheckedAt = .now
                }
                return
            }
            var chapters = detail.chapters
            if version != detail.id {
                do {
                    chapters = try await client.item(id: version, userId: userId).chapters
                } catch JellyfinError.http(let status, _) where status == 404 {
                    // A version that isn't an item of its own has no chapters.
                    chapters = nil
                }
            }
            let segments: [MediaSegment]
            do {
                segments = try await client.mediaSegments(itemId: version)
            } catch JellyfinError.http(let status, _) where status == 404 {
                // A server from before media segments, or a version without any.
                segments = []
            }
            let source = detail.mediaSources?.first { $0.id == job.mediaSourceId } ?? job.item?.mediaSources?.first
            update(job.id) { saved in
                if let source { saved.item = DownloadJob.snapshot(of: detail, keeping: source) }
                saved.item?.chapters = chapters
                saved.segments = segments
                saved.extrasItemId = version
                saved.extrasCheckedAt = .now
            }
        case .file(let file):
            var request = URLRequest(url: file.url(using: client))
            rules.access(for: job).apply(to: &request)
            let (downloaded, response) = try await probeSession.download(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                discard(downloaded)
                // Its details may be out of date: the server can make previews or chapter pictures again.
                if status == 404 { update(job.id) { $0.extrasCheckedAt = .distantPast } }
                throw JellyfinError.http(status: status, body: "")
            }
            // Removed meanwhile: its extras would be left behind.
            guard index(of: job.id) != nil else { return discard(downloaded) }
            try storage.saveExtra(downloaded, to: file.local)
            if case .artwork = file.remote { artworkRevision += 1 }
        }
    }

    /// Changes a job that may have been removed while its extras were being fetched.
    private func update(_ jobId: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = index(of: jobId) else { return }
        change(&jobs[index])
        save()
    }

    private func extrasFailed(_ job: DownloadJob, _ step: DownloadExtras.Step, _ error: any Error) {
        let count = (extrasFailures[job.id]?.count ?? 0) + 1
        Self.log.error("Extras of \(job.title, privacy: .public) failed (\(count)): \(String(describing: error), privacy: .public)")
        guard count < Self.extrasAttempts else {
            extrasFailures[job.id] = (count, .distantFuture)
            let what = switch step {
            case .lookUp: "details and intro and credits markers"
            case .file(let file): file.description
            }
            problem = "Couldn't save the \(what) for \(job.title): \(error.localizedDescription) It plays without them until vinnyfin tries again, the next time it opens."
            return
        }
        extrasFailures[job.id] = (count, .now.addingTimeInterval(30 * DownloadJob.backoff(attempt: count, cap: 8)))
    }

    /// Another pass once `seconds` have passed, while the app runs, in place of one waiting.
    private func retryExtras(after seconds: TimeInterval) {
        extrasRetry?.cancel()
        extrasRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.fetchExtrasSoon()
        }
    }

    /// Deletes a job's previews and chapter pictures, and with `besideFile` its subtitles.
    private func removeExtras(of job: DownloadJob, besideFile: Bool) {
        extrasFailures[job.id] = nil
        let subtitles = besideFile
            ? DownloadExtras.files(for: job, storage: storage).compactMap { file -> URL? in
                if case .subtitle = file.remote { return file.local }
                return nil
            }
            : []
        do {
            try storage.removeExtras(for: job.id, besideFile: subtitles)
        } catch {
            problem = "Couldn't delete the subtitles and previews of \(job.title): \(error.localizedDescription)"
        }
    }

    // MARK: Files

    private func save() {
        do {
            try storage.saveJobs(jobs)
        } catch {
            problem = "Couldn't save the download list: \(error.localizedDescription)"
        }
    }

    /// Keeps what the session has been handed on disk, for a relaunch to wait for their reports.
    private func saveHandedOut() {
        guard hasAdoptedTransfers else { return }
        let handedOut = Set(running.values.map(\.tag)).union(awaitingReports)
        guard handedOut != savedHandedOut else { return }
        do {
            try storage.saveHandedOut(handedOut)
            savedHandedOut = handedOut
        } catch {
            problem = "Couldn't save the list of transfers under way: \(error.localizedDescription)"
        }
    }

    private func discard(_ file: URL?) {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            problem = "Couldn't clean up a temporary file: \(error.localizedDescription)"
        }
    }

    /// Deletes the job's partial file and its whole-file resume data, and a transcode's pieces.
    private func removePartial(of jobId: UUID) {
        wholeFileResumeData[jobId] = nil
        do {
            try storage.removePartial(for: jobId)
            try storage.removeTranscodeFiles(for: jobId)
        } catch {
            problem = "Couldn't delete a partial download: \(error.localizedDescription)"
        }
    }

    /// Keeps a whole-file transfer's resume point for an unfinished job; a finished or forgotten
    /// one has no use for it.
    private func keepResumeData(_ point: ResumePoint, of jobId: UUID) {
        guard jobs.contains(where: { $0.id == jobId && $0.status != .completed }) else { return }
        wholeFileResumeData[jobId] = point
        do {
            try storage.saveResumePoint(point, for: jobId)
        } catch {
            problem = "Couldn't keep a download's resume data: \(error.localizedDescription)"
        }
    }

    /// Resume data is used once: a resumed transfer that fails again leaves new resume data.
    private func takeResumeData(of jobId: UUID) -> ResumePoint? {
        guard let point = wholeFileResumeData.removeValue(forKey: jobId) else { return nil }
        discard(storage.resumeDataFile(for: jobId))
        return point
    }

    // MARK: Progress

    /// The bytes each unfinished download has on disk so far: in its partial file, in staging on
    /// their way there, and in the session's files for its transfers, running, awaiting their
    /// resume data or set aside with it.
    private func bytesSoFar() -> [UUID: Int64] {
        var held: [(jobId: UUID, bytes: Int64)] = running.values.map { ($0.tag.jobId, $0.bytes) }
        held += writing.map { ($0.key.jobId, $0.value) }
        held += awaitingResumeData.map { ($0.key.jobId, $0.value) }
        held += heldResumeData.map { ($0.key.jobId, $0.value.bytes) }
        held += wholeFileResumeData.map { ($0.key, $0.value.bytes) }
        return DownloadJob.bytesSoFar(jobs, held: held)
    }

    private func refreshLiveProgress() {
        let bytes = bytesSoFar()
        let now = Date.now
        if let lastSample, now.timeIntervalSince(lastSample.date) > 5 {
            // The app was suspended: transfers carried on without reporting, so that time
            // says nothing about stalls.
            for identifier in running.keys { running[identifier]?.activity.restartClock(now: now) }
            lastActivity = now
        }
        var speeds: [UUID: Double] = [:]
        var grown: Set<UUID> = []
        if let lastSample, now > lastSample.date {
            let interval = now.timeIntervalSince(lastSample.date)
            for (id, value) in bytes {
                let instant = max(0, Double(value - (lastSample.bytes[id] ?? value)) / interval)
                speeds[id] = (bytesPerSecond[id] ?? instant) * 0.7 + instant * 0.3
                if instant > 0 { grown.insert(id) }
            }
        }
        // A retry coming due can change which files the session holds (`DownloadJob.sessionFiles`).
        let retryCameDue = lastSample.map { last in
            jobs.contains { $0.status == .active && ($0.retryAt.map { $0 > last.date && $0 <= now } ?? false) }
        } ?? false
        lastSample = (now, bytes)
        if retryCameDue { pump() }
        if receivedBytes != bytes { receivedBytes = bytes }
        if bytesPerSecond != speeds { bytesPerSecond = speeds }
        let transferring = Self.transferring(underWay: Set(running.values.filter(\.isUnderWay).map(\.tag.jobId)), grown: grown,
                                             arrivals: &arrivedAt, now: now)
        if transferringJobIds != transferring { transferringJobIds = transferring }
        if now.timeIntervalSince(lastStallCheck) > 10 {
            lastStallCheck = now
            replaceStalledTransfers(now: now)
            // Room can come from elsewhere on the device.
            if waits.values.contains(where: { if case .space = $0 { true } else { false } }) { pump() }
        }
    }

    /// The downloads with transfers under way, or whose bytes grew within `arrivalLinger`:
    /// transfers too short to be seen under way, as a transcode's pieces are, still show as
    /// bytes arriving. Takes in the downloads whose bytes have `grown` since the last sample.
    nonisolated static func transferring(underWay: Set<UUID>, grown: Set<UUID>, arrivals: inout [UUID: Date], now: Date) -> Set<UUID> {
        for id in grown { arrivals[id] = now }
        arrivals = arrivals.filter { now.timeIntervalSince($0.value) < arrivalLinger }
        return underWay.union(arrivals.keys)
    }

    // MARK: Helpers

    private func index(of id: UUID) -> Int? {
        jobs.firstIndex { $0.id == id }
    }

    private static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "No internet connection."
            case .timedOut: return "The connection stalled."
            case .networkConnectionLost: return "The connection dropped."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "Couldn't reach the server."
            case .cancelled: return "The system stopped the transfer."
            default: break
            }
        }
        return error.localizedDescription
    }

    /// The server couldn't be reached at all, rather than the device being offline or a
    /// connection to it dropping.
    private static func isUnreachable(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(code)
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

extension DownloadManager: TranscodeHost {
    var isPlaybackTranscoding: Bool {
        players.contains { $0.value && transcodingPlayers.contains($0.key) }
    }

    func changeJob(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        update(id, change)
    }

    func transcodesChanged() {
        pump()
    }

    func startOver(_ id: UUID, because reason: String) {
        guard let index = index(of: id) else { return }
        Self.log.notice("Starting \(self.jobs[index].title, privacy: .public) over: \(reason, privacy: .public)")
        cancelTransfers(of: id, discarding: true)
        removePartial(of: id)
        jobs[index].resetProgress()
        jobs[index].transcode?.startOvers += 1
        jobs[index].lastError = "\(reason) It started over."
        isSpaceCheckDue = true
        save()
        pump()
    }

    func stopJob(_ id: UUID, because message: String) {
        guard let index = index(of: id), jobs[index].status != .completed else { return }
        stop(index, because: message)
    }

    /// The next plan holds the queue to the room that's free.
    func outOfSpace(_ id: UUID, error: any Error) {
        ranOutOfSpace(error, writing: nil, of: id)
    }
}

#if !os(macOS)
/// Time the system grants the app to finish something it started, in front or in the
/// background, until `end()` or until the system takes it back.
@MainActor
final class BackgroundTime {
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "downloads")
    private let name: String
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(named name: String) {
        self.name = name
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            guard let self else { return }
            Self.log.notice("Background time ran out for \(self.name, privacy: .public)")
            self.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
#endif
