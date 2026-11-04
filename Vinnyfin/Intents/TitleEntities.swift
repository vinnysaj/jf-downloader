#if !os(tvOS)
import AppIntents
import Foundation

/// A show on the signed-in server, for Siri and Shortcuts.
nonisolated struct ShowEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Show", numericFormat: "\(placeholder: .int) shows")
    static let defaultQuery = ShowQuery()

    let id: String
    let name: String
    let year: Int?
    let poster: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: year.map { "\(String($0))" }, image: poster.map { .init(url: $0) })
    }
}

/// A movie on the signed-in server, for Siri and Shortcuts.
nonisolated struct MovieEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie", numericFormat: "\(placeholder: .int) movies")
    static let defaultQuery = MovieQuery()

    let id: String
    let name: String
    let year: Int?
    let poster: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: year.map { "\(String($0))" }, image: poster.map { .init(url: $0) })
    }
}

/// Finds shows by name and by id, and suggests the ones being watched.
struct ShowQuery: EntityStringQuery {
    @Dependency private var accounts: AccountStore

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

nonisolated extension ShowEntity {
    init(_ item: JellyfinItem, session: ServerSession) {
        self.init(id: item.id, name: item.name, year: item.productionYear, poster: session.poster(item, width: ServerTitles.posterWidth))
    }
}

nonisolated extension MovieEntity {
    init(_ item: JellyfinItem, session: ServerSession) {
        self.init(id: item.id, name: item.name, year: item.productionYear, poster: session.poster(item, width: ServerTitles.posterWidth))
    }
}

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
        var query = JellyfinClient.ItemQuery(types: [type])
        query.searchTerm = term
        query.limit = searchLimit
        return try await session.client.items(userId: session.userId, query).items
    }
}
#endif
