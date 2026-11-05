#if os(visionOS)
import XCTest

/// Plays on Apple Vision Pro from the server, a download and a file on the device, and works the
/// player: the timeline, audio and subtitle choices, skipping the intro, the next episode and the
/// up-next card, the cinema, 3D titles and closing. When `VINNYFIN_SHOTS` names a folder, each
/// step leaves a screenshot there (see `requestScreenshot`).
///
/// Expects a server at `VINNYFIN_TEST_SERVER` (default http://localhost:8096) with a user
/// "viewer" without a password. Tests skip without what they play: "Subtitle Test" (`testserver/`),
/// to download; "Orbit Diaries", a show of three-minute episodes whose chapters "Intro" (0:05 to
/// 0:25) and "Credits" (from 2:30) the Chapter Segments Provider plugin turns into segments; "Big
/// Screen", a few minutes of H.264 with forced subtitles; "Software Route", in VP9; the 3D titles
/// "Spatial MV-HEVC" and "Stereo Side by Side"; and a file "Local Clip.mp4" in the app's
/// Documents.
final class VisionPlayerTests: XCTestCase {
    private var server: String {
        ProcessInfo.processInfo.environment["VINNYFIN_TEST_SERVER"] ?? "http://localhost:8096"
    }

    override func setUp() async throws {
        continueAfterFailure = false
        let info = try XCTUnwrap(URL(string: server + "/System/Info/Public"))
        let answered = (try? await URLSession.shared.data(from: info)) != nil
        try XCTSkipUnless(answered, "No Jellyfin test server answers at \(server)")
    }

    /// A failed test leaves the screen it stopped on, as `<test>-failed`.
    override func tearDown() async throws {
        guard let run = testRun, run.totalFailureCount > 0 else { return }
        let test = name.split(separator: " ").last.map { String($0.dropLast()) } ?? "test"
        try await requestScreenshot(test + "-failed")
    }

    @MainActor
    func testPlayAMovieWithSubtitles() async throws {
        let app = try await launchSignedIn()
        try openMovie("Big Screen", in: app)
        tap(app.buttons["detail.play"])
        waitForPlayer(in: app)
        waitForPlayback(in: app)
        showControls(app)
        // Paused, the controls stay up while the panels are worked.
        tap(app.buttons["player.playPause"])
        try await requestScreenshot("movie-controls")

        tap(app.buttons["player.subtitles"])
        let subtitles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'panel.subtitle.' AND identifier != 'panel.subtitle.off'"))
        let subtitlesAppeared = subtitles.firstMatch.waitForExistence(timeout: uiTimeout)
        try await requestScreenshot("movie-subtitles")
        XCTAssertTrue(subtitlesAppeared, "The subtitle choices never appeared")
        subtitles.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["panel.subtitle.off"].waitForNonExistence(timeout: uiTimeout), "The subtitle panel didn't close")

        tap(app.buttons["player.audio"])
        let audio = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'panel.audio.'"))
        let audioAppeared = audio.firstMatch.waitForExistence(timeout: uiTimeout)
        try await requestScreenshot("movie-audio")
        XCTAssertTrue(audioAppeared, "The audio choices never appeared")
        audio.element(boundBy: 0).tap()

        try scrub(to: 0.5, in: app, expecting: "1:")
        try await requestScreenshot("movie-scrubbed")
        tap(app.buttons["player.playPause"])
        let line = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'on the big screen'")).firstMatch
        let lineAppeared = line.waitForExistence(timeout: uiTimeout)
        try await requestScreenshot("movie-subtitle-on")
        XCTAssertTrue(lineAppeared, "No subtitle showed over the picture")
        close(app, returningTo: app.buttons["detail.play"])
    }

    @MainActor
    func testSkipTheIntroThenUpNext() async throws {
        let app = try await launchSignedIn()
        tap(app.buttons["Shows"].firstMatch)
        let show = app.buttons["poster.Orbit Diaries"]
        try XCTSkipUnless(show.waitForExistence(timeout: uiTimeout), "No Orbit Diaries on this server")
        show.tap()
        tap(app.buttons["episode.1"])
        waitForPlayer(in: app)
        let skip = app.buttons["player.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: uiTimeout), "Skip Intro never appeared")
        try await requestScreenshot("episode-intro")
        skip.tap()
        try await Task.sleep(for: .seconds(2))
        showControls(app)
        tap(app.buttons["player.playPause"])
        let timeline = app.descendants(matching: .any)["player.timeline"].firstMatch
        let position = Self.timelinePosition(timeline.value as? String)
        XCTAssertTrue(position.map { (25...60).contains($0.time) } ?? false,
                      "Skipping didn't land past the intro (\(timeline.value ?? ""))")
        XCTAssertTrue(app.buttons["episodes.episode.2"].waitForExistence(timeout: uiTimeout), "The episodes aren't in the controls")
        try await requestScreenshot("episode-controls")

        // Into the credits, where the next episode is offered.
        try scrub(to: 0.88, in: app, expecting: "2:3")
        let playNext = app.buttons["player.playNext"]
        XCTAssertTrue(playNext.waitForExistence(timeout: uiTimeout), "The up-next card never appeared")
        try await requestScreenshot("episode-up-next")
        playNext.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'S01E02'")).firstMatch.waitForExistence(timeout: uiTimeout),
                      "The next episode never started")
        XCTAssertTrue(skip.waitForExistence(timeout: uiTimeout), "The next episode's intro isn't offered to skip")
        try await requestScreenshot("episode-next")
        close(app, returningTo: app.buttons["episode.1"])
    }

    /// The cinema with a title AVPlayer plays on a device, and its subtitles on the big screen.
    @MainActor
    func testTheCinema() async throws {
        try await visitTheCinema(with: "Big Screen", from: 0.88, expecting: "2:3", shot: "cinema")
    }

    /// The cinema with a title the engine decodes itself, which has no AVPlayer. The simulator
    /// decodes every title itself, so there the two cinema tests take the same route.
    @MainActor
    func testTheCinemaWithoutAVPlayer() async throws {
        try await visitTheCinema(with: "Software Route", from: 0.55, expecting: "0:2", shot: "cinema-software")
    }

    /// On a device only: the simulator has no hardware decoders, so the engine decodes every title
    /// there itself, and what it decodes plays in 2D.
    @MainActor
    func testThreeDTitles() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The simulator plays every title in 2D")
        #else
        let app = try await launchSignedIn()
        for (title, shot) in [("Spatial MV-HEVC", "3d-mv-hevc"), ("Stereo Side by Side", "3d-side-by-side")] {
            try openMovie(title, in: app)
            tap(app.buttons["detail.play"])
            waitForPlayer(in: app)
            waitForPlayback(in: app)
            showControls(app)
            let badge = app.staticTexts["player.format"]
            XCTAssertTrue(badge.waitForExistence(timeout: uiTimeout), "\(title) shows no format badge")
            XCTAssertTrue(badge.label.contains("3D"), "\(title) isn't playing in 3D (\(badge.label))")
            try await requestScreenshot(shot)
            close(app, returningTo: app.buttons["detail.play"])
            app.navigationBars.buttons.firstMatch.tap()
        }
        #endif
    }

    @MainActor
    func testPlayADownloadAndAFile() async throws {
        let app = try await launchSignedIn()
        try openMovie("Subtitle Test", in: app)
        let download = app.buttons["detail.download"]
        // Once downloaded, the button is a menu to delete it.
        if download.waitForExistence(timeout: 5), download.label == "Download" { download.tap() }
        tap(app.buttons["Downloads"].firstMatch)
        // Titled with the year, as "Subtitle Test (2019)".
        let downloaded = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'downloaded.Subtitle Test'")).firstMatch
        XCTAssertTrue(downloaded.waitForExistence(timeout: 120), "The download never finished")
        downloaded.tap()
        waitForPlayer(in: app)
        waitForPlayback(in: app)
        showControls(app)
        XCTAssertTrue(app.staticTexts["player.format"].label.contains("Downloaded"), "The download isn't what's playing")
        try await requestScreenshot("download-playing")
        close(app, returningTo: downloaded)

        // Once played, it's among the recent files too.
        let file = app.buttons.matching(identifier: "file.Local Clip.mp4").firstMatch
        try XCTSkipUnless(file.waitForExistence(timeout: 5), "No Local Clip.mp4 in the app's Documents")
        file.tap()
        waitForPlayer(in: app)
        waitForPlayback(in: app)
        showControls(app)
        try await requestScreenshot("file-playing")
        close(app, returningTo: file)
    }

    // MARK: Steps

    /// Signs in with the form as the last sign-in left it: the app's defaults name the server and
    /// user beforehand, `lastServer` (an archived URL) and `lastUserName` (see `signInArguments`).
    @MainActor
    private func launchSignedIn() async throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app)
        XCTAssertTrue(app.buttons["Movies"].firstMatch.waitForExistence(timeout: uiTimeout), "Signing in never finished")
        return app
    }

    /// Opens the movie whose name starts with `title`, as "Big Screen (2021)" does "Big Screen".
    @MainActor
    private func openMovie(_ title: String, in app: XCUIApplication) throws {
        tap(app.buttons["Movies"].firstMatch)
        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "poster.\(title)")).firstMatch
        try XCTSkipUnless(poster.waitForExistence(timeout: uiTimeout), "No \(title) on this server")
        poster.tap()
    }

    /// Plays the end of `title`, from `fraction` of the way in (where the timeline reads
    /// `expecting`), in the cinema, and leaves it. On a device a pinch on the big screen brings
    /// the controls back; a UI test's taps don't reach RealityKit's entities, so here the title's
    /// end does.
    @MainActor
    private func visitTheCinema(with title: String, from fraction: Double, expecting: String, shot: String) async throws {
        let app = try await launchSignedIn()
        try openMovie(title, in: app)
        tap(app.buttons["detail.play"])
        waitForPlayer(in: app)
        waitForPlayback(in: app)
        try await requestScreenshot(shot + "-window")
        showControls(app)
        tap(app.buttons["player.playPause"])
        try scrub(to: fraction, in: app, expecting: expecting)
        tap(app.buttons["player.playPause"])
        tap(app.buttons["player.cinema"])
        let leave = app.buttons["Leave Cinema"]
        XCTAssertTrue(leave.waitForExistence(timeout: uiTimeout), "The cinema never opened")
        XCTAssertTrue(wait(until: { !controlsAreUp(app) }, timeout: uiTimeout), "The controls never faded in the cinema")
        try await requestScreenshot(shot)
        XCTAssertTrue(wait(until: { controlsAreUp(app) }, timeout: 60), "The controls never came back at the end")
        try await requestScreenshot(shot + "-ended")
        tap(leave)
        XCTAssertTrue(app.buttons["Cinema"].waitForExistence(timeout: uiTimeout), "The cinema never closed")
        try await Task.sleep(for: .seconds(2))
        try await requestScreenshot(shot + "-left")
        close(app, returningTo: app.buttons["detail.play"])
    }

    /// Waits for the player's window and the picture in it, which shows and hides the controls
    /// in the ornament below when tapped.
    @MainActor
    private func waitForPlayer(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["player.picture"].waitForExistence(timeout: uiTimeout), "The player never opened")
    }

    /// Waits until the timeline has moved past the start, bringing the controls back to read it
    /// when they fade first.
    @MainActor
    private func waitForPlayback(in app: XCUIApplication) {
        let timeline = app.descendants(matching: .any)["player.timeline"].firstMatch
        // Read through a snapshot, as the timeline comes and goes with the controls.
        let position = { (try? timeline.snapshot())?.value as? String }
        let moved = wait(until: {
            if !controlsAreUp(app) { _ = bringBackControls(app) }
            return position().map { !$0.hasPrefix("0:00 ") } ?? false
        }, timeout: uiTimeout)
        XCTAssertTrue(moved, "Playback never got past 0:00 (\(position() ?? "no timeline"))")
    }

    /// Brings the controls back with a fresh four seconds before they fade. Up and playing,
    /// they're let fade first rather than raced; up and paused, they stay, and are left be.
    @MainActor
    private func showControls(_ app: XCUIApplication) {
        if controlsAreUp(app), !wait(until: { !controlsAreUp(app) }, timeout: 8) { return }
        XCTAssertTrue(bringBackControls(app), "The controls never came back")
    }

    /// Taps the picture, and says whether the controls came up.
    @MainActor
    private func bringBackControls(_ app: XCUIApplication) -> Bool {
        app.buttons["player.picture"].tap()
        return wait(until: { controlsAreUp(app) }, timeout: uiTimeout)
    }

    /// A fading ornament can stay in the accessibility tree with no place on screen, so being up
    /// means having a frame. Read through a snapshot, which can fail, rather than `frame`, which
    /// fails the test when the element goes.
    @MainActor
    private func controlsAreUp(_ app: XCUIApplication) -> Bool {
        (try? app.buttons["player.playPause"].snapshot()).map { !$0.frame.isEmpty } ?? false
    }

    /// Whether `condition` came true within `timeout` seconds.
    @MainActor
    private func wait(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return false }
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
        return true
    }

    /// Drags the playhead toward `fraction` of the timeline, steps it the rest of the way with the
    /// ten-second buttons, and checks the position read starts with `expecting`. A UI test's drag
    /// on Vision Pro carries the playhead up to a few times further than the pointer went, not at
    /// all when it's short, and past the end ends the title for good, so the drag aims a quarter of
    /// the way. Callers pause first, so the playhead moves only with the test.
    @MainActor
    private func scrub(to fraction: Double, in app: XCUIApplication, expecting: String) throws {
        showControls(app)
        let timeline = app.descendants(matching: .any)["player.timeline"].firstMatch
        // Read through a snapshot, as the timeline comes and goes with the controls.
        let reading = { (try? timeline.snapshot())?.value as? String }
        let arrived = { reading()?.hasPrefix(expecting) ?? false }
        let playhead = {
            try XCTUnwrap(Self.timelinePosition(reading()).map { $0.time / $0.duration },
                          "The timeline reads \(reading() ?? "nothing")")
        }
        let from = try playhead()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: from + (fraction - from) / 4, dy: 0.25)))
        var reached = wait(until: arrived, timeout: 2)
        for _ in 0..<40 where !reached {
            tap(app.buttons[try playhead() < fraction ? "Forward 10 Seconds" : "Back 10 Seconds"])
            reached = wait(until: arrived, timeout: 1)
        }
        XCTAssertTrue(reached, "Scrubbing didn't move the playhead to \(expecting)… (\(reading() ?? "no timeline"))")
    }

    /// The seconds in and the length a timeline reads, as "2:35 of 3:00" or "1:02:03 of 2:00:00".
    private static func timelinePosition(_ value: String?) -> (time: Double, duration: Double)? {
        let seconds = (value ?? "").components(separatedBy: " of ").map { part in
            part.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        }
        guard seconds.count == 2, seconds[1] > 0 else { return nil }
        return (Double(seconds[0]), Double(seconds[1]))
    }

    @MainActor
    private func close(_ app: XCUIApplication, returningTo landmark: XCUIElement) {
        showControls(app)
        tap(app.buttons["player.close"])
        XCTAssertTrue(app.buttons["player.close"].waitForNonExistence(timeout: uiTimeout), "The player never closed")
        XCTAssertTrue(landmark.waitForExistence(timeout: uiTimeout), "\(landmark) didn't come back")
    }
}
#endif
