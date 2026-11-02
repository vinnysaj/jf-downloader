import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.openURL) private var openURL

    private var unfinished: [DownloadJob] { downloads.jobs.filter { $0.status != .completed } }
    private var finished: [DownloadJob] {
        downloads.jobs.filter { $0.status == .completed }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem = downloads.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("Dismiss") { downloads.problem = nil }
                    }
                }
                if !unfinished.isEmpty {
                    Section("In Progress") {
                        ForEach(unfinished) { job in JobRow(job: job) }
                    }
                }
                if !finished.isEmpty {
                    Section {
                        ForEach(finished) { job in JobRow(job: job) }
                    } header: {
                        Text("Finished")
                    } footer: {
                        Text(FinishedFiles.hint)
                    }
                }
            }
            .overlay {
                if downloads.jobs.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Pick a movie or some episodes in Library.")
                    )
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .barTrailing) {
                    Button("Show in \(FinishedFiles.browser)", systemImage: "folder") {
                        openURL(FinishedFiles.browserURL(for: downloads.finishedFolder))
                    }
                }
                ToolbarItem(placement: .barTrailing) {
                    Menu {
                        Button("Pause All", systemImage: "pause") {
                            for job in unfinished where job.status == .active { downloads.pause(job.id) }
                        }
                        .disabled(!unfinished.contains { $0.status == .active })
                        Button("Resume All", systemImage: "play") {
                            for job in unfinished where job.status != .active { downloads.resume(job.id) }
                        }
                        .disabled(!unfinished.contains { $0.status != .active })
                        Button("Clear Finished", systemImage: "checkmark.circle") { downloads.removeCompleted() }
                            .disabled(finished.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
    }
}

private struct JobRow: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.openURL) private var openURL
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.title).font(.headline).lineLimit(2)
            if let subtitle = job.subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(job.versionName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Group {
                if job.status != .completed {
                    JobProgress(job: job)
                } else if let savedPath = job.savedPath {
                    Text(savedPath).foregroundStyle(.secondary).lineLimit(2)
                }
                JobStatusLine(job: job)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("job.\(job.title)")
        .swipeActions(edge: .trailing) {
            if job.status == .completed {
                Button("Remove", systemImage: "list.bullet") { downloads.remove(job.id) }
                    .tint(.gray)
            } else {
                Button("Cancel", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
            }
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
        .contextMenu { menu }
        .confirmationDialog("Delete the file?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete File", role: .destructive) { downloads.remove(job.id, deletingFile: true) }
        } message: {
            Text("This deletes \(job.savedPath ?? "the file") from \(FinishedFiles.place).")
        }
    }

    @ViewBuilder private var menu: some View {
        switch job.status {
        case .active:
            Button("Pause", systemImage: "pause") { downloads.pause(job.id) }
        case .paused:
            Button("Resume", systemImage: "play") { downloads.resume(job.id) }
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise") { downloads.resume(job.id) }
            Button("Start Over", systemImage: "arrow.counterclockwise") { downloads.restart(job.id) }
        case .completed:
            if let file = downloads.savedFileURL(of: job) {
                Button("Show in \(FinishedFiles.browser)", systemImage: "folder") {
                    openURL(FinishedFiles.browserURL(for: file.deletingLastPathComponent()))
                }
            }
            Button("Remove from List", systemImage: "list.bullet") { downloads.remove(job.id) }
            Button("Delete File", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        if job.status != .completed {
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { downloads.remove(job.id) }
        }
    }
}
