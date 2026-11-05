#if os(iOS) || os(macOS)
import SwiftUI

/// This device as the remote for a playback on another: the title, the timeline to scrub, the
/// transport, the tracks and the next episode, from the device's session on the server.
struct RemoteScreen: View {
    @Environment(RemoteControl.self) private var remote
    @Environment(\.session) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition: Double?

    var body: some View {
        NavigationStack {
            Group {
                if let target = remote.target {
                    ScrollView {
                        content(target)
                            .padding(24)
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView("Not Playing Elsewhere", systemImage: "tv")
                }
            }
            .screenTitle(remote.target.map { "On \($0.name)" } ?? "Remote")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // A playback that's gone has nothing left to follow; one that plays stays in the mini player.
                        if remote.isLost { remote.disconnect() } else { dismiss() }
                    }
                    .accessibilityIdentifier("remote.done")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }

    @ViewBuilder private func content(_ target: RemoteControl.Target) -> some View {
        VStack(spacing: 22) {
            if let item = remote.item {
                // Small enough that the controls fit below it on an iPhone.
                Artwork(url: session?.poster(item, width: 600), aspectRatio: item.isEpisode ? 16.0 / 9.0 : 2.0 / 3.0, cornerRadius: 14)
                    .frame(maxWidth: 520, maxHeight: 260)
                    .shadow(radius: 12, y: 6)
                VStack(spacing: 4) {
                    Text(item.isEpisode ? item.name : item.titleWithYear)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let subtitle = PlaybackResolver.subtitle(item) {
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("remote.title")
            }
            phase(target)
            if remote.item != nil {
                timeline
                transport(target)
                tracks(target)
            }
            if let error = remote.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            actions
        }
    }

    @ViewBuilder private func phase(_ target: RemoteControl.Target) -> some View {
        switch remote.phase {
        case .starting:
            HStack(spacing: 10) {
                ProgressView()
                Text("Starting on \(target.name)…")
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("remote.starting")
        case .playing:
            Label("Playing on \(target.name)", systemImage: "tv")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("remote.playing")
        case .lost(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("remote.lost")
        }
    }

    /// The player's timeline bar, rather than a Slider: in this sheet a Slider's drag never ends,
    /// so it never seeks.
    private var timeline: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(remote.duration, 1)
            let time = remote.position(at: context.date)
            let position = scrubPosition ?? time
            VStack(spacing: 4) {
                TimelineBar(time: time, duration: duration, color: .primary, height: scrubPosition == nil ? 6 : 10,
                            position: $scrubPosition) { remote.seek(to: $0) }
                    .frame(height: 28)
                    .disabled(remote.isStarting || remote.duration == 0)
                    .accessibilityElement()
                    .accessibilityLabel("Position")
                    .accessibilityValue("\(Scrubber.format(position)) of \(Scrubber.format(remote.duration))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: remote.skip(by: RemoteCommand.skipInterval)
                        case .decrement: remote.skip(by: -RemoteCommand.skipInterval)
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier("remote.timeline")
                HStack {
                    Text(Scrubber.format(position))
                    Spacer()
                    Text("-" + Scrubber.format(max(0, remote.duration - position)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func transport(_ target: RemoteControl.Target) -> some View {
        HStack(spacing: 36) {
            Button("Back 10 Seconds", systemImage: "gobackward.10") { remote.skip(by: -RemoteCommand.skipInterval) }
                .font(.title)
            Button(remote.isPaused ? "Play" : "Pause", systemImage: remote.isPaused ? "play.fill" : "pause.fill") { remote.togglePause() }
                .font(.system(size: 44))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityIdentifier("remote.playPause")
            Button("Forward 10 Seconds", systemImage: "goforward.10") { remote.skip(by: RemoteCommand.skipInterval) }
                .font(.title)
            if remote.item?.isEpisode == true {
                Button("Next Episode", systemImage: "forward.end.fill") { remote.nextEpisode() }
                    .font(.title2)
                    .accessibilityIdentifier("remote.next")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .disabled(remote.isStarting)
    }

    @ViewBuilder private func tracks(_ target: RemoteControl.Target) -> some View {
        let streams = remote.session?.nowPlayingStreams ?? []
        let audio = streams.filter { $0.type == "Audio" }
        let subtitles = streams.filter { $0.type == "Subtitle" }
        let canChooseAudio = target.supportedCommands.contains(GeneralCommandName.setAudioStreamIndex.rawValue) && audio.count > 1
        let canChooseSubtitles = target.supportedCommands.contains(GeneralCommandName.setSubtitleStreamIndex.rawValue) && !subtitles.isEmpty
        if canChooseAudio || canChooseSubtitles {
            HStack(spacing: 12) {
                if canChooseAudio {
                    Menu {
                        Picker("Audio", selection: Binding(get: { remote.session?.playState.audioStreamIndex ?? -1 },
                                                           set: { remote.chooseAudio($0) })) {
                            ForEach(audio, id: \.index) { stream in
                                Text(stream.displayTitle ?? stream.language ?? "Track \(stream.index ?? 0)").tag(stream.index ?? -1)
                            }
                        }
                    } label: {
                        Label("Audio", systemImage: "waveform")
                    }
                    .accessibilityIdentifier("remote.audio")
                }
                if canChooseSubtitles {
                    Menu {
                        Picker("Subtitles", selection: Binding(get: { remote.session?.playState.subtitleStreamIndex ?? -1 },
                                                               set: { remote.chooseSubtitle($0 < 0 ? nil : $0) })) {
                            Text("Off").tag(-1)
                            ForEach(subtitles, id: \.index) { stream in
                                Text(stream.displayTitle ?? stream.language ?? "Track \(stream.index ?? 0)").tag(stream.index ?? -1)
                            }
                        }
                    } label: {
                        Label("Subtitles", systemImage: "captions.bubble")
                    }
                    .accessibilityIdentifier("remote.subtitles")
                }
            }
            .buttonStyle(.bordered)
            .disabled(remote.isStarting)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if remote.item != nil {
                Button("Play Here", systemImage: "iphone") { remote.playHere() }
                    .accessibilityIdentifier("remote.playHere")
            }
            if !remote.isLost {
                Button("Stop", systemImage: "stop.fill", role: .destructive) { remote.stopPlayback() }
                    .accessibilityIdentifier("remote.stop")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.top, 8)
    }
}

/// The playback on another device, along the bottom of the app while this one is its remote.
struct RemoteMiniPlayer: View {
    @Environment(RemoteControl.self) private var remote

    var body: some View {
        if let target = remote.target {
            HStack(spacing: 12) {
                Button {
                    remote.showsScreen = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tv").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(remote.item?.name ?? "Starting…").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("On \(target.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("remote.mini")
                Button(remote.isPaused ? "Play" : "Pause", systemImage: remote.isPaused ? "play.fill" : "pause.fill") { remote.togglePause() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.title3)
                    .disabled(remote.isStarting)
            }
            .padding(.horizontal, 16)
        }
    }
}
#endif
