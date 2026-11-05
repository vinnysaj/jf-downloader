#if !os(tvOS)
import Foundation
import Testing
@testable import vinnyfin

/// A title with a 4K HDR version and a 1080p one, as the server lists them.
private enum Titles {
    static let item = Samples.item("""
    {"Id":"t1","Name":"Harbor Lights","Type":"Movie","ProductionYear":2026,"RunTimeTicks":4200000000,
     "MediaSources":[
       {"Id":"uhd","Name":"2160p","Size":9000000000,"Bitrate":21000000,"RunTimeTicks":4200000000,"ETag":"tag1",
        "MediaStreams":[
          {"Type":"Video","Index":0,"Codec":"hevc","Height":2160,"Width":3840,"BitRate":20000000,"VideoRange":"HDR",
           "VideoRangeType":"HDR10","RealFrameRate":23.976},
          {"Type":"Audio","Index":1,"Codec":"ac3","Language":"eng","Channels":6,"BitRate":640000,"IsDefault":true},
          {"Type":"Audio","Index":2,"Codec":"dts","Language":"spa","Channels":6},
          {"Type":"Subtitle","Index":3,"Codec":"PGSSUB","Language":"eng"},
          {"Type":"Subtitle","Index":4,"Codec":"subrip","Language":"eng"},
          {"Type":"Subtitle","Index":5,"Codec":"subrip","Language":"fra","IsExternal":true}]},
       {"Id":"fhd","Name":"1080p","Size":4000000000,"Bitrate":8000000,"RunTimeTicks":4200000000,
        "MediaStreams":[
          {"Type":"Video","Index":0,"Codec":"h264","Height":1080,"Width":1920,"BitRate":7800000},
          {"Type":"Audio","Index":1,"Codec":"aac","Language":"eng","Channels":2,"BitRate":192000}]}]}
    """)

    static var uhd: MediaSource { item.mediaSources![0] }
    static var fullHD: MediaSource { item.mediaSources![1] }

    static func request(quality: VideoQuality = .hd, choices: TranscodeChoices = TranscodeChoices()) -> TranscodeRequest {
        TranscodeRequest(source: uhd, quality: quality, choices: choices)
    }

    static func state(segmentCount: Int = 140, quality: VideoQuality = .hd) -> TranscodeState {
        var state = TranscodeState(request: request(quality: quality))
        state.playSessionId = "session"
        state.playlistBase = "videos/t1/"
        state.segmentCount = segmentCount
        return state
    }
}

struct DownloadPlannerTests {
    private func plan(_ quality: VideoQuality, transcode: Bool, picked: MediaSource? = nil) -> DownloadPlan? {
        DownloadPlanner.plan(sources: Titles.item.mediaSources!, picked: picked, quality: quality, transcodeWhenNoneFits: transcode,
                             choices: TranscodeChoices())
    }

    @Test func takesTheBestVersionThatFitsUntouched() {
        #expect(plan(.fullHD, transcode: true) == .original(Titles.fullHD))
        #expect(plan(.uhd, transcode: true) == .original(Titles.uhd))
        #expect(plan(.original, transcode: true) == .original(Titles.uhd))
    }

    @Test func transcodesTheBestVersionOnlyWhenNoneFitsAndTheSettingIsOn() {
        #expect(plan(.hd, transcode: false) == .original(Titles.fullHD))
        let transcode = plan(.hd, transcode: true)
        #expect(transcode?.source == Titles.uhd)
        #expect(transcode?.transcode?.quality == .hd)
    }

    @Test func aVersionSomeonePickedDownloadsAsItIs() {
        #expect(plan(.hd, transcode: true, picked: Titles.uhd) == .original(Titles.uhd))
    }

    @Test func saysWhatItIsBeforeItsQueued() throws {
        let transcode = try #require(plan(.hd, transcode: true))
        let bytes = try #require(transcode.expectedBytes)
        #expect(transcode.summary == "Transcoded 720p · about \(DownloadEstimate.text(bytes))")
        #expect(plan(.fullHD, transcode: true)?.summary == "1080p · \(DownloadEstimate.text(4_000_000_000))")
    }

    @Test func estimatesABatchWithTranscodesAsAbout() throws {
        let transcode = try #require(plan(.hd, transcode: true))
        let estimate = DownloadEstimate([transcode, .original(Titles.fullHD)])
        #expect(estimate.transcodeCount == 1)
        #expect(estimate.bytes == transcode.expectedBytes! + 4_000_000_000)
        #expect(estimate.summary(noun: "movie", plural: "movies") == "2 movies, about \(DownloadEstimate.text(estimate.bytes))")
    }
}

struct TranscodeRequestTests {
    @Test func asksForTheQualitysSizeAndBitrateWithTheAudioOnTop() {
        let request = Titles.request()
        #expect(request.maxHeight == 720)
        #expect(request.maxWidth == 1280)
        #expect(request.videoBitrate == VideoQuality.hd.transcodeBitrate)
        #expect(request.audioStreamIndex == 1)
        #expect(request.copiesAudio)
        #expect(request.audioBitrate == 640_000)
        #expect(request.maxStreamingBitrate == request.videoBitrate + 640_000)
        #expect(request.segmentLength == 3)
        #expect(request.isHDR)
        #expect(request.estimatedBytes == Int64(Double(request.maxStreamingBitrate) * 420 / 8))
    }

    @Test func takesTheAudioInTheSettingsLanguageAndConvertsWhatAnMP4DoesntCarry() {
        let request = Titles.request(choices: TranscodeChoices(audioLanguage: "spa"))
        #expect(request.audioStreamIndex == 2)
        #expect(!request.copiesAudio)
        #expect(request.audioBitrate == 384_000)
    }

    @Test func burnsInOnePictureSubtitleOrNone() {
        #expect(Titles.request(choices: TranscodeChoices(burnIn: .stream(3))).burnedSubtitleIndex == 3)
        // A text stream is never burned in: it comes as a file beside the download.
        #expect(Titles.request(choices: TranscodeChoices(burnIn: .stream(4))).burnedSubtitleIndex == nil)
        #expect(Titles.request(choices: TranscodeChoices(burnIn: .none)).burnedSubtitleIndex == nil)
        #expect(Titles.request(choices: TranscodeChoices(burnIn: .automatic, subtitleMode: .off)).burnedSubtitleIndex == nil)
    }

    @Test func namesTheVersionAudioAndSubtitlesOutright() {
        let none = Titles.request().playbackInfo(userId: "u", mediaSourceId: "uhd")
        #expect(none.MediaSourceId == "uhd")
        #expect(none.AudioStreamIndex == 1)
        #expect(none.SubtitleStreamIndex == -1)
        #expect(none.StartTimeTicks == 0)
        #expect(!none.EnableDirectPlay && !none.EnableDirectStream && none.EnableTranscoding)
        #expect(none.AllowAudioStreamCopy)
        let burned = Titles.request(choices: TranscodeChoices(audioLanguage: "spa", burnIn: .stream(3)))
            .playbackInfo(userId: "u", mediaSourceId: "uhd")
        #expect(burned.SubtitleStreamIndex == 3)
        #expect(!burned.AllowAudioStreamCopy)
    }

    @Test func keepsTheSmallerBitrateOfASmallSource() {
        let request = TranscodeRequest(source: Titles.fullHD, quality: .sd, choices: TranscodeChoices())
        #expect(request.videoBitrate == VideoQuality.sd.transcodeBitrate)
        let small = TranscodeRequest(source: Titles.fullHD, quality: .uhd, choices: TranscodeChoices())
        #expect(small.videoBitrate == 7_800_000)
    }
}

struct DownloadPolicyTests {
    private func decode(_ json: String) throws -> DownloadPolicy {
        try JSONDecoder().decode(DownloadPolicy.self, from: Data(json.utf8))
    }

    @Test func aPermissionTheServerLeavesOutAllows() throws {
        let policy = try decode("{}")
        #expect(policy.refusal(for: .original(Titles.fullHD), serverName: "Home") == nil)
        #expect(policy.refusal(for: .transcode(Titles.uhd, Titles.request()), serverName: "Home") == nil)
    }

    @Test func refusesEveryDownloadWithoutDownloadPermission() throws {
        let policy = try decode(#"{"EnableContentDownloading":false}"#)
        #expect(policy.refusal(for: .original(Titles.fullHD), serverName: "Home")?.contains("Allow Media Downloading") == true)
        #expect(policy.downloadRefusal(serverName: "Home")?.hasPrefix("Home doesn't allow downloads") == true)
    }

    @Test func refusesATranscodeWithoutTranscodingPermission() throws {
        let noVideo = try decode(#"{"EnableVideoPlaybackTranscoding":false}"#)
        #expect(noVideo.refusal(for: .original(Titles.fullHD), serverName: "Home") == nil)
        #expect(noVideo.refusal(for: .transcode(Titles.uhd, Titles.request()), serverName: "Home")?
            .contains("Allow Video Playback That Requires Transcoding") == true)
        let noConversion = try decode(#"{"EnableMediaConversion":false}"#)
        #expect(noConversion.refusal(for: .transcode(Titles.uhd, Titles.request()), serverName: "Home")?
            .contains("Allow Media Conversion") == true)
        let noAudio = try decode(#"{"EnableAudioPlaybackTranscoding":false}"#)
        #expect(noAudio.refusal(for: .transcode(Titles.uhd, Titles.request()), serverName: "Home") == nil)
        let converted = Titles.request(choices: TranscodeChoices(audioLanguage: "spa"))
        #expect(noAudio.refusal(for: .transcode(Titles.uhd, converted), serverName: "Home")?
            .contains("Allow Audio Playback That Requires Transcoding") == true)
    }
}

struct SegmentPlannerTests {
    /// The title runs 420 s: 140 pieces of 3 s.
    private func window(_ server: TranscodeServer, collected: some Sequence<Int> = 0..<0, claimed: Set<Int> = [], isHeld: Bool = false,
                        mayAskAhead: Bool = true, limit: Int? = nil) -> SegmentPlanner.Window {
        SegmentPlanner.window(segmentCount: 140, segmentDuration: 3, runtime: 420, collected: IndexSet(collected), claimed: claimed,
                              server: server, isHeld: isHeld, mayAskAhead: mayAskAhead, limit: limit)
    }

    @Test func keepsWellInsideTheServersRestartWindow() {
        #expect(SegmentPlanner.aheadLimit(segmentDuration: 3) == 4)
        #expect(SegmentPlanner.aheadLimit(segmentDuration: 6) == 2)
        #expect(SegmentPlanner.aheadLimit(segmentDuration: 12) == 1)
    }

    @Test func whileTranscodingAsksForWhatsMadeThenAFewAhead() {
        // At 30 s the server is making piece 10; pieces up to 8 are done.
        #expect(window(.running(position: 30), collected: 0..<5, claimed: [5]).segments == [6, 7, 8, 9])
        #expect(window(.running(position: 30), collected: 0..<9).segments == [9, 10, 11, 12])
        #expect(window(.running(position: 30), collected: 0..<9, mayAskAhead: false).segments == [])
        // Never 8 or more past the server.
        let ahead = window(.running(position: 30), collected: 0..<10).segments
        #expect(ahead.allSatisfy { $0 <= 10 + 4 })
        #expect(!window(.running(position: 30), collected: 0..<9).isProbe)
    }

    /// Found waiting on the server once it ended: everything left, in batches in front.
    @Test func asksForEveryPieceTheServerKept() {
        #expect(window(.ended, collected: 0..<130, isHeld: true).segments == Array(130..<140))
        #expect(window(.ended, collected: 0..<100, isHeld: true, limit: 16).segments == Array(100..<116))
        #expect(window(.ended, collected: 0..<140, isHeld: true).segments.isEmpty)
    }

    /// Not transcoding, and not known to have the pieces left (it finished, failed, was stopped,
    /// or restarted): one piece alone, which comes from what it kept or starts it there, once
    /// nothing else is out. Never the last piece to find out: it isn't where a failed transcode
    /// would start again.
    @Test func otherwiseAsksForTheFirstMissingPieceAlone() {
        let probe = SegmentPlanner.Window(segments: [20], isProbe: true)
        #expect(window(.ended, collected: 0..<20) == probe)
        #expect(window(.gone, collected: 0..<20) == probe)
        #expect(window(.unknown) == SegmentPlanner.Window(segments: [0], isProbe: true))
        #expect(window(.ended, collected: 0..<20, claimed: [20]).segments.isEmpty)
        #expect(window(.ended, collected: 0..<20, claimed: [25]).segments.isEmpty)
        #expect(window(.ended, collected: Array(0..<20) + [139]) == probe)
    }

    /// The server starts no later than 5 s before the end, numbering what it makes from the
    /// piece asked for all the same: a piece missing there is got by starting it earlier.
    @Test func startsTheServerNoLaterThanItStartsInPlace() {
        #expect(SegmentPlanner.restartPiece(firstOutstanding: 139, segmentDuration: 3, runtime: 420) == 138)
        #expect(SegmentPlanner.restartPiece(firstOutstanding: 137, segmentDuration: 3, runtime: 420) == 137)
        #expect(SegmentPlanner.restartPiece(firstOutstanding: 199, segmentDuration: 3, runtime: 598.8) == 197)
        #expect(SegmentPlanner.restartPiece(firstOutstanding: 3, segmentDuration: 3, runtime: nil) == 3)
        // Already here, it's asked for again to start the server where it makes the rest in place.
        #expect(window(.ended, collected: 0..<139) == SegmentPlanner.Window(segments: [138], isProbe: true))
    }

    /// A source whose clock starts 1.48 s late, with subtitles burned in, makes a transcode that
    /// much shorter than the 41 pieces listed: the last one, asked for, comes from a transcode
    /// started too late to put it in place, which is all asking can get.
    @Test func takesALastPieceTheServerCantPutInPlaceAsTheEnd() {
        #expect(SegmentPlanner.endsBefore(40, segmentCount: 41, segmentDuration: 3, runtime: 121.51))
        #expect(!SegmentPlanner.endsBefore(39, segmentCount: 41, segmentDuration: 3, runtime: 121.51))
        // One a restart can start in place is asked for again.
        #expect(!SegmentPlanner.endsBefore(40, segmentCount: 41, segmentDuration: 3, runtime: 130))
        #expect(!SegmentPlanner.endsBefore(40, segmentCount: 41, segmentDuration: 3, runtime: nil))
    }

    @Test func takesBackPiecesThatWouldMoveTheTranscode() {
        func mayStay(_ segment: Int, _ server: TranscodeServer, firstOutstanding: Int? = 9, isHeld: Bool = false) -> Bool {
            SegmentPlanner.mayStay(segment, segmentDuration: 3, runtime: 420, firstOutstanding: firstOutstanding, server: server,
                                   isHeld: isHeld)
        }
        #expect(mayStay(14, .running(position: 30)))
        #expect(!mayStay(15, .running(position: 30)))
        #expect(mayStay(9, .gone))
        #expect(!mayStay(10, .ended))
        #expect(mayStay(100, .ended, isHeld: true))
        #expect(mayStay(138, .ended, firstOutstanding: 139))
        #expect(!mayStay(139, .ended, firstOutstanding: 139))
    }

    @Test func handsTheSessionWhatItCanFetchBeforeTheServerStops() {
        #expect(SegmentPlanner.fetchable(within: 60, bytesPerSecond: nil, bytesPerSegment: 2_000_000) == 2)
        #expect(SegmentPlanner.fetchable(within: 60, bytesPerSecond: 1_000_000, bytesPerSegment: 2_000_000) == 30)
    }

    @Test func leavesOutALastPieceShorterThanAFrame() {
        #expect(SegmentPlanner.usableCount(durations: [3, 3, 0.021], frameRate: 23.976) == 2)
        #expect(SegmentPlanner.usableCount(durations: [3, 3, 1], frameRate: 23.976) == 3)
        #expect(SegmentPlanner.usableCount(durations: [], frameRate: nil) == 0)
    }
}

/// The server says no more than whether it knows the device and, while ffmpeg runs, how far it is.
struct TranscodeServerTests {
    /// A piece asked for alone at the start, or the init segment, says nothing once the server has
    /// been seen transcoding: stopped later, whether it kept the pieces is asked again.
    @Test func forgetsWhatWasAskedForAloneOnceTheServerIsSeenTranscoding() {
        var live = TranscodedDownloads.Live()
        live.probedAt = .now
        live.observe(.ended)
        #expect(live.probedAt != nil)
        live.observe(.running(position: 30))
        #expect(live.probedAt == nil)
        #expect(live.seenRunning)
        live.observe(.ended)
        #expect(live.server == .ended)
        // Down, it can't say it's transcoding until it knows the device again: what came since it
        // went down is waited on.
        live.observe(.gone)
        live.probedAt = .now
        live.observe(.gone)
        #expect(live.probedAt != nil)
    }

    @Test func aSessionTheServerDoesntListIsGone() {
        #expect(TranscodeServer.interpret(sessionFound: false, transcoding: nil, runtime: 420) == .gone)
    }

    @Test func readsThePositionFromThePercentage() {
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: TranscodingInfo(completionPercentage: 50), runtime: 420)
            == .running(position: 210))
    }

    @Test func withoutAPercentageItHasEnded() {
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: TranscodingInfo(), runtime: 420) == .ended)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: nil, runtime: 420) == .ended)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: TranscodingInfo(completionPercentage: 50), runtime: nil) == .ended)
    }
}

struct ThrottleWatchTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func watch(_ sightings: [(seconds: TimeInterval, position: Double, download: Double)]) -> ThrottleWatch {
        var watch = ThrottleWatch()
        for sighting in sightings {
            watch.observe(position: sighting.position, downloadPosition: sighting.download, now: start.addingTimeInterval(sighting.seconds))
        }
        return watch
    }

    @Test func noticesTheServerWaitingForTheDownload() {
        #expect(!watch([(0, 300, 100)]).isThrottled)
        #expect(watch([(0, 300, 100), (30, 300.2, 100)]).isThrottled)
        // Running free again, it gets ever further ahead.
        #expect(!watch([(0, 300, 100), (30, 300.2, 100), (40, 400, 110)]).isThrottled)
    }

    @Test func noticesTheServerKeepingPaceWithABurstyDownload() {
        // Four pieces land at once, and the server runs on past its mark before its next check.
        let paced = watch([(0, 220, 140), (5, 220, 140), (10, 220, 152), (15, 250, 152), (20, 250, 152), (25, 250, 152)])
        #expect(paced.isThrottled)
        let free = watch([(0, 200, 140), (15, 260, 150), (30, 320, 160)])
        #expect(!free.isThrottled)
    }

    @Test func aServerSlowerThanTheDownloadNeverStandsStill() {
        let slow = watch([(0, 200, 100), (5, 206, 110), (10, 212, 120), (15, 218, 130), (20, 224, 140), (25, 230, 150)])
        #expect(!slow.isThrottled)
    }

    @Test func aServerStandingCloseToTheDownloadIsntPacingIt() {
        var watch = ThrottleWatch()
        watch.observe(position: 120, downloadPosition: 100, now: start)
        watch.observe(position: 120, downloadPosition: 100, now: start.addingTimeInterval(60))
        #expect(!watch.isThrottled)
        watch.observe(position: nil, downloadPosition: 100, now: start.addingTimeInterval(61))
        #expect(watch == ThrottleWatch())
    }
}

struct TranscodeStateTests {
    @Test func oneInitCheckCoversALapse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var state = Titles.state()
        state.lastPing = now.addingTimeInterval(-10)
        #expect(!state.isLapsed(at: now))
        state.lastPing = now.addingTimeInterval(-90)
        #expect(state.isLapsed(at: now))
        // Checked after the server could have let go: the pieces after count.
        state.initCheckedAt = now.addingTimeInterval(-5)
        #expect(!state.isLapsed(at: now))
        state.initCheckedAt = now.addingTimeInterval(-100)
        #expect(state.isLapsed(at: now))
        // Pieces the server kept don't lapse: it only stops transcodes that run.
        state.heldSince = now.addingTimeInterval(-200)
        #expect(!state.isLapsed(at: now))
    }

    @Test func piecesTheServerKeptLastUntilItsCleanup() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var state = Titles.state()
        #expect(!state.isHeld(at: now))
        state.heldSince = now.addingTimeInterval(-3600)
        #expect(state.isHeld(at: now))
        state.heldSince = now.addingTimeInterval(-TranscodeServer.keptFor - 1)
        #expect(!state.isHeld(at: now))
    }

    /// Started again three times in a row about the same place, having run in between: it's
    /// failing there.
    @Test func countsRestartsAboutTheSamePlace() {
        var state = Titles.state()
        #expect(state.noteRestart(at: 300, seenRunning: false) == 1)
        #expect(state.noteRestart(at: 303, seenRunning: true) == 2)
        // Not seen running since: the last start may not have happened yet.
        #expect(state.noteRestart(at: 303, seenRunning: false) == 1)
        #expect(state.noteRestart(at: 300, seenRunning: true) == 2)
        #expect(state.noteRestart(at: 306, seenRunning: true) == 3)
        #expect(state.noteRestart(at: 900, seenRunning: true) == 1)
        state.reset()
        #expect(state.stopsAtSamePlace == 1)
    }

    @Test func appendsOnlyTheCheckedRunAfterTheFile() {
        var state = Titles.state(segmentCount: 6)
        state.collected = IndexSet([0, 1, 2, 4])
        #expect(state.appendable == 0..<3)
        state.unchecked = IndexSet([1])
        #expect(state.appendable == 0..<1)
        state.unchecked = []
        state.appended = 3
        #expect(state.appendable == 3..<3)
        state.collected.insert(3)
        #expect(state.appendable == 3..<5)
    }

    @Test func isCollectedOnceEveryPieceIsInTheFileAndChecked() {
        var state = Titles.state(segmentCount: 3)
        state.collected = IndexSet(integersIn: 0..<3)
        state.appended = 3
        #expect(state.isCollected)
        state.repairs = [1: 100..<200]
        #expect(!state.isCollected)
        state.repairs = [:]
        state.unchecked = [2]
        #expect(!state.isCollected)
    }

    @Test func estimatesFromWhatThePiecesWeighOnceAFewAreIn() throws {
        var state = Titles.state()
        let asked = try #require(state.request.estimatedBytes)
        #expect(state.expectedBytes == asked)
        // Never less than what's on disk.
        state.fileLength = asked * 2
        #expect(state.expectedBytes == asked * 2)
        // A quarter in (105 of 420 seconds): what the pieces weigh takes over.
        state.collected = IndexSet(integersIn: 0..<35)
        state.fileLength = 1_050_000
        #expect(state.expectedBytes == 4_200_000)
    }

    @Test func startingOverKeepsTheRequestAndTheCount() {
        var state = Titles.state()
        state.collected = IndexSet(integersIn: 0..<10)
        state.appended = 10
        state.fileLength = 1000
        state.startOvers = 1
        state.reset()
        #expect(state == {
            var fresh = TranscodeState(request: Titles.request())
            fresh.startOvers = 1
            return fresh
        }())
    }

    @Test func pacesOnTheFurthestPieceCollected() {
        var state = Titles.state(segmentCount: 4)
        state.finalSegmentDuration = 1.5
        state.collected = IndexSet([0, 1])
        #expect(state.downloadPosition == 6)
        state.collected.insert(3)
        #expect(state.downloadPosition == 10.5)
        #expect(state.collectedSeconds == 7.5)
    }

    @Test func listsTheTranscodedFilesStreamsAsTheFileNumbersThem() throws {
        var state = TranscodeState(request: Titles.request(choices: TranscodeChoices(audioLanguage: "spa")))
        state.variant = #"BANDWIDTH=6400000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720"#
        let job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, state.request))
        let english = URL(filePath: "/tmp/en.srt")
        let french = URL(filePath: "/tmp/fr.srt")
        let (item, files) = state.playback(of: job.item, subtitleFiles: [4: english, 5: french])
        let source = try #require(item?.mediaSources?.first)
        #expect(item?.mediaSources?.count == 1)
        #expect(source.container == "mp4")
        #expect(source.videoStream?.index == 0)
        #expect(source.videoStream?.codec == "h264")
        #expect(source.videoStream?.height == 720)
        #expect(source.audioStreams.map(\.index) == [1])
        #expect(source.audioStreams.first?.codec == "aac")
        #expect(source.audioStreams.first?.language == "spa")
        #expect(source.defaultAudioStreamIndex == 1)
        #expect(source.subtitleStreams.map(\.index) == [2, 3])
        #expect(files == [2: english, 3: french])
    }
}

struct HLSPlaylistTests {
    @Test func readsTheVariantAndItsAttributes() {
        let master = HLSPlaylist("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=6400000,AVERAGE-BANDWIDTH=6400000,VIDEO-RANGE=SDR,CODECS="avc1.640028,ac-3",RESOLUTION=1280x720,FRAME-RATE=23.976
        main.m3u8?DeviceId=d&MediaSourceId=uhd&VideoBitrate=5760000&AudioBitrate=640000&api_key=old
        """)
        #expect(master.variantURI?.hasPrefix("main.m3u8?") == true)
        #expect(HLSPlaylist.attribute("CODECS", in: master.variantAttributes ?? "") == "avc1.640028,ac-3")
        #expect(HLSPlaylist.attribute("RESOLUTION", in: master.variantAttributes ?? "") == "1280x720")
        #expect(HLSPlaylist.queryValue("videobitrate", in: master.variantURI ?? "") == "5760000")
    }

    @Test func listsEveryPieceAfterTheMap() {
        let main = HLSPlaylist("""
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="hls1/main/-1.mp4?runtimeTicks=0&actualSegmentLengthTicks=0"
        #EXTINF:3.000000, nodesc
        hls1/main/0.mp4?runtimeTicks=0&actualSegmentLengthTicks=30000000
        #EXTINF:3.000000, nodesc
        hls1/main/1.mp4?runtimeTicks=30000000&actualSegmentLengthTicks=30000000
        #EXTINF:0.021000, nodesc
        hls1/main/2.mp4?runtimeTicks=60000000&actualSegmentLengthTicks=210000
        #EXT-X-ENDLIST
        """)
        #expect(main.mapURI == "hls1/main/-1.mp4?runtimeTicks=0&actualSegmentLengthTicks=0")
        #expect(main.targetDuration == 3)
        #expect(main.segments.map(\.duration) == [3, 3, 0.021])
        #expect(main.segments.last?.uri.hasPrefix("hls1/main/2.mp4") == true)
        #expect(main.isComplete)
    }
}

struct TransferTagSegmentTests {
    @Test func aPieceRoundTripsThroughTheTaskDescription() {
        let id = UUID()
        let tag = TransferTag(jobId: id, segment: 12)
        #expect(tag.encoded == "\(id.uuidString) s12")
        #expect(TransferTag(encoded: tag.encoded) == tag)
        #expect(TransferTag(encoded: "\(id.uuidString) s-1") == nil)
        #expect(!tag.isWholeFile)
        #expect(TransferTag(jobId: id, range: nil).isWholeFile)
    }

    @Test func piecesOverlapOnlyThemselves() {
        let id = UUID()
        #expect(TransferTag(jobId: id, segment: 1).overlaps(TransferTag(jobId: id, segment: 1)))
        #expect(!TransferTag(jobId: id, segment: 1).overlaps(TransferTag(jobId: id, segment: 2)))
        #expect(!TransferTag(jobId: id, segment: 1).overlaps(TransferTag(jobId: UUID(), segment: 1)))
    }

    @Test func plansTheWindowLeavingOutPiecesUnderWay() {
        let job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, Titles.request()))
        let running = [TransferTag(jobId: job.id, segment: 1)]
        let plan = DownloadJob.plan([job], running: running, segmentWindows: [job.id: [0, 1, 2, 3]], budget: 10, queuingAhead: false)
        #expect(plan == [0, 2, 3].map { TransferTag(jobId: job.id, segment: $0) })
        let limited = DownloadJob.plan([job], running: [], segmentWindows: [job.id: [0, 1, 2, 3]], budget: 2, queuingAhead: false)
        #expect(limited.count == 2)
        #expect(job.nextRequests(running: [], limit: 4).isEmpty)
    }

    @Test func countsPiecesBesideTheFileAsBytesSoFar() {
        var job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, Titles.request()))
        job.transcode?.fileLength = 1000
        job.transcode?.sideBytes = 500
        #expect(DownloadJob.bytesSoFar([job], held: [(job.id, 200)])[job.id] == 1700)
        #expect(job.displayTotalBytes == job.transcode?.expectedBytes)
        #expect(!job.isTransferComplete)
        job.transcode?.isVerified = true
        #expect(job.isTransferComplete)
    }
}

@MainActor
struct SegmentResponseTests {
    private func response(_ status: Int, type: String? = "video/mp4", length: Int64? = nil, range: String? = nil) -> ResponseInfo {
        ResponseInfo(statusCode: status, contentRange: range, contentType: type, contentLength: length)
    }

    @Test func takesAWholePiece() {
        #expect(TranscodedDownloads.evaluate(response(200, length: 1000), stagedSize: 1000, segment: 3) == .body)
        #expect(TranscodedDownloads.evaluate(response(206, range: "bytes 500-999/1000"), stagedSize: 1000, segment: 3) == .body)
    }

    @Test func retriesWhatsCutShortOrNotThereYet() {
        guard case .retry = TranscodedDownloads.evaluate(response(200, length: 1000), stagedSize: 600, segment: 3) else {
            Issue.record("a cut-off piece is retried")
            return
        }
        guard case .retry(.server(let message)) = TranscodedDownloads.evaluate(response(404), stagedSize: 0, segment: 3) else {
            Issue.record("a piece the server hasn't made is retried")
            return
        }
        #expect(message.contains("404"))
        guard case .retry = TranscodedDownloads.evaluate(response(200, type: "application/json", length: 20), stagedSize: 20, segment: 3)
        else {
            Issue.record("an error page is retried")
            return
        }
        guard case .retry = TranscodedDownloads.evaluate(response(206, range: "bytes 0-499/1000"), stagedSize: 500, segment: 3) else {
            Issue.record("a partial answer short of the end is retried")
            return
        }
    }

    @Test func givesUpOnARefusal() {
        guard case .giveUp = TranscodedDownloads.evaluate(response(401), stagedSize: 0, segment: 3),
              case .giveUp = TranscodedDownloads.evaluate(response(403), stagedSize: 0, segment: 3)
        else {
            Issue.record("a refusal stops the download")
            return
        }
        guard case .retry = TranscodedDownloads.evaluate(response(429), stagedSize: 0, segment: 3) else {
            Issue.record("too many requests is retried")
            return
        }
    }

    @Test func saysWhatTheServerIsDoing() {
        var state = Titles.state()
        var live = TranscodedDownloads.Live(server: .running(position: 210))
        #expect(TranscodedDownloads.note(for: state, live: live, serverIsCurrent: true) == "Server preparing 50%")
        live.activity = .preparing
        #expect(TranscodedDownloads.note(for: state, live: live, serverIsCurrent: true) == "Asking the server for a transcode")
        live.activity = nil
        live.server = .ended
        #expect(TranscodedDownloads.note(for: state, live: live, serverIsCurrent: true) == nil)
        live.throttle.observe(position: 300, downloadPosition: 0, now: .distantPast)
        live.throttle.observe(position: 300, downloadPosition: 0, now: .distantPast.addingTimeInterval(30))
        #expect(TranscodedDownloads.note(for: state, live: live, serverIsCurrent: true) == "Server paused until the download catches up")
        state.repairs = [3: 0..<10]
        #expect(TranscodedDownloads.note(for: state, live: live, serverIsCurrent: true) == "Mending 1 piece")
    }

    /// A download waiting its turn behind another isn't asked about: what its server said when it
    /// was last in hand isn't said as what it does now.
    @Test func saysNothingOfWhatTheServerSaidLongAgo() {
        var live = TranscodedDownloads.Live(server: .running(position: 210))
        #expect(TranscodedDownloads.note(for: Titles.state(), live: live, serverIsCurrent: false) == nil)
        live.throttle.observe(position: 300, downloadPosition: 0, now: .distantPast)
        live.throttle.observe(position: 300, downloadPosition: 0, now: .distantPast.addingTimeInterval(30))
        #expect(TranscodedDownloads.note(for: Titles.state(), live: live, serverIsCurrent: false) == nil)
        live.activity = .checkingInit
        #expect(TranscodedDownloads.note(for: Titles.state(), live: live, serverIsCurrent: false) == "Checking the server's transcode")
    }
}

@MainActor
private final class TranscodeHostStub: TranscodeHost {
    var jobs: [DownloadJob]
    var isInFront = true
    var isPausedForPlayback = false
    var isPlaybackTranscoding = false
    var changes = 0

    init(_ jobs: [DownloadJob]) { self.jobs = jobs }

    func changeJob(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    func transcodesChanged() { changes += 1 }
    func startOver(_ id: UUID, because reason: String) {}
    func stopJob(_ id: UUID, because message: String) {}
    func outOfSpace(_ id: UUID, error: any Error) {}
}

@MainActor
struct ServerDownTests {
    /// A piece answered 503, or refused: the pieces out are taken back but the first missing,
    /// which is asked for alone once the server is back, so its transcode starts there rather
    /// than at whichever piece reaches it first, and again at each earlier one.
    @Test func takesBackEveryPieceButTheFirstMissingWhenTheServerGoesDown() throws {
        var job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, Titles.request()))
        var state = Titles.state()
        state.collected = IndexSet(0..<20)
        state.heldSince = .now
        job.transcode = state
        let host = TranscodeHostStub([job])
        let base = FileManager.default.temporaryDirectory.appending(path: "ServerDownTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = try #require(UserDefaults(suiteName: "ServerDownTests-\(UUID().uuidString)"))
        let transcodes = TranscodedDownloads(accounts: AccountStore(defaults: defaults),
                                             storage: DownloadStorage(finished: base.appending(path: "Finished"), root: base.appending(path: "Root")))
        transcodes.host = host
        #expect(transcodes.mayKeep(25, of: host.jobs[0]))
        transcodes.serverDown(job.id)
        #expect(transcodes.live[job.id]?.server == .gone)
        #expect(host.jobs[0].transcode?.heldSince == nil)
        #expect(host.changes == 1)
        #expect(transcodes.mayKeep(20, of: host.jobs[0]))
        #expect(!transcodes.mayKeep(21, of: host.jobs[0]))
        #expect(!transcodes.mayKeep(25, of: host.jobs[0]))
        // Down already: nothing more to do.
        transcodes.serverDown(job.id)
        #expect(host.changes == 1)
    }
}

// MARK: Fragmented MP4

/// Builds the boxes Jellyfin's fragmented MP4 is made of: an init segment with one track at
/// 90 kHz, its samples H.264 unless said otherwise, and pieces of one-second samples of ten
/// bytes: a six-byte NAL unit after its four-byte length, or an AC-3 frame.
private enum MP4 {
    static let timescale: UInt32 = 90_000
    static let sampleSize = 10

    enum Entry {
        case avc, ac3
    }

    static func uint16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    static func box(_ type: String, _ payload: Data) -> Data {
        uint32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
    }

    static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: Data) -> Data {
        box(type, uint32(UInt32(version) << 24 | flags) + payload)
    }

    static let header = makeHeader()

    /// `editMediaTime` gives the track an edit list starting there, as for pictures whose
    /// composition starts after their decoding.
    static func makeHeader(entry: Entry = .avc, editMediaTime: UInt32? = nil) -> Data {
        let ftyp = box("ftyp", Data("iso5".utf8) + uint32(512) + Data("iso5iso6mp41".utf8))
        let mvhd = fullBox("mvhd", uint32(0) + uint32(0) + uint32(1000) + uint32(0) + Data(count: 80))
        let tkhd = fullBox("tkhd", flags: 3, uint32(0) + uint32(0) + uint32(1) + Data(count: 68))
        let edts = editMediaTime.map { box("edts", fullBox("elst", uint32(1) + uint32(0) + uint32($0) + uint32(0x0001_0000))) } ?? Data()
        let mdhd = fullBox("mdhd", uint32(0) + uint32(0) + uint32(timescale) + uint32(0) + uint32(0))
        let hdlr = fullBox("hdlr", uint32(0) + Data("vide".utf8) + Data(count: 12) + Data("Video\0".utf8))
        let sampleEntry = switch entry {
        case .avc:
            // Six reserved bytes and the data reference, 70 bytes of picture fields, then avcC:
            // four-byte NAL lengths, no parameter sets.
            box("avc1", Data(count: 6) + uint16(1) + Data(count: 70) + box("avcC", Data([1, 0x64, 0, 0x28, 0xFF, 0xE0, 0])))
        case .ac3:
            box("ac-3", Data(count: 6) + uint16(1) + Data(count: 20))
        }
        let stbl = box("stbl", fullBox("stsd", uint32(1) + sampleEntry))
        let trak = box("trak", tkhd + edts + box("mdia", mdhd + hdlr + box("minf", stbl)))
        let trex = fullBox("trex", uint32(1) + uint32(1) + uint32(0) + uint32(0) + uint32(0))
        return ftyp + box("moov", mvhd + trak + box("mvex", trex))
    }

    /// A sample's ten bytes.
    static func sample(_ entry: Entry) -> Data {
        switch entry {
        case .avc: Data([0, 0, 0, 6, 0x65]) + Data(repeating: 0xAB, count: 5)
        case .ac3: Data([0x0B, 0x77]) + Data(repeating: 0xAB, count: 8)
        }
    }

    /// A piece whose picture starts at `start` seconds, with `samples` one-second samples, the
    /// first a keyframe; `extraBytes` more in its media data than its samples take.
    static func piece(start: Double, samples: Int = 3, decodeTime: Int64? = nil, entry: Entry = .avc, extraBytes: Int = 0) -> Data {
        let tfhd = fullBox("tfhd", flags: 0x020000, uint32(1))
        let tfdt = fullBox("tfdt", version: 1, uint64(UInt64(bitPattern: decodeTime ?? Int64((start * Double(timescale)).rounded()))))
        func trun(offset: UInt32) -> Data {
            var entries = Data()
            for index in 0..<samples {
                entries += uint32(timescale) + uint32(UInt32(sampleSize)) + uint32(index == 0 ? 0x0200_0000 : 0x0101_0000)
            }
            return fullBox("trun", flags: 0x000701, uint32(UInt32(samples)) + uint32(offset) + entries)
        }
        let mfhd = fullBox("mfhd", uint32(1))
        let moofLength = 8 + mfhd.count + 8 + tfhd.count + tfdt.count + trun(offset: 0).count
        let moof = box("moof", mfhd + box("traf", tfhd + tfdt + trun(offset: UInt32(moofLength + 8))))
        let mdat = box("mdat", (0..<samples).reduce(Data()) { data, _ in data + sample(entry) } + Data(repeating: 0, count: extraBytes))
        return box("styp", Data("msdh".utf8) + uint32(0) + Data("msdhmsix".utf8)) + moof + mdat
    }

    /// Where a piece's media data starts within it.
    static func mediaStart(of piece: Data) -> Int {
        piece.range(of: Data("mdat".utf8))!.upperBound - piece.startIndex
    }
}

struct FragmentedMP4Tests {
    @Test func readsTheHeadersTracks() throws {
        let header = try FragmentedMP4.header(MP4.header)
        #expect(header.videoTrack == 1)
        #expect(header.tracks[1]?.timescale == MP4.timescale)
        #expect(header.tracks[1]?.format == .nalUnits(lengthSize: 4))
        #expect(header.movieTimescale == 1000)
        #expect(header.length == Int64(MP4.header.count))
        #expect(try FragmentedMP4.header(MP4.makeHeader(entry: .ac3)).tracks[1]?.format == .ac3Frames)
        #expect(try FragmentedMP4.header(MP4.makeHeader(editMediaTime: 1800)).tracks[1]?.presentationOffset == 1800)
    }

    @Test func readsWhereAPiecesPictureLiesAndEverySample() throws {
        let header = try FragmentedMP4.header(MP4.header)
        let data = MP4.piece(start: 30)
        let piece = try FragmentedMP4.piece(data, header: header)
        #expect(piece.videoStart == 30)
        #expect(piece.videoEnd == 33)
        #expect(piece.videoSamples == 3)
        #expect(piece.range == 0..<Int64(data.count))
        #expect(!piece.isEmpty)
        let run = try #require(piece.runs.first)
        #expect(piece.runs.count == 1)
        #expect(run.decodeTime == 30 * Int64(MP4.timescale))
        #expect(run.samples.map(\.size) == [10, 10, 10])
        #expect(run.samples.map(\.duration) == [MP4.timescale, MP4.timescale, MP4.timescale])
        #expect(run.samples.map(\.isSync) == [true, false, false])
        #expect(run.dataOffset == MP4.mediaStart(of: data))
        #expect(piece.sampleCount == 3)
        #expect(piece.largestSample == 10)
        let shifted = piece.shifted(by: 1000)
        #expect(shifted.range == 1000..<Int64(1000 + data.count))
        #expect(shifted.runs.first?.dataOffset == run.dataOffset + 1000)
    }

    @Test func refusesACutOffPieceAndTellsAnEmptyOne() throws {
        let header = try FragmentedMP4.header(MP4.header)
        let whole = MP4.piece(start: 3)
        #expect(throws: FragmentedMP4.Problem.self) { try FragmentedMP4.piece(whole.prefix(whole.count - 5), header: header) }
        #expect(try FragmentedMP4.piece(MP4.piece(start: 6, samples: 0), header: header).isEmpty)
    }

    @Test func readsADecodeTimeBelowZero() throws {
        let header = try FragmentedMP4.header(MP4.header)
        let piece = try FragmentedMP4.piece(MP4.piece(start: 0, decodeTime: -1800), header: header)
        #expect(piece.videoStart == -0.02)
    }

    @Test func refusesMediaDataTheSamplesDontFill() throws {
        let header = try FragmentedMP4.header(MP4.header)
        #expect(throws: FragmentedMP4.Problem.self) { try FragmentedMP4.piece(MP4.piece(start: 3, extraBytes: 4), header: header) }
    }

    /// Damage that keeps every box's length: a NAL unit's length that no longer adds up to its
    /// sample, a NAL unit header with its forbidden bit set, an AC-3 frame without its sync word.
    @Test func refusesSamplesWhoseInsidesDontHoldTogether() throws {
        let header = try FragmentedMP4.header(MP4.header)
        var length = MP4.piece(start: 3)
        let media = MP4.mediaStart(of: length)
        length[length.startIndex + media + MP4.sampleSize + 3] = 9
        #expect(throws: FragmentedMP4.Problem.self) { try FragmentedMP4.piece(length, header: header) }
        var forbidden = MP4.piece(start: 3)
        forbidden[forbidden.startIndex + media + 4] = 0xE5
        #expect(throws: FragmentedMP4.Problem.self) { try FragmentedMP4.piece(forbidden, header: header) }

        let audioHeader = try FragmentedMP4.header(MP4.makeHeader(entry: .ac3))
        var frame = MP4.piece(start: 3, entry: .ac3)
        #expect(try FragmentedMP4.piece(frame, header: audioHeader).sampleCount == 3)
        frame[frame.startIndex + MP4.mediaStart(of: frame) + 2 * MP4.sampleSize] = 0x0C
        #expect(throws: FragmentedMP4.Problem.self) { try FragmentedMP4.piece(frame, header: audioHeader) }
    }

    @Test func findsThePiecesAfterADamagedOne() throws {
        let pieces = (0..<3).map { MP4.piece(start: Double($0) * 3) }
        var joined = MP4.header + pieces[0] + pieces[1] + pieces[2]
        // The second piece's moof claims to run past the end of the file.
        let moof = MP4.header.count + pieces[0].count + 24
        joined.replaceSubrange(moof..<(moof + 4), with: MP4.uint32(0xFFFF_FFF0))
        let starts = FragmentedMP4.pieceStarts(in: joined, from: MP4.header.count)
        #expect(starts == [MP4.header.count, MP4.header.count + pieces[0].count, MP4.header.count + pieces[0].count + pieces[1].count])
    }

    /// Past a damaged box, the next piece is looked for a block at a time, as in a file read in
    /// stretches: one whose styp straddles two blocks is found.
    @Test func findsAPieceStartAcrossTheBlocksItReads() throws {
        let first = MP4.piece(start: 0)
        let second = MP4.piece(start: 3)
        let damaged = MP4.header.count + first.count
        // The search starts 5 bytes into the damaged box and reads 1 MiB blocks: the second
        // piece's styp type begins 2 bytes before the first block ends.
        let fillerEnd = damaged + 5 + (1 << 20) - 2 - 4
        let joined = MP4.header + first + MP4.uint32(0xFFFF_FFF0) + Data("junk".utf8) + Data(count: fillerEnd - damaged - 8) + second
        var reads: [Range<Int>] = []
        let starts = try FragmentedMP4.pieceStarts(count: joined.count, from: MP4.header.count) { range in
            reads.append(range)
            return joined.subdata(in: range)
        }
        #expect(starts == [MP4.header.count, fillerEnd])
        #expect(reads.contains { $0.count == 1 << 20 })
    }
}

struct TranscodeVerifierTests {
    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "TranscodeVerifierTests-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    private func check(_ pieces: [Data], expected: Int = 3, header: Data = MP4.header) throws -> TranscodeVerifier.StructureCheck {
        let url = try file(pieces.reduce(header, +))
        defer { try? FileManager.default.removeItem(at: url) }
        return TranscodeVerifier.checkStructure(of: url, header: MP4.header, expectedPieces: expected, segmentDuration: 3)
    }

    @Test func readsEveryPieceInOrder() throws {
        let pieces = (0..<3).map { MP4.piece(start: Double($0) * 3) }
        guard case .whole(let structure) = try check(pieces) else {
            Issue.record("pieces in order pass")
            return
        }
        let starts = [MP4.header.count, MP4.header.count + pieces[0].count, MP4.header.count + pieces[0].count + pieces[1].count]
        #expect(structure.pieces.map(\.range.lowerBound) == starts.map(Int64.init))
        #expect(structure.pieces.last?.runs.first?.dataOffset == MP4.header.count + pieces[0].count + pieces[1].count + MP4.mediaStart(of: pieces[2]))
        #expect(structure.fileLength == Int64(pieces.reduce(MP4.header, +).count))
    }

    /// A source whose clock starts 1.48 s in makes pieces that start there: each piece's place
    /// counts from the first's.
    @Test func countsEachPlaceFromWhereTheFirstPieceStarts() throws {
        guard case .whole = try check((0..<3).map { MP4.piece(start: 1.48 + Double($0) * 3) }) else {
            Issue.record("pieces in place from a late start pass")
            return
        }
        guard case .failed(.badPieces(let misplaced, _)) = try check([1.48, 31.48, 7.48].map { MP4.piece(start: $0) }) else {
            Issue.record("a piece out of place is found")
            return
        }
        #expect(Array(misplaced.keys) == [1])
    }

    @Test func pointsAtADamagedPiece() throws {
        var damaged = MP4.piece(start: 3)
        // Its moof claims to run past the end of the file.
        damaged.replaceSubrange(24..<28, with: MP4.uint32(0xFFFF_FFF0))
        guard case .failed(.badPieces(let bad, _)) = try check([MP4.piece(start: 0), damaged, MP4.piece(start: 6)]) else {
            Issue.record("a damaged piece is found")
            return
        }
        #expect(Array(bad.keys) == [1])
        let start = MP4.header.count + MP4.piece(start: 0).count
        #expect(bad[1] == Int64(start)..<Int64(start + damaged.count))

        var first = MP4.piece(start: 0)
        // The first piece's own start is damaged: it runs up to the second's.
        first.replaceSubrange(0..<4, with: MP4.uint32(0xFFFF_FFF0))
        guard case .failed(.badPieces(let firstBad, _)) = try check([first, MP4.piece(start: 3), MP4.piece(start: 6)]) else {
            Issue.record("a damaged first piece is found")
            return
        }
        #expect(firstBad[0] == Int64(MP4.header.count)..<Int64(MP4.header.count + first.count))
    }

    /// Wrong in a way no piece can be blamed for: the job stops, keeping its pieces.
    @Test func namesNoPieceForAFileMissingOneOrNotStartingWithTheInitSegment() throws {
        guard case .failed(.unmendable) = try check([MP4.piece(start: 0), MP4.piece(start: 3)]) else {
            Issue.record("a missing piece names none")
            return
        }
        var otherHeader = MP4.header
        otherHeader[otherHeader.startIndex + 8] = 0
        guard case .failed(.unmendable) = try check((0..<3).map { MP4.piece(start: Double($0) * 3) }, header: otherHeader) else {
            Issue.record("a file not starting with the init segment names no piece")
            return
        }
    }
}

struct FlattenedMP4Tests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "FlattenedMP4Tests-\(UUID().uuidString)")

    /// Joins `pieces` after `header`, indexes them, and returns the indexed file's bytes and the
    /// index.
    private func flatten(_ pieces: [Data], header: Data = MP4.header) throws -> (data: Data, index: FlattenedMP4.Index, joined: Data) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let joined = pieces.reduce(header, +)
        let partial = folder.appending(path: "partial.mp4")
        let flat = folder.appending(path: "joined.mp4")
        try joined.write(to: partial)
        let parsed = try FragmentedMP4.header(header)
        var offset = header.count
        let read = try pieces.map { data in
            defer { offset += data.count }
            return try FragmentedMP4.piece(data, header: parsed).shifted(by: offset)
        }
        let index = try FlattenedMP4.index(header: header, parsed: parsed, pieces: read, fileLength: Int64(joined.count))
        let length = try FlattenedMP4.write(index, from: partial, to: flat)
        let data = try Data(contentsOf: flat)
        #expect(length == Int64(data.count))
        // The joined file stays as it was.
        #expect(try Data(contentsOf: partial) == joined)
        return (data, index, joined)
    }

    private func box(_ path: [String], in data: Data) throws -> FragmentedMP4.Box {
        var range = 0..<data.count
        var found: FragmentedMP4.Box?
        for type in path {
            found = try FragmentedMP4.boxes(in: data, range: range).first { $0.type == type }
            guard let found else { throw FragmentedMP4.Problem(message: "No \(type) box.") }
            range = found.payload
        }
        return try #require(found)
    }

    /// The 32-bit fields of a full box after its version and flags.
    private func fields(_ box: FragmentedMP4.Box, in data: Data) -> [UInt32] {
        stride(from: box.payload.lowerBound + 4, to: box.payload.upperBound, by: 4).map { data.uint32(at: $0) }
    }

    @Test func indexesEverySampleWhereItAlreadyLies() throws {
        let pieces = (0..<3).map { MP4.piece(start: Double($0) * 3) }
        let (data, index, joined) = try flatten(pieces)
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try FragmentedMP4.boxes(in: data, range: 0..<data.count)
        #expect(top.map(\.type) == ["ftyp", "mdat", "moov"])
        // The media data spans everything that was there, the pieces' bytes untouched.
        #expect(top[1].range == index.mdatOffset..<joined.count)
        #expect(data.subdata(in: (index.mdatOffset + 16)..<joined.count) == joined.subdata(in: (index.mdatOffset + 16)..<joined.count))
        let stbl = ["moov", "trak", "mdia", "minf", "stbl"]
        #expect(fields(try box(stbl + ["stsz"], in: data), in: data) == [10, 9])
        #expect(fields(try box(stbl + ["stts"], in: data), in: data) == [1, 9, MP4.timescale])
        #expect(fields(try box(stbl + ["stss"], in: data), in: data) == [3, 1, 4, 7])
        #expect(fields(try box(stbl + ["stsc"], in: data), in: data) == [1, 1, 3, 1])
        let offsets = fields(try box(stbl + ["stco"], in: data), in: data)
        #expect(offsets.count == 4)
        for offset in offsets.dropFirst() {
            #expect(data.subdata(in: Int(offset)..<(Int(offset) + 5)) == Data([0, 0, 0, 6, 0x65]))
        }
        #expect(try box(stbl + ["stsd"], in: data).range.count > 0)
        #expect(throws: FragmentedMP4.Problem.self) { try box(["moov", "mvex"], in: data) }
        // Nine seconds, from 0.
        let elst = try box(["moov", "trak", "edts", "elst"], in: data)
        #expect(data.byte(at: elst.payload.lowerBound) == 1)
        #expect(data.uint32(at: elst.payload.lowerBound + 4) == 1)
        #expect(data.uint64(at: elst.payload.lowerBound + 8) == 9000)
        #expect(data.uint64(at: elst.payload.lowerBound + 16) == 0)
        let mvhd = try box(["moov", "mvhd"], in: data)
        #expect(data.byte(at: mvhd.payload.lowerBound) == 1)
        #expect(data.uint64(at: mvhd.payload.lowerBound + 24) == 9000)
        let mdhd = try box(["moov", "trak", "mdia", "mdhd"], in: data)
        #expect(data.uint64(at: mdhd.payload.lowerBound + 24) == 9 * UInt64(MP4.timescale))
        #expect(index.origin == 0)
    }

    /// A source whose clock starts 1.5 s in: the file starts at its first picture, and an edit
    /// list starting the pictures after their decoding keeps doing so.
    @Test func putsTheFirstPictureAtTheStart() throws {
        let (late, lateIndex, _) = try flatten((0..<3).map { MP4.piece(start: 1.5 + Double($0) * 3) })
        #expect(lateIndex.origin == 1.5)
        let elst = try box(["moov", "trak", "edts", "elst"], in: late)
        #expect(late.uint64(at: elst.payload.lowerBound + 16) == 0)
        let (shifted, _, _) = try flatten((0..<3).map { MP4.piece(start: 1.5 + Double($0) * 3) }, header: MP4.makeHeader(editMediaTime: 1800))
        defer { try? FileManager.default.removeItem(at: folder) }
        let shiftedEdit = try box(["moov", "trak", "edts", "elst"], in: shifted)
        #expect(shifted.uint64(at: shiftedEdit.payload.lowerBound + 16) == 1800)
        #expect(shifted.uint64(at: shiftedEdit.payload.lowerBound + 8) == 8980)
    }

    /// A gap between two pieces lengthens the sample before it, so every sample keeps its time.
    @Test func keepsEverySampleAtItsTimeAcrossAGap() throws {
        let (data, _, _) = try flatten([0.0, 3, 7].map { MP4.piece(start: $0) })
        defer { try? FileManager.default.removeItem(at: folder) }
        let stts = try box(["moov", "trak", "mdia", "minf", "stbl", "stts"], in: data)
        #expect(fields(stts, in: data) == [3, 5, MP4.timescale, 1, 2 * MP4.timescale, 3, MP4.timescale])
    }
}

struct TranscodeAssemblyTests {
    private func makeStorage() throws -> DownloadStorage {
        let base = FileManager.default.temporaryDirectory.appending(path: "TranscodeAssemblyTests-\(UUID().uuidString)")
        let storage = DownloadStorage(finished: base.appending(path: "Finished"), root: base.appending(path: "Root"))
        try storage.prepare()
        return storage
    }

    private func keep(_ data: Data, _ index: Int, for jobId: UUID, in storage: DownloadStorage) throws {
        let staged = storage.staging.appending(path: UUID().uuidString)
        try data.write(to: staged)
        try storage.keepSegment(staged, index, for: jobId)
    }

    @Test func joinsPiecesInOrderWhicheverCameFirst() async throws {
        let storage = try makeStorage()
        let jobId = UUID()
        let pieces = (0..<3).map { MP4.piece(start: Double($0) * 3) }
        try storage.beginTranscodedFile(header: MP4.header, for: jobId)
        try keep(pieces[2], 2, for: jobId, in: storage)
        try keep(pieces[0], 0, for: jobId, in: storage)
        try keep(pieces[1], 1, for: jobId, in: storage)
        #expect(storage.transcodeSideBytes(for: jobId) == Int64(MP4.header.count + pieces.reduce(0) { $0 + $1.count }))
        let afterTwo = try await storage.appendSegments(0..<2, for: jobId, after: Int64(MP4.header.count))
        // A run that appended the last piece but ended before saying so: the next one appends it again, once.
        _ = try await storage.appendSegments(2..<3, for: jobId, after: afterTwo)
        let length = try await storage.appendSegments(2..<3, for: jobId, after: afterTwo)
        let joined = try Data(contentsOf: storage.partialFile(for: jobId))
        #expect(joined == MP4.header + pieces[0] + pieces[1] + pieces[2])
        #expect(length == Int64(joined.count))
        try storage.removeSegments(0..<3, for: jobId)
        #expect(storage.transcodeSideBytes(for: jobId) == Int64(MP4.header.count))
    }

    @Test func mendsAPieceInPlace() async throws {
        let storage = try makeStorage()
        let jobId = UUID()
        let pieces = (0..<3).map { MP4.piece(start: Double($0) * 3) }
        var damaged = pieces[1]
        damaged.removeLast(7)
        try storage.beginTranscodedFile(header: MP4.header + pieces[0] + damaged + pieces[2], for: jobId)
        try keep(pieces[1], 1, for: jobId, in: storage)
        let start = Int64(MP4.header.count + pieces[0].count)
        let length = try await storage.replaceSegment(1, for: jobId, at: start..<(start + Int64(damaged.count)))
        let mended = try Data(contentsOf: storage.partialFile(for: jobId))
        #expect(mended == MP4.header + pieces[0] + pieces[1] + pieces[2])
        #expect(length == Int64(mended.count))
    }

    /// What's published is the indexed file, however far the last run got after the check
    /// passed: before it took the joined file's place, or after.
    @Test func publishesTheIndexedFile() throws {
        let storage = try makeStorage()
        var job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, Titles.request()))
        let indexed = Data("indexed".utf8) + Data(repeating: 1, count: 100)
        try storage.beginTranscodedFile(header: MP4.header + MP4.piece(start: 0), for: job.id)
        try indexed.write(to: storage.joinedFile(for: job.id))
        job.totalBytes = Int64(indexed.count)
        let path = try storage.publish(job)
        #expect(try Data(contentsOf: storage.finished.appending(path: path)) == indexed)
        #expect(!FileManager.default.fileExists(atPath: storage.joinedFile(for: job.id).path))

        var adopted = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, Titles.request()))
        try storage.beginTranscodedFile(header: MP4.header, for: adopted.id)
        try indexed.write(to: storage.joinedFile(for: adopted.id))
        try storage.adoptJoinedFile(for: adopted.id)
        adopted.totalBytes = Int64(indexed.count)
        #expect(try Data(contentsOf: storage.finished.appending(path: try storage.publish(adopted))) == indexed)
    }

    @Test func refusesToPublishAFileShorterThanTheDownload() throws {
        let storage = try makeStorage()
        var job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, Titles.request()))
        try storage.beginTranscodedFile(header: MP4.header, for: job.id)
        job.totalBytes = Int64(MP4.header.count + 1)
        #expect(throws: CocoaError.self) { try storage.publish(job) }
    }
}
#endif
