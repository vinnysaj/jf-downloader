#if !os(tvOS)
import SwiftUI

/// Downloads worth having before going offline: the shows being watched, kept ahead with smart
/// downloads, and the movies left half-watched.
struct SuggestedDownloadsShelf: View {
    let nextUp: [JellyfinItem]
    let resume: [JellyfinItem]

    @Environment(\.session) private var session
    @Environment(DownloadManager.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages

    private struct Suggestion: Identifiable {
        enum Kind { case keepShow, movie }
        let kind: Kind
        let item: JellyfinItem
        var id: String { item.id }
    }

    private var suggestions: [Suggestion] {
        var seenShows = Set<String>()
        let shows = nextUp.compactMap { episode -> Suggestion? in
            guard let seriesId = episode.seriesId, smartDownloads.rule(for: seriesId) == nil,
                  !downloads.isDownloaded(episode.id), seenShows.insert(seriesId).inserted
            else { return nil }
            return Suggestion(kind: .keepShow, item: episode)
        }
        let movies = resume.filter { $0.isMovie && downloads.jobs(forItem: $0.id).isEmpty }.map { Suggestion(kind: .movie, item: $0) }
        return Array((shows + movies).prefix(12))
    }

    var body: some View {
        let suggestions = suggestions
        if !suggestions.isEmpty {
            Shelf(title: "Suggested Downloads", items: suggestions, cardWidth: Metrics.landscapeWidth) { suggestion in
                Button {
                    Task { await accept(suggestion) }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Artwork(url: session?.landscape(suggestion.item), aspectRatio: 16.0 / 9.0)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: suggestion.kind == .keepShow ? "sparkles" : "arrow.down.circle.fill")
                                    .font(.title3)
                                    .padding(8)
                                    .platformGlass(in: .circle)
                                    .padding(8)
                            }
                        Text(suggestion.kind == .keepShow ? (suggestion.item.seriesName ?? suggestion.item.name) : suggestion.item.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(suggestion.kind == .keepShow
                             ? "Keep the next \(settings.smartDownloadCount) episodes downloaded"
                             : "Download to finish offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.artwork)
                .accessibilityIdentifier("suggestion.\(suggestion.item.seriesName ?? suggestion.item.name)")
            }
        }
    }

    private func accept(_ suggestion: Suggestion) async {
        switch suggestion.kind {
        case .keepShow:
            guard let seriesId = suggestion.item.seriesId else { return }
            smartDownloads.setRule(seriesId: seriesId, seriesName: suggestion.item.seriesName ?? suggestion.item.name,
                                   episodesAhead: settings.smartDownloadCount)
        case .movie:
            guard let session else { return }
            do {
                let detail = try await session.client.item(id: suggestion.item.id, userId: session.userId)
                guard let source = VersionChooser.choose(from: detail.mediaSources ?? [], quality: settings.downloadQuality) else {
                    messages.show("The server lists no versions of \(suggestion.item.name) to download.")
                    return
                }
                downloads.enqueue(detail, source: source)
            } catch {
                messages.show("Couldn't start the download of \(suggestion.item.name): \(error.localizedDescription)")
            }
        }
    }
}
#endif
