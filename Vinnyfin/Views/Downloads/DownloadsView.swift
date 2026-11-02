#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// Everything on this device: downloads in progress and done, the shows kept downloaded, and
/// video files from elsewhere. Works with or without a connection.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(LocalLibrary.self) private var localLibrary
    @Environment(WatchHistory.self) private var history
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.openURL) private var openURL
    @State private var importing = false

    private var unfinished: [DownloadJob] { downloads.jobs.filter { $0.status != .completed } }
    private var finished: [DownloadJob] { downloads.jobs.filter { $0.status == .completed } }
    private var movies: [DownloadJob] {
        finished.filter { !$0.isEpisode }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    /// Downloaded episodes by show, shows by name and episodes in order.
    private var shows: [(name: String, episodes: [DownloadJob])] {
        let grouped = Dictionary(grouping: finished.filter(\.isEpisode)) { (job: DownloadJob) -> String in
            job.item?.seriesName ?? job.subtitle ?? "Other"
        }
        let shows = grouped.map { (name: $0.key, episodes: $0.value.sorted { Self.order(of: $0) < Self.order(of: $1) }) }
        return shows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func order(of job: DownloadJob) -> Int {
        (job.item?.parentIndexNumber ?? 0) * 10_000 + (job.item?.indexNumber ?? 0)
    }

    var body: some View {
        NavigationStack {
            List {
                problems
                if !unfinished.isEmpty {
                    Section("Downloading") {
                        ForEach(unfinished) { job in JobRow(job: job) }
                    }
                }
                if !smartDownloads.rules.isEmpty {
                    Section {
                        ForEach(smartDownloads.rules) { rule in SmartRuleRow(rule: rule) }
                    } header: {
                        Text("Smart Downloads")
                    } footer: {
                        Text("These shows stay downloaded ahead of where you're watching, wherever you watch.")
                    }
                }
                if !movies.isEmpty {
                    Section("Movies") {
                        ForEach(movies) { job in DownloadedRow(job: job) }
                    }
                }
                ForEach(shows, id: \.name) { show in
                    Section(show.name) {
                        ForEach(show.episodes) { job in DownloadedRow(job: job) }
                    }
                }
                LocalFilesSection()
                Section {
                    storageSummary
                } footer: {
                    Text(FinishedFiles.hint)
                }
            }
            .overlay {
                if downloads.jobs.isEmpty, localLibrary.recents.isEmpty, localLibrary.folderFiles.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Downloaded", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Download movies and episodes to watch them offline, or open a video file from this device.")
                    } actions: {
                        Button("Open a File…") { importing = true }
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar { toolbar }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.videoTypes, allowsMultipleSelection: false) { result in
                openPicked(result)
            }
            .refreshable { await smartDownloads.refresh() }
            .onAppear { localLibrary.scanFolder(excluding: Set(downloads.jobs.compactMap(\.savedPath))) }
        }
    }

    @ViewBuilder private var problems: some View {
        let messages: [(String, () -> Void)] = [
            downloads.problem.map { ($0, { downloads.problem = nil }) },
            smartDownloads.problem.map { ($0, { smartDownloads.problem = nil }) },
            history.problem.map { ($0, { history.problem = nil }) },
            localLibrary.problem.map { ($0, { localLibrary.problem = nil }) },
        ].compactMap(\.self)
        if !messages.isEmpty {
            Section {
                ForEach(messages.indices, id: \.self) { index in
                    Label(messages[index].0, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Button("Dismiss") { messages.forEach { $0.1() } }
            }
        }
    }

    @ViewBuilder private var storageSummary: some View {
        LabeledContent("Downloads Use", value: DownloadManager.bytes(downloads.storageUsed))
        if let free = downloads.availableCapacity() {
            LabeledContent("Free on This \(Device.name)", value: DownloadManager.bytes(free))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .barTrailing) {
            Button("Open File", systemImage: "folder.badge.plus") { importing = true }
                .accessibilityIdentifier("downloads.openFile")
        }
        ToolbarItem(placement: .barTrailing) {
            Menu {
                Button("Show in \(FinishedFiles.browser)", systemImage: "folder") {
                    openURL(FinishedFiles.browserURL(for: downloads.finishedFolder))
                }
                Button("Pause All", systemImage: "pause") {
                    for job in unfinished where job.status == .active { downloads.pause(job.id) }
                }
                .disabled(!unfinished.contains { $0.status == .active })
                Button("Resume All", systemImage: "play") {
                    for job in unfinished where job.status != .active { downloads.resume(job.id) }
                }
                .disabled(!unfinished.contains { $0.status != .active })
                Button("Update Smart Downloads", systemImage: "sparkles") {
                    Task { await smartDownloads.refresh() }
                }
                .disabled(smartDownloads.isRefreshing)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    static let videoTypes: [UTType] = [.movie, .video, .audiovisualContent] + ["mkv", "webm", "avi", "ts", "m2ts", "wmv", "flv", "ogv", "vob"]
        .compactMap { UTType(filenameExtension: $0) }

    private func openPicked(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            player.playFile(url)
        case .failure(let error):
            localLibrary.problem = "Couldn't open the file: \(error.localizedDescription)"
        }
    }
}

/// A download that hasn't finished, with its progress and controls.
private struct JobRow: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        HStack(spacing: 12) {
            OfflineArtwork(itemId: job.itemId, aspectRatio: job.isEpisode ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: job.isEpisode ? 96 : 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.headline).lineLimit(2)
                if let subtitle = job.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(job.versionName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Group {
                    JobProgress(job: job)
                    JobStatusLine(job: job)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("job.\(job.title)")
        .swipeActions(edge: .trailing) {
            Button("Cancel", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
        }
        .swipeActions(edge: .leading) {
            switch job.status {
            case .active:
                Button("Pause", systemImage: "pause") { downloads.pause(job.id) }.tint(.orange)
            case .paused:
                Button("Resume", systemImage: "play") { downloads.resume(job.id) }.tint(.green)
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }.tint(.blue)
            case .completed:
                EmptyView()
            }
        }
        .contextMenu {
            switch job.status {
            case .active:
                Button("Pause", systemImage: "pause") { downloads.pause(job.id) }
            case .paused:
                Button("Resume", systemImage: "play") { downloads.resume(job.id) }
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }
                Button("Start Over", systemImage: "arrow.counterclockwise") { downloads.restart(job.id) }
            case .completed:
                EmptyView()
            }
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
        }
    }
}

/// A finished download: plays when chosen, shows how far it was watched.
private struct DownloadedRow: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads
    @Environment(WatchHistory.self) private var history
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.openURL) private var openURL
    @State private var confirmingDelete = false

    var body: some View {
        Button {
            player.play(PlaybackRequest(source: .item(id: job.itemId, mediaSourceId: job.mediaSourceId), title: job.title))
        } label: {
            HStack(spacing: 12) {
                OfflineArtwork(itemId: job.itemId, aspectRatio: job.isEpisode ? 16.0 / 9.0 : 2.0 / 3.0)
                    .frame(width: job.isEpisode ? 110 : 50)
                    .overlay(alignment: .bottom) {
                        if let progress { ProgressBar(fraction: progress).padding(4) }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.isEpisode ? [job.item?.episodeCode, job.title].compactMap(\.self).joined(separator: " · ") : job.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    Text([job.versionName, job.totalBytes.map(DownloadManager.bytes)].compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if isWatched {
                        Label("Watched", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.tint)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("downloaded.\(job.title)")
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        .contextMenu {
            if let file = downloads.savedFileURL(of: job) {
                Button("Show in \(FinishedFiles.browser)", systemImage: "folder") {
                    openURL(FinishedFiles.browserURL(for: file.deletingLastPathComponent()))
                }
                ShareLink(item: file)
            }
            Button("Delete Download", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete \(job.title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Download", role: .destructive) { downloads.deleteDownloads(ofItem: job.itemId) }
        } message: {
            Text("This deletes \(job.savedPath ?? "the file") from \(FinishedFiles.place).")
        }
    }

    private var entry: WatchHistory.Entry? { history.entry(for: job.itemId) }

    private var isWatched: Bool {
        entry?.played ?? job.item?.isPlayed ?? false
    }

    private var progress: Double? {
        if let entry, let duration = entry.duration, duration > 0, entry.position > 0, !entry.played {
            return entry.position / duration
        }
        return entry == nil ? job.item?.progress : nil
    }
}

/// A show kept downloaded, with its count and a way to change or stop it.
private struct SmartRuleRow: View {
    let rule: SmartDownloads.Rule
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        HStack(spacing: 12) {
            OfflineArtwork(itemId: rule.seriesId, aspectRatio: 2.0 / 3.0).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.seriesName).font(.body.weight(.medium))
                Text(rule.episodesAhead.map { "Next \($0) episodes" } ?? "Every remaining episode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach([3, 5, 10, 20], id: \.self) { count in
                    Button("Next \(count) Episodes") {
                        smartDownloads.setRule(seriesId: rule.seriesId, seriesName: rule.seriesName, episodesAhead: count)
                    }
                }
                Button("Every Remaining Episode") {
                    smartDownloads.setRule(seriesId: rule.seriesId, seriesName: rule.seriesName, episodesAhead: nil)
                }
                Button("Stop Smart Downloads", systemImage: "xmark", role: .destructive) {
                    smartDownloads.removeRule(seriesId: rule.seriesId)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Change \(rule.seriesName)")
        }
        .accessibilityIdentifier("rule.\(rule.seriesName)")
    }
}

/// Artwork saved with a download, shown from disk so it works offline.
struct OfflineArtwork: View {
    let itemId: String
    let aspectRatio: CGFloat
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        Artwork(url: downloads.artworkURL(itemId: itemId, kind: .primary), aspectRatio: aspectRatio, cornerRadius: 6)
    }
}
#endif
