import AetherEngine
import Foundation
import Testing
@testable import vinnyfin

/// AetherEngine has a `MediaSource` of its own.
typealias MediaSource = vinnyfin.MediaSource

private func version(_ id: String, _ name: String? = nil, width: Int? = nil, height: Int? = nil) -> MediaSource {
    var source = MediaSource(id: id, name: name)
    if let width, let height {
        var video = MediaStream(type: "Video")
        video.width = width
        video.height = height
        source.mediaStreams = [video]
    }
    return source
}

struct VersionChooserTests {
    let versions = [
        version("4k-remux", "2160p REMUX", width: 3840, height: 2160),
        version("1080-web", "1080p WEB-DL", width: 1920, height: 1080),
        version("1080-bluray", "1080p BluRay", width: 1920, height: 1080),
        version("720", "720p", width: 1280, height: 720),
    ]

    @Test func bestAvailableTakesTheServersFirst() {
        #expect(VersionChooser.choose(from: versions, quality: .original)?.id == "4k-remux")
    }

    @Test func takesTheBestThatFitsKeepingTheServersOrder() {
        #expect(VersionChooser.choose(from: versions, quality: .fullHD)?.id == "1080-web")
        #expect(VersionChooser.choose(from: versions, quality: .hd)?.id == "720")
        #expect(VersionChooser.choose(from: versions, quality: .uhd)?.id == "4k-remux")
    }

    @Test func triesAnUnlabelledVersionBeforeScalingDown() {
        let sources = [version("4k", "2160p", width: 3840, height: 2160), version("mystery", "Main")]
        #expect(VersionChooser.choose(from: sources, quality: .fullHD)?.id == "mystery")
    }

    @Test func takesTheSmallestWhenNothingFits() {
        let sources = [version("4k", width: 3840, height: 2160), version("1080", width: 1920, height: 1080)]
        #expect(VersionChooser.choose(from: sources, quality: .hd)?.id == "1080")
    }

    @Test func readsTheClassFromWideFramesAndNames() {
        #expect(VersionTraits(version("scope", width: 1920, height: 800)).resolutionClass == 1080)
        #expect(VersionTraits(version("cropped", width: 3840, height: 1606)).resolutionClass == 2160)
        #expect(VersionTraits(version("gelato", "[RD+] 4K HDR DV")).resolutionClass == 2160)
        #expect(VersionTraits(version("named", "Movie.1080p.WEB")).resolutionClass == 1080)
        #expect(VersionTraits(version("none", "Director's Cut")).resolutionClass == nil)
    }

    @Test func streamsTheOriginalWhenItFits() {
        let plan = VersionChooser.planStreaming(sources: versions, preferred: nil, quality: .fullHD, allowTranscoding: true)
        #expect(plan == .direct(versions[1]))
    }

    @Test func scalesDownAPickedVersionThatIsTooBig() {
        let plan = VersionChooser.planStreaming(sources: versions, preferred: versions[0], quality: .fullHD, allowTranscoding: true)
        #expect(plan == .transcode(versions[0], .fullHD))
    }

    @Test func playsTheOriginalWhenTranscodingIsOff() {
        let only4K = [versions[0]]
        #expect(VersionChooser.planStreaming(sources: only4K, preferred: nil, quality: .fullHD, allowTranscoding: false) == .direct(versions[0]))
        #expect(VersionChooser.planStreaming(sources: only4K, preferred: nil, quality: .fullHD, allowTranscoding: true) == .transcode(versions[0], .fullHD))
    }

    @Test func playsAnUnlabelledVersionAsItIs() {
        let mystery = version("mystery")
        #expect(VersionChooser.planStreaming(sources: [mystery], preferred: nil, quality: .hd, allowTranscoding: true) == .direct(mystery))
    }
}

struct TrackChooserTests {
    let english = TrackChooser.Candidate(id: 3, language: "eng", isForced: false, isHearingImpaired: false, isDefault: false)
    let englishSDH = TrackChooser.Candidate(id: 4, language: "eng", isForced: false, isHearingImpaired: true, isDefault: false)
    let englishForced = TrackChooser.Candidate(id: 5, language: "eng", isForced: true, isHearingImpaired: false, isDefault: false)
    let french = TrackChooser.Candidate(id: 6, language: "fre", isForced: false, isHearingImpaired: false, isDefault: true)

    @Test func offChoosesNothing() {
        #expect(TrackChooser.subtitle(from: [english, englishForced], audioLanguage: "jpn", mode: .off, language: "eng") == nil)
    }

    @Test func forcedOnlyChoosesTheForcedTrack() {
        #expect(TrackChooser.subtitle(from: [english, englishForced], audioLanguage: "eng", mode: .forcedOnly, language: "eng") == 5)
        #expect(TrackChooser.subtitle(from: [english, french], audioLanguage: "eng", mode: .forcedOnly, language: "eng") == nil)
    }

    @Test func smartShowsFullSubtitlesForForeignAudio() {
        let tracks = [englishSDH, english, englishForced, french]
        #expect(TrackChooser.subtitle(from: tracks, audioLanguage: "jpn", mode: .smart, language: "eng") == 3)
        #expect(TrackChooser.subtitle(from: tracks, audioLanguage: "en", mode: .smart, language: "eng") == 5)
        #expect(TrackChooser.subtitle(from: [english], audioLanguage: "und", mode: .smart, language: "eng") == nil)
    }

    @Test func alwaysPrefersAFullTrackOverSDH() {
        #expect(TrackChooser.subtitle(from: [englishSDH, english], audioLanguage: "eng", mode: .always, language: "eng") == 3)
        #expect(TrackChooser.subtitle(from: [englishSDH], audioLanguage: "eng", mode: .always, language: "eng") == 4)
        #expect(TrackChooser.subtitle(from: [french], audioLanguage: "eng", mode: .always, language: "eng") == nil)
    }

    @Test func matchesLanguageTagsInAnyForm() {
        #expect(AppSettings.sameLanguage("eng", "en-US"))
        #expect(AppSettings.sameLanguage("fra", "fre"))
        #expect(AppSettings.sameLanguage("de", "ger"))
        #expect(!AppSettings.sameLanguage("eng", "spa"))
        #expect(!AppSettings.sameLanguage(nil, "eng"))
    }
}

@MainActor
struct WatchHistoryTests {
    private func makeHistory() -> WatchHistory {
        WatchHistory(file: FileManager.default.temporaryDirectory.appending(path: "WatchHistory-\(UUID().uuidString).json"))
    }

    @Test func ignoresTheFirstFewPercent() {
        let history = makeHistory()
        history.record(key: "a", position: 60, duration: 6000, needsSync: false)
        #expect(history.resumePosition(for: "a") == nil)
        history.record(key: "a", position: 600, duration: 6000, needsSync: false)
        #expect(history.resumePosition(for: "a") == 600)
    }

    @Test func countsTheLastTenPercentAsWatched() {
        let history = makeHistory()
        history.record(key: "a", position: 5500, duration: 6000, needsSync: true)
        let entry = history.entry(for: "a")
        #expect(entry?.played == true)
        #expect(entry?.position == 0)
        #expect(history.resumePosition(for: "a") == nil)
        #expect(history.hasPendingSync)
    }

    @Test func neverSyncsLocalFiles() {
        let history = makeHistory()
        history.record(key: WatchHistory.fileKey(name: "Home Movie.mkv", size: 42), position: 300, duration: 1000, needsSync: true)
        #expect(!history.hasPendingSync)
    }

    @Test func survivesARelaunch() {
        let file = FileManager.default.temporaryDirectory.appending(path: "WatchHistory-\(UUID().uuidString).json")
        WatchHistory(file: file).markPlayed(true, key: "episode", needsSync: true)
        let reloaded = WatchHistory(file: file)
        #expect(reloaded.entry(for: "episode")?.played == true)
        #expect(reloaded.problem == nil)
    }
}

struct JellyfinFormatTests {
    @Test func parsesSevenDigitFractions() throws {
        let date = try #require(JellyfinDate.parse("2026-03-04T05:06:07.1234567Z"))
        #expect(date == Date(timeIntervalSince1970: 1_772_600_767))
        #expect(JellyfinDate.parse("2026-03-04T05:06:07Z") == date)
        #expect(JellyfinDate.parse("2026-03-04T07:06:07.5+02:00") == date)
        #expect(JellyfinDate.parse("yesterday") == nil)
    }

    @Test func asksForTranscodesNoBiggerThanTheQuality() throws {
        let profile = DeviceProfile.transcoding(maxHeight: 1080, maxBitrate: VideoQuality.fullHD.transcodeBitrate)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let conditions = try #require((json["CodecProfiles"] as? [[String: Any]])?.first?["Conditions"] as? [[String: Any]])
        #expect(conditions.contains { $0["Property"] as? String == "Height" && $0["Value"] as? String == "1080" })
        #expect(json["MaxStreamingBitrate"] as? Int == 16_000_000)
        let transcoding = try #require((json["TranscodingProfiles"] as? [[String: Any]])?.first)
        #expect(transcoding["Protocol"] as? String == "hls")
        #expect(DeviceProfile.transcoding(maxHeight: nil, maxBitrate: 1).CodecProfiles.isEmpty)
    }

    @Test func buildsSubtitleAndImageURLs() {
        let client = JellyfinClient(serverURL: URL(string: "https://jf.example.com")!, deviceId: "d", deviceName: "TV", token: "tok")
        #expect(client.externalSubtitleURL(itemId: "i", mediaSourceId: "m", streamIndex: 3, format: "srt").absoluteString
            == "https://jf.example.com/Videos/i/m/Subtitles/3/Stream.srt?ApiKey=tok")
        #expect(client.imageURL(itemId: "i", kind: .backdrop, tag: "t", maxWidth: 1280).absoluteString
            == "https://jf.example.com/Items/i/Images/Backdrop?maxWidth=1280&quality=90&tag=t")
    }
}

struct SmartDownloadPlannerTests {
    private func episodes(played: Int, total: Int, queued: Set<Int> = [], inProgress: Set<Int> = []) -> [SmartDownloadPlanner.Episode] {
        (1...total).map { number in
            SmartDownloadPlanner.Episode(id: "e\(number)", played: number <= played, inProgress: inProgress.contains(number),
                                         isQueued: queued.contains(number))
        }
    }

    @Test func startsAfterTheLastWatchedEpisode() {
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 3, total: 10), nextUpId: nil, count: 3) == ["e4", "e5", "e6"])
    }

    @Test func startsAtTheServersNextUp() {
        // Watching skipped ahead to episode 6: the server knows, so downloads follow.
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 3, total: 10), nextUpId: "e6", count: 2) == ["e6", "e7"])
    }

    @Test func keepsARollingWindowWithoutRequeueing() {
        let list = episodes(played: 2, total: 10, queued: [3, 4])
        #expect(SmartDownloadPlanner.episodesToDownload(list, nextUpId: nil, count: 4) == ["e5", "e6"])
    }

    @Test func takesEveryUnwatchedEpisodeWithoutACount() {
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 8, total: 10), nextUpId: nil, count: nil) == ["e9", "e10"])
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 10, total: 10), nextUpId: nil, count: nil).isEmpty)
    }

    @Test func takesSkippedAndNewEpisodesWhenKeepingEveryUnwatchedOne() {
        // Episode 2 was skipped, 3 is being watched again, 5 is queued, and 7 just arrived on the server.
        var list = episodes(played: 4, total: 6, queued: [5], inProgress: [3])
        list[1] = SmartDownloadPlanner.Episode(id: "e2", played: false, inProgress: false, isQueued: false)
        list.append(SmartDownloadPlanner.Episode(id: "e7", played: false, inProgress: false, isQueued: false))
        #expect(SmartDownloadPlanner.episodesToDownload(list, nextUpId: "e5", count: nil) == ["e2", "e3", "e6", "e7"])
    }

    @Test func startsFromAnEpisodeBeingWatchedAgain() {
        let list = episodes(played: 3, total: 6, queued: [2, 3], inProgress: [3])
        #expect(SmartDownloadPlanner.episodesToDownload(list, nextUpId: "e3", count: 2) == ["e4"])
    }

    @Test func passesOverANextUpFinishedHereFirst() {
        // The server still says e4 is next; it was finished offline and isn't synced yet.
        #expect(SmartDownloadPlanner.episodesToDownload(episodes(played: 4, total: 8), nextUpId: "e4", count: 2) == ["e5", "e6"])
    }
}

struct ResumeTests {
    @Test func resumesInsideTheVersion() {
        #expect(PlaybackResolver.resumable(40, length: 60) == 40)
        #expect(PlaybackResolver.resumable(40, length: nil) == 40)
    }

    @Test func startsOverPastTheEndOfAShorterVersion() {
        #expect(PlaybackResolver.resumable(40, length: 20) == nil)
        #expect(PlaybackResolver.resumable(19, length: 20) == nil)
        #expect(PlaybackResolver.resumable(0, length: 20) == nil)
        #expect(PlaybackResolver.resumable(nil, length: 20) == nil)
    }
}

struct LocalFileTests {
    @Test func findsSubtitlesNextToAVideo() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Sidecars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Movie.mkv", "Movie.srt", "Movie.en.forced.srt", "Movie.fre.sdh.ass", "Movie 2.srt", "Movie.txt"] {
            try Data().write(to: folder.appending(path: name))
        }
        let tracks = PlaybackResolver.sidecarSubtitles(for: folder.appending(path: "Movie.mkv"))
        #expect(tracks.map(\.name) == ["Movie.en.forced.srt", "Movie.fre.sdh.ass", "Movie.srt"])
        #expect(tracks.map(\.language) == ["en", "fre", nil])
        #expect(tracks.map(\.isForced) == [true, false, false])
        #expect(tracks.map(\.isHearingImpaired) == [false, true, false])
    }
}

@MainActor
struct TrackNamingTests {
    @Test func namesCodecsTheWayPeopleKnowThem() {
        #expect(PlayerModel.codecName("dca", profile: nil) == "DTS")
        #expect(PlayerModel.codecName("dts", profile: "DTS-HD MA") == "DTS-HD MA")
        #expect(PlayerModel.codecName("eac3", profile: "Dolby Digital Plus + Dolby Atmos") == "Dolby Digital Plus + Dolby Atmos")
        #expect(PlayerModel.codecName("truehd", profile: nil) == "Dolby TrueHD")
        #expect(PlayerModel.codecName("pcm_s24le", profile: nil) == "PCM")
        #expect(PlayerModel.codecName("hdmv_pgs_subtitle", profile: nil) == "PGS")
    }
}

