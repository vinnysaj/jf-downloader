import XCTest

/// Takes the App Store screenshots against the showcase server `AppStore/screenshots.sh` runs,
/// one test per device and pose; the script picks the test, sets up the simulator (status bar,
/// fold) and turns the attachments into the store's images. Skipped without that server.
///
/// Each test starts from the same viewing history: a film and an episode partway through,
/// a few episodes watched, two favorites.
final class ScreenshotTests: XCTestCase {
    private static let username = "Alex"
    private var server = ""

    override func setUp() async throws {
        continueAfterFailure = false
        let address = ProcessInfo.processInfo.environment["VINNYFIN_SCREENSHOT_SERVER"]
        try XCTSkipUnless(address != nil, "Screenshots run from AppStore/screenshots.sh")
        server = address ?? ""
        try await ShowcaseHistory(server: server, username: Self.username).reset()
    }

    // MARK: Devices

    #if os(iOS)
    @MainActor
    func testIPhone() async throws {
        let app = launch()
        try await snapHome(app)
        try await startDownloads(app)
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snap("03-movie", once: app.buttons["detail.play"])
        tap(tab("Search", in: app))
        let field = app.searchFields.firstMatch
        tap(field)
        field.typeText("the\n")
        try await snap("05-search", once: app.buttons["poster.The Quiet Meridian"])
        try await snapDownloads(app, name: "04-downloads")
    }

    @MainActor
    func testIPad() async throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        try await snapHome(app)
        try await startDownloads(app)
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        try await snap("03-movies", once: app.buttons["poster.The Quiet Meridian"])
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snapPlayer(app, name: "04-player")
        try await snapDownloads(app, name: "05-downloads")
    }

    /// Closed: the outer display.
    @MainActor
    func testDuoOuter() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        try await snapHome(app)
        try await snapShow(app, name: "02-show")
    }

    /// Open flat, held like a book: the inner display, wider than tall.
    @MainActor
    func testDuoInner() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        try await snapHome(app)
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snapPlayer(app, name: "03-player")
    }

    /// Half open like a laptop: the picture above the fold, the episodes below.
    @MainActor
    func testDuoLaptop() async throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        tap(tab("Shows", in: app))
        tap(app.buttons["poster.Port Ellery"])
        tap(app.buttons["episode.3"])
        XCTAssertTrue(app.buttons["episodes.episode.3"].waitForExistence(timeout: uiTimeout), "The player didn't split at the fold")
        tap(app.buttons["player.playPause"])
        try await snap("01-player")
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testTV() async throws {
        let app = launch()
        try await snapHome(app)
        // The hero's film is partway through: its button resumes it.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["player.timeline"].waitForExistence(timeout: uiTimeout), "The player never opened")
        try await Task.sleep(for: .seconds(3))
        XCUIRemote.shared.press(.playPause)
        try await snap("04-player")
        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.menu)
        selectTab("Shows", in: app)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        try await snap("02-show", once: app.descendants(matching: .any)["series.play"])
        XCUIRemote.shared.press(.menu)
        selectTab("Movies", in: app)
        XCUIRemote.shared.press(.down)
        try await snap("03-movies", once: app.buttons["poster.Amber Cartographers"])
        selectTab("Search", in: app)
        XCUIRemote.shared.press(.down)
        app.typeText("the")
        try await snap("05-search", once: app.buttons["poster.The Quiet Meridian"])
    }

    /// Moves focus up to the tab bar and along it to `name`, which shows that tab.
    @MainActor
    private func selectTab(_ name: String, in app: XCUIApplication) {
        let tab = app.buttons[name].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: uiTimeout))
        for _ in 0..<6 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        for direction in [XCUIRemote.Button.right, .left] {
            for _ in 0..<6 where !tab.hasFocus { XCUIRemote.shared.press(direction) }
        }
        XCTAssertTrue(tab.hasFocus, "The \(name) tab never took focus")
    }
    #endif

    #if os(macOS)
    @MainActor
    func testMac() async throws {
        let app = launch()
        try await snapHome(app)
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snapPlayer(app, name: "03-player")
    }
    #endif

    // MARK: Screens

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        #if os(macOS)
        // A window of the default size, not wherever an earlier run left it.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        signInIfNeeded(app, server: server, username: Self.username)
        return app
    }

    @MainActor
    private func snapHome(_ app: XCUIApplication) async throws {
        try await snap("01-home", once: app.descendants(matching: .any)["home.hero"])
    }

    #if !os(tvOS)
    @MainActor
    private func snapShow(_ app: XCUIApplication, name: String) async throws {
        tap(tab("Shows", in: app))
        tap(app.buttons["poster.Port Ellery"])
        try await snap(name, once: app.buttons["episode.3"])
    }

    /// Plays the title whose page is open from where it was left, and pauses with the controls up.
    @MainActor
    private func snapPlayer(_ app: XCUIApplication, name: String) async throws {
        tap(app.buttons["detail.play"])
        let pause = app.buttons["player.playPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: uiTimeout), "The player never opened")
        // Playing, the controls hide after a few seconds; once they have, a tap on the picture
        // brings them back for a few more. Paused, they stay up.
        if pause.waitForNonExistence(timeout: 10) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        }
        tap(pause)
        try await snap(name)
        tap(app.buttons["player.close"])
    }

    /// A tab: a button in the tab bar, or a row in iPad's sidebar. Not just any button by that
    /// name, which can be the back button to the tab's first screen.
    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let places = [app.tabBars.buttons[name], app.cells[name]]
        let deadline = Date.now.addingTimeInterval(uiTimeout)
        while Date.now < deadline {
            if let tab = places.first(where: \.exists) { return tab }
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
        return places[0]
    }
    #endif

    #if os(iOS)
    /// A film and a smart download for a show, so the Downloads tab has something in it by the end.
    @MainActor
    private func startDownloads(_ app: XCUIApplication) async throws {
        tap(tab("Movies", in: app))
        tap(app.buttons["poster.Saltwater Hymns"])
        tap(app.buttons["detail.download"])
        tap(tab("Shows", in: app))
        tap(app.buttons["poster.Starfall Station"])
        tap(app.descendants(matching: .any)["series.smartDownload"].firstMatch)
        tap(app.buttons["Next 3 Episodes"])
        // Back to each tab's first screen.
        for name in ["Movies", "Shows"] {
            tap(tab(name, in: app))
            tap(tab(name, in: app))
        }
    }

    @MainActor
    private func snapDownloads(_ app: XCUIApplication, name: String) async throws {
        tap(tab("Downloads", in: app))
        let downloaded = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'downloaded.'"))
        let four = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 4"), object: downloaded)
        XCTAssertEqual(XCTWaiter.wait(for: [four], timeout: 120), .completed, "The downloads didn't finish")
        try await snap(name)
    }
    #endif

    /// Attaches a screenshot named `name`, once `landmark` is on screen and artwork has had a
    /// moment to load. The Mac's is the app's window; elsewhere, the whole screen.
    @MainActor
    private func snap(_ name: String, once landmark: XCUIElement? = nil) async throws {
        if let landmark {
            XCTAssertTrue(landmark.waitForExistence(timeout: uiTimeout), "\(landmark) never appeared for \(name)")
        }
        try await Task.sleep(for: .seconds(2.5))
        #if os(macOS)
        let screenshot = XCUIApplication().windows.firstMatch.screenshot()
        #else
        let screenshot = XCUIScreen.main.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: screenshot, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The showcase user's viewing history, set through the server's API.
private struct ShowcaseHistory {
    let server: String
    let username: String

    private struct Item: Decodable {
        let id: String
        let name: String
        let type: String
        let seriesName: String?
        let parentIndexNumber: Int?
        let indexNumber: Int?
        let runTimeTicks: Int64?

        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", type = "Type", seriesName = "SeriesName"
            case parentIndexNumber = "ParentIndexNumber", indexNumber = "IndexNumber", runTimeTicks = "RunTimeTicks"
        }
    }

    private struct Page: Decodable {
        let items: [Item]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    private struct Authentication: Decodable {
        struct User: Decodable {
            let id: String
            enum CodingKeys: String, CodingKey { case id = "Id" }
        }

        let user: User
        let accessToken: String
        enum CodingKeys: String, CodingKey { case user = "User", accessToken = "AccessToken" }
    }

    /// Partway through, as a fraction of the runtime.
    private static let inProgress: [String: Double] = ["The Quiet Meridian": 0.46, "Port Ellery S1E3": 0.35]
    private static let watched: Set<String> = ["Port Ellery S1E1", "Port Ellery S1E2", "Starfall Station S1E1",
                                               "Small Mountain Kitchens S1E1", "Small Mountain Kitchens S1E2"]
    private static let favorites: Set<String> = ["Port Ellery", "Neon Tidewater"]

    func reset() async throws {
        let decoder = JSONDecoder()
        let signIn = try decoder.decode(Authentication.self, from: try await send(
            "POST", "/Users/AuthenticateByName", body: ["Username": username, "Pw": ""]))
        let user = signIn.user.id
        let token = signIn.accessToken
        let items = try decoder.decode(Page.self, from: try await send(
            "GET", "/Items?userId=\(user)&recursive=true&includeItemTypes=Movie,Series,Episode&fields=RunTimeTicks", token: token)).items
        XCTAssertFalse(items.isEmpty, "The showcase library is empty")
        for item in items {
            let key = item.type == "Episode"
                ? "\(item.seriesName ?? "") S\(item.parentIndexNumber ?? 0)E\(item.indexNumber ?? 0)"
                : item.name
            // A show's watched state follows its episodes'.
            var data: [String: Any] = ["IsFavorite": Self.favorites.contains(key)]
            if item.type != "Series" {
                data["Played"] = Self.watched.contains(key)
                data["PlaybackPositionTicks"] = 0
                if let fraction = Self.inProgress[key], let ticks = item.runTimeTicks {
                    data["PlaybackPositionTicks"] = Int64(Double(ticks) * fraction)
                    data["LastPlayedDate"] = ISO8601DateFormatter().string(from: .now)
                }
            }
            _ = try await send("POST", "/UserItems/\(item.id)/UserData?userId=\(user)", token: token,
                               body: try JSONSerialization.data(withJSONObject: data))
        }
    }

    private func send(_ method: String, _ path: String, token: String? = nil, body: [String: String]) async throws -> Data {
        try await send(method, path, token: token, body: try JSONEncoder().encode(body))
    }

    private func send(_ method: String, _ path: String, token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
        request.httpMethod = method
        var authorization = #"MediaBrowser Client="vinnyfin screenshots", Device="Test runner", DeviceId="vinnyfin-screenshots", Version="1""#
        if let token { authorization += #", Token="\#(token)""# }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) answered \(status)"])
        }
        return data
    }
}
