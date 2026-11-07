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
    /// through the form, typing into each field the keyboard opens for. The account comes first,
    /// then the server, unless the last sign-in picked it.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication, server: String, username: String) {
        let connect = app.buttons["welcome.connect"]
        if connect.waitForExistence(timeout: 5) {
            focus(connect, in: app)
            XCUIRemote.shared.press(.select)
        }
        let usernameField = app.textFields["login.username"]
        guard usernameField.waitForExistence(timeout: 5) else { return }
        enter(username, into: usernameField, in: app)
        let change = app.buttons["login.changeServer"]
        let changing = change.exists && !isAddress(change.value as? String, of: server)
        if changing {
            focus(change, in: app)
        } else {
            let submit = app.buttons["login.submit"]
            XCTAssertTrue(submit.wait(for: \.isEnabled, toEqual: true, timeout: uiTimeout), "Sign In never became enabled")
            focus(submit, in: app)
        }
        XCUIRemote.shared.press(.select)
        let host = app.textFields["login.host"]
        guard waitForServerStep(host, orSignInPast: usernameField) else { return }
        if changing {
            // The other server's port and path would stay, as an address without its own keeps them.
            enter("", into: app.textFields["login.port"], in: app)
            enter("", into: app.textFields["login.path"], in: app)
        }
        // A full address in the host field is split into protocol, host, port and path.
        enter(server, into: host, in: app)
        let signIn = app.buttons["login.connect"]
        focus(signIn, in: app)
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

    /// Signs in with the form as it starts, from the last sign-in or `signInArguments`: its server
    /// picked and its user filled in, so Sign In signs straight in. The build must be signed, even
    /// ad hoc, for the Keychain to take the sign-in.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication) {
        let connect = app.buttons["welcome.connect"]
        guard connect.waitForExistence(timeout: 5) else { return }
        connect.tap()
        XCTAssertTrue(app.textFields["login.username"].waitForExistence(timeout: uiTimeout), "The sign-in form never opened")
        XCTAssertTrue(app.buttons["login.changeServer"].exists, "The sign-in form didn't start from the last sign-in's server")
        tap(app.buttons["login.submit"])
    }
    #else
    /// Signs in to `server` as `username`, a user without a password: typing a password would
    /// raise the system's Save Password sheet. The account comes first, then the server, unless
    /// the last sign-in picked it.
    @MainActor
    func signInIfNeeded(_ app: XCUIApplication, server: String, username: String) {
        let connect = app.buttons["welcome.connect"]
        if connect.waitForExistence(timeout: 5) { connect.tap() }
        let usernameField = app.textFields["login.username"]
        guard usernameField.waitForExistence(timeout: 5) else { return }
        // The form starts from the last sign-in's user and server. Return walks the fields:
        // username, password, then signs in to the server picked, or asks for one.
        usernameField.tap()
        usernameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + username + "\n")
        let change = app.buttons["login.changeServer"]
        let changing = change.exists && !isAddress(change.value as? String, of: server)
        if changing {
            tap(change)
        } else {
            type("\n", into: app.secureTextFields["login.password"])
        }
        let host = app.textFields["login.host"]
        guard waitForServerStep(host, orSignInPast: usernameField) else { return }
        if changing {
            // The other server's port and path would stay, as an address without its own keeps them.
            for field in [app.textFields["login.path"], app.textFields["login.port"]] {
                field.tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
            }
        }
        // A full address in the host field is split into protocol, host, port and path, and Return
        // walks the fields: host, port, path, then signs in.
        host.tap()
        host.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + server + "\n")
        type("\n", into: app.textFields["login.port"])
        type("\n", into: app.textFields["login.path"])
    }

    /// Types once `field` has the keyboard focus that Return moved to it.
    @MainActor
    func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(waitForKeyboardFocus(field), "\(field) never took focus")
        field.typeText(text)
    }

    /// Whether `element` takes the keyboard focus in time.
    @MainActor
    func waitForKeyboardFocus(_ element: XCUIElement) -> Bool {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
        return XCTWaiter.wait(for: [focused], timeout: uiTimeout) == .completed
    }
    #endif

    /// Signs out in Settings: a sheet from Home on iPhone, iPad and Vision Pro, a window of its
    /// own on the Mac, and a tab of the sidebar on Apple TV.
    @MainActor
    func signOut(_ app: XCUIApplication) {
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign Out' AND identifier != 'settings.signOut'")).firstMatch
        #if os(tvOS)
        // Left into the sidebar, no further: a press left there closes it. Focus may still be on
        // its way there, as it is at launch.
        let sidebar = app.collectionViews["Sidebar"]
        let focusedRow = sidebar.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<12 where !focusedRow.waitForExistence(timeout: 1) { XCUIRemote.shared.press(.left) }
        focus(sidebar.buttons["Settings"], in: app)
        XCUIRemote.shared.press(.select)
        focus(app.buttons["settings.signOut"], in: app, moving: [.right, .down])
        XCUIRemote.shared.press(.select)
        // The dialog's buttons are side by side, Cancel first.
        focus(confirm, in: app, moving: [.right, .left])
        XCUIRemote.shared.press(.select)
        #elseif os(macOS)
        app.typeKey(",", modifierFlags: .command)
        tap(app.buttons["settings.signOut"])
        tap(confirm)
        app.typeKey("w", modifierFlags: .command)
        #else
        tap(app.buttons["home.settings"])
        tap(app.buttons["settings.signOut"])
        tap(confirm)
        #endif
    }

    #if !os(visionOS)
    /// Waits for the sign-in screen to ask for the server's address, or to sign in to the server
    /// it picked, which takes it and the account step away. Whether it asked.
    @MainActor
    private func waitForServerStep(_ host: XCUIElement, orSignInPast usernameField: XCUIElement) -> Bool {
        let deadline = Date.now.addingTimeInterval(uiTimeout)
        while !host.waitForExistence(timeout: 1), usernameField.exists, Date.now < deadline {}
        return host.exists
    }
    #endif

    /// Whether `address`, a server's as the sign-in screen gives it, is `server`'s.
    func isAddress(_ address: String?, of server: String) -> Bool {
        func normalized(_ text: String) -> String { text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return address.map(normalized) == normalized(server)
    }

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
