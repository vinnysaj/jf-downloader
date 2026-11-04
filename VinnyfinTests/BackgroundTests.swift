#if os(iOS) || os(visionOS)
import Foundation
import Observation
import Testing
import UIKit
@testable import vinnyfin

private func job(_ item: JellyfinItem = Samples.movie, at offset: TimeInterval = 0, status: DownloadJob.Status = .active) -> DownloadJob {
    var job = DownloadJob(item: item, source: Samples.source, now: Date(timeIntervalSince1970: 1_000_000 + offset))
    job.status = status
    return job
}

/// Marks a job's file all in and published.
private func finished(_ original: DownloadJob) -> DownloadJob {
    var job = original
    job.status = .completed
    job.rangeSupport = .supported
    job.totalBytes = 300_000_000
    job.completed = ByteRanges([0..<300_000_000])
    return job
}

#if os(iOS)
@MainActor
struct ContinuedProgressTests {
    @Test func countsBytesDoneOverBytesQueued() {
        let first = job()
        let second = job(at: 1)
        var progress = ContinuedProgress()
        progress.update(jobs: [first, second], receivedBytes: [first.id: 100_000_000])
        #expect(progress.completedUnitCount == 100_000_000)
        #expect(progress.totalUnitCount == 600_000_000)
    }

    @Test func neverGoesBack() {
        let first = job()
        var progress = ContinuedProgress()
        progress.update(jobs: [first], receivedBytes: [first.id: 100_000_000])
        // A transfer cut off partway loses what it had received.
        progress.update(jobs: [first], receivedBytes: [first.id: 40_000_000])
        #expect(progress.completedUnitCount == 100_000_000)
        // The server says the file is smaller than listed.
        var smaller = first
        smaller.rangeSupport = .supported
        smaller.totalBytes = 50_000_000
        progress.update(jobs: [smaller], receivedBytes: [first.id: 40_000_000])
        #expect(progress.completedUnitCount == 100_000_000)
        #expect(progress.totalUnitCount >= progress.completedUnitCount)
    }

    @Test func countsAFinishedDownloadInFullAndOneDoneBeforeNotAtAll() {
        let earlier = finished(job())
        let current = job(at: 1)
        var progress = ContinuedProgress()
        progress.update(jobs: [earlier, current], receivedBytes: [current.id: 200_000_000])
        #expect(progress.totalUnitCount == 300_000_000)
        progress.update(jobs: [earlier, finished(current)], receivedBytes: [:])
        #expect(progress.completedUnitCount == 300_000_000)
        #expect(progress.totalUnitCount == 300_000_000)
    }

    @Test func keepsTheBytesOfADownloadThatStops() {
        let paused = job()
        let removed = job(at: 1)
        var progress = ContinuedProgress()
        progress.update(jobs: [paused, removed], receivedBytes: [paused.id: 100_000_000, removed.id: 50_000_000])
        var nowPaused = paused
        nowPaused.status = .paused
        progress.update(jobs: [nowPaused], receivedBytes: [:])
        #expect(progress.completedUnitCount == 150_000_000)
        #expect(progress.totalUnitCount == 600_000_000)
    }

    @Test func endsOnceNothingIsLeftOrAPlaybackHolds() {
        let first = job()
        let second = job(at: 1)
        var progress = ContinuedProgress()
        progress.update(jobs: [first, second], receivedBytes: [:])
        #expect(progress.ending(jobs: [first, second], isPausedForPlayback: false, waits: [:]) == nil)
        #expect(progress.ending(jobs: [first, second], isPausedForPlayback: true, waits: [:]) == .heldForPlayback)
        #expect(progress.ending(jobs: [finished(first), finished(second)], isPausedForPlayback: false, waits: [:]) == .finished(count: 2))
        var failed = second
        failed.status = .failed
        #expect(progress.ending(jobs: [finished(first), failed], isPausedForPlayback: false, waits: [:]) == .failed(count: 1))
        var paused = second
        paused.status = .paused
        #expect(progress.ending(jobs: [finished(first), paused], isPausedForPlayback: false, waits: [:]) == .paused)
        #expect(progress.ending(jobs: [], isPausedForPlayback: false, waits: [:]) == .cancelled)
        // A download finished before the task began isn't one it covered.
        let earlier = finished(job(at: -1))
        #expect(progress.ending(jobs: [earlier], isPausedForPlayback: false, waits: [:]) == .cancelled)
        #expect(ContinuedProgress.Ending.finished(count: 1).isSuccess)
        #expect(!ContinuedProgress.Ending.heldForPlayback.isSuccess)
        #expect(!ContinuedProgress.Ending.paused.isSuccess)
    }

    @Test func startsForWorkSomeoneStartedWhileInFront() {
        let mine = job()
        let smart = job(at: 1)
        let jobs = [mine, smart]
        #expect(ContinuedProgress.shouldStart(jobs: jobs, userStartedJobIds: [mine.id], isInFront: true, isPausedForPlayback: false, waits: [:]))
        #expect(!ContinuedProgress.shouldStart(jobs: jobs, userStartedJobIds: [mine.id], isInFront: false, isPausedForPlayback: false, waits: [:]))
        #expect(!ContinuedProgress.shouldStart(jobs: jobs, userStartedJobIds: [mine.id], isInFront: true, isPausedForPlayback: true, waits: [:]))
        // Smart downloads topping a show up by themselves don't start one.
        #expect(!ContinuedProgress.shouldStart(jobs: jobs, userStartedJobIds: [], isInFront: true, isPausedForPlayback: false, waits: [:]))
        // Nor does work someone started that's done.
        #expect(!ContinuedProgress.shouldStart(jobs: [finished(mine), smart], userStartedJobIds: [mine.id], isInFront: true, isPausedForPlayback: false, waits: [:]))
    }

    @Test func saysWhatsDownloadingAndHowMuchIsLeft() {
        let movie = job()
        let one = ContinuedProgress.text(jobs: [movie], receivedBytes: [movie.id: 100_000_000], isNetworkReachable: true, waits: [:])
        #expect(one.title == "Downloading Big Test Movie (2024)")
        #expect(one.subtitle == "\(Int64(200_000_000).formatted(.byteCount(style: .file))) left")
        let episode = job(Samples.episode, at: -1)
        let two = ContinuedProgress.text(jobs: [episode, movie], receivedBytes: [:], isNetworkReachable: true, waits: [:])
        #expect(two.title == "Downloading Test Show S01E02 and 1 more")
        #expect(two.subtitle == "\(Int64(600_000_000).formatted(.byteCount(style: .file))) left")
        #expect(ContinuedProgress.text(jobs: [movie], receivedBytes: [:], isNetworkReachable: false, waits: [:]).subtitle == "Waiting for a network connection")
        var unsized = Samples.source
        unsized.size = nil
        let probing = DownloadJob(item: Samples.movie, source: unsized)
        #expect(ContinuedProgress.text(jobs: [probing], receivedBytes: [:], isNetworkReachable: true, waits: [:]).subtitle == "Starting")
    }

    /// Someone's tap doesn't start one for downloads the rules hold back, unless they chose
    /// Download Now, which lifts the rules (and so the wait) for that download.
    @Test func startsOnlyForDownloadsThatMayGoOnNow() {
        let mine = job()
        let other = job(at: 1)
        let waiting: [UUID: DownloadWait] = [mine.id: .wifi]
        #expect(!ContinuedProgress.shouldStart(jobs: [mine, other], userStartedJobIds: [mine.id], isInFront: true,
                                               isPausedForPlayback: false, waits: waiting))
        #expect(ContinuedProgress.shouldStart(jobs: [mine, other], userStartedJobIds: [mine.id, other.id], isInFront: true,
                                              isPausedForPlayback: false, waits: waiting))
    }

    @Test func endsWhenEverythingLeftWaits() {
        let first = job()
        let second = job(at: 1)
        var progress = ContinuedProgress()
        progress.update(jobs: [first, second], receivedBytes: [:])
        let opens = Date(timeIntervalSince1970: 2_000_000)
        let waits: [UUID: DownloadWait] = [first.id: .overnight(opens: opens), second.id: .power]
        #expect(progress.ending(jobs: [first, second], isPausedForPlayback: false, waits: waits) == .waiting(.overnight(opens: opens)))
        #expect(progress.ending(jobs: [first, second], isPausedForPlayback: false, waits: [first.id: .power]) == nil)
        #expect(ContinuedProgress.Ending.waiting(.power).carriesOnLater)
        #expect(ContinuedProgress.Ending.heldForPlayback.carriesOnLater)
        #expect(!ContinuedProgress.Ending.finished(count: 1).carriesOnLater)
        #expect(!ContinuedProgress.Ending.waiting(.wifi).isSuccess)
    }

    @Test func saysWhatTheNextDownloadWaitsFor() {
        let movie = job()
        let text = ContinuedProgress.text(jobs: [movie], receivedBytes: [:], isNetworkReachable: true, waits: [movie.id: .wifi])
        #expect(text.subtitle == "Waiting for Wi-Fi")
        #expect(ContinuedProgress.Ending.waiting(.wifi).text.subtitle == "They carry on over Wi-Fi")
    }
}
#endif

@MainActor
struct DownloadNoticeTests {
    private func notices(
        active: Bool = true,
        cancellation: URLError.BackgroundTaskCancelledReason? = nil,
        refresh: UIBackgroundRefreshStatus = .available,
        lowPower: Bool = false,
        dismissed: Set<DownloadNotice> = []
    ) -> [DownloadNotice] {
        DownloadNotice.current(hasActiveDownloads: active, systemCancellation: cancellation, backgroundRefreshStatus: refresh,
                               isLowPowerModeEnabled: lowPower, dismissed: dismissed)
    }

    @Test func showsNothingWithoutActiveDownloads() {
        #expect(notices(active: false, cancellation: .userForceQuitApplication, refresh: .denied, lowPower: true).isEmpty)
        #expect(notices().isEmpty)
    }

    @Test func tellsWhyTheSystemCancelledTransfers() {
        #expect(notices(cancellation: .userForceQuitApplication) == [.closedByUser])
        #expect(notices(cancellation: .insufficientSystemResources) == [.stoppedBySystem])
        #expect(notices(cancellation: .backgroundUpdatesDisabled) == [.backgroundRefreshOff])
    }

    @Test func tellsWhenBackgroundAppRefreshIsOff() {
        #expect(notices(refresh: .denied) == [.backgroundRefreshOff])
        #expect(notices(cancellation: .backgroundUpdatesDisabled, refresh: .denied) == [.backgroundRefreshOff])
        #expect(notices(refresh: .restricted) == [.backgroundRefreshRestricted])
        #expect(DownloadNotice.backgroundRefreshOff.opensSettings)
    }

    @Test func mentionsOnlyLowPowerModeWhileItTurnsRefreshOff() {
        #expect(notices(refresh: .denied, lowPower: true) == [.lowPowerMode])
        #expect(notices(cancellation: .backgroundUpdatesDisabled, lowPower: true) == [.lowPowerMode])
        #expect(notices(cancellation: .userForceQuitApplication, refresh: .denied, lowPower: true) == [.closedByUser, .lowPowerMode])
    }

    @Test func leavesOutDismissedNotices() {
        #expect(notices(cancellation: .userForceQuitApplication, lowPower: true, dismissed: [.lowPowerMode]) == [.closedByUser])
    }
}

struct DiagnosticsSummaryTests {
    private let day = DateInterval(start: Date(timeIntervalSince1970: 1_000_000), duration: 86_400)

    @Test func linesSayWhatStoppedTheAppWorstFirst() {
        let lines = ExitReport.lines([.normal: 5, .memoryLimit: 2, .watchdog: 0, .memoryPressure: 1])
        #expect(lines == [
            "Stopped for using too much memory: 2",
            "Closed to free up memory for other apps: 1",
            "Closed normally, as when swiped away or closed by the system: 5",
        ])
        #expect(ExitReport.lines([:]).isEmpty)
    }

    @Test func keepsTheNewestReportsOnePerDay() {
        let older = ExitReport(timeRange: day, background: [.memoryLimit: 1])
        let newer = ExitReport(timeRange: DateInterval(start: day.end, duration: 86_400), background: [.cpuLimit: 1])
        var kept = ExitReport.keeping(older, in: [], limit: 2)
        kept = ExitReport.keeping(newer, in: kept, limit: 2)
        #expect(kept == [newer, older])
        // The same day again replaces it.
        let again = ExitReport(timeRange: day, background: [.memoryLimit: 3])
        #expect(ExitReport.keeping(again, in: kept, limit: 2) == [newer, again])
        let third = ExitReport(timeRange: DateInterval(start: newer.timeRange.end, duration: 86_400))
        #expect(ExitReport.keeping(third, in: kept, limit: 2) == [third, newer])
    }

    @Test func countsDiagnosticsByKind() {
        let later = DateInterval(start: day.end, duration: 60)
        let diagnostics = [
            Diagnostic(kind: .hang, timeRange: later),
            Diagnostic(kind: .crash, timeRange: day, detail: "SIGABRT"),
            Diagnostic(kind: .crash, timeRange: later),
        ]
        #expect(Diagnostic.lines(diagnostics) == ["Crashes: 2", "Hangs: 1"])
        #expect(Diagnostic.timeRange(diagnostics) == DateInterval(start: day.start, end: later.end))
        #expect(Diagnostic.timeRange([]) == nil)
    }

    @Test func roundTripsThroughDisk() throws {
        let saved = AppDiagnostics.Saved(
            exits: [ExitReport(timeRange: day, background: [.memoryLimit: 2], foreground: [.watchdog: 1])],
            diagnostics: [Diagnostic(kind: .crash, timeRange: day, detail: "EXC_BAD_ACCESS")]
        )
        let decoded = try JSONDecoder().decode(AppDiagnostics.Saved.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
    }
}

/// `DownloadManager.keepMoving()` waits on an `Observations` sequence for as long as a background
/// task runs, so the sequence has to end when the task is cancelled (its time is up).
@MainActor
struct ObservationsCancellationTests {
    @MainActor @Observable final class Flag {
        var isSet = false
    }

    @Test(.timeLimit(.minutes(1))) func endsWhenItsTaskIsCancelled() async {
        let flag = Flag()
        let waiting = Task {
            for await isSet in Observations({ flag.isSet }) where isSet { return true }
            return false
        }
        try? await Task.sleep(for: .milliseconds(200))
        waiting.cancel()
        #expect(await waiting.value == false)
    }

    @Test(.timeLimit(.minutes(1))) func endsWhenWhatItWaitsForHappens() async {
        let flag = Flag()
        let waiting = Task {
            for await isSet in Observations({ flag.isSet }) where isSet { return true }
            return false
        }
        try? await Task.sleep(for: .milliseconds(200))
        flag.isSet = true
        #expect(await waiting.value == true)
    }
}
#endif
