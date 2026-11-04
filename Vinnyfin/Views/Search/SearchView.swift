import SwiftUI

/// Finds movies, shows and episodes by name as you type.
struct SearchView: View {
    @Environment(\.session) private var session
    @State private var text = ""
    @State private var movies: [JellyfinItem] = []
    @State private var shows: [JellyfinItem] = []
    @State private var episodes: [JellyfinItem] = []
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            EdgeToEdgeScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    results("Movies", movies)
                    results("Shows", shows)
                    if !episodes.isEmpty {
                        Shelf(title: "Episodes", items: episodes, cardWidth: Metrics.landscapeWidth) { item in
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
            .navigationTitle("Search")
            .alwaysSearchable(text: $text, prompt: "Movies, shows and episodes")
            .navigationDestination(for: JellyfinItem.self) { ItemDestination(item: $0) }
            .task(id: text) { await search() }
        }
    }

    @ViewBuilder private func results(_ title: String, _ items: [JellyfinItem]) -> some View {
        if !items.isEmpty {
            Shelf(title: title, items: items, cardWidth: Metrics.posterWidth) { item in
                NavigationLink(value: item) { PosterCard(item: item) }
                    .buttonStyle(.artwork)
                    .contextMenu { ItemContextMenu(item: item) }
            }
        }
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
        func query(_ types: [String]) -> JellyfinClient.ItemQuery {
            var query = JellyfinClient.ItemQuery(types: types)
            query.searchTerm = term
            query.limit = 30
            return query
        }
        do {
            async let movies = session.client.items(userId: session.userId, query(["Movie"]))
            async let shows = session.client.items(userId: session.userId, query(["Series"]))
            async let episodes = session.client.items(userId: session.userId, query(["Episode"]))
            self.movies = try await movies.items
            self.shows = try await shows.items
            self.episodes = try await episodes.items
            searchError = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            searchError = error.localizedDescription
        }
    }
}
