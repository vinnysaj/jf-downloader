import XCTest

/// How long a UI test waits on the app or the server before failing.
let uiTimeout: TimeInterval = 30

#if os(visionOS)
/// Asks for a screenshot named `name` and waits for it. On visionOS a UI test's own
/// screenshots come back empty, so `simctl io screenshot` on the Mac takes it: the test
/// leaves `<name>.request` in `VINNYFIN_SHOTS` and a watcher there answers with `<name>.png`.
/// Without the folder there's nothing to take it, and the step goes on.
func requestScreenshot(_ name: String) async throws {
    guard let folder = ProcessInfo.processInfo.environment["VINNYFIN_SHOTS"] else { return }
    try await Task.sleep(for: .seconds(1))
    let request = URL(filePath: folder).appending(path: name + ".request")
    try Data().write(to: request)
    let deadline = Date.now.addingTimeInterval(15)
    while FileManager.default.fileExists(atPath: request.path), Date.now < deadline {
        try await Task.sleep(for: .seconds(0.3))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: request.path), "No screenshot was taken for \(name)")
}
#endif

extension XCTestCase {
    #if os(tvOS)
    /// Signs in to `server` as `username`, a user without a password, with the remote: down
    /// through the form, typing into each field the keyboard opens for.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication, server: String, username: String) {
        let connect = app.buttons["welcome.connect"]
        if connect.waitForExistence(timeout: 5) {
            focus(connect, in: app)
            XCUIRemote.shared.press(.select)
        }
        let host = app.textFields["login.host"]
        guard host.waitForExistence(timeout: 5) else { return }
        // A full address in the host field is split into protocol, host, port and path.
        enter(server, into: host, in: app)
        enter(username, into: app.textFields["login.username"], in: app)
        let submit = app.buttons["login.submit"]
        XCTAssertTrue(submit.wait(for: \.isEnabled, toEqual: true, timeout: uiTimeout), "Sign In never became enabled")
        focus(submit, in: app)
        XCUIRemote.shared.press(.select)
    }

    /// Moves focus each way in turn, down and then back up past the end unless told otherwise,
    /// until `element` has it: a button in a form or the sidebar takes it as its row, a cell.
    @MainActor
    func focus(_ element: XCUIElement, in app: XCUIApplication, moving directions: [XCUIRemote.Button] = [.down, .up],
               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: uiTimeout), "\(element) never appeared", file: file, line: line)
        // Its row is found by its identifier, so an element without one has to take focus itself.
        let identifier = element.identifier
        let row = app.cells.containing(NSPredicate(format: "identifier == %@", identifier)).firstMatch
        let isFocused = { element.hasFocus || !identifier.isEmpty && row.exists && row.hasFocus }
        for direction in directions {
            for _ in 0..<12 {
                if isFocused() { return }
                XCUIRemote.shared.press(direction)
            }
        }
        XCTAssertTrue(isFocused(), "\(element) never took focus", file: file, line: line)
    }

    /// Opens the keyboard for `field`, replaces what's in it with `text`, and goes back to the form.
    @MainActor
    private func enter(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        focus(field, in: app)
        XCUIRemote.shared.press(.select)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: uiTimeout), "The keyboard never opened for \(field)")
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + text)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: uiTimeout), "The keyboard never closed")
    }
    #elseif os(visionOS)
    /// Launch arguments that fill in the sign-in form with `server` and `username`, a user without
    /// a password. Text typed by a UI test doesn't reach visionOS's text fields, so the form starts
    /// from the defaults the last sign-in left, which arguments set: the server as an archived
    /// URL, given as property list data.
    func signInArguments(server: String, username: String) throws -> [String] {
        let url = try XCTUnwrap(NSURL(string: server), "\(server) isn't an address")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: url, requiringSecureCoding: true)
        return ["-lastServer", "<\(archived.map { String(format: "%02x", $0) }.joined())>", "-lastUserName", username]
    }

    /// Signs in with the form as it starts, from the last sign-in or `signInArguments`. The build
    /// must be signed, even ad hoc, for the Keychain to take the sign-in.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication) {
        let connect = app.buttons["welcome.connect"]
        guard connect.waitForExistence(timeout: 5) else { return }
        connect.tap()
        XCTAssertTrue(app.textFields["login.host"].waitForExistence(timeout: uiTimeout), "The sign-in form never opened")
        // Below the servers signed in to on other devices the form's list makes the button only
        // once it scrolls into view. The form is a window of its own, which the swipe has to name.
        let submit = app.buttons["login.submit"]
        for _ in 0..<4 where !submit.exists { app.collectionViews.firstMatch.swipeUp() }
        tap(submit)
    }
    #else
    /// Signs in to `server` as `username`, a user without a password: typing a password would
    /// raise the system's Save Password sheet.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication, server: String, username: String) {
        let connect = app.buttons["welcome.connect"]
        if connect.waitForExistence(timeout: 5) { connect.tap() }
        let host = app.textFields["login.host"]
        guard host.waitForExistence(timeout: 5) else { return }
        host.tap()
        // The form starts from the last server signed in to. A full address in the host field
        // is split into protocol, host, port and path, and Return walks the fields: host, port,
        // path, username, password, then signs in.
        host.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + server + "\n")
        type("\n", into: app.textFields["login.port"])
        type("\n", into: app.textFields["login.path"])
        type(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + username + "\n", into: app.textFields["login.username"])
        type("\n", into: app.secureTextFields["login.password"])
    }

    /// Types once `field` has the keyboard focus that Return moved to it.
    @MainActor
    func type(_ text: String, into field: XCUIElement) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: focused, object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: uiTimeout), .completed, "\(field) never took focus")
        field.typeText(text)
    }
    #endif

    #if !os(tvOS)
    /// Taps once the element is there and enabled; buttons wait on loading, and a tap before
    /// then does nothing.
    @MainActor
    func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: uiTimeout), "\(element) never appeared", file: file, line: line)
        XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: uiTimeout), "\(element) never became enabled", file: file, line: line)
        element.tap()
    }
    #endif
}
