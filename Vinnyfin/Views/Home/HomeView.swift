import SwiftUI

/// What to watch next: a featured banner, then shelves of what's in progress, what's new and
/// what's like what was watched, and downloads worth having.
struct HomeView: View {
    var openDownloads: () -> Void = {}

    @Environment(\.session) private var session
    @Environment(AccountStore.self) private var accounts
    @Environment(PlayerCoordinator.self) private var player
    @State private var path: [JellyfinItem] = []
    @State private var resume: [JellyfinItem] = []
    @State private var nextUp: [JellyfinItem] = []
    @State private var latestMovies: [JellyfinItem] = []
    @State private var latestShows: [JellyfinItem] = []
    @State private var recentlyWatched: [JellyfinItem] = []
    @State private var favorites: [JellyfinItem] = []
    @State private var becauseYouWatched: (title: String, items: [JellyfinItem])?
    @State private var isLoading = true
    @State private var loadError: String?
    /// The server turned the saved sign-in away (HTTP 401), so retrying won't help.
    @State private var sessionEnded = false
    #if os(iOS) || os(visionOS)
    @State private var showingSettings = false
    #endif

    private var featured: [JellyfinItem] {
        var seen = Set<String>()
        let candidates = resume.filter { !$0.isEpisode } + latestMovies + latestShows
        return candidates.filter { $0.backdropImageTags?.isEmpty == false && seen.insert($0.id).inserted }.prefix(6).map(\.self)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if !featured.isEmpty {
                        HeroBanner(items: featured) { path.append($0) }
                    }
                    if sessionEnded {
                        sessionEndedNotice
                    } else if let loadError {
                        offlineNotice(loadError)
                    }
                    if !resume.isEmpty {
                        Shelf(title: "Continue Watching", items: resume, cardWidth: Metrics.landscapeWidth) { item in
                            playableCard(item)
                        }
                    }
                    if !nextUp.isEmpty {
                        Shelf(title: "Next Up", items: nextUp, cardWidth: Metrics.landscapeWidth) { item in
                            playableCard(item)
                        }
                    }
                    #if !os(tvOS)
                    SuggestedDownloadsShelf(nextUp: nextUp, resume: resume)
                    #endif
                    posterShelf("Recently Added Movies", latestMovies)
                    posterShelf("Recently Added Shows", latestShows)
                    if let becauseYouWatched {
                        posterShelf("Because You Watched \(becauseYouWatched.title)", becauseYouWatched.items)
                    }
                    posterShelf("Favorites", favorites)
                    if !recentlyWatched.isEmpty {
                        Shelf(title: "Recently Watched", items: recentlyWatched, cardWidth: Metrics.landscapeWidth) { item in
                            NavigationLink(value: item) { LandscapeCard(item: item) }
                                .buttonStyle(.artwork)
                        }
                    }
                }
                .padding(.bottom, Metrics.edge)
            }
            .overlay {
                if isLoading, resume.isEmpty, latestMovies.isEmpty, latestShows.isEmpty { ProgressView() }
            }
            .ignoresSafeArea(edges: featured.isEmpty ? [] : .top)
            .scrollsEdgeToEdge()
            // The page color the hero artwork fades into.
            .background(Color.pageBackground.ignoresSafeArea())
            #if os(iOS) || os(visionOS)
            // Over the hero the bar is hidden, so Settings floats in its corner instead.
            .overlay(alignment: .topTrailing) {
                if !featured.isEmpty {
                    settingsButton
                        .labelStyle(.iconOnly)
                        .buttonStyle(.platformGlass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .padding(.trailing, Metrics.edge)
                }
            }
            #endif
            .navigationTitle("Home")
            #if !os(macOS)
            .toolbarVisibility(featured.isEmpty ? .automatic : .hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: JellyfinItem.self) { ItemDestination(item: $0) }
            #if os(iOS) || os(visionOS)
            .toolbar {
                ToolbarItem(placement: .barTrailing) { settingsButton }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            #endif
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func posterShelf(_ title: String, _ items: [JellyfinItem]) -> some View {
        Group {
            if !items.isEmpty {
                Shelf(title: title, items: items, cardWidth: Metrics.posterWidth) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }
                        .buttonStyle(.artwork)
                        .contextMenu { ItemContextMenu(item: item) }
                }
            }
        }
    }

    /// A card that plays when chosen, with the way to its page in its menu.
    private func playableCard(_ item: JellyfinItem) -> some View {
        Button {
            player.play(.item(item))
        } label: {
            LandscapeCard(item: item)
        }
        .buttonStyle(.artwork)
        .contextMenu {
            ItemContextMenu(item: item)
            Button("Details", systemImage: "info.circle") { path.append(item) }
            if item.isEpisode, let seriesId = item.seriesId {
                Button("Go to Show", systemImage: "tv") {
                    path.append(JellyfinItem(id: seriesId, name: item.seriesName ?? "", type: "Series"))
                }
            }
        }
    }

    #if os(iOS) || os(visionOS)
    private var settingsButton: some View {
        Button("Settings", systemImage: "person.crop.circle") { showingSettings = true }
            .accessibilityIdentifier("home.settings")
    }
    #endif

    private var sessionEndedNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Signed Out of \(session?.account.serverName ?? "the Server")", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
            Text("The server no longer accepts this sign-in, for example after a password change or a server reset. Downloads still play.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Sign In Again") { Task { await accounts.signOut() } }
                    .accessibilityIdentifier("home.signInAgain")
                #if !os(tvOS)
                Button("Watch Downloads", action: openDownloads)
                #endif
            }
            .buttonStyle(.platformGlass)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .padding(.horizontal, Metrics.edge)
    }

    private func offlineNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Can't reach \(session?.account.serverName ?? "the server")", systemImage: "wifi.exclamationmark")
                .font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Try Again") { Task { await load() } }
                #if !os(tvOS)
                Button("Watch Downloads", action: openDownloads)
                #endif
            }
            .buttonStyle(.platformGlass)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .padding(.horizontal, Metrics.edge)
    }

    private func load() async {
        guard let session else { return }
        isLoading = true
        defer { isLoading = false }
        let client = session.client
        let userId = session.userId
        async let resume = client.resumeItems(userId: userId)
        async let nextUp = client.nextUp(userId: userId)
        async let movies = client.latest(userId: userId, types: ["Movie"])
        async let shows = client.latest(userId: userId, types: ["Episode"])
        async let watched = client.recentlyPlayed(userId: userId)
        var favoritesQuery = JellyfinClient.ItemQuery(types: ["Movie", "Series"])
        favoritesQuery.isFavorite = true
        favoritesQuery.limit = 24
        async let favorites = client.items(userId: userId, favoritesQuery)
        do {
            self.resume = try await resume
            self.nextUp = try await nextUp
            self.latestMovies = try await movies
            self.latestShows = try await shows.map(Self.showFor)
            self.recentlyWatched = try await watched
            self.favorites = try await favorites.items
            loadError = nil
            sessionEnded = false
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch JellyfinError.http(status: 401, _) {
            sessionEnded = true
            return
        } catch {
            loadError = error.localizedDescription
            return
        }
        await loadBecauseYouWatched(client: client, userId: userId)
    }

    /// Latest episodes come back grouped by show, but a lone new episode comes back as itself;
    /// either way the shelf shows the show.
    private static func showFor(_ item: JellyfinItem) -> JellyfinItem {
        guard item.isEpisode, let seriesId = item.seriesId else { return item }
        var show = JellyfinItem(id: seriesId, name: item.seriesName ?? item.name, type: "Series")
        show.imageTags = item.seriesPrimaryImageTag.map { ["Primary": $0] }
        show.productionYear = item.productionYear
        return show
    }

    private func loadBecauseYouWatched(client: JellyfinClient, userId: String) async {
        guard let last = recentlyWatched.first else { return }
        let anchorId = last.isEpisode ? (last.seriesId ?? last.id) : last.id
        let anchorName = last.isEpisode ? (last.seriesName ?? last.name) : last.name
        do {
            let similar = try await client.similar(to: anchorId, userId: userId)
            becauseYouWatched = similar.isEmpty ? nil : (anchorName, similar)
        } catch {
            // An extra shelf; Home is complete without it.
            becauseYouWatched = nil
        }
    }
}

/// The featured titles, one at a time across the top, turning every few seconds.
private struct HeroBanner: View {
    let items: [JellyfinItem]
    let openDetails: (JellyfinItem) -> Void

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var index = 0
    @State private var isInteracting = false

    var body: some View {
        let item = items[min(index, items.count - 1)]
        ZStack(alignment: .bottomLeading) {
            Artwork(url: session?.backdrop(item), aspectRatio: nil, cornerRadius: 0)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                // Edge to edge, past the TV's overscan margins and the iPhone's landscape insets.
                .ignoresSafeArea(edges: .horizontal)
                .clipped()
                .id(item.id)
                .transition(.opacity)
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.3),
                        .init(color: Color.pageBackground.opacity(0.7), location: 0.72),
                        .init(color: Color.pageBackground, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            VStack(alignment: .leading, spacing: 10) {
                if let logo = session?.logo(item) {
                    Artwork(url: logo, aspectRatio: nil, cornerRadius: 0, placeholder: "", contentMode: .fit)
                        .frame(maxWidth: logoWidth, maxHeight: logoHeight, alignment: .leading)
                } else {
                    Text(item.name).font(.largeTitle.weight(.bold)).lineLimit(2)
                }
                Text(DetailHero<EmptyView>.facts(for: item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let overview = item.overview {
                    Text(overview).font(.subheadline).lineLimit(2).frame(maxWidth: 640, alignment: .leading)
                }
                HStack(spacing: 12) {
                    if item.isPlayable {
                        Button {
                            player.play(.item(item))
                        } label: {
                            Label(item.resumeSeconds != nil ? "Resume" : "Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.platformGlassProminent)
                    }
                    Button {
                        openDetails(item)
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(.platformGlass)
                }
                .controlSize(.large)
                if items.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(items.indices, id: \.self) { position in
                            Capsule().fill(position == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                .frame(width: position == index ? 18 : 6, height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Metrics.edge)
            .padding(.bottom, 6)
        }
        .animation(.easeInOut(duration: 0.6), value: index)
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onChanged { _ in isInteracting = true }
                .onEnded { value in
                    isInteracting = false
                    if value.translation.width < -40 { index = (index + 1) % items.count }
                    if value.translation.width > 40 { index = (index - 1 + items.count) % items.count }
                }
        )
        #endif
        #if os(tvOS)
        .focusSection()
        #endif
        .task(id: items.map(\.id)) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if !isInteracting, !Task.isCancelled { index = (index + 1) % max(1, items.count) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.hero")
    }

    private var height: CGFloat {
        #if os(tvOS)
        820
        #elseif os(iOS)
        sizeClass == .regular ? 580 : 500
        #else
        520
        #endif
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        600
        #else
        300
        #endif
    }

    private var logoHeight: CGFloat {
        #if os(tvOS)
        200
        #else
        100
        #endif
    }
}
