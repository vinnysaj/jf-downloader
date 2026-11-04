import XCTest

/// How long a UI test waits on the app or the server before failing.
let uiTimeout: TimeInterval = 30

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

    /// Moves focus down, or up past the end, until `element` has it.
    @MainActor
    func focus(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: uiTimeout), "\(element) never appeared", file: file, line: line)
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<12 {
                if element.hasFocus { return }
                XCUIRemote.shared.press(direction)
            }
        }
        XCTAssertTrue(element.hasFocus, "\(element) never took focus", file: file, line: line)
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
        // A full address in the host field is split into protocol, host, port and path, and
        // Return walks the fields: host, port, path, username, password, then signs in.
        host.typeText(server + "\n")
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
