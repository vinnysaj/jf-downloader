import Foundation
import Testing
@testable import vinnyfin

/// Plays samples a second apart through a watch, and says what it said, and when.
private struct Playback {
    var watch = ConnectionWatch()
    var time: Double = 0
    var position: Double = 600
    var bufferedAhead: Double = 30
    var throughput: Double? = 50_000_000
    var bitrate: Double? = 25_000_000
    var rate: Double = 1
    var isWanted = true

    /// Seconds of samples in which the playhead advances by `advance` each; the first reason
    /// given, with the second it came at.
    mutating func run(_ seconds: Int, advance: Double = 1, drain: Double = 0) -> (reason: ConnectionWatch.Reason, at: Double)? {
        for _ in 0..<seconds {
            time += 1
            position += advance
            bufferedAhead = max(0, bufferedAhead - drain)
            let sample = ConnectionWatch.Sample(time: time, isWanted: isWanted, position: position, rate: rate,
                                                bufferedAhead: bufferedAhead, throughput: throughput, bitrate: bitrate)
            if let reason = watch.observe(sample) { return (reason, time) }
        }
        return nil
    }

    /// The same, with the watch on a stream that is already moving.
    func started() -> Self {
        var playback = self
        _ = playback.run(2)
        return playback
    }
}

struct ConnectionWatchTests {
    @Test func leavesHealthyPlaybackAlone() {
        var playback = Playback().started()
        #expect(playback.run(300) == nil)
    }

    @Test func leavesAShortFreezeAlone() {
        var playback = Playback().started()
        #expect(playback.run(20) == nil)
        #expect(playback.run(5, advance: 0) == nil)
        #expect(playback.run(60) == nil)
    }

    @Test func stepsDownAfterOneLongFreeze() {
        var playback = Playback().started()
        _ = playback.run(10)
        let start = playback.time
        let verdict = playback.run(20, advance: 0)
        #expect(verdict?.reason == .stalled)
        #expect(verdict.map { $0.at - start } == ConnectionWatch.longStall)
    }

    @Test func stepsDownWhenItKeepsFreezing() {
        var playback = Playback().started()
        _ = playback.run(10)
        #expect(playback.run(3, advance: 0) == nil)
        #expect(playback.run(10) == nil)
        #expect(playback.run(3, advance: 0)?.reason == .stuttering)
    }

    @Test func forgetsFreezesOutsideTheWindow() {
        var playback = Playback().started()
        #expect(playback.run(4, advance: 0) == nil)
        #expect(playback.run(40) == nil)
        #expect(playback.run(4, advance: 0) == nil)
    }

    @Test func countsACrawlAsFreezing() {
        var playback = Playback().started()
        #expect(playback.run(20, advance: 0.4)?.reason == .stalled)
    }

    @Test func givesAStartLongerThanAFreeze() {
        var slow = Playback()
        let verdict = slow.run(30, advance: 0)
        #expect(verdict?.reason == .slowStart)
        #expect(verdict?.at == ConnectionWatch.slowStart + 1)

        var fine = Playback()
        #expect(fine.run(10, advance: 0) == nil)
        #expect(fine.run(60) == nil)
    }

    @Test func givesATranscodeTheServersStartToo() {
        var transcode = Playback(watch: ConnectionWatch(isTranscode: true))
        #expect(transcode.run(Int(ConnectionWatch.slowTranscodeStart), advance: 0) == nil)
        #expect(transcode.run(1, advance: 0)?.reason == .slowStart)
        // A seek in it is a start of the server's too.
        transcode.watch.restart()
        #expect(transcode.run(20, advance: 0) == nil)
    }

    @Test func keepsTheStartOutOfTheStutterCount() {
        var playback = Playback()
        #expect(playback.run(10, advance: 0) == nil)
        #expect(playback.run(10) == nil)
        #expect(playback.run(4, advance: 0) == nil)
        #expect(playback.run(30) == nil)
    }

    @Test func stepsDownBeforeTheBufferRunsDry() {
        // 12 Mbps for a 25 Mbps stream drains about half a second of buffer a second.
        var playback = Playback(bufferedAhead: 40, throughput: 12_000_000).started()
        let verdict = playback.run(120, drain: 0.52)
        #expect(verdict?.reason == .fallingBehind)
        let drain = 1 - 12.0 / 25
        #expect(playback.bufferedAhead < ConnectionWatch.runwayNeeded * drain)
        #expect(playback.bufferedAhead > ConnectionWatch.runwayNeeded * drain - 1)
    }

    @Test func waitsForTheLinkToStaySlow() {
        var playback = Playback(bufferedAhead: 5, throughput: 12_000_000)
        _ = playback.run(1)
        #expect(playback.run(ConnectionWatch.fallingBehindSamples - 1) == nil)
        playback.throughput = 40_000_000
        #expect(playback.run(1) == nil)
        playback.throughput = 12_000_000
        #expect(playback.run(ConnectionWatch.fallingBehindSamples - 1) == nil)
        #expect(playback.run(1)?.reason == .fallingBehind)
    }

    @Test func leavesASlowLinkAloneWhileTheBufferLasts() {
        var playback = Playback(bufferedAhead: 120, throughput: 20_000_000).started()
        #expect(playback.run(30, drain: 0.2) == nil)
    }

    @Test func weighsTheLinkAgainstTheSpeed() {
        var doubleSpeed = Playback(rate: 2).started()
        #expect(doubleSpeed.run(60, advance: 2) == nil)
        var tooFast = Playback(bufferedAhead: 10, throughput: 40_000_000, rate: 2).started()
        #expect(tooFast.run(10, advance: 2)?.reason == .fallingBehind)
    }

    @Test func ignoresPausesOutagesAndJumps() {
        var playback = Playback().started()
        playback.isWanted = false
        #expect(playback.run(60, advance: 0) == nil)
        playback.isWanted = true
        _ = playback.run(1)
        // A seek forward is a jump of the playhead, not playback.
        playback.position += 300
        #expect(playback.run(30) == nil)
    }

    @Test func startsOverAfterASeek() {
        var playback = Playback().started()
        #expect(playback.run(7, advance: 0) == nil)
        playback.watch.restart()
        // The wait for the seek is a start: it gets the longer allowance.
        #expect(playback.run(10, advance: 0) == nil)
    }

    @Test func estimatesTheLinkByItsBestRecentReading() {
        var playback = Playback(throughput: 12_000_000).started()
        playback.throughput = 8_000_000
        _ = playback.run(3)
        #expect(playback.watch.throughput == 12_000_000)
        _ = playback.run(10)
        #expect(playback.watch.throughput == 8_000_000)
    }
}

private func version(_ id: String, _ name: String? = nil, height: Int? = nil, bitrate: Int? = nil) -> MediaSource {
    var source = MediaSource(id: id, name: name)
    source.bitrate = bitrate
    if let height {
        var video = MediaStream(type: "Video")
        video.width = height * 16 / 9
        video.height = height
        source.mediaStreams = [video]
    }
    return source
}

struct StepDownTests {
    let uhd = version("2160", "2160p", height: 2160, bitrate: 25_259_033)
    let fullHD = version("1080", "1080p", height: 1080, bitrate: 8_261_500)
    let hd = version("720", "720p", height: 720, bitrate: 3_262_945)
    var all: [MediaSource] { [uhd, fullHD, hd] }

    private func stepDown(from plan: PlaybackPlan, bitrate: Int? = nil, throughput: Int?, sources: [MediaSource]? = nil,
                          allowTranscoding: Bool = true) -> PlaybackPlan? {
        VersionChooser.planStepDown(from: plan, bitrate: bitrate, throughput: throughput,
                                    sources: sources ?? all, allowTranscoding: allowTranscoding)
    }

    @Test func takesTheBestVersionTheLinkCarries() {
        #expect(stepDown(from: .direct(uhd), throughput: 12_300_000) == .direct(fullHD))
        #expect(stepDown(from: .direct(uhd), throughput: 8_600_000) == .direct(hd))
    }

    @Test func takesOneStepWithoutAMeasure() {
        #expect(stepDown(from: .direct(uhd), throughput: nil) == .direct(fullHD))
        #expect(stepDown(from: .direct(fullHD), throughput: nil) == .direct(hd))
    }

    @Test func prefersAVersionToATranscodeThatFits() {
        // A 720p transcode at 6 Mbps would fit too; the untouched 720p is better.
        #expect(stepDown(from: .direct(uhd), throughput: 9_000_000) == .direct(hd))
    }

    @Test func transcodesBelowTheSmallestVersion() {
        #expect(stepDown(from: .direct(hd), throughput: 3_400_000) == .transcode(hd, .sd))
        #expect(stepDown(from: .direct(hd), throughput: nil) == .transcode(hd, .sd))
        #expect(stepDown(from: .direct(hd), throughput: 3_400_000, allowTranscoding: false) == nil)
    }

    @Test func transcodesARemuxThatIsTheOnlyVersion() {
        let remux = version("remux", "1080p REMUX", height: 1080, bitrate: 32_000_000)
        #expect(stepDown(from: .direct(remux), throughput: 10_000_000, sources: [remux]) == .transcode(remux, .hd))
        #expect(stepDown(from: .direct(remux), throughput: 25_000_000, sources: [remux]) == .transcode(remux, .fullHD))
    }

    @Test func takesTheCheapestWhenNothingFits() {
        #expect(stepDown(from: .direct(uhd), throughput: 1_000_000) == .transcode(hd, .sd))
        #expect(stepDown(from: .direct(uhd), throughput: 1_000_000, allowTranscoding: false) == .direct(hd))
    }

    @Test func goesOnDownFromATranscode() {
        #expect(stepDown(from: .transcode(uhd, .fullHD), throughput: 5_000_000, sources: [uhd]) == .transcode(uhd, .sd))
        #expect(stepDown(from: .transcode(hd, .sd), throughput: 1_000_000, sources: [hd]) == nil)
    }

    @Test func weighsTheMeasuredBitrateOverTheDeclared() {
        // A version measured at 5 Mbps leaves a 6 Mbps transcode nothing to save.
        #expect(stepDown(from: .direct(fullHD), bitrate: 5_000_000, throughput: nil, sources: [fullHD]) == .transcode(fullHD, .sd))
    }

    @Test func neverMakesThePictureBigger() {
        let remux = version("remux", "1080p REMUX", height: 1080, bitrate: 32_000_000)
        let hevc4K = version("hevc", "2160p HEVC", height: 2160, bitrate: 15_000_000)
        #expect(stepDown(from: .direct(remux), throughput: 25_000_000, sources: [hevc4K, remux], allowTranscoding: false) == nil)
    }

    @Test func goesByNamesForGelatoStreamsNotYetOpened() {
        let streams = [version("a", "[RD+] 4K HDR DV"), version("b", "1080p WEB-DL"), version("c", "720p")]
        #expect(stepDown(from: .direct(streams[0]), throughput: nil, sources: streams) == .direct(streams[1]))
        #expect(stepDown(from: .direct(streams[1]), throughput: 9_000_000, sources: streams) == .direct(streams[2]))
    }

    @Test func namesTheQualityItMovesTo() {
        #expect(PlaybackPlan.direct(uhd).label == "4K")
        #expect(PlaybackPlan.direct(fullHD).label == "1080p")
        #expect(PlaybackPlan.transcode(uhd, .hd).label == "720p")
        #expect(PlaybackPlan.direct(version("x", "Director's Cut")).label == nil)
        #expect(VideoQuality.fitting(height: 1440) == .uhd)
        #expect(VideoQuality.fitting(height: 576) == .hd)
        #expect(VideoQuality.fitting(height: 4320) == .original)
    }
}

struct SameTrackTests {
    private func track(_ id: Int, _ language: String?, forced: Bool = false, hearingImpaired: Bool = false,
                       name: String? = nil) -> TrackChooser.Candidate {
        TrackChooser.Candidate(id: id, language: language, isForced: forced, isHearingImpaired: hearingImpaired,
                               isDefault: false, name: name)
    }

    @Test func findsTheLanguageUnderAnotherNumber() {
        let french = track(2, "fre")
        #expect(TrackChooser.same(as: french, in: [track(1, "eng"), track(7, "fra")]) == 7)
    }

    @Test func keepsTheKindOfTrack() {
        let forced = track(5, "eng", forced: true)
        #expect(TrackChooser.same(as: forced, in: [track(3, "eng"), track(4, "eng", forced: true)]) == 4)
        let sdh = track(6, "eng", hearingImpaired: true)
        #expect(TrackChooser.same(as: sdh, in: [track(3, "eng")]) == 3)
    }

    @Test func tellsTracksApartByName() {
        let commentary = track(2, "eng", name: "Director's Commentary")
        let tracks = [track(1, "eng", name: "Main"), track(3, "eng", name: "director's commentary")]
        #expect(TrackChooser.same(as: commentary, in: tracks) == 3)
    }

    @Test func findsNothingInAnotherLanguage() {
        #expect(TrackChooser.same(as: track(1, "jpn"), in: [track(1, "eng")]) == nil)
        #expect(TrackChooser.same(as: track(1, nil), in: [track(4, "und"), track(5, "eng")]) == 4)
    }
}
