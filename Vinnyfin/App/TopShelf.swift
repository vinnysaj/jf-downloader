#if os(tvOS)
import Foundation
import TVServices

/// Apple TV's Top Shelf, the row above vinnyfin on the Home Screen while it's in the top row: what's
/// up next, then what's new on the server. The Top Shelf extension asks the server for it whenever
/// the system asks; with nothing to show, the system shows the app's Top Shelf image instead.
nonisolated enum TopShelf {
    /// How many titles each row holds, and so how many the extension asks the server for.
    static let itemsPerSection = 12

    /// Has the system ask the extension again. The app calls it as it leaves the screen, since what
    /// was watched and who is signed in may have changed while it was open.
    static func reload() {
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// Up Next is what's partway through, then the next episode of each show in progress; the
    /// newest movies and shows follow. Each title shows once. Nil when there's nothing to show.
    static func content(resume: [JellyfinItem], nextUp: [JellyfinItem], latestMovies: [JellyfinItem],
                        latestShows: [JellyfinItem], session: ServerSession) -> TVTopShelfSectionedContent? {
        var shown = Set<String>()
        func unshown(_ items: [JellyfinItem]) -> [JellyfinItem] {
            Array(items.filter { shown.insert($0.id).inserted }.prefix(itemsPerSection))
        }
        let sections = [
            section("Up Next", unshown(resume + nextUp), shape: .hdtv, session: session),
            section("Recently Added Movies", unshown(latestMovies), shape: .poster, session: session),
            section("Recently Added Shows", unshown(latestShows), shape: .poster, session: session),
        ].compactMap(\.self)
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    private static func section(_ title: String, _ items: [JellyfinItem], shape: TVTopShelfSectionedItem.ImageShape,
                                session: ServerSession) -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? {
        guard !items.isEmpty else { return nil }
        let section = TVTopShelfItemCollection(items: items.map { shelfItem(for: $0, shape: shape, session: session) })
        section.title = title
        return section
    }

    /// Selecting the item opens its page; the play button plays it, when it's something to play.
    private static func shelfItem(for item: JellyfinItem, shape: TVTopShelfSectionedItem.ImageShape,
                                  session: ServerSession) -> TVTopShelfSectionedItem {
        let shelfItem = TVTopShelfSectionedItem(identifier: item.id)
        // An episode's still doesn't say which show it is.
        shelfItem.title = item.isEpisode
            ? [item.seriesName ?? item.name, item.episodeCode].compactMap(\.self).joined(separator: " · ")
            : item.name
        shelfItem.imageShape = shape
        let size = TVTopShelfSectionedContent.imageSize(for: shape)
        for (traits, scale) in [(TVTopShelfItem.ImageTraits.screenScale1x, 1.0), (.screenScale2x, 2.0)] {
            let width = Int(size.width * scale)
            let url = shape == .hdtv ? session.landscape(item, width: width) : session.poster(item, width: width)
            shelfItem.setImageURL(url, for: traits)
        }
        if let progress = item.progress { shelfItem.playbackProgress = progress }
        shelfItem.displayAction = TVTopShelfAction(url: AppLink(.open, item).url)
        if item.isPlayable { shelfItem.playAction = TVTopShelfAction(url: AppLink(.play, item).url) }
        return shelfItem
    }
}
#endif
