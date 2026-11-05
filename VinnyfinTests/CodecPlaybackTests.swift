import AetherEngine
import Foundation
import Testing
@testable import vinnyfin

/// Plays every file of the generated test library through the engine and checks the clock gets
/// going: each container, video and audio codec the app claims to handle. Needs the library from
/// `testserver/gen-media.sh`, and a test host that can read it (a simulator can; the sandboxed
/// Mac app can't), and is skipped otherwise.
nonisolated enum TestLibrary {
    static let media = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "testserver/media")

    static var isReadable: Bool {
        FileManager.default.isReadableFile(atPath: media.appending(path: "movies").path)
    }
}

@MainActor
@Suite(.serialized, .enabled(if: TestLibrary.isReadable, "Run testserver/gen-media.sh to generate the library"))
struct CodecPlaybackTests {
    nonisolated struct Sample: Sendable, CustomTestStringConvertible {
        let path: String
        var format: VideoFormat = .sdr
        var audioCodec: String?
        var testDescription: String { (path as NSString).lastPathComponent }
    }

    nonisolated static let samples = [
        Sample(path: "movies/Big Test Movie (2024)/Big Test Movie (2024) - 2160p.mkv", format: .hdr10, audioCodec: "eac3"),
        Sample(path: "movies/Big Test Movie (2024)/Big Test Movie (2024) - 1080p.mkv", audioCodec: "ac3"),
        Sample(path: "movies/Big Test Movie (2024)/Big Test Movie (2024) - 720p.mp4", audioCodec: "aac"),
        Sample(path: "movies/Codec Zoo VP9 (2021)/Codec Zoo VP9 (2021).webm", audioCodec: "opus"),
        Sample(path: "movies/Codec Zoo AV1 (2022)/Codec Zoo AV1 (2022).mkv", audioCodec: "flac"),
        Sample(path: "movies/Codec Zoo DTS (2005)/Codec Zoo DTS (2005).mkv", audioCodec: "dca"),
        Sample(path: "movies/Codec Zoo TrueHD (2010)/Codec Zoo TrueHD (2010).mkv", audioCodec: "truehd"),
        Sample(path: "movies/Codec Zoo MPEG-2 (1999)/Codec Zoo MPEG-2 (1999).ts", audioCodec: "ac3"),
        Sample(path: "movies/Subtitle Test (2019)/Subtitle Test (2019).mkv", audioCodec: "aac"),
    ]

    @Test(arguments: samples)
    func plays(_ sample: Sample) async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await engine.load(url: TestLibrary.media.appending(path: sample.path))

        let deadline = ContinuousClock.now + .seconds(30)
        while engine.clock.currentTime < 1.5, ContinuousClock.now < deadline {
            if case .error(let message) = engine.state {
                Issue.record("The engine failed: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(engine.clock.currentTime >= 1.5, "The clock stayed at \(engine.clock.currentTime)s")
        #expect(engine.sourceVideoFormat == sample.format)
        if let audioCodec = sample.audioCodec {
            #expect(engine.audioTracks.contains { $0.codec.lowercased().contains(audioCodec) },
                    "Audio tracks: \(engine.audioTracks.map(\.codec))")
        }
    }
}

/// One engine plays one thing after another: an episode after the one before, or a new player
/// window after the last. A playback must not inherit the state the last one left the engine in.
@MainActor
@Suite(.serialized, .enabled(if: TestLibrary.isReadable, "Run testserver/gen-media.sh to generate the library"))
struct PlayerHandoffTests {
    private func makeModel(playing file: URL, engine: AetherEngine, lease: EngineLease, history: WatchHistory) throws -> PlayerModel {
        let defaults = try #require(UserDefaults(suiteName: "PlayerHandoffTests-\(UUID().uuidString)"))
        let accounts = AccountStore(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        let resolver = PlaybackResolver(accounts: accounts, settings: settings, history: history) { _, _ in nil }
        return PlayerModel(request: try .file(file), engine: engine, lease: lease,
                           resolver: resolver, accounts: accounts, history: history, settings: settings) { _ in nil }
    }

    /// Copies library files into a temporary folder. The sandboxed Mac app can only bookmark files
    /// the user picked or its own, and the library is neither.
    private func copies(of paths: [String], into folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try paths.map { path in
            let copy = folder.appending(path: (path as NSString).lastPathComponent)
            try FileManager.default.copyItem(at: TestLibrary.media.appending(path: path), to: copy)
            return copy
        }
    }

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 30) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    @Test func aNewPlaybackIgnoresTheLastOnesEnding() async throws {
        let engine = try AetherEngine()
        let lease = EngineLease()
        let history = WatchHistory(file: FileManager.default.temporaryDirectory.appending(path: "Handoff-\(UUID().uuidString).json"))

        let folder = FileManager.default.temporaryDirectory.appending(path: "Handoff-\(UUID().uuidString)")
        let files = try copies(of: ["movies/Aurora (1992)/Aurora (1992).mp4",
                                    "movies/Big Test Movie (2024)/Big Test Movie (2024) - 720p.mp4"], into: folder)

        let first = try makeModel(playing: files[0], engine: engine, lease: lease, history: history)
        await first.start()
        try await waitUntil { first.status == .ended }
        #expect(first.status == .ended)

        let second = try makeModel(playing: files[1], engine: engine, lease: lease, history: history)
        await second.start()
        try await waitUntil { second.clock.time > 2 }
        #expect(second.status == .playing)
        #expect(second.duration > 50, "Took the last playback's duration: \(second.duration)")
        let size = try #require(try files[1].resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let key = WatchHistory.fileKey(name: files[1].lastPathComponent, size: Int64(size))
        #expect(history.entry(for: key)?.played != true, "Marked watched as it started")

        await second.close()
        await first.close()
        try FileManager.default.removeItem(at: folder)
    }

    /// Until its first frame is on screen a playback reads as loading, though the engine plays and
    /// its clock runs, so the player doesn't offer Pause over a black picture.
    @Test func playingWaitsForThePicture() async throws {
        let engine = try AetherEngine()
        let history = WatchHistory(file: FileManager.default.temporaryDirectory.appending(path: "Picture-\(UUID().uuidString).json"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "Picture-\(UUID().uuidString)")
        let files = try copies(of: ["movies/Big Test Movie (2024)/Big Test Movie (2024) - 1080p.mkv"], into: folder)

        let model = try makeModel(playing: files[0], engine: engine, lease: EngineLease(), history: history)
        await model.start()
        var playedBeforeThePicture = false
        try await waitUntil {
            if model.status == .playing, engine.startupProgress?.isComplete != true { playedBeforeThePicture = true }
            return model.status == .playing
        }
        #expect(model.status == .playing)
        #expect(!playedBeforeThePicture, "Read as playing before the first frame was on screen")

        await model.close()
        try FileManager.default.removeItem(at: folder)
    }
}
