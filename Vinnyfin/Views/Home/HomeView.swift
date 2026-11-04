import SwiftUI

/// What to watch next, and everything else to find: a featured banner, what's in progress and
/// new, then a long run of rows from what was watched and liked, the best and newest, collections
/// and every genre. Each row's title opens all of its titles.
struct HomeView: View {
    /// The pages open on top of Home: titles, and lists in full.
    @Binding var path: NavigationPath
    var openDownloads: () -> Void = {}

    @Environment(\.session) private var session
    @Environment(AccountStore.self) private var accounts
    @State private var feed = HomeFeed()
    #if os(iOS) || os(visionOS)
    @State private var showingSettings = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            EdgeToEdgeScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if !feed.featured.isEmpty {
                        HeroBanner(items: feed.featured) { path.append($0) }
                    }
                    if feed.sessionEnded {
                        sessionEndedNotice
                    } else if let loadError = feed.loadError {
                        offlineNotice(loadError)
                    }
                    ForEach(feed.rows) { row in
                        HomeRowView(row: row, feed: feed) { path.append($0) }
                    }
                }
                .padding(.bottom, Metrics.edge)
            }
            .ignoresSafeArea(edges: feed.featured.isEmpty ? [] : .top)
            // The page color the hero artwork fades into.
            .background(Color.pageBackground.ignoresSafeArea())
            .screenTitle("Home")
            #if os(tvOS)
            .toolbarVisibility(feed.featured.isEmpty ? .automatic : .hidden, for: .navigationBar)
            #elseif os(iOS) || os(visionOS)
            // Over the hero the bar keeps only Settings, floating on the artwork; on iPhone Duo
            // it goes in the vertical bar with the rest of the bar's buttons.
            .navigationBarTitleDisplayMode(feed.featured.isEmpty ? .automatic : .inline)
            .toolbar(removing: feed.featured.isEmpty ? nil : .title)
            .toolbarBackgroundVisibility(feed.featured.isEmpty ? .automatic : .hidden, for: .navigationBar)
            #if os(iOS)
            .scrollEdgeEffectHidden(!feed.featured.isEmpty, for: .top)
            #endif
            .toolbar {
                ToolbarItem(placement: .barTrailing) { settingsButton }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            #endif
            .itemDestinations()
            .refreshable { await load(reshuffling: true) }
            .task { await load() }
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
        .edgePadding()
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
        .edgePadding()
    }

    private func load(reshuffling: Bool = false) async {
        guard let session else { return }
        await feed.load(session: session, reshuffling: reshuffling)
    }
}

/// One of Home's rows: its cards once they're in, their shapes until then, or why they couldn't
/// load. A row with nothing in it isn't there at all.
private struct HomeRowView: View {
    let row: HomeRow
    let feed: HomeFeed
    let open: (JellyfinItem) -> Void

    var body: some View {
        Group {
            if let problem = feed.problems[row.id] {
                problemRow(problem)
            } else if let items = feed.items[row.id] {
                if !items.isEmpty {
                    Shelf(title: row.list.title, seeAll: row.list, items: items, cardWidth: row.list.style.cardWidth) { item in
                        card(item)
                    }
                }
            } else {
                ShelfPlaceholder(title: row.list.title, style: row.list.style)
            }
        }
        .onAppear { feed.rowAppeared(row.id) }
        .onDisappear { feed.rowDisappeared(row.id) }
    }

    @ViewBuilder private func card(_ item: JellyfinItem) -> some View {
        switch row.list.style {
        case .poster:
            NavigationLink(value: item) { PosterCard(item: item) }
                .buttonStyle(.artwork)
                .contextMenu { ItemContextMenu(item: item) { feed.replace($0) } }
        case .landscape:
            NavigationLink(value: item) { LandscapeCard(item: item) }
                .buttonStyle(.artwork)
                .contextMenu {
                    ItemContextMenu(item: item) { feed.replace($0) }
                    if item.isEpisode, let seriesId = item.seriesId {
                        Button("Go to Show", systemImage: "tv") {
                            open(JellyfinItem(id: seriesId, name: item.seriesName ?? "", type: "Series"))
                        }
                    }
                }
        }
    }

    private func problemRow(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.list.title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Label("Couldn't load these: \(problem)", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again") { feed.retry(row.id) }
                .buttonStyle(.platformGlass)
        }
        .edgePadding()
        #if os(tvOS)
        .focusSection()
        #endif
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
            .edgePadding()
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
