import Foundation

/// The parts of Jellyfin's `BaseItemDto` this app reads. Encodable too, so a downloaded item
/// keeps a snapshot of itself for browsing offline.
nonisolated struct JellyfinItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    var sortName: String?
    var overview: String?
    var taglines: [String]?
    var genres: [String]?
    var productionYear: Int?
    var premiereDate: String?
    var dateCreated: String?
    var officialRating: String?
    var communityRating: Double?
    var criticRating: Double?
    var status: String?
    var seriesName: String?
    var seriesId: String?
    var seasonId: String?
    var seasonName: String?
    var parentIndexNumber: Int?
    var indexNumber: Int?
    var indexNumberEnd: Int?
    var collectionType: String?
    var runTimeTicks: Int64?
    var childCount: Int?
    /// For a genre asked for with its item counts: how many movies and shows have it.
    var movieCount: Int?
    var seriesCount: Int?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var seriesPrimaryImageTag: String?
    var primaryImageAspectRatio: Double?
    var userData: UserItemData?
    var mediaSources: [MediaSource]?
    var people: [Person]?
    var chapters: [Chapter]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", sortName = "SortName", overview = "Overview"
        case taglines = "Taglines", genres = "Genres", productionYear = "ProductionYear"
        case premiereDate = "PremiereDate", dateCreated = "DateCreated", officialRating = "OfficialRating"
        case communityRating = "CommunityRating", criticRating = "CriticRating", status = "Status"
        case seriesName = "SeriesName", seriesId = "SeriesId", seasonId = "SeasonId", seasonName = "SeasonName"
        case parentIndexNumber = "ParentIndexNumber", indexNumber = "IndexNumber"
        case indexNumberEnd = "IndexNumberEnd", collectionType = "CollectionType"
        case runTimeTicks = "RunTimeTicks", childCount = "ChildCount", movieCount = "MovieCount"
        case seriesCount = "SeriesCount", imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags", parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags", parentLogoItemId = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag", parentThumbItemId = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag", seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio", userData = "UserData"
        case mediaSources = "MediaSources", people = "People", chapters = "Chapters"
    }

    init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }

    // Navigation and lists key items by id; equality also looks at the watch state so a row
    // showing it redraws when it changes.
    static func == (lhs: JellyfinItem, rhs: JellyfinItem) -> Bool {
        lhs.id == rhs.id && lhs.userData == rhs.userData
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var isSeries: Bool { type == "Series" }
    var isEpisode: Bool { type == "Episode" }
    var isMovie: Bool { type == "Movie" }
    var isSeason: Bool { type == "Season" }
    var isCollection: Bool { type == "BoxSet" }
    /// Something with a file of its own to play or download.
    var isPlayable: Bool { !isSeries && !isSeason && !isCollection && type != "Folder" && type != "CollectionFolder" }

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

    /// "1 hr, 52 min", or seconds for a clip under a minute.
    var runtimeText: String? {
        guard let runtime, runtime > .zero else { return nil }
        let units: Set<Duration.UnitsFormatStyle.Unit> = runtime < .seconds(60) ? [.seconds] : [.hours, .minutes]
        return runtime.formatted(.units(allowed: units, width: .abbreviated))
    }

    var runtimeSeconds: Double? {
        runTimeTicks.map { Double($0) / 10_000_000 }
    }

    /// Where a resumed playback starts, when the server has one.
    var resumeSeconds: Double? {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0, userData?.played != true else { return nil }
        return Double(ticks) / 10_000_000
    }

    /// How far through the item playback got, 0...1, for a progress bar.
    var progress: Double? {
        if let percentage = userData?.playedPercentage, percentage > 0, userData?.played != true {
            return min(1, percentage / 100)
        }
        guard let resume = resumeSeconds, let total = runtimeSeconds, total > 0 else { return nil }
        return min(1, resume / total)
    }

    var isPlayed: Bool { userData?.played == true }
    var isFavorite: Bool { userData?.isFavorite == true }

    /// The movie or show it's part of: an episode's show, or itself. Titles like an episode are
    /// titles like its show.
    var titleId: String { isEpisode ? (seriesId ?? id) : id }
    var titleName: String { isEpisode ? (seriesName ?? name) : name }

    var premiereYearText: String? {
        productionYear.map(String.init)
    }

    var addedDate: Date? { dateCreated.flatMap(JellyfinDate.parse) }
    var lastPlayedDate: Date? { userData?.lastPlayedDate.flatMap(JellyfinDate.parse) }
}

nonisolated struct UserItemData: Codable, Hashable, Sendable {
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var isFavorite: Bool?
    var played: Bool?
    var lastPlayedDate: String?
    var unplayedItemCount: Int?
    var playedPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks", playCount = "PlayCount"
        case isFavorite = "IsFavorite", played = "Played", lastPlayedDate = "LastPlayedDate"
        case unplayedItemCount = "UnplayedItemCount", playedPercentage = "PlayedPercentage"
    }
}

nonisolated struct Person: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    var role: String?
    var type: String?
    var primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", role = "Role", type = "Type", primaryImageTag = "PrimaryImageTag"
    }
}

nonisolated struct Chapter: Codable, Hashable, Sendable {
    var startPositionTicks: Int64
    var name: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks", name = "Name"
    }
}

/// The parts of Jellyfin's `MediaSourceInfo` this app reads: one version of an item.
/// Behind Gelato, every stream the addon found is one of these.
nonisolated struct MediaSource: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String?
    var path: String?
    var `protocol`: String?
    var container: String?
    var size: Int64?
    var bitrate: Int?
    var runTimeTicks: Int64?
    var isRemote: Bool?
    var supportsDirectPlay: Bool?
    var supportsTranscoding: Bool?
    var transcodingUrl: String?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var mediaStreams: [MediaStream]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", path = "Path", `protocol` = "Protocol"
        case container = "Container", size = "Size", bitrate = "Bitrate", runTimeTicks = "RunTimeTicks"
        case isRemote = "IsRemote", supportsDirectPlay = "SupportsDirectPlay"
        case supportsTranscoding = "SupportsTranscoding", transcodingUrl = "TranscodingUrl"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex", mediaStreams = "MediaStreams"
    }

    init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }

    var runtimeSeconds: Double? { runTimeTicks.map { Double($0) / 10_000_000 } }
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
        "vob", "3gp", "3g2", "asf", "rm", "rmvb", "divx", "f4v", "ogm",
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

nonisolated struct MediaStream: Codable, Hashable, Sendable {
    let type: String
    var index: Int?
    var displayTitle: String?
    var title: String?
    var codec: String?
    var profile: String?
    var language: String?
    var height: Int?
    var width: Int?
    var channels: Int?
    var channelLayout: String?
    var bitRate: Int?
    var isDefault: Bool?
    var isForced: Bool?
    var isExternal: Bool?
    var isHearingImpaired: Bool?
    var videoRange: String?
    var videoRangeType: String?
    var audioSpatialFormat: String?
    var deliveryUrl: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type", index = "Index", displayTitle = "DisplayTitle", title = "Title"
        case codec = "Codec", profile = "Profile", language = "Language", height = "Height", width = "Width"
        case channels = "Channels", channelLayout = "ChannelLayout", bitRate = "BitRate"
        case isDefault = "IsDefault", isForced = "IsForced", isExternal = "IsExternal"
        case isHearingImpaired = "IsHearingImpaired", videoRange = "VideoRange"
        case videoRangeType = "VideoRangeType", audioSpatialFormat = "AudioSpatialFormat"
        case deliveryUrl = "DeliveryUrl"
    }

    init(type: String) {
        self.type = type
    }
}

nonisolated struct ItemsPage: Decodable, Sendable {
    let items: [JellyfinItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items", totalRecordCount = "TotalRecordCount"
    }

    init(items: [JellyfinItem], totalRecordCount: Int) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([JellyfinItem].self, forKey: .items)
        // Some list endpoints leave the count out.
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount) ?? items.count
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

nonisolated struct QuickConnectState: Decodable, Identifiable, Sendable {
    let secret: String
    let code: String
    let authenticated: Bool

    var id: String { secret }

    enum CodingKeys: String, CodingKey {
        case secret = "Secret", code = "Code", authenticated = "Authenticated"
    }
}

nonisolated struct PlaybackInfoResponse: Decodable, Sendable {
    let mediaSources: [MediaSource]
    let playSessionId: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources", playSessionId = "PlaySessionId", errorCode = "ErrorCode"
    }
}

/// A stretch of an item the server's media segment providers marked, such as the intro.
/// Kept with downloads in the server's own format.
nonisolated struct MediaSegment: Codable, Sendable, Hashable {
    let type: String
    let startTicks: Int64
    let endTicks: Int64

    enum CodingKeys: String, CodingKey {
        case type = "Type", startTicks = "StartTicks", endTicks = "EndTicks"
    }

    var start: Double { Double(startTicks) / 10_000_000 }
    var end: Double { Double(endTicks) / 10_000_000 }

    /// What the button to skip it says, for the kinds worth skipping.
    var skipTitle: String? {
        switch type {
        case "Intro": "Skip Intro"
        case "Recap": "Skip Recap"
        case "Preview": "Skip Preview"
        case "Outro": "Skip Credits"
        default: nil
        }
    }
}

nonisolated struct MediaSegmentsPage: Decodable, Sendable {
    let items: [MediaSegment]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

nonisolated enum JellyfinDate {
    /// Jellyfin writes dates with up to seven fractional digits, which `ISO8601DateFormatter`
    /// rejects; the fraction is dropped before parsing.
    static func parse(_ text: String) -> Date? {
        var trimmed = text
        if let dot = trimmed.firstIndex(of: ".") {
            let suffixStart = trimmed[dot...].firstIndex { $0 == "Z" || $0 == "+" || $0 == "-" } ?? trimmed.endIndex
            trimmed.removeSubrange(dot..<suffixStart)
        }
        if !trimmed.hasSuffix("Z"), trimmed.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil {
            trimmed += "Z"
        }
        return try? Date(trimmed, strategy: .iso8601)
    }

    static func format(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
