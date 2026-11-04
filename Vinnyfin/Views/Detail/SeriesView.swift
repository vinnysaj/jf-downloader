import SwiftUI

/// A show: play the next episode, download a season or all of it, keep it downloaded, and its
/// episodes one season at a time. Select turns the episodes into checkboxes for downloading
/// several at once.
struct SeriesView: View {
    let series: JellyfinItem
    var initialSeasonId: String?

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    #if !os(tvOS)
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppMessages.self) private var messages
    #endif
    @State private var detail: JellyfinItem?
    @State private var seasons: [JellyfinItem] = []
    @State private var seasonId: String?
    @State private var episodes: [JellyfinItem]?
    @State private var nextUp: JellyfinItem?
    @State private var similar: [JellyfinItem] = []
    @State private var loadError: String?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var batch: Batch?

    struct Batch: Identifiable {
        let id = UUID()
        let episodes: [JellyfinItem]
    }

    private var shown: JellyfinItem { detail ?? series }

    var body: some View {
        EdgeToEdgeScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHero(item: shown) { actions }
                VStack(alignment: .leading, spacing: 24) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .edgePadding()
                        Button("Try Again", systemImage: "arrow.clockwise") { Task { await load() } }
                            .edgePadding()
                    }
                    OverviewText(item: shown).edgePadding()
                    seasonPicker
                    episodeList
                    if let people = detail?.people { CastShelf(people: people) }
                    if !similar.isEmpty {
                        Shelf(title: "More Like This", items: similar, cardWidth: Metrics.posterWidth) { other in
                            NavigationLink(value: other) { PosterCard(item: other) }
                                .buttonStyle(.artwork)
                        }
                    }
                }
                .padding(.bottom, Metrics.edge)
            }
        }
        .ignoresSafeArea(edges: .top)
        // The page color the hero artwork fades into.
        .background(Color.pageBackground.ignoresSafeArea())
        .navigationTitle(series.name)
        .inlineNavigationTitle()
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        #if !os(tvOS)
        .toolbar { selectionToolbar }
        .sheet(item: $batch) { batch in
            BatchDownloadSheet(episodes: batch.episodes) {
                isSelecting = false
                selection.removeAll()
            }
        }
        #endif
        .task(id: series.id) { await load() }
        .task(id: seasonId) { await loadEpisodes() }
    }

    // MARK: Actions

    /// One row, or on a narrow screen Play above the rest.
    @ViewBuilder private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                playButton
                secondaryButtons
            }
            VStack(alignment: .leading, spacing: 12) {
                playButton
                HStack(spacing: 12) { secondaryButtons }
            }
        }
    }

    @ViewBuilder private var playButton: some View {
        if let nextUp {
            Button {
                player.play(.item(nextUp))
            } label: {
                Label(playLabel(for: nextUp), systemImage: "play.fill").frame(minWidth: 120)
            }
            .buttonStyle(.platformGlassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("series.play")
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        #if !os(tvOS)
        smartDownloadMenu
        #endif
        WatchedButton(item: shown) { detail = $0 }
        FavoriteButton(item: shown) { detail = $0 }
    }

    private func playLabel(for episode: JellyfinItem) -> String {
        let code = episode.episodeCode ?? episode.name
        return episode.resumeSeconds != nil ? "Resume \(code)" : "Play \(code)"
    }

    #if !os(tvOS)
    /// Downloads now, of the season shown or the whole show, through the batch sheet's choice of
    /// versions and its size; and the ways to keep the show downloaded.
    private var smartDownloadMenu: some View {
        let rule = smartDownloads.rule(for: series.id)
        return SmartDownloadMenu(seriesId: series.id, seriesName: series.name) {
            Section("Download Now") {
                if let season = seasons.first(where: { $0.id == seasonId }) {
                    let missing = notDownloaded(episodes ?? [])
                    Button(missing.isEmpty && episodes != nil ? "\(season.name) Is Downloaded" : "Download \(season.name)",
                           systemImage: "arrow.down.circle") {
                        batch = Batch(episodes: missing)
                    }
                    .disabled(missing.isEmpty)
                    .accessibilityIdentifier("series.downloadSeason")
                }
                Button("Download Every Episode", systemImage: "square.stack.3d.down.forward") {
                    Task { await downloadEveryEpisode() }
                }
                .accessibilityIdentifier("series.downloadSeries")
            }
        } label: {
            Label(rule == nil ? "Download" : "Smart Download On", systemImage: rule == nil ? "arrow.down.circle" : "sparkles.rectangle.stack.fill")
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .accessibilityIdentifier("series.smartDownload")
    }

    /// The episodes without a download in any state.
    private func notDownloaded(_ episodes: [JellyfinItem]) -> [JellyfinItem] {
        episodes.filter { downloads.jobs(forItem: $0.id).isEmpty }
    }

    /// Every episode of every season, specials left out, that isn't downloaded or on its way.
    private func downloadEveryEpisode() async {
        guard let session else { return }
        do {
            let all = try await session.client.episodes(seriesId: series.id, seasonId: nil, userId: session.userId,
                                                        fields: "PrimaryImageAspectRatio")
            batch = Batch(episodes: notDownloaded(all.filter { $0.parentIndexNumber != 0 }))
        } catch {
            messages.show("Couldn't load the episodes of \(series.name): \(error.localizedDescription)")
        }
    }

    @ToolbarContentBuilder private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .barPinnedTrailing) {
            if isSelecting {
                Button("Done") {
                    isSelecting = false
                    selection.removeAll()
                }
                .accessibilityIdentifier("series.done")
            } else {
                Button("Select", systemImage: "checklist") { isSelecting = true }
                    .disabled(episodes?.isEmpty ?? true)
                    .accessibilityIdentifier("series.select")
            }
        }
        if isSelecting {
            ToolbarItem(placement: .barTrailing) {
                let allIds = Set(episodes?.map(\.id) ?? [])
                if !allIds.isEmpty, selection == allIds {
                    Button("Deselect All") { selection.removeAll() }
                } else {
                    Button("Select All") { selection = allIds }
                        .accessibilityIdentifier("series.selectAll")
                }
            }
            ToolbarItem(placement: .barTrailing) {
                // Text rather than an icon: bars show only the icon, and the count would be lost.
                Button("Download \(selection.count)") {
                    batch = Batch(episodes: (episodes ?? []).filter { selection.contains($0.id) })
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("series.download")
            }
        }
    }
    #endif

    // MARK: Seasons and episodes

    @ViewBuilder private var seasonPicker: some View {
        if seasons.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(seasons) { season in
                        Button {
                            seasonId = season.id
                        } label: {
                            Text(season.name)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(SeasonChipStyle(isSelected: season.id == seasonId))
                        .accessibilityIdentifier("season.\(season.name)")
                    }
                }
                .edgePadding()
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    @ViewBuilder private var episodeList: some View {
        if let episodes {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(episodes) { episode in
                    EpisodeRow(
                        episode: episode,
                        isSelecting: isSelecting,
                        isSelected: selection.contains(episode.id)
                    ) {
                        if isSelecting {
                            if selection.contains(episode.id) { selection.remove(episode.id) } else { selection.insert(episode.id) }
                        } else {
                            player.play(.item(episode))
                        }
                    } onChange: { updated in
                        if let index = self.episodes?.firstIndex(where: { $0.id == updated.id }) { self.episodes?[index] = updated }
                    }
                }
            }
            .edgePadding()
            #if os(tvOS)
            .focusSection()
            #endif
        } else if loadError == nil {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    // MARK: Loading

    private func load() async {
        guard let session else { return }
        loadError = nil
        do {
            async let detail = session.client.item(id: series.id, userId: session.userId)
            async let seasons = session.client.seasons(seriesId: series.id, userId: session.userId)
            async let nextUp = session.client.nextUp(userId: session.userId, seriesId: series.id, limit: 1)
            self.detail = try await detail
            let found = try await seasons
            self.seasons = found
            let next = try await nextUp.first
            self.nextUp = next
            if seasonId == nil {
                seasonId = initialSeasonId ?? next?.seasonId ?? found.first { ($0.indexNumber ?? 0) > 0 }?.id ?? found.first?.id
            }
        } catch is CancellationError {
            return
        } catch {
            loadError = "Couldn't load the show: \(error.localizedDescription)"
        }
        do {
            similar = try await session.client.similar(to: series.id, userId: session.userId)
        } catch {
            // More Like This is extra; the page is complete without it.
            similar = []
        }
    }

    private func loadEpisodes() async {
        guard let session, let seasonId else { return }
        episodes = nil
        selection.removeAll()
        do {
            episodes = try await session.client.episodes(seriesId: series.id, seasonId: seasonId, userId: session.userId,
                                                         fields: "Overview,PrimaryImageAspectRatio")
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            loadError = "Couldn't load the episodes: \(error.localizedDescription)"
        }
    }
}

private struct SeasonChipStyle: ButtonStyle {
    let isSelected: Bool
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary), in: .capsule)
            #if os(tvOS)
            .scaleEffect(isFocused ? 1.12 : 1)
            .shadow(radius: isFocused ? 12 : 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            #endif
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// An episode: its still with progress, number and title, length and overview.
private struct EpisodeRow: View {
    let episode: JellyfinItem
    let isSelecting: Bool
    let isSelected: Bool
    let action: () -> Void
    let onChange: (JellyfinItem) -> Void

    @Environment(\.session) private var session
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(maxHeight: .infinity)
                }
                Artwork(url: session?.client.imageURL(itemId: episode.id, tag: episode.primaryImageTag, maxWidth: 600),
                        aspectRatio: 16.0 / 9.0, placeholder: "play.rectangle")
                    .frame(width: stillWidth)
                    .overlay(alignment: .bottom) {
                        if let progress = episode.progress { ProgressBar(fraction: progress).padding(6) }
                    }
                    .overlay(alignment: .topTrailing) { WatchBadge(item: episode).padding(6) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name)
                            .font(.headline)
                            .lineLimit(2)
                        #if !os(tvOS)
                        downloadBadge
                        #endif
                    }
                    if let runtime = episode.runtimeText {
                        Text(runtime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let overview = episode.overview {
                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.artwork)
        .foregroundStyle(.primary)
        .contextMenu {
            ItemContextMenu(item: episode, onChange: onChange)
            NavigationLink("Details", value: episode)
        }
        .accessibilityIdentifier("episode.\(episode.indexNumber ?? 0)")
    }

    private var stillWidth: CGFloat {
        #if os(tvOS)
        380
        #elseif os(iOS)
        150
        #else
        220
        #endif
    }

    #if !os(tvOS)
    @ViewBuilder private var downloadBadge: some View {
        let jobs = downloads.jobs(forItem: episode.id)
        if jobs.contains(where: { $0.status == .completed }) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                .accessibilityLabel("Downloaded")
        } else if jobs.contains(where: { $0.status == .failed }) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                .accessibilityLabel("Download failed")
        } else if let job = jobs.first {
            DownloadRing(job: job)
        }
    }
    #endif
}
