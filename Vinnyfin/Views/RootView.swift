import SwiftUI

struct RootView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    @Environment(WatchHistory.self) private var history
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #elseif os(visionOS)
    @Environment(\.pushWindow) private var pushWindow
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
        .preferredColorScheme(settings.appearance.colorScheme)
        #if os(macOS) || os(visionOS)
        .onChange(of: player.pendingWindowRequest) { _, request in
            guard let request else { return }
            player.pendingWindowRequest = nil
            #if os(visionOS)
            // The player takes this window's place, and closing it brings the library back.
            pushWindow(id: PlayerWindow.id, value: request)
            #else
            // One engine plays one thing: a new playback replaces the window of the last.
            dismissWindow(id: PlayerWindow.id)
            openWindow(id: PlayerWindow.id, value: request)
            #endif
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
        // Runs while the app is open, and stops as it goes to the background.
        .task(id: scenePhase == .background) {
            #if !os(tvOS)
            downloads.sceneChanged(isInBackground: scenePhase == .background)
            #endif
            guard scenePhase != .background else {
                #if os(iOS) || os(visionOS)
                await SmartDownloads.scheduleBackgroundRefresh()
                #endif
                return
            }
            // What was watched offline goes to the server first, so smart downloads plan from it.
            if let session { await history.syncPending(using: session.client, userId: session.userId) }
            #if !os(tvOS)
            await smartDownloads.refreshWhileOpen()
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

extension AppSettings.Appearance {
    /// Nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
