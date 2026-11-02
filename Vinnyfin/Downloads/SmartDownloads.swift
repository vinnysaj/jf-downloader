#if !os(tvOS)
import Foundation
import Observation
import OSLog

/// Keeps shows downloaded ahead of where they're being watched: per show, the next N episodes
/// after the one watched last (or every remaining episode), topped up as episodes are watched
/// here or on any other device. With "Delete Watched Episodes" on, watched downloads go.
@Observable
final class SmartDownloads {
    nonisolated struct Rule: Codable, Identifiable, Equatable, Sendable {
        let seriesId: String
        var seriesName: String
        /// Nil keeps every remaining episode.
        var episodesAhead: Int?
        var id: String { seriesId }
    }

    private(set) var rules: [Rule] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Why the last refresh couldn't finish, to show until dismissed or the next one.
    var problem: String?

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.vinnysaj.vinnyfin", category: "smart-downloads")

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
        save()
        refreshSoon()
    }

    func removeRule(seriesId: String) {
        rules.removeAll { $0.seriesId == seriesId }
        save()
    }

    /// A playback of `item` ended: what's watched may have changed.
    func playbackEnded(_ item: JellyfinItem) {
        guard item.isEpisode else { return }
        refreshSoon()
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
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = .now
        }
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
            SmartDownloadPlanner.Episode(
                id: episode.id,
                played: isPlayed(episode),
                isQueued: !downloads.jobs(forItem: episode.id).isEmpty,
                isDownloaded: downloads.isDownloaded(episode.id)
            )
        }
        if let rule = rule(for: seriesId) {
            let wanted = SmartDownloadPlanner.episodesToDownload(states, nextUpId: nextUp, count: rule.episodesAhead)
            for id in wanted {
                let detail = try await client.item(id: id, userId: account.userId)
                guard let source = VersionChooser.choose(from: detail.mediaSources ?? [], quality: settings.downloadQuality) else { continue }
                downloads.enqueue(detail, source: source)
            }
        }
        if settings.deleteWatchedEpisodes {
            for id in SmartDownloadPlanner.watchedDownloads(states) {
                Self.log.info("Deleting watched episode \(id, privacy: .public)")
                downloads.deleteDownloads(ofItem: id)
            }
        }
    }

    private func deleteWatchedOffline(seriesId: String) {
        guard settings.deleteWatchedEpisodes else { return }
        for job in downloads.jobs where job.seriesId == seriesId && job.status == .completed {
            if history.entry(for: job.itemId)?.played == true { downloads.deleteDownloads(ofItem: job.itemId) }
        }
    }

    /// Watched on the server, or here since the server was last told.
    private func isPlayed(_ episode: JellyfinItem) -> Bool {
        if let local = history.entry(for: episode.id), local.needsSync { return local.played }
        return episode.isPlayed
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
        /// Has a download in any state.
        let isQueued: Bool
        let isDownloaded: Bool
    }

    /// The episodes to queue: `count` episodes (or all) from the next one to watch, which is
    /// the server's next-up episode, or else the one after the last watched.
    static func episodesToDownload(_ episodes: [Episode], nextUpId: String?, count: Int?) -> [String] {
        let start: Int
        if let nextUpId, let index = episodes.firstIndex(where: { $0.id == nextUpId }) {
            start = index
        } else if let lastPlayed = episodes.lastIndex(where: \.played) {
            start = lastPlayed + 1
        } else {
            start = 0
        }
        guard start < episodes.count else { return [] }
        let end = count.map { min(episodes.count, start + max(0, $0)) } ?? episodes.count
        return episodes[start..<end].filter { !$0.isQueued && !$0.played }.map(\.id)
    }

    static func watchedDownloads(_ episodes: [Episode]) -> [String] {
        episodes.filter { $0.played && $0.isDownloaded }.map(\.id)
    }
}
