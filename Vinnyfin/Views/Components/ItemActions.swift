import SwiftUI

/// The long-press menu for a title: play, watched, favourite and, off Apple TV, download.
struct ItemContextMenu: View {
    let item: JellyfinItem
    /// Gets the item with its new watch state, to update the list it came from.
    var onChange: (JellyfinItem) -> Void = { _ in }

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @Environment(SmartDownloads.self) private var smartDownloads
    #endif

    var body: some View {
        if item.isPlayable {
            Button(item.resumeSeconds != nil ? "Resume" : "Play", systemImage: "play.fill") {
                player.play(.item(item))
            }
            if item.resumeSeconds != nil {
                Button("Play from Beginning", systemImage: "arrow.counterclockwise") {
                    player.play(.item(item, fromBeginning: true))
                }
            }
        }
        Button(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched",
               systemImage: item.isPlayed ? "eye.slash" : "eye") {
            Task { await setPlayed(!item.isPlayed) }
        }
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: item.isFavorite ? "heart.slash" : "heart") {
            Task { await setFavorite(!item.isFavorite) }
        }
        #if !os(tvOS)
        if item.isMovie || item.isEpisode {
            if downloads.isDownloaded(item.id) {
                Button("Delete Download", systemImage: "trash", role: .destructive) {
                    downloads.deleteDownloads(ofItem: item.id)
                }
            } else if downloads.jobs(forItem: item.id).isEmpty {
                Button("Download", systemImage: "arrow.down.circle") {
                    Task { await download() }
                }
            }
        }
        if item.isSeries {
            if smartDownloads.rule(for: item.id) == nil {
                Button("Keep Next \(settings.smartDownloadCount) Downloaded", systemImage: "sparkles") {
                    smartDownloads.setRule(seriesId: item.id, seriesName: item.name, episodesAhead: settings.smartDownloadCount)
                }
            } else {
                Button("Stop Smart Downloads", systemImage: "sparkles") {
                    smartDownloads.removeRule(seriesId: item.id)
                }
            }
        }
        #endif
    }

    private func setPlayed(_ played: Bool) async {
        guard let session else { return }
        await WatchActions.setPlayed(played, on: item, session: session, messages: messages, onChange: onChange)
    }

    private func setFavorite(_ favorite: Bool) async {
        guard let session else { return }
        await WatchActions.setFavorite(favorite, on: item, session: session, messages: messages, onChange: onChange)
    }

    #if !os(tvOS)
    private func download() async {
        guard let session else { return }
        do {
            let detail = try await session.client.item(id: item.id, userId: session.userId)
            if let problem = await downloads.download(detail, settings: settings) { messages.show(problem) }
        } catch {
            messages.show("Couldn't start the download of \(item.name): \(error.localizedDescription)")
        }
    }
    #endif
}

/// Watched and favourite changes: shown at once, sent to the server, undone if it refuses.
enum WatchActions {
    static func setPlayed(_ played: Bool, on item: JellyfinItem, session: ServerSession, messages: AppMessages,
                          onChange: (JellyfinItem) -> Void) async {
        var updated = item
        var data = item.userData ?? UserItemData()
        data.played = played
        data.playbackPositionTicks = 0
        data.playedPercentage = nil
        if item.isSeries, played { data.unplayedItemCount = 0 }
        updated.userData = data
        onChange(updated)
        do {
            try await session.client.setPlayed(played, itemId: item.id, userId: session.userId)
        } catch {
            onChange(item)
            messages.show("Couldn't update \(item.name): \(error.localizedDescription)")
        }
    }

    static func setFavorite(_ favorite: Bool, on item: JellyfinItem, session: ServerSession, messages: AppMessages,
                            onChange: (JellyfinItem) -> Void) async {
        var updated = item
        var data = item.userData ?? UserItemData()
        data.isFavorite = favorite
        updated.userData = data
        onChange(updated)
        do {
            try await session.client.setFavorite(favorite, itemId: item.id, userId: session.userId)
        } catch {
            onChange(item)
            messages.show("Couldn't update \(item.name): \(error.localizedDescription)")
        }
    }
}
