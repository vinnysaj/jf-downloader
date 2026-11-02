import AetherEngine
import AVKit
import SwiftUI

/// The player: the picture edge to edge, subtitles over it, and controls that fade away while
/// it plays. Tap (or move the mouse, or press a key) to bring them back.
struct PlayerView: View {
    let model: PlayerModel
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubPosition: Double?
    @State private var fillsScreen = false
    @State private var panel: PlayerPanel?
    /// Where the controls' bottom bar starts, in global coordinates.
    @State private var bottomBarTop: CGFloat?
    #if !os(tvOS)
    @FocusState private var hasKeyboardFocus: Bool
    #endif
    #if os(iOS) || os(macOS)
    @State private var pictureInPicture = PictureInPicture()
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AetherPlayerSurface(engine: model.engine)
                .ignoresSafeArea()
                .accessibilityHidden(true)
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
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
            #endif
            statusOverlay
            if controlsVisible {
                PlayerControls(model: model, scrubPosition: $scrubPosition, fillsScreen: $fillsScreen, panel: $panel,
                               bottomBarTop: $bottomBarTop,
                               onClose: onClose, onInteraction: scheduleHide, pictureInPicture: pictureInPictureAction)
                    .transition(.opacity)
            }
            // Over the controls' shading so captions stay bright; it takes no touches, and bottom
            // captions move up out of the controls' way.
            SubtitleOverlay(model: model, videoSize: fillsScreen ? nil : model.videoSize,
                            controlsTop: controlsVisible ? bottomBarTop : nil)
                .ignoresSafeArea()
            extras
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
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(.space) { model.togglePlayPause(); showControls(); return .handled }
        .onKeyPress(.leftArrow) { model.skip(by: -PlayerModel.skipInterval); showControls(); return .handled }
        .onKeyPress(.rightArrow) { model.skip(by: PlayerModel.skipInterval); showControls(); return .handled }
        .onKeyPress(.escape) {
            if panel != nil { closePanel() } else { onClose() }
            return .handled
        }
        #endif
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        #endif
        .onChange(of: fillsScreen) { _, fills in model.engine.videoGravity = fills ? .resizeAspectFill : .resizeAspect }
        .onChange(of: model.status) { _, status in
            if status == .playing { scheduleHide() } else { showControls(autoHide: false) }
            #if os(iOS) || os(macOS)
            pictureInPicture.attach(to: model.engine)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.restoreAfterBackground() } }
        }

        .task {
            #if !os(tvOS)
            hasKeyboardFocus = true
            #endif
            await model.start()
        }
        .preferredColorScheme(.dark)
    }

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
            if !controlsVisible || Self.hasNoCenterButton {
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
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    if let segment = model.skippableSegment(at: time) {
                        Button {
                            model.seek(to: segment.end)
                        } label: {
                            Label(segment.type == "Recap" ? "Skip Recap" : "Skip Intro", systemImage: "forward.end.fill")
                        }
                        .buttonStyle(.platformGlassProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("player.skipIntro")
                    }
                    if model.showsUpNext(at: time), let next = model.nextEpisode {
                        UpNextCard(model: model, episode: next)
                    }
                }
                .padding(.horizontal, Metrics.playerInset)
                .padding(.bottom, controlsVisible ? 130 : 40)
            }
        }
    }

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
        guard model.isPlaying, scrubPosition == nil, panel == nil else { return }
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
                    Button("Play Now") { Task { await model.playNextEpisode() } }
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
