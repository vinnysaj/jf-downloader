#if !os(tvOS)
import Foundation

/// The downloads as the Downloads widget and control show them and as Siri tells them: what's
/// downloading and how far along, and what's ready to watch offline.
///
/// The app writes it to the app group (`WidgetDownloads`) with one atomic write that leaves no
/// file open, and the widget extension only reads it. Nothing in the group stays open: iOS
/// ends an app suspended while it holds a lock on a file there.
nonisolated struct DownloadsSnapshot: Codable, Equatable, Sendable {
    /// A title, with what the widget needs to show it and to link to it.
    struct Title: Codable, Equatable, Sendable, Identifiable {
        let itemId: String
        let type: String
        /// The item's own name, for links.
        let name: String
        /// A movie's name and year, or an episode's name.
        let title: String
        /// An episode's show and number.
        let subtitle: String?
        /// Its picture is in `artworkFolder`.
        var hasArtwork = false

        var id: String { itemId }

        var item: JellyfinItem { JellyfinItem(id: itemId, name: name, type: type) }
        /// Opens the title's page.
        var openLink: URL { AppLink(.open, item).url }
        /// Plays it, from the download.
        var playLink: URL { AppLink(.play, item).url }
    }

    struct Download: Codable, Equatable, Sendable, Identifiable {
        enum State: String, Codable, Sendable {
            /// The file the session works on.
            case downloading
            case queued
            /// Waiting while something plays.
            case held
            case waitingForNetwork
            /// Held back by a download rule or for want of room, as `wait` says.
            case waiting
            case paused
            case failed
        }

        let title: Title
        let state: State
        /// How far along, in whole percent; nil until the size is known.
        let percent: Int?
        /// What a waiting download waits for, as its status line in the app says it.
        var wait: String?
        /// What the server is doing for a transcoded download, beside `percent` here: "Server
        /// preparing 42%".
        var note: String?

        var id: String { title.id }

        /// How far along, with the server's side of a transcode: "45% · Server preparing 60%".
        var progress: String? {
            let parts = [percent.map { "\($0)%" }, note].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// The unfinished downloads in queue order, the first few.
    var downloads: [Download] = []
    var unfinishedCount = 0
    /// Downloads that aren't paused or failed.
    var activeCount = 0
    /// Finished downloads not yet watched, newest first, the first few.
    var ready: [Title] = []
    var readyCount = 0
    var updatedAt = Date.distantPast

    /// How many of each list the snapshot keeps: as many as the largest widget shows.
    static let listLimit = 4

    static let widgetKind = "net.vinnysaj.vinnyfin.downloads"
    static let controlKind = "net.vinnysaj.vinnyfin.downloads.control"

    /// Where the app keeps it in the app group, with the titles' pictures beside it.
    static var folder: URL? { AppGroup.container?.appending(path: "Downloads Widget", directoryHint: .isDirectory) }
    static var file: URL? { folder?.appending(path: "snapshot.json") }
    static var artworkFolder: URL? { folder?.appending(path: "Artwork", directoryHint: .isDirectory) }

    static func artworkFile(for itemId: String) -> URL? {
        artworkFolder?.appending(path: "\(itemId).jpg")
    }

    /// The last snapshot the app wrote; nil before it has written one.
    static func load() throws -> DownloadsSnapshot? {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(DownloadsSnapshot.self, from: Data(contentsOf: file))
    }

    /// Something is downloading or waiting its turn.
    var isRunning: Bool { activeCount > 0 }

    /// The download the session works on, or else the first one waiting.
    var current: Download? { downloads.first }

    /// What Siri says: what's downloading, how far along and what's behind it, then what's ready.
    var summary: String {
        var sentences: [String] = []
        if let current, activeCount > 0 {
            let progress = current.percent.flatMap { $0 > 0 ? ", \($0)% done" : nil } ?? ""
            let behind = activeCount - 1
            let more = behind > 0 ? ", with \(behind) more after it" : ""
            switch current.state {
            case .downloading:
                sentences.append("\(current.title.title) is downloading\(progress)\(more).")
                if let note = current.note { sentences.append("\(note).") }
            case .held: sentences.append("Downloads wait while you watch. \(current.title.title) is next\(progress)\(more).")
            case .waitingForNetwork: sentences.append("Downloads are waiting for a network connection. \(current.title.title) is next\(progress)\(more).")
            case .waiting: sentences.append("\(current.title.title) is next\(progress)\(more). \(current.wait ?? "It's waiting").")
            case .queued, .paused, .failed: sentences.append("\(current.title.title) is next\(progress)\(more).")
            }
        } else if unfinishedCount == 0 {
            sentences.append("Nothing is downloading.")
        }
        let paused = unfinishedCount - activeCount
        if paused > 0 {
            sentences.append(paused == 1 ? "1 download is paused or stopped." : "\(paused) downloads are paused or stopped.")
        }
        switch readyCount {
        case 0: sentences.append("Nothing new is ready to watch offline.")
        case 1: sentences.append("\(ready.first?.title ?? "1 download") is ready to watch offline.")
        default: sentences.append("\(readyCount) downloads are ready to watch offline.")
        }
        return sentences.joined(separator: " ")
    }

    /// One short line, for the Lock Screen: "Pilot 45% · 2 more" or "3 ready to watch".
    var line: String {
        if let current, activeCount > 0 {
            let progress = current.progress.map { " \($0)" } ?? ""
            return activeCount > 1 ? "\(current.title.title)\(progress) · \(activeCount - 1) more" : "\(current.title.title)\(progress)"
        }
        if unfinishedCount > 0 { return "Downloads paused" }
        return readyCount > 0 ? "\(readyCount) ready to watch" : "No downloads"
    }

    /// Whether it differs from `old` in more than progress: a download that starts, ends, stops
    /// or moves up, or a title that's ready.
    func differsInMoreThanProgress(from old: DownloadsSnapshot) -> Bool {
        func shape(_ snapshot: DownloadsSnapshot) -> [String] {
            snapshot.downloads.map { "\($0.id) \($0.state.rawValue)" } + snapshot.ready.map(\.id)
                + ["\(snapshot.unfinishedCount) \(snapshot.activeCount) \(snapshot.readyCount)"]
        }
        return shape(self) != shape(old)
    }

    /// The least time between widget reloads for a change in more than progress, which folds a
    /// burst of them into one, and for progress alone. The system allows an app in the
    /// background only so many reloads a day.
    static let changeReloadInterval: TimeInterval = 5
    static let progressReloadInterval: TimeInterval = 60

    /// When to write this snapshot and reload the widget, given the one last written at
    /// `writtenAt`: soon for a change in more than progress, a minute after the last for
    /// progress alone, and never when nothing changed.
    func writeDate(after written: DownloadsSnapshot?, writtenAt: Date) -> Date? {
        guard let written else { return .distantPast }
        var unstamped = self
        unstamped.updatedAt = written.updatedAt
        if unstamped == written { return nil }
        let interval = differsInMoreThanProgress(from: written) ? Self.changeReloadInterval : Self.progressReloadInterval
        return writtenAt.addingTimeInterval(interval)
    }
}
#endif
