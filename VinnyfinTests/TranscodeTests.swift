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
    private func window(_ server: TranscodeServer, collected: Range<Int> = 0..<0, claimed: Set<Int> = [], needsInitCheck: Bool = false,
                        mayAskAhead: Bool = true, limit: Int? = nil) -> SegmentPlanner.Window {
        SegmentPlanner.window(segmentCount: 140, segmentDuration: 3, collected: IndexSet(integersIn: collected), claimed: claimed,
                              server: server, needsInitCheck: needsInitCheck, mayAskAhead: mayAskAhead, limit: limit)
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
        #expect(!window(.running(position: 30), collected: 0..<9).startsTranscode)
    }

    @Test func onceFinishedAsksForEverythingLeft() {
        #expect(window(.finished, collected: 0..<130).segments == Array(130..<140))
        #expect(window(.finished, collected: 0..<100, limit: 16).segments == Array(100..<116))
        #expect(window(.finished, collected: 0..<140).segments.isEmpty)
    }

    @Test func stoppedAsksForWhatItLeftThenTheFirstMissingAlone() {
        #expect(window(.stopped(madeUpTo: 30), collected: 0..<5).segments == [5, 6, 7, 8])
        // Stopped by itself: the last piece tells a transcode that finished from one that failed.
        let probe = window(.stopped(madeUpTo: 30), collected: 0..<9)
        #expect(probe == SegmentPlanner.Window(segments: [139], startsTranscode: true))
        var withLast = IndexSet(integersIn: 0..<9)
        withLast.insert(139)
        let restart = SegmentPlanner.window(segmentCount: 140, segmentDuration: 3, collected: withLast, claimed: [],
                                            server: .stopped(madeUpTo: 30), needsInitCheck: false, mayAskAhead: true)
        #expect(restart == SegmentPlanner.Window(segments: [9], startsTranscode: true))
        #expect(window(.stopped(madeUpTo: nil), collected: 0..<20) == SegmentPlanner.Window(segments: [20], startsTranscode: true))
        // One request starts it: none while another is out.
        #expect(window(.stopped(madeUpTo: nil), collected: 0..<20, claimed: [20]).segments.isEmpty)
        #expect(window(.gone, collected: 0..<20).segments == [20])
        #expect(window(.unknown).segments == [0])
    }

    @Test func checksTheInitSegmentWithOnePieceFirst() {
        #expect(window(.finished, collected: 0..<20, needsInitCheck: true).segments == [20])
    }

    @Test func takesBackPiecesThatWouldMoveTheTranscode() {
        #expect(SegmentPlanner.mayStay(14, segmentCount: 140, segmentDuration: 3, firstOutstanding: 9, server: .running(position: 30)))
        #expect(!SegmentPlanner.mayStay(15, segmentCount: 140, segmentDuration: 3, firstOutstanding: 9, server: .running(position: 30)))
        #expect(SegmentPlanner.mayStay(9, segmentCount: 140, segmentDuration: 3, firstOutstanding: 9, server: .gone))
        #expect(!SegmentPlanner.mayStay(10, segmentCount: 140, segmentDuration: 3, firstOutstanding: 9, server: .stopped(madeUpTo: nil)))
        #expect(SegmentPlanner.mayStay(100, segmentCount: 140, segmentDuration: 3, firstOutstanding: 9, server: .finished))
        #expect(SegmentPlanner.mayStay(139, segmentCount: 140, segmentDuration: 3, firstOutstanding: 9, server: .stopped(madeUpTo: 30)))
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

struct TranscodeServerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func state(position: Double?, seen: TimeInterval = 10, ping: TimeInterval = 5) -> TranscodeState {
        var state = Titles.state()
        state.serverPosition = position
        state.serverSeenAt = now.addingTimeInterval(-seen)
        state.lastPing = now.addingTimeInterval(-ping)
        return state
    }

    @Test func aSessionTheServerDoesntListIsGone() {
        #expect(TranscodeServer.interpret(sessionFound: false, transcoding: nil, state: Titles.state(), speed: nil, now: now) == .gone)
    }

    @Test func readsThePositionFromThePercentage() {
        let info = TranscodingInfo(completionPercentage: 50)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: info, state: Titles.state(), speed: nil, now: now)
            == .running(position: 210))
    }

    @Test func tellsFinishedFromStoppedOnceThePercentageIsGone() {
        let info = TranscodingInfo()
        // 400 s in at 2× ten seconds ago reaches the last piece (417 s).
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: info, state: state(position: 400), speed: 2, now: now)
            == .finished)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: info, state: state(position: 100), speed: 2, now: now)
            == .stopped(madeUpTo: 100))
        // Unpinged for over a minute: stopped by the server, which deletes its pieces, unless it
        // would have reached the end before then.
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: info, state: state(position: 100, seen: 300, ping: 200),
                                          speed: 0.5, now: now) == .stopped(madeUpTo: nil))
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: info, state: state(position: 100, seen: 300, ping: 200),
                                          speed: 2, now: now) == .finished)
    }

    @Test func goesByWhenTheServerWasFirstSeenQuiet() {
        let info = TranscodingInfo()
        // Last seen at 376 s going 5.4× ten seconds ago, quiet five seconds later: the percentage
        // lagged, and it reached the end.
        var nearEnd = state(position: 376, seen: 10, ping: 5)
        nearEnd.serverQuietAt = now.addingTimeInterval(-5)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: info, state: nearEnd, speed: 5.4, now: now) == .finished)
        // A transcode that stopped at 200 s stays stopped however long it's kept alive.
        var failed = state(position: 200, seen: 10, ping: 5)
        failed.serverQuietAt = now.addingTimeInterval(-5)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: info, state: failed, speed: 5.4, now: now)
            == .stopped(madeUpTo: 200))
        failed.lastPing = now.addingTimeInterval(95)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: info, state: failed, speed: 5.4, now: now.addingTimeInterval(100))
            == .stopped(madeUpTo: 200))
    }

    @Test func aQuietServerThatHadTheLastPieceFinished() {
        var state = state(position: 100, seen: 10, ping: 5)
        state.collected.insert(139)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: TranscodingInfo(), state: state, speed: nil, now: now) == .finished)
        // Unpinged past the server's patience, its pieces are deleted, whatever it got to.
        var lapsed = self.state(position: 100, seen: 100, ping: 90)
        lapsed.collected.insert(139)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: TranscodingInfo(), state: lapsed, speed: nil, now: now)
            == .stopped(madeUpTo: nil))
    }

    @Test func aFinishedTranscodeLastsUntilTheServersCleanup() {
        var state = Titles.state()
        state.serverFinishedAt = now.addingTimeInterval(-3600)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: TranscodingInfo(), state: state, speed: nil, now: now) == .finished)
        state.serverFinishedAt = now.addingTimeInterval(-TranscodeServer.keptFor - 1)
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: TranscodingInfo(), state: state, speed: nil, now: now)
            == .stopped(madeUpTo: nil))
    }

    @Test func aSessionThatNeverTranscodedHasNothingOnTheServer() {
        #expect(TranscodeServer.interpret(sessionFound: true, transcoding: nil, state: state(position: 400), speed: 2, now: now)
            == .stopped(madeUpTo: nil))
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
        state.serverFinishedAt = now.addingTimeInterval(-200)
        #expect(!state.isLapsed(at: now))
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
        #expect(job.nextRequests(running: [], limit: 4, serverTakesRanges: true).isEmpty)
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
        #expect(TranscodedDownloads.note(for: state, live: live) == "Server preparing 50%")
        live.activity = .preparing
        #expect(TranscodedDownloads.note(for: state, live: live) == "Asking the server for a transcode")
        live.activity = nil
        live.server = .finished
        #expect(TranscodedDownloads.note(for: state, live: live) == nil)
        live.throttle.observe(position: 300, downloadPosition: 0, now: .distantPast)
        live.throttle.observe(position: 300, downloadPosition: 0, now: .distantPast.addingTimeInterval(30))
        #expect(TranscodedDownloads.note(for: state, live: live) == "Server paused until the download catches up")
        state.repairs = [3: 0..<10]
        #expect(TranscodedDownloads.note(for: state, live: live) == "Mending 1 piece")
    }
}

// MARK: Fragmented MP4

/// Builds the boxes Jellyfin's fragmented MP4 is made of: an init segment with one video track
/// at 90 kHz, and pieces of three one-second samples.
private enum MP4 {
    static let timescale: UInt32 = 90_000

    static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    static func box(_ type: String, _ payload: Data) -> Data {
        uint32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
    }

    static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: Data) -> Data {
        box(type, uint32(UInt32(version) << 24 | flags) + payload)
    }

    static let header: Data = {
        let ftyp = box("ftyp", Data("iso5".utf8) + uint32(512) + Data("iso5iso6mp41".utf8))
        let tkhd = fullBox("tkhd", flags: 3, uint32(0) + uint32(0) + uint32(1) + Data(count: 68))
        let mdhd = fullBox("mdhd", uint32(0) + uint32(0) + uint32(timescale) + uint32(0) + uint32(0))
        let hdlr = fullBox("hdlr", uint32(0) + Data("vide".utf8) + Data(count: 12) + Data("Video\0".utf8))
        let trak = box("trak", tkhd + box("mdia", mdhd + hdlr))
        let trex = fullBox("trex", uint32(1) + uint32(1) + uint32(0) + uint32(0) + uint32(0))
        return ftyp + box("moov", trak + box("mvex", trex))
    }()

    /// A piece whose picture starts at `start` seconds, with `samples` one-second samples.
    static func piece(start: Double, samples: Int = 3, decodeTime: UInt64? = nil) -> Data {
        let sampleSize: UInt32 = 10
        let tfhd = fullBox("tfhd", flags: 0x020000, uint32(1))
        let tfdt = fullBox("tfdt", version: 1, uint64(decodeTime ?? UInt64(start * Double(timescale))))
        func trun(offset: UInt32) -> Data {
            var entries = Data()
            for _ in 0..<samples { entries += uint32(timescale) + uint32(sampleSize) }
            return fullBox("trun", flags: 0x000301, uint32(UInt32(samples)) + uint32(offset) + entries)
        }
        let mfhd = fullBox("mfhd", uint32(1))
        let moofLength = 8 + mfhd.count + 8 + tfhd.count + tfdt.count + trun(offset: 0).count
        let moof = box("moof", mfhd + box("traf", tfhd + tfdt + trun(offset: UInt32(moofLength + 8))))
        let mdat = box("mdat", Data(repeating: 0xAB, count: samples * Int(sampleSize)))
        return box("styp", Data("msdh".utf8) + uint32(0) + Data("msdhmsix".utf8)) + moof + mdat
    }
}

struct FragmentedMP4Tests {
    @Test func readsTheHeadersTracks() throws {
        let header = try FragmentedMP4.header(MP4.header)
        #expect(header.videoTrack == 1)
        #expect(header.tracks[1]?.timescale == MP4.timescale)
        #expect(header.length == Int64(MP4.header.count))
    }

    @Test func readsWhereAPiecesPictureLies() throws {
        let header = try FragmentedMP4.header(MP4.header)
        let data = MP4.piece(start: 30)
        let piece = try FragmentedMP4.piece(data, header: header)
        #expect(piece.videoStart == 30)
        #expect(piece.videoEnd == 33)
        #expect(piece.videoSamples == 3)
        #expect(piece.range == 0..<Int64(data.count))
        #expect(!piece.isEmpty)
    }

    @Test func refusesACutOffPieceAndTellsAnEmptyOne() throws {
        let header = try FragmentedMP4.header(MP4.header)
        let whole = MP4.piece(start: 3)
        #expect(throws: FragmentedMP4.Problem.self) { try FragmentedMP4.piece(whole.prefix(whole.count - 5), header: header) }
        #expect(try FragmentedMP4.piece(MP4.piece(start: 6, samples: 0), header: header).isEmpty)
    }

    @Test func readsADecodeTimeBelowZero() throws {
        let header = try FragmentedMP4.header(MP4.header)
        let piece = try FragmentedMP4.piece(MP4.piece(start: 0, decodeTime: UInt64(bitPattern: -1800)), header: header)
        #expect(piece.videoStart == -0.02)
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
}

struct TranscodeVerifierTests {
    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "TranscodeVerifierTests-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    private func check(_ pieces: [Data], expected: Int = 3, runtime: Double? = 9) throws -> TranscodeVerifier.Outcome {
        let url = try file(pieces.reduce(MP4.header, +))
        defer { try? FileManager.default.removeItem(at: url) }
        return TranscodeVerifier.checkStructure(of: url, header: MP4.header, expectedPieces: expected, segmentDuration: 3, runtime: runtime)
    }

    @Test func passesPiecesInOrderEndingWithTheTitle() throws {
        #expect(try check((0..<3).map { MP4.piece(start: Double($0) * 3) }) == .good(openSeconds: 0))
    }

    @Test func pointsAtADamagedOrMisplacedPiece() throws {
        var damaged = MP4.piece(start: 3)
        // Its moof claims to run past the end of the file.
        damaged.replaceSubrange(24..<28, with: MP4.uint32(0xFFFF_FFF0))
        guard case .badPieces(let bad, _) = try check([MP4.piece(start: 0), damaged, MP4.piece(start: 6)]) else {
            Issue.record("a damaged piece is found")
            return
        }
        #expect(Array(bad.keys) == [1])
        let start = MP4.header.count + MP4.piece(start: 0).count
        #expect(bad[1] == Int64(start)..<Int64(start + damaged.count))

        guard case .badPieces(let misplaced, _) = try check([MP4.piece(start: 0), MP4.piece(start: 30), MP4.piece(start: 6)]) else {
            Issue.record("a piece out of place is found")
            return
        }
        #expect(Array(misplaced.keys) == [1])
    }

    @Test func refusesAFileMissingPiecesOrEndingEarly() throws {
        guard case .unusable = try check([MP4.piece(start: 0), MP4.piece(start: 3)]) else {
            Issue.record("a missing piece makes the file unusable")
            return
        }
        guard case .unusable = try check((0..<3).map { MP4.piece(start: Double($0) * 3) }, runtime: 60) else {
            Issue.record("a file ending well before the title is unusable")
            return
        }
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
}
#endif
