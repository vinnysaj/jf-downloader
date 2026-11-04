import Foundation

nonisolated enum JellyfinError: LocalizedError {
    /// The message says what's wrong with the address.
    case invalidServerAddress(String)
    case notJellyfin(URL)
    case http(status: Int, body: String)
    case invalidCredentials
    case quickConnectDisabled

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress(let message):
            message
        case .notJellyfin(let url):
            "No Jellyfin server answered at \(url.absoluteString)."
        case .http(let status, let body):
            body.isEmpty
                ? "The server answered with HTTP \(status)."
                : "The server answered with HTTP \(status): \(body)"
        case .invalidCredentials:
            "Wrong username or password."
        case .quickConnectDisabled:
            "Quick Connect is turned off on this server. An administrator can turn it on in the dashboard."
        }
    }
}

/// The Jellyfin API calls the app makes. Every call authenticates with the
/// `Authorization: MediaBrowser …` header; media URLs carry the token as `ApiKey`
/// instead, so a background transfer or the player needs nothing but the URL.
nonisolated struct JellyfinClient: Sendable {
    static let clientName = "vinnyfin"

    let serverURL: URL
    let deviceId: String
    /// What the server's device list calls this device.
    let deviceName: String
    var token: String?

    /// Fields the browsing screens show, asked for on list calls.
    static let listFields = "PrimaryImageAspectRatio,SortName,DateCreated,Genres,Overview,ChildCount"
    /// Everything a detail screen shows.
    static let detailFields = "Overview,Genres,People,Taglines,MediaSources,MediaStreams,Chapters,SortName,DateCreated,ChildCount,PrimaryImageAspectRatio"

    // MARK: Server and sign-in

    func publicSystemInfo() async throws -> PublicSystemInfo {
        do {
            return try await get("System/Info/Public")
        } catch is DecodingError {
            throw JellyfinError.notJellyfin(serverURL)
        }
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        struct Body: Encodable {
            let Username: String
            let Pw: String
        }
        do {
            return try await post("Users/AuthenticateByName", body: Body(Username: username, Pw: password))
        } catch JellyfinError.http(let status, _) where status == 401 {
            throw JellyfinError.invalidCredentials
        }
    }

    func quickConnectEnabled() async throws -> Bool {
        try await get("QuickConnect/Enabled")
    }

    /// Starts a Quick Connect request; the user approves `code` in another signed-in client.
    func initiateQuickConnect() async throws -> QuickConnectState {
        do {
            return try await post("QuickConnect/Initiate")
        } catch JellyfinError.http(let status, _) where status == 401 || status == 403 {
            throw JellyfinError.quickConnectDisabled
        }
    }

    func quickConnectState(secret: String) async throws -> QuickConnectState {
        try await get("QuickConnect/Connect", query: ["secret": secret])
    }

    func authenticate(quickConnectSecret secret: String) async throws -> AuthenticationResult {
        struct Body: Encodable { let Secret: String }
        return try await post("Users/AuthenticateWithQuickConnect", body: Body(Secret: secret))
    }

    func signOut() async throws {
        try await send("Sessions/Logout", method: "POST")
    }

    // MARK: Browsing

    func libraries(userId: String) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("UserViews", query: ["userId": userId])
        return page.items.filter { Self.videoCollectionTypes.contains($0.collectionType ?? "") }
    }

    /// Collection types that hold movies or episodes. "" stands for a view without one (mixed content).
    static let videoCollectionTypes: Set<String> = ["movies", "tvshows", "homevideos", "musicvideos", "mixed", ""]

    struct ItemQuery: Sendable, Equatable {
        var types: [String] = ["Movie", "Series"]
        var parentId: String?
        var searchTerm: String?
        var sortBy = "SortName"
        var ascending = true
        var isPlayed: Bool?
        var isFavorite: Bool?
        var genres: [String] = []
        var fields = JellyfinClient.listFields
        var startIndex = 0
        var limit: Int?
    }

    func items(userId: String, _ query: ItemQuery) async throws -> ItemsPage {
        var parameters = [
            "userId": userId,
            "recursive": "true",
            "includeItemTypes": query.types.joined(separator: ","),
            "sortBy": query.sortBy == "SortName" ? "SortName" : "\(query.sortBy),SortName",
            "sortOrder": query.ascending ? "Ascending" : "Descending",
            "fields": query.fields,
            "imageTypeLimit": "1",
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
            "enableUserData": "true",
            "startIndex": String(query.startIndex),
        ]
        if let limit = query.limit { parameters["limit"] = String(limit) }
        if let parentId = query.parentId { parameters["parentId"] = parentId }
        if let term = query.searchTerm, !term.isEmpty { parameters["searchTerm"] = term }
        if let played = query.isPlayed { parameters["isPlayed"] = String(played) }
        if query.isFavorite == true { parameters["isFavorite"] = "true" }
        if !query.genres.isEmpty { parameters["genres"] = query.genres.joined(separator: "|") }
        return try await get("Items", query: parameters)
    }

    /// The item with its media sources. Behind Gelato this is also the call that makes the
    /// server look up the item's streams, so it can take a few seconds.
    func item(id: String, userId: String) async throws -> JellyfinItem {
        try await get("Items/\(id)", query: ["userId": userId, "fields": Self.detailFields])
    }

    func resumeItems(userId: String, limit: Int = 20) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("UserItems/Resume", query: [
            "userId": userId, "limit": String(limit), "mediaTypes": "Video",
            "fields": Self.listFields, "enableUserData": "true", "imageTypeLimit": "1",
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
        ])
        return page.items
    }

    /// The next episode to watch of every show in progress, or of one show.
    func nextUp(userId: String, seriesId: String? = nil, limit: Int = 20) async throws -> [JellyfinItem] {
        var query = [
            "userId": userId, "limit": String(limit), "fields": Self.listFields,
            "enableUserData": "true", "imageTypeLimit": "1", "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
            "enableResumable": "true", "disableFirstEpisode": "false",
        ]
        if let seriesId { query["seriesId"] = seriesId }
        let page: ItemsPage = try await get("Shows/NextUp", query: query)
        return page.items
    }

    func latest(userId: String, types: [String], limit: Int = 24) async throws -> [JellyfinItem] {
        try await get("Items/Latest", query: [
            "userId": userId, "includeItemTypes": types.joined(separator: ","), "limit": String(limit),
            "fields": Self.listFields, "enableUserData": "true", "groupItems": "true",
            "imageTypeLimit": "1", "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
        ])
    }

    func recentlyPlayed(userId: String, limit: Int = 20) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("Items", query: [
            "userId": userId, "recursive": "true", "includeItemTypes": "Movie,Episode",
            "filters": "IsPlayed", "sortBy": "DatePlayed", "sortOrder": "Descending",
            "limit": String(limit), "fields": Self.listFields, "enableUserData": "true",
            "imageTypeLimit": "1", "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
        ])
        return page.items
    }

    func similar(to itemId: String, userId: String, limit: Int = 16) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("Items/\(itemId)/Similar", query: [
            "userId": userId, "limit": String(limit), "fields": Self.listFields,
        ])
        return page.items
    }

    func genres(userId: String, types: [String]) async throws -> [String] {
        let page: ItemsPage = try await get("Genres", query: [
            "userId": userId, "includeItemTypes": types.joined(separator: ","), "sortBy": "SortName",
        ])
        return page.items.map(\.name)
    }

    func seasons(seriesId: String, userId: String) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("Shows/\(seriesId)/Seasons", query: [
            "userId": userId, "enableUserData": "true", "fields": "ChildCount",
        ])
        return page.items
    }

    /// One season's episodes, or every episode of the show in order when `seasonId` is nil.
    func episodes(seriesId: String, seasonId: String?, userId: String, fields: String = "Overview,MediaSources,MediaStreams") async throws -> [JellyfinItem] {
        var query = ["userId": userId, "fields": fields, "enableUserData": "true"]
        if let seasonId { query["seasonId"] = seasonId }
        let page: ItemsPage = try await get("Shows/\(seriesId)/Episodes", query: query)
        return page.items
    }

    /// The episode after `episodeId` in the show's order, if there is one.
    func episode(after episodeId: String, seriesId: String, userId: String) async throws -> JellyfinItem? {
        let page: ItemsPage = try await get("Shows/\(seriesId)/Episodes", query: [
            "userId": userId, "startItemId": episodeId, "limit": "2", "enableUserData": "true",
            "fields": Self.listFields,
        ])
        return page.items.dropFirst().first { $0.parentIndexNumber != 0 }
    }

    /// Every kind of segment; `MediaSegment.skipTitle` picks the ones worth skipping. Jellyfin's
    /// type filter wants the parameter repeated, and answers a comma-separated list with a 400.
    func mediaSegments(itemId: String) async throws -> [MediaSegment] {
        let page: MediaSegmentsPage = try await get("MediaSegments/\(itemId)")
        return page.items
    }

    // MARK: Watch state

    func setPlayed(_ played: Bool, itemId: String, userId: String) async throws {
        try await send("UserPlayedItems/\(itemId)", method: played ? "POST" : "DELETE", query: ["userId": userId])
    }

    func setFavorite(_ favorite: Bool, itemId: String, userId: String) async throws {
        try await send("UserFavoriteItems/\(itemId)", method: favorite ? "POST" : "DELETE", query: ["userId": userId])
    }

    /// Writes a position and played state recorded while the server couldn't be reached.
    func updateUserData(itemId: String, userId: String, positionTicks: Int64, played: Bool, lastPlayed: Date) async throws {
        struct Body: Encodable {
            let PlaybackPositionTicks: Int64
            let Played: Bool
            let LastPlayedDate: String
        }
        let body = Body(PlaybackPositionTicks: positionTicks, Played: played, LastPlayedDate: JellyfinDate.format(lastPlayed))
        try await send("UserItems/\(itemId)/UserData", method: "POST", query: ["userId": userId], body: body)
    }

    // MARK: Playback

    /// Asks the server how it would deliver a version under `profile`; used for transcoding.
    func playbackInfo(itemId: String, userId: String, request: PlaybackInfoRequest) async throws -> PlaybackInfoResponse {
        try await post("Items/\(itemId)/PlaybackInfo", query: ["userId": userId], body: request)
    }

    func reportPlaybackStart(_ report: PlaybackReport) async throws {
        try await send("Sessions/Playing", method: "POST", body: report)
    }

    func reportPlaybackProgress(_ report: PlaybackReport) async throws {
        try await send("Sessions/Playing/Progress", method: "POST", body: report)
    }

    func reportPlaybackStopped(_ report: PlaybackReport) async throws {
        try await send("Sessions/Playing/Stopped", method: "POST", body: report)
    }

    /// Ends the server's transcode for a play session.
    func stopTranscoding(playSessionId: String) async throws {
        try await send("Videos/ActiveEncodings", method: "DELETE", query: ["deviceId": deviceId, "playSessionId": playSessionId])
    }

    // MARK: URLs

    enum ImageKind: String, Sendable {
        case primary = "Primary", backdrop = "Backdrop", logo = "Logo", thumb = "Thumb"
    }

    func imageURL(itemId: String, kind: ImageKind = .primary, tag: String?, maxWidth: Int) -> URL {
        var query = ["maxWidth": String(maxWidth), "quality": "90"]
        if let tag { query["tag"] = tag }
        return url(for: "Items/\(itemId)/Images/\(kind.rawValue)", query: query)
    }

    /// The source's original bytes, untouched. Jellyfin serves a local file with byte ranges
    /// itself and passes a remote stream's (Gelato's) Range header through to the upstream.
    /// `/Items/{id}/Download` is not used: Gelato replaces it with a response that ignores Range.
    func streamURL(itemId: String, mediaSourceId: String) -> URL {
        var query = ["static": "true", "mediaSourceId": mediaSourceId]
        if let token { query["ApiKey"] = token }
        return url(for: "Videos/\(itemId)/stream", query: query)
    }

    /// A subtitle file that sits next to the media on the server, in its own format.
    func externalSubtitleURL(itemId: String, mediaSourceId: String, streamIndex: Int, format: String) -> URL {
        var query: [String: String] = [:]
        if let token { query["ApiKey"] = token }
        return url(for: "Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/Stream.\(format)", query: query)
    }

    /// A path the server handed out (a transcoding URL), made absolute.
    func absoluteURL(serverPath: String) -> URL? {
        if let url = URL(string: serverPath), url.scheme != nil { return url }
        let trimmed = serverPath.hasPrefix("/") ? String(serverPath.dropFirst()) : serverPath
        return URL(string: trimmed, relativeTo: serverURL.absoluteString.hasSuffix("/") ? serverURL : serverURL.appending(path: ""))?.absoluteURL
    }

    // MARK: Plumbing

    var authorizationHeader: String {
        var fields = [
            "Client": Self.clientName,
            "Device": deviceName,
            "DeviceId": deviceId,
            "Version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
        ]
        if let token { fields["Token"] = token }
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\"\(value.replacingOccurrences(of: "\"", with: ""))\""
        }
        return "MediaBrowser " + pairs.joined(separator: ", ")
    }

    private func url(for path: String, query: [String: String] = [:]) -> URL {
        var url = serverURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        }
        return url
    }

    private func request(for path: String, method: String = "GET", query: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(for: path, query: query))
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private func get<Response: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Response {
        try await decode(request(for: path, query: query))
    }

    private func post<Response: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Response {
        try await decode(request(for: path, method: "POST", query: query))
    }

    private func post<Response: Decodable>(_ path: String, query: [String: String] = [:], body: some Encodable) async throws -> Response {
        try await decode(request(for: path, method: "POST", query: query, body: body))
    }

    private func send(_ path: String, method: String, query: [String: String] = [:]) async throws {
        _ = try await data(for: request(for: path, method: method, query: query))
    }

    private func send(_ path: String, method: String, query: [String: String] = [:], body: some Encodable) async throws {
        _ = try await data(for: request(for: path, method: method, query: query, body: body))
    }

    private func request(for path: String, method: String, query: [String: String], body: some Encodable) throws -> URLRequest {
        var request = request(for: path, method: method, query: query)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func decode<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let body = try await data(for: request)
        return try JSONDecoder().decode(Response.self, from: body)
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body.prefix(300), encoding: .utf8) ?? ""
            throw JellyfinError.http(status: http.statusCode, body: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return body
    }
}

/// What the server is told about a playback, at start, while it runs and when it stops.
nonisolated struct PlaybackReport: Encodable, Sendable {
    let ItemId: String
    let MediaSourceId: String?
    let PlaySessionId: String
    let PlayMethod: String
    var PositionTicks: Int64
    var IsPaused: Bool
    var CanSeek = true
    var AudioStreamIndex: Int?
    var SubtitleStreamIndex: Int?
}

nonisolated struct PlaybackInfoRequest: Encodable, Sendable {
    let UserId: String
    let MediaSourceId: String
    let MaxStreamingBitrate: Int
    let StartTimeTicks: Int64
    let AudioStreamIndex: Int?
    let SubtitleStreamIndex: Int?
    let DeviceProfile: DeviceProfile
    var EnableDirectPlay = false
    var EnableDirectStream = false
    var EnableTranscoding = true
    var AllowVideoStreamCopy = true
    var AllowAudioStreamCopy = true
    var AutoOpenLiveStream = true
}

/// Jellyfin's description of what this device plays, sent only when asking for a transcode:
/// the engine direct-plays every container and codec, so the profile's job is to say what to
/// transcode into and how big the picture may be.
nonisolated struct DeviceProfile: Encodable, Sendable {
    struct TranscodingProfile: Encodable, Sendable {
        let Container: String
        let `Type`: String
        let VideoCodec: String
        let AudioCodec: String
        let `Protocol`: String
        let Context: String
        let MaxAudioChannels: String
        let MinSegments: Int
        let BreakOnNonKeyFrames: Bool
    }

    struct ProfileCondition: Encodable, Sendable {
        let Condition: String
        let Property: String
        let Value: String
        let IsRequired: Bool
    }

    struct CodecProfile: Encodable, Sendable {
        let `Type`: String
        let Conditions: [ProfileCondition]
    }

    struct SubtitleProfile: Encodable, Sendable {
        let Format: String
        let Method: String
    }

    var Name = "vinnyfin"
    let MaxStreamingBitrate: Int
    let MaxStaticBitrate: Int
    var DirectPlayProfiles: [String] = []
    let TranscodingProfiles: [TranscodingProfile]
    let CodecProfiles: [CodecProfile]
    let SubtitleProfiles: [SubtitleProfile]

    /// HLS in fragmented MP4: HEVC keeps HDR and saves bandwidth where the server can encode
    /// it, H.264 otherwise. Text subtitles become WebVTT renditions; picture-based and styled
    /// ones are burned in.
    static func transcoding(maxHeight: Int?, maxBitrate: Int) -> DeviceProfile {
        var conditions: [ProfileCondition] = []
        if let maxHeight {
            conditions.append(ProfileCondition(Condition: "LessThanEqual", Property: "Height", Value: String(maxHeight), IsRequired: true))
            conditions.append(ProfileCondition(Condition: "LessThanEqual", Property: "Width", Value: String(maxHeight * 16 / 9), IsRequired: true))
        }
        let burnedFormats = ["ass", "ssa", "pgssub", "pgs", "dvdsub", "dvbsub", "sub", "idx"]
        return DeviceProfile(
            MaxStreamingBitrate: maxBitrate,
            MaxStaticBitrate: maxBitrate,
            TranscodingProfiles: [
                TranscodingProfile(
                    Container: "mp4", Type: "Video", VideoCodec: "hevc,h264", AudioCodec: "aac,eac3,ac3,flac,alac",
                    Protocol: "hls", Context: "Streaming", MaxAudioChannels: "8", MinSegments: 1, BreakOnNonKeyFrames: true
                ),
            ],
            CodecProfiles: conditions.isEmpty ? [] : [CodecProfile(Type: "Video", Conditions: conditions)],
            SubtitleProfiles: [SubtitleProfile(Format: "vtt", Method: "Hls")]
                + burnedFormats.map { SubtitleProfile(Format: $0, Method: "Encode") }
        )
    }
}
