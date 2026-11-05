import AppIntents
import Foundation
#if !os(tvOS)
import CoreSpotlight
#endif

// Each entity is the server's item as a list gave it, with the poster Siri, Shortcuts and
// Spotlight show. Its properties are the item's, which Shortcuts offers and Siri reasons with.

/// A show on the signed-in server, for Siri, Shortcuts and Spotlight.
nonisolated struct ShowEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Show", numericFormat: "\(placeholder: .int) shows")
    static let defaultQuery = ShowQuery()

    /// The show as the server listed it; its page and the player load the rest.
    let item: JellyfinItem
    let poster: URL?

    var id: String { item.id }
    @ComputedProperty(title: "Name") var name: String { item.name }
    @ComputedProperty(title: "Year") var year: Int? { item.productionYear }
    @ComputedProperty(title: "Summary") var overview: String? { item.overview }
    @ComputedProperty(title: "Genres") var genres: [String] { item.genres ?? [] }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: year.map { "\(String($0))" }, image: poster.map { .init(url: $0) })
    }
}

/// A movie on the signed-in server, for Siri, Shortcuts and Spotlight.
nonisolated struct MovieEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie", numericFormat: "\(placeholder: .int) movies")
    static let defaultQuery = MovieQuery()

    let item: JellyfinItem
    let poster: URL?

    var id: String { item.id }
    @ComputedProperty(title: "Name") var name: String { item.name }
    @ComputedProperty(title: "Year") var year: Int? { item.productionYear }
    @ComputedProperty(title: "Summary") var overview: String? { item.overview }
    @ComputedProperty(title: "Genres") var genres: [String] { item.genres ?? [] }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: year.map { "\(String($0))" }, image: poster.map { .init(url: $0) })
    }
}

/// An episode of a show on the signed-in server, for Siri, Shortcuts and Spotlight.
nonisolated struct EpisodeEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode", numericFormat: "\(placeholder: .int) episodes")
    static let defaultQuery = EpisodeQuery()

    let item: JellyfinItem
    /// The show's, which says which show it is better than the episode's still.
    let poster: URL?

    var id: String { item.id }
    @ComputedProperty(title: "Name") var name: String { item.name }
    @ComputedProperty(title: "Show") var show: String { item.seriesName ?? "" }
    @ComputedProperty(title: "Season") var season: Int? { item.parentIndexNumber }
    @ComputedProperty(title: "Episode") var number: Int? { item.indexNumber }
    @ComputedProperty(title: "Summary") var overview: String? { item.overview }
    /// "S01E02", when the server numbers it.
    var code: String? { item.episodeCode }

    /// Its name, then which show and where in it: "Pilot", "Severance · S01E01".
    var displayRepresentation: DisplayRepresentation {
        let place = [show, code].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(name)", subtitle: "\(place)", image: poster.map { .init(url: $0) })
    }
}

nonisolated extension EntityIdentifier {
    /// The entity of a movie, show or episode, for a page to tell Siri what it shows. Nil for
    /// other items.
    static func title(_ item: JellyfinItem) -> EntityIdentifier? {
        switch item.type {
        case "Movie": EntityIdentifier(for: MovieEntity.self, identifier: item.id)
        case "Series": EntityIdentifier(for: ShowEntity.self, identifier: item.id)
        case "Episode": EntityIdentifier(for: EpisodeEntity.self, identifier: item.id)
        default: nil
        }
    }
}

nonisolated extension ShowEntity {
    init(_ item: JellyfinItem, session: ServerSession) {
        self.init(item: item, poster: session.poster(item, width: ServerTitles.posterWidth))
    }
}

nonisolated extension MovieEntity {
    init(_ item: JellyfinItem, session: ServerSession) {
        self.init(item: item, poster: session.poster(item, width: ServerTitles.posterWidth))
    }
}

nonisolated extension EpisodeEntity {
    init(_ item: JellyfinItem, session: ServerSession) {
        self.init(item: item, poster: session.seriesPoster(item, width: ServerTitles.posterWidth))
    }
}

#if !os(tvOS)
/// What Spotlight searches besides the name: the summary, the genres and, for an episode, its
/// show. The name, the year and the picture come from the display representation.
extension ShowEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = overview
        attributes.keywords = genres + ["show", "TV"]
        attributes.genre = genres.first
        return attributes
    }
}

extension MovieEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = overview
        attributes.keywords = genres + ["movie", "film"]
        attributes.genre = genres.first
        return attributes
    }
}

extension EpisodeEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = overview
        attributes.keywords = [show, code, "episode"].compactMap(\.self).filter { !$0.isEmpty }
        return attributes
    }
}
#endif

/// Finds shows by name and by id, and suggests the ones being watched.
struct ShowQuery: EntityStringQuery {
    @Dependency private var accounts: AccountStore
    #if !os(tvOS)
    @Dependency private var spotlight: SpotlightTitles
    #endif

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ShowEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.items(ids: identifiers, type: "Series", session: session).map { ShowEntity($0, session: session) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ShowEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.search(string, type: "Series", session: session).map { ShowEntity($0, session: session) }
    }

    /// The shows with a next episode to watch, else the newest.
    @MainActor
    func suggestedEntities() async throws -> [ShowEntity] {
        let session = try ServerTitles.session(accounts)
        var seriesIds: [String] = []
        for episode in try await session.client.nextUp(userId: session.userId, limit: ServerTitles.suggestionLimit).items {
            if let seriesId = episode.seriesId, !seriesIds.contains(seriesId) { seriesIds.append(seriesId) }
        }
        let shows = seriesIds.isEmpty
            ? try await ServerTitles.newest(.recentlyAddedShows, session: session)
            : try await ServerTitles.items(ids: seriesIds, type: "Series", session: session)
        return shows.map { ShowEntity($0, session: session) }
    }
}

/// Finds movies by name and by id, and suggests the newest.
struct MovieQuery: EntityStringQuery {
    @Dependency private var accounts: AccountStore
    #if !os(tvOS)
    @Dependency private var spotlight: SpotlightTitles
    #endif

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MovieEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.items(ids: identifiers, type: "Movie", session: session).map { MovieEntity($0, session: session) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MovieEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.search(string, type: "Movie", session: session).map { MovieEntity($0, session: session) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MovieEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.newest(.recentlyAddedMovies, session: session).map { MovieEntity($0, session: session) }
    }
}

/// Finds episodes by name and by id, and suggests the next ones to watch.
struct EpisodeQuery: EntityStringQuery {
    @Dependency private var accounts: AccountStore
    #if !os(tvOS)
    @Dependency private var spotlight: SpotlightTitles
    #endif

    @MainActor
    func entities(for identifiers: [String]) async throws -> [EpisodeEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.items(ids: identifiers, type: "Episode", session: session).map { EpisodeEntity($0, session: session) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [EpisodeEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.search(string, type: "Episode", session: session).map { EpisodeEntity($0, session: session) }
    }

    @MainActor
    func suggestedEntities() async throws -> [EpisodeEntity] {
        let session = try ServerTitles.session(accounts)
        return try await session.client.nextUp(userId: session.userId, limit: ServerTitles.suggestionLimit).items
            .map { EpisodeEntity($0, session: session) }
    }
}

#if !os(tvOS)
// Spotlight asks for a kind's entries again when it lost them. There is one index, so which one
// it names doesn't matter, and the description, which can't go to the main actor, stays here.

extension ShowQuery: IndexedEntityQuery {
    nonisolated func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(identifiers)
    }

    nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(nil)
    }

    private func reindex(_ ids: [String]?) async throws {
        try await spotlight.reindex(.show, ids: ids)
    }
}

extension MovieQuery: IndexedEntityQuery {
    nonisolated func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(identifiers)
    }

    nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(nil)
    }

    private func reindex(_ ids: [String]?) async throws {
        try await spotlight.reindex(.movie, ids: ids)
    }
}

extension EpisodeQuery: IndexedEntityQuery {
    nonisolated func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(identifiers)
    }

    nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(nil)
    }

    private func reindex(_ ids: [String]?) async throws {
        try await spotlight.reindex(.episode, ids: ids)
    }
}
#endif

/// The signed-in server's titles, as the entity queries ask for them.
enum ServerTitles {
    static let searchLimit = 25
    static let suggestionLimit = 20
    /// Small enough for Siri's and Shortcuts' lists.
    nonisolated static let posterWidth = 200

    static func session(_ accounts: AccountStore) throws -> ServerSession {
        guard let session = accounts.session else { throw PlaybackError.notSignedIn }
        return session
    }

    static func items(ids: [String], type: String, session: ServerSession) async throws -> [JellyfinItem] {
        guard !ids.isEmpty else { return [] }
        var query = JellyfinClient.ItemQuery(types: [type])
        query.ids = ids
        return try await session.client.items(userId: session.userId, query).items
    }

    /// The newest titles of a kind, as many as a list of suggestions shows.
    static func newest(_ query: JellyfinClient.ItemQuery, session: ServerSession) async throws -> [JellyfinItem] {
        var query = query
        query.limit = suggestionLimit
        return try await session.client.items(userId: session.userId, query).items
    }

    static func search(_ term: String, type: String, session: ServerSession) async throws -> [JellyfinItem] {
        try await search(term, types: [type], session: session)
    }

    static func search(_ term: String, types: [String], session: ServerSession) async throws -> [JellyfinItem] {
        var query = JellyfinClient.ItemQuery(types: types)
        query.searchTerm = term
        query.limit = searchLimit
        return try await session.client.items(userId: session.userId, query).items
    }
}
