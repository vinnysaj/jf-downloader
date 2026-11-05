#if !os(tvOS)
import Foundation

/// Makes a transcoded download's joined file, a fragmented MP4, an ordinary one without moving
/// a byte of its media: an index of every sample (a moov box with full sample tables) goes after
/// the last piece, pointing at each sample where it already lies, and the 16 bytes after the
/// ftyp box become the header of one media data box spanning everything up to the index. The
/// init segment's moov and the pieces' boxes stay where they were, inside that media data, which
/// players skip over as they do anything no index points at. Both changes are written into the
/// joined file itself and can be taken back (`undo`), so indexing takes no room but the index's,
/// on any volume.
///
/// The player reads every fragment's header of a fragmented MP4 as it opens it, a few hundred
/// KB per piece read from storage: a few thousand pieces take it seconds and most of a GB, every
/// time the title is opened. It reads an ordinary MP4's index in one go, as long as it is.
///
/// Every sample keeps its own time: its decode time and composition offset as the server wrote
/// them. Where a restarted transcode's piece takes over (`TranscodeTimeline`), the pictures from
/// its first one on are left out, which have to be the last decoded, and so are its audio frames
/// the file already has; anything else that doesn't follow on, a gap or an overlap in any track,
/// names the piece, and nothing is moved to hide it.
///
/// The index also puts the title's start at 0. The server's transcode keeps the source's
/// timestamps (`-copyts`), so a source whose clock doesn't start at 0, as broadcast recordings'
/// don't, makes pieces that start that far in; positions to resume from, and markers for intros
/// and credits, count from the title's start. The first picture is shown at 0, each track keeps
/// its place against it, and each plays to the end of its last sample, by an edit list.
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

    /// Why a piece can't be indexed where it lies: `piece` is its place among the pieces given.
    struct Misfit: Error, Equatable, LocalizedError {
        let piece: Int
        let message: String
        var errorDescription: String? { message }
    }

    /// Builds the index for a joined file of `fileLength` bytes that starts with the init segment
    /// `header` and holds `pieces`, as read from it in order. Throws `Misfit` for a piece that
    /// doesn't follow on from the ones before it.
    static func index(header: Data, parsed: FragmentedMP4.Header, pieces: [FragmentedMP4.Piece], fileLength: Int64) throws -> Index {
        let top = try FragmentedMP4.boxes(in: header, range: 0..<Int(parsed.length))
        guard let ftyp = top.first, ftyp.type == "ftyp", let moov = top.first(where: { $0.type == "moov" }),
              moov.range.lowerBound == ftyp.range.upperBound, moov.range.count >= 16
        else { throw FragmentedMP4.Problem(message: "The init segment doesn't start with ftyp and moov.") }
        guard let videoId = parsed.videoTrack else { throw FragmentedMP4.Problem(message: "The header has no video track.") }

        var tracks: [UInt32: Samples] = [:]
        for (id, track) in parsed.tracks { tracks[id] = Samples(timescale: Int64(track.timescale), presentationOffset: track.presentationOffset) }
        for (place, piece) in pieces.enumerated() {
            guard let picture = piece.spans[videoId] else { throw Misfit(piece: place, message: "Piece \(place) has no pictures.") }
            guard place == 0 || piece.startsWithSync else {
                throw Misfit(piece: place, message: "Piece \(place) doesn't start with a keyframe.")
            }
            do {
                try tracks[videoId]?.takeOver(at: picture.start)
                for run in piece.runs where !run.samples.isEmpty && run.track == videoId { try tracks[videoId]?.add(run) }
                for (id, span) in piece.spans where id != videoId {
                    for run in piece.runs where !run.samples.isEmpty && run.track == id {
                        let end = tracks[id]?.end
                        try tracks[id]?.add(run, after: end, halfSample: span.sampleDuration / 2)
                    }
                }
            } catch let problem as FragmentedMP4.Problem {
                throw Misfit(piece: place, message: "Piece \(place): \(problem.message)")
            }
        }
        guard let video = tracks[videoId], let originTicks = video.firstShown else {
            throw FragmentedMP4.Problem(message: "The file has no pictures.")
        }
        let origin = Double(originTicks) / Double(video.timescale)
        let movieTimescale = Int64(parsed.movieTimescale)

        var traks: [UInt32: Data] = [:]
        var movieDuration: Int64 = 0
        for child in try FragmentedMP4.boxes(in: header, range: moov.payload) where child.type == "trak" {
            guard let id = try trackId(of: child, in: header), let samples = tracks[id], let first = samples.decodeTimes.first else { continue }
            let durations = try samples.durations()
            let timescale = samples.timescale
            let mediaDuration = durations.reduce(Int64(0)) { $0 + Int64($1) }
            // In the track's media time, which starts at its first decode time: where the movie's
            // 0 falls, when its first sample is shown, and when its last stops being shown.
            let zero = (origin * Double(timescale)).rounded() + Double(samples.presentationOffset) - Double(first)
            var earliest = Int64.max
            var latest = Int64.min
            for index in durations.indices {
                let shown = samples.decodeTimes[index] - first + Int64(samples.compositionOffsets[index])
                earliest = min(earliest, shown)
                latest = max(latest, shown + Int64(durations[index]))
            }
            let mediaTime = max(Int64(zero), earliest)
            let emptyEdit = mediaTime > Int64(zero) ? ((mediaTime - Int64(zero)) * movieTimescale + timescale / 2) / timescale : 0
            let shown = max(0, latest - mediaTime)
            let shownInMovie = (shown * movieTimescale + timescale / 2) / timescale
            movieDuration = max(movieDuration, emptyEdit + shownInMovie)
            traks[id] = try rebuildTrack(child, in: header, samples: samples, durations: durations,
                                         rollDistance: parsed.tracks[id]?.rollDistance, mediaDuration: mediaDuration,
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

    /// Writes `index` into the joined `file` of `length` bytes and returns its new length.
    static func write(_ index: Index, into file: URL, length: Int64) throws -> Int64 {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
        try handle.seek(toOffset: UInt64(index.mdatOffset))
        try handle.write(contentsOf: index.mdatHeader)
        try handle.seekToEnd()
        try handle.write(contentsOf: index.moov)
        try handle.synchronize()
        return Int64(try handle.offset())
    }

    /// Takes an index out of the joined `file` again, whatever got written of it: the file goes
    /// back to `length` bytes, and the bytes after the ftyp box to the init segment's `header`.
    static func undo(_ file: URL, header: Data, length: Int64) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
        let ftypEnd = Int(header.uint32(at: 0))
        guard header.count >= ftypEnd + 16 else { return }
        try handle.seek(toOffset: UInt64(ftypEnd))
        if try handle.read(upToCount: 16) != header.subdata(in: ftypEnd..<(ftypEnd + 16)) {
            try handle.seek(toOffset: UInt64(ftypEnd))
            try handle.write(contentsOf: header.subdata(in: ftypEnd..<(ftypEnd + 16)))
        }
        try handle.synchronize()
    }

    // MARK: Samples

    /// One track's samples across the file, in decode order, each at its own time.
    private struct Samples {
        let timescale: Int64
        let presentationOffset: Int64
        var decodeTimes: [Int64] = []
        var ownDurations: [UInt32] = []
        var sizes: [UInt32] = []
        var compositionOffsets: [Int32] = []
        var syncs: [Bool] = []
        /// Each run is a chunk: its samples lie one after another from `offset`.
        var chunks: [(offset: Int, count: Int)] = []

        init(timescale: Int64, presentationOffset: Int64) {
            self.timescale = timescale
            self.presentationOffset = presentationOffset
        }

        private func shown(_ index: Int) -> Int64 {
            decodeTimes[index] + Int64(compositionOffsets[index]) - presentationOffset
        }

        var firstShown: Int64? { decodeTimes.indices.map(shown).min() }

        /// When the last sample stops being shown: one of the last few decoded, as no codec
        /// reorders further than that.
        var end: Int64? {
            decodeTimes.indices.suffix(Self.reorderWindow).map { shown($0) + Int64(ownDurations[$0]) }.max()
        }

        /// More samples than any codec decodes ahead of showing them.
        private static let reorderWindow = 64

        /// A restarted transcode's pictures take over at `time`: the pictures shown from then on
        /// go, which have to be the last decoded, and the ones kept have to end there.
        mutating func takeOver(at time: Int64) throws {
            guard let end else { return }
            let slack = max(1, timescale / 1000)
            if time > end + slack { throw FragmentedMP4.Problem(message: "its pictures start \(Self.seconds(time - end, timescale)) s after the ones before end.") }
            guard time < end - slack else { return }
            var keep = decodeTimes.count
            while keep > 0, shown(keep - 1) >= time - slack { keep -= 1 }
            guard (0..<keep).allSatisfy({ shown($0) < time - slack }) else {
                throw FragmentedMP4.Problem(message: "it takes over where the pictures before it can't be cut.")
            }
            removeLast(decodeTimes.count - keep)
            let keptEnd = self.end ?? time
            guard abs(keptEnd - time) <= slack else {
                throw FragmentedMP4.Problem(message: "it takes over \(Self.seconds(keptEnd - time, timescale)) s from where the pictures kept end.")
            }
        }

        /// Adds a run's samples. For a track other than the pictures, with the file's samples of it
        /// ending at `end`, the run's samples that start before it, by more than `halfSample`, go:
        /// a restarted transcode's audio that the file has already.
        mutating func add(_ run: FragmentedMP4.Run, after end: Int64? = nil, halfSample: Int64 = 0) throws {
            var time = run.decodeTime
            var offset = run.dataOffset
            var count = 0
            for sample in run.samples {
                let shown = time + Int64(sample.compositionOffset) - presentationOffset
                if let end, shown < end - halfSample {
                    time += Int64(sample.duration)
                    offset += Int(sample.size)
                    continue
                }
                if count == 0, let end, shown > end + halfSample {
                    throw FragmentedMP4.Problem(message: "a track starts \(Self.seconds(shown - end, timescale)) s after it ends in the piece before.")
                }
                if let last = decodeTimes.last, time <= last {
                    throw FragmentedMP4.Problem(message: "its samples are decoded before the ones before them.")
                }
                decodeTimes.append(time)
                ownDurations.append(sample.duration)
                sizes.append(sample.size)
                compositionOffsets.append(sample.compositionOffset)
                syncs.append(sample.isSync)
                time += Int64(sample.duration)
                count += 1
            }
            if count > 0 { chunks.append((offset, count)) }
        }

        private mutating func removeLast(_ count: Int) {
            guard count > 0 else { return }
            decodeTimes.removeLast(count)
            ownDurations.removeLast(count)
            sizes.removeLast(count)
            compositionOffsets.removeLast(count)
            syncs.removeLast(count)
            var left = count
            while left > 0, let last = chunks.last {
                if last.count <= left {
                    chunks.removeLast()
                    left -= last.count
                } else {
                    chunks[chunks.count - 1].count -= left
                    left = 0
                }
            }
        }

        /// Each sample's duration in the index: up to the next one's decode time, so each keeps
        /// its own; the last keeps its own duration.
        func durations() throws -> [UInt32] {
            var durations: [UInt32] = []
            durations.reserveCapacity(decodeTimes.count)
            for index in decodeTimes.indices.dropLast() {
                let gap = decodeTimes[index + 1] - decodeTimes[index]
                guard gap > 0, gap <= Int64(UInt32.max) else { throw FragmentedMP4.Problem(message: "Its samples are out of order.") }
                durations.append(UInt32(gap))
            }
            if let last = ownDurations.last { durations.append(last) }
            return durations
        }

        private static func seconds(_ ticks: Int64, _ timescale: Int64) -> String {
            (Double(ticks) / Double(timescale)).formatted(.number.precision(.fractionLength(3)))
        }
    }

    // MARK: Boxes

    private static func trackId(of trak: FragmentedMP4.Box, in data: Data) throws -> UInt32? {
        guard let tkhd = try FragmentedMP4.boxes(in: data, range: trak.payload).first(where: { $0.type == "tkhd" }) else { return nil }
        let version = data.byte(at: tkhd.payload.lowerBound)
        return data.uint32(at: tkhd.payload.lowerBound + 4 + (version == 1 ? 16 : 8))
    }

    private static func rebuildTrack(_ trak: FragmentedMP4.Box, in data: Data, samples: Samples, durations: [UInt32],
                                     rollDistance: Int16?, mediaDuration: Int64, trackDuration: Int64, edits: [(duration: Int64, mediaTime: Int64)]) throws -> Data {
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
                                minf += sampleTable(stsd: data.subdata(in: stsd.range), samples: samples, durations: durations,
                                                    rollDistance: rollDistance)
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

    private static func sampleTable(stsd: Data, samples: Samples, durations: [UInt32], rollDistance: Int16?) -> Data {
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
        // Every sample in the one roll group. The server's fragments don't carry it, and without it
        // AVFoundation plays AAC about 44 ms ahead of the picture.
        if let rollDistance {
            var description = Data("roll".utf8)
            description.append(uint32: 2)
            description.append(uint32: 1)
            description.append(uint16: UInt16(bitPattern: rollDistance))
            table += fullBox("sgpd", version: 1, description)
            var grouping = Data("roll".utf8)
            grouping.append(uint32: 1)
            grouping.append(uint32: UInt32(samples.sizes.count))
            grouping.append(uint32: 1)
            table += fullBox("sbgp", grouping)
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
    mutating func append(uint16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(uint64 value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
#endif
