import AppIntents
import SwiftUI

struct RootView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppMessages.self) private var messages
    @Environment(WatchHistory.self) private var history
    @Environment(AppSettings.self) private var settings
    @Environment(IncomingLinks.self) private var links
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
    @Environment(DownloadManager.self) private var downloads
    @Environment(SpotlightTitles.self) private var spotlight
    /// A title handed off from a sign-in this device doesn't have, until it has it.
    @State private var handoff: Handoff?
    @State private var showingHandoffMismatch = false
    /// The sign-in screen, for the server a handed-off title is from.
    @State private var handoffSignIn: ServerSignIn?
    #endif
    /// A title a link asked to open, for Home to show.
    @State private var linkedItem: JellyfinItem?
    #if os(iOS)
    /// The full-screen player is up, until it has finished going away.
    @State private var playerCovers = false
    #endif

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
        .fullScreenCover(item: $player.presented) {
            #if os(iOS)
            playerCovers = false
            #endif
        } content: { model in
            PlayerView(model: model) { Task { await player.dismiss() } }
                .environment(\.session, session)
                #if os(iOS)
                .onAppear { playerCovers = true }
                #endif
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
        #if !os(tvOS)
        .alert("Download a Transcode?", isPresented: Binding(get: { downloads.transcodes.proposal != nil },
                                                             set: { if !$0 { downloads.transcodes.proposal = nil } }),
               presenting: downloads.transcodes.proposal) { proposal in
            Button("Download Transcode") { downloads.enqueue(proposal.item, plan: proposal.plan, startedByUser: true) }
                .accessibilityIdentifier("transcode.download")
            Button("Download As It Is (\(proposal.original.summary))") {
                downloads.enqueue(proposal.item, plan: proposal.original, startedByUser: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { proposal in
            Text(proposal.message)
        }
        #endif
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
        .onOpenURL { url in open(url) }
        // A tapped notification, Siri, Shortcuts, Spotlight and Handoff open titles as a link would.
        .onChange(of: links.pending, initial: true) { _, incoming in
            guard let incoming else { return }
            links.pending = nil
            follow(incoming)
        }
        #if !os(tvOS)
        .onContinueUserActivity(Handoff.activityType) { activity in
            guard let handoff = Handoff(activity) else {
                messages.show("vinnyfin can't continue what your other device handed over. Updating vinnyfin on both may help.")
                return
            }
            links.open(handoff)
        }
        .alert(handoffMismatch.map(Handoff.title) ?? "", isPresented: $showingHandoffMismatch, presenting: handoff) { handoff in
            if let mismatch = handoffMismatch {
                Button(handoff.signInTitle(for: mismatch)) { Task { await signIn(for: handoff) } }
            }
            Button("Cancel", role: .cancel) { self.handoff = nil }
        } message: { handoff in
            Text(handoffMismatch.map { handoff.explanation(for: $0, on: Device.name) } ?? "")
        }
        .sheet(item: $handoffSignIn, onDismiss: {
            if handoff?.signIn.isSignedIn(as: accounts.account) != true { handoff = nil }
        }) { signIn in
            LoginView(offer: signIn)
        }
        // Once signed in where the handed-off title is from, it opens.
        .onChange(of: accounts.account) { _, account in
            guard let handoff, handoff.signIn.isSignedIn(as: account) else { return }
            self.handoff = nil
            open(handoff.link)
        }
        #endif
        #if os(macOS)
        // Links and handed-off titles open in the window that's open, rather than in a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        #endif
        // Runs while the app is open, and stops as it goes to the background.
        .task(id: scenePhase == .background) {
            guard scenePhase != .background else {
                #if os(tvOS)
                TopShelf.reload()
                #elseif os(iOS)
                UpNextWidgets.reload()
                #endif
                // What's being watched, which Siri's phrases name, may have changed while it was open.
                VinnyfinShortcuts.updateAppShortcutParameters()
                return
            }
            // What was watched offline goes to the server first, so smart downloads plan from it.
            if let session { await history.syncPending(using: session.client, userId: session.userId) }
            #if !os(tvOS)
            async let spotlightRefresh: Void = spotlight.refreshWhileOpen()
            await smartDownloads.refreshWhileOpen()
            await spotlightRefresh
            #endif
        }
    }

    #if os(iOS) || os(macOS)
    /// The remote's screen. On iPhone and iPad it waits for the player that handed its playback
    /// over to be gone: a sheet presented over the full-screen player keeps it from closing, and
    /// one presented while it goes takes on its dark appearance on a light sheet.
    private var showsRemoteScreen: Binding<Bool> {
        Binding {
            #if os(iOS)
            remote.showsScreen && !playerCovers
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
            player.play(.item(link.item, continuingFrom: link.position))
        case .open:
            guard session != nil else {
                messages.show("Sign in to see \(link.name).")
                return
            }
            Task { await player.dismiss() }
            linkedItem = link.item
        }
    }

    private func follow(_ incoming: IncomingLinks.Incoming) {
        switch incoming {
        case .link(let url):
            open(url)
        #if !os(tvOS)
        case .handoff(let handoff):
            continueHandoff(handoff)
        #endif
        }
    }

    #if !os(tvOS)
    /// Opens a title handed off from another of the person's devices, when this one is signed in
    /// where it's from; otherwise says where it's signed in, and offers to sign in there.
    private func continueHandoff(_ handoff: Handoff) {
        if handoff.mismatch(with: accounts.account) == nil {
            open(handoff.link)
        } else {
            self.handoff = handoff
            showingHandoffMismatch = true
        }
    }

    private var handoffMismatch: Handoff.Mismatch? {
        handoff?.mismatch(with: accounts.account)
    }

    /// Signs out of where this device is signed in, as Settings does, and opens the sign-in for
    /// where the title is from.
    private func signIn(for handoff: Handoff) async {
        if accounts.account != nil { await accounts.signOut(cancelling: downloads) }
        handoffSignIn = handoff.signIn
    }
    #endif
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
    @Environment(PlayerCoordinator.self) private var player
    /// The Go menu's Search commands so far, each of which puts the cursor in the search field.
    @State private var searchFieldRequests = 0
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
                #if os(tvOS)
                SearchView()
                #else
                SearchView(fieldRequests: searchFieldRequests)
                #endif
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if !os(tvOS)
        // While the player covers the tabs, the Go menu waits for it to close.
        .focusedSceneValue(\.tabs, player.coversScreens ? nil : TabCommandTarget(go: go))
        #endif
        .onChange(of: linkedItem, initial: true) {
            guard let linkedItem else { return }
            selection = .home
            homePath = NavigationPath([linkedItem])
            self.linkedItem = nil
        }
    }

    #if !os(tvOS)
    private func go(_ command: TabCommand) {
        selection = command.destination
        if command == .search { searchFieldRequests += 1 }
    }
    #endif
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
