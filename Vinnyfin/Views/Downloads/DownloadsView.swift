#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// Everything on this device: downloads in progress and done, the shows kept downloaded, and
/// video files from elsewhere. Works with or without a connection.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(DownloadNotifications.self) private var downloadNotifications
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(LocalLibrary.self) private var localLibrary
    @Environment(WatchHistory.self) private var history
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    #if os(iOS) || os(visionOS)
    @Environment(BackgroundDownloads.self) private var backgroundDownloads
    #endif
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
                #if os(iOS) || os(visionOS)
                BackgroundNotices(hasActiveDownloads: unfinished.contains { $0.status == .active })
                #endif
                spaceNotice
                if !unfinished.isEmpty {
                    Section {
                        ForEach(unfinished) { job in JobRow(job: job, isFirst: job.id == unfinished.first?.id) }
                            .onMove { from, to in
                                var order = unfinished.map(\.id)
                                order.move(fromOffsets: from, toOffset: to)
                                downloads.reorderUnfinished(order)
                            }
                    } header: {
                        Text("Downloading")
                    } footer: {
                        if unfinished.count > 1 {
                            Text("Downloads go one at a time, in this order. Drag one to move it, or choose Download Next.")
                        }
                    }
                }
                if !smartDownloads.rules.isEmpty {
                    Section {
                        ForEach(smartDownloads.rules) { rule in SmartRuleRow(rule: rule) }
                    } header: {
                        Text("Smart Downloads")
                    } footer: {
                        Text("These shows stay downloaded ahead of where you're watching, wherever you watch. They're checked whenever vinnyfin opens, regularly while it's open, and every few hours in the background.")
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
            .onAppear { localLibrary.scanFolder(excluding: Set(downloads.jobs.compactMap(\.savedPath))) }
        }
    }

    /// Each problem to show, with how to dismiss it.
    private var problemMessages: [(String, () -> Void)] {
        var messages: [(String, () -> Void)?] = [
            downloads.problem.map { ($0, { downloads.problem = nil }) },
            smartDownloads.problem.map { ($0, { smartDownloads.problem = nil }) },
            downloadNotifications.problem.map { ($0, { downloadNotifications.problem = nil }) },
            history.problem.map { ($0, { history.problem = nil }) },
            localLibrary.problem.map { ($0, { localLibrary.problem = nil }) },
        ]
        #if os(iOS) || os(visionOS)
        messages.append(backgroundDownloads.problem.map { ($0, { backgroundDownloads.problem = nil }) })
        #endif
        return messages.compactMap(\.self)
    }

    @ViewBuilder private var problems: some View {
        let messages = problemMessages
        if !messages.isEmpty {
            Section {
                ForEach(messages.indices, id: \.self) { index in
                    Label(messages[index].0, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Button("Dismiss") { messages.forEach { $0.1() } }
            }
        }
    }

    /// What to do when downloads wait for room.
    @ViewBuilder private var spaceNotice: some View {
        if downloads.waits.values.contains(where: { if case .space = $0 { true } else { false } }) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Not enough space for downloads", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Downloads wait until there's room. \(StorageBudget.advice(hasLimit: settings.downloadStorageLimit > 0)) \(StorageUsage.deletionPolicy)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("notice.space")
            }
        }
    }

    @ViewBuilder private var storageSummary: some View {
        StorageUsage()
        if let free = downloads.availableCapacity() {
            LabeledContent("Free on This \(Device.name)", value: DownloadManager.bytes(free))
        }
        if let freed = downloads.lastFreed {
            Text("To make room, \(freed.date.formatted(.relative(presentation: .named))) vinnyfin deleted \(ListFormatter.localizedString(byJoining: freed.titles)), watched since \(freed.titles.count == 1 ? "it was" : "they were") downloaded (\(DownloadManager.bytes(freed.bytes))).")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                Button("Pause All", systemImage: "pause") { downloads.pauseAll() }
                    .disabled(!unfinished.contains { $0.status == .active })
                    .accessibilityIdentifier("downloads.pauseAll")
                Button("Resume All", systemImage: "play") { downloads.resumeAll() }
                    .disabled(!unfinished.contains { $0.status != .active })
                    .accessibilityIdentifier("downloads.resumeAll")
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("downloads.more")
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
    /// First in the list, so first to download.
    let isFirst: Bool
    @Environment(DownloadManager.self) private var downloads

    /// The network or the schedule holds it back, which Download Now lifts.
    private var mayDownloadNow: Bool {
        job.status == .active && downloads.waits[job.id]?.isRule == true
    }

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
                if mayDownloadNow {
                    Button("Download Now", systemImage: "arrow.down.to.line") { downloads.downloadNow(job.id) }.tint(.blue)
                }
            case .paused:
                Button("Resume", systemImage: "play") { downloads.resume(job.id) }.tint(.green)
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }.tint(.blue)
            case .completed:
                EmptyView()
            }
        }
        .contextMenu {
            if mayDownloadNow {
                Button("Download Now", systemImage: "arrow.down.to.line") { downloads.downloadNow(job.id) }
            }
            if !isFirst {
                Button("Download Next", systemImage: "text.line.first.and.arrowtriangle.forward") { downloads.downloadNext(job.id) }
            }
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

#if os(iOS) || os(visionOS)
/// What holds downloads back outside the app, with what to do about it.
private struct BackgroundNotices: View {
    let hasActiveDownloads: Bool
    @Environment(BackgroundDownloads.self) private var backgroundDownloads
    @Environment(\.openURL) private var openURL

    var body: some View {
        let notices = backgroundDownloads.notices(hasActiveDownloads: hasActiveDownloads)
        if !notices.isEmpty {
            Section {
                ForEach(notices) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(notice.title, systemImage: notice.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("notice.\(notice.rawValue)")
                        Text(notice.message).font(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            if notice.opensSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                                Button("Open Settings") { openURL(settings) }
                                    .accessibilityIdentifier("notice.\(notice.rawValue).settings")
                            }
                            Button("Dismiss") { backgroundDownloads.dismiss(notice) }
                                .accessibilityIdentifier("notice.\(notice.rawValue).dismiss")
                        }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
#endif

/// How much room downloads take, against the storage limit when there is one.
struct StorageUsage: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var settings

    static let deletionPolicy = "Downloads you've watched are deleted to make room by themselves; unwatched and partly watched ones never are."

    var body: some View {
        let used = downloads.storageUsed
        let limit = DownloadRules(settings).storageLimit
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Downloads Use") {
                Text(limit.map { "\(DownloadManager.bytes(used)) of \(DownloadManager.bytes($0))" } ?? DownloadManager.bytes(used))
                    .monospacedDigit()
            }
            if let limit {
                ProgressView(value: Double(min(used, limit)), total: Double(limit))
                    .tint(used >= limit ? .orange : .accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storage.usage")
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
