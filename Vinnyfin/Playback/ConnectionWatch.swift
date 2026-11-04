import Foundation

/// Watches whether the connection keeps a stream playing, from a sample of the player about once
/// a second, and says when it doesn't and a cheaper version is called for.
///
/// It goes by what the viewer sees, the playhead against the clock, so it reads the same on every
/// decode path, and by the engine's measure of the link against the stream's bitrate, which tells
/// before the buffer runs dry. A short freeze now and then is left alone.
nonisolated struct ConnectionWatch {
    struct Sample: Equatable, Sendable {
        /// Seconds on a steady clock.
        var time: Double
        /// Playback is meant to be moving: not paused, seeking or reconnecting to a source that's gone.
        var isWanted: Bool
        /// The playhead, in media seconds.
        var position: Double
        /// The playback speed.
        var rate: Double = 1
        /// Media seconds buffered past the playhead.
        var bufferedAhead: Double = 0
        /// What the link delivers while it delivers, in bits per second; nil before it's measured.
        var throughput: Double?
        /// The stream's bitrate, in bits per second; nil when unknown.
        var bitrate: Double?
    }

    enum Reason: Equatable, Sendable {
        /// The stream took too long to start moving.
        case slowStart
        /// The picture froze for a long stretch.
        case stalled
        /// The picture keeps freezing.
        case stuttering
        /// The stream arrives slower than it plays and the buffer is about to run dry.
        case fallingBehind
    }

    /// A stream, or a seek, gets this long to start moving. It's longer than a freeze mid-play
    /// may last because it includes opening the file, which a cheaper version would pay again.
    static let slowStart: Double = 12
    /// A transcode's start includes the server's, which measured close to `slowStart` over a
    /// slow link, and which a cheaper transcode would pay again too.
    static let slowTranscodeStart: Double = 30
    /// One freeze this long is enough.
    static let longStall: Double = 8
    /// This much freezing in `stutterWindow`, over two freezes or more.
    static let stutterTotal: Double = 6
    static let stutterWindow: Double = 30
    /// The link has to deliver at least this share of what the stream needs...
    static let keepingUpShare: Double = 0.9
    /// ...or, this many samples in a row...
    static let fallingBehindSamples = 5
    /// ...it is falling behind, which matters once the buffer would run dry within this many seconds.
    static let runwayNeeded: Double = 30

    private struct Interval {
        let wanted: Double
        let frozen: Double
        let startsFreeze: Bool
    }

    /// The rate the link carries, by the best the engine measured over the last ten seconds, in
    /// bits per second: its figure for a moment can read well under what the link carries.
    var throughput: Double? { recentThroughput.map(\.rate).max() }

    /// The stream is a transcode, whose start gets `slowTranscodeStart`.
    private let isTranscode: Bool
    private var last: Sample?
    private var recentThroughput: [(time: Double, rate: Double)] = []
    /// Whether the playhead has moved since the stream or the seek began.
    private var hasMoved = false
    /// Wanted playback since it moved, newest last, covering `stutterWindow`.
    private var intervals: [Interval] = []
    private var currentFreeze: Double = 0
    private var samplesFallingBehind = 0

    init(isTranscode: Bool = false) {
        self.isTranscode = isTranscode
    }

    /// Starts over, as after a seek, whose wait is a start of its own.
    mutating func restart() {
        self = ConnectionWatch(isTranscode: isTranscode)
    }

    /// Takes the next sample. Returns why the stream needs to get cheaper, or nil while it's fine.
    mutating func observe(_ sample: Sample) -> Reason? {
        defer { last = sample }
        if let rate = sample.throughput { recentThroughput.append((sample.time, rate)) }
        recentThroughput.removeAll { sample.time - $0.time > 10 }
        guard sample.isWanted, let last, last.isWanted else {
            currentFreeze = 0
            samplesFallingBehind = 0
            return nil
        }
        let elapsed = sample.time - last.time
        let advanced = sample.position - last.position
        // A gap in the samples, or a jump of the playhead, says nothing about the connection.
        guard elapsed > 0, elapsed < 5, advanced >= -0.25, advanced <= elapsed * sample.rate + 1 else { return nil }

        let frozen = max(0, elapsed - max(0, advanced) / max(sample.rate, 0.1))
        let isFreezing = frozen > elapsed / 2
        if !hasMoved {
            guard !isFreezing else {
                currentFreeze += frozen
                return currentFreeze >= (isTranscode ? Self.slowTranscodeStart : Self.slowStart) ? .slowStart : nil
            }
            hasMoved = true
            currentFreeze = 0
        }

        intervals.append(Interval(wanted: elapsed, frozen: frozen, startsFreeze: isFreezing && currentFreeze == 0))
        currentFreeze = isFreezing ? currentFreeze + frozen : 0
        var wanted = intervals.reduce(0) { $0 + $1.wanted }
        while let first = intervals.first, wanted - first.wanted >= Self.stutterWindow {
            wanted -= first.wanted
            intervals.removeFirst()
        }
        if currentFreeze >= Self.longStall { return .stalled }
        if intervals.filter(\.startsFreeze).count >= 2, intervals.reduce(0, { $0 + $1.frozen }) >= Self.stutterTotal {
            return .stuttering
        }

        guard let throughput = sample.throughput, let bitrate = sample.bitrate, bitrate > 0,
              throughput < bitrate * sample.rate * Self.keepingUpShare
        else {
            samplesFallingBehind = 0
            return nil
        }
        samplesFallingBehind += 1
        // Media seconds the buffer loses each second at this pace.
        let drain = sample.rate - throughput / bitrate
        let runsDrySoon = sample.bufferedAhead < Self.runwayNeeded * drain
        return samplesFallingBehind >= Self.fallingBehindSamples && runsDrySoon ? .fallingBehind : nil
    }
}
