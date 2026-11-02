import SwiftUI

struct ItemDetailView: View {
    let item: JellyfinItem
    let client: JellyfinClient
    let account: AccountStore.Account

    var body: some View {
        Group {
            if item.isSeries {
                SeriesView(series: item, client: client, account: account)
            } else {
                VersionsView(item: item, client: client, account: account)
            }
        }
        .navigationDestination(for: JellyfinItem.self) { episode in
            VersionsView(item: episode, client: client, account: account)
        }
    }
}

/// A movie or an episode: its versions, one to pick, and its downloads.
struct VersionsView: View {
    let item: JellyfinItem
    let client: JellyfinClient
    let account: AccountStore.Account

    @Environment(DownloadManager.self) private var downloads
    @State private var detail: JellyfinItem?
    @State private var selectedSourceId: String?
    @State private var loadError: String?

    private var sources: [MediaSource] { detail?.mediaSources ?? [] }
    private var jobs: [DownloadJob] { downloads.jobs.filter { $0.itemId == item.id } }

    var body: some View {
        List {
            Section {
                header
            }
            Section {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await load() } }
                } else if detail == nil {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Finding versions…").foregroundStyle(.secondary)
                    }
                } else if sources.isEmpty {
                    Text("The server lists no versions of this title.").foregroundStyle(.secondary)
                } else {
                    VersionPicker(sources: sources, selection: $selectedSourceId)
                }
            } header: {
                Text(sources.count > 1 ? "\(sources.count) Versions" : "Version")
            }
            if !jobs.isEmpty {
                Section("Downloads") {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.versionName).lineLimit(2)
                            if job.status != .completed { JobProgress(job: job).font(.caption) }
                            JobStatusLine(job: job).font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle(item.isEpisode ? (item.episodeCode ?? item.name) : item.name)
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .barPinnedTrailing) {
                Button("Download", systemImage: "arrow.down.circle") { download() }
                    .disabled(selectedSourceId == nil)
                    .accessibilityIdentifier("versions.download")
            }
        }
        .sensoryFeedback(.success, trigger: jobs.count)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Artwork(
                url: client.imageURL(itemId: item.id, tag: item.primaryImageTag, maxWidth: 300),
                aspectRatio: item.isEpisode ? 16.0 / 9.0 : 2.0 / 3.0
            )
            .frame(width: item.isEpisode ? 150 : 90)
            VStack(alignment: .leading, spacing: 4) {
                if item.isEpisode, let seriesName = item.seriesName {
                    Text(seriesName).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(item.name).font(.headline)
                Text(item.metadataLine).font(.caption).foregroundStyle(.secondary)
                if let overview = (detail ?? item).overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                }
            }
        }
    }

    private func load() async {
        loadError = nil
        do {
            let detail = try await client.item(id: item.id, userId: account.userId)
            self.detail = detail
            if selectedSourceId == nil { selectedSourceId = detail.mediaSources?.first?.id }
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func download() {
        guard let detail, let source = sources.first(where: { $0.id == selectedSourceId }) else { return }
        downloads.enqueue(detail, source: source)
    }
}
