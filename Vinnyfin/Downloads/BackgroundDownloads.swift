#if os(iOS) || os(visionOS)
import BackgroundTasks
import Foundation
import Observation
import OSLog
import UIKit

/// The time the app gets to run in the background for downloads. Transfers run in the system's
/// download daemon whether or not the app runs, but only a running app writes finished chunks
/// into place, publishes files, replaces stalled transfers and hands the session what's next;
/// a suspended one waits for the system to wake it, which it does once every transfer in the
/// session is done.
///
/// - On iPhone and iPad, downloads someone starts from the foreground (Download, Resume, Retry,
///   Start Over, Download Next or Download Now, or setting up a smart download) run under a
///   continued-processing task: the system keeps the app running in the background and shows
///   the task's progress, bytes done over bytes queued, as a Live Activity the person can stop.
///   One runs at a time, and only for downloads that may go on now: the rules (Download Over
///   Cellular, Low Data Mode, Only While Charging) and room still hold back those someone
///   started, unless they chose Download Now. It ends once nothing is left to download, or as
///   a playback, the rules or room hold back the rest (its progress would stand still), and
///   another starts once they let go while the app is in front and work someone started
///   remains. Stopped by the person or the system, it ends and the session carries on alone,
///   until someone starts a download again. Swiping the app away ends it too.
/// - Leaving the foreground with downloads unfinished books a catch-up processing task: the
///   system launches the app when the device is idle and online and, for Only While Charging,
///   on power (`DownloadManager.catchUpRequiresExternalPower`). That's how downloads waiting
///   for power start once the device is plugged in, with the app suspended: the app keeps the
///   queue moving until the queue is done or waits, or the time is up, and books another
///   until it's done.
/// - The app refresh wake, no more often than every `refreshInterval`, refreshes smart
///   downloads and then keeps the queue moving the same way.
///
/// Beside all of these, the person can keep the app running with audio, Keep Downloads Running
/// in Settings (`KeepAwakeAudio`); the Live Activity says so while it plays.
///
/// With Background App Refresh off (Low Power Mode turns it off), the system may not launch the
/// app for any of these, or for finished transfers; `notices` tells the user that, and why the
/// system cancelled transfers.
@Observable
final class BackgroundDownloads {
    /// Listed under BGTaskSchedulerPermittedIdentifiers in Info.plist, as are the others.
    static let refreshIdentifier = "net.vinnysaj.vinnyfin.smart-downloads"
    static let refreshInterval: TimeInterval = 2 * 60 * 60
    static let catchUpIdentifier = "net.vinnysaj.vinnyfin.download-catch-up"
    #if os(iOS)
    /// Each continued-processing task's identifier is this with a unique suffix; Info.plist
    /// lists it with `*` after it. A handler is registered for each identifier just before it's
    /// submitted: one registered for the pattern isn't used, and registering an identifier
    /// twice crashes the app.
    static let continuedIdentifierPrefix = "net.vinnysaj.vinnyfin.continued-download."
    #endif
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "background")

    private(set) var backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Notices the user dismissed. One comes back when what it's about changes.
    private(set) var dismissedNotices: Set<DownloadNotice> = []
    /// Why the system wouldn't give downloads time in the background, to show until dismissed.
    var problem: String?

    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let smartDownloads: SmartDownloads
    /// Whether the keep-alive plays too, for the Live Activity to say so on iPhone and iPad.
    @ObservationIgnored private let keepAwake: KeepAwakeAudio
    @ObservationIgnored private var appObservations: [NotificationCenter.ObservationToken] = []
    #if os(iOS)
    /// The continued-processing task submitted, until it ends.
    @ObservationIgnored private var continuedIdentifier: String?
    /// The task, once the system has started it.
    @ObservationIgnored private var continuedTask: BGContinuedProcessingTask?
    @ObservationIgnored private var continuedProgress = ContinuedProgress()
    @ObservationIgnored private var shownText: (title: String, subtitle: String)?
    #endif

    init(downloads: DownloadManager, smartDownloads: SmartDownloads, keepAwake: KeepAwakeAudio) {
        self.downloads = downloads
        self.smartDownloads = smartDownloads
        self.keepAwake = keepAwake
    }

    // MARK: Launch

    /// Registers what runs when the system launches the app for its tasks. The system requires
    /// that before the app finishes launching.
    func registerLaunchHandlers() {
        register(Self.refreshIdentifier) { [weak self] in await self?.refresh() }
        register(Self.catchUpIdentifier) { [weak self] in await self?.catchUp() }
    }

    /// Runs `work` for each launch of the task until it returns or the task's time is up, then
    /// completes the task, successfully unless its time ran out.
    private func register(_ identifier: String, work: @escaping @MainActor () async -> Void) {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            Self.log.info("Launched for \(identifier, privacy: .public)")
            let running = Task { await work() }
            task.expirationHandler = { @Sendable in running.cancel() }
            Task {
                await running.value
                Self.log.info("\(identifier, privacy: .public) \(running.isCancelled ? "ran out of time" : "is done", privacy: .public)")
                task.setTaskCompleted(success: !running.isCancelled)
            }
        }
        if !registered { problem = "vinnyfin can't run \(identifier) in the background: it's missing from the app's permitted tasks." }
    }

    /// Books the wakes as the app leaves the foreground, follows Background App Refresh and Low
    /// Power Mode and, on iPhone and iPad, starts, updates and ends continued-processing tasks as
    /// the downloads change, for the life of the app.
    func run() async {
        let center = NotificationCenter.default
        appObservations = [
            center.addObserver(of: UIApplication.shared, for: .didEnterBackground) { [weak self] _ in
                Task { await self?.appEnteredBackground() }
            },
            center.addObserver(of: UIApplication.shared, for: .backgroundRefreshStatusDidChange) { [weak self] _ in
                self?.backgroundRefreshChanged()
            },
        ]
        await withDiscardingTaskGroup { group in
            group.addTask { await self.followPowerState() }
            #if os(iOS)
            group.addTask { await self.followDownloads() }
            #endif
        }
    }

    // MARK: Leaving the foreground

    /// Books the wakes: the refresh, and a catch-up while downloads are unfinished.
    private func appEnteredBackground() async {
        await bookRefresh()
        if DownloadJob.queue(downloads.jobs).isEmpty {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.catchUpIdentifier)
        } else {
            await bookCatchUp()
        }
    }

    private func bookRefresh() async {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(Self.refreshInterval)
        await submit(request, for: "the smart download refresh")
    }

    private func bookCatchUp() async {
        let request = BGProcessingTaskRequest(identifier: Self.catchUpIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = downloads.catchUpRequiresExternalPower
        await submit(request, for: "catching up on downloads")
    }

    /// The system woke the app to refresh: books the next refresh, refreshes smart downloads,
    /// then keeps the queue moving for the rest of the time.
    private func refresh() async {
        await bookRefresh()
        await smartDownloads.refresh()
        await downloads.keepMoving()
    }

    /// The system launched the app to catch up: keeps the queue moving until it's done or waits,
    /// or the time is up. The next catch-up is booked first, in case this one runs out of time,
    /// and called off once the queue is done.
    private func catchUp() async {
        await bookCatchUp()
        await downloads.keepMoving()
        if DownloadJob.queue(downloads.jobs).isEmpty {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.catchUpIdentifier)
        }
    }

    /// Hands the system a request. Its failures that Background App Refresh being off explains
    /// show as that notice; others as `problem`.
    private func submit(_ request: sending BGTaskRequest, for purpose: String) async {
        let identifier = request.identifier
        do {
            try await Self.submitOffTheMainThread(request)
            Self.log.info("Booked \(identifier, privacy: .public)")
        } catch {
            Self.log.error("Couldn't book \(identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            if (error as? BGTaskScheduler.Error)?.code == .unavailable, backgroundRefreshStatus != .available { return }
            problem = "The system wouldn't give vinnyfin time in the background for \(purpose): \(Self.describe(error))"
        }
    }

    /// The scheduler asks not to be called on the main thread.
    @concurrent private nonisolated static func submitOffTheMainThread(_ request: sending BGTaskRequest) async throws {
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }

    private static func describe(_ error: any Error) -> String {
        switch (error as? BGTaskScheduler.Error)?.code {
        case .unavailable: "background tasks aren't available here (the Simulator doesn't run them)."
        case .tooManyPendingTaskRequests: "too many background tasks are waiting."
        case .notPermitted: "vinnyfin isn't set up to ask for it."
        case .immediateRunIneligible: "it's too busy to start one right now."
        default: error.localizedDescription
        }
    }

    // MARK: Notices

    /// What holds downloads back, for the Downloads screen.
    func notices(hasActiveDownloads: Bool) -> [DownloadNotice] {
        DownloadNotice.current(
            hasActiveDownloads: hasActiveDownloads,
            systemCancellation: downloads.systemCancellation,
            backgroundRefreshStatus: backgroundRefreshStatus,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            dismissed: dismissedNotices
        )
    }

    func dismiss(_ notice: DownloadNotice) {
        switch notice {
        case .closedByUser, .stoppedBySystem:
            downloads.systemCancellation = nil
        case .backgroundRefreshOff, .backgroundRefreshRestricted, .lowPowerMode:
            if downloads.systemCancellation == .backgroundUpdatesDisabled { downloads.systemCancellation = nil }
            dismissedNotices.insert(notice)
        }
    }

    private func backgroundRefreshChanged() {
        backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        dismissedNotices.subtract([.backgroundRefreshOff, .backgroundRefreshRestricted])
        Self.log.info("Background App Refresh is now \(self.backgroundRefreshStatus.rawValue)")
    }

    private func followPowerState() async {
        for await _ in NotificationCenter.default.messages(of: ProcessInfo.processInfo, for: .powerStateDidChange) {
            let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            guard enabled != isLowPowerModeEnabled else { continue }
            isLowPowerModeEnabled = enabled
            dismissedNotices.remove(.lowPowerMode)
            Self.log.info("Low Power Mode is now \(enabled ? "on" : "off", privacy: .public)")
        }
    }

    // MARK: Continued processing

    #if os(iOS)
    /// The downloads as a continued-processing task sees them.
    private struct DownloadsState: Sendable {
        let jobs: [DownloadJob]
        let receivedBytes: [UUID: Int64]
        let userStartedJobIds: Set<UUID>
        let isInFront: Bool
        let isPausedForPlayback: Bool
        let isNetworkReachable: Bool
        let waits: [UUID: DownloadWait]
        /// What the server is doing for transcoded downloads.
        let notes: [UUID: String]
        let isKeptRunning: Bool

        @MainActor init(_ downloads: DownloadManager, keepAwake: KeepAwakeAudio) {
            jobs = downloads.jobs
            receivedBytes = downloads.receivedBytes
            userStartedJobIds = downloads.userStartedJobIds
            isInFront = downloads.isInFront
            isPausedForPlayback = downloads.isPausedForPlayback
            isNetworkReachable = downloads.isNetworkReachable
            waits = downloads.waits
            notes = downloads.transcodes.notes(for: downloads.jobs)
            isKeptRunning = keepAwake.isRunning
        }

        @MainActor var text: (title: String, subtitle: String) {
            ContinuedProgress.text(jobs: jobs, receivedBytes: receivedBytes, isNetworkReachable: isNetworkReachable, waits: waits, notes: notes,
                                   isKeptRunning: isKeptRunning)
        }
    }

    private func followDownloads() async {
        let downloads = downloads
        let keepAwake = keepAwake
        for await state in Observations({ DownloadsState(downloads, keepAwake: keepAwake) }) {
            update(state)
        }
    }

    private func update(_ state: DownloadsState) {
        if let task = continuedTask {
            continuedProgress.update(jobs: state.jobs, receivedBytes: state.receivedBytes)
            task.progress.totalUnitCount = continuedProgress.totalUnitCount
            task.progress.completedUnitCount = continuedProgress.completedUnitCount
            if let ending = continuedProgress.ending(jobs: state.jobs, isPausedForPlayback: state.isPausedForPlayback, waits: state.waits) {
                end(task, ending)
            } else {
                show(state.text, on: task)
            }
        } else if let identifier = continuedIdentifier {
            // Submitted but not started: called off if the work goes first, or can't go on.
            if state.isPausedForPlayback || DownloadJob.queue(state.jobs).allSatisfy({ state.waits[$0] != nil }) {
                Self.log.info("Calling off \(identifier, privacy: .public) before it started")
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                continuedIdentifier = nil
            }
        } else if ContinuedProgress.shouldStart(jobs: state.jobs, userStartedJobIds: state.userStartedJobIds, isInFront: state.isInFront,
                                                isPausedForPlayback: state.isPausedForPlayback, waits: state.waits) {
            submitContinuedTask(state)
        }
    }

    private func submitContinuedTask(_ state: DownloadsState) {
        let identifier = Self.continuedIdentifierPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            self.continuedTaskStarted(task, identifier: identifier)
        }
        guard registered else {
            gaveUpContinuing(because: "it's missing from the app's permitted tasks.")
            return
        }
        continuedIdentifier = identifier
        continuedProgress = ContinuedProgress()
        let text = state.text
        Task { await submitContinuedRequest(identifier, text: text) }
    }

    private func submitContinuedRequest(_ identifier: String, text: (title: String, subtitle: String)) async {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: text.title, subtitle: text.subtitle)
        // Started later, when the system has room, rather than not at all.
        request.strategy = .queue
        Self.log.info("Submitting \(identifier, privacy: .public): \(text.title, privacy: .public)")
        do {
            try await Self.submitOffTheMainThread(request)
        } catch {
            Self.log.error("Couldn't submit \(identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            guard continuedIdentifier == identifier else { return }
            continuedIdentifier = nil
            if (error as? BGTaskScheduler.Error)?.code == .unavailable, backgroundRefreshStatus != .available {
                downloads.forgetUserStartedJobs()
            } else {
                gaveUpContinuing(because: Self.describe(error))
            }
        }
    }

    private func continuedTaskStarted(_ task: BGContinuedProcessingTask, identifier: String) {
        guard identifier == continuedIdentifier else {
            // Called off before the system got to it.
            task.setTaskCompleted(success: false)
            return
        }
        Self.log.info("Started \(identifier, privacy: .public)")
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.continuedTaskExpired(identifier) }
        }
        continuedTask = task
        shownText = (task.title, task.subtitle)
        update(DownloadsState(downloads, keepAwake: keepAwake))
    }

    /// The person stopped it from its Live Activity, or the system needed the resources back.
    /// The downloads go on in the session regardless.
    private func continuedTaskExpired(_ identifier: String) {
        guard identifier == continuedIdentifier, let task = continuedTask else { return }
        Self.log.notice("\(identifier, privacy: .public) expired")
        task.setTaskCompleted(success: false)
        continuedTask = nil
        continuedIdentifier = nil
        downloads.forgetUserStartedJobs()
    }

    private func end(_ task: BGContinuedProcessingTask, _ ending: ContinuedProgress.Ending) {
        Self.log.info("Ending \(task.identifier, privacy: .public): \(String(describing: ending), privacy: .public)")
        let text = ending.text
        task.updateTitle(text.title, subtitle: text.subtitle)
        task.setTaskCompleted(success: ending.isSuccess)
        continuedTask = nil
        continuedIdentifier = nil
        shownText = nil
        // After a playback, or once the rules or room let go, the work someone started carries
        // on under a new task.
        if !ending.carriesOnLater { downloads.forgetUserStartedJobs() }
    }

    private func show(_ text: (title: String, subtitle: String), on task: BGContinuedProcessingTask) {
        guard shownText.map({ $0 != text }) ?? true else { return }
        task.updateTitle(text.title, subtitle: text.subtitle)
        shownText = text
    }

    private func gaveUpContinuing(because reason: String) {
        downloads.forgetUserStartedJobs()
        problem = "vinnyfin couldn't keep running in the background for these downloads, so they may wait while it's suspended: \(reason)"
    }
    #endif
}
#endif
