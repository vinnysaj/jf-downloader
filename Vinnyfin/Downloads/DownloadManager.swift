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
/// Files download one at a time, oldest first, and none while something plays. Each file is
/// asked for one byte first, for its size and whether ranges work, until one has shown that the
/// server takes ranges; after that, chunks are planned from the size Jellyfin lists. While the app
/// is in front of the user, the session holds the first file's chunks only, while the files
/// after it are probed in turn (`DownloadJob.plan`), through an ordinary session so the probes
/// don't wait behind those chunks for a connection. The session runs `connectionsPerHost`
/// transfers at a time in no promised order (nor by task priority), so that's what keeps the
/// server on one file. As the app resigns active, while it's still in the foreground to the
/// system, every file's chunks go in, up to `maxQueuedTransfers`: the session then works through
/// the queue by itself with the app suspended or terminated, which it wouldn't promptly otherwise.
/// Transfers created while the app is in the background start only when the system sees fit,
/// after a delay that grows with every time the system wakes the app, in a connection pool of
/// their own; it wakes the app only once every transfer is done. Entering the foreground again,
/// the chunks of later files that haven't started come out. Launched in the background, the app
/// queues ahead the same way. A file the server keeps refusing lets the files behind it go
/// ahead while it waits out its retry.
///
/// Whenever the process runs, in front or kept running in the background (`BackgroundDownloads`),
/// finished chunks go into place as they arrive, files are published, and `trackProgress`
/// replaces stalled transfers. Swiping the app away in the app switcher makes the system cancel
/// every transfer and leave the app closed until it's opened again; the reason comes with the
/// cancellations then, and is kept in `systemCancellation` to tell the user. Which downloads
/// someone started, rather than smart downloads by themselves, is in `userStartedJobIds`.
///
/// Every transfer's purpose is in its `taskDescription` (`TransferTag`), so the queue rebuilds
/// itself from the session after a relaunch. What was handed to the session is kept on disk as
/// well: transfers that ended while the app was dead report only after the relaunch, and their
/// ranges aren't planned again until they have, or `relaunchReportWait` has passed. So is the
/// resume data of ranges held for a playback, so a kill during one loses none of it.
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
    /// Visible in Console.app (subsystem net.vinnysaj.vinnyfin) for following a download.
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "downloads")

    private(set) var jobs: [DownloadJob] = []
    /// Bytes on disk plus bytes running transfers have received, by job. Refreshed by `trackProgress()`.
    private(set) var receivedBytes: [UUID: Int64] = [:]
    private(set) var bytesPerSecond: [UUID: Double] = [:]
    private(set) var isNetworkReachable = true
    /// The job the session works on now; the other active jobs are queued behind it.
    private(set) var downloadingJobId: UUID?
    /// Something is playing, or a player is open in front of the user, so transfers wait.
    private(set) var isPausedForPlayback = false
    /// The app is in front of the user and active.
    private(set) var isInFront = false
    /// Jobs someone started (downloaded, resumed, retried or started over, or queued by a smart
    /// download they set up), as opposed to smart downloads topping a show up by themselves.
    /// Only those keep the app running in the background on iPhone and iPad. Kept until
    /// `forgetUserStartedJobs()`.
    private(set) var userStartedJobIds: Set<UUID> = []
    /// Why the system last cancelled transfers by itself, to tell the user until dismissed.
    var systemCancellation: URLError.BackgroundTaskCancelledReason?
    /// Moves when saved artwork changes, so views showing it look again.
    private(set) var artworkRevision = 0
    /// A local problem (storage, the saved queue) to show until dismissed.
    var problem: String?

    private struct RunningTransfer {
        let tag: TransferTag
        let task: URLSessionDownloadTask
        var received: Int64
        /// The bytes its last progress event reported. Nil for a transfer adopted after a
        /// relaunch until its first event: what the task says it has received at adoption isn't
        /// on the same count, and can be more than that first event.
        var reported: Int64?
        /// When bytes last arrived, or when the app started or adopted the transfer.
        var lastProgress = Date.now
        /// When the current attempt began: the app started or adopted the transfer, or the
        /// daemon started its range over.
        var attemptStart = Date.now
        /// Started from a stalled transfer's resume data.
        var resumed = false

        /// The daemon has a response for it, or bytes: it's under way rather than waiting its turn.
        var isUnderWay: Bool { task.response != nil || task.countOfBytesReceived > 0 }
    }

    /// After a relaunch, how long transfers that were handed to the session but that it no
    /// longer lists may take to report how they ended, before their ranges are planned again.
    static let relaunchReportWait: Duration = .seconds(30)

    @ObservationIgnored private let accounts: AccountStore
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
    /// Tasks this app cancelled (pause, remove, restart); whatever they deliver is dropped.
    @ObservationIgnored private var cancelledByUs: Set<Int> = []
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
    @ObservationIgnored private var lastStallCheck = Date.now
    /// The open players, by their model's id, and whether each is playing.
    @ObservationIgnored private var players: [UUID: Bool] = [:]
    /// The app is off screen, so the session holds the next files' chunks as well.
    @ObservationIgnored private var isQueuingAhead = false
    /// Resume data of ranges cancelled for a playback, to carry on from afterwards. Kept on disk
    /// too, so a kill during the playback loses none of it.
    @ObservationIgnored private var heldResumeData: [TransferTag: Data] = [:]
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

    init(accounts: AccountStore, storage: DownloadStorage = .standard) {
        self.accounts = accounts
        self.storage = storage
        do {
            try storage.prepare()
            try storage.clearStaging()
        } catch {
            problem = "Couldn't prepare the downloads folder: \(error.localizedDescription)"
        }
        do {
            jobs = try storage.loadJobs()
        } catch {
            problem = Self.setAsideUnreadableJobs(storage, error: error)
        }
        do {
            awaitingReports = Set(try storage.loadHandedOut())
            heldResumeData = try storage.loadHeld()
        } catch {
            problem = "Couldn't read what the last run left with the system: \(error.localizedDescription). Some of it may download again."
        }

        delegate = TransferDelegate(stagingDirectory: storage.staging)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
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

    // MARK: Running

    /// Adopts the transfers the session still has, then handles its events for the life of the app.
    func run() async {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(reachable: reachable) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "net.vinnysaj.vinnyfin.path"))
        followAppState()

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
            running[task.taskIdentifier] = RunningTransfer(tag: tag, task: download, received: task.countOfBytesReceived)
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
        #if !os(macOS)
        // Opened in front, later files' transfers queued ahead before the relaunch come out.
        if isInFront { stopQueuingAhead() }
        #endif
        // Opened to play a file, the player can be up before the session's tasks are adopted.
        // Held ranges left by a run that ended during a playback carry on otherwise.
        if isPausedForPlayback { holdTransfers() } else if !heldResumeData.isEmpty { releaseTransfers() }
        pump()
        fetchExtrasSoon()

        for await event in delegate.events {
            switch event {
            case .progress(let taskIdentifier, let received):
                guard let transfer = running[taskIdentifier] else { continue }
                running[taskIdentifier]?.received = received
                running[taskIdentifier]?.reported = received
                running[taskIdentifier]?.lastProgress = .now
                if let reported = transfer.reported, received < reported { restarted(taskIdentifier, after: reported) }
            case .finished(let finished):
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
    /// has settled (every active download done and the extras pass over, or held for a playback)
    /// or the caller's task is cancelled, for a background task to keep the app running that
    /// long. Meanwhile the session's events and `trackProgress` keep the queue moving.
    func keepMoving() async {
        pump()
        fetchExtrasSoon()
        let settled = Observations { [weak self] in
            guard let self else { return true }
            return self.hasAdoptedTransfers
                && (self.isPausedForPlayback || (DownloadJob.queue(self.jobs).isEmpty && !self.isFetchingExtras))
        }
        for await isSettled in settled where isSettled || Task.isCancelled { return }
    }

    /// Lets the jobs someone started go on without keeping the app running, as after the
    /// person or the system stopped the background task that did.
    func forgetUserStartedJobs() {
        if !userStartedJobIds.isEmpty { userStartedJobIds = [] }
    }

    // MARK: Commands

    /// Queues a version of an item. `startedByUser` is false for downloads smart downloads add
    /// by themselves.
    func enqueue(_ item: JellyfinItem, source: MediaSource, startedByUser: Bool) {
        let known = jobs.contains { $0.itemId == item.id && $0.mediaSourceId == source.id }
        guard !known else { return }
        var job = DownloadJob(item: item, source: source)
        if let size = job.sizeHint, let available = storage.availableCapacity(), available < queuedBytesRemaining + size {
            job.status = .failed
            job.lastError = "Not enough free space: the downloads queued need \(Self.bytes(queuedBytesRemaining + size)), \(Self.bytes(available)) is free."
        }
        jobs.append(job)
        if startedByUser { userStartedJobIds.insert(job.id) }
        save()
        pump()
        fetchExtrasSoon()
    }

    func pause(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status == .active else { return }
        cancelTransfers(of: id)
        jobs[index].status = .paused
        save()
        pump()
    }

    /// Pauses every download under way.
    func pauseAll() {
        for job in jobs where job.status == .active { pause(job.id) }
    }

    /// Continues every paused download, and retries every failed one.
    func resumeAll() {
        for job in jobs where job.status == .paused || job.status == .failed { resume(job.id) }
    }

    /// A player opened, or started or stopped playing.
    func playerChanged(_ player: UUID, isPlaying: Bool) {
        players[player] = isPlaying
        updateHold()
    }

    func playerClosed(_ player: UUID) {
        players[player] = nil
        updateHold()
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
    #endif

    private func appStateChanged(isInFront: Bool) {
        #if !os(macOS)
        settling?.cancel()
        settling = nil
        if isInFront { stopQueuingAhead() } else { isQueuingAhead = true }
        #endif
        if isInFront != self.isInFront {
            self.isInFront = isInFront
            Self.log.info("App \(isInFront ? "in front" : "leaving the front")")
            updateHold()
        }
        pump()
    }

    /// Back to one file in the session: the later files' transfers that haven't started come out,
    /// those queued ahead before a relaunch too. Ones under way finish.
    private func stopQueuingAhead() {
        isQueuingAhead = false
        let first = DownloadJob.queue(jobs).first
        var count = 0
        for (identifier, transfer) in running where transfer.tag.jobId != first && !transfer.isUnderWay {
            cancel(identifier, transfer)
            count += 1
        }
        guard count > 0 else { return }
        saveHandedOut()
        Self.log.info("Took back \(count) transfers queued ahead")
    }

    /// Downloads leave the connection and the server to the picture while something plays, and
    /// while a player is open in front of the user, paused or between episodes, so pausing
    /// doesn't stop and start them. A paused player the app leaves lets them go on: they're let
    /// go as it resigns active, while it's still in the foreground, so the system starts them
    /// right away.
    private func updateHold() {
        let hold = players.values.contains(true) || (!players.isEmpty && isInFront)
        guard hold != isPausedForPlayback else { return }
        isPausedForPlayback = hold
        if hold { holdTransfers() } else { releaseTransfers() }
    }

    /// Cancels every transfer, keeping any resume data, those waiting their turn first: the
    /// daemon fills a connection freed by one under way from the waiting ones. Suspending would
    /// keep them in place, but a suspended transfer loses its connection after a minute or so and
    /// starts its range over, and one suspended when the app dies stays that way until the app
    /// opens again.
    private func holdTransfers() {
        Self.log.info("Holding \(self.running.count) transfers for a playback")
        for (identifier, transfer) in Self.cancellationOrder(running) {
            cancelledByUs.insert(identifier)
            running[identifier] = nil
            transfer.task.cancel(byProducingResumeData: { [weak self] data in
                guard let data else { return }
                Task { @MainActor in self?.hold(data, for: transfer.tag) }
            })
        }
        saveHandedOut()
    }

    /// The transfers in the order to cancel them in: those waiting their turn first, as the
    /// daemon gives a connection freed by one under way to one waiting.
    private static func cancellationOrder(_ transfers: [Int: RunningTransfer]) -> [(key: Int, value: RunningTransfer)] {
        transfers.sorted { !$0.value.isUnderWay && $1.value.isUnderWay }
    }

    private func hold(_ data: Data, for tag: TransferTag) {
        if tag.range == nil {
            keepResumeData(data, of: tag.jobId)
        } else if isPausedForPlayback {
            heldResumeData[tag] = data
            do {
                try storage.saveHeld(data, for: tag)
            } catch {
                problem = "Couldn't keep a held download's progress: \(error.localizedDescription)"
            }
        }
    }

    /// Carries on from the held ranges' bytes, oldest file first, then plans the rest.
    private func releaseTransfers() {
        Self.log.info("Carrying on with \(self.heldResumeData.count) held transfers after a playback")
        let held = heldResumeData
        heldResumeData = [:]
        do {
            try storage.removeHeld { _ in true }
        } catch {
            problem = "Couldn't clear a held download's progress: \(error.localizedDescription)"
        }
        if let client = accounts.client {
            let order = { (tag: TransferTag) in (self.index(of: tag.jobId) ?? .max, tag.range?.lowerBound ?? 0) }
            for (tag, data) in held.sorted(by: { order($0.key) < order($1.key) }) {
                guard let range = tag.range, let job = jobs.first(where: { $0.id == tag.jobId }), job.status == .active,
                      !job.completed.covers(range), !isClaimed(tag)
                else { continue }
                start(tag, for: job, client: client, resumeData: data)
            }
        }
        pump()
        fetchExtrasSoon()
    }

    /// Whether a transfer handed to the session, or one that may still report from before a
    /// relaunch, covers some of the tag's range.
    private func isClaimed(_ tag: TransferTag) -> Bool {
        let overlaps = { (other: TransferTag) in
            guard other.jobId == tag.jobId else { return false }
            guard let range = tag.range, let otherRange = other.range else { return true }
            return range.overlaps(otherRange)
        }
        return running.values.contains { overlaps($0.tag) } || awaitingReports.contains(where: overlaps)
    }

    /// Continues a paused job, or retries a failed one from where it got to.
    func resume(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status == .paused || jobs[index].status == .failed else { return }
        jobs[index].status = .active
        jobs[index].networkFailures = 0
        jobs[index].serverFailures = 0
        jobs[index].retryAt = nil
        userStartedJobIds.insert(id)
        save()
        pump()
    }

    /// Starts over from the first byte, for a source that changed on the server.
    func restart(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status != .completed else { return }
        cancelTransfers(of: id)
        removePartial(of: id)
        jobs[index].resetProgress()
        userStartedJobIds.insert(id)
        save()
        pump()
    }

    /// Stops and forgets a job, with its extras, and the item's artwork once no other job of it
    /// is left. `deletingFile` deletes the finished file and the subtitles beside it too.
    func remove(_ id: UUID, deletingFile: Bool = false) {
        guard let index = index(of: id) else { return }
        let job = jobs[index]
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
        if !jobs.contains(where: { $0.itemId == job.itemId }) {
            do {
                try storage.removeArtwork(for: job.itemId)
                artworkRevision += 1
            } catch {
                problem = "Couldn't delete saved artwork: \(error.localizedDescription)"
            }
        }
        save()
        pump()
    }

    /// Stops and forgets every unfinished job, for signing out. Finished files stay.
    func removeUnfinished() {
        for job in jobs where job.status != .completed {
            cancelTransfers(of: job.id)
            removePartial(of: job.id)
            removeExtras(of: job, besideFile: false)
        }
        jobs.removeAll { $0.status != .completed }
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
                return PlaybackResolver.DownloadedCopy(url: url, item: job.item, segments: job.segments ?? [],
                                                       subtitleFiles: saved.subtitles, trickplaySheets: saved.trickplaySheets,
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
        for job in jobs where job.itemId == itemId { remove(job.id, deletingFile: true) }
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

    /// Bytes the active downloads still have to fetch, as far as their sizes are known.
    private var queuedBytesRemaining: Int64 {
        jobs.filter { $0.status == .active }.reduce(0) { total, job in
            total + max(0, (job.displayTotalBytes ?? 0) - job.completed.byteCount)
        }
    }

    /// Bytes the finished downloads take up, extras included.
    var storageUsed: Int64 {
        jobs.filter { $0.status == .completed }.reduce(0) { $0 + $1.storedBytes }
    }

    func availableCapacity() -> Int64? { storage.availableCapacity() }

    /// The free space the downloads already queued don't need, for new ones.
    func spaceForNewDownloads() -> Int64? {
        storage.availableCapacity().map { $0 - queuedBytesRemaining }
    }

    /// Saved artwork for an item, for showing it offline.
    func artworkURL(itemId: String, kind: JellyfinClient.ImageKind) -> URL? {
        _ = artworkRevision
        let file = storage.artworkFile(itemId: itemId, kind: kind)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    var finishedFolder: URL { storage.finished }

    // MARK: Scheduling

    /// Publishes finished files, then hands the session what `DownloadJob.plan` gives.
    private func pump() {
        guard hasAdoptedTransfers else { return }
        defer { saveHandedOut() }
        guard let client = accounts.client else { return }
        var published = false
        for index in jobs.indices where jobs[index].status == .active && jobs[index].isTransferComplete {
            publish(index)
            published = true
        }
        if published { save() }
        let queue = DownloadJob.queue(jobs)
        if downloadingJobId != queue.first { downloadingJobId = queue.first }
        guard !isPausedForPlayback else { return }
        let probing = probes.keys.map { TransferTag(jobId: $0, range: DownloadJob.probeRange) }
        let plan = DownloadJob.plan(jobs, running: running.values.map(\.tag) + awaitingReports + probing,
                                    budget: Self.maxQueuedTransfers - running.count, queuingAhead: isQueuingAhead)
        for tag in plan {
            guard let job = jobs.first(where: { $0.id == tag.jobId }) else { continue }
            if job.rangeSupport == .unknown, tag.range == DownloadJob.probeRange {
                probe(job, client: client)
            } else {
                start(tag, for: job, client: client)
            }
        }
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

    /// The probe's answer as a transfer's report: the byte in staging for a 206, the headers
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
            // One byte more than asked for is enough to tell the server sent too much.
            for try await byte in bytes {
                body.append(byte)
                if body.count > tag.range?.count ?? 1 { break }
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

    /// Starts a transfer, from `resumeData` when there is some: the bytes a cut-off transfer
    /// already received (only servers that send ETag or Last-Modified allow it).
    private func start(_ tag: TransferTag, for job: DownloadJob, client: JellyfinClient, resumeData: Data? = nil) {
        guard !isPausedForPlayback else {
            if let resumeData { hold(resumeData, for: tag) }
            return
        }
        let task: URLSessionDownloadTask
        if let resumeData = resumeData ?? (tag.range == nil ? takeResumeData(of: job.id) : nil) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: client.streamURL(itemId: job.itemId, mediaSourceId: job.mediaSourceId))
            // Byte offsets have to be offsets into the file itself, not into a compressed body.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let header = tag.rangeHeader { request.setValue(header, forHTTPHeaderField: "Range") }
            task = session.downloadTask(with: request)
            if let range = tag.range { task.countOfBytesClientExpectsToReceive = range.upperBound - range.lowerBound }
        }
        task.taskDescription = tag.encoded
        if let retryAt = job.retryAt, retryAt > .now { task.earliestBeginDate = retryAt }
        running[task.taskIdentifier] = RunningTransfer(tag: tag, task: task, received: 0, resumed: resumeData != nil)
        task.resume()
        Self.log.debug("Started task \(task.taskIdentifier) [\(tag.encoded)]\(task.earliestBeginDate.map { " from \($0)" } ?? "")")
    }

    /// Cancels the job's transfers, or only those whose range `matching` accepts, and forgets
    /// any held for a playback or awaiting a report.
    private func cancelTransfers(of jobId: UUID, matching: (Range<Int64>) -> Bool = { _ in true }) {
        // A whole-file transfer has no range and only goes with the whole job.
        func isMatch(_ tag: TransferTag) -> Bool { tag.jobId == jobId && (tag.range.map(matching) ?? true) }
        for (identifier, transfer) in Self.cancellationOrder(running) where isMatch(transfer.tag) {
            cancel(identifier, transfer)
        }
        awaitingReports = awaitingReports.filter { !isMatch($0) }
        if isMatch(TransferTag(jobId: jobId, range: DownloadJob.probeRange)) { probes.removeValue(forKey: jobId)?.task.cancel() }
        guard heldResumeData.keys.contains(where: isMatch) else { return }
        heldResumeData = heldResumeData.filter { !isMatch($0.key) }
        do {
            try storage.removeHeld(where: isMatch)
        } catch {
            problem = "Couldn't clear a held download's progress: \(error.localizedDescription)"
        }
    }

    private func cancel(_ identifier: Int, _ transfer: RunningTransfer) {
        cancelledByUs.insert(identifier)
        running[identifier] = nil
        if transfer.tag.range == nil {
            // All a whole-file transfer has is its resume data: paused, it carries on from there.
            transfer.task.cancel(byProducingResumeData: { [weak self] data in
                guard let data else { return }
                Task { @MainActor in self?.keepResumeData(data, of: transfer.tag.jobId) }
            })
        } else {
            transfer.task.cancel()
        }
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

    /// Replaces the transfers that moved no bytes for `stallLimit`. The session starts transfers
    /// in an order of its own, so the running ones are those the server has answered, and one
    /// waiting its turn isn't stalled. When nothing has moved at all while the app is in front,
    /// the oldest `connectionsPerHost` count too: a transfer can stall before any answer. Off
    /// screen, transfers wait at the system's discretion, so nothing moving says nothing. A
    /// replaced transfer that received nothing loses nothing.
    private func replaceStalledTransfers(now: Date) {
        guard isNetworkReachable, !isPausedForPlayback else { return }
        let isStalled = { (transfer: RunningTransfer) in now.timeIntervalSince(transfer.lastProgress) > Self.stallLimit }
        var due = running.filter { $0.value.task.response != nil }
        if isInFront, running.values.allSatisfy(isStalled) {
            for (identifier, transfer) in running.sorted(by: { $0.key < $1.key }).prefix(Self.connectionsPerHost) {
                due[identifier] = transfer
            }
        }
        for (identifier, transfer) in due where (transfer.task.earliestBeginDate ?? .distantPast) <= now && isStalled(transfer) {
            Self.log.notice("Task \(identifier) [\(transfer.tag.encoded)]: no bytes for \(Int(now.timeIntervalSince(transfer.lastProgress)))s, replacing it")
            // Stuck partway: the link can't carry a chunk this big between drops.
            if let index = index(of: transfer.tag.jobId) {
                jobs[index].recordCut(receivedBytes: transfer.received, attemptStart: transfer.attemptStart, now: now)
            }
            cancelledByUs.insert(identifier)
            if transfer.resumed {
                // Resuming didn't get it going either (the daemon can carry its wait over into the
                // resume data): the range goes back to be planned again in today's chunk size.
                transfer.task.cancel()
                running[identifier] = nil
                pump()
                continue
            }
            // The transfer keeps its range until the replacement starts, so nothing else claims it.
            running[identifier]?.lastProgress = now
            transfer.task.cancel(byProducingResumeData: { [weak self] resumeData in
                Task { @MainActor in self?.replace(identifier, resumeData: resumeData) }
            })
        }
    }

    /// Continues a stalled transfer from the bytes it has, or, without resume data, hands its
    /// range back to be planned again in today's chunk size.
    private func replace(_ identifier: Int, resumeData: Data?) {
        guard let transfer = running.removeValue(forKey: identifier) else { return }
        guard let resumeData, let client = accounts.client,
              let job = jobs.first(where: { $0.id == transfer.tag.jobId }), job.status == .active,
              !(transfer.tag.range.map(job.completed.covers) ?? false)
        else { return pump() }
        start(transfer.tag, for: job, client: client, resumeData: resumeData)
    }

    private func networkChanged(reachable: Bool) {
        isNetworkReachable = reachable
        if reachable {
            pump()
            fetchExtrasSoon()
        }
    }

    // MARK: Finished transfers

    private func handle(_ finished: TransferDelegate.Finished) async {
        let transfer = running.removeValue(forKey: finished.taskIdentifier)
        let cancelled = cancelledByUs.remove(finished.taskIdentifier) != nil
        guard !cancelled, let tag = transfer?.tag ?? finished.tag,
              let index = index(of: tag.jobId), jobs[index].status != .completed
        else {
            discard(finished.stagedFile)
            return
        }
        let received = transfer?.received ?? 0
        Self.log.info("""
            Task \(finished.taskIdentifier) [\(tag.encoded)] finished: HTTP \(finished.response?.statusCode ?? 0), \
            Content-Range \(finished.response?.contentRange ?? "none"), \(finished.stagedSize ?? -1) bytes, \
            error \(finished.error.map { String(describing: $0) } ?? "none")
            """)

        if let error = finished.error {
            discard(finished.stagedFile)
            if tag.range == nil, let resumeData = finished.resumeData { keepResumeData(resumeData, of: tag.jobId) }
            guard jobs[index].status == .active else { return }
            if let reason = (error as? URLError)?.backgroundTaskCancelledReason, systemCancellation != reason {
                Self.log.notice("The system cancelled transfers: \(String(describing: reason), privacy: .public)")
                systemCancellation = reason
            }
            // Stopped by the system, e.g. when the app was force quit, says nothing about the
            // connection: no backoff, and the range is asked for again right away.
            if (error as? URLError)?.code != .cancelled {
                jobs[index].recordFailure(.network(Self.describe(error)), receivedBytes: received,
                                          attemptStart: transfer?.attemptStart ?? .now)
                save()
            }
            // A range that can resume carries on from its bytes instead of waiting to be planned
            // again, unless it has been already: after a relaunch, the wait for reports is bounded.
            if let range = tag.range, let resumeData = finished.resumeData, let client = accounts.client,
               !jobs[index].completed.covers(range), !isClaimed(tag)
            {
                start(tag, for: jobs[index], client: client, resumeData: resumeData)
            }
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
                                      attemptStart: transfer?.attemptStart ?? .now)
            if jobs[index].status == .failed { cancelTransfers(of: tag.jobId) }
            save()

        case .giveUp(let message):
            discard(finished.stagedFile)
            stop(index, because: message)
        }
    }

    private func acceptChunk(_ file: URL, range: Range<Int64>, total: Int64, jobId: UUID, response: ResponseInfo?) async {
        guard let index = index(of: jobId) else { return discard(file) }
        if jobs[index].rangeSupport == .unknown {
            jobs[index].rangeSupport = .supported
            jobs[index].totalBytes = total
            noteFileExtension(from: response, at: index)
            // Ranges planned from a listed size that was too big ask for bytes past the end.
            cancelTransfers(of: jobId) { $0.lowerBound >= total }
            if let available = storage.availableCapacity(), available < total - range.count64 {
                discard(file)
                stop(index, because: "Not enough free space: this needs \(Self.bytes(total)), \(Self.bytes(available)) is free.")
                return
            }
        }

        do {
            try await storage.writeChunk(file, into: jobId, at: range.lowerBound)
        } catch {
            discard(file)
            if let index = self.index(of: jobId) {
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

    /// Moves the finished file into Documents.
    private func publish(_ index: Int) {
        // Ranges another transfer already delivered can still be in flight.
        cancelTransfers(of: jobs[index].id)
        do {
            jobs[index].savedPath = try storage.publish(jobs[index])
            jobs[index].status = .completed
            jobs[index].completedAt = .now
            jobs[index].lastError = nil
            jobs[index].retryAt = nil
            // Its subtitles go beside it now.
            extrasDone.remove(jobs[index].id)
            fetchExtrasSoon()
        } catch {
            jobs[index].status = .failed
            jobs[index].lastError = "Couldn't move the finished file into place: \(error.localizedDescription)"
        }
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
        for job in jobs.sorted(by: { $0.createdAt < $1.createdAt })
        where (job.status == .active || job.status == .completed) && !extrasDone.contains(job.id)
            && (extrasFailures[job.id]?.retryAt ?? .distantPast) <= now
        {
            if let step = DownloadExtras.nextStep(for: job, storage: storage, exists: exists, now: now) { return (job, step) }
            extrasDone.insert(job.id)
            let size = storage.size(of: DownloadExtras.files(for: job, storage: storage).filter(\.isOwn).map(\.local))
            if job.extrasBytes != size, let index = index(of: job.id) {
                jobs[index].extrasBytes = size
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
            let (downloaded, response) = try await probeSession.download(for: URLRequest(url: file.url(using: client)))
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

    private func removePartial(of jobId: UUID) {
        do {
            try storage.removePartial(for: jobId)
        } catch {
            problem = "Couldn't delete a partial download: \(error.localizedDescription)"
        }
    }

    private func keepResumeData(_ data: Data, of jobId: UUID) {
        do {
            try data.write(to: storage.resumeDataFile(for: jobId), options: .atomic)
        } catch {
            problem = "Couldn't keep a download's resume data: \(error.localizedDescription)"
        }
    }

    /// Resume data is used once: a resumed transfer that fails again leaves new resume data.
    private func takeResumeData(of jobId: UUID) -> Data? {
        let file = storage.resumeDataFile(for: jobId)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        defer { discard(file) }
        do {
            return try Data(contentsOf: file)
        } catch {
            problem = "Couldn't read a download's resume data, so it starts over: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Progress

    private func refreshLiveProgress() {
        var bytes: [UUID: Int64] = [:]
        for job in jobs where job.status != .completed {
            bytes[job.id] = job.completed.byteCount
        }
        for transfer in running.values where bytes[transfer.tag.jobId] != nil {
            bytes[transfer.tag.jobId, default: 0] += transfer.received
        }
        let now = Date.now
        if let lastSample, now.timeIntervalSince(lastSample.date) > 5 {
            // The app was suspended: transfers carried on without reporting, so that time
            // says nothing about stalls.
            for identifier in running.keys { running[identifier]?.lastProgress = now }
        }
        var speeds: [UUID: Double] = [:]
        if let lastSample, now > lastSample.date {
            let interval = now.timeIntervalSince(lastSample.date)
            for (id, value) in bytes {
                let instant = max(0, Double(value - (lastSample.bytes[id] ?? value)) / interval)
                speeds[id] = (bytesPerSecond[id] ?? instant) * 0.7 + instant * 0.3
            }
        }
        lastSample = (now, bytes)
        if receivedBytes != bytes { receivedBytes = bytes }
        if bytesPerSecond != speeds { bytesPerSecond = speeds }
        if now.timeIntervalSince(lastStallCheck) > 10 {
            lastStallCheck = now
            replaceStalledTransfers(now: now)
        }
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

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

#if !os(macOS)
/// Time the system grants the app to finish something it started, in front or in the
/// background, until `end()` or until the system takes it back.
@MainActor
private final class BackgroundTime {
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
