#if os(iOS) || os(visionOS)
import AVFoundation
import Foundation
import Testing
@testable import vinnyfin

private typealias Inputs = KeepAwakePlan.Inputs

/// Switched on and signed in, with downloads left, in front, nothing playing.
private func inputs(
    isOn: Bool = true,
    keepsPlaying: Bool = false,
    isSignedIn: Bool = true,
    hasDownloads: Bool = true,
    isPausedForPlayback: Bool = false,
    isInFront: Bool = true,
    userStarts: Int = 0
) -> Inputs {
    Inputs(isOn: isOn, keepsPlayingAfterDownloads: keepsPlaying, isSignedIn: isSignedIn, hasDownloads: hasDownloads,
           isPausedForPlayback: isPausedForPlayback, isInFront: isInFront, userStartCount: userStarts)
}

/// A plan the person started by turning the switch on, playing.
private func playing(_ given: Inputs = inputs()) -> KeepAwakePlan {
    var plan = KeepAwakePlan()
    plan.switchedOn(given)
    return plan
}

struct KeepAwakePlanTests {
    @Test func startsWhenSwitchedOnWithDownloadsUnfinished() {
        let plan = playing()
        #expect(plan.isStarted && plan.isPlaying)

        var nothingLeft = KeepAwakePlan()
        nothingLeft.switchedOn(inputs(hasDownloads: false))
        #expect(!nothingLeft.isStarted && !nothingLeft.isPlaying)
        // Keep Playing After Downloads Finish doesn't start it with nothing to download.
        var keeping = KeepAwakePlan()
        keeping.switchedOn(inputs(keepsPlaying: true, hasDownloads: false))
        #expect(!keeping.isStarted)
    }

    @Test func startsWhenSomeoneStartsDownloadsWithItOn() {
        var plan = KeepAwakePlan()
        plan.update(inputs(userStarts: 1))
        #expect(plan.isStarted && plan.isPlaying)

        var off = KeepAwakePlan()
        off.update(inputs(isOn: false, userStarts: 1))
        // Turned on later, the earlier start doesn't count.
        off.update(inputs(isOn: true, userStarts: 1))
        #expect(!off.isStarted)
    }

    /// The switch being on, with downloads unfinished, starts nothing by itself: at launch, or
    /// when the downloads change.
    @Test func neverStartsByItself() {
        var plan = KeepAwakePlan()
        plan.update(inputs())
        plan.update(inputs(hasDownloads: false))
        plan.update(inputs(hasDownloads: true))
        #expect(!plan.isStarted && !plan.isPlaying)
    }

    /// A background app can't start audio: started away from the front, it waits to be in front
    /// to play, and once playing it carries on wherever the app goes.
    @Test func beginsPlayingOnlyInFrontAndCarriesOnBehind() {
        var plan = KeepAwakePlan()
        plan.update(inputs(isInFront: false, userStarts: 1))
        #expect(plan.isStarted && !plan.isPlaying)
        plan.update(inputs(isInFront: true, userStarts: 1))
        #expect(plan.isPlaying)
        plan.update(inputs(isInFront: false, userStarts: 1))
        #expect(plan.isPlaying)
    }

    @Test func stopsOnceNothingIsLeftToDownload() {
        var plan = playing()
        plan.update(inputs(hasDownloads: false))
        #expect(!plan.isStarted && !plan.isPlaying)
        // Downloads that come back later, smart ones say, don't start it again.
        plan.update(inputs(hasDownloads: true))
        #expect(!plan.isStarted)
    }

    @Test func keepsPlayingAfterDownloadsFinishUntilStopped() {
        var plan = playing(inputs(keepsPlaying: true))
        plan.update(inputs(keepsPlaying: true, hasDownloads: false, isInFront: false))
        #expect(plan.isStarted && plan.isPlaying)
        plan.stop()
        #expect(!plan.isStarted && !plan.isPlaying)
        plan.update(inputs(keepsPlaying: true, hasDownloads: false))
        #expect(!plan.isStarted)
    }

    @Test func turningKeepPlayingOffWithNothingLeftStopsIt() {
        var plan = playing(inputs(keepsPlaying: true))
        plan.update(inputs(keepsPlaying: true, hasDownloads: false))
        plan.update(inputs(keepsPlaying: false, hasDownloads: false))
        #expect(!plan.isStarted)
    }

    @Test func stopsWhenTheSwitchGoesOffOrOnSignOut() {
        var switchedOff = playing(inputs(keepsPlaying: true))
        switchedOff.update(inputs(isOn: false, keepsPlaying: true))
        #expect(!switchedOff.isStarted && !switchedOff.isPlaying)
        var signedOut = playing(inputs(keepsPlaying: true))
        signedOut.update(inputs(keepsPlaying: true, isSignedIn: false, hasDownloads: false))
        #expect(!signedOut.isStarted && !signedOut.isPlaying)
    }

    @Test func theStopButtonEndsItUntilSomeoneStartsDownloadsAgain() {
        var plan = playing()
        plan.stop()
        plan.update(inputs())
        #expect(!plan.isStarted)
        // Resuming a download moves the count, even for one started before.
        plan.update(inputs(userStarts: 1))
        #expect(plan.isStarted && plan.isPlaying)
    }

    // MARK: The playback hold

    @Test func stepsAsideWhileAPlaybackHoldsTheDownloads() {
        var plan = playing()
        plan.update(inputs(isPausedForPlayback: true))
        #expect(plan.isStarted && !plan.isPlaying)
        // Picture in Picture in the background is a playback holding them.
        plan.update(inputs(isPausedForPlayback: true, isInFront: false))
        #expect(!plan.isPlaying)
        plan.update(inputs(isPausedForPlayback: false, isInFront: true))
        #expect(plan.isPlaying)
    }

    /// A paused player the app leaves lets the downloads go on, but the keep-alive waits for the
    /// app in front with the player closed.
    @Test func comesBackOnlyOnceThePlayerClosesInFront() {
        var plan = playing()
        plan.update(inputs(isPausedForPlayback: true))
        // Paused, then the app leaves: the hold lets go as the app leaves the front.
        plan.update(inputs(isPausedForPlayback: false, isInFront: false))
        #expect(plan.isStarted && !plan.isPlaying)
        // Back in front with the player still open: held again.
        plan.update(inputs(isPausedForPlayback: true, isInFront: true))
        #expect(!plan.isPlaying)
        plan.update(inputs(isPausedForPlayback: false, isInFront: true))
        #expect(plan.isPlaying)
    }

    @Test func startedDuringAPlaybackPlaysOnceItsOver() {
        var plan = KeepAwakePlan()
        plan.update(inputs(isPausedForPlayback: true, userStarts: 1))
        #expect(plan.isStarted && !plan.isPlaying)
        plan.update(inputs(isPausedForPlayback: false, userStarts: 1))
        #expect(plan.isPlaying)
    }

    @Test func downloadsFinishingDuringAPlaybackEndIt() {
        var plan = playing()
        plan.update(inputs(hasDownloads: false, isPausedForPlayback: true))
        plan.update(inputs(hasDownloads: false, isPausedForPlayback: false))
        #expect(!plan.isStarted && !plan.isPlaying)
    }
}

struct KeepAwakeSoundTests {
    private let noise = URL(string: "https://example.com/sounds/noise.mp3")!
    private let rain = URL(string: "http://nas.local:8080/rain.wav")!
    private let kept = URL(filePath: "/tmp/kept.mp3")

    @Test func readsTheAddressInSettings() {
        #expect(KeepAwakeSound.address(from: "") == .success(nil))
        #expect(KeepAwakeSound.address(from: "  \n") == .success(nil))
        #expect(KeepAwakeSound.address(from: "https://example.com/sounds/noise.mp3") == .success(noise))
        #expect(KeepAwakeSound.address(from: "  http://nas.local:8080/rain.wav ") == .success(rain))
        for wrong in ["white noise", "ftp://example.com/noise.mp3", "file:///tmp/noise.mp3", "https://", "example.com/noise.mp3"] {
            #expect(KeepAwakeSound.address(from: wrong) == .failure(.notAnAddress), "\(wrong)")
        }
    }

    @Test func blankPlaysSilence() {
        #expect(KeepAwakeSound.step(for: "", current: .silence) { _ in nil } == .keep)
        #expect(KeepAwakeSound.step(for: " ", current: .ready(noise, file: kept)) { _ in nil } == .silence)
        #expect(KeepAwakeSound.step(for: "", current: .failed(.notAudio)) { _ in nil } == .silence)
        #expect(KeepAwakeSound.silence.file == nil)
    }

    @Test func aWrongAddressFails() {
        #expect(KeepAwakeSound.step(for: "noise", current: .ready(noise, file: kept)) { _ in nil } == .fail(.notAnAddress))
        #expect(KeepAwakeSound.step(for: "noise", current: .failed(.notAnAddress)) { _ in nil } == .keep)
    }

    @Test func fetchesAnAddressOnceAndKeepsIt() {
        #expect(KeepAwakeSound.step(for: noise.absoluteString, current: .silence) { _ in nil } == .fetch(noise))
        #expect(KeepAwakeSound.step(for: noise.absoluteString, current: .fetching(noise)) { _ in nil } == .keep)
        #expect(KeepAwakeSound.step(for: noise.absoluteString, current: .ready(noise, file: kept)) { _ in nil } == .keep)
        // Kept from before, at launch: used without fetching.
        #expect(KeepAwakeSound.step(for: noise.absoluteString, current: .silence) { $0 == noise ? kept : nil } == .use(noise, file: kept))
        #expect(KeepAwakeSound.ready(noise, file: kept).file == kept)
        #expect(KeepAwakeSound.fetching(noise).file == nil)
    }

    @Test func fetchesAgainWhenTheAddressChanges() {
        #expect(KeepAwakeSound.step(for: rain.absoluteString, current: .ready(noise, file: kept)) { _ in nil } == .fetch(rain))
        #expect(KeepAwakeSound.step(for: rain.absoluteString, current: .fetching(noise)) { _ in nil } == .fetch(rain))
        #expect(KeepAwakeSound.keptName(for: noise) == KeepAwakeSound.keptName(for: noise))
        #expect(KeepAwakeSound.keptName(for: noise) != KeepAwakeSound.keptName(for: rain))
        #expect(KeepAwakeSound.keptName(for: noise).count == 16)
    }

    /// A fetch that failed is tried again when it's next resolved: the address changing, or the
    /// person starting the keep-alive.
    @Test func triesAFailedFetchAgain() {
        #expect(KeepAwakeSound.step(for: noise.absoluteString, current: .failed(.unreachable("offline"))) { _ in nil } == .fetch(noise))
        #expect(KeepAwakeSound.step(for: noise.absoluteString, current: .failed(.refused(status: 404))) { _ in nil } == .fetch(noise))
    }

    @Test @MainActor func saysWhatsWrongInPlainWords() {
        #expect(KeepAwakeSound.Failure.notAnAddress.message.contains("http://"))
        #expect(KeepAwakeSound.Failure.refused(status: 404).message == "The server answered 404 (\(HTTPURLResponse.localizedString(forStatusCode: 404))).")
        #expect(KeepAwakeSound.Failure.notAudio.message == "It isn't an audio file vinnyfin can play.")
        #expect(KeepAwakeSound.Failure.unreachable("Could not connect to the server.").message.hasSuffix("Could not connect to the server."))
    }

    @Test func givesWayToSilenceWhenItsOutputGoesAway() {
        #expect(KeepAwakeSound.isMuted(after: .oldDeviceUnavailable, wasMuted: false))
        #expect(!KeepAwakeSound.isMuted(after: .newDeviceAvailable, wasMuted: true))
        #expect(KeepAwakeSound.isMuted(after: .categoryChange, wasMuted: true))
        #expect(!KeepAwakeSound.isMuted(after: .override, wasMuted: false))
    }
}

/// The fetch, through file addresses so no server is needed: the session fetches them the same way.
struct KeepAwakeFetchTests {
    private let directory = URL.temporaryDirectory.appending(path: "KeepAwakeFetchTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func keepsAudioNamedForItsAddress() async throws {
        let source = try writeTone(frames: 4_800, sampleRate: 48_000)
        defer { cleanUp(source) }
        let kept = try await KeepAwakeSound.fetch(source, into: directory)
        #expect(kept.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(kept.deletingPathExtension().lastPathComponent == KeepAwakeSound.keptName(for: source))
        #expect(kept.pathExtension == "caf")
        #expect(try AVAudioFile(forReading: kept).length == 4_800)
        // Fetched again, it replaces what was kept.
        #expect(try await KeepAwakeSound.fetch(source, into: directory) == kept)
    }

    @Test func refusesAFileThatIsntAudio() async throws {
        let text = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mp3")
        try Data("not audio at all".utf8).write(to: text)
        defer { cleanUp(text) }
        await #expect(throws: KeepAwakeSound.Failure.notAudio) { try await KeepAwakeSound.fetch(text, into: directory) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func saysWhenItCantBeFetched() async throws {
        let missing = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        defer { cleanUp(missing) }
        let error = await #expect(throws: KeepAwakeSound.Failure.self) { try await KeepAwakeSound.fetch(missing, into: directory) }
        guard case .unreachable = error else {
            Issue.record("A file that isn't there should be unreachable, not \(String(describing: error))")
            return
        }
    }

    private func cleanUp(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The audio that keeps the app running: silence that's silent, and loops that join without a seam.
struct KeepAwakeLoopTests {
    @Test func silenceIsZeros() throws {
        let buffer = try #require(KeepAwakePlayer.silence(sampleRate: 44_100))
        #expect(buffer.frameLength == KeepAwakePlayer.silenceFrames)
        #expect(buffer.format.channelCount == 1 && buffer.format.sampleRate == 44_100)
        let samples = try #require(buffer.floatChannelData)[0]
        #expect((0..<Int(buffer.frameLength)).allSatisfy { samples[$0] == 0 })
    }

    @Test func aShortSoundLoopsFromMemoryAndALongOneFromItsFile() throws {
        let short = try writeTone(frames: 8_000, sampleRate: 8_000)
        let long = try writeTone(frames: Int(KeepAwakePlayer.longestInMemory + 1) * 8_000, sampleRate: 8_000)
        defer {
            try? FileManager.default.removeItem(at: short)
            try? FileManager.default.removeItem(at: long)
        }
        guard case .buffer(let buffer) = try KeepAwakePlayer.loop(for: short) else {
            Issue.record("A one-second sound should loop from memory")
            return
        }
        #expect(buffer.frameLength == 8_000)
        guard case .file(let file, let copies, let duration) = try KeepAwakePlayer.loop(for: long) else {
            Issue.record("A sound longer than \(KeepAwakePlayer.longestInMemory) s should loop from its file")
            return
        }
        #expect(file == long && copies.count == 2 && duration == KeepAwakePlayer.longestInMemory + 1)
    }

    /// Rendered offline, a sound looped from memory comes out as itself again and again, sample
    /// for sample, with nothing at the seams.
    @Test func aLoopFromMemoryHasNoSeam() throws {
        let frames = 1_000
        let file = try writeTone(frames: frames, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: file) }
        guard case .buffer(let sound) = try KeepAwakePlayer.loop(for: file) else {
            Issue.record("It should loop from memory")
            return
        }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        try engine.enableManualRenderingMode(.offline, format: sound.format, maximumFrameCount: 512)
        try engine.connectNode(node, to: engine.mainMixerNode, format: sound.format)
        node.scheduleBuffer(sound, at: nil, options: .loops)
        try engine.start()
        try node.playAudio()
        defer { engine.stop() }

        var rendered: [Float] = []
        let output = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        while rendered.count < frames * 3 + 250 {
            #expect(try engine.renderOffline(512, to: output) == .success)
            let channel = try #require(output.floatChannelData)[0]
            rendered += (0..<Int(output.frameLength)).map { channel[$0] }
        }
        let expected = (0..<rendered.count).map { tone(at: $0 % frames, of: frames) }
        let worst = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-6)
    }
}

/// One ramp up from -0.5 to 0.5 over the sound: any seam that drops, repeats or smooths a sample
/// shows as a difference.
private func tone(at frame: Int, of frames: Int) -> Float {
    Float(frame) / Float(frames) - 0.5
}

/// Writes a mono Core Audio file of `tone` in the temporary folder.
private func writeTone(frames: Int, sampleRate: Double) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = try #require(buffer.floatChannelData)[0]
    for frame in 0..<frames { samples[frame] = tone(at: frame, of: frames) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    return url
}
#endif
