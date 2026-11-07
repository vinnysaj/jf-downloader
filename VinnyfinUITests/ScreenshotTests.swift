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
        let app = try launch()
        try await snapHome(app)
        try await startDownloads(app)
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snap("03-movie", once: app.buttons["detail.play"])
        try await snapRemote(app)
        tap(tab("Search", in: app))
        let field = app.searchFields.firstMatch
        tap(field)
        field.typeText("the\n")
        try await snap("05-search", once: app.buttons["poster.The Quiet Meridian"])
        try await snapDownloads(app, name: "04-downloads")
    }

    /// Plays the title whose page is open on the living room's Apple TV, and shows the remote.
    @MainActor
    private func snapRemote(_ app: XCUIApplication) async throws {
        let livingRoom = LivingRoomTV(server: server, username: Self.username)
        try await livingRoom.open()
        tap(app.buttons["playElsewhere"])
        // By name: any other device signed in to the server, such as a simulator still running
        // an earlier test's app, is a target too.
        tap(app.buttons.matching(identifier: "playOn.target").matching(NSPredicate(format: "label BEGINSWITH %@", "Living Room")).firstMatch)
        let playing = app.descendants(matching: .any)["remote.playing"]
        XCTAssertTrue(playing.waitForExistence(timeout: uiTimeout), "The remote never showed the living room playing")
        try await snap("06-remote", once: app.descendants(matching: .any)["remote.title"])
        tap(app.buttons["remote.stop"])
        try await livingRoom.close()
    }

    @MainActor
    func testIPad() async throws {
        useFullScreenApps()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launch()
        try await snapHome(app)
        try await startDownloads(app)
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        try await snap("03-movies", once: app.buttons["poster.The Quiet Meridian"])
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snapPlayer(app, name: "04-player")
        try await snapDownloads(app, name: "05-downloads")
    }

    /// Full Screen Apps, as the App Store shows an iPad app: a window has a resize handle in its
    /// corner, and its app's name in the status bar.
    @MainActor
    private func useFullScreenApps() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        tap(settings.descendants(matching: .any)["Multitasking & Gestures"].firstMatch)
        let fullScreen = settings.buttons["com.apple.settings.multitaskingAndGestures.fullScreenApps"]
        tap(fullScreen)
        XCTAssertTrue(fullScreen.wait(for: \.isSelected, toEqual: true, timeout: uiTimeout), "Full Screen Apps never took")
        settings.terminate()
    }

    /// Closed: the outer display. Its shots and the inner display's share a slot, numbered to
    /// take turns, closed first.
    @MainActor
    func testDuoOuter() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launch()
        try await snapHome(app)
        try await startDownloads(app)
        // The season snapDownloads starts is Port Ellery's, from its page.
        tap(tab("Shows", in: app))
        tap(app.buttons["poster.Port Ellery"])
        try await snapDownloads(app, name: "03-downloads")
    }

    /// Open flat, held like a book: the inner display, wider than tall.
    @MainActor
    func testDuoInner() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launch()
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snapPlayer(app, name: "04-player")
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testTV() async throws {
        let app = try launch()
        // From the sidebar, where focus starts, to the hero's button for its film, partway through.
        focus(app.descendants(matching: .any)["home.hero"].buttons["Resume"], in: app, moving: [.right, .up, .left])
        try await snapHome(app)
        XCUIRemote.shared.press(.select)
        let timeline = app.descendants(matching: .any)["player.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: uiTimeout), "The player never opened")
        // Until the picture is up, a spinner over it reads Loading.
        XCTAssertTrue(app.activityIndicators["Loading"].waitForNonExistence(timeout: uiTimeout), "The picture never came up")
        XCUIRemote.shared.press(.playPause)
        for _ in 0..<3 where !timeline.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(timeline.hasFocus, "The timeline never took focus")
        // Back into the chapter before, whose picture the scrub preview shows over the paused one.
        for _ in 0..<12 { XCUIRemote.shared.press(.left) }
        try await snap("04-player")
        // Menu backs out of the scrub, then out of the player.
        for _ in 0..<3 where timeline.exists {
            XCUIRemote.shared.press(.menu)
            _ = timeline.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(timeline.exists, "The player never closed")
        selectTab("Shows", in: app)
        focus(app.buttons["poster.Port Ellery"], in: app, moving: [.right, .left])
        XCUIRemote.shared.press(.select)
        try await snap("02-show", once: app.descendants(matching: .any)["series.play"])
        XCUIRemote.shared.press(.menu)
        selectTab("Movies", in: app)
        try await snap("03-movies", once: app.buttons["poster.Amber Cartographers"])
        selectTab("Search", in: app)
        app.typeText("the")
        try await snap("05-search", once: app.buttons["poster.The Quiet Meridian"])
    }

    /// Moves focus left into the sidebar, no further: a press left there closes it. Then along it
    /// to `name`, and shows that tab.
    @MainActor
    private func selectTab(_ name: String, in app: XCUIApplication) {
        let sidebar = app.collectionViews["Sidebar"]
        let focusedRow = sidebar.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<12 where !focusedRow.exists { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(focusedRow.exists, "Focus never reached the sidebar")
        focus(sidebar.buttons[name], in: app)
        XCUIRemote.shared.press(.select)
    }
    #endif

    #if os(macOS)
    @MainActor
    func testMac() async throws {
        let app = try launch()
        try await snapHome(app)
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snapPlayer(app, name: "03-player")
    }
    #endif

    #if os(visionOS)
    @MainActor
    func testVision() async throws {
        let app = try launch()
        try await snapHome(app)
        try await snapShow(app, name: "02-show")
        tap(tab("Movies", in: app))
        tap(app.buttons["poster.The Quiet Meridian"])
        try await snapPlayer(app, name: "03-player")
    }
    #endif

    // MARK: Screens

    @MainActor
    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication()
        #if os(macOS)
        // A window of the default size, not wherever an earlier run left it.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        #if os(visionOS)
        app.launchArguments += try signInArguments(server: server, username: Self.username)
        app.launch()
        signInIfNeeded(app)
        #else
        app.launch()
        signInIfNeeded(app, server: server, username: Self.username)
        #endif
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
        try await snap(name, once: app.buttons["episode.1"])
    }

    /// Plays the title whose page is open from where it was left, and pauses with the controls up
    /// and the chapters open.
    @MainActor
    private func snapPlayer(_ app: XCUIApplication, name: String) async throws {
        tap(app.buttons["detail.play"])
        waitForPicture(app)
        let pause = app.buttons["player.playPause"]
        // Playing, the controls hide after a few seconds; once they have, a tap on the picture
        // brings them back for a few more. Paused, they stay up.
        if pause.waitForNonExistence(timeout: 10) { tap(app.buttons["player.picture"]) }
        tap(pause)
        tap(app.buttons["player.chapters"])
        try await snap(name, once: app.buttons["panel.chapter.0"])
        tap(app.buttons["player.close"])
    }

    /// Waits for the player's picture: until it's up, the play button is a spinner that reads Play.
    @MainActor
    private func waitForPicture(_ app: XCUIApplication) {
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: uiTimeout), "The player never opened")
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "Pause", timeout: uiTimeout), "The picture never came up")
    }

    /// A tab: a button in the tab bar, a row in iPad's sidebar, or a button in the bar down the
    /// side of iPhone Duo's outer display, which isn't a tab bar to XCUITest. A tab reads its
    /// badge's count after its name. Not the back button to the tab's first screen, which can
    /// have the same name.
    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let named = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ", ")
        let places = [app.tabBars.buttons.matching(named).firstMatch, app.cells.matching(named).firstMatch,
                      app.buttons.matching(named).matching(NSPredicate(format: "identifier != 'BackButton'")).firstMatch]
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
    /// They download as they are.
    @MainActor
    private func startDownloads(_ app: XCUIApplication) async throws {
        chooseDownloads("1080p", transcoded: false, in: app)
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

    /// `element`, once the list it's in has scrolled up to it: a list makes its rows as they come
    /// into view.
    @MainActor
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<8 where !element.exists { app.swipeUp() }
        return element
    }

    /// Chooses the download quality and whether the server may make a download at it, in Settings
    /// from Home. Both follow the person through iCloud, so a fresh install can start from what an
    /// earlier run chose.
    @MainActor
    private func chooseDownloads(_ quality: String, transcoded: Bool, keepingThemRunning: Bool = false, in app: XCUIApplication) {
        tap(tab("Home", in: app))
        tap(app.buttons["home.settings"])
        tap(scrolledTo(app.buttons["settings.downloadQuality"], in: app))
        tap(app.buttons[quality])
        turn(scrolledTo(app.switches["settings.transcodeDownloads"], in: app), on: transcoded)
        if keepingThemRunning { turn(scrolledTo(app.switches["settings.keepDownloadsRunning"], in: app), on: true) }
        // On iPhone Duo's outer display the bar scrolls away with the form, and back as it scrolls up.
        let done = app.navigationBars.buttons["Done"]
        for _ in 0..<8 where !done.exists { app.swipeDown() }
        tap(done)
    }

    /// Turns `toggle` on or off, a row whose switch at the end takes the tap.
    @MainActor
    private func turn(_ toggle: XCUIElement, on: Bool) {
        let value = on ? "1" : "0"
        XCTAssertTrue(toggle.waitForExistence(timeout: uiTimeout), "\(toggle) never appeared")
        if toggle.value as? String != value { tap(toggle.switches.firstMatch) }
        let turned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: uiTimeout), .completed, "\(toggle) never turned \(on ? "on" : "off")")
    }

    /// The Downloads tab once those downloads are done, and a season is on its way at a quality
    /// the server makes for it, with Keep Downloads Running on.
    @MainActor
    private func snapDownloads(_ app: XCUIApplication, name: String) async throws {
        tap(tab("Downloads", in: app))
        // Done when no row is left at the top in progress. Finished rows can't be counted: a list
        // makes its rows only as they come into view, and on iPhone Duo's outer display they don't
        // all fit.
        let unfinished = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'job.'")).firstMatch
        let downloaded = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'downloaded.'")).firstMatch
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !unfinished.exists && downloaded.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 120), .completed, "The downloads didn't finish")
        chooseDownloads("720p", transcoded: true, keepingThemRunning: true, in: app)
        // Port Ellery's page, still open from its screenshot.
        tap(tab("Shows", in: app))
        tap(app.descendants(matching: .any)["series.smartDownload"].firstMatch)
        tap(app.buttons["Download Season 1"])
        tap(app.buttons["batch.download"])
        tap(tab("Downloads", in: app))
        XCTAssertTrue(unfinished.waitForExistence(timeout: uiTimeout), "The season never started downloading")
        try await snap(name, once: app.descendants(matching: .any)["keepAwake.status"])
    }
    #endif

    /// Attaches a screenshot named `name`, once `landmark` is on screen and artwork has had a
    /// moment to load. The Mac's is the app's window; elsewhere, the whole screen, which on
    /// Vision Pro the script takes when asked.
    @MainActor
    private func snap(_ name: String, once landmark: XCUIElement? = nil) async throws {
        if let landmark {
            XCTAssertTrue(landmark.waitForExistence(timeout: uiTimeout), "\(landmark) never appeared for \(name)")
        }
        try await Task.sleep(for: .seconds(2.5))
        #if os(visionOS)
        try await requestScreenshot(name)
        #else
        #if os(macOS)
        let screenshot = XCUIApplication().windows.firstMatch.screenshot()
        #else
        // The screen the app's window fills, which on iPhone Duo open is the inner display, not
        // the main one. The largest window: the player adds one of no size ahead of it.
        let window = XCUIApplication().windows.allElementsBoundByIndex.map(\.frame.size)
            .max { $0.width * $0.height < $1.width * $1.height } ?? .zero
        let screenshot = try XCTUnwrap(XCUIScreen.screens.lazy.map { $0.screenshot() }.first { shot in
            abs(shot.image.size.width - window.width) < 1 && abs(shot.image.size.height - window.height) < 1
        }, "No screen is the size of the app's window, \(window)")
        #endif
        let attachment = XCTAttachment(screenshot: screenshot, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }
}

/// The showcase user's viewing history, set through the server's API.
private struct ShowcaseHistory {
    let server: String
    let username: String

    private var api: ShowcaseAPI {
        ShowcaseAPI(server: server, client: #"Client="vinnyfin screenshots", Device="Test runner", DeviceId="vinnyfin-screenshots""#)
    }

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

    /// Partway through, as a fraction of the runtime.
    private static let inProgress: [String: Double] = ["The Quiet Meridian": 0.46, "Port Ellery S1E3": 0.35]
    private static let watched: Set<String> = ["Port Ellery S1E1", "Port Ellery S1E2", "Starfall Station S1E1",
                                               "Small Mountain Kitchens S1E1", "Small Mountain Kitchens S1E2"]
    private static let favorites: Set<String> = ["Port Ellery", "Neon Tidewater"]

    func reset() async throws {
        let (user, token) = try await api.signIn(username)
        let items = try JSONDecoder().decode(Page.self, from: try await api.send(
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
            try await api.send("POST", "/UserItems/\(item.id)/UserData?userId=\(user)", token: token, body: try ShowcaseAPI.json(data))
        }
    }
}

/// The showcase server's API, called as the client and device `client` names.
private struct ShowcaseAPI: Sendable {
    let server: String
    /// The Authorization header's client, device and device id.
    let client: String

    private struct Authentication: Decodable {
        struct User: Decodable {
            let id: String
            enum CodingKeys: String, CodingKey { case id = "Id" }
        }

        let user: User
        let accessToken: String
        enum CodingKeys: String, CodingKey { case user = "User", accessToken = "AccessToken" }
    }

    /// Signs in as `username`, a user without a password.
    func signIn(_ username: String) async throws -> (userId: String, token: String) {
        let signIn = try JSONDecoder().decode(Authentication.self, from: try await send(
            "POST", "/Users/AuthenticateByName", body: try Self.json(["Username": username, "Pw": ""])))
        return (signIn.user.id, signIn.accessToken)
    }

    /// Sends `body`, JSON, and returns what the server answers.
    @discardableResult
    func send(_ method: String, _ path: String, token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
        request.httpMethod = method
        request.setValue(authorization(token: token), forHTTPHeaderField: "Authorization")
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

    /// The server's socket, signed in with `token`.
    func socketRequest(token: String) throws -> URLRequest {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server.replacingOccurrences(of: "http", with: "ws", options: .anchored) + "/socket")))
        request.setValue(authorization(token: token), forHTTPHeaderField: "Authorization")
        return request
    }

    private func authorization(token: String?) -> String {
        #"MediaBrowser \#(client), Version="1""# + (token.map { #", Token="\#($0)""# } ?? "")
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

#if os(iOS)
/// vinnyfin on the living room's Apple TV, as the server sees it, for the remote's screenshot.
/// It holds the server's socket open, which lists it among the devices to play on, and plays
/// what it's sent by telling the server it plays it, as the app there would.
private actor LivingRoomTV {
    private static let deviceId = "vinnyfin-screenshots-living-room"
    private let username: String
    private let api: ShowcaseAPI
    private var token = ""
    private var socket: URLSessionWebSocketTask?
    private var listening: Task<Void, Never>?
    private var keepingAlive: Task<Void, Never>?
    /// What it plays, and from where, as the server's playback reports put it.
    private var playing: [String: Any]?
    private var isClosing = false
    /// What went wrong while it was open.
    private var failure: (any Error)?

    init(server: String, username: String) {
        self.username = username
        api = ShowcaseAPI(server: server, client: #"Client="vinnyfin tvOS", Device="Living Room", DeviceId="\#(Self.deviceId)""#)
    }

    func open() async throws {
        token = try await api.signIn(username).token
        try await api.send("POST", "/Sessions/Capabilities/Full", token: token, body: try ShowcaseAPI.json([
            "PlayableMediaTypes": ["Video"], "SupportedCommands": [String](), "SupportsMediaControl": true,
        ]))
        let socket = URLSession.shared.webSocketTask(with: try api.socketRequest(token: token))
        socket.resume()
        self.socket = socket
        listening = Task { await listen(to: socket) }
        try await waitUntilListed()
    }

    private struct Session: Decodable {
        let supportsRemoteControl: Bool
        enum CodingKeys: String, CodingKey { case supportsRemoteControl = "SupportsRemoteControl" }
    }

    /// Waits for the server to take the socket, after which it lists the TV as a device to play on.
    private func waitUntilListed() async throws {
        let deadline = Date.now.addingTimeInterval(uiTimeout)
        while Date.now < deadline {
            let sessions = try JSONDecoder().decode([Session].self, from: try await api.send(
                "GET", "/Sessions?deviceId=\(Self.deviceId)", token: token))
            if sessions.contains(where: \.supportsRemoteControl) { return }
            if let failure { throw failure }
            try await Task.sleep(for: .seconds(0.5))
        }
        throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "The server never listed the living room as a device to play on"])
    }

    /// Stops what it plays and closes the socket, and throws what went wrong while it was open.
    func close() async throws {
        isClosing = true
        keepingAlive?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        await listening?.value
        if let playing { try await report("Stopped", playing) }
        playing = nil
        if let failure { throw failure }
    }

    private func listen(to socket: URLSessionWebSocketTask) async {
        do {
            while true {
                guard case .string(let text) = try await socket.receive(),
                      let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                try await handle(message, from: socket)
            }
        } catch {
            if !isClosing { failure = error }
        }
    }

    private func handle(_ message: [String: Any], from socket: URLSessionWebSocketTask) async throws {
        switch message["MessageType"] as? String {
        case "ForceKeepAlive":
            // Word at least this often, in seconds, or the server closes the socket.
            let seconds = message["Data"] as? Double ?? 60
            keepingAlive?.cancel()
            keepingAlive = Task {
                do {
                    while true {
                        try await socket.send(.string(#"{"MessageType":"KeepAlive"}"#))
                        try await Task.sleep(for: .seconds(seconds / 2))
                    }
                } catch {
                    if !isClosing, !(error is CancellationError) { failure = error }
                }
            }
        case "Play":
            let data = message["Data"] as? [String: Any] ?? [:]
            guard let itemId = (data["ItemIds"] as? [String])?.first else { return }
            var started: [String: Any] = ["ItemId": itemId, "PositionTicks": data["StartPositionTicks"] ?? 0,
                                          "IsPaused": false, "CanSeek": true, "PlayMethod": "DirectPlay"]
            started["MediaSourceId"] = data["MediaSourceId"]
            playing = started
            try await report(nil, started)
        case "Playstate":
            let data = message["Data"] as? [String: Any] ?? [:]
            guard var progress = playing else { return }
            switch data["Command"] as? String {
            case "Pause": progress["IsPaused"] = true
            case "Unpause": progress["IsPaused"] = false
            case "Seek": progress["PositionTicks"] = data["SeekPositionTicks"] ?? progress["PositionTicks"]
            case "Stop":
                playing = nil
                try await report("Stopped", progress)
                return
            default: return
            }
            playing = progress
            try await report("Progress", progress)
        default:
            return
        }
    }

    /// Tells the server a playback started (`event` nil), went on or stopped.
    private func report(_ event: String?, _ playback: [String: Any]) async throws {
        try await api.send("POST", "/Sessions/Playing" + (event.map { "/\($0)" } ?? ""), token: token, body: try ShowcaseAPI.json(playback))
    }
}
#endif
