#if !os(tvOS)
import AppIntents
import CoreSpotlight
import CryptoKit
import Foundation
import Observation
import OSLog

/// Keeps the signed-in server's movies, shows and episodes in Spotlight, as the entities Siri
/// and Shortcuts know them by, so the Home Screen's search finds them and opens their pages.
///
/// A library of up to `SpotlightPlan.limit` movies, shows and episodes goes in whole; a bigger
/// one, the part someone is likely to look for (see `SpotlightPlan`). Each pass asks the server
/// for that part, a page at a time, and writes only the entries that changed since the last pass
/// and deletes the ones gone, by the fingerprints kept in `SpotlightLedger`. Passes run while the
/// app is open, once a day, at once for a new sign-in, and when Spotlight asks for its entries
/// again. Signing out, or into another server or user, deletes every entry.
///
/// Entries are deleted by the ids the ledger lists, never in bulk: Core Spotlight's bulk deletes
/// (every item, a domain, an entity type) delete, but their completion never came in the iOS 27.2
/// simulator, so a pass or sign-out awaiting one never finished; and they delete the whole app's
/// items, whichever index they're asked of. The ledger is saved after every batch written or
/// deleted, so it lists what Spotlight holds even when a pass stops partway.
///
/// Spotlight keeps its index itself, outside the app; the ledger is a file in the app's own
/// container.
@Observable
final class SpotlightTitles {
    /// What Spotlight holds, for Settings.
    nonisolated struct Status: Equatable, Sendable {
        let serverId: String
        let userId: String
        let plan: SpotlightPlan
        let counts: [SpotlightEntity.Kind: Int]
        let refreshedAt: Date

        /// "12 movies, 4 shows and 1 episode".
        var summary: String {
            let parts: [(SpotlightEntity.Kind, String, String)] = [(.movie, "movie", "movies"), (.show, "show", "shows"), (.episode, "episode", "episodes")]
            return parts.map { kind, one, many in
                let count = counts[kind] ?? 0
                return "\(count.formatted()) \(count == 1 ? one : many)"
            }
            .formatted(.list(type: .and))
        }
    }

    /// A day: the server's titles change slowly, and Spotlight is for finding them, not for
    /// what's new this hour. A sign-in doesn't wait for it.
    nonisolated static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// How often, while the app is open, it checks whether a pass is due.
    nonisolated static let checkInterval: Duration = .seconds(60 * 60)
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "spotlight")

    private(set) var status: Status?
    private(set) var isUpdating = false
    /// Why Spotlight couldn't be brought up to date, to show until dismissed or the next pass
    /// succeeds.
    var problem: String?

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var ledger: SpotlightLedger?
    @ObservationIgnored private var passing: Task<Void, any Error>?

    init(accounts: AccountStore, downloads: DownloadManager,
         file: URL = URL.applicationSupportDirectory.appending(path: "Spotlight.json")) {
        self.accounts = accounts
        self.downloads = downloads
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let ledger = try JSONDecoder().decode(SpotlightLedger.self, from: Data(contentsOf: file))
            self.ledger = ledger
            status = Self.status(of: ledger)
        } catch {
            // The next pass writes the titles it finds again, over their old entries; entries for
            // titles it no longer finds stay until the app is deleted.
            Self.log.error("Couldn't read the Spotlight ledger: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Follows who is signed in for the life of the app: deletes every entry when nobody is, or
    /// someone else is, than the entries are for, and brings Spotlight up to date for a new sign-in.
    /// A deletion that failed is tried again at the next launch, or from Settings.
    func run() async {
        let accounts = accounts
        for await key in Observations({ accounts.account.map(SpotlightLedger.AccountKey.init) }) {
            guard key != ledger?.account else { continue }
            await wipe(for: key)
            if key != nil { await refresh(force: false) }
        }
    }

    /// Brings Spotlight up to date whenever a pass is due, while the calling task lasts: the
    /// root view's, while the app is open. Leaving the foreground cancels a pass under way.
    func refreshWhileOpen() async {
        while !Task.isCancelled {
            if isDue() { await refresh(force: false) }
            try? await Task.sleep(for: Self.checkInterval)
        }
    }

    /// Brings Spotlight up to date now, due or not, deleting first the entries of whoever was
    /// signed in before when that failed.
    func refreshNow() async {
        let key = accounts.account.map(SpotlightLedger.AccountKey.init)
        if key != ledger?.account { await wipe(for: key) }
        await refresh(force: true)
    }

    /// Writes a kind's entries again, those of `ids` or all of them, for Spotlight, which asks
    /// when it lost them.
    func reindex(_ kind: SpotlightEntity.Kind, ids: [String]?) async throws {
        try await pass(force: true) { ledger in ledger.forget(kind, ids: ids) }
    }

    private func isDue(now: Date = .now) -> Bool {
        guard let key = accounts.account.map(SpotlightLedger.AccountKey.init) else { return false }
        guard let ledger, ledger.account == key, let refreshedAt = ledger.refreshedAt else { return true }
        return now.timeIntervalSince(refreshedAt) >= Self.refreshInterval
    }

    private func refresh(force: Bool) async {
        do {
            try await pass(force: force) { _ in }
        } catch {
            // Already said, in `problem`.
        }
    }

    /// Runs one pass at a time: waits for the one under way, then runs unless it did what was
    /// due. `prepare` changes the ledger first, as of when the pass starts.
    private func pass(force: Bool, prepare: @escaping @MainActor (inout SpotlightLedger) -> Void) async throws {
        while let running = passing { _ = await running.result }
        guard force || isDue() else { return }
        // Lets go of `passing` before the pass's waiters resume.
        let task = Task {
            defer { self.passing = nil }
            try await self.performPass(prepare: prepare)
        }
        passing = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            guard !error.isCancellation else { return }
            Self.log.error("Spotlight pass failed: \(error.localizedDescription, privacy: .public)")
            problem = "Couldn't bring Spotlight up to date: \(error.localizedDescription)"
            throw error
        }
    }

    private func performPass(prepare: (inout SpotlightLedger) -> Void) async throws {
        guard let session = accounts.session else { return }
        let key = SpotlightLedger.AccountKey(session.account)
        guard ledger?.account == key else { return }
        try record(prepare)
        isUpdating = true
        defer { isUpdating = false }
        let started = ContinuousClock.now

        let counts = try await titleCounts(session: session)
        try ensureCurrent(key)
        let plan = SpotlightPlan(titles: counts.titles, episodes: counts.episodes)
        let entries = Array(try await gather(plan, session: session, key: key).values)
        let fingerprints = SpotlightLedger.byKind(entries.map { ($0.entity.kind, $0.entity.id, $0.fingerprint) })
        let changes = SpotlightLedger.Changes(from: ledger?.fingerprints ?? [:], to: fingerprints)
        try await write(entries.filter { changes.writes[$0.entity.kind]?.contains($0.entity.id) == true })
        try ensureCurrent(key)
        try await delete(changes.deletions)
        try ensureCurrent(key)

        try record { ledger in
            ledger.plan = plan
            ledger.refreshedAt = .now
        }
        status = ledger.flatMap(Self.status(of:))
        problem = nil
        let written = changes.writes.values.reduce(0) { $0 + $1.count }
        let deleted = changes.deletions.values.reduce(0) { $0 + $1.count }
        Self.log.notice("""
            Spotlight pass (\(plan.rawValue, privacy: .public)) of \(counts.titles) titles and \(counts.episodes) episodes: \
            \(entries.count) entries, \(written) written, \(deleted) deleted, in \(ContinuousClock.now - started, privacy: .public)
            """)
    }

    /// Deletes every entry the ledger lists and starts it over for `key`, or for nobody. When a
    /// deletion fails, the ledger keeps listing what's left, under its account, for the next try.
    private func wipe(for key: SpotlightLedger.AccountKey?) async {
        while let running = passing {
            running.cancel()
            _ = await running.result
        }
        do {
            let count = ledger?.fingerprints.values.reduce(0) { $0 + $1.count } ?? 0
            if let ledger { try await delete(ledger.fingerprints.mapValues { $0.keys.sorted() }) }
            let fresh = key.map { SpotlightLedger(account: $0) }
            if let fresh { try save(fresh) } else if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            ledger = fresh
            status = nil
            problem = nil
            Self.log.notice("Deleted the \(count) Spotlight entries of the last sign-in")
        } catch {
            Self.log.error("Couldn't delete the Spotlight entries: \(error.localizedDescription, privacy: .public)")
            problem = "Couldn't take the last server's titles out of Spotlight: \(error.localizedDescription)"
        }
    }

    /// Changes the ledger and saves it.
    private func record(_ change: (inout SpotlightLedger) -> Void) throws {
        guard var ledger else { return }
        change(&ledger)
        try save(ledger)
        self.ledger = ledger
    }

    /// Stops a pass whose account is no longer the one signed in.
    private func ensureCurrent(_ key: SpotlightLedger.AccountKey) throws {
        guard accounts.account.map(SpotlightLedger.AccountKey.init) == key else { throw CancellationError() }
    }

    // MARK: Gathering

    private func titleCounts(session: ServerSession) async throws -> (titles: Int, episodes: Int) {
        async let titles = session.client.count(userId: session.userId, JellyfinClient.ItemQuery(types: ["Movie", "Series"]))
        async let episodes = session.client.count(userId: session.userId, JellyfinClient.ItemQuery(types: ["Episode"]))
        return try await (titles, episodes)
    }

    /// The entries the plan puts in Spotlight, by id: what's being watched and downloaded in
    /// any library, then the whole library or the part of it the plan keeps.
    private func gather(_ plan: SpotlightPlan, session: ServerSession, key: SpotlightLedger.AccountKey) async throws -> [String: SpotlightEntry] {
        var entries: [String: SpotlightEntry] = [:]
        func add(_ items: [JellyfinItem], priority: Int) {
            for item in items {
                guard let entry = SpotlightEntry(item, priority: priority, session: session) else { continue }
                entries[item.id] = entries[item.id]?.raised(to: entry.priority) ?? entry
            }
        }

        let client = session.client
        let userId = session.userId
        let resume = try await client.resumeItems(userId: userId, limit: SpotlightPlan.inProgressLimit).items
        let nextUp = try await client.nextUp(userId: userId, limit: SpotlightPlan.inProgressLimit).items
        try ensureCurrent(key)
        add(resume + nextUp, priority: SpotlightEntry.watchingPriority)
        let jobs = downloads.jobs
        let downloadedIds = jobs.map(\.itemId)
        let watchedShowIds = (resume + nextUp).compactMap(\.seriesId) + jobs.compactMap(\.seriesId)

        switch plan {
        case .everything:
            add(try await allItems(SpotlightPlan.query(["Movie", "Series"]), session: session), priority: 0)
            try ensureCurrent(key)
            add(try await allItems(SpotlightPlan.query(["Episode"]), session: session), priority: 0)
        case .allTitles:
            add(try await allItems(SpotlightPlan.query(["Movie", "Series"]), session: session), priority: 0)
        case .personal:
            var favourites = SpotlightPlan.query(["Movie", "Series"])
            favourites.isFavorite = true
            add(try await allItems(favourites, limit: SpotlightPlan.favouriteLimit, session: session), priority: 0)
            try ensureCurrent(key)
            var watched = SpotlightPlan.query(["Movie", "Series"])
            watched.isPlayed = true
            watched.sortBy = "DatePlayed"
            watched.ascending = false
            add(try await allItems(watched, limit: SpotlightPlan.watchedLimit, session: session), priority: 0)
            try ensureCurrent(key)
            for newest in [JellyfinClient.ItemQuery.recentlyAddedMovies, .recentlyAddedShows] {
                var query = newest
                query.fields = SpotlightPlan.fields
                add(try await allItems(query, limit: SpotlightPlan.recentLimit, session: session), priority: SpotlightEntry.watchedPriority)
            }
        }
        try ensureCurrent(key)

        // The shows of what's being watched or downloaded, and downloads, that aren't in yet.
        let missingShows = Array(Set(watchedShowIds).subtracting(entries.keys)).sorted()
        add(try await items(ids: missingShows, types: ["Series"], session: session), priority: SpotlightEntry.watchingPriority)
        let missingDownloads = Array(Set(downloadedIds).subtracting(entries.keys)).sorted()
        add(try await items(ids: missingDownloads, types: ["Movie", "Episode"], session: session), priority: SpotlightEntry.watchingPriority)
        for id in Set(downloadedIds).union(watchedShowIds) {
            entries[id] = entries[id]?.raised(to: SpotlightEntry.watchingPriority)
        }
        return entries
    }

    /// Every item the query finds, or the first `limit`, a page at a time.
    private func allItems(_ query: JellyfinClient.ItemQuery, limit: Int? = nil, session: ServerSession) async throws -> [JellyfinItem] {
        var items: [JellyfinItem] = []
        var query = query
        var total: Int?
        while let page = SpotlightPlan.nextPage(loaded: items.count, total: total, limit: limit) {
            query.startIndex = page.lowerBound
            query.limit = page.count
            let result = try await session.client.items(userId: session.userId, query)
            items += result.items
            total = result.items.isEmpty ? items.count : result.totalRecordCount
        }
        return items
    }

    /// The items of `ids`, asked for a page of ids at a time so the address stays short.
    private func items(ids: [String], types: [String], session: ServerSession) async throws -> [JellyfinItem] {
        var items: [JellyfinItem] = []
        for start in stride(from: 0, to: ids.count, by: SpotlightPlan.idsPerRequest) {
            var query = SpotlightPlan.query(types)
            query.ids = Array(ids[start..<min(ids.count, start + SpotlightPlan.idsPerRequest)])
            items += try await session.client.items(userId: session.userId, query).items
        }
        return items
    }

    // MARK: Writing

    /// Writes the entries a batch at a time, of one kind and rank each, and records each batch.
    private func write(_ entries: [SpotlightEntry]) async throws {
        for kind in SpotlightEntity.Kind.allCases {
            let ofKind = entries.filter { $0.entity.kind == kind }
            for priority in Set(ofKind.map(\.priority)).sorted(by: >) {
                let ranked = ofKind.filter { $0.priority == priority }
                for start in stride(from: 0, to: ranked.count, by: SpotlightPlan.writeBatch) {
                    let batch = ranked[start..<min(ranked.count, start + SpotlightPlan.writeBatch)]
                    try await SpotlightIndex.write(batch.map(\.entity), of: kind, priority: priority)
                    try record { ledger in
                        for entry in batch { ledger.fingerprints[kind, default: [:]][entry.entity.id] = entry.fingerprint }
                    }
                    try Task.checkCancellation()
                }
            }
        }
    }

    /// Deletes the entries a batch at a time, and records each batch.
    private func delete(_ deletions: [SpotlightEntity.Kind: [String]]) async throws {
        for (kind, ids) in deletions {
            for start in stride(from: 0, to: ids.count, by: SpotlightPlan.writeBatch) {
                let batch = Array(ids[start..<min(ids.count, start + SpotlightPlan.writeBatch)])
                try await SpotlightIndex.delete(batch, of: kind)
                try record { ledger in
                    for id in batch { ledger.fingerprints[kind]?[id] = nil }
                }
            }
        }
    }

    private func save(_ ledger: SpotlightLedger) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
    }

    private static func status(of ledger: SpotlightLedger) -> Status? {
        guard let plan = ledger.plan, let refreshedAt = ledger.refreshedAt else { return nil }
        return Status(serverId: ledger.account.serverId, userId: ledger.account.userId, plan: plan,
                      counts: ledger.fingerprints.mapValues(\.count), refreshedAt: refreshedAt)
    }
}

/// The app's entries in Spotlight's index, written and deleted off the main actor a kind at a
/// time, as Spotlight's calls take them.
nonisolated enum SpotlightIndex {
    /// Writes the entities of `kind` among `entities`.
    @concurrent
    static func write(_ entities: [SpotlightEntity], of kind: SpotlightEntity.Kind, priority: Int) async throws {
        let index = CSSearchableIndex.default()
        switch kind {
        case .movie: try await index.indexAppEntities(entities.compactMap(\.movie), priority: priority)
        case .show: try await index.indexAppEntities(entities.compactMap(\.show), priority: priority)
        case .episode: try await index.indexAppEntities(entities.compactMap(\.episode), priority: priority)
        }
    }

    @concurrent
    static func delete(_ ids: [String], of kind: SpotlightEntity.Kind) async throws {
        let index = CSSearchableIndex.default()
        switch kind {
        case .movie: try await index.deleteAppEntities(identifiedBy: ids, ofType: MovieEntity.self)
        case .show: try await index.deleteAppEntities(identifiedBy: ids, ofType: ShowEntity.self)
        case .episode: try await index.deleteAppEntities(identifiedBy: ids, ofType: EpisodeEntity.self)
        }
    }
}

/// How much of a library goes into Spotlight.
///
/// Measured in the iPhone 17 Pro simulator on iOS 27.2 (see `SpotlightBenchmarkTests`) and
/// against Jellyfin 12.4 with 18,000 titles, with a two-sentence summary each: an entry is 1.3 KB
/// handed to Spotlight, which takes about a millisecond each to index it, and 2.1 KB kept on the
/// device (1.1 KB in Spotlight's index, 1 KB in the system's store of app entities); a title is
/// 0.65 KB from the server, in pages of 500 that take about a second. Spotlight holds at most
/// 16 MB of an app's writes waiting to be indexed, and in the simulator a write past that never
/// returns, so a pass has to stay well under 12,000 entries.
///
/// At `limit`, a pass is 6.5 MB handed over, under half of that, 10 MB on the device and 3.3 MB
/// from the server in 10 pages. A whole library of 20,000 would be 26 MB handed over, 42 MB on
/// the device and 13 MB from the server every day. Past `limit`, Spotlight gets what someone is
/// likely to look for, about 2,400 entries and the downloads however big the library: what's
/// being watched and its shows, downloads, favourites, the most recently watched, and the newest.
nonisolated enum SpotlightPlan: String, Codable, Sendable {
    /// Every movie, show and episode.
    case everything
    /// Every movie and show, and the episodes being watched or downloaded.
    case allTitles
    /// What's being watched and its shows, downloads, favourites, the most recently watched
    /// titles and the newest.
    case personal

    /// The most entries a whole library, or its movies and shows alone, can have to go in whole.
    static let limit = 5_000
    /// How many of each of these the personal plan takes.
    static let favouriteLimit = 1_000
    static let watchedLimit = 1_000
    static let recentLimit = 100
    /// Resume and Next Up, which are seldom longer.
    static let inProgressLimit = 100

    static let pageSize = 500
    static let idsPerRequest = 100
    static let writeBatch = 500
    /// What an entry shows and searches beyond the fields every item comes with.
    static let fields = "Overview,Genres"

    init(titles: Int, episodes: Int) {
        if titles + episodes <= Self.limit {
            self = .everything
        } else if titles <= Self.limit {
            self = .allTitles
        } else {
            self = .personal
        }
    }

    /// Items of `types` as an entry needs them, by name.
    static func query(_ types: [String]) -> JellyfinClient.ItemQuery {
        var query = JellyfinClient.ItemQuery(types: types)
        query.fields = fields
        return query
    }

    /// The next page to ask for, after `loaded` items of a list of `total` (unknown before the
    /// first page), or of its first `limit`. Nil once there's no more.
    static func nextPage(loaded: Int, total: Int?, limit: Int?) -> Range<Int>? {
        let end = min(total ?? .max, limit ?? .max)
        guard loaded < end else { return nil }
        return loaded..<min(end, loaded + pageSize)
    }
}

/// A movie, show or episode as it goes into Spotlight.
nonisolated enum SpotlightEntity: Sendable {
    enum Kind: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
        case movie, show, episode
    }

    case movie(MovieEntity)
    case show(ShowEntity)
    case episode(EpisodeEntity)

    /// Nil for items that aren't a movie, a show or an episode.
    init?(_ item: JellyfinItem, session: ServerSession) {
        switch item.type {
        case "Movie": self = .movie(MovieEntity(item, session: session))
        case "Series": self = .show(ShowEntity(item, session: session))
        case "Episode": self = .episode(EpisodeEntity(item, session: session))
        default: return nil
        }
    }

    var kind: Kind {
        switch self {
        case .movie: .movie
        case .show: .show
        case .episode: .episode
        }
    }

    var id: String {
        switch self {
        case .movie(let movie): movie.id
        case .show(let show): show.id
        case .episode(let episode): episode.id
        }
    }

    var movie: MovieEntity? { if case .movie(let movie) = self { movie } else { nil } }
    var show: ShowEntity? { if case .show(let show) = self { show } else { nil } }
    var episode: EpisodeEntity? { if case .episode(let episode) = self { episode } else { nil } }

    /// Everything Spotlight is given about it, which changes when its entry has to be written again.
    var contents: [String?] {
        switch self {
        case .movie(let movie):
            ["movie", movie.name, movie.year.map(String.init), movie.overview, movie.genres.joined(separator: ","), movie.poster?.absoluteString]
        case .show(let show):
            ["show", show.name, show.year.map(String.init), show.overview, show.genres.joined(separator: ","), show.poster?.absoluteString]
        case .episode(let episode):
            ["episode", episode.name, episode.show, episode.code, episode.overview, episode.poster?.absoluteString]
        }
    }
}

/// An entity and how high Spotlight ranks it among the app's entries.
nonisolated struct SpotlightEntry: Sendable {
    /// Being watched, a favourite or downloaded.
    static let watchingPriority = 2
    /// Watched, or new.
    static let watchedPriority = 1

    let entity: SpotlightEntity
    let priority: Int

    init(entity: SpotlightEntity, priority: Int) {
        self.entity = entity
        self.priority = priority
    }

    /// At least `priority`, or higher for what the item's own watch state says.
    init?(_ item: JellyfinItem, priority: Int, session: ServerSession) {
        guard let entity = SpotlightEntity(item, session: session) else { return nil }
        self.init(entity: entity, priority: max(priority, Self.priority(of: item)))
    }

    static func priority(of item: JellyfinItem) -> Int {
        if item.isFavorite || item.resumeSeconds != nil { return watchingPriority }
        if item.isPlayed { return watchedPriority }
        return 0
    }

    func raised(to priority: Int) -> SpotlightEntry {
        SpotlightEntry(entity: entity, priority: max(self.priority, priority))
    }

    /// A short digest of what's written for the entry, its rank included.
    var fingerprint: String {
        let text = (entity.contents + [String(priority)]).map { $0 ?? "" }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Whose entries Spotlight holds, when they were last brought up to date, and each one's
/// fingerprint, to write only what changed.
nonisolated struct SpotlightLedger: Codable, Equatable, Sendable {
    struct AccountKey: Codable, Equatable, Sendable {
        let serverId: String
        let userId: String

        init(_ account: AccountStore.Account) {
            serverId = account.serverId
            userId = account.userId
        }
    }

    /// What a pass writes and deletes.
    struct Changes: Equatable, Sendable {
        var writes: [SpotlightEntity.Kind: Set<String>] = [:]
        var deletions: [SpotlightEntity.Kind: [String]] = [:]

        /// New and changed entries are written; entries no longer there are deleted.
        init(from previous: [SpotlightEntity.Kind: [String: String]], to next: [SpotlightEntity.Kind: [String: String]]) {
            for (kind, fingerprints) in next {
                let changed = fingerprints.filter { previous[kind]?[$0.key] != $0.value }.keys
                if !changed.isEmpty { writes[kind] = Set(changed) }
            }
            for (kind, fingerprints) in previous {
                let gone = fingerprints.keys.filter { next[kind]?[$0] == nil }.sorted()
                if !gone.isEmpty { deletions[kind] = gone }
            }
        }
    }

    let account: AccountKey
    var plan: SpotlightPlan?
    var refreshedAt: Date?
    var fingerprints: [SpotlightEntity.Kind: [String: String]] = [:]

    init(account: AccountKey) {
        self.account = account
    }

    /// Makes the next pass write the entries of `ids`, or all of a kind's, again, still listing
    /// them so a pass that no longer finds them deletes them.
    mutating func forget(_ kind: SpotlightEntity.Kind, ids: [String]?) {
        guard var ofKind = fingerprints[kind] else { return }
        for id in ids ?? Array(ofKind.keys) where ofKind[id] != nil { ofKind[id] = "" }
        fingerprints[kind] = ofKind
    }

    static func byKind(_ entries: [(SpotlightEntity.Kind, String, String)]) -> [SpotlightEntity.Kind: [String: String]] {
        var fingerprints: [SpotlightEntity.Kind: [String: String]] = [:]
        for (kind, id, fingerprint) in entries { fingerprints[kind, default: [:]][id] = fingerprint }
        return fingerprints
    }
}
#endif
