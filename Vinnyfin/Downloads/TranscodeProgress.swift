#if !os(tvOS)
import Foundation

/// How far a transcoded download has got, kept with its job.
///
/// The server cuts the transcode into pieces (HLS segments) of about `segmentDuration` seconds,
/// numbered from 0; each is fetched as a transfer of its own (`TransferTag.segment`), in any
/// order, and appended to the download's partial file once every piece before it is in. A piece
/// that arrives early waits beside the file. `TranscodedDownloads` runs it.
nonisolated struct TranscodeState: Codable, Equatable, Sendable {
    let request: TranscodeRequest
    /// The server's play session; every request of the download names it, and the server's
    /// copy of the transcode is deleted by it when the download is done.
    var playSessionId: String?
    /// The path, from the server's address, the playlist's addresses are relative to: "videos/<id>/".
    var playlistBase: String?
    /// The pieces to fetch. A last piece shorter than a frame isn't one: the server makes nothing for it.
    var segmentCount: Int?
    /// Seconds of each piece but the last.
    var segmentDuration: Double = Double(TranscodeRequest.segmentLength)
    var finalSegmentDuration: Double?
    /// The media source's tag when the transcode started. Another means the file changed.
    var sourceTag: String?
    /// The video and audio bitrates the server settled on, from its transcoding address.
    var videoBitrate: Int?
    var audioBitrate: Int?
    /// When the account's permissions and the source's tag were last looked at.
    var checkedAt: Date?

    /// Pieces on disk, in the file or beside it.
    var collected = IndexSet()
    /// Pieces 0..<appended are in the file.
    var appended = 0
    /// The bytes the file holds for certain: the init segment and the pieces appended. Anything
    /// past it was appended by a run that ended before it could say so.
    var fileLength: Int64 = 0
    /// The bytes beside the file: the init segment's copy and the pieces that came early.
    var sideBytes: Int64 = 0
    /// The server may have started its transcode again since the pieces collected so far were
    /// made, so its init segment is compared with the one kept before any newer piece counts:
    /// once a piece has come from the transcode as it is now.
    var needsInitCheck = false
    /// Pieces collected while `needsInitCheck` was set, which count once the init segment matches.
    var unchecked = IndexSet()

    /// What the server's playlist says of the stream it makes: `CODECS="avc1.640028,ac-3",
    /// RESOLUTION=1280x720` and the like.
    var variant: String?

    /// Where the first piece's picture starts, in seconds of the transcode's timeline: the
    /// server keeps the source's timestamps, which don't start at 0 for every source. Each
    /// piece's place counts from it.
    var timelineOrigin: Double?

    /// When the pieces left were found waiting on the server, its transcode ended: pieces asked
    /// for while it wasn't transcoding came, and it still wasn't once they had. It had finished,
    /// and keeps them as files until its cleanup, so they can all be asked for at once.
    var heldSince: Date?
    /// When the server last acknowledged a ping for this download: it stops a transcode a minute
    /// after the last.
    var lastPing: Date?
    /// When the server's init segment last matched the one kept.
    var initCheckedAt: Date?

    /// Whether a piece arriving at `now` may be from a transcode the server started again after
    /// stopping its own for want of pings (the app was suspended or closed meanwhile), and the
    /// init segment hasn't been checked since it could have.
    func isLapsed(at now: Date) -> Bool {
        guard heldSince == nil, let lastPing else { return false }
        let mayHaveStopped = lastPing.addingTimeInterval(TranscodeServer.killDelay)
        return now > mayHaveStopped && (initCheckedAt ?? .distantPast) < mayHaveStopped
    }

    /// Whether the pieces left are waiting on the server (`heldSince`) at `now`.
    func isHeld(at now: Date) -> Bool {
        heldSince.map { now.timeIntervalSince($0) < TranscodeServer.keptFor } ?? false
    }

    /// Where, in seconds, the server's transcode was last started again after it had ended
    /// short of every piece having come, having been seen transcoding since the time before;
    /// and how many times in a row that was about there.
    var lastStopPosition: Double?
    var stopsAtSamePlace = 0

    /// How many times it started over from nothing: for a server transcode that changed, a file
    /// that changed on the server, or a joined file that didn't check out.
    var startOvers = 0
    /// The joined file checked out (`TranscodeVerifier`).
    var isVerified = false
    /// Pieces in the file that didn't check out, and the bytes each takes there, to fetch again.
    var repairs: [Int: Range<Int64>] = [:]
    /// How many checks of the joined file in a row found something to repair.
    var repairRounds = 0
    /// Why the last check of the joined file failed, while it's put right.
    var verifyFailure: String?

    init(request: TranscodeRequest) {
        self.request = request
    }

    var isPrepared: Bool { playSessionId != nil && segmentCount != nil && playlistBase != nil }

    /// Every byte the download holds on disk.
    var bytes: Int64 { fileLength + sideBytes }

    /// Every piece is in the file, and none waits for a check or a repair.
    var isCollected: Bool {
        guard let segmentCount else { return false }
        return appended >= segmentCount && unchecked.isEmpty && repairs.isEmpty
    }

    var runtimeSeconds: Double? {
        request.runtimeSeconds ?? segmentCount.map { Double(max(0, $0 - 1)) * segmentDuration + (finalSegmentDuration ?? segmentDuration) }
    }

    func duration(of segment: Int) -> Double {
        guard let segmentCount, segment == segmentCount - 1, let finalSegmentDuration else { return segmentDuration }
        return finalSegmentDuration
    }

    /// Where the last piece starts: a transcode that got there made every piece.
    var endPosition: Double {
        Double(max(0, (segmentCount ?? 1) - 1)) * segmentDuration
    }

    /// The end of the furthest piece collected, which is as far as the server counts the
    /// download as having got when it paces itself.
    var downloadPosition: Double {
        guard let last = collected.last else { return 0 }
        return Double(last) * segmentDuration + duration(of: last)
    }

    /// Seconds of the picture collected.
    var collectedSeconds: Double {
        collected.reduce(0) { $0 + duration(of: $1) }
    }

    /// What the file is expected to come to: once a few pieces are in, what they weigh per
    /// second, taking over from the bitrate asked for as more come; never less than what's on disk.
    var expectedBytes: Int64? {
        guard let total = runtimeSeconds, total > 0 else { return request.estimatedBytes }
        let bitrate = Double((videoBitrate ?? request.videoBitrate) + (audioBitrate ?? request.audioBitrate))
        let asked = bitrate * total / 8
        let seconds = collectedSeconds
        guard collected.count >= 4, seconds > 0 else { return max(bytes, Int64(asked)) }
        let measured = Double(bytes) / seconds * total
        let weight = min(1, seconds / total * 4)
        return max(bytes, Int64(measured * weight + asked * (1 - weight)))
    }

    /// The pieces that can go into the file now: the run of checked pieces after it.
    var appendable: Range<Int> {
        var end = appended
        while collected.contains(end), !unchecked.contains(end) { end += 1 }
        return appended..<end
    }

    /// Back to nothing collected, keeping what was asked and how often this happened.
    mutating func reset() {
        let kept = self
        self = TranscodeState(request: kept.request)
        startOvers = kept.startOvers
        lastStopPosition = kept.lastStopPosition
        stopsAtSamePlace = kept.stopsAtSamePlace
    }

    /// Takes in where the server's transcode is being started again because it ended short,
    /// `seenRunning` since the time before: three times in a row about the same place, it's
    /// failing there. Returns how many times that was.
    mutating func noteRestart(at position: Double, seenRunning: Bool) -> Int {
        let again = seenRunning && (lastStopPosition.map { abs($0 - position) <= 2 * segmentDuration } ?? false)
        stopsAtSamePlace = again ? stopsAtSamePlace + 1 : 1
        lastStopPosition = position
        return stopsAtSamePlace
    }
}

// MARK: The server's transcode

/// What the server says about its transcode for a download: no more than it shows.
///
/// The server lists the downloads' device as a session, and while ffmpeg runs, the share of the
/// title it has made (`TranscodingInfo.CompletionPercentage`). Once ffmpeg exits, the share goes,
/// whether it finished, failed or was stopped, and a stopped transcode's pieces go with it
/// unless it had finished: whether the pieces left are there to be had shows only by asking
/// for some (`TranscodeState.heldSince`). The share also reads empty for the moment between a
/// transcode starting and ffmpeg's first progress line.
nonisolated enum TranscodeServer: Equatable, Sendable {
    /// Nothing heard in this run of the app, or not lately enough to go by.
    case unknown
    /// Transcoding, this far in seconds.
    case running(position: Double)
    /// Not transcoding.
    case ended
    /// The server doesn't know the download's device: it restarted, and its transcodes went with it.
    case gone

    var position: Double? {
        if case .running(let position) = self { position } else { nil }
    }

    /// How long after the last ping the server stops a transcode, deleting its files.
    static let killDelay: TimeInterval = 60
    /// The server's cleanup deletes transcode files a day after they were written.
    static let keptFor: TimeInterval = 20 * 60 * 60

    /// How long a transcode a request started can take to show as running: the server reads its
    /// share from ffmpeg's progress lines, a fast ffmpeg makes the first pieces before the first
    /// line, and the server serves them as they're made.
    static let progressLag: TimeInterval = 5

    /// What the server's sessions for the download's device say.
    static func interpret(sessionFound: Bool, transcoding: TranscodingInfo?, runtime: Double?) -> TranscodeServer {
        guard sessionFound else { return .gone }
        guard let percent = transcoding?.completionPercentage, let runtime, runtime > 0 else { return .ended }
        return .running(position: percent / 100 * runtime)
    }
}

/// The parts of a session's `TranscodingInfo` read here.
nonisolated struct TranscodingInfo: Decodable, Equatable, Sendable {
    var completionPercentage: Double?
    var videoCodec: String?
    var audioCodec: String?
    var width: Int?
    var height: Int?
    var framerate: Double?
    var hardwareAccelerationType: String?

    enum CodingKeys: String, CodingKey {
        case completionPercentage = "CompletionPercentage", videoCodec = "VideoCodec", audioCodec = "AudioCodec"
        case width = "Width", height = "Height", framerate = "Framerate", hardwareAccelerationType = "HardwareAccelerationType"
    }
}

/// A session as `GET /Sessions?deviceId=` lists it, for its transcode.
nonisolated struct TranscodingSession: Decodable, Sendable {
    var deviceId: String?
    var transcodingInfo: TranscodingInfo?

    enum CodingKeys: String, CodingKey {
        case deviceId = "DeviceId", transcodingInfo = "TranscodingInfo"
    }
}

// MARK: Which pieces to ask for

nonisolated enum SegmentPlanner {
    struct Window: Equatable, Sendable {
        var segments: [Int] = []
        /// One piece asked for to find out whether the server has the pieces left, which may
        /// start its transcode again there.
        var isProbe = false
    }

    /// The server starts its transcode again at a piece more than 24 / length pieces past the
    /// newest it has made. Asking for at most this many past it keeps well inside that.
    static func aheadLimit(segmentDuration: Double) -> Int {
        max(1, min(4, Int(24 / max(1, segmentDuration.rounded())) / 2))
    }

    /// In front, pieces waiting on the server are handed to the session this many at a time,
    /// which is plenty for its four connections and little to take back if they turn out not to
    /// be there after all.
    static let finishedBatch = 16

    /// The server starts a transcode it's asked to start at a piece no later than 5 seconds
    /// before the title's end (half a second earlier still when it copies the video), and
    /// numbers what it makes from that piece all the same, so pieces it makes after starting
    /// later are out of place. This much before the end leaves room for both.
    static let restartMargin: TimeInterval = 6

    /// The piece to start the server's transcode at to get `firstOutstanding`: that one, unless
    /// the server would start too late for it to be in place, then the last that's early enough.
    static func restartPiece(firstOutstanding: Int, segmentDuration: Double, runtime: Double?) -> Int {
        guard let runtime, runtime > restartMargin else { return firstOutstanding }
        return min(firstOutstanding, Int(((runtime - restartMargin) / segmentDuration).rounded(.down)))
    }

    /// Whether the last piece coming back as something else (unreadable, without pictures, or
    /// out of place) shows the transcode ends before it. The server lists pieces to the end of
    /// the title as it knows its length, and a transcode can end sooner: one that starts the
    /// picture at the source's first frame (subtitles burned in) makes a source whose clock
    /// starts late that much shorter. Asked for a piece its transcode never made, the server
    /// transcodes again from too late to put it in place, so for the last piece, when that's
    /// all asking can get, it isn't there to get.
    static func endsBefore(_ segment: Int, segmentCount: Int, segmentDuration: Double, runtime: Double?) -> Bool {
        segment == segmentCount - 1
            && restartPiece(firstOutstanding: segment, segmentDuration: segmentDuration, runtime: runtime) < segment
    }

    /// The pieces that may be asked for now, lowest first, leaving out those collected and
    /// those `claimed` by transfers under way.
    ///
    /// - While the server transcodes, the pieces it has made (each ends at least a piece behind
    ///   it), then, once fewer than `aheadLimit` of those are left, up to `aheadLimit` past its
    ///   position, which it serves as it makes them, when `mayAskAhead`.
    /// - Not transcoding, with the pieces left known to wait on it (`isHeld`): every piece left,
    ///   up to `limit`.
    /// - Otherwise (not transcoding, gone, not known), one piece, alone, once nothing else is out:
    ///   the server sends it from what it kept, or starts its transcode again there, which then
    ///   shows. That's the first piece missing (`restartPiece`), from which the output joins
    ///   cleanly; near the end, an earlier piece, already here.
    static func window(segmentCount: Int, segmentDuration: Double, runtime: Double?, collected: IndexSet, claimed: Set<Int>,
                       server: TranscodeServer, isHeld: Bool, mayAskAhead: Bool, limit: Int? = nil) -> Window {
        let outstanding = (0..<segmentCount).filter { !collected.contains($0) }
        let missing = outstanding.filter { !claimed.contains($0) }
        guard let firstOutstanding = outstanding.first, !missing.isEmpty else { return Window() }
        var window: Window
        switch server {
        case .ended where isHeld:
            window = Window(segments: missing)
        case .ended, .gone, .unknown:
            let start = restartPiece(firstOutstanding: firstOutstanding, segmentDuration: segmentDuration, runtime: runtime)
            window = claimed.isEmpty ? Window(segments: [start], isProbe: true) : Window()
        case .running(let position):
            let current = Int(position / segmentDuration)
            let made = missing.filter { $0 + 2 <= current }
            window = Window(segments: made)
            let ahead = aheadLimit(segmentDuration: segmentDuration)
            if mayAskAhead, made.count < ahead {
                let next = missing.filter { $0 + 2 > current && $0 <= current + ahead }
                window.segments += next.prefix(ahead - made.count)
            }
        }
        if let limit { window.segments = Array(window.segments.prefix(max(0, limit))) }
        return window
    }

    /// Whether a piece handed to the session that hasn't started yet may stay there: asking for
    /// it now doesn't start the server's transcode somewhere else.
    static func mayStay(_ segment: Int, segmentDuration: Double, runtime: Double?, firstOutstanding: Int?, server: TranscodeServer,
                        isHeld: Bool) -> Bool {
        switch server {
        case .running(let position):
            return segment <= Int(position / segmentDuration) + aheadLimit(segmentDuration: segmentDuration)
        case .ended where isHeld:
            return true
        case .ended, .gone, .unknown:
            guard let firstOutstanding else { return false }
            return segment == restartPiece(firstOutstanding: firstOutstanding, segmentDuration: segmentDuration, runtime: runtime)
        }
    }

    /// How many pieces the app can count on the system fetching within `seconds` at
    /// `bytesPerSecond`, at least two: what's handed to it as the app leaves the screen with the
    /// transcode still running, before the server stops it for want of pings.
    static func fetchable(within seconds: Double, bytesPerSecond: Double?, bytesPerSegment: Double) -> Int {
        guard let bytesPerSecond, bytesPerSecond > 0, bytesPerSegment > 0 else { return 2 }
        return max(2, Int(bytesPerSecond * seconds / bytesPerSegment))
    }

    /// The pieces the playlist lists, leaving out a last one shorter than a frame, which the
    /// server has nothing to put in.
    static func usableCount(durations: [Double], frameRate: Double?) -> Int {
        guard let last = durations.last else { return 0 }
        let frame = 1 / (frameRate.flatMap { $0 > 0 ? $0 : nil } ?? 24)
        return last < frame ? durations.count - 1 : durations.count
    }
}

// MARK: Pacing

/// Telling the server pacing its transcode to the download (the administrator's Throttle
/// Transcodes): it pauses once it's ThrottleDelaySeconds (180 by default, 60 at least) past the
/// piece last asked for, and goes on for a few seconds at a time, between its checks, as
/// further pieces are asked for. Paced, it stands still between those requests and gets no
/// further than the download, give or take what it runs on between checks; running free, it
/// never stands still, and a server faster than the download gets ever further ahead. While it
/// moves with every look, its percentage says enough by itself.
nonisolated struct ThrottleWatch: Equatable, Sendable {
    struct Sighting: Equatable, Sendable {
        var at: Date
        var position: Double
        var downloadPosition: Double
    }

    /// What was seen of the server lately, while it was well ahead of the download.
    private(set) var sightings: [Sighting] = []
    private(set) var isThrottled = false

    /// How long the server has to keep pace to count.
    static let span: TimeInterval = 25
    /// How long a sighting is kept.
    static let memory: TimeInterval = 60
    /// How much further than the download the server may get while paced: what it makes, at
    /// several times real time, in the seconds between its checks.
    static let overshoot: Double = 45
    /// The least lead over the download the server pauses at.
    static let minimumLead: Double = 55

    /// Takes the server's position as seen at `now`, with the end of the furthest piece collected.
    mutating func observe(position: Double?, downloadPosition: Double, now: Date) {
        guard let position, position - downloadPosition >= Self.minimumLead else {
            self = ThrottleWatch()
            return
        }
        sightings.append(Sighting(at: now, position: position, downloadPosition: downloadPosition))
        sightings.removeAll { now.timeIntervalSince($0.at) > Self.memory }
        guard let first = sightings.first, now.timeIntervalSince(first.at) >= Self.span else {
            isThrottled = false
            return
        }
        let stood = zip(sightings, sightings.dropFirst()).contains { abs($1.position - $0.position) < 0.5 }
        isThrottled = stood && position - first.position <= downloadPosition - first.downloadPosition + Self.overshoot
    }
}
#endif
