import AetherEngine
import Nuke
import OSLog
import SwiftUI

/// The player's controls over the picture: close and title along the top, transport in the
/// middle, the timeline and track menus along the bottom. Below the fold of an iPhone Duo
/// standing half open they sit under the picture instead, with the show's episodes, and on
/// Vision Pro on a pane of glass below the window, with the transport in the bottom row.
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
            #elseif os(visionOS)
            underWindow
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
                EpisodeStrip(model: model, playing: item, onInteraction: onInteraction)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
    }
    #endif

    #if os(visionOS)
    private var underWindow: some View {
        VStack(spacing: 18) {
            VStack(spacing: 14) {
                topBar
                bottomBar
            }
            .padding(.horizontal, 28)
            if let item = model.item, item.isEpisode {
                EpisodeStrip(model: model, playing: item, onInteraction: onInteraction)
            }
        }
        .padding(.vertical, 22)
        .frame(width: 920)
        .glassBackgroundEffect(in: .rect(cornerRadius: 40))
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
        // Smaller below the fold, where it shares the half screen with the episodes, and in
        // Vision Pro's bar, where it shares a row with the other buttons.
        #if os(visionOS)
        let scale: CGFloat = 0.6
        #else
        let scale: CGFloat = isBelowFold ? 0.75 : 1
        #endif
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
                #if os(visionOS)
                CinemaButton(onUse: onInteraction)
                #endif
            }
            .controlSize(controlSize)
            #if os(visionOS)
            // In the middle of the row, whatever is at its ends.
            .overlay { transport.controlSize(controlSize) }
            #endif
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
        if !model.chapters.isEmpty {
            panelButton(.chapters, identifier: "player.chapters")
        }
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

/// What's on screen when it's worth saying: 3D, Dolby Vision, HDR, or that the server is transcoding.
private struct FormatBadge: View {
    let model: PlayerModel
    #if os(visionOS)
    @Environment(PlayerCoordinator.self) private var coordinator
    #endif

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
        #if os(visionOS)
        if coordinator.pictureIsStereo { parts.append("3D") }
        #endif
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

/// The timeline: how far along, how much is buffered, where chapters start, and a handle to drag
/// (or, on Apple TV, to move with the remote and click to jump). While it moves, a preview over
/// it shows the picture there, when the server made scrub previews, and the chapter.
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
                    ForEach(model.chapters.filter { $0.start > 0 && $0.start < duration }) { chapter in
                        Rectangle().fill(.black.opacity(0.55))
                            .frame(width: 2)
                            .offset(x: width * chapter.start / duration - 1)
                    }
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    if let position {
                        ScrubPreview(model: model, time: position)
                            .alignmentGuide(.leading) { preview in
                                // Centered over the handle, kept within the timeline.
                                let center = width * min(1, max(0, position / duration))
                                return -min(max(0, center - preview.width / 2), max(0, width - preview.width))
                            }
                            .alignmentGuide(.bottom) { preview in preview.height + 18 }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
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
            #if os(visionOS)
            // Tall enough to look at and pinch, and lit under the eyes as a slider is.
            .frame(height: 44)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
            #else
            .frame(height: 24)
            #endif
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

/// Over the timeline while it moves: the picture at that point, when the server made scrub
/// previews, with the chapter and the time under it.
private struct ScrubPreview: View {
    let model: PlayerModel
    let time: Double

    var body: some View {
        let chapter = ChapterMark.current(in: model.chapters, at: time)
        VStack(spacing: 4) {
            if let tiles = model.trickplay {
                TrickplayThumbnail(tiles: tiles, time: time)
                    .frame(width: Self.thumbnailWidth)
                    .clipShape(.rect(cornerRadius: 8))
            }
            if let chapter {
                Text(chapter.name).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text(Scrubber.format(time)).font(.caption).monospacedDigit()
        }
        .padding(model.trickplay == nil ? 8 : 4)
        .frame(maxWidth: Self.thumbnailWidth + 8)
        .platformGlass(in: .rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private static var thumbnailWidth: CGFloat {
        #if os(tvOS)
        320
        #else
        CGFloat(TrickplayTiles.preferredWidth) / 2
        #endif
    }
}

/// One thumbnail cut from its sheet of scrub previews, which comes from the image cache, or from
/// disk for a download.
private struct TrickplayThumbnail: View {
    let tiles: TrickplayTiles
    let time: Double
    @State private var sheet: (index: Int, image: CGImage)?
    /// The sheet that couldn't be loaded, whose thumbnails say so.
    @State private var failedSheet: Int?

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")

    var body: some View {
        let spot = tiles.thumbnail(at: time)
        Group {
            if let spot, let sheet, sheet.index == spot.sheet, let thumbnail = sheet.image.cropping(to: spot.rect) {
                Image(decorative: thumbnail, scale: 1).resizable()
            } else {
                Rectangle().fill(.black.opacity(0.6))
                    .overlay {
                        if let spot, failedSheet == spot.sheet {
                            Text("No preview").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .aspectRatio(CGFloat(tiles.info.width) / CGFloat(max(1, tiles.info.height)), contentMode: .fit)
        .task(id: spot?.sheet) {
            guard let index = spot?.sheet, sheet?.index != index else { return }
            do {
                let image = try await ImagePipeline.shared.image(for: tiles.sheets[index])
                #if os(macOS)
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                let cgImage = image.cgImage
                #endif
                if let cgImage {
                    sheet = (index, cgImage)
                } else {
                    Self.log.notice("Scrub preview sheet \(index) has no bitmap")
                    failedSheet = index
                }
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.notice("Couldn't load scrub previews: \(error.localizedDescription, privacy: .public)")
                failedSheet = index
            }
        }
    }
}
