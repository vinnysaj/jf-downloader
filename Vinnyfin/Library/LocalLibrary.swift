#if !os(tvOS)
import Foundation
import Observation

/// Video files on this device that aren't server downloads: ones opened from the Files app or
/// Finder (remembered as bookmarks), and, on iPhone and iPad, ones copied into the app's folder.
@Observable
final class LocalLibrary {
    nonisolated struct Recent: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var name: String
        var bookmark: Data
        var size: Int64
        var openedAt: Date

        var historyKey: String { WatchHistory.fileKey(name: name, size: size) }
    }

    private(set) var recents: [Recent] = []
    /// Videos in the app's own folder that no download put there.
    private(set) var folderFiles: [URL] = []
    var problem: String?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let folder: URL?

    static let maxRecents = 50

    init(file: URL = URL.applicationSupportDirectory.appending(path: "RecentFiles.json"), folder: URL? = LocalLibrary.appFolder) {
        self.file = file
        self.folder = folder
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            recents = try JSONDecoder().decode([Recent].self, from: Data(contentsOf: file))
        } catch {
            problem = "Couldn't read the list of recent files: \(error.localizedDescription)"
        }
    }

    /// Documents, which the Files app shows as the app's folder. The Mac has no such folder.
    static var appFolder: URL? {
        #if os(macOS)
        nil
        #else
        URL.documentsDirectory
        #endif
    }

    /// Remembers a file that was opened, most recent first. The caller holds access to `url`.
    func noteOpened(_ url: URL, request: PlaybackRequest) {
        guard case .file(let bookmark, let name) = request.source else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        recents.removeAll { $0.name == name && $0.size == size }
        recents.insert(Recent(name: name, bookmark: bookmark, size: size, openedAt: .now), at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
    }

    func remove(_ recent: Recent) {
        recents.removeAll { $0.id == recent.id }
        save()
    }

    /// Lists the videos in the app's folder, leaving out the files downloads put there.
    func scanFolder(excluding downloaded: Set<String>) {
        guard let folder else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return
        }
        var found: [URL] = []
        let excluded = Set(downloaded.map { folder.appending(path: $0).standardizedFileURL.path })
        for case let url as URL in enumerator {
            guard MediaSource.videoExtensions.contains(url.pathExtension.lowercased()),
                  !excluded.contains(url.standardizedFileURL.path)
            else { continue }
            found.append(url)
        }
        folderFiles = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func deleteFolderFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            folderFiles.removeAll { $0 == url }
        } catch {
            problem = "Couldn't delete \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recents).write(to: file, options: .atomic)
        } catch {
            problem = "Couldn't save the list of recent files: \(error.localizedDescription)"
        }
    }
}
#endif
