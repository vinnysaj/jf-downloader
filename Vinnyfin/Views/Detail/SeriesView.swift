import SwiftUI

/// A show: play the next episode, keep it downloaded, and its episodes one season at a time.
/// Select turns the episodes into checkboxes for downloading several at once.
struct SeriesView: View {
    let series: JellyfinItem
    var initialSeasonId: String?

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    #if !os(tvOS)
    @Environment(SmartDownloads.self) private var smartDownloads
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
    #if os(tvOS)
    @FocusState private var focusedAction: Action?
    /// Focus has been put on the page's buttons, as it first appeared.
    @State private var placedFocus = false

    /// The buttons over the artwork that focus starts on.
    private enum Action {
        case play, watched
    }
    #endif

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
                        Shelf(title: "More Like This", seeAll: .moreLike(shown), items: similar, cardWidth: Metrics.posterWidth) { other in
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
        #else
        // Focus starts on Play, or until the next episode is in, on Watched; also for a page
        // opened from a link at launch, while focus is still in the sidebar. Coming back to the
        // page leaves focus where it was.
        .task {
            guard !placedFocus else { return }
            placedFocus = true
            focusedAction = nextUp == nil ? .watched : .play
        }
        .onChange(of: nextUp?.id) {
            if nextUp != nil, focusedAction == .watched { focusedAction = .play }
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
            #if os(tvOS)
            .focused($focusedAction, equals: .play)
            #endif
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        #if !os(tvOS)
        smartDownloadMenu
        #endif
        WatchedButton(item: shown) { detail = $0 }
            #if os(tvOS)
            .focused($focusedAction, equals: .watched)
            #endif
        FavoriteButton(item: shown) { detail = $0 }
    }

    private func playLabel(for episode: JellyfinItem) -> String {
        let code = episode.episodeCode ?? episode.name
        return episode.resumeSeconds != nil ? "Resume \(code)" : "Play \(code)"
    }

    #if !os(tvOS)
    private var smartDownloadMenu: some View {
        let rule = smartDownloads.rule(for: series.id)
        return Menu {
            Section("Keep Downloaded From the Next Episode") {
                ForEach([3, 5, 10, 20], id: \.self) { count in
                    Button {
                        smartDownloads.setRule(seriesId: series.id, seriesName: series.name, episodesAhead: count)
                    } label: {
                        if rule?.episodesAhead == count { Label("Next \(count) Episodes", systemImage: "checkmark") } else { Text("Next \(count) Episodes") }
                    }
                }
                Button {
                    smartDownloads.setRule(seriesId: series.id, seriesName: series.name, episodesAhead: nil)
                } label: {
                    if rule != nil, rule?.episodesAhead == nil { Label("Every Remaining Episode", systemImage: "checkmark") } else { Text("Every Remaining Episode") }
                }
            }
            if rule != nil {
                Button("Stop Smart Downloads", systemImage: "xmark", role: .destructive) {
                    smartDownloads.removeRule(seriesId: series.id)
                }
            }
        } label: {
            Label(rule == nil ? "Smart Download" : "Smart Download On", systemImage: rule == nil ? "sparkles" : "sparkles.rectangle.stack.fill")
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .accessibilityIdentifier("series.smartDownload")
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
            let next = try await nextUp.items.first
            self.nextUp = next
            if seasonId == nil {
                seasonId = initialSeasonId ?? next?.seasonId ?? found.first { ($0.indexNumber ?? 0) > 0 }?.id ?? found.first?.id
            }
        } catch {
            guard !error.isCancellation else { return }
            loadError = "Couldn't load the show: \(error.localizedDescription)"
        }
        do {
            similar = try await session.client.similar(to: series.id, userId: session.userId)
        } catch {
            guard !error.isCancellation else { return }
            similar = []
            loadError = loadError ?? "Couldn't load shows like this one: \(error.localizedDescription)"
        }
    }

    private func loadEpisodes() async {
        guard let session, let seasonId else { return }
        episodes = nil
        selection.removeAll()
        do {
            episodes = try await session.client.episodes(seriesId: series.id, seasonId: seasonId, userId: session.userId,
                                                         fields: "Overview,PrimaryImageAspectRatio")
        } catch {
            if !error.isCancellation { loadError = "Couldn't load the episodes: \(error.localizedDescription)" }
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
