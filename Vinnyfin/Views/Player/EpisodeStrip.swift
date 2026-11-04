#if os(iOS) || os(visionOS)
import SwiftUI

/// The show's episodes in the player's controls, below the fold of an iPhone Duo standing half
/// open and under Vision Pro's window: a season at a time, starting from the one playing.
/// Tapping one plays it in place. Offline, the show's downloads.
struct EpisodeStrip: View {
    let model: PlayerModel
    let playing: JellyfinItem
    /// Called as it's scrolled or used, so controls that fade stay up meanwhile.
    var onInteraction: () -> Void = {}

    @Environment(\.session) private var session
    @Environment(DownloadManager.self) private var downloads
    @State private var seasons: [JellyfinItem] = []
    @State private var seasonId: String?
    @State private var episodes: [JellyfinItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(episodes) { episode in
                            Button {
                                onInteraction()
                                Task { await model.play(episode) }
                            } label: {
                                card(episode)
                            }
                            .buttonStyle(.artwork)
                            .id(episode.id)
                            .accessibilityIdentifier("episodes.episode.\(episode.indexNumber ?? 0)")
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, Metrics.playerInset, for: .scrollContent)
                .onScrollPhaseChange { _, phase in
                    if phase.isScrolling { onInteraction() }
                }
                .onChange(of: episodes) { proxy.scrollTo(playing.id, anchor: .leading) }
                .onChange(of: playing.id) { withAnimation { proxy.scrollTo(playing.id, anchor: .leading) } }
            }
        }
        .task(id: playing.seriesId) { await loadSeasons() }
        .task(id: seasonId) { await loadEpisodes() }
    }

    private var header: some View {
        HStack {
            if seasons.count > 1 {
                Menu {
                    Picker("Season", selection: $seasonId) {
                        ForEach(seasons) { Text($0.name).tag(Optional($0.id)) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(seasonName)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                }
                .accessibilityIdentifier("episodes.season")
            } else {
                Text(seasonName)
            }
            Spacer()
        }
        .font(.headline)
        .padding(.horizontal, Metrics.playerInset)
    }

    private var seasonName: String {
        seasons.first { $0.id == seasonId }?.name ?? playing.seasonName ?? "Episodes"
    }

    private func card(_ episode: JellyfinItem) -> some View {
        let isPlaying = episode.id == playing.id
        return VStack(alignment: .leading, spacing: 6) {
            Artwork(url: session?.client.imageURL(itemId: episode.id, tag: episode.primaryImageTag, maxWidth: 400),
                    aspectRatio: 16.0 / 9.0, placeholder: "play.rectangle")
                .overlay(alignment: .bottom) {
                    if let progress = episode.progress, !isPlaying { ProgressBar(fraction: progress).padding(6) }
                }
                .overlay {
                    if isPlaying {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(.white, lineWidth: 2)
                        Image(systemName: "waveform")
                            .font(.title2.weight(.semibold))
                            .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
                            .shadow(radius: 4)
                    }
                }
            Text(episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let runtime = episode.runtimeText {
                Text(runtime).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 168)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
    }

    private func loadSeasons() async {
        seasonId = playing.seasonId
        guard let session, let seriesId = playing.seriesId else { return }
        do {
            seasons = try await session.client.seasons(seriesId: seriesId, userId: session.userId)
        } catch {
            // Offline: the downloads are listed together, without seasons.
            seasons = []
        }
    }

    private func loadEpisodes() async {
        guard let seriesId = playing.seriesId else { return }
        if let session {
            do {
                episodes = try await session.client.episodes(seriesId: seriesId, seasonId: seasonId, userId: session.userId,
                                                             fields: JellyfinClient.listFields)
                return
            } catch is CancellationError {
                return
            } catch {
                // Falls through to what's downloaded.
            }
        }
        episodes = downloads.downloadedEpisodes(seriesId: seriesId)
    }
}
#endif
