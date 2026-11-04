#if !os(tvOS)
import Foundation
import Observation
import OSLog

/// Keeps shows downloaded ahead of where they're being watched: per show, the next N episodes
/// after the one watched last (or every remaining episode), topped up as episodes are watched
/// here or on any other device. With "Delete Watched Episodes" on, watched downloads go.
///
/// Refreshes when the app opens, every `openInterval` while it's open, when a player closes, and
/// on the background refresh wake (`BackgroundDownloads`). Never while a player is open: the
/// episode in it could be the one a refresh deletes. The episodes a refresh queues for a show
/// someone just set up count as downloads they started; the ones it tops up later don't.
@Observable
final class SmartDownloads {
    static let openInterval: Duration = .seconds(15 * 60)

    nonisolated struct Rule: Codable, Identifiable, Equatable, Sendable {
        let seriesId: String
        var seriesName: String
        /// Nil keeps every remaining episode.
        var episodesAhead: Int?
        var id: String { seriesId }
    }

    private(set) var rules: [Rule] = []
    /// Why the last refresh couldn't finish, to show until dismissed or the next one.
    var problem: String?

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    /// The players open, by their model's id.
    @ObservationIgnored private var openPlayers: Set<UUID> = []
    /// Shows someone set up or changed whose next refresh hasn't queued their episodes yet.
    @ObservationIgnored private var seriesSetUpByUser: Set<String> = []

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "smart-downloads")

    init(accounts: AccountStore, downloads: DownloadManager, settings: AppSettings, history: WatchHistory,
         file: URL = URL.applicationSupportDirectory.appending(path: "SmartDownloads.json")) {
        self.accounts = accounts
        self.downloads = downloads
        self.settings = settings
        self.history = history
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                rules = try JSONDecoder().decode([Rule].self, from: Data(contentsOf: file))
            } catch {
                problem = "Couldn't read the smart download list: \(error.localizedDescription)"
            }
        }
    }

    func rule(for seriesId: String) -> Rule? {
        rules.first { $0.seriesId == seriesId }
    }

    func setRule(seriesId: String, seriesName: String, episodesAhead: Int?) {
        let rule = Rule(seriesId: seriesId, seriesName: seriesName, episodesAhead: episodesAhead)
        if let index = rules.firstIndex(where: { $0.seriesId == seriesId }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        seriesSetUpByUser.insert(seriesId)
        save()
        refreshSoon()
    }

    func removeRule(seriesId: String) {
        rules.removeAll { $0.seriesId == seriesId }
        seriesSetUpByUser.remove(seriesId)
        save()
    }

    func playerOpened(_ player: UUID) {
        openPlayers.insert(player)
    }

    /// Catches up on what the playback changed once no player is open.
    func playerClosed(_ player: UUID) {
        openPlayers.remove(player)
        if openPlayers.isEmpty { refreshSoon() }
    }

    /// Refreshes now, then every `openInterval` until the caller's task is cancelled, as the app
    /// goes to the background.
    func refreshWhileOpen() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.openInterval)
        }
    }

    /// Refreshes after a moment, folding several triggers into one pass.
    func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await refresh()
        }
    }

    /// Tops up every rule's show and deletes watched episodes, as far as the server can be
    /// reached; offline, only episodes watched on this device are deleted.
    func refresh() async {
        guard !isRefreshing else { return }
        guard openPlayers.isEmpty else {
            Self.log.info("Refresh skipped while a player is open; it runs when the player closes")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        problem = nil
        var seriesIds = Set(rules.map(\.seriesId))
        if settings.deleteWatchedEpisodes {
            seriesIds.formUnion(downloads.jobs.compactMap { $0.status == .completed ? $0.seriesId : nil })
        }
        for seriesId in seriesIds.sorted() {
            if Task.isCancelled { return }
            do {
                try await refresh(seriesId: seriesId)
            } catch {
                // The background refresh ran out of time, or the app is closing.
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                if Self.isOffline(error) {
                    deleteWatchedOffline(seriesId: seriesId)
                    continue
                }
                let name = rule(for: seriesId)?.seriesName ?? "a show"
                problem = "Couldn't update downloads for \(name): \(error.localizedDescription)"
                Self.log.error("Refresh of \(seriesId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func refresh(seriesId: String) async throws {
        guard let client = accounts.client, let account = accounts.account else { return }
        let episodes = try await client.episodes(seriesId: seriesId, seasonId: nil, userId: account.userId, fields: "MediaSources")
            .filter { $0.parentIndexNumber != 0 }
        let nextUp = try await client.nextUp(userId: account.userId, seriesId: seriesId, limit: 1).first?.id
        let states = episodes.map { episode in
            let downloadedAt = downloads.jobs(forItem: episode.id).compactMap(\.completedAt).min()
            return SmartDownloadPlanner.Episode(
                id: episode.id,
                played: isPlayed(episode),
                inProgress: isInProgress(episode),
                isQueued: !downloads.jobs(forItem: episode.id).isEmpty,
                isDownloaded: downloads.isDownloaded(episode.id),
                watchedSinceDownload: downloadedAt.map { watched(episode, since: $0) } ?? false
            )
        }
        if let rule = rule(for: seriesId) {
            let wanted = SmartDownloadPlanner.episodesToDownload(states, nextUpId: nextUp, count: rule.episodesAhead)
            let startedByUser = seriesSetUpByUser.contains(seriesId)
            for id in wanted {
                let detail = try await client.item(id: id, userId: account.userId)
                guard let source = VersionChooser.choose(from: detail.mediaSources ?? [], quality: settings.downloadQuality) else { continue }
                downloads.enqueue(detail, source: source, startedByUser: startedByUser)
            }
            seriesSetUpByUser.remove(seriesId)
        }
        if settings.deleteWatchedEpisodes {
            for id in SmartDownloadPlanner.watchedDownloads(states) {
                // A player opened while the server was answering could be playing this one.
                guard openPlayers.isEmpty else { return }
                Self.log.info("Deleting watched episode \(id, privacy: .public)")
                downloads.deleteDownloads(ofItem: id)
            }
        }
    }

    private func deleteWatchedOffline(seriesId: String) {
        guard settings.deleteWatchedEpisodes, openPlayers.isEmpty else { return }
        for job in downloads.jobs where job.seriesId == seriesId && job.status == .completed {
            guard let entry = history.entry(for: job.itemId), let completedAt = job.completedAt else { continue }
            if entry.played, entry.updatedAt > completedAt { downloads.deleteDownloads(ofItem: job.itemId) }
        }
    }

    /// Finished since `date`, when it was downloaded, rather than watched before and downloaded
    /// to see again. Where this device played it since, its own record decides: a rewatch stopped
    /// early leaves the server still calling the episode watched.
    private func watched(_ episode: JellyfinItem, since date: Date) -> Bool {
        if let local = history.entry(for: episode.id), local.updatedAt > date { return local.played }
        return (episode.lastPlayedDate ?? .distantPast) > date
    }

    /// Watched on the server, or here since the server was last told.
    private func isPlayed(_ episode: JellyfinItem) -> Bool {
        if let local = history.entry(for: episode.id), local.needsSync { return local.played }
        return episode.isPlayed
    }

    /// Partway through, here or on the server. The server keeps a rewatched episode marked
    /// watched while it's partway through again.
    private func isInProgress(_ episode: JellyfinItem) -> Bool {
        if let local = history.entry(for: episode.id), local.needsSync { return !local.played && local.position > 0 }
        return (episode.userData?.playbackPositionTicks ?? 0) > 0
    }

    private static func isOffline(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .timedOut, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed].contains(urlError.code)
    }

    private func save() {
        do {
            try JSONEncoder().encode(rules).write(to: file, options: .atomic)
        } catch {
            problem = "Couldn't save the smart download list: \(error.localizedDescription)"
        }
    }
}
#endif

/// What smart downloads do with a show, worked out from its episodes in watching order.
nonisolated enum SmartDownloadPlanner {
    struct Episode: Equatable, Sendable {
        let id: String
        let played: Bool
        /// Partway through, as when picking a watched episode up again. Kept, never deleted.
        let inProgress: Bool
        /// Has a download in any state.
        let isQueued: Bool
        let isDownloaded: Bool
        /// Finished after its download did; one downloaded already watched is being kept to see again.
        var watchedSinceDownload = false
    }

    /// The episodes to queue: `count` episodes (or all) from the next one to watch, which is
    /// the server's next-up episode, or else the one after the last watched. A next-up episode
    /// finished here before the server heard about it is passed over.
    static func episodesToDownload(_ episodes: [Episode], nextUpId: String?, count: Int?) -> [String] {
        var start: Int
        if let nextUpId, let index = episodes.firstIndex(where: { $0.id == nextUpId }) {
            start = index
            while start < episodes.count, episodes[start].isFinished { start += 1 }
        } else if let lastPlayed = episodes.lastIndex(where: \.isFinished) {
            start = lastPlayed + 1
        } else {
            start = 0
        }
        guard start < episodes.count else { return [] }
        let end = count.map { min(episodes.count, start + max(0, $0)) } ?? episodes.count
        return episodes[start..<end].filter { !$0.isQueued && !$0.isFinished }.map(\.id)
    }

    /// The downloads to delete: episodes finished since they were downloaded.
    static func watchedDownloads(_ episodes: [Episode]) -> [String] {
        episodes.filter { $0.isFinished && $0.isDownloaded && $0.watchedSinceDownload }.map(\.id)
    }
}

nonisolated extension SmartDownloadPlanner.Episode {
    /// Watched and not being watched again.
    var isFinished: Bool { played && !inProgress }
}
