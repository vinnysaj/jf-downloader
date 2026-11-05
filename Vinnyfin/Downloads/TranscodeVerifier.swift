#if !os(tvOS)
import AetherEngine
import CoreGraphics
import Foundation
import OSLog

/// Checks a transcoded download's joined file before it's shown as ready: it starts with the
/// transcode's init segment; every piece is whole, fits it and starts where its place on the
/// timeline is; the player opens it, reads it as the title's length, and shows a picture at the
/// start, the middle and the end.
nonisolated enum TranscodeVerifier {
    enum Outcome: Equatable, Sendable {
        /// `openSeconds` is how long the player took to open it.
        case good(openSeconds: Double)
        /// These pieces are bad, at these bytes of the file: fetching them again mends it.
        case badPieces([Int: Range<Int64>], reason: String)
        /// The file can't be mended piece by piece.
        case unusable(String)
    }

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "downloads")

    /// How far a piece's picture may start from where it belongs, in seconds.
    static let placementTolerance = 0.1

    @concurrent
    static func verify(_ file: URL, header: Data, expectedPieces: Int, segmentDuration: Double, runtime: Double?) async -> Outcome {
        let structure = checkStructure(of: file, header: header, expectedPieces: expectedPieces, segmentDuration: segmentDuration,
                                       runtime: runtime)
        guard case .good = structure else { return structure }
        return await checkPlayback(of: file, runtime: runtime, segmentDuration: segmentDuration, header: header)
    }

    /// The structure, read without decoding: the init segment first, then one piece per segment
    /// expected, each whole, with pictures, starting where its segment starts, the last ending
    /// about where the title does.
    static func checkStructure(of file: URL, header: Data, expectedPieces: Int, segmentDuration: Double,
                               runtime: Double?) -> Outcome {
        let parsedHeader: FragmentedMP4.Header
        let data: Data
        do {
            parsedHeader = try FragmentedMP4.header(header)
            data = try Data(contentsOf: file, options: .alwaysMapped)
        } catch {
            return .unusable("The file can't be read: \(error.localizedDescription)")
        }
        guard data.count >= header.count, data.prefix(header.count) == header else {
            return .unusable("The file doesn't start with the transcode's init segment.")
        }
        let ranges = pieceRanges(in: data, headerLength: Int(parsedHeader.length))
        guard ranges.first?.lowerBound == Int(parsedHeader.length) else {
            let end = ranges.first?.lowerBound ?? data.count
            return expectedPieces > 0 ? .badPieces([0: parsedHeader.length..<Int64(end)], reason: "The first piece is damaged.")
                : .unusable("The file has no pieces.")
        }
        guard ranges.count == expectedPieces else {
            return .unusable("The file holds \(ranges.count) pieces of the \(expectedPieces) expected.")
        }
        var bad: [Int: Range<Int64>] = [:]
        var reasons: [String] = []
        for (index, range) in ranges.enumerated() {
            let bytes = Int64(range.lowerBound)..<Int64(range.upperBound)
            let expectedStart = Double(index) * segmentDuration
            do {
                let piece = try FragmentedMP4.piece(data, in: range, header: parsedHeader)
                if piece.isEmpty {
                    bad[index] = bytes
                    reasons.append("piece \(index) has no pictures")
                } else if let start = piece.videoStart, abs(start - expectedStart) > placementTolerance {
                    bad[index] = bytes
                    reasons.append("piece \(index) starts at \(start.formatted(.number.precision(.fractionLength(2)))) s, not \(Int(expectedStart)) s")
                } else if index == ranges.count - 1, let runtime, let end = piece.videoEnd, abs(end - runtime) > max(1, segmentDuration) {
                    return .unusable("The picture ends at \(Int(end)) s, but the title runs \(Int(runtime)) s.")
                }
            } catch {
                bad[index] = bytes
                reasons.append("piece \(index): \(error.localizedDescription)")
            }
        }
        guard bad.isEmpty else { return .badPieces(bad, reason: reasons.prefix(3).joined(separator: "; ")) }
        return .good(openSeconds: 0)
    }

    /// Where each piece of a joined file lies, as its styp boxes tell, past the init segment.
    static func pieceRanges(in data: Data, headerLength: Int) -> [Range<Int>] {
        let starts = FragmentedMP4.pieceStarts(in: data, from: headerLength)
        return zip(starts, starts.dropFirst() + [data.count]).map { $0..<$1 }
    }

    /// Opens the file as the player does and decodes a picture at the start, the middle and the end.
    static func checkPlayback(of file: URL, runtime: Double?, segmentDuration: Double, header: Data) async -> Outcome {
        let started = ContinuousClock.now
        let probe: SourceProbe
        do {
            probe = try AetherEngine.probe(url: file)
        } catch {
            return .unusable("The player can't open it: \(error.localizedDescription)")
        }
        let elapsed = ContinuousClock.now - started
        let openSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        log.info("""
            Opened \(file.lastPathComponent, privacy: .public) in \(Int(openSeconds * 1000)) ms: \
            \(probe.durationSeconds) s, \(probe.videoWidth)x\(probe.videoHeight) \(probe.videoCodecName ?? "?", privacy: .public)
            """)
        guard probe.videoCodecID != 0 else { return .unusable("The player finds no picture in it.") }
        if let runtime, runtime > 0, abs(probe.durationSeconds - runtime) > max(2, runtime * 0.01) {
            return .unusable("The player reads it as \(Int(probe.durationSeconds)) s long, but the title runs \(Int(runtime)) s.")
        }
        let length = probe.durationSeconds > 0 ? probe.durationSeconds : (runtime ?? 0)
        let points = [min(1, length / 2), length / 2, max(0, length - 2)]
        let limits = ProbeLimits(maxInputBytes: 256 << 20, maxPackets: 2_000, maxPacketBytes: 32 << 20, timeBudget: 30)
        for point in points {
            let extractor = FrameExtractor(url: file)
            let still = await extractor.boundedSnapshot(at: point, maxSize: CGSize(width: 320, height: 320), limits: limits,
                                                        cancellation: ProbeCancellation())
            await extractor.shutdown()
            let index = max(0, Int(point / segmentDuration))
            let reason: String
            if let still {
                guard let actual = still.actualSeconds, abs(actual - point) > segmentDuration + 1 else { continue }
                reason = "Seeking to \(Int(point)) s lands at \(Int(actual)) s."
            } else {
                reason = "The player shows no picture at \(Int(point)) s."
            }
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped),
                  let range = pieceRanges(in: data, headerLength: header.count).dropFirst(index).first
            else { return .unusable(reason) }
            return .badPieces([index: Int64(range.lowerBound)..<Int64(range.upperBound)], reason: reason)
        }
        return .good(openSeconds: openSeconds)
    }
}
#endif
