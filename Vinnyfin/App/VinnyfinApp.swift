import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
#if os(visionOS)
import GroupActivities
#endif

@main
struct VinnyfinApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if os(visionOS)
    @State private var cinemaImmersion: any ImmersionStyle = .progressive(0.2...1, initialAmount: 1)
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .withAppEnvironment(appDelegate)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
        #if !os(tvOS)
        .commands {
            #if os(macOS)
            CommandGroup(replacing: .newItem) {
                Button("Open File…") { appDelegate.openFilePanel() }
                    .keyboardShortcut("o")
            }
            #endif
            AppCommands()
        }
        #endif

        #if os(macOS) || os(visionOS)
        WindowGroup("Player", id: PlayerWindow.id, for: PlaybackRequest.self) { $request in
            PlayerWindow(request: request)
                .withAppEnvironment(appDelegate)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        #else
        // The picture is the window, with no glass around it, and the window keeps its shape.
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        #endif
        .restorationBehavior(.disabled)
        #endif

        #if os(visionOS)
        ImmersiveSpace(id: CinemaSpace.id) {
            CinemaSpace()
                .withAppEnvironment(appDelegate)
        }
        // The Digital Crown brings the room back in around the theater.
        .immersionStyle(selection: $cinemaImmersion, in: .progressive)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .withAppEnvironment(appDelegate)
                .frame(minWidth: 520, minHeight: 560)
        }
        #endif
    }
}

extension View {
    /// The app's shared state, for every window.
    func withAppEnvironment(_ app: AppDelegate) -> some View {
        #if os(tvOS)
        environment(app.accounts)
            .environment(app.knownServers)
            .environment(app.settings)
            .environment(app.history)
            .environment(app.messages)
            .environment(app.player)
            .environment(app.socket)
            .environment(app.sharePlay)
        #else
        environment(app.accounts)
            .environment(app.knownServers)
            .environment(app.settings)
            .environment(app.history)
            .environment(app.messages)
            .environment(app.player)
            .environment(app.socket)
            .environment(app.sharePlay)
            .environment(app.downloads)
            .environment(app.downloadNotifications)
            .environment(app.smartDownloads)
            .environment(app.localLibrary)
            #if os(iOS) || os(visionOS)
            .environment(app.backgroundDownloads)
            .environment(app.keepAwake)
            .environment(app.diagnostics)
            #endif
            #if os(iOS) || os(macOS)
            .environment(app.remote)
            #endif
        #endif
    }
}

/// Owns the app's state from launch, including the background launches the system makes
/// to hand over finished transfers or run a background task, when no window may be shown.
final class AppDelegate: NSObject {
    let settings = AppSettings(cloud: NSUbiquitousKeyValueStore.default)
    let accounts = AccountStore()
    let history = WatchHistory()
    let messages = AppMessages()
    private(set) lazy var knownServers = KnownServers(accounts: accounts, cloud: NSUbiquitousKeyValueStore.default)
    private lazy var cloudSync = CloudSync(store: .default, settings: settings, servers: knownServers, messages: messages)
    #if os(tvOS)
    private(set) lazy var player = PlayerCoordinator(accounts: accounts, settings: settings, history: history)
    #else
    private(set) lazy var downloadNotifications = DownloadNotifications(settings: settings)
    private(set) lazy var downloads = DownloadManager(accounts: accounts, settings: settings, history: history,
                                                      notifications: downloadNotifications)
    private(set) lazy var smartDownloads = SmartDownloads(accounts: accounts, downloads: downloads, settings: settings, history: history)
    let localLibrary = LocalLibrary()
    private(set) lazy var player = PlayerCoordinator(accounts: accounts, settings: settings, history: history,
                                                     downloads: downloads, smartDownloads: smartDownloads, localLibrary: localLibrary)
    #endif
    #if os(iOS) || os(visionOS)
    private(set) lazy var keepAwake = KeepAwakeAudio(downloads: downloads, settings: settings, accounts: accounts)
    private(set) lazy var backgroundDownloads = BackgroundDownloads(downloads: downloads, smartDownloads: smartDownloads,
                                                                    keepAwake: keepAwake)
    let diagnostics = AppDiagnostics()
    #endif
    /// Jellyfin's remote control: other devices play to this one, and this one to them.
    let socket = SessionSocket()
    private(set) lazy var sharePlay = SharePlay(accounts: accounts, player: player)
    #if os(iOS) || os(macOS)
    private(set) lazy var remote = RemoteControl(accounts: accounts, socket: socket, player: player)
    #endif

    private func launched() {
        ImageCache.configure()
        let cloudSync = cloudSync
        Task { await cloudSync.run() }
        let knownServers = knownServers
        Task { await knownServers.followSignIns() }
        let player = player
        player.sharePlay = sharePlay
        socket.onCommand = { command in player.perform(command) }
        // From launch, so a session started on FaceTime before the app opened is joined.
        let sharePlay = sharePlay
        Task { await sharePlay.run() }
        #if !os(tvOS)
        downloadNotifications.start()
        let downloads = downloads
        Task { await downloads.run() }
        Task { await downloads.trackProgress() }
        #endif
        #if os(iOS) || os(visionOS)
        backgroundDownloads.registerLaunchHandlers()
        let backgroundDownloads = backgroundDownloads
        Task { await backgroundDownloads.run() }
        let keepAwake = keepAwake
        Task { await keepAwake.run() }
        let diagnostics = diagnostics
        Task { await diagnostics.run() }
        #endif
    }

    #if os(macOS)
    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DownloadsView.videoTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.playFile(url)
    }
    #endif
}

#if os(macOS)
extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        launched()
    }
}
#else
extension AppDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        launched()
        return true
    }

    #if os(iOS)
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlayerOrientationLock.allowed
    }
    #endif

    #if !os(tvOS)
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        downloads.handleBackgroundEvents(completion: completionHandler)
    }
    #endif
}
#endif

#if os(macOS) || os(visionOS)
/// A player window on the Mac and Vision Pro, one per playback.
struct PlayerWindow: View {
    static let id = "player"
    let request: PlaybackRequest?

    @Environment(PlayerCoordinator.self) private var player
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismissWindow) private var dismissWindow
    #if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif
    @State private var model: PlayerModel?

    var body: some View {
        Group {
            if let model {
                PlayerView(model: model) { dismissWindow() }
            } else {
                Color.black
            }
        }
        .environment(\.session, accounts.session)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 270)
        #else
        // Shaped like the picture, which then fills it edge to edge, at any size it's pulled to.
        .aspectRatio(pictureAspectRatio, contentMode: .fit)
        .frame(minWidth: 640, idealWidth: 1280, maxWidth: 3200)
        // Watching together, the Spatial Personas gather around this window.
        .groupActivityAssociation(.primary(PlayerWindow.id))
        #endif
        .navigationTitle(model?.title ?? request?.title ?? "vinnyfin")
        .onAppear {
            guard model == nil, let request else { return }
            model = player.makeModel(for: request)
            player.presented = model
        }
        .onDisappear {
            let closing = model
            model = nil
            if player.presented === closing { player.presented = nil }
            #if os(visionOS)
            if player.isInCinema { Task { await dismissImmersiveSpace() } }
            #endif
            Task { await closing?.close() }
        }
    }

    #if os(visionOS)
    /// 16:9 until the video says otherwise.
    private var pictureAspectRatio: CGFloat {
        guard let size = model?.videoSize, size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }
    #endif
}
#endif
