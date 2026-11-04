import SwiftUI

/// Finds movies, shows and episodes by name as you type. Each row samples its matches; its title
/// opens all of them.
struct SearchView: View {
    @Environment(\.session) private var session
    @State private var text = ""
    /// What the results on screen were found for.
    @State private var searched = ""
    @State private var movies: [JellyfinItem] = []
    @State private var shows: [JellyfinItem] = []
    @State private var episodes: [JellyfinItem] = []
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            EdgeToEdgeScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    results(list("Movies", types: ["Movie"]), movies)
                    results(list("Shows", types: ["Series"]), shows)
                    if !episodes.isEmpty {
                        Shelf(title: "Episodes", seeAll: list("Episodes", types: ["Episode"], style: .landscape),
                              items: episodes, cardWidth: Metrics.landscapeWidth) { item in
                            NavigationLink(value: item) { LandscapeCard(item: item) }
                                .buttonStyle(.artwork)
                                .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                }
                .padding(.vertical, Metrics.edge)
            }
            .overlay {
                if let searchError {
                    ContentUnavailableView("Search Failed", systemImage: "exclamationmark.magnifyingglass", description: Text(searchError))
                } else if text.isEmpty {
                    ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                           description: Text("Find movies, shows and episodes by name."))
                } else if isSearching, movies.isEmpty, shows.isEmpty, episodes.isEmpty {
                    ProgressView()
                } else if movies.isEmpty, shows.isEmpty, episodes.isEmpty {
                    ContentUnavailableView.search(text: text)
                }
            }
            .screenTitle("Search")
            .alwaysSearchable(text: $text, prompt: "Movies, shows and episodes")
            .itemDestinations()
            .task(id: text) { await search() }
        }
    }

    @ViewBuilder private func results(_ list: BrowseList, _ items: [JellyfinItem]) -> some View {
        if !items.isEmpty {
            Shelf(title: list.title, seeAll: list, items: items, cardWidth: Metrics.posterWidth) { item in
                NavigationLink(value: item) { PosterCard(item: item) }
                    .buttonStyle(.artwork)
                    .contextMenu { ItemContextMenu(item: item) }
            }
        }
    }

    /// Every match of one kind, for the row's title to open.
    private func list(_ title: String, types: [String], style: BrowseList.Style = .poster) -> BrowseList {
        BrowseList(title: title, source: .items(Self.query(types, term: searched)), style: style)
    }

    private static func query(_ types: [String], term: String) -> JellyfinClient.ItemQuery {
        var query = JellyfinClient.ItemQuery(types: types)
        query.searchTerm = term
        query.fields = JellyfinClient.cardFields
        return query
    }

    private func search() async {
        guard let session else { return }
        let term = text.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            movies = []
            shows = []
            episodes = []
            searchError = nil
            return
        }
        // Wait for typing to settle; a newer search cancels this one.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        isSearching = true
        defer { isSearching = false }
        func page(_ types: [String]) -> JellyfinClient.ItemQuery {
            var query = Self.query(types, term: term)
            query.limit = 24
            return query
        }
        do {
            async let movies = session.client.items(userId: session.userId, page(["Movie"]))
            async let shows = session.client.items(userId: session.userId, page(["Series"]))
            async let episodes = session.client.items(userId: session.userId, page(["Episode"]))
            self.movies = try await movies.items
            self.shows = try await shows.items
            self.episodes = try await episodes.items
            searched = term
            searchError = nil
        } catch {
            if !error.isCancellation { searchError = error.localizedDescription }
        }
    }
}
