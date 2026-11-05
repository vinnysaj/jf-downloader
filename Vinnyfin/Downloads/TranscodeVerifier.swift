#if !os(tvOS)
import AetherEngine
import CoreGraphics
import Foundation
import OSLog

/// Checks a transcoded download before it's shown as ready, and makes it the file that is: the
/// joined file starts with the transcode's init segment; every piece is whole, fits it, opens
/// with a keyframe, and follows on from the pieces before it in every track, each sample at its
/// own time, or takes over from them as a restarted transcode does (`TranscodeTimeline`); the
/// transcode reaches about as far as the title runs; then it's indexed as an ordinary MP4
/// (`FlattenedMP4`), and the player opens it, reads it as as long as the transcode, and shows a
/// picture at the start, the middle and the end.
///
/// A piece found damaged, out of place, or without the picture the player looked for (each
/// piece starts with a keyframe, so a picture comes from its own piece alone) is named, to be
/// fetched again; so is the end, when the transcode stops well short of the title's length.
/// Anything else that's wrong names no piece, and fetching every piece again wouldn't change
/// what the server makes: the download stops and keeps what it has, for a later build to check
/// again. Whatever the outcome but good, the file is left as it was.
nonisolated enum TranscodeVerifier {
    enum Outcome: Equatable, Sendable {
        /// The indexed file plays: it's `length` bytes, the player opened it in `openSeconds`, and
        /// its picture's dynamic range is `videoRangeType`, as the header names it.
        case good(length: Int64, openSeconds: Double, videoRangeType: String?)
        /// These pieces, by their place in the file, are bad: fetching them again mends it.
        case badPieces([Int: Place], reason: String)
        /// The transcode ends `delivered` seconds in, well short of the title's `runtime`.
        case endsEarly(delivered: Double, runtime: Double)
        /// Wrong in a way no piece can be blamed for.
        case unmendable(String)
    }

    /// Where a bad piece lies: its bytes in the file, and the stretch of the picture it covers in
    /// seconds of the transcode's timeline, `end` nil when it can't be read, and `start` then
    /// where the piece before it ends.
    struct Place: Equatable, Sendable {
        var bytes: Range<Int64>
        var start: Double
        var end: Double?
    }

    /// The joined file's pieces, each read and in its place.
    struct Structure: Equatable, Sendable {
        var header: FragmentedMP4.Header
        var pieces: [FragmentedMP4.Piece]
        var fileLength: Int64

        /// Where the transcode's picture starts and ends, in seconds of its timeline.
        var start: Double { pieces.first?.videoStart ?? 0 }
        var end: Double { pieces.last?.videoEnd ?? 0 }

        func place(_ index: Int) -> Place {
            let piece = pieces[index]
            let before = index > 0 ? pieces[index - 1].videoEnd : nil
            return Place(bytes: piece.range, start: piece.videoStart ?? before ?? 0, end: piece.videoStart == nil ? nil : piece.videoEnd)
        }
    }

    enum StructureCheck: Equatable, Sendable {
        case whole(Structure)
        case failed(Outcome)
    }

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "downloads")

    /// The player reads its input in blocks this big, and again from the start of one after each
    /// seek.
    static let playerReadBlock: Int64 = 256 << 10

    /// How far short of the title's length the transcode may end: a container's header can
    /// overstate the length of what it holds.
    static func shortfallAllowed(runtime: Double) -> Double { max(10, runtime * 0.02) }

    /// Checks `file`, the joined fragmented file, and indexes it in place. Throws when writing the
    /// index, or taking it out again, fails.
    @concurrent
    static func verify(_ file: URL, header: Data, runtime: Double?) async throws -> Outcome {
        let structure: Structure
        switch checkStructure(of: file, header: header) {
        case .whole(let whole): structure = whole
        case .failed(let outcome): return outcome
        }
        let delivered = structure.end - structure.start
        if let runtime, runtime > 0, delivered < runtime - shortfallAllowed(runtime: runtime) {
            return .endsEarly(delivered: delivered, runtime: runtime)
        }
        let index: FlattenedMP4.Index
        do {
            index = try FlattenedMP4.index(header: header, parsed: structure.header, pieces: structure.pieces,
                                           fileLength: structure.fileLength)
        } catch let misfit as FlattenedMP4.Misfit {
            return .badPieces([misfit.piece: structure.place(misfit.piece)], reason: misfit.message)
        } catch {
            return .unmendable("Its pieces can't be indexed: \(error.localizedDescription)")
        }
        let length: Int64
        do {
            length = try FlattenedMP4.write(index, into: file, length: structure.fileLength)
        } catch {
            try FlattenedMP4.undo(file, header: header, length: structure.fileLength)
            throw error
        }
        log.info("""
            Indexed \(file.lastPathComponent, privacy: .public): \(structure.pieces.count) pieces, \(index.moov.count) bytes of index, \
            its 0 at \(index.origin) s of the transcode
            """)
        let outcome = await checkPlayback(of: file, length: length, structure: structure, indexBytes: index.moov.count)
        if case .good = outcome { return outcome }
        try FlattenedMP4.undo(file, header: header, length: structure.fileLength)
        return outcome
    }

    /// The structure, read a piece at a time without decoding: the init segment first, then each
    /// piece whole, with pictures, starting with a keyframe.
    static func checkStructure(of file: URL, header: Data) -> StructureCheck {
        let parsedHeader: FragmentedMP4.Header
        let handle: FileHandle
        let length: Int
        do {
            parsedHeader = try FragmentedMP4.header(header)
            handle = try FileHandle(forReadingFrom: file)
            length = Int(try handle.seekToEnd())
        } catch {
            return .failed(.unmendable("The file can't be read: \(error.localizedDescription)"))
        }
        defer { try? handle.close() }
        func read(_ range: Range<Int>) throws -> Data {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let data = try handle.read(upToCount: range.count) ?? Data()
            guard data.count == range.count else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path]) }
            return data
        }
        let headerLength = Int(parsedHeader.length)
        var ranges: [Range<Int>]
        do {
            guard length >= header.count, try read(0..<header.count) == header else {
                return .failed(.unmendable("The file doesn't start with the transcode's init segment."))
            }
            let starts = try FragmentedMP4.pieceStarts(count: length, from: headerLength, read: read)
            ranges = zip(starts, starts.dropFirst() + [length]).map { $0..<$1 }
        } catch {
            return .failed(.unmendable("The file can't be read: \(error.localizedDescription)"))
        }
        // A first piece whose own start is damaged runs up to the second's.
        if let first = ranges.first?.lowerBound, first > headerLength {
            ranges.insert(headerLength..<first, at: 0)
        } else if ranges.isEmpty, length > headerLength {
            ranges = [headerLength..<length]
        }
        guard !ranges.isEmpty else { return .failed(.unmendable("The file holds no pieces.")) }
        var pieces: [FragmentedMP4.Piece] = []
        var bad: [Int] = []
        var reasons: [String] = []
        for (index, range) in ranges.enumerated() {
            let bytes = Int64(range.lowerBound)..<Int64(range.upperBound)
            do {
                let piece = try FragmentedMP4.piece(try read(range), header: parsedHeader).shifted(by: range.lowerBound)
                if piece.isEmpty || piece.videoStart == nil {
                    bad.append(index)
                    reasons.append("piece \(index) has no pictures")
                } else if !piece.startsWithSync {
                    bad.append(index)
                    reasons.append("piece \(index) doesn't start with a keyframe")
                }
                pieces.append(piece)
            } catch let error as FragmentedMP4.Problem {
                bad.append(index)
                reasons.append("piece \(index): \(error.message)")
                pieces.append(FragmentedMP4.Piece(range: bytes))
            } catch {
                return .failed(.unmendable("The file can't be read: \(error.localizedDescription)"))
            }
        }
        let structure = Structure(header: parsedHeader, pieces: pieces, fileLength: Int64(length))
        guard bad.isEmpty else {
            let places = Dictionary(uniqueKeysWithValues: bad.map { ($0, structure.place($0)) })
            return .failed(.badPieces(places, reason: reasons.prefix(3).joined(separator: "; ")))
        }
        return .whole(structure)
    }

    /// The pictures after one that its decoder may take in before showing it: the most an H.264
    /// or HEVC encoder may reorder (16), and two for the player's frame-threaded decoding.
    static let decodeLookahead = 18

    /// A picture the playback check decodes: when it's shown, in seconds into the indexed file,
    /// the piece it's in, and what decoding it may take.
    struct Still: Equatable, Sendable {
        var seconds: Double
        /// How long the picture is shown: the decode must land within half of it.
        var duration: Double
        var piece: Int
        var limits: ProbeLimits
    }

    /// The pictures the playback check decodes: the first, the last shown of a piece in the
    /// middle that the file holds whole, and the very last. Each is asked for by the time it's
    /// shown, so the decode lands on it at any frame rate, however far apart the pictures are.
    /// Decoding one may read the index and the pieces from its own through those holding the
    /// `decodeLookahead` pictures after it, and the piece before for where a seek lands: what
    /// a picture takes in a file indexed as it should be, at 1 fps as at 60.
    static func stills(in structure: Structure, indexBytes: Int) -> [Still] {
        let pieces = structure.pieces
        guard let video = structure.header.videoTrack, let timescale = structure.header.tracks[video]?.timescale, timescale > 0,
              !pieces.isEmpty
        else { return [] }
        // One a later run took over from is in the file only in part.
        let whole = pieces.indices.dropLast().filter { pieces[$0 + 1].videoStart ?? 0 >= (pieces[$0].videoEnd ?? 0) - 0.001 }
        let half = pieces.count / 2
        let middle = whole.min { (abs($0 - half), $0) < (abs($1 - half), $1) } ?? pieces.count - 1
        let largestSample = Int(pieces.map(\.largestSample).max() ?? 0)
        func still(in index: Int, last: Bool) -> Still? {
            let pictures = pieces[index].pictures(header: structure.header)
            guard let picture = last ? pictures.max(by: { $0.shown < $1.shown }) : pictures.min(by: { $0.shown < $1.shown }) else {
                return nil
            }
            var through = index
            var after = 0
            while through < pieces.count - 1, after < decodeLookahead {
                through += 1
                after += pieces[through].videoSamples
            }
            let stretch = pieces[max(0, index - 1)...through]
            let bytes = stretch.reduce(Int64(0)) { $0 + $1.range.upperBound - $1.range.lowerBound }
            let packets = stretch.reduce(0) { $0 + $1.sampleCount }
            return Still(seconds: Double(picture.shown) / Double(timescale) - structure.start,
                         duration: Double(picture.sample.duration) / Double(timescale), piece: index,
                         limits: ProbeLimits(maxInputBytes: structure.header.length + Int64(indexBytes) + bytes + 6 * playerReadBlock,
                                             maxPackets: packets + 16, maxPacketBytes: largestSample, timeBudget: 30))
        }
        return [still(in: 0, last: false), still(in: middle, last: true), still(in: pieces.count - 1, last: true)].compactMap { $0 }
    }

    /// Opens the indexed file as the player does, and decodes the pictures `stills` picks, each
    /// within what it may take.
    static func checkPlayback(of file: URL, length: Int64, structure: Structure, indexBytes: Int) async -> Outcome {
        let started = ContinuousClock.now
        let probe: SourceProbe
        do {
            probe = try AetherEngine.probe(url: file)
        } catch {
            return .unmendable("The player can't open it: \(error.localizedDescription)")
        }
        let elapsed = ContinuousClock.now - started
        let openSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        log.info("""
            Opened \(file.lastPathComponent, privacy: .public) in \(Int(openSeconds * 1000)) ms: \
            \(probe.durationSeconds) s, \(probe.videoWidth)x\(probe.videoHeight) \(probe.videoCodecName ?? "?", privacy: .public)
            """)
        guard probe.videoCodecID != 0 else { return .unmendable("The player finds no picture in it.") }
        let delivered = structure.end - structure.start
        if abs(probe.durationSeconds - delivered) > max(2, delivered * 0.01) {
            return .unmendable("The player reads it as \(Int(probe.durationSeconds)) s long, but the transcode runs \(Int(delivered)) s.")
        }
        for still in stills(in: structure, indexBytes: indexBytes) {
            let extractor = FrameExtractor(url: file)
            // A millisecond early: the decode takes the first picture shown from the time asked.
            let frame = await extractor.boundedSnapshot(at: still.seconds - 0.001, maxSize: CGSize(width: 320, height: 320),
                                                        limits: still.limits, cancellation: ProbeCancellation())
            await extractor.shutdown()
            guard let frame else {
                return .badPieces([still.piece: structure.place(still.piece)],
                                  reason: "The player shows no picture at \(String(format: "%.3f", still.seconds)) s.")
            }
            if let actual = frame.actualSeconds, abs(actual - still.seconds) > still.duration / 2 + 0.001 {
                return .unmendable(
                    "Asked for the picture at \(String(format: "%.3f", still.seconds)) s, the player shows the one at \(String(format: "%.3f", actual)) s.")
            }
        }
        return .good(length: length, openSeconds: openSeconds, videoRangeType: structure.header.videoRangeType)
    }
}
#endif
