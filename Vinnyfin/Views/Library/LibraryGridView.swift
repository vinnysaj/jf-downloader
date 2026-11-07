import SwiftUI

/// A list in full, as a grid of cards: every movie or show, or everything a Home row samples.
/// It loads a page at a time around what's on screen, so it opens at once and scrolls the same
/// at any length. Sorted by name it has an A–Z index down the side.
struct LibraryGridView: View {
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

        /// The server's field for it. A show counts as added when an episode last was.
        func serverField(for types: [String]) -> String {
            switch self {
            case .name: "SortName"
            case .dateAdded: types == ["Series"] ? "DateLastContentAdded" : "DateCreated"
            case .releaseDate: "PremiereDate"
            case .rating: "CommunityRating"
            case .lastPlayed: "DatePlayed"
            }
        }

        /// The sort a query uses, if it's one of these.
        init?(_ query: JellyfinClient.ItemQuery) {
            guard let sort = Self.allCases.first(where: { $0.serverField(for: query.types) == query.sortBy }) else { return nil }
            self = sort
        }

        func apply(to query: inout JellyfinClient.ItemQuery) {
            query.sortBy = serverField(for: query.types)
            query.ascending = self == .name
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

        init(_ query: JellyfinClient.ItemQuery) {
            self = query.isFavorite == true ? .favorites : query.isPlayed == false ? .unwatched : .all
        }

        func apply(to query: inout JellyfinClient.ItemQuery) {
            query.isPlayed = self == .unwatched ? false : nil
            query.isFavorite = self == .favorites ? true : nil
        }
    }

    let list: BrowseList

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    /// The list's query as the menu has changed it; nil for a list that isn't a query.
    @State private var query: JellyfinClient.ItemQuery?
    @State private var items: PagedItems?
    @State private var refreshProblem: String?
    @State private var genres: [String] = []
    @State private var libraries: [JellyfinItem] = []
    @State private var filterProblem: String?
    /// The position at the top of the screen, kept there when the columns change with the width:
    /// a rotation, an unfold, a resized window.
    @State private var position = ScrollPosition(idType: Int.self)
    /// The jump to the letter last chosen; choosing another replaces it.
    @State private var jumping: Task<Void, Never>?
    @FocusState private var focusedIndex: Int?
    #if os(tvOS)
    /// Opened from another screen rather than as a tab's first.
    @Environment(\.isPresented) private var isPresented
    @State private var pendingFocus: Int?
    /// Titles a row of the grid holds, once its width is known.
    @State private var columnCount: Int?
    /// The positions the grid holds.
    @State private var focusWindow = FocusWindow()
    #endif

    init(list: BrowseList) {
        self.list = list
        _query = State(initialValue: Self.query(of: list))
    }

    private static func query(of list: BrowseList) -> JellyfinClient.ItemQuery? {
        guard case .items(var query) = list.source else { return nil }
        query.fields = JellyfinClient.cardFields
        return query
    }

    /// The list's own query, which the menu refines but whose filters it leaves alone.
    private var base: JellyfinClient.ItemQuery? { Self.query(of: list) }
    private var source: JellyfinClient.ItemSource { query.map { .items($0) } ?? list.source }
    private var showsIndex: Bool { items?.isSortedByName == true && (items?.count ?? 0) > 30 }

    var body: some View {
        EdgeToEdgeScrollView {
            Group {
                if let items, let count = items.count {
                    grid(items, count: count)
                }
            }
            .padding(.horizontal, Metrics.edge)
            .padding(Self.indexEdge, showsIndex ? indexWidth + indexInset : 0)
            .padding(.bottom, Metrics.edge)
        }
        .scrollPosition($position, anchor: .top)
        #if os(tvOS)
        .onScrollPhaseChange { _, phase in
            if phase == .idle, let index = focusedIndex, let columnCount, let count = items?.count {
                focusWindow.follow(index, count: count, columns: columnCount)
            }
        }
        #endif
        // A new sort or filter starts at the top.
        .id(source)
        .overlay(alignment: Self.indexEdge == .leading ? .leading : .trailing) {
            if showsIndex, let items {
                // Every letter is live until the server's counts say which have titles.
                AlphabetIndex(available: items.index.map { Set($0.sections.map(\.letter)) } ?? Set(LibraryIndex.alphabet)) { letter in
                    jump(to: letter, in: items)
                }
                .padding(.vertical, 12)
                .padding(.top, indexTopInset)
                .padding(Self.indexEdge, indexInset)
            }
        }
        .overlay { status }
        .overlay(alignment: .bottom) { pageProblem }
        .screenTitle(list.title)
        #if !os(tvOS)
        .toolbar {
            if query != nil {
                ToolbarItem(placement: .primaryAction) { sortAndFilter }
            }
        }
        #endif
        .task(id: source) { await load(startingOver: true) }
        .onChange(of: player.endedPlayback) { items?.update(from: player.endedPlayback) }
        .task { await loadFilters() }
        .refreshable { await load(startingOver: false) }
    }

    @ViewBuilder private var status: some View {
        if let items, items.count == nil, let problem = items.problem {
            ContentUnavailableView {
                Label("Couldn't Load \(list.title)", systemImage: "wifi.exclamationmark")
            } description: {
                Text(problem)
            } actions: {
                Button("Try Again") { Task { await load(startingOver: true) } }
            }
        } else if items?.count == nil {
            ProgressView()
        } else if items?.count == 0 {
            ContentUnavailableView("No \(list.title)", systemImage: list.symbol,
                                   description: Text(query == base ? "Nothing here yet." : "Nothing matches these filters."))
        }
    }

    /// A page, or a refresh, that failed while the list is showing.
    @ViewBuilder private var pageProblem: some View {
        if let items, items.count != nil, let problem = items.problem ?? refreshProblem {
            HStack(spacing: 12) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .lineLimit(2)
                Button("Try Again") {
                    refreshProblem = nil
                    items.retry()
                }
                .buttonStyle(.platformGlassProminent)
            }
            .padding(12)
            .platformGlass(in: .capsule)
            .padding(.horizontal, Metrics.edge)
            .padding(.bottom, Metrics.edge)
        }
    }

    private var indexWidth: CGFloat {
        #if os(tvOS)
        60
        #else
        22
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

    /// The side the index has its column on. Apple TV's is the leading one, where focus goes
    /// from the grid toward the sidebar.
    private static var indexEdge: Edge.Set {
        #if os(tvOS)
        .leading
        #else
        .trailing
        #endif
    }

    /// The index's distance from the screen's edge: on Apple TV, inside the overscan margin.
    private var indexInset: CGFloat {
        #if os(tvOS)
        Metrics.edge
        #else
        4
        #endif
    }

    private var columns: [GridItem] {
        let width = list.style.cardWidth
        return [GridItem(.adaptive(minimum: width, maximum: width * 1.35), spacing: Metrics.gridSpacing, alignment: .top)]
    }

    /// One flat grid at any sort: letters don't head sections, since where each starts is
    /// known only once the server has counted, and headers placed then would move what's on
    /// screen.
    @ViewBuilder private func grid(_ items: PagedItems, count: Int) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.gridSpacing) {
            // The head goes with the list's first rows.
            if focusWindow.start == 0 { head }
            // The rows around focus; see `FocusWindow`.
            LazyVGrid(columns: fixedColumns, spacing: Metrics.gridSpacing) {
                if let columnCount {
                    ForEach(focusWindow.range(count: count, columns: columnCount), id: \.self) { cell(items, $0) }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                columnCount = max(1, Int((width + Metrics.gridSpacing) / (list.style.cardWidth + Metrics.gridSpacing)))
            }
            .scrollTargetLayout()
        }
        #else
        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridSpacing) {
            ForEach(0..<count, id: \.self) { cell(items, $0) }
        }
        .scrollTargetLayout()
        #endif
    }

    #if os(tvOS)
    /// Above the grid on Apple TV, where the bar stays over what scrolls under it: the title of a
    /// list opened from another screen, and Sort and Filter.
    @ViewBuilder private var head: some View {
        if isPresented || query != nil {
            HStack {
                if isPresented {
                    Text(list.title).font(.title2.bold())
                }
                Spacer()
                if query != nil { sortAndFilter }
            }
        }
    }

    /// As many columns as fit, so whole rows leave the window as it moves and the rest stay put.
    private var fixedColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing, alignment: .top), count: columnCount ?? 1)
    }
    #endif

    /// Scrolls to a letter's first title.
    private func jump(to letter: String, in items: PagedItems) {
        jumping?.cancel()
        jumping = Task {
            guard let first = await items.start(of: letter), !Task.isCancelled else { return }
            #if os(tvOS)
            if let columnCount, let count = items.count {
                focusWindow.center(on: first, count: count, columns: columnCount)
            }
            #endif
            position.scrollTo(id: first, anchor: .top)
            #if os(tvOS)
            // Focus follows to the letter's first title, once it's loaded and made.
            pendingFocus = first
            focusedIndex = first
            #endif
        }
    }

    private func cell(_ items: PagedItems, _ index: Int) -> some View {
        #if os(tvOS)
        GridCell(items: items, index: index, style: list.style, focus: $focusedIndex, pendingFocus: $pendingFocus)
        #else
        GridCell(items: items, index: index, style: list.style, focus: $focusedIndex)
        #endif
    }

    private var sortAndFilter: some View {
        Menu {
            Picker("Sort By", selection: sortSelection) {
                ForEach(Sort.allCases) { Text($0.label).tag(Optional($0)) }
            }
            if base?.isPlayed == nil, base?.isFavorite == nil {
                Picker("Show", selection: filterSelection) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
            }
            if !genres.isEmpty {
                Picker("Genre", selection: genreSelection) {
                    Text("All Genres").tag(String?.none)
                    ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
            if libraries.count > 1 {
                Picker("Library", selection: librarySelection) {
                    Text("All Libraries").tag(String?.none)
                    ForEach(libraries) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
            }
            if let filterProblem {
                Section("Genres and libraries couldn't load: \(filterProblem)") {
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await loadFilters() } }
                }
            }
        } label: {
            Label("Sort and Filter", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("library.sortFilter")
    }

    private var sortSelection: Binding<Sort?> {
        Binding {
            query.flatMap(Sort.init)
        } set: { sort in
            guard let sort, var changed = query else { return }
            sort.apply(to: &changed)
            query = changed
        }
    }

    private var filterSelection: Binding<Filter> {
        Binding {
            query.map(Filter.init) ?? .all
        } set: { filter in
            guard var changed = query else { return }
            filter.apply(to: &changed)
            query = changed
        }
    }

    private var genreSelection: Binding<String?> {
        Binding {
            query?.genres.first
        } set: { genre in
            query?.genres = genre.map { [$0] } ?? []
        }
    }

    private var librarySelection: Binding<String?> {
        Binding {
            query?.parentId
        } set: { library in
            query?.parentId = library
        }
    }

    // MARK: Loading

    /// Starting over shows the new list from its first page; a refresh keeps the list on screen
    /// until the new one is in.
    private func load(startingOver: Bool) async {
        guard let session else { return }
        let next = PagedItems(source: source, client: session.client, userId: session.userId)
        if startingOver {
            items?.cancel()
            items = next
            refreshProblem = nil
            position = ScrollPosition(idType: Int.self)
            #if os(tvOS)
            focusWindow = FocusWindow()
            #endif
        }
        await next.load()
        guard !Task.isCancelled else {
            next.cancel()
            return
        }
        if !startingOver {
            if next.count == nil, items?.count != nil {
                refreshProblem = next.problem
            } else {
                items?.cancel()
                items = next
                refreshProblem = nil
            }
        }
    }

    /// The genres and libraries the menu narrows the list to, where the list doesn't fix them.
    private func loadFilters() async {
        guard let session, let base else { return }
        do {
            if base.genres.isEmpty {
                genres = try await session.client.genres(userId: session.userId, types: base.types).map(\.name)
            }
            if base.parentId == nil {
                let kinds = Set(base.types.compactMap(Self.collectionType))
                libraries = try await session.client.libraries(userId: session.userId).filter { kinds.contains($0.collectionType ?? "") }
            }
            filterProblem = nil
        } catch {
            if !error.isCancellation { filterProblem = error.localizedDescription }
        }
    }

    /// The kind of library an item type lives in.
    private static func collectionType(of type: String) -> String? {
        switch type {
        case "Movie": "movies"
        case "Series", "Episode": "tvshows"
        default: nil
        }
    }
}

/// One position in the grid: its card once its page is in, a placeholder of the same size until then.
private struct GridCell: View {
    let items: PagedItems
    let index: Int
    let style: BrowseList.Style
    let focus: FocusState<Int?>.Binding
    #if os(tvOS)
    @Binding var pendingFocus: Int?
    #endif

    var body: some View {
        let item = items.item(at: index)
        NavigationLink(value: item) {
            if let item {
                switch style {
                case .poster: PosterCard(item: item)
                case .landscape: LandscapeCard(item: item)
                }
            } else {
                CardPlaceholder(style: style)
            }
        }
        .buttonStyle(.artwork)
        .focused(focus, equals: index)
        .contextMenu {
            if let item { ItemContextMenu(item: item) { items.replace($0) } }
        }
        .onAppear { items.show(index) }
        #if os(tvOS)
        .onChange(of: item?.id, initial: true) {
            // An index jump's target takes focus once it can: loaded, and so enabled.
            guard item != nil, pendingFocus == index else { return }
            pendingFocus = nil
            focus.wrappedValue = index
        }
        #endif
    }
}
