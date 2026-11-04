#if !os(tvOS)
import XCTest

/// Drives the app against the local test server: signs in, browses with the A–Z index, plays a
/// chosen version until the clock moves, and turns on smart downloads for a show.
///
/// Expects the server and library `testserver/` sets up: a user "viewer" without a password,
/// "Big Test Movie" in 2160p, 1080p and 720p versions, and a two-season "Test Show". The
/// address comes from `VINNYFIN_TEST_SERVER` (pass `TEST_RUNNER_VINNYFIN_TEST_SERVER` to
/// xcodebuild) and defaults to http://localhost:8096.
final class VinnyfinUITests: XCTestCase {
    private let timeout = uiTimeout

    override func setUp() {
        continueAfterFailure = false
    }

    private var server: String {
        ProcessInfo.processInfo.environment["VINNYFIN_TEST_SERVER"] ?? "http://localhost:8096"
    }

    private func requireServer() async throws {
        let info = try XCTUnwrap(URL(string: server + "/System/Info/Public"))
        let answered = (try? await URLSession.shared.data(from: info)) != nil
        try XCTSkipUnless(answered, "No Jellyfin test server answers at \(server)")
    }

    @MainActor
    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "viewer")
        return app
    }

    // MARK: Server state

    private struct Authentication: Decodable {
        struct User: Decodable {
            let id: String
            enum CodingKeys: String, CodingKey { case id = "Id" }
        }

        let user: User
        let accessToken: String
        enum CodingKeys: String, CodingKey { case user = "User", accessToken = "AccessToken" }
    }

    private struct Items: Decodable {
        struct Item: Decodable {
            let id: String
            let name: String
            enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
        }

        let items: [Item]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    private func send(_ method: String, _ path: String, token: String? = nil, body: [String: String]? = nil) async throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
        request.httpMethod = method
        var authorization = #"MediaBrowser Client="vinnyfin UI tests", Device="Test runner", DeviceId="vinnyfin-ui-tests", Version="1""#
        if let token { authorization += #", Token="\#(token)""# }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) answered \(status)"])
        }
        return data
    }

    /// Marks every episode of a show unwatched for the test user, so a test starts from the
    /// library as set up rather than from wherever earlier viewing left it.
    private func markEveryEpisodeUnwatched(of show: String) async throws {
        let decoder = JSONDecoder()
        let signIn = try decoder.decode(Authentication.self, from: try await send("POST", "/Users/AuthenticateByName",
                                                                                 body: ["Username": "viewer", "Pw": ""]))
        let user = signIn.user.id
        let token = signIn.accessToken
        let term = try XCTUnwrap(show.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let series = try decoder.decode(Items.self, from: try await send(
            "GET", "/Items?userId=\(user)&includeItemTypes=Series&recursive=true&searchTerm=\(term)", token: token))
        let seriesId = try XCTUnwrap(series.items.first { $0.name == show }?.id, "No show named \(show)")
        let episodes = try decoder.decode(Items.self, from: try await send("GET", "/Shows/\(seriesId)/Episodes?userId=\(user)", token: token))
        for episode in episodes.items {
            _ = try await send("DELETE", "/UserPlayedItems/\(episode.id)?userId=\(user)", token: token)
        }
    }

    @MainActor
    func testBrowseAndPlayAVersion() async throws {
        try await requireServer()
        let app = launchSignedIn()
        tap(app.buttons["Movies"].firstMatch)

        // The index jumps past everything before B.
        tap(app.buttons["index.B"])
        tap(app.buttons["poster.Big Test Movie"])

        tap(app.buttons["version.1080p"])
        XCTAssertTrue(app.buttons["version.1080p"].wait(for: \.isSelected, toEqual: true, timeout: timeout))
        tap(app.buttons["detail.play"])

        // The controls fade while playing; a tap on the picture brings them back.
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: timeout), "The player never opened")
        let picture = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let timeline = app.descendants(matching: .any)["player.timeline"].firstMatch
        let deadline = Date.now.addingTimeInterval(timeout)
        var position = ""
        while Date.now < deadline {
            if !timeline.exists { picture.tap() }
            if timeline.waitForExistence(timeout: 2), let value = timeline.value as? String {
                position = value
                if !value.hasPrefix("0:00 ") { break }
            }
        }
        XCTAssertFalse(position.isEmpty || position.hasPrefix("0:00 "), "Playback never got past 0:00 (\(position))")
        // The controls may fade between looking and tapping; bring them back until Close takes.
        let close = app.buttons["player.close"]
        for _ in 0..<5 where app.buttons["player.close"].exists || !app.buttons["detail.play"].exists {
            if !close.exists { picture.tap() }
            if close.waitForExistence(timeout: 2), close.isHittable { close.tap() }
            if app.buttons["detail.play"].waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: timeout))
    }

    @MainActor
    func testSmartDownloadsKeepAShowAhead() async throws {
        try await requireServer()
        // Three episodes ahead needs three unwatched ones.
        try await markEveryEpisodeUnwatched(of: "Test Show")
        let app = launchSignedIn()
        tap(app.buttons["Shows"].firstMatch)
        tap(app.buttons["poster.Test Show"])
        tap(app.descendants(matching: .any)["series.smartDownload"].firstMatch)
        tap(app.buttons["Next 3 Episodes"])

        tap(app.buttons["Downloads"].firstMatch)
        XCTAssertTrue(app.staticTexts["Next 3 episodes"].waitForExistence(timeout: timeout), "The smart download isn't listed")
        let downloaded = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'downloaded.'"))
        let three = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 3"), object: downloaded)
        XCTAssertEqual(XCTWaiter.wait(for: [three], timeout: 60), .completed, "Smart downloads didn't fetch three episodes")
    }
}
#endif
