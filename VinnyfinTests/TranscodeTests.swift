#if !os(tvOS)
import AetherEngine
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

    static func state(quality: VideoQuality = .hd) -> TranscodeState {
        var state = TranscodeState(request: request(quality: quality))
        state.playSessionId = "session"
        state.playlistBase = "videos/t1/"
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
        // The 4K version is HDR, and encoded again at 720p it comes out SDR.
        #expect(transcode.summary == "Transcoded 720p SDR · about \(DownloadEstimate.text(bytes))")
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

    /// The server keeps HDR only where it copies the picture; encoding it again, it maps it to
    /// SDR, which the version line says before the download starts.
    @Test func saysAnHDRSourceEncodedAgainComesOutSDR() {
        let request = Titles.request()
        #expect(request.copiesPicture == false)
        #expect(request.label == "Transcoded 720p SDR")
        // A 4K HDR10 picture within a 4K request's size and bitrate is copied as it is, HDR and all.
        let roomy = TranscodeRequest(source: Titles.uhd, quality: .uhd, choices: TranscodeChoices())
        #expect(roomy.copiesPicture == true)
        #expect(roomy.label == "Transcoded 4K")
        #expect(!TranscodeRequest.fitsAsItIs(Titles.uhd.videoStream, maxWidth: 1920, maxHeight: 1080, bitrate: 20_000_000,
                                             sourceBitrate: 20_000_000))
        // Burning subtitles in encodes the picture again.
        #expect(Titles.request(choices: TranscodeChoices(burnIn: .stream(3))).copiesPicture == false)
        let small = TranscodeRequest(source: Titles.fullHD, quality: .uhd, choices: TranscodeChoices())
        #expect(small.copiesPicture == true)
        #expect(small.label == "Transcoded 4K")
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
    /// The file takes piece `next` next; the server is making `serverPiece`.
    private func window(_ server: TranscodeServer, next: Int = 0, end: Int? = nil, mends: [Int] = [], collected: some Sequence<Int> = 0..<0,
                        claimed: Set<Int> = [], serverPiece: Int? = nil, lastPiece: Int? = 139, isHeld: Bool = false,
                        mayAskAhead: Bool = true, limit: Int? = nil) -> SegmentPlanner.Window {
        SegmentPlanner.window(next: next, end: end, mends: mends, collected: IndexSet(collected), claimed: claimed, server: server,
                              serverPiece: serverPiece, lastPiece: lastPiece, isHeld: isHeld, mayAskAhead: mayAskAhead, pieceLength: 3,
                              limit: limit)
    }

    @Test func keepsWellInsideTheServersRestartWindow() {
        #expect(SegmentPlanner.aheadLimit(pieceLength: 3) == 4)
        #expect(SegmentPlanner.aheadLimit(pieceLength: 6) == 2)
        #expect(SegmentPlanner.aheadLimit(pieceLength: 12) == 1)
    }

    /// Counted from where the file ends, at the length the server cuts them, not from the start:
    /// after a restart the server numbers its pieces from the one asked for.
    @Test func placesThePieceTheServerMakesFromTheFilesEnd() {
        #expect(SegmentPlanner.piece(at: 3631.5, next: 210, contentEnd: 3600.2, pieceLength: 3) == 220)
        #expect(SegmentPlanner.piece(at: 3600.2, next: 210, contentEnd: 3600.2, pieceLength: 3) == 210)
    }

    @Test func whileTranscodingAsksForWhatsMadeThenAFewAhead() {
        // The server is making piece 10; pieces up to 8 are done.
        #expect(window(.running(position: 30), next: 5, collected: 0..<5, claimed: [5], serverPiece: 10).segments == [6, 7, 8, 9])
        #expect(window(.running(position: 30), next: 9, collected: 0..<9, serverPiece: 10).segments == [9, 10, 11, 12])
        #expect(window(.running(position: 30), next: 9, collected: 0..<9, serverPiece: 10, mayAskAhead: false).segments == [])
        // Never 8 or more past the server.
        let ahead = window(.running(position: 30), next: 10, collected: 0..<10, serverPiece: 10).segments
        #expect(ahead.allSatisfy { $0 <= 10 + 4 })
        #expect(!window(.running(position: 30), next: 9, collected: 0..<9, serverPiece: 10).isProbe)
    }

    /// Found waiting on the server once it ended: everything left up to the last piece the
    /// title's length surely makes, in batches in front; past it, one at a time.
    @Test func asksForEveryPieceTheServerKept() {
        #expect(window(.ended, next: 130, collected: 0..<130, isHeld: true).segments == Array(130...139))
        #expect(window(.ended, next: 100, collected: 0..<100, isHeld: true, limit: 16).segments == Array(100..<116))
        #expect(window(.ended, next: 140, collected: 0..<140, isHeld: true).segments == [140])
        #expect(window(.ended, next: 140, collected: 0..<140, claimed: [140], isHeld: true).segments.isEmpty)
    }

    /// Not transcoding, and not known to have the pieces left: the first missing piece alone,
    /// which comes from what it kept or starts it there, once nothing else is out.
    @Test func otherwiseAsksForTheFirstMissingPieceAlone() {
        let probe = SegmentPlanner.Window(segments: [20], isProbe: true)
        #expect(window(.ended, next: 20, collected: 0..<20) == probe)
        #expect(window(.gone, next: 20, collected: 0..<20) == probe)
        #expect(window(.unknown) == SegmentPlanner.Window(segments: [0], isProbe: true))
        #expect(window(.ended, next: 20, collected: 0..<20, claimed: [20]).segments.isEmpty)
        #expect(window(.ended, next: 20, collected: 0..<20, claimed: [25]).segments.isEmpty)
        #expect(window(.ended, next: 20, collected: Array(0..<20) + [139]) == probe)
    }

    /// Once the end is known nothing past it is asked for; pieces to mend the file come first.
    @Test func asksForNothingPastTheEndAndMendsFirst() {
        #expect(window(.ended, next: 140, end: 140, collected: 0..<140, isHeld: true).segments.isEmpty)
        #expect(window(.ended, next: 140, end: 140, mends: [7], collected: Array(0..<7) + Array(8..<140)) ==
            SegmentPlanner.Window(segments: [7], isProbe: true))
        #expect(window(.running(position: 30), next: 140, end: 140, mends: [7, 3], collected: [0], serverPiece: 10).segments == [3, 7])
        // From the pieces the server kept, with the whole file in.
        #expect(window(.ended, next: 139, end: 139, mends: [32], collected: Array(0..<32) + Array(33..<139), isHeld: true).segments == [32])
    }

    @Test func takesBackPiecesThatWouldMoveTheTranscode() {
        func mayStay(_ segment: Int, _ server: TranscodeServer, firstOutstanding: Int? = 9, serverPiece: Int? = 10, isHeld: Bool = false)
            -> Bool {
            SegmentPlanner.mayStay(segment, firstOutstanding: firstOutstanding, server: server, serverPiece: serverPiece, lastPiece: 139,
                                   isHeld: isHeld, pieceLength: 3)
        }
        #expect(mayStay(14, .running(position: 30)))
        #expect(!mayStay(15, .running(position: 30)))
        #expect(mayStay(9, .gone))
        #expect(!mayStay(10, .ended))
        #expect(mayStay(100, .ended, isHeld: true))
        #expect(!mayStay(141, .ended, firstOutstanding: 140, isHeld: true))
        #expect(mayStay(140, .ended, firstOutstanding: 140, isHeld: true))
    }

    @Test func handsTheSessionWhatItCanFetchBeforeTheServerStops() {
        #expect(SegmentPlanner.fetchable(within: 60, bytesPerSecond: nil, bytesPerSegment: 2_000_000) == 2)
        #expect(SegmentPlanner.fetchable(within: 60, bytesPerSecond: 1_000_000, bytesPerSegment: 2_000_000) == 30)
    }
}

/// A piece's request asks the server, should it have to start its transcode to make it, to start
/// where the piece takes over from the file, and pieces past the playlist's are asked for all
/// the same: it lists them at a length it doesn't cut them at.
struct SegmentAddressTests {
    private let playlist = HLSPlaylist("""
    #EXTM3U
    #EXT-X-MAP:URI="hls1/main/-1.mp4?DeviceId=d&runtimeTicks=0&actualSegmentLengthTicks=0"
    #EXTINF:3.003000, nodesc
    hls1/main/0.mp4?DeviceId=d&PlaySessionId=p&runtimeTicks=0&actualSegmentLengthTicks=30030000
    #EXTINF:3.003000, nodesc
    hls1/main/1.mp4?DeviceId=d&PlaySessionId=p&runtimeTicks=30030000&actualSegmentLengthTicks=30030000
    #EXT-X-ENDLIST
    """)

    @Test func asksTheServerToStartWhereThePieceTakesOver() {
        #expect(TranscodedDownloads.segmentURI(1, in: playlist, startTicks: 29_822_916)
            == "hls1/main/1.mp4?DeviceId=d&PlaySessionId=p&actualSegmentLengthTicks=30030000&runtimeTicks=29822916")
    }

    @Test func asksForPiecesPastTheList() {
        #expect(TranscodedDownloads.segmentURI(201, in: playlist, startTicks: 6_000_000_000)
            == "hls1/main/201.mp4?DeviceId=d&PlaySessionId=p&actualSegmentLengthTicks=30030000&runtimeTicks=6000000000")
        #expect(TranscodedDownloads.segmentURI(-1, in: playlist, startTicks: 0) == nil)
        #expect(TranscodedDownloads.segmentURI(0, in: HLSPlaylist("#EXTM3U"), startTicks: 0) == nil)
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

    /// Stopped three times in a row with the file ending at the same place, having run in
    /// between: it's failing there.
    @Test func countsStopsWithTheFileEndingAtTheSamePlace() {
        var state = Titles.state()
        #expect(state.noteStop(at: 300.0417, seenRunning: false) == 1)
        #expect(state.noteStop(at: 300.0417, seenRunning: true) == 2)
        // Not seen running since: the last start may not have happened yet.
        #expect(state.noteStop(at: 300.0417, seenRunning: false) == 1)
        #expect(state.noteStop(at: 300.0417, seenRunning: true) == 2)
        #expect(state.noteStop(at: 300.0417, seenRunning: true) == 3)
        // The file got further: a new place.
        #expect(state.noteStop(at: 303.0447, seenRunning: true) == 1)
        state.reset()
        #expect(state.stopsAtSamePlace == 1)
    }

    @Test func isCollectedOnceTheEndIsInTheFileAndChecked() {
        var state = Titles.state()
        state.collected = IndexSet(integersIn: 0..<3)
        state.appended = 3
        // Where the transcode ends isn't known yet.
        #expect(!state.isCollected)
        state.pieceCount = 3
        #expect(state.isCollected)
        state.mends = [1: TranscodeState.Mend(bytes: 100..<200, start: 3, end: 6)]
        #expect(!state.isCollected)
        state.mends = nil
        state.unchecked = [2]
        #expect(!state.isCollected)
    }

    @Test func numbersThePiecesInTheFileLeavingOutTheSkipped() {
        var state = Titles.state()
        state.appended = 8
        state.skipped = [3, 4]
        #expect(Array(state.piecesInFile) == [0, 1, 2, 5, 6, 7])
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
        state.appended = 35
        state.timelineOrigin = 1.5
        state.contentEnd = 106.5
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

    /// The server paces itself to the end of the file's picture, from the title's start.
    @Test func pacesOnWhereTheFileEnds() {
        var state = Titles.state()
        #expect(state.downloadPosition == 0)
        state.timelineOrigin = 36_001.4
        state.contentEnd = 36_031.43
        state.appended = 10
        #expect(abs(state.downloadPosition - 30.03) < 1e-9)
        state.collected = IndexSet(integersIn: 0..<10).union([11, 12])
        #expect(abs(state.collectedSeconds - 36.03) < 1e-9)
    }

    /// The version line follows what the server made, once its init segment says.
    @Test func labelsTheDownloadByWhatTheTranscodeIs() {
        var state = Titles.state()
        #expect(state.label == "Transcoded 720p SDR")
        state.videoRangeType = "HDR10"
        #expect(state.label == "Transcoded 720p HDR10")
        state.videoRangeType = "SDR"
        #expect(state.label == "Transcoded 720p SDR")
        var job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, state.request))
        job.transcode = state
        #expect(job.versionLabel == "Transcoded 720p SDR")
        #expect(job.versionName == "Transcoded 720p SDR")
        let plain = TranscodeState(request: TranscodeRequest(source: Titles.fullHD, quality: .sd, choices: TranscodeChoices()))
        #expect(plain.label == "Transcoded 480p")
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

    /// The player is told the picture's range as the transcode has it, not the source's.
    @Test func playsThePictureInTheRangeTheTranscodeHas() throws {
        var state = Titles.state()
        state.videoRangeType = "SDR"
        let job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, state.request))
        let video = try #require(state.playback(of: job.item, subtitleFiles: [:]).0?.mediaSources?.first?.videoStream)
        #expect(video.videoRange == "SDR")
        #expect(video.videoRangeType == "SDR")
        state.videoRangeType = "HDR10"
        let kept = try #require(state.playback(of: job.item, subtitleFiles: [:]).0?.mediaSources?.first?.videoStream)
        #expect(kept.videoRange == "HDR")
        #expect(kept.videoRangeType == "HDR10")
    }
}

/// The server says no more than whether it knows the device and, while ffmpeg runs, how far it is.
struct TranscodeServerTests {
    /// A piece asked for alone at the start, or the init segment, says nothing once the server has
    /// been seen transcoding: stopped later, whether it kept the pieces is asked again.
    @Test func forgetsWhatWasAskedForAloneOnceTheServerIsSeenTranscoding() {
        var live = TranscodedDownloads.Live()
        live.probedAt = .now
        live.observe(.ended, pieceLength: 3)
        #expect(live.probedAt != nil)
        live.observe(.running(position: 30), pieceLength: 3)
        #expect(live.probedAt == nil)
        #expect(live.seenRunning)
        live.observe(.ended, pieceLength: 3)
        #expect(live.server == .ended)
        // Down, it can't say it's transcoding until it knows the device again: what came since it
        // went down is waited on.
        live.observe(.gone, pieceLength: 3)
        live.probedAt = .now
        live.observe(.gone, pieceLength: 3)
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
        state.mends = [3: TranscodeState.Mend(bytes: 0..<10, start: 9, end: 12)]
        #expect(TranscodedDownloads.note(for: state, live: live, serverIsCurrent: true) == "Mending 1 piece")
        state.mends = nil
        live.isRestarting = true
        #expect(TranscodedDownloads.note(for: state, live: live, serverIsCurrent: true) == "Server starting the transcode again")
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
    var failures: [TransferFailure] = []

    init(_ jobs: [DownloadJob]) { self.jobs = jobs }

    func changeJob(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    func transcodesChanged() { changes += 1 }
    func startOver(_ id: UUID, because reason: String) {}
    func stopJob(_ id: UUID, because message: String) {}
    func transcodeFailed(_ id: UUID, _ failure: TransferFailure) { failures.append(failure) }
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
        // Past the end, once it's known, nothing stays.
        host.jobs[0].transcode?.pieceCount = 20
        #expect(!transcodes.mayKeep(20, of: host.jobs[0]))
    }

    /// The init segment is asked for once the server's transcode has made a piece since it was
    /// seen starting: pieces served from what a stopped run left don't mean it has one yet.
    @Test func waitsForARunToMakeAPieceBeforeAskingForItsInitSegment() {
        var live = TranscodedDownloads.Live()
        #expect(!live.hasMadeAPiece(at: 100, pieceLength: 3))
        live.observe(.running(position: 100), pieceLength: 3)
        #expect(!live.hasMadeAPiece(at: 102, pieceLength: 3))
        #expect(live.hasMadeAPiece(at: 103, pieceLength: 3))
        live.observe(.running(position: 104), pieceLength: 3)
        #expect(live.hasMadeAPiece(at: 104, pieceLength: 3))
        // Started again, further back.
        #expect(live.startsAfresh(.running(position: 20), pieceLength: 3))
        live.observe(.running(position: 20), pieceLength: 3)
        #expect(!live.hasMadeAPiece(at: 21, pieceLength: 3))
        live.observe(.ended, pieceLength: 3)
        #expect(!live.hasMadeAPiece(at: 30, pieceLength: 3))
        #expect(live.startsAfresh(.running(position: 30), pieceLength: 3))
        live.observe(.running(position: 30), pieceLength: 3)
        #expect(live.hasMadeAPiece(at: 33, pieceLength: 3))
    }

    /// The app stops the server's transcode to start it again elsewhere: the queue is planned
    /// first, which takes back every piece the server hasn't answered, as none may stay.
    @Test func takesBackThePiecesOutBeforeStoppingTheServersTranscode() throws {
        var job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, Titles.request()))
        var state = Titles.state()
        state.collected = IndexSet(0..<20)
        job.transcode = state
        let host = TranscodeHostStub([job])
        let base = FileManager.default.temporaryDirectory.appending(path: "ServerDownTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = try #require(UserDefaults(suiteName: "ServerDownTests-\(UUID().uuidString)"))
        let transcodes = TranscodedDownloads(accounts: AccountStore(defaults: defaults),
                                             storage: DownloadStorage(finished: base.appending(path: "Finished"), root: base.appending(path: "Root")))
        transcodes.host = host
        #expect(transcodes.mayKeep(21, of: host.jobs[0]))
        #expect(transcodes.holdForRestart(job.id, deeper: false))
        #expect(host.changes == 1)
        #expect(!transcodes.mayKeep(20, of: host.jobs[0]))
        #expect(!transcodes.mayKeep(21, of: host.jobs[0]))
        // Being stopped already: nothing more.
        #expect(!transcodes.holdForRestart(job.id, deeper: true))
        #expect(host.changes == 1)
    }
}

// MARK: Fragmented MP4

/// Builds the boxes Jellyfin's fragmented MP4 is made of: an init segment with its tracks, and
/// pieces of fragments of samples of ten bytes each: a six-byte NAL unit after its four-byte
/// length, or an AC-3 frame.
private enum MP4 {
    static let timescale: UInt32 = 90_000
    static let sampleSize = 10

    enum Entry {
        case avc, ac3
        /// An mp4a entry whose decoder configuration names this object type: 0x40 is AAC, 0x6B MP3.
        case mp4a(objectType: UInt8)
    }

    struct Track {
        var id: UInt32 = 1
        var entry = Entry.avc
        var timescale = MP4.timescale
        /// An edit list starting the track's presentation there, as for pictures whose
        /// composition starts after their decoding.
        var editMediaTime: UInt32?
        /// The transfer characteristics the picture's colr box names.
        var colourTransfer: UInt16?
        /// The bit rate its sample entry gives, in a btrt box and an mp4a entry's decoder
        /// configuration; without, no btrt box and 192 kb/s in the decoder configuration.
        var bitRate: UInt32?
    }

    struct Sample {
        var duration: UInt32
        var compositionOffset: Int32 = 0
        var isSync = false
    }

    /// One track's samples in a fragment, decoded from `decodeTime` on.
    struct Run {
        var track: Track
        var decodeTime: Int64
        var samples: [Sample]
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

    static func makeHeader(entry: Entry = .avc, editMediaTime: UInt32? = nil) -> Data {
        makeHeader(tracks: [Track(entry: entry, editMediaTime: editMediaTime)])
    }

    static func makeHeader(tracks: [Track]) -> Data {
        let ftyp = box("ftyp", Data("iso5".utf8) + uint32(512) + Data("iso5iso6mp41".utf8))
        let mvhd = fullBox("mvhd", uint32(0) + uint32(0) + uint32(1000) + uint32(0) + Data(count: 80))
        var traks = Data()
        var trexes = Data()
        for track in tracks {
            let tkhd = fullBox("tkhd", flags: 3, uint32(0) + uint32(0) + uint32(track.id) + Data(count: 68))
            let edts = track.editMediaTime.map { box("edts", fullBox("elst", uint32(1) + uint32(0) + uint32($0) + uint32(0x0001_0000))) }
                ?? Data()
            let mdhd = fullBox("mdhd", uint32(0) + uint32(0) + uint32(track.timescale) + uint32(0) + uint32(0))
            let handler = if case .avc = track.entry { "vide" } else { "soun" }
            let hdlr = fullBox("hdlr", uint32(0) + Data(handler.utf8) + Data(count: 12) + Data("Track\0".utf8))
            let bitRates = track.bitRate.map { box("btrt", uint32(0) + uint32($0) + uint32($0)) } ?? Data()
            let sampleEntry = switch track.entry {
            case .avc:
                // Six reserved bytes and the data reference, 70 bytes of picture fields, then avcC:
                // four-byte NAL lengths, no parameter sets; and the colour, if said.
                box("avc1", Data(count: 6) + uint16(1) + Data(count: 70) + box("avcC", Data([1, 0x64, 0, 0x28, 0xFF, 0xE0, 0]))
                    + (track.colourTransfer.map { box("colr", Data("nclx".utf8) + uint16(9) + uint16($0) + uint16(9) + Data([0])) } ?? Data())
                    + bitRates)
            case .ac3:
                box("ac-3", Data(count: 6) + uint16(1) + Data(count: 20) + bitRates)
            case .mp4a(let objectType):
                // An ES descriptor (tag 3) holding a decoder configuration (tag 4): the object and
                // stream types, the buffer size, the highest and average bit rates; and its
                // specific info (tag 5).
                box("mp4a", Data(count: 6) + uint16(1) + Data(count: 20) + fullBox("esds", Data([
                    0x03, 0x80, 0x80, 0x80, 0x19, 0x00, 0x02, 0x00,
                    0x04, 0x80, 0x80, 0x80, 0x11, objectType, 0x15, 0, 0, 0,
                ]) + uint32(track.bitRate ?? 192_000) + uint32(track.bitRate ?? 192_000) + Data([
                    0x05, 0x80, 0x80, 0x80, 0x02, 0x11, 0x90,
                ])) + bitRates)
            }
            let stbl = box("stbl", fullBox("stsd", uint32(1) + sampleEntry))
            traks += box("trak", tkhd + edts + box("mdia", mdhd + hdlr + box("minf", stbl)))
            trexes += fullBox("trex", uint32(track.id) + uint32(1) + uint32(0) + uint32(0) + uint32(0))
        }
        return ftyp + box("moov", mvhd + traks + box("mvex", trexes))
    }

    /// A sample's ten bytes.
    static func sample(_ entry: Entry) -> Data {
        switch entry {
        case .avc: Data([0, 0, 0, 6, 0x65]) + Data(repeating: 0xAB, count: 5)
        case .ac3: Data([0x0B, 0x77]) + Data(repeating: 0xAB, count: 8)
        case .mp4a: Data(repeating: 0x21, count: 10)
        }
    }

    /// A piece whose picture starts at `start` seconds, with `samples` one-second samples, the
    /// first a keyframe; `extraBytes` more in its media data than its samples take.
    static func piece(start: Double, samples: Int = 3, decodeTime: Int64? = nil, entry: Entry = .avc, extraBytes: Int = 0) -> Data {
        let run = Run(track: Track(entry: entry), decodeTime: decodeTime ?? Int64((start * Double(timescale)).rounded()),
                      samples: (0..<samples).map { Sample(duration: timescale, isSync: $0 == 0) })
        return piece([run], extraBytes: extraBytes)
    }

    /// A piece of one fragment holding `runs`, their samples one run after another in its media data.
    static func piece(_ runs: [Run], extraBytes: Int = 0) -> Data {
        func traf(_ run: Run, offset: UInt32) -> Data {
            let tfhd = fullBox("tfhd", flags: 0x020000, uint32(run.track.id))
            let tfdt = fullBox("tfdt", version: 1, uint64(UInt64(bitPattern: run.decodeTime)))
            var entries = Data()
            for sample in run.samples {
                entries += uint32(sample.duration) + uint32(UInt32(sampleSize)) + uint32(sample.isSync ? 0x0200_0000 : 0x0101_0000)
                    + uint32(UInt32(bitPattern: sample.compositionOffset))
            }
            let trun = fullBox("trun", version: 1, flags: 0x000F01, uint32(UInt32(run.samples.count)) + uint32(offset) + entries)
            return box("traf", tfhd + tfdt + trun)
        }
        let mfhd = fullBox("mfhd", uint32(1))
        let moofLength = 8 + mfhd.count + runs.reduce(0) { $0 + traf($1, offset: 0).count }
        var trafs = Data()
        var offset = moofLength + 8
        for run in runs {
            trafs += traf(run, offset: UInt32(offset))
            offset += run.samples.count * sampleSize
        }
        let media = runs.reduce(Data()) { data, run in data + run.samples.reduce(Data()) { bytes, _ in bytes + sample(run.track.entry) } }
        return box("styp", Data("msdh".utf8) + uint32(0) + Data("msdhmsix".utf8)) + box("moof", mfhd + trafs)
            + box("mdat", media + Data(repeating: 0, count: extraBytes))
    }

    /// Where a piece's media data starts within it.
    static func mediaStart(of piece: Data) -> Int {
        piece.range(of: Data("mdat".utf8))!.upperBound - piece.startIndex
    }
}

/// A transcode as Jellyfin's x264 makes it, frame by frame: 24000 ticks a second, frames of 1001
/// (23.976 fps), shown two frames after they're decoded (an edit list of 2002), in groups of four
/// decoded I P B B and shown I B B P; with audio of a frame's length at 48 kHz.
private enum Film {
    static let frame = 1001
    static let video = MP4.Track(id: 1, entry: .avc, timescale: 24000, editMediaTime: 2002)
    static let audio = MP4.Track(id: 2, entry: .ac3, timescale: 48000)
    static let header = MP4.makeHeader(tracks: [video, audio])
    static var parsed: FragmentedMP4.Header { try! FragmentedMP4.header(header) }
    /// The pieces here are eight frames long.
    static let cutInterval = 8 * Double(frame) / 24000

    /// Frame `number`'s time, in the video's ticks.
    static func time(_ number: Int) -> Int64 { Int64(number * frame) }
    static func seconds(_ number: Int) -> Double { Double(number * frame) / 24000 }

    /// The pictures shown from frame `first` on, `count` of them, as decoded: in groups of four
    /// reordered, or one after another as a restarted run's are here.
    static func pictures(from first: Int, count: Int, reordered: Bool = true) -> MP4.Run {
        let samples = (0..<count).map { index in
            let shown = reordered ? index / 4 * 4 + [0, 3, 1, 2][index % 4] : index
            return MP4.Sample(duration: UInt32(frame), compositionOffset: Int32((shown - index + 2) * frame),
                              isSync: reordered ? index % 4 == 0 : index == 0)
        }
        return MP4.Run(track: video, decodeTime: time(first), samples: samples)
    }

    /// Audio from frame `first`'s time on, `count` frames of it.
    static func sound(from first: Int, count: Int) -> MP4.Run {
        MP4.Run(track: audio, decodeTime: time(first) * 2, samples: (0..<count).map { _ in MP4.Sample(duration: UInt32(2 * frame)) })
    }

    /// The piece of frames `frames`, with audio from `audioFrom` (the first frame, unless said) to their end.
    static func piece(_ frames: Range<Int>, audioFrom: Int? = nil, reordered: Bool = true) -> Data {
        let audioStart = audioFrom ?? frames.lowerBound
        return MP4.piece([pictures(from: frames.lowerBound, count: frames.count, reordered: reordered),
                          sound(from: audioStart, count: frames.upperBound - audioStart)])
    }

    static func read(_ data: Data) -> FragmentedMP4.Piece { try! FragmentedMP4.piece(data, header: parsed) }

    /// A timeline holding the pieces of `frames`, eight at a time.
    static func timeline(_ frames: Range<Int>) -> TranscodeTimeline {
        let pieces = stride(from: frames.lowerBound, to: frames.upperBound, by: 8).map { read(piece($0..<min($0 + 8, frames.upperBound))) }
        return TranscodeTimeline(pieces: pieces, header: parsed, cutInterval: cutInterval)!
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
        #expect(try FragmentedMP4.header(MP4.makeHeader(tracks: [MP4.Track(), MP4.Track(id: 2, entry: .ac3)])).tracks[2]?.format == .ac3Frames)
        #expect(try FragmentedMP4.header(MP4.makeHeader(editMediaTime: 1800)).tracks[1]?.presentationOffset == 1800)
    }

    /// The picture's dynamic range as the transcode made it, from its colour.
    @Test func readsThePicturesDynamicRange() throws {
        func range(_ transfer: UInt16?) throws -> String? {
            try FragmentedMP4.header(MP4.makeHeader(tracks: [MP4.Track(colourTransfer: transfer)])).videoRangeType
        }
        #expect(try range(16) == "HDR10")
        #expect(try range(18) == "HLG")
        #expect(try range(1) == "SDR")
        #expect(try range(nil) == nil)
    }

    /// AAC's frames overlap the one before; the init segment says it's AAC, not that.
    @Test func readsThatAACNeedsTheSampleBefore() throws {
        func roll(_ entry: MP4.Entry) throws -> Int16? {
            try FragmentedMP4.header(MP4.makeHeader(tracks: [MP4.Track(), MP4.Track(id: 2, entry: entry)])).tracks[2]?.rollDistance
        }
        #expect(try roll(.mp4a(objectType: 0x40)) == -1)
        #expect(try roll(.mp4a(objectType: 0x67)) == -1)
        #expect(try roll(.mp4a(objectType: 0x6B)) == nil)
        #expect(try roll(.ac3) == nil)
        #expect(try FragmentedMP4.header(MP4.header).tracks[1]?.rollDistance == nil)
    }

    /// A restarted transcode works out the bit rates its init segment gives afresh; its pieces
    /// join the file all the same, unless what the samples are decoded with differs.
    @Test func joinsARunWhoseInitGivesOtherBitRates() throws {
        func header(bitRate: UInt32, objectType: UInt8 = 0x40, rate: UInt32 = 48000) -> Data {
            MP4.makeHeader(tracks: [MP4.Track(bitRate: bitRate * 10),
                                    MP4.Track(id: 2, entry: .mp4a(objectType: objectType), timescale: rate, bitRate: bitRate)])
        }
        let first = header(bitRate: 194_897)
        #expect(try FragmentedMP4.header(first).tracks[2]?.rollDistance == -1)
        #expect(try FragmentedMP4.decodeAlike(first, header(bitRate: 196_200)))
        #expect(try !FragmentedMP4.decodeAlike(first, header(bitRate: 194_897, rate: 44100)))
        #expect(try !FragmentedMP4.decodeAlike(first, header(bitRate: 194_897, objectType: 0x6B)))
        #expect(try !FragmentedMP4.decodeAlike(first, MP4.makeHeader(tracks: [MP4.Track(bitRate: 1_948_970)])))
        #expect(throws: FragmentedMP4.Problem.self) { try FragmentedMP4.decodeAlike(first, first.prefix(first.count - 3)) }
    }

    @Test func readsWhereAPiecesPictureLiesAndEverySample() throws {
        let header = try FragmentedMP4.header(MP4.header)
        let data = MP4.piece(start: 30)
        let piece = try FragmentedMP4.piece(data, header: header)
        #expect(piece.videoStart == 30)
        #expect(piece.videoEnd == 33)
        #expect(piece.videoSamples == 3)
        #expect(piece.startsWithSync)
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

    /// Each track's stretch is when its samples are shown: decode time and composition offset,
    /// less the header's edit, so a picture's time is the source's.
    @Test func readsEachTracksStretchAsShown() throws {
        let piece = Film.read(Film.piece(16..<24, audioFrom: 15))
        #expect(piece.spans[1] == FragmentedMP4.Span(start: Film.time(16), end: Film.time(24), sampleDuration: Int64(Film.frame)))
        #expect(piece.spans[2] == FragmentedMP4.Span(start: Film.time(15) * 2, end: Film.time(24) * 2, sampleDuration: Int64(2 * Film.frame)))
        #expect(piece.videoStart == Film.seconds(16))
        #expect(piece.pictures(header: Film.parsed).map(\.shown) == [16, 19, 17, 18, 20, 23, 21, 22].map(Film.time))
    }

    /// Every piece starts with a keyframe; one that doesn't is told.
    @Test func tellsAPieceThatDoesntStartWithAKeyframe() throws {
        var run = Film.pictures(from: 0, count: 8)
        run.samples[0].isSync = false
        #expect(!Film.read(MP4.piece([run])).startsWithSync)
        #expect(Film.read(Film.piece(0..<8)).startsWithSync)
    }

    /// Where a later run can take over: where every picture shown before is decoded before every
    /// one shown from there.
    @Test func findsTheCleanCutsOfReorderedPictures() {
        let pictures = Film.read(Film.piece(0..<8)).pictures(header: Film.parsed)
        #expect(FragmentedMP4.cleanCuts(pictures) == [0, 1, 4, 5].map(Film.time))
    }

    /// From box and fragment headers alone, as a long file's pieces are read: the same timing as
    /// reading them whole.
    @Test func outlinesAJoinedFilesPieces() throws {
        let pieces = [Film.piece(0..<8), Film.piece(8..<16), Film.piece(16..<20)]
        let joined = pieces.reduce(Film.header, +)
        let outlines = try FragmentedMP4.outlines(count: joined.count, from: Film.header.count, header: Film.parsed) { joined.subdata(in: $0) }
        var offset = Film.header.count
        let read = pieces.map { data in
            defer { offset += data.count }
            return Film.read(data).shifted(by: offset)
        }
        #expect(outlines == read)
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

        let audioHeader = try FragmentedMP4.header(MP4.makeHeader(tracks: [MP4.Track(), MP4.Track(id: 2, entry: .ac3)]))
        var frame = MP4.piece([MP4.Run(track: MP4.Track(id: 2, entry: .ac3), decodeTime: 0,
                                       samples: (0..<3).map { _ in MP4.Sample(duration: 1536) })])
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

struct TranscodeTimelineTests {
    /// The server's playlist lists 23.976 fps pieces at 3.003 s and 3.004 s, while ffmpeg cuts
    /// them at 72 frames, 3.003 s: placed by the playlist they drift apart from the 14th on.
    /// Placed by their own timestamps, every one follows on.
    @Test func followsPiecesByTheirOwnTimestampsAtAnNTSCRate() throws {
        let pieces = (0..<60).map { Film.read(Film.piece(($0 * 72)..<($0 * 72 + 72), reordered: false)) }
        var judge = TranscodeJudge(timeline: nil, runEndedAt: nil, skippedEnd: nil, header: Film.parsed, cutInterval: 3, runtime: nil)
        for (number, piece) in pieces.enumerated() { #expect(judge.take(piece, number: number) == nil) }
        #expect(judge.joining == Array(0..<60))
        let timeline = try #require(judge.timeline)
        #expect(timeline.end == Film.seconds(60 * 72))
        // Where the playlist would put the 41st piece, 120.16 s in, is 0.04 s past where the file ends.
        let listed = Film.read(Film.piece(2881..<2953, reordered: false))
        #expect(TranscodeTimeline(pieces: Array(pieces.prefix(40)), header: Film.parsed, cutInterval: 3)?.fit(listed) == .late)
    }

    @Test func tellsHowARestartedRunsPieceFits() {
        let timeline = Film.timeline(0..<32)
        #expect(timeline.fit(Film.read(Film.piece(32..<40))) == .continues)
        // At a clean cut of the file's pictures, with audio from before its audio ends.
        #expect(timeline.fit(Film.read(Film.piece(29..<37, audioFrom: 28, reordered: false))) == .joins)
        #expect(timeline.fit(Film.read(Film.piece(24..<32, audioFrom: 24, reordered: false))) == .joins)
        // Where pictures before it are decoded after it.
        #expect(timeline.fit(Film.read(Film.piece(26..<34, reordered: false))) == .early)
        // Past the end, in its pictures or its audio.
        #expect(timeline.fit(Film.read(Film.piece(33..<41, reordered: false))) == .late)
        #expect(timeline.fit(Film.read(Film.piece(32..<40, audioFrom: 33))) == .late)
        var keyless = Film.pictures(from: 32, count: 8)
        keyless.samples[0].isSync = false
        #expect(timeline.fit(Film.read(MP4.piece([keyless]))) == .late)
    }

    /// The latest clean cut a run started again can take over at: before the file's audio ends,
    /// with room for an encoder's lead-in, and early enough for the server to start there.
    @Test func aimsARestartAtTheLatestCleanCutItCanTakeOverAt() throws {
        let timeline = Film.timeline(0..<40)
        // The audio ends at frame 40, 1.668 s; a tenth of a second before is frame 37.6.
        #expect(timeline.restartPoint(runtimeEnd: nil, searchBack: 0) == Film.time(37))
        #expect(timeline.restartPoint(runtimeEnd: nil, searchBack: 0.5) == Film.time(25))
        // The server starts no later than 5 s before what it takes as the end.
        #expect(timeline.restartPoint(runtimeEnd: 6.1, searchBack: 0) == Film.time(21))
        // Half a frame early, from the first picture.
        let cut = try #require(timeline.restartPoint(runtimeEnd: nil, searchBack: 0))
        #expect(timeline.seekTime(for: cut) == Double(37 * 1001 - 500) / 24000)
        // Further back than the file has cuts for, nothing.
        #expect(timeline.restartPoint(runtimeEnd: nil, searchBack: 10) == nil)
    }

    /// A piece off the grid the server cuts a run's pieces on starts a run, which a restart
    /// lands on whatever the source: where it aims once the file has no cut as far back as the
    /// attempt says, and past the attempts that aim back.
    @Test func aimsTheLastRestartWhereTheFilesLastRunStarted() {
        var timeline = Film.timeline(0..<32)
        #expect(timeline.runStart == timeline.origin)
        for frames in [29..<37, 37..<45, 45..<53] {
            let piece = Film.read(Film.piece(frames, audioFrom: frames.lowerBound == 29 ? 28 : nil, reordered: false))
            timeline.append(piece, header: Film.parsed, cutInterval: Film.cutInterval)
        }
        #expect(timeline.runStart == Film.time(29))
        #expect(timeline.restartCut(attempt: 0, runtimeEnd: nil) == timeline.restartPoint(runtimeEnd: nil, searchBack: 0))
        #expect(timeline.restartCut(attempt: 1, runtimeEnd: nil) == Film.time(29))
        #expect(timeline.restartCut(attempt: TranscodeTimeline.restartAttempts - 1, runtimeEnd: nil) == Film.time(29))
        // A piece fetched again at its own start is on the grid.
        timeline.append(Film.read(Film.piece(45..<53, reordered: false)), header: Film.parsed, cutInterval: Film.cutInterval)
        #expect(timeline.runStart == Film.time(29))
    }

    @Test func tellsAShortLastPiece() {
        #expect(!Film.timeline(0..<40).endsShort)
        #expect(Film.timeline(0..<36).endsShort)
    }
}

struct TranscodeJudgeTests {
    private func judge(_ timeline: TranscodeTimeline?, runtime: Double? = nil, runEndedAt: Double? = nil) -> TranscodeJudge {
        TranscodeJudge(timeline: timeline, runEndedAt: runEndedAt, skippedEnd: nil, header: Film.parsed, cutInterval: Film.cutInterval,
                       runtime: runtime)
    }

    /// The run asked for past the end starts near it, takes over, and ends where the one before
    /// did with a short piece: that's the end, about where the title ends.
    @Test func endsWhereTwoRunsEnd() {
        var judge = judge(Film.timeline(0..<40), runtime: Film.seconds(40))
        #expect(judge.take(Film.read(Film.piece(29..<37, audioFrom: 28, reordered: false)), number: 5) == nil)
        #expect(judge.runEndedAt == Film.seconds(40))
        #expect(judge.takeovers.map(\.piece) == [5])
        #expect(judge.takeovers.first?.at == Film.seconds(29))
        #expect(judge.takeovers.first?.fileEnd == Film.seconds(40))
        #expect(judge.take(Film.read(Film.piece(37..<40, reordered: false)), number: 6) == .end(7))
        #expect(judge.joining == [5, 6])
    }

    /// Short of the title's length, a short piece where a run ended before isn't taken as the
    /// end without asking further: a run the server stopped can end with one too. The run asked
    /// for next starting again before the file's end is.
    @Test func asksPastAShortPieceShortOfTheTitlesLength() {
        var judge = judge(Film.timeline(0..<40), runtime: 600)
        #expect(judge.take(Film.read(Film.piece(29..<37, audioFrom: 28, reordered: false)), number: 5) == nil)
        #expect(judge.take(Film.read(Film.piece(37..<40, reordered: false)), number: 6) == nil)
        #expect(judge.take(Film.read(Film.piece(29..<37, audioFrom: 28, reordered: false)), number: 7) == .end(7))
    }

    /// An MPEG-TS source's run starts at a keyframe that may not be a clean cut: its pieces in
    /// the file's stretch are left out, and the next run starting before the file ends again
    /// ends the transcode.
    @Test func leavesOutWhatTheFileHasAndEndsWhereARunEndsAgain() {
        var judge = judge(Film.timeline(0..<40))
        #expect(judge.take(Film.read(Film.piece(34..<38, reordered: false)), number: 5) == nil)
        #expect(judge.take(Film.read(Film.piece(38..<40, reordered: false)), number: 6) == nil)
        #expect(judge.skipping == [5, 6])
        #expect(judge.take(Film.read(Film.piece(34..<38, reordered: false)), number: 7) == .end(7))
    }

    /// A run that left pieces out goes on into the file where one of its pieces starts at a
    /// clean cut.
    @Test func joinsALaterPieceOfARunThatStartedEarly() {
        var judge = judge(Film.timeline(0..<40))
        #expect(judge.take(Film.read(Film.piece(26..<28, reordered: false)), number: 5) == nil)
        #expect(judge.take(Film.read(Film.piece(28..<36, audioFrom: 26, reordered: false)), number: 6) == nil)
        #expect(judge.skipping == [5])
        #expect(judge.joining == [6])
        #expect(judge.timeline?.end == Film.seconds(36))
        #expect(judge.take(Film.read(Film.piece(36..<44, reordered: false)), number: 7) == nil)
        #expect(judge.timeline?.end == Film.seconds(44))
    }

    @Test func stopsAtAGapAndAtThePieceAfterThePicture() {
        var gap = judge(Film.timeline(0..<40))
        #expect(gap.take(Film.read(Film.piece(42..<50)), number: 5) == .gap)
        #expect(gap.joining.isEmpty)
        var empty = judge(Film.timeline(0..<40))
        #expect(empty.take(Film.read(MP4.piece([Film.sound(from: 40, count: 1)])), number: 5) == .end(5))
    }

    @Test func startsTheFileWithTheFirstPiece() {
        var judge = judge(nil)
        #expect(judge.take(Film.read(Film.piece(0..<8)), number: 0) == nil)
        #expect(judge.timeline?.originSeconds == 0)
        #expect(judge.joining == [0])
    }
}

struct TranscodeVerifierTests {
    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "TranscodeVerifierTests-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    private func check(_ pieces: [Data], header: Data = MP4.header) throws -> TranscodeVerifier.StructureCheck {
        let url = try file(pieces.reduce(header, +))
        defer { try? FileManager.default.removeItem(at: url) }
        return TranscodeVerifier.checkStructure(of: url, header: MP4.header)
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
        #expect(structure.start == 0)
        #expect(structure.end == 9)
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
        // Unreadable, it's asked for where the piece before ends.
        #expect(bad[1] == TranscodeVerifier.Place(bytes: Int64(start)..<Int64(start + damaged.count), start: 3, end: nil))

        var first = MP4.piece(start: 0)
        // The first piece's own start is damaged: it runs up to the second's.
        first.replaceSubrange(0..<4, with: MP4.uint32(0xFFFF_FFF0))
        guard case .failed(.badPieces(let firstBad, _)) = try check([first, MP4.piece(start: 3), MP4.piece(start: 6)]) else {
            Issue.record("a damaged first piece is found")
            return
        }
        #expect(firstBad[0]?.bytes == Int64(MP4.header.count)..<Int64(MP4.header.count + first.count))
    }

    /// Every piece the server makes starts with a keyframe; one that doesn't is named, to be
    /// fetched again.
    @Test func namesAPieceThatDoesntStartWithAKeyframe() throws {
        var run = MP4.Run(track: MP4.Track(), decodeTime: 3 * Int64(MP4.timescale),
                          samples: (0..<3).map { _ in MP4.Sample(duration: MP4.timescale) })
        run.samples[1].isSync = true
        guard case .failed(.badPieces(let bad, let reason)) = try check([MP4.piece(start: 0), MP4.piece([run]), MP4.piece(start: 6)]) else {
            Issue.record("a piece without a keyframe first is found")
            return
        }
        #expect(Array(bad.keys) == [1])
        #expect(bad[1]?.start == 3)
        #expect(bad[1]?.end == 6)
        #expect(reason.contains("doesn't start with a keyframe"))
    }

    /// Wrong in a way no piece can be blamed for: the job stops, keeping its pieces.
    @Test func namesNoPieceForAFileNotStartingWithTheInitSegment() throws {
        var otherHeader = MP4.header
        otherHeader[otherHeader.startIndex + 8] = 0
        guard case .failed(.unmendable) = try check((0..<3).map { MP4.piece(start: Double($0) * 3) }, header: otherHeader) else {
            Issue.record("a file not starting with the init segment names no piece")
            return
        }
    }

    private func structure(_ pieces: [Data], header: Data) throws -> TranscodeVerifier.Structure {
        let parsed = try FragmentedMP4.header(header)
        var offset = header.count
        let read = try pieces.map { data in
            defer { offset += data.count }
            return try FragmentedMP4.piece(data, header: parsed).shifted(by: offset)
        }
        return TranscodeVerifier.Structure(header: parsed, pieces: read, fileLength: Int64(offset))
    }

    /// A slideshow at 1 fps, in pieces of three pictures each shown a picture after it's decoded:
    /// the pictures checked are asked for at the times they're shown, and decoding one may read on
    /// through the pieces holding the pictures its decoder takes in after it, six pieces here.
    @Test func checksPicturesAtTheirOwnTimesAtOneFramePerSecond() throws {
        let track = MP4.Track(id: 1, entry: .avc, timescale: 1000, editMediaTime: 1000)
        let header = MP4.makeHeader(tracks: [track])
        // Decoded I P B, shown I B P.
        let pieces = (0..<30).map { index in
            MP4.piece([MP4.Run(track: track, decodeTime: Int64(index) * 3000, samples: [
                MP4.Sample(duration: 1000, compositionOffset: 1000, isSync: true), MP4.Sample(duration: 1000, compositionOffset: 2000),
                MP4.Sample(duration: 1000, compositionOffset: 0),
            ])])
        }
        let stills = TranscodeVerifier.stills(in: try structure(pieces, header: header), indexBytes: 500)
        #expect(stills.map(\.seconds) == [0, 47, 89])
        #expect(stills.map(\.piece) == [0, 15, 29])
        #expect(stills.map(\.duration) == [1, 1, 1])
        let block = 6 * TranscodeVerifier.playerReadBlock
        // From the piece before through six after.
        #expect(stills[1].limits.maxInputBytes == Int64(header.count + 500 + 8 * pieces[0].count) + block)
        #expect(stills[1].limits.maxPackets == 8 * 3 + 16)
        #expect(stills[2].limits.maxInputBytes == Int64(header.count + 500 + 2 * pieces[0].count) + block)
        #expect(stills[0].limits.maxPackets == 7 * 3 + 16)
        #expect(stills.allSatisfy { $0.limits.maxPacketBytes == MP4.sampleSize })
    }

    /// At 23.976 fps a piece holds eight pictures: three more pieces cover those after. A piece a
    /// later run took over from isn't checked in the middle: the file holds it only in part.
    @Test func checksAPieceTheFileHoldsWhole() throws {
        let pieces = [Film.piece(0..<8), Film.piece(8..<16), Film.piece(16..<24), Film.piece(24..<32),
                      Film.piece(29..<37, audioFrom: 28, reordered: false), Film.piece(37..<45, reordered: false),
                      Film.piece(45..<53, reordered: false)]
        let stills = TranscodeVerifier.stills(in: try structure(pieces, header: Film.header), indexBytes: 0)
        #expect(stills.map(\.piece) == [0, 2, 6])
        // The last shown of frames 16 to 23, and the very last.
        #expect(stills.map(\.seconds) == [0, Film.seconds(23), Film.seconds(52)])
        let bytes = pieces[1...5].reduce(0) { $0 + $1.count }
        #expect(stills[1].limits.maxInputBytes == Int64(Film.header.count + bytes) + 6 * TranscodeVerifier.playerReadBlock)
    }

    /// A container's header can overstate how long it runs: a transcode as long as what it holds
    /// passes, one well short of it doesn't.
    @Test func allowsAnOverstatedLength() {
        #expect(TranscodeVerifier.shortfallAllowed(runtime: 306) == 10)
        #expect(TranscodeVerifier.shortfallAllowed(runtime: 9000) == 180)
        #expect(300 >= 306 - TranscodeVerifier.shortfallAllowed(runtime: 306))
        #expect(Film.timeline(0..<40).reaches(runtime: Film.seconds(40) + 9))
        #expect(!Film.timeline(0..<40).reaches(runtime: Film.seconds(40) + 11))
        #expect(!Film.timeline(0..<40).reaches(runtime: nil))
    }
}

struct FlattenedMP4Tests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "FlattenedMP4Tests-\(UUID().uuidString)")

    private func read(_ pieces: [Data], header: Data) throws -> [FragmentedMP4.Piece] {
        let parsed = try FragmentedMP4.header(header)
        var offset = header.count
        return try pieces.map { data in
            defer { offset += data.count }
            return try FragmentedMP4.piece(data, header: parsed).shifted(by: offset)
        }
    }

    private func index(_ pieces: [Data], header: Data) throws -> FlattenedMP4.Index {
        let joined = pieces.reduce(header, +)
        return try FlattenedMP4.index(header: header, parsed: FragmentedMP4.header(header), pieces: read(pieces, header: header),
                                      fileLength: Int64(joined.count))
    }

    /// Joins `pieces` after `header` and indexes them in the joined file, and returns its bytes
    /// as indexed, the index, and as joined.
    private func flatten(_ pieces: [Data], header: Data = MP4.header) throws -> (data: Data, index: FlattenedMP4.Index, joined: Data) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let joined = pieces.reduce(header, +)
        let file = folder.appending(path: "partial-\(UUID().uuidString).mp4")
        try joined.write(to: file)
        let index = try index(pieces, header: header)
        let length = try FlattenedMP4.write(index, into: file, length: Int64(joined.count))
        let data = try Data(contentsOf: file)
        #expect(length == Int64(data.count))
        // Taken out again, the joined file is as it was.
        try FlattenedMP4.undo(file, header: header, length: Int64(joined.count))
        #expect(try Data(contentsOf: file) == joined)
        return (data, index, joined)
    }

    private func box(_ path: [String], in data: Data, track: Int = 0) throws -> FragmentedMP4.Box {
        var range = 0..<data.count
        var found: FragmentedMP4.Box?
        for type in path {
            let matches = try FragmentedMP4.boxes(in: data, range: range).filter { $0.type == type }
            found = type == "trak" && matches.indices.contains(track) ? matches[track] : matches.first
            guard let found else { throw FragmentedMP4.Problem(message: "No \(type) box.") }
            range = found.payload
        }
        return try #require(found)
    }

    /// The 32-bit fields of a full box after its version and flags.
    private func fields(_ box: FragmentedMP4.Box, in data: Data) -> [UInt32] {
        stride(from: box.payload.lowerBound + 4, to: box.payload.upperBound, by: 4).map { data.uint32(at: $0) }
    }

    /// The edit list's entries: duration in the movie's timescale, and media time.
    private func edits(in data: Data, track: Int = 0) throws -> [(duration: UInt64, mediaTime: Int64)] {
        let elst = try box(["moov", "trak", "edts", "elst"], in: data, track: track)
        let count = Int(data.uint32(at: elst.payload.lowerBound + 4))
        return (0..<count).map { entry in
            let at = elst.payload.lowerBound + 8 + entry * 20
            return (data.uint64(at: at), Int64(bitPattern: data.uint64(at: at + 8)))
        }
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
        #expect(try edits(in: data).map(\.duration) == [9000])
        #expect(try edits(in: data).map(\.mediaTime) == [0])
        let mvhd = try box(["moov", "mvhd"], in: data)
        #expect(data.byte(at: mvhd.payload.lowerBound) == 1)
        #expect(data.uint64(at: mvhd.payload.lowerBound + 24) == 9000)
        let mdhd = try box(["moov", "trak", "mdia", "mdhd"], in: data)
        #expect(data.uint64(at: mdhd.payload.lowerBound + 24) == 9 * UInt64(MP4.timescale))
        #expect(index.origin == 0)
    }

    /// A source whose clock starts 1.5 s in: the file starts at its first picture.
    @Test func putsTheFirstPictureAtTheStart() throws {
        let (late, lateIndex, _) = try flatten((0..<3).map { MP4.piece(start: 1.5 + Double($0) * 3) })
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(lateIndex.origin == 1.5)
        #expect(try edits(in: late).map(\.mediaTime) == [0])
        #expect(try edits(in: late).map(\.duration) == [9000])
    }

    /// Pictures shown two frames after they're decoded: the edit list starts at the first shown
    /// and runs to the end of the last, which an edit as long as the samples less its start
    /// would cut off; the audio keeps its place beside them.
    @Test func showsEveryPictureToTheLast() throws {
        let (data, index, _) = try flatten([Film.piece(0..<8), Film.piece(8..<16), Film.piece(16..<24)], header: Film.header)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(index.origin == 0)
        // 24 frames of 1001 at 24000 a second are 1001 ms.
        #expect(try edits(in: data).map(\.mediaTime) == [2002])
        #expect(try edits(in: data).map(\.duration) == [1001])
        #expect(try edits(in: data, track: 1).map(\.mediaTime) == [0])
        #expect(try edits(in: data, track: 1).map(\.duration) == [1001])
        let mvhd = try box(["moov", "mvhd"], in: data)
        #expect(data.uint64(at: mvhd.payload.lowerBound + 24) == 1001)
    }

    /// AAC's frames each need the one before: the index says so, as the server's fragments can't,
    /// for a player to take the encoder's priming as such and keep the sound with the picture.
    @Test func groupsAACSamplesAsNeedingTheOneBefore() throws {
        let sound = MP4.Track(id: 2, entry: .mp4a(objectType: 0x40), timescale: 48000)
        let header = MP4.makeHeader(tracks: [MP4.Track(), sound])
        let pieces = (0..<2).map { index in
            MP4.piece([MP4.Run(track: MP4.Track(), decodeTime: Int64(index) * 3 * Int64(MP4.timescale),
                               samples: (0..<3).map { MP4.Sample(duration: MP4.timescale, isSync: $0 == 0) }),
                       MP4.Run(track: sound, decodeTime: Int64(index) * 140 * 1024, samples: (0..<140).map { _ in MP4.Sample(duration: 1024) })])
        }
        let (data, _, _) = try flatten(pieces, header: header)
        defer { try? FileManager.default.removeItem(at: folder) }
        let table = ["moov", "trak", "mdia", "minf", "stbl"]
        let sgpd = try box(table + ["sgpd"], in: data, track: 1)
        #expect(data.subdata(in: sgpd.payload) == Data([1, 0, 0, 0]) + Data("roll".utf8) + Data([0, 0, 0, 2, 0, 0, 0, 1, 0xFF, 0xFF]))
        let sbgp = try box(table + ["sbgp"], in: data, track: 1)
        #expect(data.subdata(in: sbgp.payload) == Data([0, 0, 0, 0]) + Data("roll".utf8) + MP4.uint32(1) + MP4.uint32(280) + MP4.uint32(1))
        #expect(throws: FragmentedMP4.Problem.self) { try box(table + ["sgpd"], in: data, track: 0) }
    }

    /// A restarted run takes over at a clean cut: the pictures from there on before it go, and
    /// so does its audio the file has; every sample keeps its own time.
    @Test func takesOverWhereARestartedRunJoins() throws {
        let pieces = [Film.piece(0..<8), Film.piece(8..<16), Film.piece(16..<24), Film.piece(24..<32),
                      Film.piece(29..<37, audioFrom: 28, reordered: false)]
        let (data, _, _) = try flatten(pieces, header: Film.header)
        defer { try? FileManager.default.removeItem(at: folder) }
        let videoTable = ["moov", "trak", "mdia", "minf", "stbl"]
        // Frames 0 to 28 of the first run, then 29 to 36 of the second.
        #expect(fields(try box(videoTable + ["stsz"], in: data), in: data) == [10, 37])
        #expect(fields(try box(videoTable + ["stts"], in: data), in: data) == [1, 37, 1001])
        #expect(try edits(in: data).map(\.duration) == [Int64(37 * 1001 * 1000 / 24000)].map(UInt64.init))
        // Audio to frame 32 from the first run, then from 32 on from the second.
        #expect(fields(try box(videoTable + ["stsz"], in: data, track: 1), in: data) == [10, 37])
        #expect(fields(try box(videoTable + ["stts"], in: data, track: 1), in: data) == [1, 37, 2002])
    }

    /// A run the server stopped can end on an audio sample it cut short; the next run has it
    /// whole at the same time, and it's left out of that run rather than put twice.
    @Test func leavesOutTheAudioSampleARunCutShort() throws {
        var first = Film.sound(from: 0, count: 32)
        first.samples[31].duration = 700
        let pieces = [MP4.piece([Film.pictures(from: 0, count: 32), first]),
                      MP4.piece([Film.pictures(from: 29, count: 8, reordered: false), Film.sound(from: 28, count: 9)])]
        let (data, _, _) = try flatten(pieces, header: Film.header)
        defer { try? FileManager.default.removeItem(at: folder) }
        let table = ["moov", "trak", "mdia", "minf", "stbl"]
        #expect(fields(try box(table + ["stsz"], in: data, track: 1), in: data) == [10, 37])
        // The short one plays to the next, as long as a whole one.
        #expect(fields(try box(table + ["stts"], in: data, track: 1), in: data) == [1, 37, 2002])
    }

    /// Anything else that doesn't follow on names the piece, in pictures or in audio, rather
    /// than move samples to hide it.
    @Test func namesAPieceThatDoesntFollowOn() throws {
        let gap = #expect(throws: FlattenedMP4.Misfit.self) { try index([0.0, 3, 7].map { MP4.piece(start: $0) }, header: MP4.header) }
        #expect(gap?.piece == 2)
        #expect(gap?.message.contains("after the ones before end") == true)
        let audioGap = #expect(throws: FlattenedMP4.Misfit.self) {
            try index([Film.piece(0..<8), Film.piece(8..<16, audioFrom: 9)], header: Film.header)
        }
        #expect(audioGap?.piece == 1)
        // A run taking over where the pictures before can't be cut.
        let uncut = #expect(throws: FlattenedMP4.Misfit.self) {
            try index([Film.piece(0..<8), Film.piece(8..<16), Film.piece(10..<18, reordered: false)], header: Film.header)
        }
        #expect(uncut?.piece == 2)
        var keyless = Film.pictures(from: 8, count: 8)
        keyless.samples[0].isSync = false
        let keylessMisfit = #expect(throws: FlattenedMP4.Misfit.self) { try index([Film.piece(0..<8), MP4.piece([keyless])], header: Film.header) }
        #expect(keylessMisfit?.piece == 1)
    }

    /// Written into the joined file itself, on any volume, and taken out again whatever got
    /// written of it.
    @Test func undoesAnIndexCutOffWhileItWasWritten() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pieces = (0..<3).map { MP4.piece(start: Double($0) * 3) }
        let joined = pieces.reduce(MP4.header, +)
        let file = folder.appending(path: "partial.mp4")
        try joined.write(to: file)
        let index = try index(pieces, header: MP4.header)
        // The media data header written, the index cut off halfway.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(index.mdatOffset))
        try handle.write(contentsOf: index.mdatHeader)
        try handle.seekToEnd()
        try handle.write(contentsOf: index.moov.prefix(index.moov.count / 2))
        try handle.close()
        try FlattenedMP4.undo(file, header: MP4.header, length: Int64(joined.count))
        #expect(try Data(contentsOf: file) == joined)
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

    @Test func joinsPiecesInTheOrderGivenWhicheverCameFirst() async throws {
        let storage = try makeStorage()
        let jobId = UUID()
        let pieces = (0..<4).map { MP4.piece(start: Double($0) * 3) }
        try storage.beginTranscodedFile(header: MP4.header, for: jobId)
        for index in [3, 0, 2, 1] { try keep(pieces[index], index, for: jobId, in: storage) }
        #expect(storage.transcodeSideBytes(for: jobId) == Int64(MP4.header.count + pieces.reduce(0) { $0 + $1.count }))
        let afterTwo = try await storage.appendSegments([0, 1], for: jobId, after: Int64(MP4.header.count))
        // A run that appended the last pieces but ended before saying so: the next one appends them again, once.
        _ = try await storage.appendSegments([3], for: jobId, after: afterTwo)
        // Piece 2 left out: the file has its stretch.
        let length = try await storage.appendSegments([3], for: jobId, after: afterTwo)
        let joined = try Data(contentsOf: storage.partialFile(for: jobId))
        #expect(joined == MP4.header + pieces[0] + pieces[1] + pieces[3])
        #expect(length == Int64(joined.count))
        try storage.removeSegments(0..<4, for: jobId)
        #expect(storage.transcodeSideBytes(for: jobId) == Int64(MP4.header.count))
    }

    /// Where the file ends is read from its pieces' headers, and a file cut back loses the rest.
    @Test func readsAndCutsBackTheJoinedFile() throws {
        let storage = try makeStorage()
        let jobId = UUID()
        let pieces = (0..<3).map { MP4.piece(start: Double($0) * 3) }
        try storage.beginTranscodedFile(header: pieces.reduce(MP4.header, +), for: jobId)
        let header = try FragmentedMP4.header(MP4.header)
        let length = Int64(MP4.header.count + pieces[0].count + pieces[1].count)
        let read = try storage.transcodedPieces(for: jobId, header: header, length: length)
        #expect(read.map(\.videoStart) == [0, 3])
        try storage.truncateTranscodedFile(for: jobId, to: length)
        #expect(storage.size(of: storage.partialFile(for: jobId)) == length)
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

    /// What's published is the joined file as indexed in place.
    @Test func publishesTheIndexedFile() throws {
        let storage = try makeStorage()
        var job = DownloadJob(item: Titles.item, plan: .transcode(Titles.uhd, Titles.request()))
        let indexed = MP4.header + MP4.piece(start: 0) + Data(repeating: 1, count: 100)
        try storage.beginTranscodedFile(header: indexed, for: job.id)
        job.totalBytes = Int64(indexed.count)
        let path = try storage.publish(job)
        #expect(try Data(contentsOf: storage.finished.appending(path: path)) == indexed)
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
