import SwiftUI

/// Every movie, or every show, across the user's libraries, as a poster grid. Sorted by name
/// it is split into letters with an A–Z index down the side.
struct LibraryGridView: View {
    enum Kind: String {
        case movies, shows

        var title: String { self == .movies ? "Movies" : "Shows" }
        var itemType: String { self == .movies ? "Movie" : "Series" }
        var collectionType: String { self == .movies ? "movies" : "tvshows" }
        var symbol: String { self == .movies ? "film" : "tv" }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case name, dateAdded, releaseDate, rating, lastPlayed

        var id: Self { self }
        var label: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Date Added"
            case .releaseDate: "Release Date"
            case .rating: "Rating"
            case .lastPlayed: "Recently Watched"
            }
        }

        var serverField: String {
            switch self {
            case .name: "SortName"
            case .dateAdded: "DateCreated"
            case .releaseDate: "PremiereDate"
            case .rating: "CommunityRating"
            case .lastPlayed: "DatePlayed"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, unwatched, favorites
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .unwatched: "Unwatched"
            case .favorites: "Favorites"
            }
        }
    }

    private struct Query: Equatable {
        var sort: Sort
        var filter: Filter
        var genre: String?
        var libraryId: String?
    }

    let kind: Kind

    @Environment(\.session) private var session
    @State private var items: [JellyfinItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var query = Query(sort: .name, filter: .all)
    @State private var genres: [String] = []
    @State private var libraries: [JellyfinItem] = []
    @FocusState private var focusedItem: String?
    #if os(tvOS)
    @State private var pendingFocus: String?
    #endif

    private static let firstPage = 150
    private static let pageSize = 500

    private var index: LibraryIndex<JellyfinItem> { LibraryIndex(items) { $0.indexName } }
    private var showsIndex: Bool { query.sort == .name && items.count > 30 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                grid
                    .padding(.horizontal, Metrics.edge)
                    .padding(.trailing, showsIndex ? indexWidth + indexInset : 0)
                    .padding(.bottom, Metrics.edge)
            }
            .scrollsEdgeToEdge()
            .overlay(alignment: .trailing) {
                if showsIndex {
                    let index = index
                    AlphabetIndex(available: Set(index.sections.map(\.letter))) { letter in
                        guard let section = index.section(for: letter) else { return }
                        proxy.scrollTo(section.letter, anchor: .top)
                        #if os(tvOS)
                        // Focus follows to the section's first title; one the lazy grid hasn't
                        // made yet takes it as it appears.
                        let first = section.items.first?.id
                        pendingFocus = first
                        focusedItem = first
                        #endif
                    }
                    .padding(.vertical, 12)
                    .padding(.top, indexTopInset)
                    .padding(.trailing, indexInset)
                }
            }
            .overlay {
                if let loadError, items.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load \(kind.title)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if items.isEmpty, isLoading {
                    ProgressView()
                } else if items.isEmpty {
                    ContentUnavailableView("No \(kind.title)", systemImage: kind.symbol,
                                           description: Text(query == Query(sort: query.sort, filter: .all) ? "Nothing here yet." : "Nothing matches these filters."))
                }
            }
        }
        .navigationTitle(kind.title)
        .toolbar { toolbar }
        .task(id: query) { await load() }
        .task { await loadFilters() }
        .refreshable { await load() }
    }

    private var indexWidth: CGFloat {
        #if os(tvOS)
        60
        #else
        22
        #endif
    }

    /// Apple TV scrolls the grid to follow focus, so letters don't need to stay pinned.
    private static var pinnedHeaders: PinnedScrollableViews {
        #if os(tvOS)
        []
        #else
        .sectionHeaders
        #endif
    }

    /// Room above the index for Apple TV's toolbar, which floats over the grid.
    private var indexTopInset: CGFloat {
        #if os(tvOS)
        120
        #else
        0
        #endif
    }

    /// The index's distance from the trailing edge: on Apple TV, inside the overscan margin.
    private var indexInset: CGFloat {
        #if os(tvOS)
        Metrics.edge
        #else
        4
        #endif
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Metrics.posterWidth, maximum: Metrics.posterWidth * 1.35), spacing: Metrics.gridSpacing, alignment: .top)],
            alignment: .leading,
            spacing: Metrics.gridSpacing,
            pinnedViews: showsIndex ? Self.pinnedHeaders : []
        ) {
            if showsIndex {
                ForEach(index.sections) { section in
                    Section {
                        ForEach(section.items) { item in card(item) }
                    } header: {
                        Text(section.letter)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            #if !os(tvOS)
                            .background(.background.opacity(0.92))
                            #endif
                            .id(section.letter)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            } else {
                ForEach(items) { item in card(item) }
            }
        }
    }

    private func card(_ item: JellyfinItem) -> some View {
        NavigationLink(value: item) {
            PosterCard(item: item)
        }
        .buttonStyle(.artwork)
        .focused($focusedItem, equals: item.id)
        #if os(tvOS)
        .onAppear {
            guard pendingFocus == item.id else { return }
            pendingFocus = nil
            focusedItem = item.id
        }
        #endif
        .contextMenu {
            ItemContextMenu(item: item) { updated in
                if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $query.sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Show", selection: $query.filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                if !genres.isEmpty {
                    Picker("Genre", selection: $query.genre) {
                        Text("All Genres").tag(String?.none)
                        ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu)
                }
                if libraries.count > 1 {
                    Picker("Library", selection: $query.libraryId) {
                        Text("All Libraries").tag(String?.none)
                        ForEach(libraries) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                Label("Sort and Filter", systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityIdentifier("library.sortFilter")
        }
    }

    // MARK: Loading

    private func itemQuery(startIndex: Int, limit: Int) -> JellyfinClient.ItemQuery {
        var itemQuery = JellyfinClient.ItemQuery(types: [kind.itemType])
        itemQuery.parentId = query.libraryId
        itemQuery.sortBy = query.sort.serverField
        itemQuery.ascending = query.sort == .name
        itemQuery.isPlayed = query.filter == .unwatched ? false : nil
        itemQuery.isFavorite = query.filter == .favorites ? true : nil
        itemQuery.genres = query.genre.map { [$0] } ?? []
        itemQuery.fields = "SortName,DateCreated,PrimaryImageAspectRatio"
        itemQuery.startIndex = startIndex
        itemQuery.limit = limit
        return itemQuery
    }

    /// The first screenful right away, then the rest of the library in large pages, so the
    /// index can jump anywhere.
    private func load() async {
        guard let session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let first = try await session.client.items(userId: session.userId, itemQuery(startIndex: 0, limit: Self.firstPage))
            items = first.items
            loadError = nil
            var loaded = first.items
            let starts = Array(stride(from: first.items.count, to: first.totalRecordCount, by: Self.pageSize))
            guard !starts.isEmpty else { return }
            let pages = try await withThrowingTaskGroup(of: (Int, [JellyfinItem]).self) { group in
                for start in starts {
                    let pageQuery = itemQuery(startIndex: start, limit: Self.pageSize)
                    group.addTask { (start, try await session.client.items(userId: session.userId, pageQuery).items) }
                }
                var pages: [(Int, [JellyfinItem])] = []
                for try await page in group { pages.append(page) }
                return pages.sorted { $0.0 < $1.0 }
            }
            let known = Set(loaded.map(\.id))
            loaded += pages.flatMap(\.1).filter { !known.contains($0.id) }
            items = loaded
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadFilters() async {
        guard let session else { return }
        do {
            async let genres = session.client.genres(userId: session.userId, types: [kind.itemType])
            async let libraries = session.client.libraries(userId: session.userId)
            self.genres = try await genres
            self.libraries = try await libraries.filter { $0.collectionType == kind.collectionType }
        } catch {
            // The grid works without its filter menus; a failure shows in the grid's own load.
            return
        }
    }
}
