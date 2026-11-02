import XCTest

/// Signs in to a test server and queues downloads through the UI: both versions of a movie,
/// a movie whose source is a remote stream, and a whole season through multi-select.
///
/// Expects the server and library `testserver/` sets up: a user "viewer" without a password,
/// a "Big Test Movie (2024)" with 1080p and 720p versions, a "Remote Stream Movie (2023)" .strm,
/// and a five-episode "Test Show". The server address comes from `JFD_TEST_SERVER` (pass `TEST_RUNNER_JFD_TEST_SERVER` to xcodebuild).
final class QueueDownloadsUITests: XCTestCase {
    private let timeout: TimeInterval = 30

    override func setUp() {
        continueAfterFailure = false
    }

    private var server: String {
        ProcessInfo.processInfo.environment["JFD_TEST_SERVER"] ?? "http://localhost:8097"
    }

    @MainActor
    func testQueueMoviesAndASeason() async throws {
        let info = try XCTUnwrap(URL(string: server + "/System/Info/Public"))
        let answered = (try? await URLSession.shared.data(from: info)) != nil
        try XCTSkipUnless(answered, "No Jellyfin test server answers at \(server)")

        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app)

        open(app, "item.Big Test Movie (2024)")
        for version in ["version.1080p", "version.720p"] {
            // The picker puts the identifier on a button inside each row, with a suffix.
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", version)).firstMatch
            tap(row)
            XCTAssertTrue(row.wait(for: \.isSelected, toEqual: true, timeout: timeout), "\(version) wasn't selected")
            tap(app.buttons["versions.download"])
        }

        open(app, "item.Remote Stream Movie (2023)")
        tap(app.buttons["versions.download"])

        showList(app)
        tap(app.buttons["library.picker"])
        tap(app.buttons["Shows"])
        open(app, "item.Test Show")
        tap(app.buttons["series.select"])
        tap(app.buttons["series.selectAll"])
        tap(app.buttons["series.download"])
        let queue = app.buttons["batch.download"]
        XCTAssertTrue(queue.wait(for: \.label, toEqual: "Download 5", timeout: timeout))
        tap(queue)

        tap(app.buttons["Downloads"].firstMatch)
        let jobRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'job.'"))
        XCTAssertTrue(jobRows.firstMatch.waitForExistence(timeout: timeout))
    }

    @MainActor
    private func signInIfNeeded(_ app: XCUIApplication) {
        let host = app.textFields["login.host"]
        guard host.waitForExistence(timeout: 5) else { return }
        host.tap()
        // A full address in the host field is split into protocol, host, port and path, and
        // Return walks the fields: host, port, path, username, password, then signs in.
        host.typeText(server + "\n")
        let port = app.textFields["login.port"]
        XCTAssertEqual(port.value as? String, "8097")
        type("\n", into: port)
        type("\n", into: app.textFields["login.path"])
        // A user without a password: typing one would raise the system's Save Password sheet.
        type("viewer\n", into: app.textFields["login.username"])
        type("\n", into: app.secureTextFields["login.password"])
    }

    /// Types once `field` has the keyboard focus that Return moved to it.
    @MainActor
    private func type(_ text: String, into field: XCUIElement) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: focused, object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "\(field) never took focus")
        field.typeText(text)
    }

    /// Opens a title from the list, going back to the list first when the device is folded
    /// and the list is behind the detail.
    @MainActor
    private func open(_ app: XCUIApplication, _ identifier: String) {
        let row = app.buttons[identifier]
        if !(row.exists && row.isHittable) { showList(app) }
        tap(row)
    }

    /// Goes back from a title to the list, when folded and the title covers it.
    @MainActor
    private func showList(_ app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        if back.exists, back.isHittable { back.tap() }
    }

    /// Taps once the element is there and enabled; buttons wait on loading, like Select on the
    /// episodes, and a tap before then does nothing.
    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) never appeared", file: file, line: line)
        XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: timeout), "\(element) never became enabled", file: file, line: line)
        element.tap()
    }
}
