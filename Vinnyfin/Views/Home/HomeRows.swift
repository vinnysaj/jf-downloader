import Foundation

/// A row of Home: the list it samples, which its title opens in full.
nonisolated struct HomeRow: Identifiable, Hashable, Sendable {
    let id: String
    let list: BrowseList
}

/// Random numbers that come out the same from the same seed (SplitMix64), so rows picked at
/// random stay put each time Home reloads, until a refresh asks for new ones.
nonisolated struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// How many titles of a kind have a genre.
nonisolated struct GenreSize: Hashable, Sendable {
    let name: String
    let count: Int
}

/// Home's rows, in order: what's in progress and what's new first; then, mixed together, rows
/// from what was watched and liked, the best and newest, and the genres watched most; and at the
/// end a row for each remaining genre big enough to fill one.
nonisolated enum HomeRows {
    /// Titles a row samples.
    static let rowLength = 20
    /// Genres with fewer titles of a kind get no row for it.
    static let minimumGenreSize = 6
    static let becauseYouWatchedCount = 3
    static let moreLikeFavoritesCount = 2

    static let continueWatching = row("continueWatching", "Continue Watching", .resume, style: .landscape)
    static let nextUp = row("nextUp", "Next Up", .nextUp, style: .landscape)
    static let recentMovies = row("recentMovies", "Recently Added Movies", .items(.recentlyAddedMovies))
    static let recentShows = row("recentShows", "Recently Added Shows", .items(.recentlyAddedShows))
    static let newMovies = row("newMovies", "New Releases", .items(query(["Movie"], sortBy: "PremiereDate")))
    static let newShows = row("newShows", "New Shows", .items(query(["Series"], sortBy: "PremiereDate")))
    static let topMovies = row("topMovies", "Top Rated Movies", .items(query(["Movie"], sortBy: "CommunityRating")))
    static let topShows = row("topShows", "Top Rated Shows", .items(query(["Series"], sortBy: "CommunityRating")))
    static let favorites = row("favorites", "Favorites", .items(query(["Movie", "Series"], sortBy: "SortName", ascending: true) {
        $0.isFavorite = true
    }))
    static let unwatchedFavorites = row("unwatchedFavorites", "Unwatched Favorites", .items(query(["Movie", "Series"], sortBy: "SortName", ascending: true) {
        $0.isFavorite = true
        $0.isPlayed = false
    }))
    static let collections = row("collections", "Collections", .items(query(["BoxSet"], sortBy: "SortName", ascending: true)))
    static let recentlyWatched = row("recentlyWatched", "Recently Watched", .items(query(["Movie", "Episode"], sortBy: "DatePlayed") {
        $0.isPlayed = true
    }), style: .landscape)

    static func becauseYouWatched(_ title: JellyfinItem) -> HomeRow {
        row("becauseYouWatched.\(title.id)", "Because You Watched \(title.name)", .similar(toItemId: title.id))
    }

    static func moreLike(_ favorite: JellyfinItem) -> HomeRow {
        row("moreLike.\(favorite.id)", "More Like \(favorite.name)", .similar(toItemId: favorite.id))
    }

    /// The best of a genre, for movies or for shows.
    static func genre(_ name: String, type: String) -> HomeRow {
        row("genre.\(type).\(name)", "\(name) \(type == "Movie" ? "Movies" : "Shows")", .items(query([type], sortBy: "CommunityRating") {
            $0.genres = [name]
        }))
    }

    /// The best of a genre not yet watched, movies and shows together.
    static func somethingDifferent(_ genre: String) -> HomeRow {
        row("somethingDifferent.\(genre)", "Something Different: \(genre)", .items(query(["Movie", "Series"], sortBy: "CommunityRating") {
            $0.genres = [genre]
            $0.isPlayed = false
        }))
    }

    /// What the rows are made from.
    struct Inputs: Sendable {
        /// Movies and shows watched, newest first, with their genres.
        var watched: [JellyfinItem] = []
        var favorites: [JellyfinItem] = []
        var movieGenres: [GenreSize] = []
        var showGenres: [GenreSize] = []
    }

    static func assemble(_ inputs: Inputs, using random: inout some RandomNumberGenerator) -> [HomeRow] {
        let anchors = inputs.watched.prefix(becauseYouWatchedCount)
        let anchorIds = Set(anchors.map(\.id))
        var becauseRows = anchors.map(becauseYouWatched)
        var favoriteRows = inputs.favorites.filter { !anchorIds.contains($0.id) }.shuffled(using: &random)
            .prefix(moreLikeFavoritesCount).map(moreLike)
        var genreRows = rankedGenres(inputs).map { genre($0.name, type: $0.type) }
        let different = differentGenre(inputs, using: &random).map(somethingDifferent)

        var rows = [continueWatching, nextUp, recentMovies, recentShows]
        func take(_ queue: inout [HomeRow]) {
            if !queue.isEmpty { rows.append(queue.removeFirst()) }
        }
        take(&becauseRows)
        take(&genreRows)
        rows.append(newMovies)
        take(&becauseRows)
        take(&genreRows)
        rows.append(topMovies)
        if !inputs.favorites.isEmpty { rows.append(favorites) }
        take(&becauseRows)
        take(&genreRows)
        rows += [newShows, topShows]
        take(&favoriteRows)
        if !inputs.favorites.isEmpty { rows.append(unwatchedFavorites) }
        if let different { rows.append(different) }
        take(&genreRows)
        rows.append(collections)
        take(&favoriteRows)
        rows.append(recentlyWatched)
        return rows + genreRows
    }

    /// Every genre big enough for a row, for movies and for shows: those of the most titles
    /// watched first, then the biggest.
    static func rankedGenres(_ inputs: Inputs) -> [(name: String, type: String)] {
        let affinity = affinity(of: inputs.watched)
        let candidates = inputs.movieGenres.map { ($0, "Movie") } + inputs.showGenres.map { ($0, "Series") }
        return candidates
            .filter { $0.0.count >= minimumGenreSize }
            .sorted { left, right in
                let leftScore = affinity[left.0.name, default: 0], rightScore = affinity[right.0.name, default: 0]
                if leftScore != rightScore { return leftScore > rightScore }
                if left.0.count != right.0.count { return left.0.count > right.0.count }
                return (left.0.name, left.1) < (right.0.name, right.1)
            }
            .map { (name: $0.0.name, type: $0.1) }
    }

    /// A genre, picked at random, of the least watched among those big enough for a row.
    static func differentGenre(_ inputs: Inputs, using random: inout some RandomNumberGenerator) -> String? {
        let affinity = affinity(of: inputs.watched)
        var sizes: [String: Int] = [:]
        for genre in inputs.movieGenres + inputs.showGenres { sizes[genre.name, default: 0] += genre.count }
        let candidates = sizes.filter { $0.value >= minimumGenreSize }.keys.sorted()
        guard let least = candidates.map({ affinity[$0, default: 0] }).min() else { return nil }
        return candidates.filter { affinity[$0, default: 0] == least }.randomElement(using: &random)
    }

    /// How many of the titles watched have each genre.
    static func affinity(of watched: [JellyfinItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for title in watched {
            for genre in Set(title.genres ?? []) { counts[genre, default: 0] += 1 }
        }
        return counts
    }

    /// The movies and shows behind what was played, newest first and each once: an episode
    /// stands for its show, looked up in `shows`.
    static func titles(played: [JellyfinItem], shows: [JellyfinItem]) -> [JellyfinItem] {
        let showsById = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return played.compactMap { item in
            let title = item.isEpisode ? showsById[item.titleId] : item
            guard let title, seen.insert(title.id).inserted else { return nil }
            return title
        }
    }

    private static func row(_ id: String, _ title: String, _ source: JellyfinClient.ItemSource,
                            style: BrowseList.Style = .poster) -> HomeRow {
        HomeRow(id: id, list: BrowseList(title: title, source: source, style: style))
    }

    /// A row's query: newest, best or last first unless `ascending`.
    private static func query(_ types: [String], sortBy: String, ascending: Bool = false,
                              _ refine: (inout JellyfinClient.ItemQuery) -> Void = { _ in }) -> JellyfinClient.ItemQuery {
        var query = JellyfinClient.ItemQuery(types: types)
        query.sortBy = sortBy
        query.ascending = ascending
        query.fields = JellyfinClient.cardFields
        refine(&query)
        return query
    }
}
