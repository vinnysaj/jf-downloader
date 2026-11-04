#if !os(tvOS)
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
/// Files download oldest first, and none while something plays. Their chunks are planned from
/// the size Jellyfin lists and handed to the session in that order while the app is open, so the
/// session works through the queue by itself with the app suspended or terminated: transfers
/// created on a background wake start only when the system sees fit, and the system wakes the
/// app only once every transfer is done. The session runs `connectionsPerHost` transfers at a
/// time and doesn't promise an order (nor honors task priority), but takes them about as they
/// were created, so the server serves one file at a time except as one file hands over to the
/// next. A file whose size isn't listed is asked for one byte first, and the files after it wait
/// for the answer.
///
/// Every transfer's purpose is in its `taskDescription` (`TransferTag`), so the queue rebuilds
/// itself from the session after a relaunch.
@Observable
final class DownloadManager {
    static let sessionIdentifier = "net.vinnysaj.vinnyfin.transfers"
    /// Transfers handed to the system at once, across the queue; the session runs
    /// `connectionsPerHost` of them at a time. The queue is deep because transfers created while
    /// the app is open start right away, while ones created on a background wake may be held
    /// back by the system (until Wi-Fi or charging, say): queued from the foreground, a whole
    /// file or several keep downloading after the phone goes in a pocket.
    static let maxQueuedTransfers = 128
    static let connectionsPerHost = 4
    /// While the app is open, a transfer the session should be running that moved no bytes for
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
    /// Moves when saved artwork changes, so views showing it look again.
    private(set) var artworkRevision = 0
    /// A local problem (storage, the saved queue) to show until dismissed.
    var problem: String?

    private struct RunningTransfer {
        let tag: TransferTag
        let task: URLSessionDownloadTask
        var received: Int64
        /// When bytes last arrived, or when the app started or adopted the transfer.
        var lastProgress = Date.now
        /// Started from a stalled transfer's resume data.
        var resumed = false
    }

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let storage: DownloadStorage
    @ObservationIgnored private let delegate: TransferDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var running: [Int: RunningTransfer] = [:]
    /// Tasks this app cancelled (pause, remove, restart); whatever they deliver is dropped.
    @ObservationIgnored private var cancelledByUs: Set<Int> = []
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var backgroundEventsDelivered = false
    /// False until `run()` has adopted the session's existing transfers; scheduling before that
    /// would request ranges that are already in flight.
    @ObservationIgnored private var hasAdoptedTransfers = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastSample: (date: Date, bytes: [UUID: Int64])?
    @ObservationIgnored private var lastStallCheck = Date.now
    /// The open players, by their model's id, and whether each is playing.
    @ObservationIgnored private var players: [UUID: Bool] = [:]
    @ObservationIgnored private var isInBackground = false
    /// Resume data of ranges cancelled for a playback, by tag, to carry on from afterwards.
    @ObservationIgnored private var heldResumeData: [String: Data] = [:]

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
        hasAdoptedTransfers = true
        // Opened to play a file, the player can be up before the session's tasks are adopted.
        if isPausedForPlayback { holdTransfers() }
        pump()

        for await event in delegate.events {
            switch event {
            case .progress(let taskIdentifier, let received):
                guard let transfer = running[taskIdentifier] else { continue }
                running[taskIdentifier]?.received = received
                running[taskIdentifier]?.lastProgress = .now
                if received < transfer.received { restarted(taskIdentifier, after: transfer.received) }
            case .finished(let finished):
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
    /// replaces stalled transfers meanwhile. Runs while the app is open.
    func trackProgress() async {
        while !Task.isCancelled {
            refreshLiveProgress()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Commands

    func enqueue(_ item: JellyfinItem, source: MediaSource) {
        let known = jobs.contains { $0.itemId == item.id && $0.mediaSourceId == source.id }
        guard !known else { return }
        var job = DownloadJob(item: item, source: source)
        if let size = job.sizeHint, let available = storage.availableCapacity(), available < queuedBytesRemaining + size {
            job.status = .failed
            job.lastError = "Not enough free space: the downloads queued need \(Self.bytes(queuedBytesRemaining + size)), \(Self.bytes(available)) is free."
        }
        jobs.append(job)
        save()
        pump()
        if let client = accounts.client {
            let storage = storage
            Task { [weak self] in
                do {
                    try await storage.saveArtwork(for: item, client: client)
                } catch {
                    Self.log.notice("Couldn't save artwork for \(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                self?.artworkRevision += 1
            }
            // The intro and credits, so the skip buttons work offline too.
            Task { [weak self] in
                do {
                    let segments = try await client.mediaSegments(itemId: item.id)
                    guard let self, let index = self.index(of: job.id) else { return }
                    self.jobs[index].segments = segments
                    self.save()
                } catch {
                    Self.log.notice("Couldn't save segments for \(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func pause(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status == .active else { return }
        cancelTransfers(of: id)
        jobs[index].status = .paused
        save()
        pump()
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

    func sceneChanged(isInBackground: Bool) {
        self.isInBackground = isInBackground
        updateHold()
    }

    /// Downloads leave the connection and the server to the picture while something plays, and
    /// while a player is open in front of the user, paused or between episodes, so pausing
    /// doesn't stop and start them. A paused player left in the background lets them go on.
    private func updateHold() {
        let hold = players.values.contains(true) || (!players.isEmpty && !isInBackground)
        guard hold != isPausedForPlayback else { return }
        isPausedForPlayback = hold
        if hold { holdTransfers() } else { releaseTransfers() }
    }

    /// Cancels every transfer, keeping any resume data. Suspending would keep them in place, but
    /// a suspended transfer loses its connection after a minute or so and starts its range over,
    /// and one suspended when the app dies stays that way until the app opens again.
    private func holdTransfers() {
        Self.log.info("Holding \(self.running.count) transfers for a playback")
        for (identifier, transfer) in running {
            cancelledByUs.insert(identifier)
            running[identifier] = nil
            transfer.task.cancel(byProducingResumeData: { [weak self] data in
                guard let data else { return }
                Task { @MainActor in self?.hold(data, for: transfer.tag) }
            })
        }
    }

    private func hold(_ data: Data, for tag: TransferTag) {
        if tag.range == nil {
            keepResumeData(data, of: tag.jobId)
        } else if isPausedForPlayback {
            heldResumeData[tag.encoded] = data
        }
    }

    /// Carries on from the held ranges' bytes, oldest file first, then plans the rest.
    private func releaseTransfers() {
        Self.log.info("Carrying on with \(self.heldResumeData.count) held transfers after a playback")
        let held = heldResumeData.compactMap { encoded, data in TransferTag(encoded: encoded).map { ($0, data) } }
        heldResumeData = [:]
        if let client = accounts.client {
            let order = { (tag: TransferTag) in (self.index(of: tag.jobId) ?? .max, tag.range?.lowerBound ?? 0) }
            for (tag, data) in held.sorted(by: { order($0.0) < order($1.0) }) {
                guard let range = tag.range, let job = jobs.first(where: { $0.id == tag.jobId }), job.status == .active,
                      !job.completed.covers(range),
                      !running.values.contains(where: { $0.tag.jobId == tag.jobId && $0.tag.range?.overlaps(range) == true })
                else { continue }
                start(tag, for: job, client: client, resumeData: data)
            }
        }
        pump()
    }

    /// Continues a paused job, or retries a failed one from where it got to.
    func resume(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status == .paused || jobs[index].status == .failed else { return }
        jobs[index].status = .active
        jobs[index].networkFailures = 0
        jobs[index].serverFailures = 0
        jobs[index].retryAt = nil
        save()
        pump()
    }

    /// Starts over from the first byte, for a source that changed on the server.
    func restart(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status != .completed else { return }
        cancelTransfers(of: id)
        removePartial(of: id)
        jobs[index].resetProgress()
        save()
        pump()
    }

    func remove(_ id: UUID, deletingFile: Bool = false) {
        guard let index = index(of: id) else { return }
        cancelTransfers(of: id)
        removePartial(of: id)
        if deletingFile, let savedPath = jobs[index].savedPath {
            let file = storage.finished.appending(path: savedPath)
            do {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            } catch {
                problem = "Couldn't delete \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }
        jobs.remove(at: index)
        save()
        pump()
    }

    func removeCompleted() {
        jobs.removeAll { $0.status == .completed }
        save()
    }

    /// Stops and forgets every unfinished job, for signing out. Finished files stay.
    func removeUnfinished() {
        for job in jobs where job.status != .completed {
            cancelTransfers(of: job.id)
            removePartial(of: job.id)
        }
        jobs.removeAll { $0.status != .completed }
        save()
    }

    func savedFileURL(of job: DownloadJob) -> URL? {
        job.savedPath.map { storage.finished.appending(path: $0) }
    }

    /// A finished download of the item (of that version, when one is given) whose file is still there.
    func playableFile(itemId: String, mediaSourceId: String?) -> PlaybackResolver.DownloadedCopy? {
        let candidates = jobs.filter {
            $0.itemId == itemId && $0.status == .completed && (mediaSourceId == nil || $0.mediaSourceId == mediaSourceId)
        }
        for job in candidates {
            if let url = savedFileURL(of: job), FileManager.default.fileExists(atPath: url.path) {
                return PlaybackResolver.DownloadedCopy(url: url, item: job.item, segments: job.segments ?? [])
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
        do {
            try storage.removeArtwork(for: itemId)
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

    /// Bytes the active downloads still have to fetch, as far as their sizes are known.
    private var queuedBytesRemaining: Int64 {
        jobs.filter { $0.status == .active }.reduce(0) { total, job in
            total + max(0, (job.displayTotalBytes ?? 0) - job.completed.byteCount)
        }
    }

    /// Bytes the finished downloads take up.
    var storageUsed: Int64 {
        jobs.filter { $0.status == .completed }.reduce(0) { $0 + ($1.totalBytes ?? 0) }
    }

    func availableCapacity() -> Int64? { storage.availableCapacity() }

    /// Saved artwork for an item, for showing it offline.
    func artworkURL(itemId: String, kind: JellyfinClient.ImageKind) -> URL? {
        _ = artworkRevision
        let file = storage.artworkFile(itemId: itemId, kind: kind)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    var finishedFolder: URL { storage.finished }

    // MARK: Scheduling

    /// Publishes finished files, then hands the session as many transfers as the budget allows,
    /// oldest file first.
    private func pump() {
        guard hasAdoptedTransfers, let client = accounts.client else { return }
        var published = false
        for index in jobs.indices where jobs[index].status == .active && jobs[index].isTransferComplete {
            publish(index)
            published = true
        }
        if published { save() }
        let queue = DownloadJob.queue(jobs)
        if downloadingJobId != queue.first { downloadingJobId = queue.first }
        guard !isPausedForPlayback else { return }
        var budget = Self.maxQueuedTransfers - running.count
        for id in queue {
            guard budget > 0, let index = index(of: id) else { break }
            let tags = running.values.filter { $0.tag.jobId == id }.map(\.tag)
            for range in jobs[index].nextRequests(running: tags, limit: budget) {
                start(TransferTag(jobId: id, range: range), for: jobs[index], client: client)
                budget -= 1
            }
            // The files after one of unknown size wait for its answer, so the server isn't asked
            // about every file at once.
            if jobs[index].needsProbe { break }
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

    /// Cancels the job's transfers, or only those whose range `matching` accepts.
    private func cancelTransfers(of jobId: UUID, matching: (Range<Int64>) -> Bool = { _ in true }) {
        for (identifier, transfer) in running where transfer.tag.jobId == jobId {
            // A whole-file transfer has no range and only goes with the whole job.
            guard transfer.tag.range.map(matching) ?? true else { continue }
            cancelledByUs.insert(identifier)
            running[identifier] = nil
            if transfer.tag.range == nil {
                // All a whole-file transfer has is its resume data: paused, it carries on from there.
                transfer.task.cancel(byProducingResumeData: { [weak self] data in
                    guard let data else { return }
                    Task { @MainActor in self?.keepResumeData(data, of: jobId) }
                })
            } else {
                transfer.task.cancel()
            }
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
        jobs[index].recordCut(receivedBytes: lostBytes)
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
    /// waiting its turn isn't stalled. When nothing has moved at all, the oldest
    /// `connectionsPerHost` count too: a transfer can stall before any answer. A replaced
    /// transfer that received nothing loses nothing.
    private func replaceStalledTransfers(now: Date) {
        guard isNetworkReachable, !isPausedForPlayback else { return }
        let isStalled = { (transfer: RunningTransfer) in now.timeIntervalSince(transfer.lastProgress) > Self.stallLimit }
        var due = running.filter { $0.value.task.response != nil }
        if running.values.allSatisfy(isStalled) {
            for (identifier, transfer) in running.sorted(by: { $0.key < $1.key }).prefix(Self.connectionsPerHost) {
                due[identifier] = transfer
            }
        }
        for (identifier, transfer) in due where (transfer.task.earliestBeginDate ?? .distantPast) <= now && isStalled(transfer) {
            Self.log.notice("Task \(identifier) [\(transfer.tag.encoded)]: no bytes for \(Int(now.timeIntervalSince(transfer.lastProgress)))s, replacing it")
            // Stuck partway: the link can't carry a chunk this big between drops.
            if let index = index(of: transfer.tag.jobId) { jobs[index].recordCut(receivedBytes: transfer.received) }
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
        if reachable { pump() }
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
            // Stopped by the system, e.g. when the app was force quit, says nothing about the
            // connection: no backoff, and the range is asked for again right away.
            if (error as? URLError)?.code != .cancelled {
                jobs[index].recordFailure(.network(Self.describe(error)), receivedBytes: received)
                save()
            }
            // A range that can resume carries on from its bytes instead of waiting to be planned again.
            if tag.range != nil, let resumeData = finished.resumeData, let client = accounts.client {
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
            jobs[index].recordFailure(failure, receivedBytes: max(received, finished.stagedSize ?? 0))
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
        if jobs[index].status == .active { jobs[index].recordSuccess(growingChunks: range.count64 >= jobs[index].chunkSize) }
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

    // MARK: Files

    private func save() {
        do {
            try storage.saveJobs(jobs)
        } catch {
            problem = "Couldn't save the download list: \(error.localizedDescription)"
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
#endif
