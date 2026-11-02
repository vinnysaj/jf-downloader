import Foundation

nonisolated enum JellyfinError: LocalizedError {
    /// The message says what's wrong with the address.
    case invalidServerAddress(String)
    case notJellyfin(URL)
    case http(status: Int, body: String)
    case invalidCredentials

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
        }
    }
}

/// The few Jellyfin API calls the app makes. Every call authenticates with the
/// `Authorization: MediaBrowser …` header; download URLs carry the token as `ApiKey`
/// instead, so a background transfer needs nothing but its URL.
nonisolated struct JellyfinClient: Sendable {
    static let clientName = "JF Downloader"

    let serverURL: URL
    let deviceId: String
    /// What the server's device list calls this device.
    let deviceName: String
    var token: String?

    // MARK: Calls

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
        var request = request(for: "Users/AuthenticateByName")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(Username: username, Pw: password))
        do {
            return try await send(request)
        } catch JellyfinError.http(let status, _) where status == 401 {
            throw JellyfinError.invalidCredentials
        }
    }

    func signOut() async throws {
        var request = request(for: "Sessions/Logout")
        request.httpMethod = "POST"
        _ = try await data(for: request)
    }

    func libraries(userId: String) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("UserViews", query: ["userId": userId])
        return page.items.filter { Self.videoCollectionTypes.contains($0.collectionType ?? "") }
    }

    /// Collection types that hold movies or episodes. "" stands for a view without one (mixed content).
    static let videoCollectionTypes: Set<String> = ["movies", "tvshows", "homevideos", "musicvideos", "mixed", ""]

    func items(userId: String, parentId: String?, searchTerm: String?, startIndex: Int, limit: Int) async throws -> ItemsPage {
        var query = [
            "userId": userId,
            "recursive": "true",
            "includeItemTypes": "Movie,Series,Video",
            "sortBy": "SortName",
            "sortOrder": "Ascending",
            "imageTypeLimit": "1",
            "enableImageTypes": "Primary",
            "enableUserData": "false",
            "startIndex": String(startIndex),
            "limit": String(limit),
        ]
        if let parentId { query["parentId"] = parentId }
        if let searchTerm, !searchTerm.isEmpty { query["searchTerm"] = searchTerm }
        return try await get("Items", query: query)
    }

    /// The item with its media sources. Behind Gelato this is also the call that makes the
    /// server look up the item's streams, so it can take a few seconds.
    func item(id: String, userId: String) async throws -> JellyfinItem {
        try await get("Items/\(id)", query: ["userId": userId])
    }

    func seasons(seriesId: String, userId: String) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get("Shows/\(seriesId)/Seasons", query: ["userId": userId])
        return page.items
    }

    func episodes(seriesId: String, seasonId: String, userId: String) async throws -> [JellyfinItem] {
        let page: ItemsPage = try await get(
            "Shows/\(seriesId)/Episodes",
            query: ["userId": userId, "seasonId": seasonId, "fields": "Overview", "enableUserData": "false"]
        )
        return page.items
    }

    // MARK: URLs

    func imageURL(itemId: String, tag: String?, maxWidth: Int) -> URL {
        var query = ["maxWidth": String(maxWidth), "quality": "85"]
        if let tag { query["tag"] = tag }
        return url(for: "Items/\(itemId)/Images/Primary", query: query)
    }

    /// The source's original bytes, untouched. Jellyfin serves a local file with byte ranges
    /// itself and passes a remote stream's (Gelato's) Range header through to the upstream.
    /// `/Items/{id}/Download` is not used: Gelato replaces it with a response that ignores Range.
    func streamURL(itemId: String, mediaSourceId: String) -> URL {
        var query = ["static": "true", "mediaSourceId": mediaSourceId]
        if let token { query["ApiKey"] = token }
        return url(for: "Videos/\(itemId)/stream", query: query)
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

    private func request(for path: String, query: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(for: path, query: query))
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return request
    }

    private func get<Response: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Response {
        try await send(request(for: path, query: query))
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
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
