import AetherEngine
import Foundation
import Observation

/// Starts playbacks and owns the one playback engine, which is built once and reused for every
/// title, as the engine expects. On iPhone, iPad and Apple TV the player covers the app; on the
/// Mac and Vision Pro it opens in a window of its own.
@Observable
final class PlayerCoordinator {
    /// The playback on screen: the full-screen player's, or the player window's, which sets it.
    var presented: PlayerModel?
    /// A playback waiting for the root view to open its window, on the Mac and Vision Pro.
    var pendingWindowRequest: PlaybackRequest?
    #if os(visionOS)
    /// The playback is on the cinema's big screen, in its immersive space, rather than in its window.
    var isInCinema = false
    /// RealityKit is drawing the picture in 3D.
    var pictureIsStereo = false
    /// Pinches on RealityKit's screen, in the window or the cinema, counted: the player window shows
    /// or hides its controls on each.
    var screenTaps = 0
    #endif
    /// Why the engine couldn't be built, to show instead of playing.
    var problem: String?

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private var engine: AetherEngine?
    @ObservationIgnored private let lease = EngineLease()
    #if !os(tvOS)
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let smartDownloads: SmartDownloads
    @ObservationIgnored private let localLibrary: LocalLibrary

    init(accounts: AccountStore, settings: AppSettings, history: WatchHistory,
         downloads: DownloadManager, smartDownloads: SmartDownloads, localLibrary: LocalLibrary) {
        self.accounts = accounts
        self.settings = settings
        self.history = history
        self.downloads = downloads
        self.smartDownloads = smartDownloads
        self.localLibrary = localLibrary
    }
    #else
    init(accounts: AccountStore, settings: AppSettings, history: WatchHistory) {
        self.accounts = accounts
        self.settings = settings
        self.history = history
    }
    #endif

    func play(_ request: PlaybackRequest) {
        #if os(macOS) || os(visionOS)
        pendingWindowRequest = request
        #else
        Task { await present(request) }
        #endif
    }

    /// Plays a file the user picked, remembering it among the recent files. The caller holds
    /// access to the file while this runs.
    func playFile(_ url: URL) {
        do {
            let request = try PlaybackRequest.file(url)
            #if !os(tvOS)
            localLibrary.noteOpened(url, request: request)
            #endif
            play(request)
        } catch {
            problem = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func present(_ request: PlaybackRequest) async {
        if let presented { await presented.close() }
        presented = makeModel(for: request)
    }

    func dismiss() async {
        guard let model = presented else { return }
        presented = nil
        await model.close()
    }

    /// A model for `request`, on the shared engine. Nil when the engine can't be built.
    func makeModel(for request: PlaybackRequest) -> PlayerModel? {
        guard let engine = sharedEngine() else { return nil }
        #if os(tvOS)
        let resolver = PlaybackResolver(accounts: accounts, settings: settings, history: history) { _, _ in nil }
        let model = PlayerModel(request: request, engine: engine, lease: lease, resolver: resolver, accounts: accounts,
                                history: history, settings: settings) { _ in nil }
        #else
        let resolver = PlaybackResolver(accounts: accounts, settings: settings, history: history) { [downloads] itemId, mediaSourceId in
            downloads.playableFile(itemId: itemId, mediaSourceId: mediaSourceId)
        }
        let model = PlayerModel(request: request, engine: engine, lease: lease, resolver: resolver, accounts: accounts,
                                history: history, settings: settings) { [downloads] episode in
            downloads.downloadedEpisode(after: episode)
        }
        // Downloads wait while something plays, and smart downloads while the player is open.
        let id = model.id
        downloads.playerChanged(id, isPlaying: true)
        smartDownloads.playerOpened(id)
        model.onUnderwayChanged = { [downloads] underway in downloads.playerChanged(id, isPlaying: underway) }
        model.onClose = { [downloads, smartDownloads] in
            downloads.playerClosed(id)
            smartDownloads.playerClosed(id)
        }
        #endif
        return model
    }

    private func sharedEngine() -> AetherEngine? {
        if let engine { return engine }
        do {
            let engine = try AetherEngine()
            // The player draws its own controls, so the engine owns the system's Now Playing
            // card and remote commands on both of its decode paths.
            #if os(iOS) || os(tvOS)
            engine.ownsVideoNowPlayingSession = true
            #endif
            engine.ownsSoftwareNowPlaying = true
            engine.remoteSkipInterval = PlayerModel.skipInterval
            self.engine = engine
            return engine
        } catch {
            problem = "The player couldn't start: \(error.localizedDescription)"
            return nil
        }
    }
}
