import AetherEngine
import AVKit
#if os(macOS)
import AppKit
#endif
#if os(visionOS)
import Combine
#endif
import SwiftUI

/// The player: the picture edge to edge, subtitles over it, and controls that fade away while
/// it plays. Tap (or move the mouse, or press a key) to bring them back; pinch to fill the
/// screen. On an iPhone Duo standing half open like a laptop the picture takes the top half and
/// the controls the bottom, with the show's episodes. On Vision Pro the window is the picture,
/// with the controls on glass below it, and the room dims while it plays; in the cinema the
/// picture moves to the big screen, a pinch there shows the controls, and the window stays,
/// clear, holding them.
struct PlayerView: View {
    let model: PlayerModel
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    #if os(visionOS)
    @Environment(PlayerCoordinator.self) private var coordinator
    #endif
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubPosition: Double?
    @State private var fillsScreen = false
    @State private var panel: PlayerPanel?
    /// Where the controls' bottom bar starts, in global coordinates.
    @State private var bottomBarTop: CGFloat?
    /// Where the controls' top bar ends, in global coordinates.
    @State private var topBarBottom: CGFloat?
    #if !os(tvOS)
    @FocusState private var hasKeyboardFocus: Bool
    #endif
    #if os(iOS) || os(macOS)
    @State private var pictureInPicture = PictureInPicture()
    #endif
    #if os(iOS)
    @State private var orientationLock = PlayerOrientationLock()
    /// The fold across the screen of an iPhone Duo standing half open, in window coordinates.
    @State private var fold: CGRect?
    #else
    private let fold: CGRect? = nil
    #endif

    var body: some View {
        ZStack {
            if showsPicture {
                #if !os(visionOS)
                // On Vision Pro the surface fills its own: RealityKit's picture draws behind the
                // window's views, so a fill here would hide it.
                Color.black
                    .ignoresSafeArea()
                    #if os(iOS)
                    .onGeometryChange(for: CGRect?.self) { Self.fold(in: $0) } action: { fold = $0 }
                    .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { orientationLock.windowChanged(isWide: $0) }
                    #endif
                #endif
                PlayerSurface(engine: model.engine)
                    .frame(height: fold?.minY)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            #if os(tvOS)
            if !controlsVisible {
                // Holds focus while the controls are hidden, so a click or a swipe brings them back.
                // It sits beside the controls rather than around them: a focused parent would keep
                // focus from moving between the controls.
                Color.clear
                    .ignoresSafeArea()
                    .focusable()
                    .focusEffectDisabled()
                    .onTapGesture { showControls() }
                    .onMoveCommand { _ in showControls() }
            }
            #else
            // Taps on the picture show and hide the controls; taps on a control stay with it.
            Color.clear
                .contentShape(.rect)
                .frame(height: fold?.minY)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
                // So VoiceOver, too, can bring back controls that have faded.
                .accessibilityElement()
                .accessibilityLabel("Video")
                .accessibilityHint("Shows or hides the controls")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("player.picture")
                #if os(iOS)
                .gesture(MagnifyGesture().onEnded { pinched($0.magnification) })
                #endif
            #endif
            inPictureArea { statusOverlay }
            #if os(visionOS)
            // The controls are in an ornament below the window (see `controlsOrnament`).
            #else
            if let fold {
                PlayerControls(model: model, scrubPosition: $scrubPosition, fillsScreen: $fillsScreen, panel: $panel,
                               bottomBarTop: $bottomBarTop, topBarBottom: $topBarBottom,
                               onClose: onClose, onInteraction: {}, pictureInPicture: pictureInPictureAction,
                               isBelowFold: true)
                    .padding(.top, fold.maxY)
                    .ignoresSafeArea(edges: .top)
            } else if controlsVisible {
                PlayerControls(model: model, scrubPosition: $scrubPosition, fillsScreen: $fillsScreen, panel: $panel,
                               bottomBarTop: $bottomBarTop, topBarBottom: $topBarBottom,
                               onClose: onClose, onInteraction: scheduleHide, pictureInPicture: pictureInPictureAction)
                    .transition(.opacity)
            }
            #endif
            #if os(iOS)
            if orientationLock.isAnnouncing, !showsControls {
                // Where it waits among the controls, so it seems to go back into them.
                RotateButton(onUse: scheduleHide)
                    .padding(.horizontal, Metrics.playerInset)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            #endif
            // Over the controls' shading so captions stay bright; it takes no touches, and bottom
            // captions move up out of the controls' way.
            if showsPicture {
                SubtitleOverlay(model: model, videoSize: fillsScreen ? nil : model.videoSize,
                                controlsTop: controlsVisible && fold == nil && Self.controlsArePictureOverlay ? bottomBarTop : nil)
                    .frame(height: fold?.minY)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            }
            inPictureArea { extras }
            if let notice = model.notice {
                inPictureArea {
                    PlayerNotice(text: notice, controlsBottom: controlsVisible && fold == nil && Self.controlsArePictureOverlay ? topBarBottom : nil)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let panel {
                TrackPanel(model: model, panel: panel) { closePanel() }
                    .padding(Metrics.edge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.snappy, value: panel)
        .animation(.snappy, value: model.notice)
        #if os(visionOS)
        // The window has no glass of its own; the picture takes its rounded shape.
        .clipShape(.rect(cornerRadius: 46))
        .ornament(visibility: controlsVisible ? .visible : .hidden, attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            controlsOrnament
        }
        .preferredSurroundingsEffect(model.isPlaying && showsPicture ? .dark : nil)
        // A new picture is flat until the screen showing it finds otherwise.
        .onReceive(model.engine.$currentAVPlayer.removeDuplicates { $0 === $1 }) { _ in coordinator.pictureIsStereo = false }
        .onChange(of: coordinator.screenTaps) { toggleControls() }
        #endif
        #if os(iOS)
        .animation(.snappy, value: orientationLock.isAnnouncing)
        .animation(.smooth, value: fold)
        .environment(orientationLock)
        .onHingeChange { _, context in orientationLock.hingeChanged(isHalfOpen: context.hinge?.status == .partiallyOpen) }
        .onAppear { orientationLock.start() }
        .onDisappear { orientationLock.stop() }
        #endif
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        #endif
        #if os(tvOS)
        .onPlayPauseCommand {
            model.togglePlayPause()
            showControls()
        }
        .onExitCommand {
            if panel != nil {
                closePanel()
            } else if controlsVisible, model.isPlaying {
                hideControls()
            } else {
                onClose()
            }
        }
        #else
        // The player takes focus as it opens, for the Playback menu's keys (`PlayerCommand`) and
        // for the menu to act on it: a scene value doesn't reach the menu from the full-screen
        // cover the player is on iPhone and iPad.
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(keys: PlayerCommand.keys) { press in
            guard let command = PlayerCommand.pressed(press.key, modifiers: press.modifiers) else { return .ignored }
            perform(command)
            return .handled
        }
        .focusedValue(\.player, PlayerCommandTarget(model: model, fillsScreen: fillsScreen, perform: perform))
        .handoffPlayback(model)
        #endif
        #if os(iOS)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(.hidden)
        // On iPhone Duo the controls keep to the middle of the screen, where the picture is,
        // rather than making room for a vertical bar.
        .toolbarVerticalBehavior(.disabled)
        #endif
        .onChange(of: fillsScreen) { _, fills in model.engine.videoGravity = fills ? .resizeAspectFill : .resizeAspect }
        .onChange(of: model.status) { _, status in
            switch status {
            case .playing: scheduleHide()
            // Up for a new title, and for what the viewer acts on. A new stream of the same title
            // and a stall show in the picture, and leave the controls as they were.
            case .preparing, .paused, .ended, .failed: showControls(autoHide: false)
            case .loading, .buffering: break
            }
            #if os(iOS) || os(macOS)
            pictureInPicture.attach(to: model.engine)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.restoreAfterBackground() } }
        }
        .onChange(of: model.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }

        .task {
            #if !os(tvOS)
            hasKeyboardFocus = true
            #endif
            await model.start()
        }
        .preferredColorScheme(.dark)
    }

    /// Below the fold the controls stay, off the picture.
    private var showsControls: Bool { controlsVisible || fold != nil }

    /// In the cinema the picture and its subtitles are on the big screen instead.
    private var showsPicture: Bool {
        #if os(visionOS)
        !coordinator.isInCinema
        #else
        true
        #endif
    }

    /// The controls lie over the picture, so what's along its top and bottom moves out of their
    /// way. On Vision Pro they're below the window instead.
    private static var controlsArePictureOverlay: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    #if os(visionOS)
    private var controlsOrnament: some View {
        PlayerControls(model: model, scrubPosition: $scrubPosition, fillsScreen: $fillsScreen, panel: $panel,
                       bottomBarTop: $bottomBarTop, topBarBottom: $topBarBottom,
                       onClose: onClose, onInteraction: scheduleHide, pictureInPicture: nil)
            .padding(.top, 24)
    }
    #endif

    /// `content` over the picture: above the fold when there is one, else the whole screen.
    @ViewBuilder private func inPictureArea(@ViewBuilder _ content: () -> some View) -> some View {
        if let fold {
            content()
                .frame(height: fold.minY)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        } else {
            content()
        }
    }

    #if os(iOS)
    /// The fold across the window when an iPhone Duo stands half open like a laptop. Held like
    /// a book, the fold runs down the middle and the picture spans it.
    nonisolated private static func fold(in proxy: GeometryProxy) -> CGRect? {
        proxy.reservedRegions(kind: .division)
            .first { $0.isActive && $0.frame.width > $0.frame.height }?
            .frame
    }

    /// Spreading two fingers fills the screen, cutting the picture's edges; pinching fits it.
    private func pinched(_ magnification: CGFloat) {
        if magnification > 1.15 {
            fillsScreen = true
        } else if magnification < 0.87 {
            fillsScreen = false
        }
    }
    #endif

    private static var hasNoCenterButton: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var pictureInPictureAction: (() -> Void)? {
        #if os(iOS) || os(macOS)
        pictureInPicture.isPossible ? { pictureInPicture.toggle() } : nil
        #else
        nil
        #endif
    }

    @ViewBuilder private var statusOverlay: some View {
        switch model.status {
        case .preparing, .loading, .buffering:
            // With the controls up, the play button shows this instead (on Apple TV there is none).
            if !showsControls || Self.hasNoCenterButton {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityLabel("Loading")
            }
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text("Couldn't Play This").font(.title3.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                HStack {
                    Button("Try Again") { Task { await model.retry() } }
                    if model.item != nil, !model.isTranscoding {
                        Button("Play Through the Server") { Task { await model.retryTranscoded() } }
                    }
                    Button("Close", action: onClose)
                }
                .buttonStyle(.platformGlass)
            }
            .padding(30)
            .platformGlass(in: .rect(cornerRadius: 28))
            .padding()
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var extras: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let time = model.clock.time
            // In the credits the up-next card is the way past them, when there's a next episode.
            let upNext = model.showsUpNext(at: time) ? model.nextEpisode : nil
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    if let upNext {
                        UpNextCard(model: model, episode: upNext)
                    } else if let segment = model.skippableSegment(at: time), let title = segment.skipTitle {
                        Button {
                            model.seek(to: segment.end)
                        } label: {
                            Label(title, systemImage: "forward.end.fill")
                        }
                        .buttonStyle(.platformGlassProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("player.skip")
                    }
                }
                .padding(.horizontal, Metrics.playerInset)
                .padding(.bottom, fold != nil ? 16 : controlsVisible && Self.controlsArePictureOverlay ? 130 : 40)
            }
        }
    }

    #if !os(tvOS)
    /// A command from the Playback menu, or its key. The controls come up to show what it did.
    private func perform(_ command: PlayerCommand) {
        switch command {
        case .playPause:
            model.togglePlayPause()
        case .skipBack:
            model.skip(by: -PlayerModel.skipInterval)
        case .skipForward:
            model.skip(by: PlayerModel.skipInterval)
        case .nextEpisode:
            guard let next = model.nextEpisode else { return }
            Task { await model.play(next) }
        case .fullScreen:
            #if os(macOS)
            NSApplication.shared.keyWindow?.toggleFullScreen(nil)
            #else
            fillsScreen.toggle()
            #endif
        case .close:
            if panel != nil { closePanel() } else { onClose() }
            return
        }
        showControls()
    }
    #endif

    // MARK: Controls visibility

    private func toggleControls() {
        if panel != nil {
            closePanel()
        } else if controlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    private func closePanel() {
        panel = nil
        scheduleHide()
    }

    private func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func hideControls() {
        hideTask?.cancel()
        guard model.isPlaying, scrubPosition == nil, panel == nil, fold == nil else { return }
        controlsVisible = false
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { hideControls() }
        }
    }
}

/// A brief word over the picture, such as a move to a lower quality, below the controls' top
/// bar while they show.
private struct PlayerNotice: View {
    let text: String
    /// The bottom of the controls' top bar in global coordinates while they show.
    var controlsBottom: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let clearBelow = controlsBottom.map { max(0, $0 - geometry.frame(in: .global).minY) } ?? 0
            Label(text, systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .platformGlass(in: .capsule)
                .padding(.top, clearBelow + 12)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Metrics.playerInset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.notice")
    }
}

/// The card offering the next episode near the end, counting down when it plays by itself.
private struct UpNextCard: View {
    let model: PlayerModel
    let episode: JellyfinItem
    @Environment(\.session) private var session

    var body: some View {
        HStack(spacing: 14) {
            Artwork(url: session?.landscape(episode, width: 480), aspectRatio: 16.0 / 9.0, cornerRadius: 8, placeholder: "play.rectangle")
                .frame(width: 150)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.upNextCountdown.map { "Next episode in \($0)" } ?? "Up Next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text([episode.episodeCode, episode.name].compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack {
                    Button("Play Now") { Task { await model.play(episode) } }
                        .buttonStyle(.platformGlassProminent)
                        .accessibilityIdentifier("player.playNext")
                    Button("Hide") { model.cancelUpNext() }
                        .buttonStyle(.platformGlass)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: 440)
        .platformGlass(in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.upNext")
    }
}

#if os(iOS) || os(macOS)
/// Picture in Picture for whichever layer the engine draws into: AVPlayer's on the native path,
/// the sample-buffer layer on the software path.
@Observable
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var isPossible = false
    private(set) var isActive = false
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private weak var engine: AetherEngine?
    @ObservationIgnored private var attachedLayer: AnyObject?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?

    /// Builds the controller for the layer the engine is drawing into now.
    func attach(to engine: AetherEngine) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        self.engine = engine
        let controller: AVPictureInPictureController?
        if let layer = engine.nativePlayerLayer {
            guard attachedLayer !== layer else { return }
            attachedLayer = layer
            controller = AVPictureInPictureController(playerLayer: layer)
        } else if let source = engine.softwarePiPSource {
            guard attachedLayer !== source.layer else { return }
            attachedLayer = source.layer
            controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: self))
        } else {
            return
        }
        controller?.delegate = self
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        self.controller = controller
        possibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = true
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = false
            self.isActive = false
        }
    }

    // Sample-buffer playback, answered from the engine's software source.

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.engine?.softwarePiPSource?.setPlaying(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated { engine?.softwarePiPSource?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { engine?.softwarePiPSource?.isPaused ?? true }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        await MainActor.run { engine?.softwarePiPSource?.skip(by: skipInterval.seconds) }
    }
}

/// The system's AirPlay and audio route button.
struct RoutePicker: View {
    var body: some View {
        RoutePickerRepresentable()
            .frame(width: 32, height: 32)
            .accessibilityLabel("AirPlay")
    }
}

#if os(iOS)
private struct RoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
private struct RoutePickerRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif
#endif

#if os(iOS)
/// Turns the player the way the phone is turned, while it holds still for watching lying down.
struct RotateButton: View {
    var onUse: () -> Void = {}
    @Environment(PlayerOrientationLock.self) private var lock: PlayerOrientationLock?

    var body: some View {
        if let lock, let offer = lock.offer {
            Button {
                lock.rotate()
                onUse()
            } label: {
                Image(systemName: offer.isPortrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.platformGlass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Rotate")
            .accessibilityIdentifier("player.rotate")
        }
    }
}
#endif
