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
    /// made, so its init segment is compared with the one kept before any newer piece counts.
    var needsInitCheck = false
    /// Pieces collected while `needsInitCheck` was set, which count once the init segment matches.
    var unchecked = IndexSet()

    /// What the server's playlist says of the stream it makes: `CODECS="avc1.640028,ac-3",
    /// RESOLUTION=1280x720` and the like.
    var variant: String?

    /// The server's position the last time it was seen transcoding, in seconds, and when, and
    /// how many seconds of the title it was making a second.
    var serverPosition: Double?
    var serverSeenAt: Date?
    var serverSpeed: Double?
    /// When the server was first seen not transcoding after that: its transcode ended before then.
    var serverQuietAt: Date?
    /// When the server's transcode was first seen to have reached the end.
    var serverFinishedAt: Date?
    /// When the server last acknowledged a ping for this download: it stops a transcode a minute
    /// after the last.
    var lastPing: Date?
    /// When the server's init segment last matched the one kept.
    var initCheckedAt: Date?

    /// Whether a piece arriving at `now` may be from a transcode the server started again after
    /// stopping its own for want of pings (the app was suspended or closed meanwhile), and the
    /// init segment hasn't been checked since it could have.
    func isLapsed(at now: Date) -> Bool {
        guard serverFinishedAt == nil, let lastPing else { return false }
        let mayHaveStopped = lastPing.addingTimeInterval(TranscodeServer.killDelay)
        return now > mayHaveStopped && (initCheckedAt ?? .distantPast) < mayHaveStopped
    }
    /// Where the server's transcode last stopped short of the end on its own, and how many times
    /// in a row it did about there.
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
}

// MARK: The server's transcode

/// What the app knows about the server's transcode for a download.
nonisolated enum TranscodeServer: Equatable, Sendable {
    /// Nothing heard yet in this run of the app.
    case unknown
    /// Transcoding, this far in seconds.
    case running(position: Double)
    /// Done: every piece from where it last started is on the server, as files, until it's
    /// cleaned up.
    case finished
    /// Not transcoding, short of the end. Its pieces up to `madeUpTo` are still on the server
    /// (it stopped by itself), or none are (nil: it was stopped for want of pings, which deletes
    /// them). Asking for a piece it doesn't have starts it again there.
    case stopped(madeUpTo: Double?)
    /// The server doesn't know the download's device: it restarted, and its transcodes went with it.
    case gone

    var position: Double? {
        if case .running(let position) = self { position } else { nil }
    }

    /// How long after the last ping the server stops a transcode, deleting its files.
    static let killDelay: TimeInterval = 60
    /// The server's cleanup deletes transcode files a day after they were written.
    static let keptFor: TimeInterval = 20 * 60 * 60

    /// How far behind ffmpeg the percentage the server lists can be, in seconds of its work: the
    /// server takes it from ffmpeg's progress lines, and ffmpeg makes its last pieces between two
    /// looks at it.
    static let progressLag: TimeInterval = 5

    /// What the server's sessions for the download's device say, read against what was known:
    /// the position it was last seen at, when, and how fast it went; when it was first seen not
    /// transcoding since; when it was last pinged.
    ///
    /// The server clears its percentage once ffmpeg exits, whether it finished, failed or was
    /// stopped. It finished if, going as fast as it was, it would have reached the last piece
    /// before it was first seen quiet, or before the server stopped it a minute after the last
    /// ping, allowing for the percentage lagging. Otherwise it stopped short: by itself,
    /// keeping its pieces, if it was pinged within the minute; else for want of pings, which
    /// deletes them.
    static func interpret(sessionFound: Bool, transcoding: TranscodingInfo?, state: TranscodeState, speed: Double?,
                          now: Date) -> TranscodeServer {
        guard sessionFound else { return .gone }
        if let percent = transcoding?.completionPercentage, let runtime = state.runtimeSeconds, runtime > 0 {
            return .running(position: percent / 100 * runtime)
        }
        if let finishedAt = state.serverFinishedAt {
            return now.timeIntervalSince(finishedAt) < keptFor ? .finished : .stopped(madeUpTo: nil)
        }
        guard transcoding != nil, let position = state.serverPosition, let seenAt = state.serverSeenAt else {
            return .stopped(madeUpTo: nil)
        }
        let lastPing = state.lastPing ?? seenAt
        let pinged = now.timeIntervalSince(lastPing) < killDelay
        // The last piece is made last: a quiet server that had it, its pieces kept, got to the end.
        if pinged, let count = state.segmentCount, count > 0, state.collected.contains(count - 1) { return .finished }
        let ended = min(now, state.serverQuietAt ?? now, max(seenAt, lastPing.addingTimeInterval(killDelay)))
        let reach = position + (speed ?? 0) * (max(0, ended.timeIntervalSince(seenAt)) + progressLag)
        if reach >= state.endPosition { return .finished }
        return pinged ? .stopped(madeUpTo: position) : .stopped(madeUpTo: nil)
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
        /// Asking for them starts the server's transcode (again) at the first.
        var startsTranscode = false
    }

    /// The server starts its transcode again at a piece more than 24 / length pieces past the
    /// newest it has made. Asking for at most this many past it keeps well inside that.
    static func aheadLimit(segmentDuration: Double) -> Int {
        max(1, min(4, Int(24 / max(1, segmentDuration.rounded())) / 2))
    }

    /// In front, pieces of a finished transcode are handed to the session this many at a time,
    /// which is plenty for its four connections and little to take back if the transcode turns
    /// out not to be finished after all.
    static let finishedBatch = 16

    /// The pieces that may be asked for now, lowest first, leaving out those collected and
    /// those `claimed` by transfers under way.
    ///
    /// - Once the server has finished, every piece left, up to `limit`.
    /// - While it transcodes, the pieces it has made (each ends at least a piece behind it),
    ///   then, once fewer than `aheadLimit` of those are left, up to `aheadLimit` past its
    ///   position, which it serves as it makes them, when `mayAskAhead`.
    /// - Stopped by itself, the pieces it left on the server, then the last piece, alone: a
    ///   transcode that got to the end before its progress said so has it there, and one that
    ///   failed starts again to make it; the pieces asked for next then start it where they are,
    ///   which shows as it running.
    /// - Stopped for want of pings (its pieces deleted), gone or not known, the first piece
    ///   missing, alone: asking for it starts the transcode there, and the output joins cleanly.
    /// - While the init segment has to be checked, nothing but the one piece that tells.
    static func window(segmentCount: Int, segmentDuration: Double, collected: IndexSet, claimed: Set<Int>,
                       server: TranscodeServer, needsInitCheck: Bool, mayAskAhead: Bool, limit: Int? = nil) -> Window {
        let outstanding = (0..<segmentCount).filter { !collected.contains($0) }
        let missing = outstanding.filter { !claimed.contains($0) }
        guard let firstOutstanding = outstanding.first, !missing.isEmpty else { return Window() }
        let alone = claimed.isEmpty ? Window(segments: [firstOutstanding], startsTranscode: true) : Window()
        var window: Window
        switch server {
        case _ where needsInitCheck:
            window = alone
        case .finished:
            window = Window(segments: missing)
        case .running(let position):
            let current = Int(position / segmentDuration)
            let made = missing.filter { $0 + 2 <= current }
            window = Window(segments: made)
            let ahead = aheadLimit(segmentDuration: segmentDuration)
            if mayAskAhead, made.count < ahead {
                let next = missing.filter { $0 + 2 > current && $0 <= current + ahead }
                window.segments += next.prefix(ahead - made.count)
            }
        case .stopped(let madeUpTo):
            let made = madeUpTo.map { end in missing.filter { Double($0 + 2) * segmentDuration <= end } } ?? []
            if !made.isEmpty {
                window = Window(segments: made)
            } else if madeUpTo != nil, claimed.isEmpty, missing.last == segmentCount - 1 {
                window = Window(segments: [segmentCount - 1], startsTranscode: true)
            } else {
                window = alone
            }
        case .unknown, .gone:
            window = alone
        }
        if let limit { window.segments = Array(window.segments.prefix(max(0, limit))) }
        return window
    }

    /// Whether a piece handed to the session that hasn't started yet may stay there: asking for
    /// it now doesn't start the server's transcode somewhere else.
    static func mayStay(_ segment: Int, segmentCount: Int, segmentDuration: Double, firstOutstanding: Int?,
                        server: TranscodeServer) -> Bool {
        switch server {
        case .finished:
            return true
        case .running(let position):
            return segment <= Int(position / segmentDuration) + aheadLimit(segmentDuration: segmentDuration)
        case .stopped(let madeUpTo):
            if let madeUpTo, Double(segment + 2) * segmentDuration <= madeUpTo || segment == segmentCount - 1 { return true }
            return segment == firstOutstanding
        case .unknown, .gone:
            return segment == firstOutstanding
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
