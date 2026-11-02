#if !os(tvOS)
import SwiftUI

/// Video files from outside the server: recently opened ones, and on iPhone and iPad the ones
/// copied into the app's folder in the Files app.
struct LocalFilesSection: View {
    @Environment(LocalLibrary.self) private var localLibrary
    @Environment(WatchHistory.self) private var history
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        if !localLibrary.recents.isEmpty || !localLibrary.folderFiles.isEmpty {
            Section {
                ForEach(localLibrary.folderFiles, id: \.self) { url in
                    fileRow(name: url.lastPathComponent, key: key(for: url)) {
                        player.playFile(url)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { localLibrary.deleteFolderFile(url) }
                    }
                }
                ForEach(localLibrary.recents) { recent in
                    fileRow(name: recent.name, key: recent.historyKey) {
                        player.play(PlaybackRequest(source: .file(bookmark: recent.bookmark, name: recent.name),
                                                    title: (recent.name as NSString).deletingPathExtension))
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { localLibrary.remove(recent) }
                    }
                }
            } header: {
                Text("On This \(Device.name)")
            } footer: {
                if LocalLibrary.appFolder != nil {
                    Text("Videos you put in the vinnyfin folder in the Files app show up here too.")
                }
            }
        }
    }

    private func key(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        return WatchHistory.fileKey(name: url.lastPathComponent, size: size)
    }

    private func fileRow(name: String, key: String, play: @escaping () -> Void) -> some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text((name as NSString).deletingPathExtension).font(.body.weight(.medium)).lineLimit(2)
                    if let entry = history.entry(for: key) {
                        if entry.played {
                            Label("Watched", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.tint)
                        } else if let duration = entry.duration, duration > 0, entry.position > 0 {
                            ProgressBar(fraction: entry.position / duration).frame(maxWidth: 120)
                        }
                    } else {
                        Text((name as NSString).pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("file.\(name)")
    }
}
#endif
