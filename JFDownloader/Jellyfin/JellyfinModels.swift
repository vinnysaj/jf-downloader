import Foundation

/// The parts of Jellyfin's `BaseItemDto` this app reads.
nonisolated struct JellyfinItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let productionYear: Int?
    let seriesName: String?
    let seriesId: String?
    let seasonId: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let indexNumberEnd: Int?
    let collectionType: String?
    let overview: String?
    let runTimeTicks: Int64?
    let imageTags: [String: String]?
    let seriesPrimaryImageTag: String?
    let mediaSources: [MediaSource]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", productionYear = "ProductionYear"
        case seriesName = "SeriesName", seriesId = "SeriesId", seasonId = "SeasonId"
        case parentIndexNumber = "ParentIndexNumber", indexNumber = "IndexNumber"
        case indexNumberEnd = "IndexNumberEnd", collectionType = "CollectionType"
        case overview = "Overview", runTimeTicks = "RunTimeTicks", imageTags = "ImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag", mediaSources = "MediaSources"
    }

    var isSeries: Bool { type == "Series" }
    var isEpisode: Bool { type == "Episode" }

    var primaryImageTag: String? { imageTags?["Primary"] }

    /// "S01E02", or "S01E02-E03" for a multi-episode file.
    var episodeCode: String? {
        guard let indexNumber else { return nil }
        let season = String(format: "S%02d", parentIndexNumber ?? 0)
        let episode = String(format: "E%02d", indexNumber)
        if let indexNumberEnd, indexNumberEnd > indexNumber {
            return season + episode + String(format: "-E%02d", indexNumberEnd)
        }
        return season + episode
    }

    var runtime: Duration? {
        runTimeTicks.map { .milliseconds($0 / 10_000) }
    }
}

/// The parts of Jellyfin's `MediaSourceInfo` this app reads: one version of an item.
/// Behind Gelato, every stream the addon found is one of these.
nonisolated struct MediaSource: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let path: String?
    let `protocol`: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let mediaStreams: [MediaStream]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", path = "Path", `protocol` = "Protocol"
        case container = "Container", size = "Size", bitrate = "Bitrate", mediaStreams = "MediaStreams"
    }

    var videoStream: MediaStream? { mediaStreams?.first { $0.type == "Video" } }
    var audioStreams: [MediaStream] { mediaStreams?.filter { $0.type == "Audio" } ?? [] }
    var subtitleStreams: [MediaStream] { mediaStreams?.filter { $0.type == "Subtitle" } ?? [] }

    /// The size Jellyfin reports, when it is believable. A `.strm` or other remote source
    /// reports the size of its pointer file (a few bytes), not of the stream.
    var plausibleSize: Int64? {
        guard let size, size > 1_000_000 else { return nil }
        return size
    }

    /// The file extension the download should get, from the source's path or container.
    var fileExtension: String? {
        if let path, let ext = Self.videoExtension(fromPath: path) { return ext }
        // ffprobe reports some containers as a list, e.g. "mov,mp4,m4a,3gp,3g2,mj2".
        for token in (container ?? "").lowercased().split(separator: ",") {
            switch token {
            case "matroska", "mkv": return "mkv"
            case "mp4", "mov", "m4v": return String(token)
            case "webm", "avi", "ts", "m2ts", "wmv", "flv", "mpeg", "mpg", "ogv": return String(token)
            default: continue
            }
        }
        return nil
    }

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "wmv", "flv", "mpg", "mpeg", "ogv", "iso",
    ]

    static func videoExtension(fromPath path: String) -> String? {
        let lastComponent: String
        if let url = URL(string: path), url.scheme != nil {
            lastComponent = url.lastPathComponent
        } else {
            lastComponent = (path as NSString).lastPathComponent
        }
        let ext = (lastComponent as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext) ? ext : nil
    }
}

nonisolated struct MediaStream: Decodable, Hashable, Sendable {
    let type: String
    let displayTitle: String?
    let codec: String?
    let language: String?
    let height: Int?
    let width: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type", displayTitle = "DisplayTitle", codec = "Codec", language = "Language"
        case height = "Height", width = "Width"
    }
}

nonisolated struct ItemsPage: Decodable, Sendable {
    let items: [JellyfinItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items", totalRecordCount = "TotalRecordCount"
    }
}

nonisolated struct PublicSystemInfo: Decodable, Sendable {
    let serverName: String?
    let version: String?
    let id: String

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName", version = "Version", id = "Id"
    }
}

nonisolated struct AuthenticationResult: Decodable, Sendable {
    struct User: Decodable, Sendable {
        let id: String
        let name: String
        enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
    }

    let user: User
    let accessToken: String
    let serverId: String

    enum CodingKeys: String, CodingKey {
        case user = "User", accessToken = "AccessToken", serverId = "ServerId"
    }
}
