#if !os(tvOS)
import Foundation

/// Reads the box structure of the fragmented MP4 a transcoded download is made of: the init
/// segment (ftyp, moov) and the pieces after it (styp, moof, mdat). Enough to tell a piece that
/// came through whole and fits the header from a cut-off, empty or foreign one, where each piece
/// of the joined file starts and what stretch of each track it covers, where a later piece can
/// take over from its pictures, and every sample's size, timing and place, which `FlattenedMP4`
/// turns into an ordinary MP4's sample tables.
///
/// Each fragment's samples have to fill its media data exactly, and their insides have to hold
/// together as far as their lengths tell without decoding: a video sample is NAL units, each after
/// its length, that add up to the sample; an AC-3 frame starts with its sync word. That catches
/// bytes damaged where a length or a frame start lies; damage inside a NAL unit's or an audio
/// frame's payload passes.
nonisolated enum FragmentedMP4 {
    struct Problem: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What a track's samples hold, as far as the check reads them.
    enum SampleFormat: Equatable, Sendable {
        /// H.264 or HEVC: NAL units, each after its length in this many bytes.
        case nalUnits(lengthSize: Int)
        /// AC-3 or E-AC-3: frames starting with the sync word 0x0B77.
        case ac3Frames
        /// Nothing inside that can be checked without decoding: AAC, FLAC, ALAC.
        case opaque
    }

    /// What the init segment says about its tracks.
    struct Header: Equatable, Sendable {
        struct Track: Equatable, Sendable {
            var timescale: UInt32 = 0
            var isVideo = false
            var defaultDuration: UInt32 = 0
            var defaultSize: UInt32 = 0
            var defaultFlags: UInt32 = 0
            /// Where its edit list starts presenting the media, in its timescale: the media time of
            /// its first edit less any empty edit before it. A decode time minus this is when a
            /// sample is presented, before its composition offset.
            var presentationOffset: Int64 = 0
            var format = SampleFormat.opaque
            /// The picture's transfer characteristics (ITU-T H.273) from its sample entry's colr
            /// box: 16 is PQ (HDR10), 18 HLG, anything else SDR.
            var colourTransfer: UInt16?
            /// How many samples before one its decoder needs, as a roll distance (ISO/IEC 14496-12
            /// 'roll' sample group): -1 for AAC, whose frames overlap the one before. Nil for
            /// samples that decode alone.
            var rollDistance: Int16?
        }

        var tracks: [UInt32: Track] = [:]
        var movieTimescale: UInt32 = 1000
        /// Bytes the header takes at the start of the joined file.
        var length: Int64 = 0

        var videoTrack: UInt32? { tracks.first { $0.value.isVideo }?.key }

        /// The picture's dynamic range as Jellyfin names it ("SDR", "HDR10", "HLG"), from what the
        /// header says of its colour; nil when it says nothing.
        var videoRangeType: String? {
            guard let transfer = videoTrack.flatMap({ tracks[$0]?.colourTransfer }) else { return nil }
            return switch transfer {
            case 16: "HDR10"
            case 18: "HLG"
            default: "SDR"
            }
        }
    }

    struct Sample: Equatable, Sendable {
        var duration: UInt32
        var size: UInt32
        var compositionOffset: Int32
        var isSync: Bool
    }

    /// One track's samples in a fragment, one after another in its media data.
    struct Run: Equatable, Sendable {
        var track: UInt32
        /// The first sample's, in the track's timescale. Decode times can start below zero: the
        /// server keeps the source's timestamps, and audio often starts a few milliseconds early.
        var decodeTime: Int64
        /// Where its first sample's bytes are in the data read.
        var dataOffset: Int
        var samples: [Sample]

        var duration: Int64 { samples.reduce(0) { $0 + Int64($1.duration) } }
        var byteCount: Int { samples.reduce(0) { $0 + Int($1.size) } }
        var dataRange: Range<Int> { dataOffset..<(dataOffset + byteCount) }
    }

    /// Where a track's samples in a piece are shown, on the transcode's timeline in the track's
    /// timescale: each sample's decode time plus its composition offset, less the header's
    /// presentation offset, so a picture's time is the source's time for it.
    struct Span: Equatable, Sendable {
        /// When its earliest sample is shown.
        var start: Int64
        /// When its latest sample stops being shown.
        var end: Int64
        /// The duration of its first sample in decode order: a frame, or an audio frame.
        var sampleDuration: Int64
    }

    /// One piece as found: where it lies, the stretch of each track it covers, and its samples.
    struct Piece: Equatable, Sendable {
        var range: Range<Int64>
        var fragments = 0
        var runs: [Run] = []
        var spans: [UInt32: Span] = [:]
        var videoSamples = 0
        /// The video's first sample in decode order is a sync sample (a keyframe), which the
        /// server starts every piece with: decoding can start there, given, for pictures that
        /// lead it in an open GOP of a copied picture (shown before it, decoded after), the
        /// pictures before it, which the piece it follows or takes over from has.
        var startsWithSync = false
        /// The picture's stretch in seconds.
        var videoStart: Double?
        var videoEnd: Double?

        /// No samples at all, as the server sends for a piece past the end of the picture.
        var isEmpty: Bool { fragments == 0 || videoSamples == 0 }
        var sampleCount: Int { runs.reduce(0) { $0 + $1.samples.count } }
        var largestSample: UInt32 { runs.lazy.flatMap(\.samples).map(\.size).max() ?? 0 }

        /// The piece as it lies `offset` bytes further on, as one read on its own does in the
        /// joined file.
        func shifted(by offset: Int) -> Piece {
            var piece = self
            piece.range = (range.lowerBound + Int64(offset))..<(range.upperBound + Int64(offset))
            for index in piece.runs.indices { piece.runs[index].dataOffset += offset }
            return piece
        }

        /// The video's samples in decode order, each with the time it's shown at, as in `Span`.
        func pictures(header: Header) -> [(sample: Sample, shown: Int64)] {
            guard let id = header.videoTrack, let track = header.tracks[id] else { return [] }
            var samples: [(Sample, Int64)] = []
            for run in runs where run.track == id {
                var time = run.decodeTime
                for sample in run.samples {
                    samples.append((sample, time + Int64(sample.compositionOffset) - track.presentationOffset))
                    time += Int64(sample.duration)
                }
            }
            return samples
        }
    }

    /// The times, in decode order of `samples`, at which a later sample can take over: every
    /// sample shown before one of them is decoded before every sample shown from it, so the
    /// samples from there on can be left out without a sample kept missing what it refers to.
    /// A restarted transcode's piece can follow the pictures kept up to one of these.
    static func cleanCuts(_ samples: [(sample: Sample, shown: Int64)]) -> [Int64] {
        var earliestFrom = Array(repeating: Int64.max, count: samples.count + 1)
        for index in samples.indices.reversed() { earliestFrom[index] = min(samples[index].shown, earliestFrom[index + 1]) }
        var cuts: [Int64] = []
        var latestBefore = Int64.min
        for index in samples.indices {
            if earliestFrom[index] > latestBefore { cuts.append(earliestFrom[index]) }
            latestBefore = max(latestBefore, samples[index].shown)
        }
        return cuts
    }

    // MARK: Header

    static func header(_ data: Data) throws -> Header {
        var header = Header()
        var sawMoov = false
        for box in try boxes(in: data, range: 0..<data.count) {
            if box.type == "moov" {
                sawMoov = true
                for child in try boxes(in: data, range: box.payload) {
                    switch child.type {
                    case "mvhd":
                        let version = data.byte(at: child.payload.lowerBound)
                        let offset = child.payload.lowerBound + 4 + (version == 1 ? 16 : 8)
                        guard offset + 4 <= child.payload.upperBound else { throw Problem(message: "The header's mvhd box is cut short.") }
                        header.movieTimescale = max(1, data.uint32(at: offset))
                    case "trak":
                        try readTrack(data, child.payload, into: &header)
                    case "mvex":
                        for trex in try boxes(in: data, range: child.payload) where trex.type == "trex" {
                            let base = trex.payload.lowerBound + 4
                            guard trex.payload.count >= 24 else { throw Problem(message: "The header's trex box is cut short.") }
                            let id = data.uint32(at: base)
                            header.tracks[id, default: Header.Track()].defaultDuration = data.uint32(at: base + 8)
                            header.tracks[id, default: Header.Track()].defaultSize = data.uint32(at: base + 12)
                            header.tracks[id, default: Header.Track()].defaultFlags = data.uint32(at: base + 16)
                        }
                    default:
                        continue
                    }
                }
            }
            header.length = Int64(box.range.upperBound)
            if sawMoov { break }
        }
        guard sawMoov, !header.tracks.isEmpty else { throw Problem(message: "The header has no tracks.") }
        guard header.videoTrack != nil else { throw Problem(message: "The header has no video track.") }
        for (id, track) in header.tracks where track.timescale == 0 {
            throw Problem(message: "Track \(id) in the header has no timescale.")
        }
        return header
    }

    private static func readTrack(_ data: Data, _ range: Range<Int>, into header: inout Header) throws {
        var id: UInt32?
        var track = Header.Track()
        var emptyEdit: Int64 = 0
        var mediaTime: Int64 = 0
        for box in try boxes(in: data, range: range) {
            switch box.type {
            case "tkhd":
                let version = data.byte(at: box.payload.lowerBound)
                let offset = box.payload.lowerBound + 4 + (version == 1 ? 16 : 8)
                guard offset + 4 <= box.payload.upperBound else { throw Problem(message: "The header's tkhd box is cut short.") }
                id = data.uint32(at: offset)
            case "edts":
                for elst in try boxes(in: data, range: box.payload) where elst.type == "elst" {
                    (emptyEdit, mediaTime) = try readEditList(data, elst.payload)
                }
            case "mdia":
                for child in try boxes(in: data, range: box.payload) {
                    switch child.type {
                    case "mdhd":
                        let version = data.byte(at: child.payload.lowerBound)
                        let offset = child.payload.lowerBound + 4 + (version == 1 ? 16 : 8)
                        guard offset + 4 <= child.payload.upperBound else { throw Problem(message: "The header's mdhd box is cut short.") }
                        track.timescale = data.uint32(at: offset)
                    case "hdlr" where child.payload.count >= 12:
                        track.isVideo = data.fourCC(at: child.payload.lowerBound + 8) == "vide"
                    case "minf":
                        for stbl in try boxes(in: data, range: child.payload) where stbl.type == "stbl" {
                            for stsd in try boxes(in: data, range: stbl.payload) where stsd.type == "stsd" {
                                track.format = try sampleFormat(data, stsd.payload)
                                track.colourTransfer = try colourTransfer(data, stsd.payload)
                                track.rollDistance = try rollDistance(data, stsd.payload)
                            }
                        }
                    default:
                        continue
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
        merged.format = track.format
        merged.colourTransfer = track.colourTransfer
        merged.rollDistance = track.rollDistance
        // The empty edit is in the movie's timescale, which mvhd gave before the tracks.
        let dwell = header.movieTimescale > 0 ? emptyEdit * Int64(track.timescale) / Int64(header.movieTimescale) : 0
        merged.presentationOffset = mediaTime - dwell
        header.tracks[id] = merged
    }

    /// The empty edit at the start of an edit list, in the movie's timescale, and the media time
    /// of the first edit that shows media.
    private static func readEditList(_ data: Data, _ payload: Range<Int>) throws -> (empty: Int64, mediaTime: Int64) {
        guard payload.count >= 8 else { throw Problem(message: "The header's elst box is cut short.") }
        let version = data.byte(at: payload.lowerBound)
        let count = Int(data.uint32(at: payload.lowerBound + 4))
        let entrySize = version == 1 ? 20 : 12
        guard payload.lowerBound + 8 + count * entrySize <= payload.upperBound else { throw Problem(message: "The header's elst box is cut short.") }
        var empty: Int64 = 0
        for index in 0..<count {
            let entry = payload.lowerBound + 8 + index * entrySize
            let duration = version == 1 ? Int64(clamping: data.uint64(at: entry)) : Int64(data.uint32(at: entry))
            let time = version == 1 ? Int64(bitPattern: data.uint64(at: entry + 8)) : Int64(Int32(bitPattern: data.uint32(at: entry + 4)))
            if time == -1 {
                empty += duration
            } else {
                return (empty, time)
            }
        }
        return (empty, 0)
    }

    /// What the first sample entry says the samples hold.
    private static func sampleFormat(_ data: Data, _ payload: Range<Int>) throws -> SampleFormat {
        guard payload.count >= 8 else { throw Problem(message: "The header's stsd box is cut short.") }
        guard let entry = try boxes(in: data, range: (payload.lowerBound + 8)..<payload.upperBound).first else { return .opaque }
        switch entry.type {
        case "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe":
            // A visual sample entry's boxes follow 78 bytes of fields.
            let children = (entry.payload.lowerBound + 78)..<entry.payload.upperBound
            guard !children.isEmpty else { throw Problem(message: "The header's \(entry.type) entry is cut short.") }
            for child in try boxes(in: data, range: children) {
                if child.type == "avcC", child.payload.count >= 5 {
                    return .nalUnits(lengthSize: Int(data.byte(at: child.payload.lowerBound + 4) & 0x03) + 1)
                }
                if child.type == "hvcC", child.payload.count >= 22 {
                    return .nalUnits(lengthSize: Int(data.byte(at: child.payload.lowerBound + 21) & 0x03) + 1)
                }
            }
            throw Problem(message: "The header's \(entry.type) entry has no decoder configuration.")
        case "ac-3", "ec-3":
            return .ac3Frames
        default:
            return .opaque
        }
    }

    /// The roll distance of an audio sample entry's samples: -1 for AAC (an mp4a entry whose
    /// decoder configuration names MPEG-4 audio or MPEG-2 AAC), nil otherwise.
    private static func rollDistance(_ data: Data, _ payload: Range<Int>) throws -> Int16? {
        guard payload.count >= 8, let entry = try boxes(in: data, range: (payload.lowerBound + 8)..<payload.upperBound).first,
              entry.type == "mp4a", entry.payload.count >= 28
        else { return nil }
        // An audio sample entry's boxes follow 28 bytes of fields, QuickTime's versions 1 and 2 more.
        let fields = switch data.uint16(at: entry.payload.lowerBound + 8) {
        case 1: 44
        case 2: 64
        default: 28
        }
        guard entry.payload.lowerBound + fields <= entry.payload.upperBound,
              let esds = try boxes(in: data, range: (entry.payload.lowerBound + fields)..<entry.payload.upperBound).first(where: { $0.type == "esds" })
        else { return nil }
        // After the full box's version and flags: an ES descriptor (tag 3) holding a decoder
        // configuration descriptor (tag 4), each tag followed by a length of up to four bytes.
        var at = esds.payload.lowerBound + 4
        func descriptor(_ tag: UInt8) -> Bool {
            guard at < esds.payload.upperBound, data.byte(at: at) == tag else { return false }
            at += 1
            for _ in 0..<4 {
                guard at < esds.payload.upperBound else { return false }
                let byte = data.byte(at: at)
                at += 1
                if byte & 0x80 == 0 { break }
            }
            return true
        }
        guard descriptor(3), at + 3 <= esds.payload.upperBound else { return nil }
        let flags = data.byte(at: at + 2)
        at += 3
        if flags & 0x80 != 0 { at += 2 }
        if flags & 0x40 != 0, at < esds.payload.upperBound { at += 1 + Int(data.byte(at: at)) }
        if flags & 0x20 != 0 { at += 2 }
        guard descriptor(4), at < esds.payload.upperBound else { return nil }
        return [0x40, 0x66, 0x67, 0x68].contains(data.byte(at: at)) ? -1 : nil
    }

    /// The transfer characteristics a visual sample entry's colr box names (nclx or nclc).
    private static func colourTransfer(_ data: Data, _ payload: Range<Int>) throws -> UInt16? {
        guard payload.count >= 8, let entry = try boxes(in: data, range: (payload.lowerBound + 8)..<payload.upperBound).first,
              ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe"].contains(entry.type), entry.payload.count > 78
        else { return nil }
        for child in try boxes(in: data, range: (entry.payload.lowerBound + 78)..<entry.payload.upperBound) where child.type == "colr" {
            guard child.payload.count >= 10 else { continue }
            let kind = data.fourCC(at: child.payload.lowerBound)
            guard kind == "nclx" || kind == "nclc" else { continue }
            return UInt16(data.byte(at: child.payload.lowerBound + 6)) << 8 | UInt16(data.byte(at: child.payload.lowerBound + 7))
        }
        return nil
    }

    // MARK: Pieces

    /// Checks a piece on its own against the header: every box whole, at least one fragment, and
    /// each fragment's samples filling the media data after it and holding together inside. A
    /// piece without samples is returned as empty rather than refused.
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
        var pendingMoof: (range: Range<Int>, runs: [Run])?
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
                try checkMediaData(data, mdat: box, moof: moof.range, runs: moof.runs, header: header)
                if var piece = current {
                    for run in moof.runs {
                        piece.runs.append(run)
                        if header.tracks[run.track]?.isVideo == true { piece.videoSamples += run.samples.count }
                    }
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
        return pieces.map { measured($0, header: header) }
    }

    /// The piece with each track's stretch, and whether it starts with a keyframe.
    private static func measured(_ piece: Piece, header: Header) -> Piece {
        var piece = piece
        for (id, track) in header.tracks {
            var span: Span?
            for run in piece.runs where run.track == id {
                var time = run.decodeTime
                for sample in run.samples {
                    let shown = time + Int64(sample.compositionOffset) - track.presentationOffset
                    let end = shown + Int64(sample.duration)
                    if var found = span {
                        found.start = min(found.start, shown)
                        found.end = max(found.end, end)
                        span = found
                    } else {
                        span = Span(start: shown, end: end, sampleDuration: Int64(sample.duration))
                    }
                    time += Int64(sample.duration)
                }
            }
            piece.spans[id] = span
        }
        if let id = header.videoTrack, let track = header.tracks[id], let span = piece.spans[id] {
            let scale = Double(track.timescale)
            piece.videoStart = Double(span.start) / scale
            piece.videoEnd = Double(span.end) / scale
            let first = piece.pictures(header: header).first
            piece.startsWithSync = first?.sample.isSync ?? false
        }
        return piece
    }

    /// The samples of a fragment fill its media data, back to back with nothing left over, and
    /// each holds together inside as far as its track's format tells.
    private static func checkMediaData(_ data: Data, mdat: Box, moof: Range<Int>, runs: [Run], header: Header) throws {
        let sampled = runs.filter { !$0.samples.isEmpty }
        guard !sampled.isEmpty else { return }
        var cursor = mdat.payload.lowerBound
        for run in sampled.sorted(by: { $0.dataOffset < $1.dataOffset }) {
            guard run.dataOffset == cursor, run.dataRange.upperBound <= mdat.payload.upperBound else {
                throw Problem(message: "The samples of the fragment at byte \(moof.lowerBound) don't fill its media data.")
            }
            cursor = run.dataRange.upperBound
            if let track = header.tracks[run.track] { try checkSamples(data, run: run, format: track.format) }
        }
        guard cursor == mdat.payload.upperBound else {
            throw Problem(message: "The media data at byte \(mdat.range.lowerBound) holds \(mdat.payload.upperBound - cursor) bytes no sample covers.")
        }
    }

    private static func checkSamples(_ data: Data, run: Run, format: SampleFormat) throws {
        switch format {
        case .opaque:
            return
        case .ac3Frames:
            var offset = run.dataOffset
            for sample in run.samples {
                guard sample.size >= 2, data.byte(at: offset) == 0x0B, data.byte(at: offset + 1) == 0x77 else {
                    throw Problem(message: "The audio frame at byte \(offset) doesn't start as an AC-3 frame does.")
                }
                offset += Int(sample.size)
            }
        case .nalUnits(let lengthSize):
            var offset = run.dataOffset
            for sample in run.samples {
                let end = offset + Int(sample.size)
                var cursor = offset
                while cursor < end {
                    guard cursor + lengthSize < end else { break }
                    var length = 0
                    for index in 0..<lengthSize { length = length << 8 | Int(data.byte(at: cursor + index)) }
                    let unit = cursor + lengthSize
                    // A NAL unit has a header, whose first bit is always zero.
                    guard length > 0, unit + length <= end, data.byte(at: unit) & 0x80 == 0 else { break }
                    cursor = unit + length
                }
                guard cursor == end else {
                    throw Problem(message: "The video sample at byte \(offset) doesn't hold whole NAL units.")
                }
                offset = end
            }
        }
    }

    private static func readFragment(_ data: Data, _ moof: Box, header: Header) throws -> [Run] {
        var runs: [Run] = []
        for traf in try boxes(in: data, range: moof.payload) where traf.type == "traf" {
            var id: UInt32 = 0
            var defaultDuration: UInt32?
            var defaultSize: UInt32?
            var defaultFlags: UInt32?
            var baseOffset = moof.range.lowerBound
            var decodeTime: Int64 = 0
            var trafRuns: [Run] = []
            var nextDataOffset: Int?
            for child in try boxes(in: data, range: traf.payload) {
                let base = child.payload.lowerBound
                switch child.type {
                case "tfhd":
                    guard child.payload.count >= 8 else { throw Problem(message: "A tfhd box is cut short.") }
                    let flags = data.uint32(at: base) & 0xFFFFFF
                    id = data.uint32(at: base + 4)
                    var cursor = base + 8
                    let present = [0x1, 0x2, 0x8, 0x10, 0x20].filter { flags & UInt32($0) != 0 }
                    let length = present.reduce(0) { $0 + ($1 == 0x1 ? 8 : 4) }
                    guard cursor + length <= child.payload.upperBound else { throw Problem(message: "A tfhd box is cut short.") }
                    if flags & 0x1 != 0 { baseOffset = Int(clamping: data.uint64(at: cursor)); cursor += 8 }
                    if flags & 0x2 != 0 { cursor += 4 }
                    if flags & 0x8 != 0 { defaultDuration = data.uint32(at: cursor); cursor += 4 }
                    if flags & 0x10 != 0 { defaultSize = data.uint32(at: cursor); cursor += 4 }
                    if flags & 0x20 != 0 { defaultFlags = data.uint32(at: cursor); cursor += 4 }
                case "tfdt":
                    guard child.payload.count >= 8, data.byte(at: base) != 1 || child.payload.count >= 12 else {
                        throw Problem(message: "A tfdt box is cut short.")
                    }
                    decodeTime = data.byte(at: base) == 1 ? Int64(bitPattern: data.uint64(at: base + 4))
                        : Int64(Int32(bitPattern: data.uint32(at: base + 4)))
                case "trun":
                    guard child.payload.count >= 8 else { throw Problem(message: "A trun box is cut short.") }
                    guard let track = header.tracks[id] else {
                        throw Problem(message: "A fragment names track \(id), which the header doesn't have.")
                    }
                    let version = data.byte(at: base)
                    let flags = data.uint32(at: base) & 0xFFFFFF
                    let count = Int(data.uint32(at: base + 4))
                    var cursor = base + 8
                    var dataOffset = nextDataOffset ?? baseOffset
                    if flags & 0x1 != 0 {
                        guard cursor + 4 <= child.payload.upperBound else { throw Problem(message: "A trun box is cut short.") }
                        dataOffset = baseOffset + Int(Int32(bitPattern: data.uint32(at: cursor)))
                        cursor += 4
                    }
                    var firstFlags: UInt32?
                    if flags & 0x4 != 0 {
                        guard cursor + 4 <= child.payload.upperBound else { throw Problem(message: "A trun box is cut short.") }
                        firstFlags = data.uint32(at: cursor)
                        cursor += 4
                    }
                    let perSample = [0x100, 0x200, 0x400, 0x800].filter { flags & UInt32($0) != 0 }.count * 4
                    guard count >= 0, cursor + count * perSample <= child.payload.upperBound else {
                        throw Problem(message: "A trun box is cut short.")
                    }
                    var samples: [Sample] = []
                    samples.reserveCapacity(count)
                    for index in 0..<count {
                        var duration = defaultDuration ?? track.defaultDuration
                        var size = defaultSize ?? track.defaultSize
                        var sampleFlags = defaultFlags ?? track.defaultFlags
                        var compositionOffset: Int32 = 0
                        if flags & 0x100 != 0 { duration = data.uint32(at: cursor); cursor += 4 }
                        if flags & 0x200 != 0 { size = data.uint32(at: cursor); cursor += 4 }
                        if flags & 0x400 != 0 { sampleFlags = data.uint32(at: cursor); cursor += 4 }
                        if index == 0, let firstFlags { sampleFlags = firstFlags }
                        if flags & 0x800 != 0 {
                            let raw = data.uint32(at: cursor)
                            // Version 0 offsets are unsigned; none Jellyfin writes reach the sign bit.
                            compositionOffset = version == 0 ? Int32(clamping: raw) : Int32(bitPattern: raw)
                            cursor += 4
                        }
                        // sample_is_non_sync_sample, the 17th bit of the flags.
                        samples.append(Sample(duration: duration, size: size, compositionOffset: compositionOffset,
                                              isSync: sampleFlags & 0x0001_0000 == 0))
                    }
                    let start = decodeTime + trafRuns.reduce(0) { $0 + $1.duration }
                    let run = Run(track: id, decodeTime: start, dataOffset: dataOffset, samples: samples)
                    guard dataOffset >= 0 else { throw Problem(message: "A fragment at byte \(moof.range.lowerBound) points before the file.") }
                    nextDataOffset = run.dataRange.upperBound
                    trafRuns.append(run)
                default:
                    continue
                }
            }
            guard header.tracks[id] != nil else { throw Problem(message: "A fragment names track \(id), which the header doesn't have.") }
            runs += trafRuns
        }
        return runs
    }

    /// Where each piece of a joined file starts: its styp box. A box whose size makes no sense
    /// ends the walk there, and it picks up at the next styp, so the pieces after a damaged one
    /// are still found.
    static func pieceStarts(in data: Data, from start: Int) -> [Int] {
        // Taking bytes out of `data` doesn't fail.
        (try? pieceStarts(count: data.count, from: start) { data.subdata(in: $0) }) ?? []
    }

    /// Where each piece starts in `count` bytes that `read` hands over a stretch at a time, as
    /// for a file too big to read whole: only box headers are read, and the bytes after a
    /// damaged box up to the next styp.
    static func pieceStarts(count: Int, from start: Int, read: (Range<Int>) throws -> Data) throws -> [Int] {
        var starts: [Int] = []
        var cursor = start
        let marker = Data("styp".utf8)
        while cursor + 8 <= count {
            let boxHeader = try read(cursor..<(cursor + 8))
            let size = Int(boxHeader.uint32(at: 0))
            let type = boxHeader.fourCC(at: 4)
            if type == "styp" { starts.append(cursor) }
            let isPlausible = size >= 8 && size <= count - cursor && type.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            if isPlausible {
                cursor += size
                continue
            }
            // A block at a time, each overlapping the last by less than a marker, so none is
            // missed across two.
            var searchFrom = cursor + 5
            var found: Int?
            while found == nil, searchFrom + marker.count <= count {
                let block = try read(searchFrom..<min(count, searchFrom + (1 << 20)))
                found = block.range(of: marker).map { searchFrom + ($0.lowerBound - block.startIndex) }
                searchFrom += block.count - (marker.count - 1)
            }
            guard let found else { break }
            cursor = found - 4
        }
        return starts
    }

    /// The pieces in `count` bytes that `read` hands over a stretch at a time, from their box and
    /// fragment headers alone, without their media data, for the stretch each covers and its
    /// samples' timing: what the pieces of a file being joined are known to hold already.
    static func outlines(count: Int, from start: Int, header: Header, read: (Range<Int>) throws -> Data) throws -> [Piece] {
        var pieces: [Piece] = []
        var cursor = start
        while cursor + 8 <= count {
            let boxHeader = try read(cursor..<(cursor + 8))
            var size = Int(boxHeader.uint32(at: 0))
            let type = boxHeader.fourCC(at: 4)
            if size == 1 {
                guard cursor + 16 <= count else { throw Problem(message: "A box at byte \(cursor) is cut short.") }
                size = Int(clamping: try read((cursor + 8)..<(cursor + 16)).uint64(at: 0))
            }
            guard size >= 8, size <= count - cursor else { throw Problem(message: "The \(type) box at byte \(cursor) is cut short.") }
            switch type {
            case "styp":
                pieces.append(Piece(range: Int64(cursor)..<Int64(cursor + size)))
            case "moof":
                let moof = try read(cursor..<(cursor + size))
                let runs = try readFragment(moof, Box(type: type, range: 0..<size, payload: 8..<size), header: header)
                guard !pieces.isEmpty else { throw Problem(message: "A fragment at byte \(cursor) belongs to no piece.") }
                for var run in runs {
                    run.dataOffset += cursor
                    pieces[pieces.count - 1].runs.append(run)
                    if header.tracks[run.track]?.isVideo == true { pieces[pieces.count - 1].videoSamples += run.samples.count }
                }
                pieces[pieces.count - 1].fragments += 1
            default:
                break
            }
            if let last = pieces.indices.last { pieces[last].range = pieces[last].range.lowerBound..<Int64(cursor + size) }
            cursor += size
        }
        return pieces.map { measured($0, header: header) }
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
                size = Int(clamping: data.uint64(at: cursor + 8))
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - cursor
            }
            guard size >= headerSize, size <= range.upperBound - cursor else {
                throw Problem(message: "The \(type.isEmpty ? "box" : type + " box") at byte \(cursor) is cut short.")
            }
            boxes.append(Box(type: type, range: cursor..<(cursor + size), payload: (cursor + headerSize)..<(cursor + size)))
            cursor += size
        }
        return boxes
    }
}

nonisolated extension Data {
    func uint16(at offset: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.bigEndian
    }

    func uint32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.bigEndian
    }

    func uint64(at offset: Int) -> UInt64 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.bigEndian
    }

    func byte(at offset: Int) -> UInt8 {
        withUnsafeBytes { $0[offset] }
    }

    func fourCC(at offset: Int) -> String {
        withUnsafeBytes { String(decoding: UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + 4)]), as: UTF8.self) }
    }
}
#endif
