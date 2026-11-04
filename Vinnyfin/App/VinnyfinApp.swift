import AppIntents
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open File…") { appDelegate.openFilePanel() }
                    .keyboardShortcut("o")
            }
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
            .environment(app.settings)
            .environment(app.history)
            .environment(app.messages)
            .environment(app.player)
        #else
        environment(app.accounts)
            .environment(app.settings)
            .environment(app.history)
            .environment(app.messages)
            .environment(app.player)
            .environment(app.downloads)
            .environment(app.downloadNotifications)
            .environment(app.smartDownloads)
            .environment(app.localLibrary)
            #if os(iOS) || os(visionOS)
            .environment(app.backgroundDownloads)
            .environment(app.diagnostics)
            #endif
            #if os(iOS) || os(macOS)
            .environment(app.widgetDownloads)
            #endif
        #endif
    }
}

/// Owns the app's state from launch, including the background launches the system makes
/// to hand over finished transfers or run a background task, when no window may be shown.
final class AppDelegate: NSObject {
    let settings = AppSettings()
    #if os(iOS) || os(macOS)
    let accounts = AccountStore(movingSignInFrom: .standard)
    #else
    let accounts = AccountStore()
    #endif
    let history = WatchHistory()
    let messages = AppMessages()
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
    private(set) lazy var backgroundDownloads = BackgroundDownloads(downloads: downloads, smartDownloads: smartDownloads)
    let diagnostics = AppDiagnostics()
    #endif
    #if os(iOS) || os(macOS)
    private(set) lazy var widgetDownloads = WidgetDownloads(downloads: downloads, history: history)
    #endif

    private func launched() {
        ImageCache.configure()
        #if os(iOS) || os(macOS)
        if let problem = accounts.sharingProblem { messages.show(problem) }
        #endif
        #if !os(tvOS)
        downloadNotifications.start()
        let downloads = downloads
        let smartDownloads = smartDownloads
        // Siri, Shortcuts and the Downloads control act on these, also with the app in the background.
        AppDependencyManager.shared.add(dependency: self.accounts)
        AppDependencyManager.shared.add(dependency: self.settings)
        AppDependencyManager.shared.add(dependency: self.history)
        AppDependencyManager.shared.add(dependency: downloads)
        AppDependencyManager.shared.add(dependency: smartDownloads)
        Task { await downloads.run() }
        Task { await downloads.trackProgress() }
        #endif
        #if os(iOS) || os(macOS)
        let widgetDownloads = widgetDownloads
        AppDependencyManager.shared.add(dependency: widgetDownloads as any DownloadsRunning)
        Task { await widgetDownloads.run() }
        #endif
        #if os(iOS) || os(visionOS)
        backgroundDownloads.registerLaunchHandlers()
        let backgroundDownloads = backgroundDownloads
        Task { await backgroundDownloads.run() }
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

    /// The desktop's widgets come into view as another app takes over.
    func applicationDidResignActive(_ notification: Notification) {
        UpNextWidgets.reload()
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
