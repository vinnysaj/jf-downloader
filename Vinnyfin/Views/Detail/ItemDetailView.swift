import SwiftUI

/// Where a title in a list leads: a show's page, or a movie's or episode's.
struct ItemDestination: View {
    let item: JellyfinItem

    var body: some View {
        if item.isSeries {
            SeriesView(series: item)
        } else if item.isSeason, let seriesId = item.seriesId {
            SeriesView(series: JellyfinItem(id: seriesId, name: item.seriesName ?? item.name, type: "Series"), initialSeasonId: item.id)
        } else {
            ItemDetailView(item: item)
        }
    }
}

/// A movie or an episode: play it, pick a version, download it, and more like it.
struct ItemDetailView: View {
    let item: JellyfinItem

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    @State private var detail: JellyfinItem?
    @State private var similar: [JellyfinItem] = []
    @State private var loadError: String?
    /// A version the user picked; nil lets playback and downloads choose by quality.
    @State private var pickedSourceId: String?

    private var shown: JellyfinItem { detail ?? item }
    private var sources: [MediaSource] { detail?.mediaSources ?? [] }
    private var playbackSource: MediaSource? {
        sources.first { $0.id == pickedSourceId } ?? VersionChooser.choose(from: sources, quality: settings.streamingQuality)
    }

    var body: some View {
        EdgeToEdgeScrollView {
            VStack(alignment: .leading, spacing: 28) {
                DetailHero(item: shown, eyebrow: shown.isEpisode ? shown.seriesName : nil, badgesSource: playbackSource) {
                    actions
                }
                VStack(alignment: .leading, spacing: 28) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .edgePadding()
                    }
                    OverviewText(item: shown).edgePadding()
                    if sources.count > 1 { versions }
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
        .navigationTitle(shown.name)
        .inlineNavigationTitle()
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .task(id: item.id) { await load() }
    }

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

    private var playButton: some View {
        PlayButton(item: shown, mediaSourceId: pickedSourceId)
    }

    @ViewBuilder private var secondaryButtons: some View {
        #if !os(tvOS)
        DownloadButton(item: detail, source: pickedSourceId.flatMap { id in sources.first { $0.id == id } })
        #endif
        WatchedButton(item: shown) { detail = $0 }
        FavoriteButton(item: shown) { detail = $0 }
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(sources.count) Versions").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                VersionPicker(sources: sources, selection: Binding(get: { playbackSource?.id }, set: { pickedSourceId = $0 }))
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 16))
            Text("Plays and downloads use the version picked here. Without a pick, they choose the one closest to your quality settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .edgePadding()
        .frame(maxWidth: 900, alignment: .leading)
    }

    private func load() async {
        guard let session else { return }
        do {
            detail = try await session.client.item(id: item.id, userId: session.userId)
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = "Couldn't load the details: \(error.localizedDescription)"
        }
        do {
            similar = try await session.client.similar(to: item.isEpisode ? (item.seriesId ?? item.id) : item.id, userId: session.userId)
        } catch {
            // More Like This is extra; the page is complete without it.
            similar = []
        }
    }
}

/// Play, or Resume with the time left, plus Start Over when there's a position.
struct PlayButton: View {
    let item: JellyfinItem
    var mediaSourceId: String?
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        Button {
            player.play(.item(item, mediaSourceId: mediaSourceId))
        } label: {
            Label(label, systemImage: "play.fill")
                .frame(minWidth: 120)
        }
        .buttonStyle(.platformGlassProminent)
        .controlSize(.large)
        .accessibilityIdentifier("detail.play")
        if item.resumeSeconds != nil {
            Button {
                player.play(.item(item, mediaSourceId: mediaSourceId, fromBeginning: true))
            } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.platformGlass)
            .controlSize(.large)
        }
    }

    private var label: String {
        guard let resume = item.resumeSeconds else { return "Play" }
        if let total = item.runtimeSeconds, total > resume {
            return "Resume · \(Duration.seconds(total - resume).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left"
        }
        return "Resume"
    }
}

struct WatchedButton: View {
    let item: JellyfinItem
    let onChange: (JellyfinItem) -> Void
    @Environment(\.session) private var session
    @Environment(AppMessages.self) private var messages

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Label(item.isPlayed ? "Watched" : "Mark Watched", systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("detail.watched")
    }

    private func toggle() async {
        guard let session else { return }
        await WatchActions.setPlayed(!item.isPlayed, on: item, session: session, messages: messages, onChange: onChange)
    }
}

struct FavoriteButton: View {
    let item: JellyfinItem
    let onChange: (JellyfinItem) -> Void
    @Environment(\.session) private var session
    @Environment(AppMessages.self) private var messages

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Label(item.isFavorite ? "Favorite" : "Add to Favorites", systemImage: item.isFavorite ? "heart.fill" : "heart")
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
    }

    private func toggle() async {
        guard let session else { return }
        await WatchActions.setFavorite(!item.isFavorite, on: item, session: session, messages: messages, onChange: onChange)
    }
}

#if !os(tvOS)
/// Download, then the download's progress, then a way to delete it.
struct DownloadButton: View {
    /// Nil until the item's versions have loaded.
    let item: JellyfinItem?
    /// A version the user picked; otherwise the download quality decides.
    let source: MediaSource?

    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages

    var body: some View {
        let jobs = item.map { downloads.jobs(forItem: $0.id) } ?? []
        Group {
            if jobs.contains(where: { $0.status == .completed }) {
                Menu {
                    Button("Delete Download", systemImage: "trash", role: .destructive) {
                        if let item { downloads.deleteDownloads(ofItem: item.id) }
                    }
                } label: {
                    Label("Downloaded", systemImage: "arrow.down.circle.fill")
                }
            } else if let job = jobs.first {
                Menu {
                    if job.status == .failed {
                        Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }
                    }
                    Button("Cancel Download", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
                } label: {
                    if job.status == .failed {
                        Label("Download Failed", systemImage: "exclamationmark.circle")
                    } else {
                        Label {
                            Text("Downloading")
                        } icon: {
                            DownloadRing(job: job)
                        }
                    }
                }
            } else {
                Button {
                    download()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(item == nil)
            }
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("detail.download")
    }

    private func download() {
        guard let item else { return }
        guard let chosen = source ?? VersionChooser.choose(from: item.mediaSources ?? [], quality: settings.downloadQuality) else {
            messages.show("The server lists no versions of \(item.name) to download.")
            return
        }
        downloads.enqueue(item, source: chosen)
    }
}

/// A download's progress as a ring.
struct DownloadRing: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let received = downloads.receivedBytes[job.id] ?? job.completed.byteCount
        let fraction = job.displayTotalBytes.map { $0 > 0 ? Double(received) / Double($0) : 0 } ?? 0
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
            Circle().trim(from: 0, to: fraction).stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel("Downloading, \(Int(fraction * 100)) percent")
    }
}
#endif
