#if os(iOS)
import XCTest

/// Drives the Go and Playback menus' keys from the iPad's hardware keyboard,
/// and signs in again from the server the sign-in screen remembers. Expects the
/// local test server `VinnyfinUITests` describes, and an iPad simulator.
final class ContinuityUITests: XCTestCase {
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
    private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testKeyboardGoesThroughTabsAndDrivesThePlayer() async throws {
        try await requireServer()
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "viewer")
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: timeout), "Home never appeared")

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["index.B"].waitForExistence(timeout: timeout), "⌘2 didn't open Movies")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: timeout), "⌘1 didn't open Home")

        app.typeKey("f", modifierFlags: .command)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "⌘F didn't open Search")
        // Typed to whatever has the cursor, so it reaches the field only if ⌘F put the cursor
        // there. Away from the player, space is for typing.
        app.typeText("Big Test")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Big Test'"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: timeout), .completed,
                       "⌘F didn't put the cursor in the search field: it has \(String(describing: field.value))")
        XCTAssertTrue(app.buttons["poster.Big Test Movie"].waitForExistence(timeout: timeout), "Search found nothing")
        keep("Search from ⌘F")

        app.typeKey("2", modifierFlags: .command)
        // The test library's longest movie, at 30 seconds: room to skip both ways while paused.
        tap(app.buttons["index.S"])
        tap(app.buttons["poster.Subtitle Test"])
        // From the start, wherever an earlier run left off.
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: timeout), "The movie's page never opened")
        let startOver = app.buttons["Start Over"]
        tap(startOver.waitForExistence(timeout: 5) ? startOver : app.buttons["detail.play"])

        let timeline = app.descendants(matching: .any)["player.timeline"].firstMatch
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(timeline.waitForExistence(timeout: timeout), "The player never opened")
        // The controls are up as the player opens, and fade a few seconds into playback.
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "Pause", timeout: timeout), "Playback never started")

        // Space pauses; the controls come up to show it, and stay while paused.
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "Play", timeout: timeout), "Space didn't pause")
        let paused = try XCTUnwrap(Self.seconds(timeline.value as? String))

        // The left arrow skips ten seconds back, the right one ahead again.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        let back = NSPredicate { element, _ in
            (Self.seconds((element as? XCUIElement)?.value as? String) ?? .infinity) <= max(0, paused - 9)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: back, object: timeline)], timeout: timeout),
                       .completed, "← didn't skip back from \(paused) s")
        let behind = try XCTUnwrap(Self.seconds(timeline.value as? String))
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let ahead = NSPredicate { element, _ in
            (Self.seconds((element as? XCUIElement)?.value as? String) ?? 0) >= behind + 9
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ahead, object: timeline)], timeout: timeout),
                       .completed, "→ didn't skip ahead from \(behind) s")
        keep("Player after the keys")

        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "Pause", timeout: timeout), "Space didn't play again")

        // Escape closes the player.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: timeout), "Escape didn't close the player")
    }

    @MainActor
    func testSignInScreenOffersTheServerSignedInToBefore() async throws {
        try await requireServer()
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app, server: server, username: "viewer")
        tap(app.buttons["home.settings"])
        tap(app.buttons["settings.signOut"])
        tap(app.buttons.matching(NSPredicate(format: "label == 'Sign Out' AND identifier != 'settings.signOut'")).firstMatch)

        tap(app.buttons["welcome.connect"])
        let known = app.buttons["login.knownServer"].firstMatch
        XCTAssertTrue(known.waitForExistence(timeout: timeout), "The sign-in screen doesn't offer the server")
        XCTAssertTrue(known.label.hasSuffix("as viewer"), "Offered \(known.label)")
        keep("Sign-in offering the server")

        // Clear the form, so the tap is what fills it in.
        let host = app.textFields["login.host"]
        host.tap()
        host.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        known.tap()
        XCTAssertTrue(waitForKeyboardFocus(app.secureTextFields["login.password"]), "The password wasn't next")
        XCTAssertEqual(app.textFields["login.username"].value as? String, "viewer")
        XCTAssertEqual(host.value as? String, URL(string: server)?.host())
        keep("Sign-in filled in from the server")

        // Return on the password signs in; the Sign In button is below the keyboard.
        app.typeText("\n")
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: timeout), "Signing in again didn't open Home")
    }

    @MainActor
    private func waitForKeyboardFocus(_ element: XCUIElement) -> Bool {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
        return XCTWaiter.wait(for: [focused], timeout: timeout) == .completed
    }

    /// "1:05 of 10:00" as 65.
    private static func seconds(_ value: String?) -> Double? {
        guard let first = value?.components(separatedBy: " of ").first else { return nil }
        let parts = first.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
#endif
