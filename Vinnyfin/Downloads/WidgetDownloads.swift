#if !os(tvOS)
import Foundation
#if os(iOS) || os(macOS)
import ImageIO
import Observation
import WidgetKit
#if os(iOS)
import UIKit
#endif
#endif

extension DownloadsSnapshot {
    /// The downloads as they stand now.
    init(_ downloads: DownloadManager, history: WatchHistory) {
        self.init(jobs: downloads.jobs, receivedBytes: downloads.receivedBytes, downloadingJobId: downloads.downloadingJobId,
                  isHeldForPlayback: downloads.isPausedForPlayback, isNetworkReachable: downloads.isNetworkReachable,
                  waits: downloads.waits.mapValues(\.status), notes: downloads.transcodes.notes(for: downloads.jobs),
                  isWatched: { $0.watchState(local: history.entry(for: $0.itemId)).isWatched })
    }

    /// The unfinished downloads in the order they download, the paused and failed ones after
    /// them, and the finished ones not yet watched, one per title. `waits` says what holds
    /// queued downloads back, in the words of their status lines, and `notes` what the server
    /// is doing for transcoded ones.
    init(jobs: [DownloadJob], receivedBytes: [UUID: Int64], downloadingJobId: UUID?, isHeldForPlayback: Bool,
         isNetworkReachable: Bool, waits: [UUID: String] = [:], notes: [UUID: String] = [:], isWatched: (DownloadJob) -> Bool,
         now: Date = .now) {
        self.init()
        let unfinished = jobs.filter { $0.status != .completed }
        let queue = DownloadJob.queue(jobs)
        let ordered = queue.compactMap { id in unfinished.first { $0.id == id } }
            + unfinished.filter { !queue.contains($0.id) }
        downloads = ordered.prefix(Self.listLimit).map { job in
            let wait = job.status == .active ? waits[job.id] : nil
            let state: Download.State = switch job.status {
            case .paused: .paused
            case .failed: .failed
            case .active, .completed:
                isHeldForPlayback ? .held : !isNetworkReachable ? .waitingForNetwork : wait != nil ? .waiting
                    : job.id == downloadingJobId ? .downloading : .queued
            }
            let received = receivedBytes[job.id] ?? job.bytesOnDisk
            let percent = job.displayTotalBytes.flatMap { total in total > 0 ? Int(min(100, received * 100 / total)) : nil }
            return Download(title: Title(job), state: state, percent: percent, wait: wait, note: notes[job.id])
        }
        unfinishedCount = unfinished.count
        activeCount = unfinished.count { $0.status == .active }
        var seen = Set<String>()
        let finished = jobs.filter { $0.status == .completed && !isWatched($0) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .filter { seen.insert($0.itemId).inserted }
        ready = finished.prefix(Self.listLimit).map(Title.init)
        readyCount = finished.count
        updatedAt = now
    }
}

extension DownloadsSnapshot.Title {
    init(_ job: DownloadJob) {
        self.init(itemId: job.itemId, type: job.item?.type ?? (job.isEpisode ? "Episode" : "Movie"),
                  name: job.item?.name ?? job.title, title: job.title, subtitle: job.subtitle)
    }
}

#if os(iOS) || os(macOS)
/// Keeps the Downloads widget and control up to date: writes the downloads' `DownloadsSnapshot`
/// to the app group as they change, with small copies of the titles' pictures, and has the system
/// reload them. A change in more than progress goes out within seconds, progress alone once a
/// minute, and whatever is waiting as the app leaves the foreground. Each file is written whole
/// and closed at once; nothing in the group stays open.
@Observable
final class WidgetDownloads: DownloadsRunning {
    /// Why the widget can't be kept up to date, to show until dismissed.
    var problem: String?

    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private var written: DownloadsSnapshot?
    @ObservationIgnored private var writtenAt = Date.distantPast
    @ObservationIgnored private var pending: DownloadsSnapshot?
    @ObservationIgnored private var scheduled: (date: Date, task: Task<Void, Never>)?
    @ObservationIgnored private var appObservations: [NotificationCenter.ObservationToken] = []

    /// How wide the pictures the widget shows are kept, in pixels.
    nonisolated static let artworkSize = 360

    init(downloads: DownloadManager, history: WatchHistory) {
        self.downloads = downloads
        self.history = history
    }

    /// Follows the downloads for the life of the app.
    func run() async {
        #if os(iOS)
        appObservations = [
            NotificationCenter.default.addObserver(of: UIApplication.shared, for: .didEnterBackground) { [weak self] _ in
                Task { await self?.writePending() }
            },
        ]
        #endif
        let downloads = downloads
        let history = history
        for await snapshot in Observations({ DownloadsSnapshot(downloads, history: history) }) {
            pending = snapshot
            schedule()
        }
    }

    /// Runs or pauses every download for the Downloads control, and writes the snapshot at once,
    /// so the control and widget show it as soon as the intent returns.
    func setRunning(_ isRunning: Bool) async {
        if isRunning { downloads.resumeAll() } else { downloads.pauseAll() }
        pending = DownloadsSnapshot(downloads, history: history)
        await writePending()
    }

    /// Times the next write for what's pending, sooner than one already timed when it has to be.
    private func schedule() {
        guard let pending, let date = pending.writeDate(after: written, writtenAt: writtenAt) else { return }
        if let scheduled, scheduled.date <= date { return }
        scheduled?.task.cancel()
        scheduled = (date, Task { [weak self] in
            let wait = date.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            await self.writePending()
        })
    }

    private func writePending() async {
        guard let snapshot = pending, snapshot.writeDate(after: written, writtenAt: writtenAt) != nil else { return }
        scheduled?.task.cancel()
        scheduled = nil
        guard let folder = DownloadsSnapshot.folder else {
            problem = "The Downloads widget can't be kept up to date: this copy of vinnyfin can't reach its app group."
            return
        }
        var pictures: [String: URL] = [:]
        for title in snapshot.downloads.map(\.title) + snapshot.ready {
            let job = downloads.jobs(forItem: title.itemId).first
            pictures[title.itemId] = downloads.artworkURL(itemId: title.itemId, kind: .primary)
                ?? job?.seriesId.flatMap { downloads.artworkURL(itemId: $0, kind: .primary) }
        }
        do {
            let saved = try await Self.write(snapshot, pictures: pictures, to: folder)
            let controlChanged = written.map { $0.isRunning != saved.isRunning || $0.unfinishedCount != saved.unfinishedCount } ?? true
            written = snapshot
            writtenAt = .now
            WidgetCenter.shared.reloadTimelines(ofKind: DownloadsSnapshot.widgetKind)
            if controlChanged { ControlCenter.shared.reloadControls(ofKind: DownloadsSnapshot.controlKind) }
        } catch {
            problem = "Couldn't update the Downloads widget: \(error.localizedDescription)"
        }
        // What changed while this was written.
        schedule()
    }

    /// Writes the pictures the snapshot's titles lack, deletes those it no longer shows, then
    /// the snapshot, marked with the pictures it has.
    @concurrent
    private nonisolated static func write(_ snapshot: DownloadsSnapshot, pictures: [String: URL], to folder: URL) async throws -> DownloadsSnapshot {
        let manager = FileManager.default
        let artworkFolder = folder.appending(path: "Artwork", directoryHint: .isDirectory)
        try manager.createDirectory(at: artworkFolder, withIntermediateDirectories: true)
        var snapshot = snapshot
        var kept = Set<String>()
        func withArtwork(_ title: DownloadsSnapshot.Title) throws -> DownloadsSnapshot.Title {
            var title = title
            let file = artworkFolder.appending(path: "\(title.itemId).jpg")
            if !manager.fileExists(atPath: file.path), let source = pictures[title.itemId], let data = thumbnail(of: source) {
                try data.write(to: file, options: writeOptions)
            }
            title.hasArtwork = manager.fileExists(atPath: file.path)
            kept.insert(file.lastPathComponent)
            return title
        }
        snapshot.downloads = try snapshot.downloads.map { download in
            DownloadsSnapshot.Download(title: try withArtwork(download.title), state: download.state, percent: download.percent)
        }
        snapshot.ready = try snapshot.ready.map(withArtwork)
        for file in try manager.contentsOfDirectory(at: artworkFolder, includingPropertiesForKeys: nil)
        where !kept.contains(file.lastPathComponent) {
            try manager.removeItem(at: file)
        }
        try JSONEncoder().encode(snapshot).write(to: folder.appending(path: "snapshot.json"), options: writeOptions)
        return snapshot
    }

    /// Whole and in one go, readable on the Lock Screen once the device has been unlocked since it started.
    private nonisolated static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        .atomic
        #endif
    }

    /// A small JPEG of a saved picture. Nil when the picture can't be read, which leaves the
    /// widget's placeholder in its place.
    private nonisolated static func thumbnail(of picture: URL) -> Data? {
        CGImageSourceCreateWithURL(picture as CFURL, nil).flatMap {
            WidgetArtwork.jpeg(from: $0, maxPixelSize: artworkSize, quality: 0.8)
        }
    }
}
#endif
#endif
