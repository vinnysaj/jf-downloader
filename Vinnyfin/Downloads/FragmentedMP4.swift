#if !os(tvOS)
import Foundation

/// Reads the box structure of the fragmented MP4 a transcoded download is made of: the init
/// segment (ftyp, moov) and the pieces after it (styp, moof, mdat). Enough to tell a piece that
/// came through whole and fits the header from a cut-off, empty or foreign one, and where each
/// piece of the joined file starts and what stretch of the picture it covers.
nonisolated enum FragmentedMP4 {
    struct Problem: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What the init segment says about its tracks.
    struct Header: Equatable, Sendable {
        struct Track: Equatable, Sendable {
            var timescale: UInt32 = 0
            var isVideo = false
            var defaultDuration: UInt32 = 0
            var defaultSize: UInt32 = 0
        }

        var tracks: [UInt32: Track] = [:]
        /// Bytes the header takes at the start of the joined file.
        var length: Int64 = 0

        var videoTrack: UInt32? { tracks.first { $0.value.isVideo }?.key }
    }

    /// One piece as found: where it lies, and the stretch of the picture it covers in seconds.
    struct Piece: Equatable, Sendable {
        var range: Range<Int64>
        var videoStart: Double?
        var videoEnd: Double?
        var videoSamples = 0
        var fragments = 0

        /// No samples at all, as the server sends for a last piece past the end of the picture.
        var isEmpty: Bool { fragments == 0 || videoSamples == 0 }
    }

    /// One track's samples in a fragment. Decode times can start below zero: the server keeps
    /// the source's timestamps, and audio often starts a few milliseconds early.
    struct Run: Equatable, Sendable {
        var start: Int64
        var duration: Int64
        var count: Int
        var dataRange: Range<Int>?
    }

    // MARK: Header

    static func header(_ data: Data) throws -> Header {
        var header = Header()
        var sawMoov = false
        for box in try boxes(in: data, range: 0..<data.count) {
            if box.type == "moov" {
                sawMoov = true
                for child in try boxes(in: data, range: box.payload) {
                    if child.type == "trak" { try readTrack(data, child.payload, into: &header) }
                    if child.type == "mvex" {
                        for trex in try boxes(in: data, range: child.payload) where trex.type == "trex" {
                            let base = trex.payload.lowerBound + 4
                            guard trex.payload.count >= 24 else { throw Problem(message: "The header's trex box is cut short.") }
                            let id = data.uint32(at: base)
                            header.tracks[id, default: Header.Track()].defaultDuration = data.uint32(at: base + 8)
                            header.tracks[id, default: Header.Track()].defaultSize = data.uint32(at: base + 12)
                        }
                    }
                }
            }
            header.length = Int64(box.range.upperBound)
            if sawMoov { break }
        }
        guard sawMoov, !header.tracks.isEmpty else { throw Problem(message: "The header has no tracks.") }
        guard header.videoTrack != nil else { throw Problem(message: "The header has no video track.") }
        return header
    }

    private static func readTrack(_ data: Data, _ range: Range<Int>, into header: inout Header) throws {
        var id: UInt32?
        var track = Header.Track()
        for box in try boxes(in: data, range: range) {
            switch box.type {
            case "tkhd":
                let version = data.byte(at: box.payload.lowerBound)
                let offset = box.payload.lowerBound + 4 + (version == 1 ? 16 : 8)
                guard offset + 4 <= box.payload.upperBound else { throw Problem(message: "The header's tkhd box is cut short.") }
                id = data.uint32(at: offset)
            case "mdia":
                for child in try boxes(in: data, range: box.payload) {
                    if child.type == "mdhd" {
                        let version = data.byte(at: child.payload.lowerBound)
                        let offset = child.payload.lowerBound + 4 + (version == 1 ? 16 : 8)
                        guard offset + 4 <= child.payload.upperBound else { throw Problem(message: "The header's mdhd box is cut short.") }
                        track.timescale = data.uint32(at: offset)
                    }
                    if child.type == "hdlr", child.payload.count >= 12 {
                        track.isVideo = data.fourCC(at: child.payload.lowerBound + 8) == "vide"
                    }
                }
            default:
                continue
            }
        }
        guard let id else { throw Problem(message: "A track in the header has no number.") }
        var merged = header.tracks[id] ?? Header.Track()
        merged.timescale = track.timescale
        merged.isVideo = track.isVideo
        header.tracks[id] = merged
    }

    // MARK: Pieces

    /// Checks a piece on its own against the header: every box whole, at least one fragment, and
    /// each fragment's samples inside the media data after it. A piece without samples is
    /// returned as empty rather than refused.
    static func piece(_ data: Data, in range: Range<Int>? = nil, header: Header) throws -> Piece {
        let pieces = try pieces(in: data, range: range ?? 0..<data.count, header: header)
        guard pieces.count == 1, let piece = pieces.first else {
            throw Problem(message: pieces.isEmpty ? "The piece has no content." : "The piece holds \(pieces.count) pieces.")
        }
        return piece
    }

    /// The pieces in `range` of `data`: each starts with a styp box, or a moof when there is none.
    static func pieces(in data: Data, range: Range<Int>, header: Header) throws -> [Piece] {
        var pieces: [Piece] = []
        var current: Piece?
        var pendingMoof: (range: Range<Int>, samples: [UInt32: Run])?
        func finish() {
            if let piece = current { pieces.append(piece) }
            current = nil
        }
        for box in try boxes(in: data, range: range) {
            switch box.type {
            case "styp":
                if pendingMoof != nil { throw Problem(message: "A fragment at byte \(box.range.lowerBound) has no media data.") }
                finish()
                current = Piece(range: Int64(box.range.lowerBound)..<Int64(box.range.upperBound))
            case "moof":
                if pendingMoof != nil { throw Problem(message: "A fragment at byte \(box.range.lowerBound) has no media data.") }
                if current == nil { current = Piece(range: Int64(box.range.lowerBound)..<Int64(box.range.upperBound)) }
                pendingMoof = (box.range, try readFragment(data, box, header: header))
            case "mdat":
                guard let moof = pendingMoof else { throw Problem(message: "Media data at byte \(box.range.lowerBound) belongs to no fragment.") }
                for (id, run) in moof.samples {
                    if let dataRange = run.dataRange, dataRange.lowerBound < box.payload.lowerBound || dataRange.upperBound > box.payload.upperBound {
                        throw Problem(message: "A fragment at byte \(moof.range.lowerBound) points past its media data.")
                    }
                    guard var piece = current, let track = header.tracks[id], track.timescale > 0, track.isVideo else { continue }
                    let start = Double(run.start) / Double(track.timescale)
                    let end = Double(run.start &+ run.duration) / Double(track.timescale)
                    piece.videoStart = min(piece.videoStart ?? start, start)
                    piece.videoEnd = max(piece.videoEnd ?? end, end)
                    piece.videoSamples += run.count
                    current = piece
                }
                if var piece = current {
                    piece.fragments += 1
                    piece.range = piece.range.lowerBound..<Int64(box.range.upperBound)
                    current = piece
                }
                pendingMoof = nil
            case "sidx", "free", "skip", "prft", "emsg":
                if var piece = current {
                    piece.range = piece.range.lowerBound..<Int64(box.range.upperBound)
                    current = piece
                }
            default:
                throw Problem(message: "An unexpected \(box.type) box at byte \(box.range.lowerBound).")
            }
        }
        if pendingMoof != nil { throw Problem(message: "The last fragment has no media data.") }
        finish()
        return pieces
    }

    private static func readFragment(_ data: Data, _ moof: Box, header: Header)
        throws -> [UInt32: Run] {
        var runs: [UInt32: Run] = [:]
        for traf in try boxes(in: data, range: moof.payload) where traf.type == "traf" {
            var id: UInt32 = 0
            var defaultDuration: UInt32?
            var defaultSize: UInt32?
            var baseOffset = moof.range.lowerBound
            var decodeTime: Int64 = 0
            var duration: UInt64 = 0
            var count = 0
            var dataRange: Range<Int>?
            for child in try boxes(in: data, range: traf.payload) {
                let base = child.payload.lowerBound
                switch child.type {
                case "tfhd":
                    guard child.payload.count >= 8 else { throw Problem(message: "A tfhd box is cut short.") }
                    let flags = data.uint32(at: base) & 0xFFFFFF
                    id = data.uint32(at: base + 4)
                    var cursor = base + 8
                    if flags & 0x1 != 0 { baseOffset = Int(clamping: data.uint64(at: cursor)); cursor += 8 }
                    if flags & 0x2 != 0 { cursor += 4 }
                    if flags & 0x8 != 0 { defaultDuration = data.uint32(at: cursor); cursor += 4 }
                    if flags & 0x10 != 0 { defaultSize = data.uint32(at: cursor); cursor += 4 }
                    guard cursor <= child.payload.upperBound else { throw Problem(message: "A tfhd box is cut short.") }
                case "tfdt":
                    guard child.payload.count >= 8 else { throw Problem(message: "A tfdt box is cut short.") }
                    decodeTime = data.byte(at: base) == 1 ? Int64(bitPattern: data.uint64(at: base + 4)) : Int64(Int32(bitPattern: data.uint32(at: base + 4)))
                case "trun":
                    guard child.payload.count >= 8 else { throw Problem(message: "A trun box is cut short.") }
                    let flags = data.uint32(at: base) & 0xFFFFFF
                    let samples = Int(data.uint32(at: base + 4))
                    var cursor = base + 8
                    var offset: Int?
                    if flags & 0x1 != 0 { offset = Int(Int32(bitPattern: data.uint32(at: cursor))); cursor += 4 }
                    if flags & 0x4 != 0 { cursor += 4 }
                    let track = header.tracks[id]
                    let perSample = [0x100, 0x200, 0x400, 0x800].filter { flags & UInt32($0) != 0 }.count * 4
                    guard cursor + samples * perSample <= child.payload.upperBound else { throw Problem(message: "A trun box is cut short.") }
                    var size = 0
                    for _ in 0..<samples {
                        if flags & 0x100 != 0 {
                            duration += UInt64(data.uint32(at: cursor)); cursor += 4
                        } else {
                            duration += UInt64(defaultDuration ?? track?.defaultDuration ?? 0)
                        }
                        if flags & 0x200 != 0 {
                            size += Int(data.uint32(at: cursor)); cursor += 4
                        } else {
                            size += Int(defaultSize ?? track?.defaultSize ?? 0)
                        }
                        if flags & 0x400 != 0 { cursor += 4 }
                        if flags & 0x800 != 0 { cursor += 4 }
                    }
                    count += samples
                    if let offset { dataRange = (baseOffset + offset)..<(baseOffset + offset + size) }
                default:
                    continue
                }
            }
            guard header.tracks[id] != nil else { throw Problem(message: "A fragment names track \(id), which the header doesn't have.") }
            runs[id] = Run(start: decodeTime, duration: Int64(clamping: duration), count: count, dataRange: dataRange)
        }
        return runs
    }

    /// Where each piece of a joined file starts: its styp box. A box whose size makes no sense
    /// ends the walk there, and it picks up at the next styp, so the pieces after a damaged one
    /// are still found.
    static func pieceStarts(in data: Data, from start: Int) -> [Int] {
        var starts: [Int] = []
        var cursor = start
        let marker = Data("styp".utf8)
        while cursor + 8 <= data.count {
            let size = Int(data.uint32(at: cursor))
            let type = data.fourCC(at: cursor + 4)
            if type == "styp" { starts.append(cursor) }
            let isPlausible = size >= 8 && cursor + size <= data.count && type.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            if isPlausible {
                cursor += size
                continue
            }
            guard let found = data.range(of: marker, in: (cursor + 5)..<data.count) else { break }
            cursor = found.lowerBound - 4
        }
        return starts
    }

    // MARK: Boxes

    struct Box {
        let type: String
        let range: Range<Int>
        let payload: Range<Int>
    }

    /// The boxes one after another in `range`; a box that runs past it is cut short.
    static func boxes(in data: Data, range: Range<Int>) throws -> [Box] {
        var boxes: [Box] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor + 8 <= range.upperBound else { throw Problem(message: "A box at byte \(cursor) is cut short.") }
            var size = Int(data.uint32(at: cursor))
            let type = data.fourCC(at: cursor + 4)
            var headerSize = 8
            if size == 1 {
                guard cursor + 16 <= range.upperBound else { throw Problem(message: "A box at byte \(cursor) is cut short.") }
                size = Int(data.uint64(at: cursor + 8))
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - cursor
            }
            guard size >= headerSize, cursor + size <= range.upperBound else {
                throw Problem(message: "The \(type.isEmpty ? "box" : type + " box") at byte \(cursor) is cut short.")
            }
            boxes.append(Box(type: type, range: cursor..<(cursor + size), payload: (cursor + headerSize)..<(cursor + size)))
            cursor += size
        }
        return boxes
    }
}

private nonisolated extension Data {
    func uint32(at offset: Int) -> UInt32 {
        let index = startIndex + offset
        return self[index..<(index + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        let index = startIndex + offset
        return self[index..<(index + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    func byte(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func fourCC(at offset: Int) -> String {
        let index = startIndex + offset
        return String(decoding: self[index..<(index + 4)], as: UTF8.self)
    }
}
#endif
