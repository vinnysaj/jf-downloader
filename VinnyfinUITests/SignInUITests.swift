import XCTest

/// Signs in as someone would, the account first and the server second, against the local test
/// server `VinnyfinUITests` describes: a user "viewer" without a password.
final class SignInUITests: XCTestCase {
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

    /// Signs in from wherever the app starts, then signs out and in to the test server, changing
    /// the server the sign-in screen picks when the last sign-in was to another. Signed out again,
    /// the screen starts from that sign-in, its user and its server picked, which sign straight in.
    @MainActor
    func testSignsInAgainFromTheLastSignIn() async throws {
        try await requireServer()
        let app = XCUIApplication()
        #if os(visionOS)
        app.launchArguments = try signInArguments(server: server, username: "viewer")
        #endif
        app.launch()
        signIn(app)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in never finished")
        signOut(app)
        signIn(app)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in after signing out never finished")

        signOut(app)
        #if !os(tvOS)
        tap(app.buttons["welcome.connect"])
        #endif
        let picked = app.buttons["login.changeServer"]
        XCTAssertTrue(picked.waitForExistence(timeout: uiTimeout), "The sign-in screen didn't pick the server signed in to last")
        XCTAssertTrue(isAddress(picked.value as? String, of: server), "The sign-in screen picked \(String(describing: picked.value))")
        XCTAssertEqual(app.textFields["login.username"].value as? String, "viewer")
        #if !os(tvOS)
        // Closed, for the sign-in to open it as it does from the start.
        tap(app.buttons["Cancel"])
        XCTAssertTrue(picked.waitForNonExistence(timeout: uiTimeout), "Cancel didn't close the sign-in screen")
        #endif
        signIn(app)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in again never finished")
    }

    #if os(iOS) || os(macOS)
    /// A server that doesn't answer keeps the server step, with its error and the cursor in the
    /// host; Back goes to the account step with the server picked before, which signs in.
    @MainActor
    func testAServerThatDoesntAnswerKeepsTheServerStep() async throws {
        try await requireServer()
        let app = XCUIApplication()
        app.launch()
        signIn(app)
        signOut(app)
        tap(app.buttons["welcome.connect"])

        let picked = app.buttons["login.changeServer"]
        tap(picked)
        // Change puts the cursor in the host. Nothing listens on port 9.
        let host = app.textFields["login.host"]
        type(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "127.0.0.1:9\n", into: host)
        type("\n", into: app.textFields["login.port"])
        type("\n", into: app.textFields["login.path"])
        XCTAssertTrue(app.descendants(matching: .any)["login.error"].waitForExistence(timeout: uiTimeout),
                      "The server step never said the server doesn't answer")
        XCTAssertTrue(app.buttons["login.connect"].exists, "The sign-in left the server step")
        XCTAssertTrue(waitForKeyboardFocus(host), "The cursor didn't go back to the host")
        XCTAssertEqual(host.value as? String, "127.0.0.1")
        XCTAssertEqual(app.textFields["login.port"].value as? String, "9")
        keep("Server step with its error", in: app)

        tap(app.buttons["login.back"])
        XCTAssertTrue(picked.waitForExistence(timeout: uiTimeout), "Back didn't go to the account step")
        XCTAssertTrue(isAddress(picked.value as? String, of: server), "Back picked \(String(describing: picked.value))")
        XCTAssertFalse(app.descendants(matching: .any)["login.error"].exists, "The server step's error stayed")
        // Return on the password signs in to the server picked.
        let password = app.secureTextFields["login.password"]
        password.tap()
        type("\n", into: password)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Signing in from the account step never finished")
    }

    @MainActor
    private func keep(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    #if !os(tvOS)
    /// Quick Connect from the account step goes straight to the code of the server picked, and
    /// signs in once someone signed in approves it.
    @MainActor
    func testQuickConnectSignsInOnceTheCodeIsApproved() async throws {
        try await requireServer()
        let app = XCUIApplication()
        #if os(visionOS)
        app.launchArguments = try signInArguments(server: server, username: "viewer")
        #endif
        app.launch()
        signIn(app)
        signOut(app)
        tap(app.buttons["welcome.connect"])
        XCTAssertTrue(app.buttons["login.changeServer"].waitForExistence(timeout: uiTimeout),
                      "The sign-in screen didn't pick the server signed in to last")

        tap(app.buttons["login.quickConnect"])
        let code = app.staticTexts["login.quickConnectCode"]
        XCTAssertTrue(code.waitForExistence(timeout: uiTimeout), "No Quick Connect code came up")
        try await approve(code.label)
        XCTAssertTrue(tabs(app).waitForExistence(timeout: uiTimeout), "Approving the code didn't sign in")
    }

    private struct Authentication: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "AccessToken" }
    }

    /// Approves a Quick Connect code as "viewer", as Jellyfin on a device signed in would.
    private func approve(_ code: String) async throws {
        let client = #"MediaBrowser Client="vinnyfin UI tests", Device="Test runner", DeviceId="vinnyfin-ui-tests", Version="1""#
        var signIn = URLRequest(url: try XCTUnwrap(URL(string: server + "/Users/AuthenticateByName")))
        signIn.httpMethod = "POST"
        signIn.setValue(client, forHTTPHeaderField: "Authorization")
        signIn.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signIn.httpBody = try JSONEncoder().encode(["Username": "viewer", "Pw": ""])
        let token = try JSONDecoder().decode(Authentication.self, from: try await URLSession.shared.data(for: signIn).0).accessToken
        var approval = URLRequest(url: try XCTUnwrap(URL(string: server + "/QuickConnect/Authorize?code=" + code)))
        approval.httpMethod = "POST"
        approval.setValue(client + #", Token="\#(token)""#, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: approval)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "The server didn't approve the code")
    }
    #endif

    @MainActor
    private func signIn(_ app: XCUIApplication) {
        #if os(visionOS)
        signInIfNeeded(app)
        #else
        signInIfNeeded(app, server: server, username: "viewer")
        #endif
    }

    /// The Movies tab, which is there once signed in.
    @MainActor
    private func tabs(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Movies'")).firstMatch
    }
}
