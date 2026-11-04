import AetherEngine
import SwiftUI

/// The player's controls over the picture: close and title along the top, transport in the
/// middle, the timeline and track menus along the bottom. Below the fold of an iPhone Duo
/// standing half open they sit under the picture instead, with the show's episodes.
struct PlayerControls: View {
    let model: PlayerModel
    @Binding var scrubPosition: Double?
    @Binding var fillsScreen: Bool
    @Binding var panel: PlayerPanel?
    /// Where the timeline and buttons start, in global coordinates, so subtitles can stay above them.
    @Binding var bottomBarTop: CGFloat?
    /// Where the title and its buttons end, in global coordinates, so notices can stay below them.
    @Binding var topBarBottom: CGFloat?
    let onClose: () -> Void
    /// Called on every use, so the controls stay up while they're being used.
    let onInteraction: () -> Void
    /// Nil when Picture in Picture isn't possible right now.
    let pictureInPicture: (() -> Void)?
    var isBelowFold = false
    #if os(tvOS)
    /// The controls the remote moves between. Moving counts as using them, so they stay up.
    private enum Control: Hashable {
        case timeline, playPause, next
        case panel(PlayerPanel)
    }

    @FocusState private var focusedControl: Control?
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            if isBelowFold { belowFold } else { overPicture }
            #else
            overPicture
            #endif
        }
        .foregroundStyle(.white)
        #if os(tvOS)
        .defaultFocus($focusedControl, .timeline)
        .onChange(of: focusedControl) { onInteraction() }
        // Back to the button that opened a panel once it closes.
        .onChange(of: panel) { closed, opened in
            if opened == nil, let closed { focusedControl = .panel(closed) }
        }
        #endif
    }

    private var overPicture: some View {
        ZStack {
            // Dark enough behind the timeline to read it over a bright picture.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.7), location: 0),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 0.5),
                .init(color: .black.opacity(0.6), location: 0.78),
                .init(color: .black.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                #if !os(tvOS)
                transport
                Spacer()
                #endif
                bottomBar
            }
            .padding(.horizontal, Metrics.playerInset)
            .padding(.vertical, 12)
        }
    }

    #if os(iOS)
    private var belowFold: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                topBar
                bottomBar
                transport
            }
            .padding(.horizontal, Metrics.playerInset)
            if let item = model.item, item.isEpisode {
                FoldEpisodes(model: model, playing: item)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
    }
    #endif

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: 14) {
            #if !os(tvOS)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.platformGlass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("player.close")
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline).lineLimit(1)
                if let subtitle = model.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.top, 6)
            Spacer()
            FormatBadge(model: model).padding(.top, 6)
            #if os(iOS) || os(macOS)
            RoutePicker()
            if let pictureInPicture {
                Button(action: pictureInPicture) {
                    Image(systemName: "pip.enter").font(.headline).frame(width: 22, height: 22)
                }
                .buttonStyle(.platformGlass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Picture in Picture")
            }
            #endif
            #if os(iOS)
            // Last, where it shows by itself as the phone turns.
            RotateButton(onUse: onInteraction)
            #endif
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }
    }

    // MARK: Middle

    #if !os(tvOS)
    private var transport: some View {
        // Smaller below the fold, where it shares the half screen with the episodes.
        let scale: CGFloat = isBelowFold ? 0.75 : 1
        return HStack(spacing: 44 * scale) {
            transportButton("gobackward.10", label: "Back 10 Seconds", size: 30 * scale) { model.skip(by: -PlayerModel.skipInterval) }
            transportButton(playPauseSymbol, label: model.isPlaying ? "Pause" : "Play", size: 44 * scale, showsProgress: isWaiting) {
                model.togglePlayPause()
            }
            .accessibilityIdentifier("player.playPause")
            transportButton("goforward.10", label: "Forward 10 Seconds", size: 30 * scale) { model.skip(by: PlayerModel.skipInterval) }
        }
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, showsProgress: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Group {
                if showsProgress {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: size * 1.6, height: size * 1.6)
        }
        .buttonStyle(.platformGlass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
    #endif

    /// Loading or refilling the buffer: the play button turns into the spinner.
    private var isWaiting: Bool {
        switch model.status {
        case .preparing, .loading, .buffering: true
        default: false
        }
    }

    private var playPauseSymbol: String {
        switch model.status {
        case .ended: "arrow.counterclockwise"
        default: model.isPlaying ? "pause.fill" : "play.fill"
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 10) {
            #if os(tvOS)
            Scrubber(model: model, position: $scrubPosition, onInteraction: onInteraction) { focusedControl = .playPause }
                .focused($focusedControl, equals: .timeline)
            #else
            Scrubber(model: model, position: $scrubPosition, onInteraction: onInteraction)
            #endif
            HStack(spacing: 12) {
                #if os(tvOS)
                Button {
                    model.togglePlayPause()
                    onInteraction()
                } label: {
                    Image(systemName: playPauseSymbol)
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .focused($focusedControl, equals: .playPause)
                #endif
                trackMenus
                    .labelStyle(.iconOnly)
                Spacer()
                if let next = model.nextEpisode {
                    Button {
                        Task { await model.play(next) }
                    } label: {
                        Label("Next Episode", systemImage: "forward.end.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.platformGlass)
                    .accessibilityHint(next.name)
                    #if os(tvOS)
                    .focused($focusedControl, equals: .next)
                    #endif
                }
                #if os(iOS)
                Button {
                    fillsScreen.toggle()
                    onInteraction()
                } label: {
                    Image(systemName: fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.platformGlass)
                .accessibilityLabel(fillsScreen ? "Fit to Screen" : "Fill Screen")
                #endif
            }
            .controlSize(controlSize)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomBarTop = $0 }
    }

    private var controlSize: ControlSize {
        #if os(tvOS)
        .regular
        #else
        .large
        #endif
    }

    @ViewBuilder private var trackMenus: some View {
        panelButton(.audio, identifier: "player.audio")
            .disabled(model.audioOptions.isEmpty)
        panelButton(.subtitles, identifier: "player.subtitles", filled: model.selectedSubtitle != nil)
        panelButton(.speed, identifier: "player.speed")
    }

    private func panelButton(_ kind: PlayerPanel, identifier: String, filled: Bool = false) -> some View {
        Button {
            panel = panel == kind ? nil : kind
            onInteraction()
        } label: {
            Label(kind.title, systemImage: filled ? kind.symbol + ".fill" : kind.symbol)
        }
        .buttonStyle(.platformGlass)
        #if os(tvOS)
        .focused($focusedControl, equals: .panel(kind))
        #endif
        .accessibilityIdentifier(identifier)
    }
}

/// What's on screen when it's worth saying: Dolby Vision, HDR, or that the server is transcoding.
private struct FormatBadge: View {
    let model: PlayerModel

    var body: some View {
        if let text {
            Text(text)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .platformGlass(in: .capsule)
                .accessibilityIdentifier("player.format")
        }
    }

    private var text: String? {
        var parts: [String] = []
        switch model.videoFormat {
        case .dolbyVision: parts.append("Dolby Vision")
        case .hdr10: parts.append("HDR10")
        case .hdr10Plus: parts.append("HDR10+")
        case .hlg: parts.append("HLG")
        case .sdr: break
        }
        if model.isTranscoding { parts.append("Transcoding") }
        if model.current?.isDownload == true { parts.append("Downloaded") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The timeline: how far along, how much is buffered, and a handle to drag (or, on Apple TV,
/// to move with the remote and click to jump).
struct Scrubber: View {
    let model: PlayerModel
    @Binding var position: Double?
    let onInteraction: () -> Void
    #if os(tvOS)
    /// Swiping down off the timeline. Its move handler takes every direction, so it passes focus
    /// on itself.
    let onMoveDown: () -> Void
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        let duration = max(model.duration, 1)
        let time = position ?? model.clock.time
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.4))
                        .frame(width: width * min(1, max(0, model.clock.buffered / duration)))
                    Capsule().fill(.white)
                        .frame(width: width * min(1, max(0, time / duration)))
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity)
                #if !os(tvOS)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            position = min(duration, max(0, value.location.x / width * duration))
                            onInteraction()
                        }
                        .onEnded { _ in
                            if let position { model.seek(to: position) }
                            self.position = nil
                        }
                )
                #endif
            }
            .frame(height: 24)
            HStack {
                Text(Self.format(time)).monospacedDigit()
                Spacer()
                Text("-" + Self.format(max(0, duration - time))).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        #if os(tvOS)
        .padding(.vertical, 8)
        .focusable()
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1)
        .onMoveCommand { direction in
            let step = max(10, duration / 200)
            switch direction {
            case .left: position = max(0, (position ?? model.clock.time) - step)
            case .right: position = min(duration, (position ?? model.clock.time) + step)
            case .down:
                onMoveDown()
                return
            default: return
            }
            onInteraction()
        }
        .onTapGesture {
            if let position {
                model.seek(to: position)
                self.position = nil
            } else {
                model.togglePlayPause()
            }
            onInteraction()
        }
        .onChange(of: isFocused) { _, focused in if !focused { position = nil } }
        #endif
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(Self.format(time)) of \(Self.format(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.skip(by: PlayerModel.skipInterval)
            case .decrement: model.skip(by: -PlayerModel.skipInterval)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("player.timeline")
    }

    private var barHeight: CGFloat {
        #if os(tvOS)
        isFocused ? 12 : 8
        #else
        position == nil ? 5 : 9
        #endif
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
