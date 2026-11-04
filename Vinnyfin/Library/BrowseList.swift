import Foundation

/// A list to browse in full, in a grid: a library, everything a Home row samples, a collection.
nonisolated struct BrowseList: Hashable, Sendable {
    enum Style: Hashable, Sendable {
        /// Posters, for movies and shows.
        case poster
        /// 16:9 stills, for episodes and what's in progress.
        case landscape
    }

    let title: String
    let source: JellyfinClient.ItemSource
    var style = Style.poster

    static let movies = BrowseList(title: "Movies", source: .items(.init(types: ["Movie"])))
    static let shows = BrowseList(title: "Shows", source: .items(.init(types: ["Series"])))

    /// What the server finds most like a title, or an episode's show.
    static func moreLike(_ item: JellyfinItem) -> BrowseList {
        BrowseList(title: "More Like \(item.titleName)", source: .similar(toItemId: item.titleId))
    }

    /// A collection's titles, oldest first.
    static func collection(_ item: JellyfinItem) -> BrowseList {
        var query = JellyfinClient.ItemQuery(types: ["Movie", "Series"])
        query.parentId = item.id
        query.sortBy = "PremiereDate"
        return BrowseList(title: item.name, source: .items(query))
    }

    /// The SF Symbol for what the list holds.
    var symbol: String {
        guard case .items(let query) = source else { return style == .landscape ? "play.rectangle" : "film" }
        switch query.types {
        case ["Series"]: return "tv"
        case ["BoxSet"]: return "square.stack"
        default: return "film"
        }
    }
}
