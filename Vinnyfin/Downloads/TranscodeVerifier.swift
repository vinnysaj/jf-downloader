#if !os(tvOS)
import AetherEngine
import CoreGraphics
import Foundation
import OSLog

/// Checks a transcoded download before it's shown as ready, and makes the file that is: the
/// joined file starts with the transcode's init segment; every piece is whole, fits it, and
/// starts where its place on the timeline is, counted from where the first piece starts; then
/// it's indexed as an ordinary MP4 (`FlattenedMP4`), and the player opens that, reads it as the
/// title's length, and shows a picture at the start, the middle and the end.
///
/// A piece found damaged, out of place, or without the picture the player looked for (each
/// piece starts with a keyframe, so a picture comes from its own piece alone) is named, to be
/// fetched again. Anything else that's wrong names no piece, and fetching every piece again
/// wouldn't change what the server makes: the download stops and keeps what it has, for a later
/// build to check again.
nonisolated enum TranscodeVerifier {
    enum Outcome: Equatable, Sendable {
        /// The indexed file plays: it's `length` bytes, and the player opened it in `openSeconds`.
        case good(length: Int64, openSeconds: Double)
        /// These pieces are bad, at these bytes of the joined file: fetching them again mends it.
        case badPieces([Int: Range<Int64>], reason: String)
        /// Wrong in a way no piece can be blamed for.
        case unmendable(String)
    }

    /// The joined file's pieces, each read and in its place.
    struct Structure: Equatable, Sendable {
        var header: FragmentedMP4.Header
        var pieces: [FragmentedMP4.Piece]
        var fileLength: Int64
    }

    enum StructureCheck: Equatable, Sendable {
        case whole(Structure)
        case failed(Outcome)
    }

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "downloads")

    /// How far a piece's picture may start from where it belongs, in seconds.
    static let placementTolerance = 0.1

    /// The player reads its input in blocks this big, and again from the start of one after each
    /// seek.
    static let playerReadBlock: Int64 = 256 << 10

    /// Checks `partial`, the joined fragmented file, and writes the indexed file at `joined`.
    /// Throws when writing it fails.
    @concurrent
    static func verify(_ partial: URL, into joined: URL, header: Data, expectedPieces: Int, segmentDuration: Double,
                       runtime: Double?) async throws -> Outcome {
        let structure: Structure
        switch checkStructure(of: partial, header: header, expectedPieces: expectedPieces, segmentDuration: segmentDuration) {
        case .whole(let whole): structure = whole
        case .failed(let outcome): return outcome
        }
        let index: FlattenedMP4.Index
        do {
            index = try FlattenedMP4.index(header: header, parsed: structure.header, pieces: structure.pieces,
                                           fileLength: structure.fileLength)
        } catch {
            return .unmendable("Its pieces can't be indexed: \(error.localizedDescription)")
        }
        let length = try FlattenedMP4.write(index, from: partial, to: joined)
        log.info("""
            Indexed \(joined.lastPathComponent, privacy: .public): \(structure.pieces.count) pieces, \(index.moov.count) bytes of index, \
            its 0 at \(index.origin) s of the transcode
            """)
        return await checkPlayback(of: joined, length: length, structure: structure, indexBytes: index.moov.count,
                                   segmentDuration: segmentDuration, runtime: runtime)
    }

    /// The structure, read a piece at a time without decoding: the init segment first, then one
    /// piece per segment expected, each whole, with pictures, starting where its segment does.
    static func checkStructure(of file: URL, header: Data, expectedPieces: Int, segmentDuration: Double) -> StructureCheck {
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
        guard ranges.count == expectedPieces else {
            return .failed(.unmendable("The file holds \(ranges.count) pieces where \(expectedPieces) were fetched."))
        }
        var pieces: [FragmentedMP4.Piece?] = []
        var bad: [Int: Range<Int64>] = [:]
        var reasons: [String] = []
        for (index, range) in ranges.enumerated() {
            let bytes = Int64(range.lowerBound)..<Int64(range.upperBound)
            do {
                let piece = try FragmentedMP4.piece(try read(range), header: parsedHeader).shifted(by: range.lowerBound)
                guard !piece.isEmpty, piece.videoStart != nil else {
                    bad[index] = bytes
                    reasons.append("piece \(index) has no pictures")
                    pieces.append(nil)
                    continue
                }
                pieces.append(piece)
            } catch let error as FragmentedMP4.Problem {
                bad[index] = bytes
                reasons.append("piece \(index): \(error.message)")
                pieces.append(nil)
            } catch {
                return .failed(.unmendable("The file can't be read: \(error.localizedDescription)"))
            }
        }
        // Where the timeline starts: what most pieces agree on, which is the first piece's start
        // when it's in its place.
        let offsets = pieces.enumerated().compactMap { index, piece in piece?.videoStart.map { $0 - Double(index) * segmentDuration } }
        if let origin = offsets.sorted().dropFirst((offsets.count - 1) / 2).first {
            for (index, piece) in pieces.enumerated() {
                guard let start = piece?.videoStart else { continue }
                let expected = origin + Double(index) * segmentDuration
                if abs(start - expected) > placementTolerance {
                    bad[index] = Int64(ranges[index].lowerBound)..<Int64(ranges[index].upperBound)
                    reasons.append("piece \(index) starts \(Self.seconds(start - origin)) s in, not \(Self.seconds(expected - origin)) s")
                }
            }
        }
        guard bad.isEmpty else { return .failed(.badPieces(bad, reason: reasons.prefix(3).joined(separator: "; "))) }
        return .whole(Structure(header: parsedHeader, pieces: pieces.compactMap(\.self), fileLength: Int64(length)))
    }

    /// Opens the indexed file as the player does, and decodes a picture at the start, the middle
    /// and the end. The player may read no more than the index and a couple of the largest pieces
    /// for each picture: what a picture takes in a file indexed as it should be.
    static func checkPlayback(of file: URL, length: Int64, structure: Structure, indexBytes: Int, segmentDuration: Double,
                              runtime: Double?) async -> Outcome {
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
        if let runtime, runtime > 0, abs(probe.durationSeconds - runtime) > max(2, runtime * 0.01) {
            return .unmendable("The player reads it as \(Int(probe.durationSeconds)) s long, but the title runs \(Int(runtime)) s.")
        }
        let pieces = structure.pieces
        let largestPiece = pieces.map { $0.range.upperBound - $0.range.lowerBound }.max() ?? 0
        let limits = ProbeLimits(maxInputBytes: structure.header.length + Int64(indexBytes) + 2 * largestPiece + 6 * playerReadBlock,
                                 maxPackets: 2 * (pieces.map(\.sampleCount).max() ?? 0) + 16,
                                 maxPacketBytes: Int(pieces.map(\.largestSample).max() ?? 0),
                                 timeBudget: 30)
        let duration = probe.durationSeconds > 0 ? probe.durationSeconds : (runtime ?? 0)
        for point in [min(1, duration / 2), duration / 2, max(0, duration - 2)] {
            let extractor = FrameExtractor(url: file)
            let still = await extractor.boundedSnapshot(at: point, maxSize: CGSize(width: 320, height: 320), limits: limits,
                                                        cancellation: ProbeCancellation())
            await extractor.shutdown()
            guard let still else {
                let index = min(pieces.count - 1, max(0, Int(point / segmentDuration)))
                return .badPieces([index: pieces[index].range], reason: "The player shows no picture at \(Int(point)) s.")
            }
            if let actual = still.actualSeconds, abs(actual - point) > segmentDuration + 1 {
                return .unmendable("Seeking to \(Int(point)) s lands at \(Int(actual)) s.")
            }
        }
        return .good(length: length, openSeconds: openSeconds)
    }

    private static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}
#endif
