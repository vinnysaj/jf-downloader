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
    #endif
    #if !os(tvOS)
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(DownloadNotifications.self) private var downloadNotifications
    #endif
    /// A title a link asked to open, for Home to show.
    @State private var linkedItem: JellyfinItem?

    private var session: ServerSession? { accounts.session }

    var body: some View {
        @Bindable var player = player
        @Bindable var messages = messages
        Group {
            if let session {
                MainTabs(linkedItem: $linkedItem)
                    // Each server and user gets fresh browsing state.
                    .id(session.account.serverId + session.account.userId)
            } else {
                WelcomeView()
            }
        }
        .environment(\.session, session)
        .preferredColorScheme(settings.appearance.colorScheme)
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
        .onOpenURL { url in open(url) }
        #if !os(tvOS)
        // A tapped notification opens its title as a link would, launching the app or not.
        .onChange(of: downloadNotifications.openedLink, initial: true) { _, link in
            guard let link else { return }
            downloadNotifications.openedLink = nil
            open(link)
        }
        #endif
        // Runs while the app is open, and stops as it goes to the background.
        .task(id: scenePhase == .background) {
            guard scenePhase != .background else {
                #if os(tvOS)
                TopShelf.reload()
                #endif
                return
            }
            // What was watched offline goes to the server first, so smart downloads plan from it.
            if let session { await history.syncPending(using: session.client, userId: session.userId) }
            #if !os(tvOS)
            await smartDownloads.refreshWhileOpen()
            #endif
        }
    }

    /// Plays a file, or follows a vinnyfin:// link.
    private func open(_ url: URL) {
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            player.playFile(url)
        } else if let link = AppLink(url) {
            open(link)
        } else {
            messages.show("vinnyfin can't open \(url.absoluteString).")
        }
    }

    /// Plays the title, or shows its page on Home in place of the player.
    private func open(_ link: AppLink) {
        switch link.action {
        case .play:
            player.play(.item(link.item))
        case .open:
            guard session != nil else {
                messages.show("Sign in to see \(link.name).")
                return
            }
            Task { await player.dismiss() }
            linkedItem = link.item
        }
    }
}

struct MainTabs: View {
    enum Destination: Hashable {
        case home, movies, shows, downloads, settings, search
    }

    /// A title a link asked to open, shown on Home as the page after it.
    @Binding var linkedItem: JellyfinItem?
    @State private var selection = Destination.home
    @State private var homePath: [JellyfinItem] = []
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: .home) {
                HomeView(path: $homePath) { selection = .downloads }
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
        .onChange(of: linkedItem, initial: true) {
            guard let linkedItem else { return }
            selection = .home
            homePath = [linkedItem]
            self.linkedItem = nil
        }
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
