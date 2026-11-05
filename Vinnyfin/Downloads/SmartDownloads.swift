#if !os(tvOS)
import Foundation
import Observation
import OSLog

/// Keeps shows downloaded ahead of where they're being watched: per show, the next N episodes
/// after the one watched last, or every episode not yet watched, topped up as episodes are
/// watched here or on any other device and as new ones reach the server. Each refresh also
/// brings what the server says about how finished downloads were watched into the downloads
/// (`DownloadManager.recordWatchState`), which decide from it, and from this device's history,
/// what's watched since it was queued: an episode of one of these shows watched before its
/// download finished is dropped, with "Delete Watched Episodes" on, watched episodes go, and
/// watched downloads of any kind go to make room.
///
/// Refreshes when the app opens, every `openInterval` while it's open, when a player closes, and
/// on the background refresh wake (`BackgroundDownloads`). Never while a player is open: the
/// episode in it could be the one a refresh deletes. The episodes a refresh queues for a show
/// someone just set up count as downloads they started; the ones it tops up later don't. Siri
/// and Shortcuts queue a show's next episodes once through `downloadNext`.
@Observable
final class SmartDownloads {
    static let openInterval: Duration = .seconds(15 * 60)

    nonisolated struct Rule: Codable, Identifiable, Equatable, Sendable {
        let seriesId: String
        var seriesName: String
        /// Nil keeps every episode not yet watched, wherever it is in the show.
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

    /// Tops up every rule's show and learns how finished downloads were watched, as far as the
    /// server can be reached, then deletes watched episodes; offline, with what the server last
    /// said and this device's own history.
    func refresh() async {
        guard !isRefreshing else { return }
        guard openPlayers.isEmpty else {
            Self.log.info("Refresh skipped while a player is open; it runs when the player closes")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        problem = nil
        for seriesId in rules.map(\.seriesId).sorted() {
            if Task.isCancelled { return }
            do {
                try await refresh(seriesId: seriesId)
            } catch {
                // The background refresh ran out of time, or the app is closing.
                if error.isCancellation { return }
                if Self.isOffline(error) { continue }
                let name = rule(for: seriesId)?.seriesName ?? "a show"
                problem = "Couldn't update downloads for \(name): \(error.localizedDescription)"
                Self.log.error("Refresh of \(seriesId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            try await refreshWatchState()
        } catch {
            if error.isCancellation { return }
            if !Self.isOffline(error) {
                problem = "Couldn't check which downloads were watched: \(error.localizedDescription)"
                Self.log.error("Watch state refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
        // A player opened while the server was answering could be playing one of them.
        guard openPlayers.isEmpty else { return }
        // An episode watched since it was queued isn't ahead of where the show is watched any more.
        downloads.dropWatchedEpisodes(ofShows: Set(rules.map(\.seriesId)))
        if settings.deleteWatchedEpisodes { downloads.deleteWatchedEpisodes() }
    }

    private func refresh(seriesId: String) async throws {
        guard let client = accounts.client, let account = accounts.account, let rule = rule(for: seriesId) else { return }
        let show = try await show(seriesId, client: client, userId: account.userId)
        let wanted = SmartDownloadPlanner.episodesToDownload(show.states, nextUpId: show.nextUpId, count: rule.episodesAhead)
        _ = try await queue(wanted, startedByUser: seriesSetUpByUser.contains(seriesId), client: client, userId: account.userId)
        seriesSetUpByUser.remove(seriesId)
    }

    /// Queues the next `count` episodes to watch of a show, once, as Siri and Shortcuts ask.
    /// Returns the episodes it queued: none when they're all downloaded or on their way.
    func downloadNext(_ count: Int, seriesId: String) async throws -> [JellyfinItem] {
        guard let client = accounts.client, let account = accounts.account else { throw PlaybackError.notSignedIn }
        let show = try await show(seriesId, client: client, userId: account.userId)
        let wanted = SmartDownloadPlanner.episodesToDownload(show.states, nextUpId: show.nextUpId, count: count)
        return try await queue(wanted, startedByUser: true, client: client, userId: account.userId)
    }

    /// What keeping every unwatched episode of a show would add to the downloads, by the sizes
    /// the server lists for the versions closest to the download quality, and the transcodes'
    /// estimates where none fits and Transcode When No Version Fits is on.
    func everyUnwatchedEstimate(seriesId: String) async throws -> DownloadEstimate {
        guard let client = accounts.client, let account = accounts.account else { throw PlaybackError.notSignedIn }
        let show = try await show(seriesId, client: client, userId: account.userId)
        let wanted = Set(SmartDownloadPlanner.episodesToDownload(show.states, nextUpId: show.nextUpId, count: nil))
        return DownloadEstimate(show.episodes.filter { wanted.contains($0.id) }.map { episode in
            DownloadPlanner.plan(for: episode, settings: settings)
        })
    }

    /// A show's episodes in watching order, specials left out, with how smart downloads see each
    /// and the server's next one to watch.
    private func show(_ seriesId: String, client: JellyfinClient, userId: String) async throws
        -> (episodes: [JellyfinItem], states: [SmartDownloadPlanner.Episode], nextUpId: String?) {
        let episodes = try await client.episodes(seriesId: seriesId, seasonId: nil, userId: userId, fields: "MediaSources")
            .filter { $0.parentIndexNumber != 0 }
        let nextUp = try await client.nextUp(userId: userId, seriesId: seriesId, limit: 1).items.first?.id
        let states = episodes.map { episode in
            SmartDownloadPlanner.Episode(
                id: episode.id,
                played: isPlayed(episode),
                inProgress: isInProgress(episode),
                isQueued: !downloads.jobs(forItem: episode.id).isEmpty
            )
        }
        return (episodes, states, nextUp)
    }

    /// Asks the server how every download was watched, finished or not, a page of them at a time.
    private func refreshWatchState() async throws {
        guard let client = accounts.client, let account = accounts.account else { return }
        let ids = Set(downloads.jobs.map(\.itemId)).sorted()
        for start in stride(from: 0, to: ids.count, by: Self.watchStatePage) {
            let page = Array(ids[start..<min(ids.count, start + Self.watchStatePage)])
            var query = JellyfinClient.ItemQuery(types: ["Movie", "Episode"], ids: page)
            query.limit = page.count
            downloads.recordWatchState(from: try await client.items(userId: account.userId, query).items)
        }
    }

    /// Queues each episode as the download settings say (`DownloadPlanner`), and returns the
    /// episodes it queued. The server looks each one's versions up as it's asked for its details.
    /// Throws `DownloadRefused` when the account may not download them.
    private func queue(_ ids: [String], startedByUser: Bool, client: JellyfinClient, userId: String) async throws -> [JellyfinItem] {
        var queued: [JellyfinItem] = []
        for id in ids {
            let detail = try await client.item(id: id, userId: userId)
            guard let plan = DownloadPlanner.plan(for: detail, settings: settings) else { continue }
            if let refusal = await downloads.transcodes.refusal(for: plan) { throw DownloadRefused(message: refusal) }
            downloads.enqueue(detail, plan: plan, startedByUser: startedByUser)
            queued.append(detail)
        }
        return queued
    }

    /// Item ids per request, which keeps its address well under what servers accept.
    private static let watchStatePage = 100

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
        /// Partway through, as when picking a watched episode up again.
        let inProgress: Bool
        /// Has a download in any state.
        let isQueued: Bool
    }

    /// The episodes to queue: `count` episodes from the next one to watch, which is the server's
    /// next-up episode, or else the one after the last watched; a next-up episode finished here
    /// before the server heard about it is passed over. Without a count, every episode not yet
    /// watched, skipped ones before it too.
    static func episodesToDownload(_ episodes: [Episode], nextUpId: String?, count: Int?) -> [String] {
        guard let count else { return episodes.filter { !$0.isQueued && !$0.isFinished }.map(\.id) }
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
        let end = min(episodes.count, start + max(0, count))
        return episodes[start..<end].filter { !$0.isQueued && !$0.isFinished }.map(\.id)
    }
}

nonisolated extension SmartDownloadPlanner.Episode {
    /// Watched and not being watched again.
    var isFinished: Bool { played && !inProgress }
}
