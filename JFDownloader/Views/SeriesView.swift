import SwiftUI

/// A show's episodes, one season at a time. Select turns the list into checkboxes for
/// downloading several episodes at once.
struct SeriesView: View {
    let series: JellyfinItem
    let client: JellyfinClient
    let account: AccountStore.Account

    @Environment(DownloadManager.self) private var downloads
    @State private var seasons: [JellyfinItem]?
    @State private var seasonId: String?
    @State private var episodes: [JellyfinItem]?
    @State private var loadError: String?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var batch: Batch?

    struct Batch: Identifiable {
        let id = UUID()
        let episodes: [JellyfinItem]
    }

    var body: some View {
        List(selection: $selection) {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await loadSeasons() } }
                }
            }
            if let seasons, seasons.count > 1 {
                Section {
                    Picker("Season", selection: $seasonId) {
                        ForEach(seasons) { season in
                            Text(season.name).tag(Optional(season.id))
                        }
                    }
                    .accessibilityIdentifier("series.season")
                }
            }
            Section {
                if let episodes {
                    ForEach(episodes) { episode in
                        if isSelecting {
                            EpisodeRow(episode: episode, client: client).tag(episode.id)
                        } else {
                            NavigationLink(value: episode) {
                                EpisodeRow(episode: episode, client: client)
                            }
                        }
                    }
                } else if loadError == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                if let season = seasons?.first(where: { $0.id == seasonId }) { Text(season.name) }
            }
        }
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $batch) { batch in
            BatchDownloadSheet(episodes: batch.episodes, client: client, account: account) {
                isSelecting = false
                selection.removeAll()
            }
        }
        .task { await loadSeasons() }
        .task(id: seasonId) { await loadEpisodes() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarPinnedTrailing) {
            if isSelecting {
                Button("Done", systemImage: "checkmark") {
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
            ToolbarItem(placement: .bottomBar) {
                let allIds = Set(episodes?.map(\.id) ?? [])
                if !allIds.isEmpty, selection == allIds {
                    Button("Deselect All", systemImage: "circle") { selection.removeAll() }
                } else {
                    Button("Select All", systemImage: "checkmark.circle") { selection = allIds }
                        .accessibilityIdentifier("series.selectAll")
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Download \(selection.count)", systemImage: "arrow.down.circle") {
                    let chosen = (episodes ?? []).filter { selection.contains($0.id) }
                    batch = Batch(episodes: chosen)
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("series.download")
            }
        }
    }

    private func loadSeasons() async {
        loadError = nil
        do {
            let found = try await client.seasons(seriesId: series.id, userId: account.userId)
            seasons = found
            if seasonId == nil { seasonId = found.first?.id }
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let seasonId else { return }
        episodes = nil
        selection.removeAll()
        do {
            episodes = try await client.episodes(seriesId: series.id, seasonId: seasonId, userId: account.userId)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct EpisodeRow: View {
    let episode: JellyfinItem
    let client: JellyfinClient
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        HStack(spacing: 12) {
            Artwork(
                url: client.imageURL(itemId: episode.id, tag: episode.primaryImageTag, maxWidth: 240),
                aspectRatio: 16.0 / 9.0
            )
            .frame(width: 96)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name)
                    .lineLimit(2)
                if let runtime = episode.runtime {
                    Text(runtime.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            badge
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("episode.\(episode.indexNumber ?? 0)")
    }

    @ViewBuilder private var badge: some View {
        let jobs = downloads.jobs.filter { $0.itemId == episode.id }
        if jobs.contains(where: { $0.status == .completed }) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        } else if jobs.contains(where: { $0.status == .failed }) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                .accessibilityLabel("Download failed")
        } else if !jobs.isEmpty {
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                .accessibilityLabel("Downloading")
        }
    }
}
