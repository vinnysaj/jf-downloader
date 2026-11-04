#if os(iOS) || os(visionOS)
import Foundation
import UIKit

#if os(iOS)
/// What a continued-processing task shows while downloads go on in the background: bytes done
/// over bytes queued, across every download that was active while the task ran, counted so
/// the bytes done never go back.
nonisolated struct ContinuedProgress: Equatable, Sendable {
    /// A download's bytes as last seen while it was active, or in full once it finished.
    private struct Counted: Equatable, Sendable {
        var done: Int64
        var total: Int64
    }

    private var counted: [UUID: Counted] = [:]
    private(set) var completedUnitCount: Int64 = 0
    private(set) var totalUnitCount: Int64 = 0

    /// Counts the downloads as they are now. One that stops while the task runs (paused, failed
    /// or removed) keeps the bytes it had; one that finishes counts in full. A transfer cut off
    /// partway takes its bytes back, but the count done stays where it was.
    mutating func update(jobs: [DownloadJob], receivedBytes: [UUID: Int64]) {
        for job in jobs {
            switch job.status {
            case .active:
                let total = job.displayTotalBytes ?? 0
                let received = job.isTransferComplete ? total : min(total, receivedBytes[job.id] ?? job.completed.byteCount)
                counted[job.id] = Counted(done: max(counted[job.id]?.done ?? 0, received), total: total)
            case .completed:
                guard counted[job.id] != nil, let total = job.totalBytes else { continue }
                counted[job.id] = Counted(done: total, total: total)
            case .paused, .failed:
                continue
            }
        }
        let done = counted.values.reduce(0) { $0 + $1.done }
        let total = counted.values.reduce(0) { $0 + $1.total }
        completedUnitCount = max(completedUnitCount, done)
        totalUnitCount = max(total, completedUnitCount)
    }

    /// How the task ends: once nothing is left to download, or as a playback holds the
    /// downloads, when its progress would stand still. Nil while it has work.
    func ending(jobs: [DownloadJob], isPausedForPlayback: Bool) -> Ending? {
        if isPausedForPlayback { return .heldForPlayback }
        guard DownloadJob.queue(jobs).isEmpty else { return nil }
        let mine = jobs.filter { counted[$0.id] != nil }
        let failed = mine.count { $0.status == .failed }
        if failed > 0 { return .failed(count: failed) }
        if mine.contains(where: { $0.status == .paused }) { return .paused }
        let finished = mine.count { $0.status == .completed }
        return finished > 0 ? .finished(count: finished) : .cancelled
    }

    enum Ending: Equatable, Sendable {
        case finished(count: Int)
        case paused
        case failed(count: Int)
        /// Every download it covered was removed.
        case cancelled
        case heldForPlayback

        /// Only downloads that all came through count as the task succeeding.
        var isSuccess: Bool {
            if case .finished = self { true } else { false }
        }

        /// The Live Activity's last words.
        var text: (title: String, subtitle: String) {
            switch self {
            case .finished(let count):
                (count == 1 ? "Download finished" : "Downloads finished", "Ready to watch offline in vinnyfin")
            case .paused:
                ("Downloads paused", "Resume them in vinnyfin")
            case .failed(let count):
                (count == 1 ? "A download failed" : "\(count) downloads failed", "Open vinnyfin to retry")
            case .cancelled:
                ("Downloads cancelled", "Nothing is left to download")
            case .heldForPlayback:
                ("Downloads paused while you watch", "They carry on once you're done")
            }
        }
    }

    /// Whether a task should start: the app is in front (the system asks for that), someone
    /// started downloads that aren't done, and nothing holds them.
    static func shouldStart(jobs: [DownloadJob], userStartedJobIds: Set<UUID>, isInFront: Bool, isPausedForPlayback: Bool) -> Bool {
        isInFront && !isPausedForPlayback && !userStartedJobIds.isDisjoint(with: DownloadJob.queue(jobs))
    }

    /// The Live Activity's words while downloading: what's downloading and how much is left.
    static func text(jobs: [DownloadJob], receivedBytes: [UUID: Int64], isNetworkReachable: Bool) -> (title: String, subtitle: String) {
        let queue = DownloadJob.queue(jobs).compactMap { id in jobs.first { $0.id == id } }
        guard let first = queue.first else { return ("Downloading", "Finishing up") }
        let title = queue.count == 1 ? "Downloading \(first.shortName)" : "Downloading \(first.shortName) and \(queue.count - 1) more"
        guard isNetworkReachable else { return (title, "Waiting for a network connection") }
        let sizes = queue.map(\.displayTotalBytes)
        guard !sizes.contains(nil) else { return (title, "Starting") }
        let left = queue.reduce(Int64(0)) { total, job in
            total + max(0, (job.displayTotalBytes ?? 0) - (receivedBytes[job.id] ?? job.completed.byteCount))
        }
        return (title, "\(left.formatted(.byteCount(style: .file))) left")
    }
}

nonisolated extension DownloadJob {
    /// A short name for the system's UI: "Show S01E02" for an episode, else the title.
    var shortName: String {
        guard isEpisode, let series = item?.seriesName else { return title }
        return [series, item?.episodeCode].compactMap(\.self).joined(separator: " ")
    }
}
#endif

/// Something outside the app that holds downloads back, in plain words with what to do.
enum DownloadNotice: String, CaseIterable, Identifiable, Sendable {
    /// The app was swiped away in the app switcher, which cancels every transfer and keeps
    /// the app closed until it's opened again.
    case closedByUser
    /// The system cancelled transfers to free up resources, or for a reason newer than this code.
    case stoppedBySystem
    /// Background App Refresh is off, so the system won't launch the app for finished transfers.
    case backgroundRefreshOff
    /// Background App Refresh is turned off for this device by Screen Time or a profile.
    case backgroundRefreshRestricted
    case lowPowerMode

    var id: Self { self }

    var title: String {
        switch self {
        case .closedByUser: "Downloads stopped when vinnyfin was closed"
        case .stoppedBySystem: "The system stopped downloads"
        case .backgroundRefreshOff: "Background App Refresh is off for vinnyfin"
        case .backgroundRefreshRestricted: "Background App Refresh isn't allowed on this \(Device.name)"
        case .lowPowerMode: "Low Power Mode is on"
        }
    }

    var message: String {
        switch self {
        case .closedByUser:
            #if os(visionOS)
            "Force quitting vinnyfin stops its downloads until you open it again. They've carried on now."
            #else
            "Swiping vinnyfin away in the app switcher stops its downloads until you open it again. They've carried on now. To keep them going in the background, leave vinnyfin in the app switcher."
            #endif
        case .stoppedBySystem:
            "It needed the resources for something else. They've carried on now that vinnyfin is open."
        case .backgroundRefreshOff:
            "Without it, downloads can stop while vinnyfin is in the background and wait for you to open it. Turn it on in vinnyfin's settings."
        case .backgroundRefreshRestricted:
            "Screen Time or a device profile turns it off, so downloads may carry on only while vinnyfin is open."
        case .lowPowerMode:
            "It turns off Background App Refresh, so downloads can stop while vinnyfin is in the background. Keep vinnyfin open, or turn Low Power Mode off in Control Center or Settings › Battery."
        }
    }

    var systemImage: String {
        switch self {
        case .closedByUser: "xmark.app"
        case .stoppedBySystem: "exclamationmark.arrow.triangle.2.circlepath"
        case .backgroundRefreshOff, .backgroundRefreshRestricted: "arrow.clockwise.circle"
        case .lowPowerMode: "battery.25percent"
        }
    }

    /// Offers to open the app's page in Settings, where the switch is.
    var opensSettings: Bool { self == .backgroundRefreshOff }

    /// The notices to show, in this order, while there are active downloads. With Low Power
    /// Mode on, Background App Refresh reads as off and its switch can't be turned on, so only
    /// Low Power Mode is mentioned.
    static func current(
        hasActiveDownloads: Bool,
        systemCancellation: URLError.BackgroundTaskCancelledReason?,
        backgroundRefreshStatus: UIBackgroundRefreshStatus,
        isLowPowerModeEnabled: Bool,
        dismissed: Set<DownloadNotice>
    ) -> [DownloadNotice] {
        guard hasActiveDownloads else { return [] }
        var notices: [DownloadNotice] = []
        switch systemCancellation {
        case .userForceQuitApplication: notices.append(.closedByUser)
        case .backgroundUpdatesDisabled: notices.append(.backgroundRefreshOff)
        case .insufficientSystemResources: notices.append(.stoppedBySystem)
        case nil: break
        @unknown default: notices.append(.stoppedBySystem)
        }
        if isLowPowerModeEnabled {
            notices.removeAll { $0 == .backgroundRefreshOff }
            notices.append(.lowPowerMode)
        } else {
            switch backgroundRefreshStatus {
            case .denied: if !notices.contains(.backgroundRefreshOff) { notices.append(.backgroundRefreshOff) }
            case .restricted: notices.append(.backgroundRefreshRestricted)
            case .available: break
            @unknown default: break
            }
        }
        return notices.filter { !dismissed.contains($0) }
    }
}
#endif
