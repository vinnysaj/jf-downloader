import SwiftUI

struct RootView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    @Environment(WatchHistory.self) private var history
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    #endif

    private var session: ServerSession? {
        guard let client = accounts.client, let account = accounts.account else { return nil }
        return ServerSession(client: client, account: account)
    }

    var body: some View {
        @Bindable var player = player
        @Bindable var messages = messages
        Group {
            if let session {
                MainTabs()
                    // Each server and user gets fresh browsing state.
                    .id(session.account.serverId + session.account.userId)
            } else {
                WelcomeView()
            }
        }
        .environment(\.session, session)
        #if os(macOS)
        .onChange(of: player.pendingWindowRequest) { _, request in
            guard let request else { return }
            player.pendingWindowRequest = nil
            // One engine plays one thing: a new playback replaces the window of the last.
            dismissWindow(id: PlayerWindow.id)
            openWindow(id: PlayerWindow.id, value: request)
        }
        #else
        .fullScreenCover(item: $player.presented) { model in
            PlayerView(model: model) { Task { await player.dismiss() } }
                .environment(\.session, session)
        }
        #endif
        .alert("Something Went Wrong", isPresented: Binding(get: { messages.current != nil }, set: { if !$0 { messages.current = nil } })) {
            Button("OK") { messages.current = nil }
        } message: {
            Text(messages.current ?? "")
        }
        .alert("Can't Play", isPresented: Binding(get: { player.problem != nil }, set: { if !$0 { player.problem = nil } })) {
            Button("OK") { player.problem = nil }
        } message: {
            Text(player.problem ?? "")
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            player.playFile(url)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            if let session { Task { await history.syncPending(using: session.client, userId: session.userId) } }
            #if !os(tvOS)
            smartDownloads.refreshSoon()
            #endif
        }
        #if !os(tvOS)
        .task { await downloads.trackProgress() }
        #endif
    }
}

struct MainTabs: View {
    enum Destination: Hashable {
        case home, movies, shows, downloads, settings, search
    }

    @State private var selection = Destination.home
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: .home) {
                HomeView { selection = .downloads }
            }
            Tab("Movies", systemImage: "film", value: .movies) {
                NavigationStack {
                    LibraryGridView(kind: .movies)
                        .navigationDestination(for: JellyfinItem.self) { ItemDestination(item: $0) }
                }
            }
            Tab("Shows", systemImage: "tv", value: .shows) {
                NavigationStack {
                    LibraryGridView(kind: .shows)
                        .navigationDestination(for: JellyfinItem.self) { ItemDestination(item: $0) }
                }
            }
            #if os(tvOS)
            Tab("Settings", systemImage: "gear", value: .settings) {
                SettingsView()
            }
            #else
            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                DownloadsView()
            }
            .badge(downloads.jobs.count { $0.status == .active })
            #endif
            Tab(value: .search, role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
