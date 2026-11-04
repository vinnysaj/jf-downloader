import Foundation
import Observation

/// Home's rows and their titles. One round of requests fills the banner and the first rows and
/// says what the rest are; each of the rest loads as it comes near the screen, a few at a time.
@MainActor @Observable
final class HomeFeed {
    /// Requests at once for rows coming on screen.
    static let width = 3
    /// Rows past the last one on screen to load ahead of scrolling.
    static let lookahead = 2

    private(set) var rows: [HomeRow] = []
    /// Each row's titles, once loaded; empty rows aren't shown.
    private(set) var items: [HomeRow.ID: [JellyfinItem]] = [:]
    /// Why a row couldn't load.
    private(set) var problems: [HomeRow.ID: String] = [:]
    /// The titles the banner turns through.
    private(set) var featured: [JellyfinItem] = []
    private(set) var isLoading = false
    /// Why Home couldn't load, when the server can't be reached.
    private(set) var loadError: String?
    /// The server turned the saved sign-in away (HTTP 401), so retrying won't help.
    private(set) var sessionEnded = false

    @ObservationIgnored private var session: ServerSession?
    /// Picks the rows chosen at random; the same from one load to the next.
    @ObservationIgnored private var randomSeed = UInt64.random(in: .min ... .max)
    /// How many views of each row are on screen; a row's view is replaced as it loads, and the
    /// old one can go after the new one comes.
    @ObservationIgnored private var onScreen: [HomeRow.ID: Int] = [:]
    /// Rows kept through a refresh, shown until they load again.
    @ObservationIgnored private var stale: Set<HomeRow.ID> = []
    @ObservationIgnored private lazy var queue = LoadQueue<HomeRow.ID>(width: Self.width) { [weak self] id in
        await self?.loadRow(id)
    }

    /// Loads Home again, as it comes back on screen to show what changed, or with new rows
    /// picked at random when `reshuffling`.
    func load(session: ServerSession, reshuffling: Bool = false) async {
        self.session = session
        if reshuffling { randomSeed = .random(in: .min ... .max) }
        isLoading = true
        defer { isLoading = false }
        let client = session.client
        let userId = session.userId
        func seed(_ row: HomeRow, fields: String) async throws -> [JellyfinItem] {
            guard case .items(var query) = row.list.source else { return [] }
            query.fields = fields
            return try await client.page(of: .items(query), userId: userId, startIndex: 0, limit: HomeRows.rowLength).items
        }
        do {
            // The banner shows overviews, so the rows it picks from come with them.
            async let resume = client.resumeItems(userId: userId, limit: HomeRows.rowLength)
            async let nextUp = client.nextUp(userId: userId, limit: HomeRows.rowLength)
            async let movies = seed(HomeRows.recentMovies, fields: JellyfinClient.listFields)
            async let shows = seed(HomeRows.recentShows, fields: JellyfinClient.listFields)
            async let favorites = seed(HomeRows.favorites, fields: JellyfinClient.cardFields)
            async let watched = Self.recentlyWatched(client: client, userId: userId)
            async let movieGenres = client.genres(userId: userId, types: ["Movie"], withCounts: true)
            async let showGenres = client.genres(userId: userId, types: ["Series"], withCounts: true)
            let seeded: [HomeRow.ID: [JellyfinItem]] = try await [
                HomeRows.continueWatching.id: resume.items,
                HomeRows.nextUp.id: nextUp.items,
                HomeRows.recentMovies.id: movies,
                HomeRows.recentShows.id: shows,
                HomeRows.favorites.id: favorites,
                HomeRows.recentlyWatched.id: watched.played,
            ]
            let inputs = try await HomeRows.Inputs(
                watched: watched.titles,
                favorites: favorites,
                movieGenres: movieGenres.compactMap { genre in genre.movieCount.map { GenreSize(name: genre.name, count: $0) } },
                showGenres: showGenres.compactMap { genre in genre.seriesCount.map { GenreSize(name: genre.name, count: $0) } }
            )
            var random = SeededRandom(seed: randomSeed)
            let rows = HomeRows.assemble(inputs, using: &random)
            let ids = Set(rows.map(\.id))
            queue.cancelAll()
            stale = Set(items.keys).intersection(ids).subtracting(seeded.keys)
            items = items.filter { stale.contains($0.key) }.merging(seeded) { _, new in new }
            problems = [:]
            self.rows = rows
            let inProgress = seeded[HomeRows.continueWatching.id, default: []].filter { !$0.isEpisode }
            featured = Self.featured(from: inProgress + seeded[HomeRows.recentMovies.id, default: []] + seeded[HomeRows.recentShows.id, default: []])
            loadError = nil
            sessionEnded = false
            schedule()
        } catch JellyfinError.http(status: 401, _) {
            sessionEnded = true
        } catch {
            if !error.isCancellation { loadError = error.localizedDescription }
        }
    }

    func rowAppeared(_ id: HomeRow.ID) {
        onScreen[id, default: 0] += 1
        schedule()
    }

    func rowDisappeared(_ id: HomeRow.ID) {
        onScreen[id, default: 0] -= 1
        if onScreen[id, default: 0] <= 0 { onScreen[id] = nil }
        schedule()
    }

    func retry(_ id: HomeRow.ID) {
        problems[id] = nil
        schedule()
    }

    /// Swaps in a title whose watch state changed, wherever it shows.
    func replace(_ item: JellyfinItem) {
        for (id, titles) in items {
            if let position = titles.firstIndex(where: { $0.id == item.id }) { items[id]?[position] = item }
        }
        if let position = featured.firstIndex(where: { $0.id == item.id }) { featured[position] = item }
    }

    /// Loads the rows on screen and the next few below them, and stops loading those gone.
    private func schedule() {
        let positions = rows.indices.filter { onScreen[rows[$0].id] != nil }
        guard let first = positions.min(), let last = positions.max() else {
            queue.retain { _ in false }
            return
        }
        let near = rows[first...min(rows.count - 1, last + Self.lookahead)].map(\.id)
        let nearIds = Set(near)
        queue.retain { nearIds.contains($0) }
        queue.want(near.filter { (items[$0] == nil || stale.contains($0)) && problems[$0] == nil })
    }

    private func loadRow(_ id: HomeRow.ID) async {
        guard let session, let row = rows.first(where: { $0.id == id }) else { return }
        do {
            let page = try await session.client.page(of: row.list.source, userId: session.userId, startIndex: 0, limit: HomeRows.rowLength)
            items[id] = page.items
            stale.remove(id)
        } catch {
            guard !error.isCancellation else { return }
            problems[id] = error.localizedDescription
        }
    }

    /// What was watched last, for its row, and the movies and shows behind it, with their
    /// genres, for the rows made from them.
    private static func recentlyWatched(client: JellyfinClient, userId: String) async throws -> (played: [JellyfinItem], titles: [JellyfinItem]) {
        guard case .items(var query) = HomeRows.recentlyWatched.list.source else { return ([], []) }
        query.fields = "Genres"
        let played = try await client.page(of: .items(query), userId: userId, startIndex: 0, limit: HomeRows.rowLength).items
        // An episode's own genres are usually empty; its show's say what it is.
        var showIds: [String] = []
        for item in played where item.isEpisode && !showIds.contains(item.titleId) { showIds.append(item.titleId) }
        var shows: [JellyfinItem] = []
        if !showIds.isEmpty {
            var showQuery = JellyfinClient.ItemQuery(types: ["Series"])
            showQuery.ids = showIds
            showQuery.fields = "Genres"
            shows = try await client.items(userId: userId, showQuery).items
        }
        return (played, HomeRows.titles(played: played, shows: shows))
    }

    /// Up to six titles with a backdrop for the banner, each once.
    private static func featured(from candidates: [JellyfinItem]) -> [JellyfinItem] {
        var seen = Set<String>()
        return candidates.filter { $0.backdropImageTags?.isEmpty == false && seen.insert($0.id).inserted }.prefix(6).map(\.self)
    }
}
