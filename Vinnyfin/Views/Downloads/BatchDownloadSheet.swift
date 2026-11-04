#if !os(tvOS)
import SwiftUI

/// Picks a version for each selected episode, then queues them all.
/// Each episode starts on the version closest to the download quality; choosing a version for
/// one episode can carry the same release over to the rest.
struct BatchDownloadSheet: View {
    let episodes: [JellyfinItem]
    let onQueued: () -> Void

    @Environment(\.session) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var details: [String: Result<JellyfinItem, LoadFailure>] = [:]
    @State private var choices: [String: String] = [:]

    struct LoadFailure: Error {
        let message: String
    }

    private static let parallelLoads = 4

    private var ready: [(JellyfinItem, MediaSource)] {
        episodes.compactMap { episode in
            guard case .success(let detail) = details[episode.id],
                  let source = detail.mediaSources?.first(where: { $0.id == choices[episode.id] })
            else { return nil }
            return (detail, source)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(episodes) { episode in
                    row(for: episode)
                }
            }
            .navigationTitle(episodes.count == 1 ? "Download Episode" : "Download \(episodes.count) Episodes")
            .inlineNavigationTitle()
            .navigationDestination(for: String.self) { episodeId in
                if case .success(let detail) = details[episodeId] {
                    VersionChoiceList(
                        episode: detail,
                        selection: Binding(get: { choices[episodeId] }, set: { choices[episodeId] = $0 }),
                        applyToAll: { source in matchAll(to: source, from: episodeId) }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download \(ready.count)", systemImage: "arrow.down.circle") {
                        for (episode, source) in ready { downloads.enqueue(episode, source: source, startedByUser: true) }
                        onQueued()
                        dismiss()
                    }
                    .disabled(ready.isEmpty)
                    .accessibilityIdentifier("batch.download")
                }
            }
            .task { await loadAll() }
        }
    }

    @ViewBuilder private func row(for episode: JellyfinItem) -> some View {
        let title = [episode.episodeCode, episode.name].compactMap(\.self).joined(separator: " · ")
        switch details[episode.id] {
        case nil:
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text(title)
                    Text("Finding versions…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView()
            }
        case .failure(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try Again", systemImage: "arrow.clockwise") {
                    details[episode.id] = nil
                    Task { await load(episode) }
                }
                .font(.caption)
            }
        case .success(let detail):
            let sources = detail.mediaSources ?? []
            let chosen = sources.first { $0.id == choices[episode.id] }
            NavigationLink(value: episode.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    if let chosen {
                        VersionSummary(source: chosen)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No versions").font(.caption).foregroundStyle(.red)
                    }
                    if sources.count > 1 {
                        Text("\(sources.count) versions").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(sources.isEmpty)
        }
    }

    private func loadAll() async {
        await withTaskGroup { group in
            var pending = episodes.filter { details[$0.id] == nil }.makeIterator()
            for _ in 0..<Self.parallelLoads {
                guard let episode = pending.next() else { break }
                group.addTask { await load(episode) }
            }
            while await group.next() != nil {
                if let episode = pending.next() { group.addTask { await load(episode) } }
            }
        }
    }

    private func load(_ episode: JellyfinItem) async {
        guard let session else { return }
        do {
            let detail = try await session.client.item(id: episode.id, userId: session.userId)
            details[episode.id] = .success(detail)
            if choices[episode.id] == nil {
                choices[episode.id] = VersionChooser.choose(from: detail.mediaSources ?? [], quality: settings.downloadQuality)?.id
            }
        } catch {
            details[episode.id] = .failure(LoadFailure(message: error.localizedDescription))
        }
    }

    private func matchAll(to source: MediaSource, from episodeId: String) {
        for episode in episodes where episode.id != episodeId {
            guard case .success(let detail) = details[episode.id],
                  let match = source.closestMatch(in: detail.mediaSources ?? [])
            else { continue }
            choices[episode.id] = match.id
        }
    }
}

private struct VersionChoiceList: View {
    let episode: JellyfinItem
    @Binding var selection: String?
    let applyToAll: (MediaSource) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VersionPicker(sources: episode.mediaSources ?? [], selection: $selection)
            }
            Section {
                Button("Use the Closest Version for Every Episode", systemImage: "rectangle.stack") {
                    if let source = episode.mediaSources?.first(where: { $0.id == selection }) {
                        applyToAll(source)
                        dismiss()
                    }
                }
                .disabled(selection == nil)
            } footer: {
                Text("Picks, in each other episode, the version whose name and quality share the most with this one.")
            }
        }
        .navigationTitle(episode.episodeCode ?? episode.name)
    }
}
#endif
