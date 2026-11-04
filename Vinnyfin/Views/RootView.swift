import SwiftUI

struct RootView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    @Environment(WatchHistory.self) private var history
    @Environment(AppSettings.self) private var settings
    @Environment(SessionSocket.self) private var socket
    @Environment(SharePlay.self) private var sharePlay
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS) || os(macOS)
    @Environment(RemoteControl.self) private var remote
    #endif
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #elseif os(visionOS)
    @Environment(\.pushWindow) private var pushWindow
    #endif
    #if !os(tvOS)
    @Environment(SmartDownloads.self) private var smartDownloads
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
        .alert("Can't Watch Together", isPresented: Binding(get: { sharePlay.problem != nil }, set: { if !$0 { sharePlay.problem = nil } })) {
            Button("OK") { sharePlay.problem = nil }
        } message: {
            Text(sharePlay.problem ?? "")
        }
        #if os(iOS) || os(macOS)
        .sheet(isPresented: showsRemoteScreen) {
            RemoteScreen()
                .environment(\.session, session)
        }
        #endif
        // Others can play to this device while it's open, or while it plays in the background.
        .task(id: socketConnection) {
            guard socketConnection != nil, let client = accounts.client else { return }
            await socket.run(client: client)
        }
        .onOpenURL { url in
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

    #if os(iOS) || os(macOS)
    /// The remote's screen. On iPhone and iPad it waits for the player that handed its playback
    /// over to close: a sheet presented over the full-screen player keeps it from closing.
    private var showsRemoteScreen: Binding<Bool> {
        Binding {
            #if os(iOS)
            remote.showsScreen && player.presented == nil
            #else
            remote.showsScreen
            #endif
        } set: {
            remote.showsScreen = $0
        }
    }
    #endif

    /// The sign-in the socket is open for; nil while it's closed: signed out, or in the background
    /// with nothing playing, when the server then stops listing this device to play to. On the
    /// Mac, which doesn't suspend apps, it stays open.
    private var socketConnection: String? {
        guard let client = accounts.client, let account = accounts.account else { return nil }
        #if !os(macOS)
        if scenePhase == .background, player.presented?.isPlaying != true { return nil }
        #endif
        return "\(client.serverURL.absoluteString) \(account.userId) \(client.token ?? "")"
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
    @State private var homePath = NavigationPath()
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    #if os(iOS) || os(macOS)
    @Environment(RemoteControl.self) private var remote
    #endif

    var body: some View {
        tabs
            #if os(iOS)
            .tabViewBottomAccessory(isEnabled: remote.isActive) { RemoteMiniPlayer() }
            #elseif os(macOS)
            .safeAreaInset(edge: .bottom) {
                if remote.isActive {
                    RemoteMiniPlayer()
                        .padding(.vertical, 10)
                        .background(.bar)
                }
            }
            #endif
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: .home) {
                HomeView(path: $homePath) { selection = .downloads }
            }
            Tab("Movies", systemImage: "film", value: .movies) {
                NavigationStack {
                    LibraryGridView(list: .movies).itemDestinations()
                }
            }
            Tab("Shows", systemImage: "tv", value: .shows) {
                NavigationStack {
                    LibraryGridView(list: .shows).itemDestinations()
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
            homePath = NavigationPath([linkedItem])
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
