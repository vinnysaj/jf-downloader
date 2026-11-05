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

nonisolated extension Error {
    /// The task gave up, or its request was cancelled: nothing to tell anyone about.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// The Jellyfin API calls the app makes. Every call authenticates with the
/// `Authorization: MediaBrowser …` header; media URLs carry the token as `ApiKey`
/// instead, so a background transfer or the player needs nothing but the URL.
nonisolated struct JellyfinClient: Sendable {
    static let clientName = "vinnyfin"

    /// The app's name to the server, with the platform's, as Jellyfin's own apps give theirs:
    /// "vinnyfin tvOS". Other devices tell vinnyfin on Apple TV apart by it.
    static func clientName(for platform: Device.Platform) -> String {
        "\(clientName) \(platform.rawValue)"
    }

    let serverURL: URL
    let deviceId: String
    /// What the server's device list calls this device.
    let deviceName: String
    var token: String?

    /// Fields the browsing screens show, asked for on list calls.
    static let listFields = "PrimaryImageAspectRatio,SortName,Genres,Overview,ChildCount"
    /// No fields beyond those every item comes with, which are all a card shows: long lists
    /// leave out overviews, the bulk of a list's bytes.
    static let cardFields = ""
    /// Everything a detail screen shows.
    static let detailFields = "Overview,Genres,People,Taglines,MediaSources,MediaStreams,Chapters,SortName,ChildCount,PrimaryImageAspectRatio"

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

    struct ItemQuery: Sendable, Hashable {
        var types: [String] = ["Movie", "Series"]
        /// Only these items.
        var ids: [String] = []
        var parentId: String?
        var searchTerm: String?
        var sortBy = "SortName"
        var ascending = true
        var isPlayed: Bool?
        var isFavorite: Bool?
        var genres: [String] = []
        /// Only titles whose sort name comes before this. The server keeps sort names lowercased,
        /// without accents or a leading article, and compares them without regard to case.
        var nameLessThan: String?
        var fields = JellyfinClient.listFields
        var startIndex = 0
        var limit: Int?

        /// Movies, the newest added first.
        static let recentlyAddedMovies = newest(["Movie"], by: "DateCreated")
        /// Shows, the one with an episode added last first.
        static let recentlyAddedShows = newest(["Series"], by: "DateLastContentAdded")

        private static func newest(_ types: [String], by field: String) -> Self {
            var query = Self(types: types)
            query.sortBy = field
            query.ascending = false
            query.fields = JellyfinClient.cardFields
            return query
        }
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
        if !query.ids.isEmpty { parameters["ids"] = query.ids.joined(separator: ",") }
        if let parentId = query.parentId { parameters["parentId"] = parentId }
        if let term = query.searchTerm, !term.isEmpty { parameters["searchTerm"] = term }
        if let played = query.isPlayed { parameters["isPlayed"] = String(played) }
        if query.isFavorite == true { parameters["isFavorite"] = "true" }
        if !query.genres.isEmpty { parameters["genres"] = query.genres.joined(separator: "|") }
        if let nameLessThan = query.nameLessThan { parameters["nameLessThan"] = nameLessThan }
        return try await get("Items", query: parameters)
    }

    /// How many items match, without fetching any.
    func count(userId: String, _ query: ItemQuery) async throws -> Int {
        var query = query
        query.startIndex = 0
        query.limit = 0
        return try await items(userId: userId, query).totalRecordCount
    }

    /// Where a list of items comes from, a page at a time.
    enum ItemSource: Sendable, Hashable {
        /// The library, filtered and sorted.
        case items(ItemQuery)
        /// What's partway through.
        case resume
        /// The next episode of every show in progress.
        case nextUp
        /// The titles the server finds most like one, best first.
        case similar(toItemId: String)
    }

    func page(of source: ItemSource, userId: String, startIndex: Int, limit: Int) async throws -> ItemsPage {
        switch source {
        case .items(var query):
            query.startIndex = startIndex
            query.limit = limit
            return try await items(userId: userId, query)
        case .resume:
            return try await resumeItems(userId: userId, startIndex: startIndex, limit: limit)
        case .nextUp:
            return try await nextUp(userId: userId, startIndex: startIndex, limit: limit)
        case .similar(let itemId):
            // The server ranks similar titles without paging them, so the first page is the list.
            guard startIndex == 0 else { return ItemsPage(items: [], totalRecordCount: 0) }
            let items = try await similar(to: itemId, userId: userId, limit: limit)
            return ItemsPage(items: items, totalRecordCount: items.count)
        }
    }

    /// The item with its versions, its own first, and the position of the version played last.
    /// Behind Gelato this is also the call that makes the server look up the item's streams, so
    /// it can take a few seconds.
    func item(id: String, userId: String) async throws -> JellyfinItem {
        try await withOwnVersionFirst(get("Items/\(id)", query: ["userId": userId, "fields": Self.detailFields]), userId: userId)
    }

    /// What's partway through, each as the item library lists show, at the position reached last.
    func resumeItems(userId: String, startIndex: Int = 0, limit: Int = 20) async throws -> ItemsPage {
        try await listedItems(in: get("UserItems/Resume", query: [
            "userId": userId, "startIndex": String(startIndex), "limit": String(limit), "mediaTypes": "Video",
            "fields": Self.listFields + ",MediaSourceCount", "enableUserData": "true", "imageTypeLimit": "1",
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
        ]), userId: userId)
    }

    /// The next episode to watch of every show in progress, or of one show, each as the item
    /// library lists show, at the position reached last.
    func nextUp(userId: String, seriesId: String? = nil, startIndex: Int = 0, limit: Int = 20) async throws -> ItemsPage {
        var query = [
            "userId": userId, "startIndex": String(startIndex), "limit": String(limit),
            "fields": Self.listFields + ",MediaSourceCount", "enableUserData": "true", "imageTypeLimit": "1",
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo", "enableResumable": "true", "disableFirstEpisode": "false",
        ]
        if let seriesId { query["seriesId"] = seriesId }
        return try await listedItems(in: get("Shows/NextUp", query: query), userId: userId)
    }

    // MARK: Versions

    /// The item with its own version first and the position of the version played last, when
    /// the server lists another version ahead of the item's own (see `JellyfinItem.versionPlayedLast`).
    private func withOwnVersionFirst(_ item: JellyfinItem, userId: String) async throws -> JellyfinItem {
        guard let playedLast = item.versionPlayedLast else { return item }
        return item.withOwnVersionFirst(positionFrom: try await userData(itemId: playedLast.id, userId: userId))
    }

    /// The page with each item that has versions replaced by the item library lists show for it,
    /// at the position of its version played last. Resume names the version partway through, and
    /// Next Up can name the version of the next episode matching the one played, either of which
    /// can be an alternate version: an item of its own, whose page and playback are that version's.
    private func listedItems(in page: ItemsPage, userId: String) async throws -> ItemsPage {
        let versioned = page.items.filter { ($0.mediaSourceCount ?? 0) > 1 }
        guard !versioned.isEmpty else { return page }
        let types = Array(Set(versioned.map(\.type)))
        var listed = try await self.listed(ids: versioned.map(\.id), types: types, userId: userId)
        let alternates = versioned.filter { item in !listed.contains { $0.id == item.id } }
        if !alternates.isEmpty {
            // An alternate version lists every version of its item, the item's own among them.
            let versionIds = try await withThrowingTaskGroup(of: [String].self) { group in
                for alternate in alternates {
                    group.addTask {
                        let detail: JellyfinItem = try await get("Items/\(alternate.id)", query: ["userId": userId, "fields": "MediaSources"])
                        return detail.mediaSources?.map(\.id) ?? []
                    }
                }
                return try await group.reduce(into: Set<String>()) { $0.formUnion($1) }
            }
            let known = Set(listed.map(\.id))
            listed += try await self.listed(ids: versionIds.subtracting(known).sorted(), types: types, userId: userId)
        }
        let shown = try await withThrowingTaskGroup(of: JellyfinItem.self) { group in
            for item in listed {
                group.addTask { try await withOwnVersionFirst(item, userId: userId) }
            }
            return try await group.reduce(into: [JellyfinItem]()) { $0.append($1) }
        }
        return ItemsPage(items: page.items.map { $0.listedItem(among: shown) ?? $0 }, totalRecordCount: page.totalRecordCount)
    }

    /// Those of `ids` that library lists show, with their versions.
    private func listed(ids: [String], types: [String], userId: String) async throws -> [JellyfinItem] {
        guard !ids.isEmpty else { return [] }
        var query = ItemQuery(types: types)
        query.ids = ids
        query.fields = Self.listFields + ",MediaSources"
        return try await items(userId: userId, query).items
    }

    func similar(to itemId: String, userId: String, limit: Int = 16) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("Items/\(itemId)/Similar", query: [
            "userId": userId, "limit": String(limit), "fields": Self.listFields,
        ])
        return page.items
    }

    /// The genres of items of `types`, by name; with counts, each says how many movies and
    /// shows have it.
    func genres(userId: String, types: [String], withCounts: Bool = false) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("Genres", query: [
            "userId": userId, "includeItemTypes": types.joined(separator: ","), "sortBy": "SortName",
            "fields": withCounts ? "ItemCounts" : "", "enableImages": "false",
        ])
        return page.items
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

    /// The episode before `episodeId` in the show's order, if there is one.
    func episode(before episodeId: String, seriesId: String, userId: String) async throws -> JellyfinItem? {
        let page: ItemsPage = try await get("Shows/\(seriesId)/Episodes", query: [
            "userId": userId, "adjacentTo": episodeId, "enableUserData": "true", "fields": Self.listFields,
        ])
        guard let index = page.items.firstIndex(where: { $0.id == episodeId }), index > 0 else { return nil }
        return page.items[index - 1]
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

    /// Writes what `update` gives of an item's user data. It goes through none of the rules a
    /// playback report does, such as clearing a position in the first few percent.
    func updateUserData(itemId: String, userId: String, _ update: UserDataUpdate) async throws {
        try await send("UserItems/\(itemId)/UserData", method: "POST", query: ["userId": userId], body: update)
    }

    func userData(itemId: String, userId: String) async throws -> UserItemData {
        try await get("UserItems/\(itemId)/UserData", query: ["userId": userId])
    }

    /// Gives an item the position the server keeps for its version `versionId`, which was just
    /// reported (see `UserDataUpdate.init(positionOf:)`).
    func givePosition(ofVersion versionId: String, toItem itemId: String, userId: String) async throws {
        let version = try await userData(itemId: versionId, userId: userId)
        try await updateUserData(itemId: itemId, userId: userId, UserDataUpdate(positionOf: version))
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

    // MARK: Remote control

    /// Says what this session plays and obeys. With the socket open, other devices can then
    /// play here and control what plays.
    func reportCapabilities(_ capabilities: ClientCapabilities) async throws {
        try await send("Sessions/Capabilities/Full", method: "POST", body: capabilities)
    }

    /// The sessions the user can play to and control: those whose apps hold a socket open.
    func controllableSessions(userId: String) async throws -> [RemoteSession] {
        try await get("Sessions", query: ["controllableByUserId": userId])
    }

    /// Asks a session to play an item now, from `start` seconds, in a version and with streams
    /// when given; -1 for the subtitles turns them off.
    func play(itemId: String, onSession sessionId: String, start: Double, mediaSourceId: String?,
              audioStreamIndex: Int?, subtitleStreamIndex: Int?) async throws {
        var query = ["playCommand": "PlayNow", "itemIds": itemId, "startPositionTicks": String(Int64(max(0, start) * 10_000_000))]
        if let mediaSourceId { query["mediaSourceId"] = mediaSourceId }
        if let audioStreamIndex { query["audioStreamIndex"] = String(audioStreamIndex) }
        if let subtitleStreamIndex { query["subtitleStreamIndex"] = String(subtitleStreamIndex) }
        try await send("Sessions/\(sessionId)/Playing", method: "POST", query: query)
    }

    func send(_ command: PlaystateCommand, toSession sessionId: String, seekTo seconds: Double? = nil) async throws {
        var query: [String: String] = [:]
        if let seconds { query["seekPositionTicks"] = String(Int64(max(0, seconds) * 10_000_000)) }
        try await send("Sessions/\(sessionId)/Playing/\(command.rawValue)", method: "POST", query: query)
    }

    func send(_ command: GeneralCommand, toSession sessionId: String) async throws {
        try await send("Sessions/\(sessionId)/Command", method: "POST", body: command)
    }

    /// The server's socket, signed in as this client, over which it sends commands and updates.
    var socketRequest: URLRequest {
        var url = serverURL.appending(path: "socket")
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = serverURL.scheme?.lowercased() == "https" ? "wss" : "ws"
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
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
            "Client": Self.clientName(for: .current),
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

    private func get<Response: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> Response {
        try await decode(request(for: path, query: query))
    }

    private func post<Response: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> Response {
        try await decode(request(for: path, method: "POST", query: query))
    }

    private func post<Response: Decodable & Sendable>(_ path: String, query: [String: String] = [:], body: some Encodable) async throws -> Response {
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

    /// Off the caller's actor: decoding a page of a big library on the main actor stalls scrolling.
    @concurrent
    private func decode<Response: Decodable & Sendable>(_ request: URLRequest) async throws -> Response {
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

/// A change to an item's user data. The server writes what's given and leaves the rest as it is.
nonisolated struct UserDataUpdate: Encodable, Sendable {
    let PlaybackPositionTicks: Int64
    var Played: Bool?
    var LastPlayedDate: String?

    init(positionTicks: Int64, played: Bool?, lastPlayed: Date?) {
        PlaybackPositionTicks = positionTicks
        Played = played
        LastPlayedDate = lastPlayed.map(JellyfinDate.format)
    }

    /// An item's share of what the server keeps for one of its versions, just reported: that
    /// version's position, and a play just after the version's, so the server takes the item for
    /// the version played last. Every list and every other client then shows the item's own
    /// position, and the server lists the item's own version first and names the item itself in
    /// Resume and Next Up. The watched state isn't given: finishing a version already marks every
    /// version watched and clears their positions, and the item then gets no position.
    init(positionOf version: UserItemData) {
        // A second on, as the date is given to the second and the version's has a fraction.
        self.init(positionTicks: version.playbackPositionTicks ?? 0, played: nil,
                  lastPlayed: version.lastPlayedDate.flatMap(JellyfinDate.parse)?.addingTimeInterval(1))
    }
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
                    Protocol: "hls", Context: "Streaming", MaxAudioChannels: "8", MinSegments: 1
                ),
            ],
            CodecProfiles: conditions.isEmpty ? [] : [CodecProfile(Type: "Video", Conditions: conditions)],
            SubtitleProfiles: [SubtitleProfile(Format: "vtt", Method: "Hls")]
                + burnedFormats.map { SubtitleProfile(Format: $0, Method: "Encode") }
        )
    }
}
