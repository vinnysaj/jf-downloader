#if !os(tvOS)
import Foundation

/// Where a transcoded download's joined file ends, track by track, on the transcode's own
/// timeline, and how a piece fits after it.
///
/// The server's playlist doesn't say where its pieces start. It lists each at a length it works
/// out from the frame rate (3.003 s at 23.976 fps), while ffmpeg cuts a run's pieces at the first
/// frame at or after each multiple of 3 s from that run's first frame, so from 14 pieces in the
/// two drift apart; a picture it copies rather than encodes is cut at the source's keyframes.
/// Within one run each piece starts where the one before ended, so pieces are placed by their
/// own timestamps, never by their numbers.
///
/// When the server starts its transcode again, it seeks to the time the request names
/// (`runtimeTicks`), and the new run starts at the first frame at or after it, for an MKV or MP4
/// source, or at the first source keyframe after where its seek lands, for MPEG-TS and M2TS; a
/// copied picture starts at the source's keyframe before it. Its first piece starts with a
/// keyframe, so it can take over from the file's pictures at a clean cut: a time at which every
/// picture shown before is decoded before every picture shown from it, so the pictures from
/// there on can be left out without one kept missing what it refers to. Its audio has to start
/// no later than the file's audio ends, so nothing is lost there either. The file keeps every
/// byte; its index (`FlattenedMP4`) leaves out the pictures from the cut on and the new run's
/// audio the file has already, and keeps each sample at its time.
nonisolated struct TranscodeTimeline: Equatable, Sendable {
    struct Track: Equatable, Sendable {
        var timescale: Int64
        /// When the file's last sample of the track stops being shown, in its timescale.
        var end: Int64
        /// A sample's duration: a frame, or an audio frame.
        var sampleDuration: Int64
    }

    /// How a piece fits after the file.
    enum Fit: Equatable, Sendable {
        /// It starts where the file ends.
        case continues
        /// It starts earlier, at a clean cut of the file's pictures, with keyframe and audio to
        /// take over there: a restarted transcode's.
        case joins
        /// It starts before the file ends but not at a clean cut of it: a later piece of its run
        /// may take over. A remuxed run's pieces start at source keyframes, so one can; an encoded
        /// run's start on its own 3 s grid, each as far off the file's cuts as its first.
        case early
        /// It starts after the file ends, in its pictures or its audio, or without a keyframe:
        /// something would be lost between them.
        case late
    }

    var videoTrack: UInt32
    var tracks: [UInt32: Track]
    /// When the first picture is shown, in the video's timescale.
    var origin: Int64
    /// The clean cuts of the file's last pictures, oldest first, as far back as a restart looks.
    var cuts: [Int64]
    /// Where the run of the server's transcode that made the file's last pieces started. The
    /// server starts each run's pieces every `cutInterval` from its start, so a piece off that
    /// grid starts a run. A restart aimed there lands there whatever the source, for a run
    /// started there before, and it's a clean cut of the file.
    var runStart: Int64
    /// The last piece is shorter than the server cuts them: the run that made it ended there.
    var endsShort = false

    /// How far back clean cuts are kept: past the furthest a restart aims back (`searchBack`),
    /// with room for the run to land.
    static let cutsKept: TimeInterval = 120

    /// How far before the latest clean cut each attempt at a restart aims, one after another
    /// (`restartCut`). An MKV or MP4 source lands where it's asked, so the first does. MPEG-TS
    /// and M2TS land on the first source keyframe at or after it (Jellyfin 12.4 lands on the
    /// frame asked for only within a frame or two after one), usually past the file's end;
    /// aimed further back, the new run lands within the file, and takes over when that keyframe
    /// is one of the file's clean cuts, which about half of those tried were.
    static let searchBack: [TimeInterval] = [0, 10, 20, 30, 40, 60, 80, 100]

    var video: Track { tracks[videoTrack] ?? Track(timescale: 1, end: 0, sampleDuration: 1) }

    /// The file's end, in seconds of the transcode's timeline.
    var end: Double { Double(video.end) / Double(video.timescale) }
    var originSeconds: Double { Double(origin) / Double(video.timescale) }

    /// A timeline holding `piece`, the file's first.
    init?(first piece: FragmentedMP4.Piece, header: FragmentedMP4.Header, cutInterval: Double) {
        guard let videoTrack = header.videoTrack, let span = piece.spans[videoTrack] else { return nil }
        self.videoTrack = videoTrack
        tracks = [:]
        origin = span.start
        runStart = span.start
        cuts = []
        append(piece, header: header, cutInterval: cutInterval)
    }

    /// The timeline of a file holding `pieces`, in order.
    init?(pieces: [FragmentedMP4.Piece], header: FragmentedMP4.Header, cutInterval: Double) {
        guard let first = pieces.first, var timeline = TranscodeTimeline(first: first, header: header, cutInterval: cutInterval) else {
            return nil
        }
        for piece in pieces.dropFirst() { timeline.append(piece, header: header, cutInterval: cutInterval) }
        self = timeline
    }

    /// Takes in `piece`, which `fit` said continues or joins the file.
    mutating func append(_ piece: FragmentedMP4.Piece, header: FragmentedMP4.Header, cutInterval: Double) {
        for (id, span) in piece.spans {
            guard let timescale = header.tracks[id].map({ Int64($0.timescale) }) else { continue }
            if id == videoTrack {
                let from = span.start - tolerance(timescale)
                cuts.removeAll { $0 >= from }
                cuts += FragmentedMP4.cleanCuts(piece.pictures(header: header))
                tracks[id] = Track(timescale: timescale, end: span.end, sampleDuration: span.sampleDuration)
                // The server cuts a piece at the first picture at or after each interval.
                let interval = cutInterval * Double(timescale)
                let sinceRunStart = Double(span.start - runStart)
                if abs(sinceRunStart - (sinceRunStart / interval).rounded() * interval) > Double(span.sampleDuration) {
                    runStart = span.start
                }
                let length = Double(span.end - span.start) / Double(timescale)
                endsShort = length < cutInterval - Double(span.sampleDuration) / Double(timescale) - 0.001
            } else {
                let end = max(tracks[id]?.end ?? span.end, span.end)
                tracks[id] = Track(timescale: timescale, end: end, sampleDuration: span.sampleDuration)
            }
        }
        let oldest = video.end - Int64(Self.cutsKept * Double(video.timescale))
        cuts.removeAll { $0 < oldest }
    }

    /// How `piece` fits after the file.
    func fit(_ piece: FragmentedMP4.Piece) -> Fit {
        guard let span = piece.spans[videoTrack], piece.startsWithSync else { return .late }
        let video = video
        let slack = tolerance(video.timescale)
        let fit: Fit
        if abs(span.start - video.end) <= slack {
            fit = .continues
        } else if span.start > video.end {
            return .late
        } else if cuts.contains(where: { abs($0 - span.start) <= slack }) {
            fit = .joins
        } else {
            return .early
        }
        // Each other track picks up no later than it ends, give or take half a sample, which a
        // run started again with its audio cut differently can't help.
        for (id, track) in tracks where id != videoTrack {
            guard let other = piece.spans[id] else { continue }
            if other.start > track.end + other.sampleDuration / 2 { return .late }
        }
        return fit
    }

    /// The latest clean cut a restarted transcode can take over at: early enough that the new
    /// run's audio starts before the file's audio ends, which needs a margin when the server
    /// encodes the audio and its first frames lead in, and before the server's own limit of
    /// 5 s before what it takes as the title's end (`runtimeEnd`, in seconds of the timeline),
    /// less `searchBack` seconds.
    func restartPoint(runtimeEnd: Double?, searchBack: TimeInterval) -> Int64? {
        let video = video
        let scale = Double(video.timescale)
        var bound = Double(video.end) / scale
        for (id, track) in tracks where id != videoTrack {
            bound = min(bound, Double(track.end) / Double(track.timescale) - Self.audioLeadIn)
        }
        if let runtimeEnd { bound = min(bound, runtimeEnd - Self.serverEndLimit) }
        let latest = Int64(((bound - searchBack) * scale).rounded(.down))
        return cuts.last { $0 <= latest }
    }

    /// How far before the file's audio ends a restart aims: the server's encoder spends its
    /// first frames leading in.
    static let audioLeadIn: TimeInterval = 0.1
    /// The server starts a transcode it's asked to start later than this before the title's
    /// end this far before it instead; with a little to spare.
    static let serverEndLimit: TimeInterval = 5.1

    /// Where attempt `attempt` at a restart aims: `restartPoint` as far back as `searchBack`
    /// says, or `runStart` when the file has no cut that far back; after those, `runStart`.
    func restartCut(attempt: Int, runtimeEnd: Double?) -> Int64 {
        guard Self.searchBack.indices.contains(attempt) else { return runStart }
        return restartPoint(runtimeEnd: runtimeEnd, searchBack: Self.searchBack[attempt]) ?? runStart
    }

    static var restartAttempts: Int { searchBack.count + 1 }

    /// The time a restart aimed at `cut` asks the server for, in seconds from the title's start:
    /// half a frame early, so a source whose clock starts with its audio a little ahead of its
    /// picture still lands on that frame.
    func seekTime(for cut: Int64) -> Double {
        let video = video
        return max(0, Double(cut - origin - video.sampleDuration / 2) / Double(video.timescale))
    }

    /// A millisecond, which no two frames are as close as and timestamps rounded across runs are
    /// always within.
    private func tolerance(_ timescale: Int64) -> Int64 { max(1, timescale / 1000) }

    /// Whether the file reaches about as far as a title of `runtime` seconds: short of it by no
    /// more than a container's header can overstate it.
    func reaches(runtime: Double?) -> Bool {
        guard let runtime else { return false }
        return end - originSeconds >= runtime - TranscodeVerifier.shortfallAllowed(runtime: runtime)
    }
}

/// Judges the pieces after a transcoded download's file one after another, by where each starts
/// against where the file ends (`TranscodeTimeline.fit`): which join it, which it has already
/// (a restarted run's, before one takes over), and where that stops.
///
/// The server's playlist doesn't say how many pieces there are, and a run of its transcode ends
/// where the title does or where it was stopped, so the end shows by runs: when a run starts
/// again (its first piece starts before the file ends), the one before ended where the file
/// does, and two ending at the same place end the transcode. The one asked for past the end
/// starts near it and ends there too; it isn't fetched further when its last piece is short,
/// as one a run ends with is, about where the title ends.
nonisolated struct TranscodeJudge {
    enum Outcome: Equatable {
        /// The run that made the next piece doesn't take over from the file.
        case gap
        /// The transcode ends with the file; the piece judged there is the count's number.
        case end(Int)
    }

    var timeline: TranscodeTimeline?
    /// Where the file ended when a run was last seen to end (`TranscodedDownloads.Live`).
    var runEndedAt: Double?
    /// Where the last piece left out ends: the next of its run starts there.
    var skippedEnd: Double?
    /// The pieces that join the file, and those it has already, in order.
    var joining: [Int] = []
    var skipping: [Int] = []
    /// The pieces that take over from a file reaching further: where, and where the file reached.
    var takeovers: [(piece: Int, at: Double, fileEnd: Double)] = []
    let header: FragmentedMP4.Header
    let cutInterval: Double
    let runtime: Double?

    init(timeline: TranscodeTimeline?, runEndedAt: Double?, skippedEnd: Double?, header: FragmentedMP4.Header, cutInterval: Double,
         runtime: Double?) {
        self.timeline = timeline
        self.runEndedAt = runEndedAt
        self.skippedEnd = skippedEnd
        self.header = header
        self.cutInterval = cutInterval
        self.runtime = runtime
    }

    /// Takes piece `number`, the next. Returns how the transcode goes on when the judging stops
    /// with it; nil to go on to the next.
    mutating func take(_ piece: FragmentedMP4.Piece, number: Int) -> Outcome? {
        // The server's piece past the end of the picture.
        guard !piece.isEmpty else { return .end(number) }
        guard var current = timeline else {
            timeline = TranscodeTimeline(first: piece, header: header, cutInterval: cutInterval)
            joining.append(number)
            return nil
        }
        let fit = current.fit(piece)
        let followsSkipped = skippedEnd.map { abs($0 - (piece.videoStart ?? .nan)) < 0.001 } ?? false
        if fit == .joins || fit == .early, !followsSkipped {
            // The first piece of a run started again: the run before ended where the file does.
            if let runEndedAt, abs(runEndedAt - current.end) < 0.001 { return .end(number) }
            runEndedAt = current.end
        }
        switch fit {
        case .continues, .joins:
            if fit == .joins, let start = piece.videoStart { takeovers.append((number, start, current.end)) }
            current.append(piece, header: header, cutInterval: cutInterval)
            timeline = current
            joining.append(number)
            skippedEnd = nil
            // Its run ended with it, about where the title ends, where the run before ended.
            if current.endsShort, let runEndedAt, abs(runEndedAt - current.end) < 0.001, current.reaches(runtime: runtime) {
                return .end(number + 1)
            }
            return nil
        case .early:
            skipping.append(number)
            skippedEnd = piece.videoEnd
            return nil
        case .late:
            return .gap
        }
    }
}
#endif
