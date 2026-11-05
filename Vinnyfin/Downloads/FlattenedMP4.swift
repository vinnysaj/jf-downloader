#if !os(tvOS)
import Foundation

/// Makes a transcoded download's joined file, a fragmented MP4, an ordinary one without moving
/// a byte of its media: an index of every sample (a moov box with full sample tables) goes after
/// the last piece, pointing at each sample where it already lies, and the 16 bytes after the
/// ftyp box become the header of one media data box spanning everything up to the index. The
/// init segment's moov and the pieces' boxes stay where they were, inside that media data, which
/// players skip over as they do anything no index points at.
///
/// The player reads every fragment's header of a fragmented MP4 as it opens it, a few hundred
/// KB per piece read from storage: a few thousand pieces take it seconds and most of a GB, every
/// time the title is opened. It reads an ordinary MP4's index in one go, as long as it is.
///
/// The index also puts the title's start at 0. The server's transcode keeps the source's
/// timestamps (`-copyts`), so a source whose clock doesn't start at 0, as broadcast recordings'
/// don't, makes pieces that start that far in; positions to resume from, and markers for intros
/// and credits, count from the title's start. The first picture's decode time becomes 0, and
/// each track keeps its place against it, by an edit list.
nonisolated enum FlattenedMP4 {
    /// What makes a joined file an ordinary MP4: `mdatHeader` goes at `mdatOffset` and `moov` at
    /// the end.
    struct Index: Equatable, Sendable {
        var mdatOffset: Int
        var mdatHeader: Data
        var moov: Data
        /// Where the file's 0 lies on the transcode's timeline, in seconds.
        var origin: Double
    }

    /// Builds the index for a joined file of `fileLength` bytes that starts with the init segment
    /// `header` and holds `pieces`, as read from it in order.
    static func index(header: Data, parsed: FragmentedMP4.Header, pieces: [FragmentedMP4.Piece], fileLength: Int64) throws -> Index {
        let top = try FragmentedMP4.boxes(in: header, range: 0..<Int(parsed.length))
        guard let ftyp = top.first, ftyp.type == "ftyp", let moov = top.first(where: { $0.type == "moov" }),
              moov.range.lowerBound == ftyp.range.upperBound, moov.range.count >= 16
        else { throw FragmentedMP4.Problem(message: "The init segment doesn't start with ftyp and moov.") }
        guard let videoId = parsed.videoTrack else { throw FragmentedMP4.Problem(message: "The header has no video track.") }

        var tracks: [UInt32: Samples] = [:]
        for piece in pieces {
            for run in piece.runs where !run.samples.isEmpty {
                tracks[run.track, default: Samples()].add(run)
            }
        }
        guard let video = tracks[videoId], let videoStart = video.decodeTimes.first, let videoTrack = parsed.tracks[videoId] else {
            throw FragmentedMP4.Problem(message: "The file has no pictures.")
        }
        let origin = Double(videoStart) / Double(videoTrack.timescale)
        let movieTimescale = Int64(parsed.movieTimescale)

        var traks: [UInt32: Data] = [:]
        var movieDuration: Int64 = 0
        for child in try FragmentedMP4.boxes(in: header, range: moov.payload) where child.type == "trak" {
            guard let id = try trackId(of: child, in: header), let info = parsed.tracks[id], let samples = tracks[id] else { continue }
            let timescale = Int64(info.timescale)
            let durations = samples.flatDurations()
            let mediaDuration = durations.reduce(Int64(0)) { $0 + Int64($1) }
            // Where this track's presentation starts once the picture's first decode time is 0.
            let shift = info.presentationOffset - (samples.decodeTimes.first ?? 0) + Int64((origin * Double(timescale)).rounded())
            let emptyEdit = shift < 0 ? (-shift * movieTimescale + timescale / 2) / timescale : 0
            let mediaTime = max(0, shift)
            let shown = max(0, mediaDuration - mediaTime)
            let shownInMovie = (shown * movieTimescale + timescale / 2) / timescale
            movieDuration = max(movieDuration, emptyEdit + shownInMovie)
            traks[id] = try rebuildTrack(child, in: header, samples: samples, durations: durations, mediaDuration: mediaDuration,
                                         trackDuration: emptyEdit + shownInMovie,
                                         edits: (emptyEdit > 0 ? [(emptyEdit, Int64(-1))] : []) + [(shownInMovie, mediaTime)])
        }
        guard traks[videoId] != nil else { throw FragmentedMP4.Problem(message: "The file has no pictures.") }

        var children = Data()
        for child in try FragmentedMP4.boxes(in: header, range: moov.payload) {
            switch child.type {
            case "mvhd":
                children += try withDuration(child, in: header, movieDuration)
            case "trak":
                if let id = try trackId(of: child, in: header), let trak = traks[id] { children += trak }
            case "mvex":
                // The file is no longer fragmented.
                continue
            default:
                children += header.subdata(in: child.range)
            }
        }
        let mdatOffset = ftyp.range.upperBound
        var mdatHeader = Data()
        mdatHeader.append(uint32: 1)
        mdatHeader += Data("mdat".utf8)
        mdatHeader.append(uint64: UInt64(fileLength) - UInt64(mdatOffset))
        return Index(mdatOffset: mdatOffset, mdatHeader: mdatHeader, moov: box("moov", children), origin: origin)
    }

    /// Writes `index` into a copy of `source` at `destination`, over any earlier one, and returns
    /// its length. The copy is a clone where the file system makes them (APFS), which shares the
    /// source's blocks: only the blocks written take room of their own.
    static func write(_ index: Index, from source: URL, to destination: URL) throws -> Int64 {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: source, to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index.mdatOffset))
        try handle.write(contentsOf: index.mdatHeader)
        try handle.seekToEnd()
        try handle.write(contentsOf: index.moov)
        try handle.synchronize()
        return Int64(try handle.offset())
    }

    // MARK: Samples

    /// One track's samples across the file, in order.
    private struct Samples {
        var decodeTimes: [Int64] = []
        var durations: [UInt32] = []
        var sizes: [UInt32] = []
        var compositionOffsets: [Int32] = []
        var syncs: [Bool] = []
        /// Each run is a chunk: its samples lie one after another from `offset`.
        var chunks: [(offset: Int, count: Int)] = []

        mutating func add(_ run: FragmentedMP4.Run) {
            var time = run.decodeTime
            for sample in run.samples {
                decodeTimes.append(time)
                durations.append(sample.duration)
                sizes.append(sample.size)
                compositionOffsets.append(sample.compositionOffset)
                syncs.append(sample.isSync)
                time += Int64(sample.duration)
            }
            chunks.append((run.dataOffset, run.samples.count))
        }

        /// Each sample's duration on a timeline that starts at the track's first decode time and
        /// keeps every sample at its own: a gap between pieces lengthens the sample before it,
        /// and a piece that starts before the one ahead of it ends starts at that end.
        func flatDurations() -> [UInt32] {
            guard let first = decodeTimes.first else { return [] }
            var positions: [Int64] = []
            positions.reserveCapacity(decodeTimes.count)
            for (index, time) in decodeTimes.enumerated() {
                let target = time - first
                positions.append(index == 0 ? 0 : max(target, positions[index - 1] + Int64(durations[index - 1])))
            }
            var flat = zip(positions, positions.dropFirst()).map { UInt32(clamping: $1 - $0) }
            flat.append(durations.last ?? 0)
            return flat
        }
    }

    // MARK: Boxes

    private static func trackId(of trak: FragmentedMP4.Box, in data: Data) throws -> UInt32? {
        guard let tkhd = try FragmentedMP4.boxes(in: data, range: trak.payload).first(where: { $0.type == "tkhd" }) else { return nil }
        let version = data.byte(at: tkhd.payload.lowerBound)
        return data.uint32(at: tkhd.payload.lowerBound + 4 + (version == 1 ? 16 : 8))
    }

    private static func rebuildTrack(_ trak: FragmentedMP4.Box, in data: Data, samples: Samples, durations: [UInt32],
                                     mediaDuration: Int64, trackDuration: Int64, edits: [(duration: Int64, mediaTime: Int64)]) throws -> Data {
        var children = Data()
        for part in try FragmentedMP4.boxes(in: data, range: trak.payload) {
            switch part.type {
            case "tkhd":
                children += try withDuration(part, in: data, trackDuration)
                var list = Data()
                list.append(uint32: UInt32(edits.count))
                for edit in edits {
                    list.append(uint64: UInt64(edit.duration))
                    list.append(uint64: UInt64(bitPattern: edit.mediaTime))
                    list.append(uint32: 0x0001_0000)
                }
                children += box("edts", fullBox("elst", version: 1, list))
            case "edts":
                continue
            case "mdia":
                var mdia = Data()
                for child in try FragmentedMP4.boxes(in: data, range: part.payload) {
                    switch child.type {
                    case "mdhd":
                        mdia += try withDuration(child, in: data, mediaDuration)
                    case "minf":
                        var minf = Data()
                        for leaf in try FragmentedMP4.boxes(in: data, range: child.payload) {
                            if leaf.type == "stbl" {
                                guard let stsd = try FragmentedMP4.boxes(in: data, range: leaf.payload).first(where: { $0.type == "stsd" }) else {
                                    throw FragmentedMP4.Problem(message: "A track in the header has no sample description.")
                                }
                                minf += sampleTable(stsd: data.subdata(in: stsd.range), samples: samples, durations: durations)
                            } else {
                                minf += data.subdata(in: leaf.range)
                            }
                        }
                        mdia += box("minf", minf)
                    default:
                        mdia += data.subdata(in: child.range)
                    }
                }
                children += box("mdia", mdia)
            default:
                children += data.subdata(in: part.range)
            }
        }
        return box("trak", children)
    }

    private static func sampleTable(stsd: Data, samples: Samples, durations: [UInt32]) -> Data {
        var table = stsd
        let times = runLengths(durations)
        var stts = Data()
        stts.append(uint32: UInt32(times.count))
        for (count, duration) in times {
            stts.append(uint32: UInt32(count))
            stts.append(uint32: duration)
        }
        table += fullBox("stts", stts)
        if samples.compositionOffsets.contains(where: { $0 != 0 }) {
            let offsets = runLengths(samples.compositionOffsets)
            var ctts = Data()
            ctts.append(uint32: UInt32(offsets.count))
            for (count, offset) in offsets {
                ctts.append(uint32: UInt32(count))
                ctts.append(uint32: UInt32(bitPattern: offset))
            }
            // Version 1 reads the offsets as signed.
            table += fullBox("ctts", version: samples.compositionOffsets.contains { $0 < 0 } ? 1 : 0, ctts)
        }
        if samples.syncs.contains(false) {
            let numbers = samples.syncs.indices.filter { samples.syncs[$0] }
            var stss = Data()
            stss.append(uint32: UInt32(numbers.count))
            for number in numbers { stss.append(uint32: UInt32(number + 1)) }
            table += fullBox("stss", stss)
        }
        var entries: [(firstChunk: Int, count: Int)] = []
        for (index, chunk) in samples.chunks.enumerated() where entries.last?.count != chunk.count {
            entries.append((index + 1, chunk.count))
        }
        var stsc = Data()
        stsc.append(uint32: UInt32(entries.count))
        for entry in entries {
            stsc.append(uint32: UInt32(entry.firstChunk))
            stsc.append(uint32: UInt32(entry.count))
            stsc.append(uint32: 1)
        }
        table += fullBox("stsc", stsc)
        var stsz = Data()
        if let size = samples.sizes.first, samples.sizes.allSatisfy({ $0 == size }) {
            stsz.append(uint32: size)
            stsz.append(uint32: UInt32(samples.sizes.count))
        } else {
            stsz.append(uint32: 0)
            stsz.append(uint32: UInt32(samples.sizes.count))
            for size in samples.sizes { stsz.append(uint32: size) }
        }
        table += fullBox("stsz", stsz)
        var offsets = Data()
        offsets.append(uint32: UInt32(samples.chunks.count))
        if samples.chunks.allSatisfy({ $0.offset <= Int(UInt32.max) }) {
            for chunk in samples.chunks { offsets.append(uint32: UInt32(chunk.offset)) }
            table += fullBox("stco", offsets)
        } else {
            for chunk in samples.chunks { offsets.append(uint64: UInt64(chunk.offset)) }
            table += fullBox("co64", offsets)
        }
        return box("stbl", table)
    }

    private static func runLengths<Value: Equatable>(_ values: [Value]) -> [(count: Int, value: Value)] {
        var runs: [(count: Int, value: Value)] = []
        for value in values {
            if let last = runs.last, last.value == value {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((1, value))
            }
        }
        return runs
    }

    /// An mvhd, tkhd or mdhd box as version 1, its duration 64 bits wide, set to `duration`.
    private static func withDuration(_ box: FragmentedMP4.Box, in data: Data, _ duration: Int64) throws -> Data {
        let payload = box.payload
        let version = data.byte(at: payload.lowerBound)
        let wide = version == 1
        // Creation and modification times, then the track's number and a reserved word (tkhd),
        // or the timescale (mvhd, mdhd), then the duration.
        let timesEnd = payload.lowerBound + 4 + (wide ? 16 : 8)
        let fieldsEnd = timesEnd + (box.type == "tkhd" ? 8 : 4)
        let durationEnd = fieldsEnd + (wide ? 8 : 4)
        guard durationEnd <= payload.upperBound else { throw FragmentedMP4.Problem(message: "The header's \(box.type) box is cut short.") }
        var rebuilt = Data([1]) + data.subdata(in: (payload.lowerBound + 1)..<(payload.lowerBound + 4))
        if wide {
            rebuilt += data.subdata(in: (payload.lowerBound + 4)..<timesEnd)
        } else {
            rebuilt.append(uint64: UInt64(data.uint32(at: payload.lowerBound + 4)))
            rebuilt.append(uint64: UInt64(data.uint32(at: payload.lowerBound + 8)))
        }
        rebuilt += data.subdata(in: timesEnd..<fieldsEnd)
        rebuilt.append(uint64: UInt64(max(0, duration)))
        rebuilt += data.subdata(in: durationEnd..<payload.upperBound)
        return Self.box(box.type, rebuilt)
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.reserveCapacity(8 + payload.count)
        data.append(uint32: UInt32(8 + payload.count))
        data += Data(type.utf8)
        data += payload
        return data
    }

    private static func fullBox(_ type: String, version: UInt8 = 0, _ payload: Data) -> Data {
        var body = Data([version, 0, 0, 0])
        body += payload
        return box(type, body)
    }
}

private nonisolated extension Data {
    mutating func append(uint32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(uint64 value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
#endif
