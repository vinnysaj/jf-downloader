#if !os(tvOS)
import Foundation

/// What a transfer task is for. Stored as the task's `taskDescription`, which the background
/// session keeps across app launches, so a relaunched app knows what every task carries.
nonisolated struct TransferTag: Hashable, Sendable {
    let jobId: UUID
    /// The bytes asked for; nil for a whole-file request without a Range header.
    let range: Range<Int64>?

    init(jobId: UUID, range: Range<Int64>?) {
        self.jobId = jobId
        self.range = range
    }

    init?(encoded: String?) {
        let parts = encoded?.split(separator: " ") ?? []
        guard let first = parts.first, let jobId = UUID(uuidString: String(first)) else { return nil }
        switch parts.count {
        case 1:
            self.init(jobId: jobId, range: nil)
        case 3:
            guard let lower = Int64(parts[1]), let upper = Int64(parts[2]), lower < upper else { return nil }
            self.init(jobId: jobId, range: lower..<upper)
        default:
            return nil
        }
    }

    var encoded: String {
        guard let range else { return jobId.uuidString }
        return "\(jobId.uuidString) \(range.lowerBound) \(range.upperBound)"
    }

    /// The Range header value; HTTP ranges are inclusive.
    var rangeHeader: String? {
        range.map { "bytes=\($0.lowerBound)-\($0.upperBound - 1)" }
    }

    /// Whether the two ask for some of the same bytes. A whole-file request asks for them all.
    func overlaps(_ other: TransferTag) -> Bool {
        guard other.jobId == jobId else { return false }
        guard let range, let otherRange = other.range else { return true }
        return range.overlaps(otherRange)
    }
}

/// A parsed `Content-Range: bytes 0-99/1234` header, as a half-open range.
nonisolated struct ContentRange: Equatable, Sendable {
    let range: Range<Int64>
    /// Nil when the server sent `*`.
    let total: Int64?

    init?(header: String?) {
        guard let header else { return nil }
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = text.dropFirst("bytes ".count)
        let halves = spec.split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), first <= last else { return nil }
        if halves[1] == "*" {
            total = nil
        } else {
            guard let total = Int64(halves[1]), total > last else { return nil }
            self.total = total
        }
        range = first..<(last + 1)
    }
}

/// The parts of a response the policy looks at.
nonisolated struct ResponseInfo: Sendable, Equatable {
    var statusCode: Int
    var contentRange: String?
    var contentType: String?
    /// Nil when the server didn't say.
    var contentLength: Int64?
    /// From Content-Disposition, or the URL.
    var suggestedFilename: String?
}

nonisolated extension ResponseInfo {
    init(_ response: HTTPURLResponse) {
        statusCode = response.statusCode
        contentRange = response.value(forHTTPHeaderField: "Content-Range")
        contentType = response.value(forHTTPHeaderField: "Content-Type")
        contentLength = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        suggestedFilename = response.suggestedFilename
    }

    /// The file extension the response suggests, from Content-Disposition or Content-Type.
    var videoExtension: String? {
        if let suggestedFilename, let ext = MediaSource.videoExtension(fromPath: suggestedFilename) { return ext }
        let mimeType = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return switch mimeType {
        case "video/x-matroska", "video/matroska": "mkv"
        case "video/mp4": "mp4"
        case "video/x-m4v": "m4v"
        case "video/quicktime": "mov"
        case "video/webm": "webm"
        case "video/mp2t": "ts"
        case "video/x-msvideo", "video/avi": "avi"
        default: nil
        }
    }
}

nonisolated enum TransferFailure: Equatable, Sendable {
    /// The connection failed or was cut. Retried forever.
    case network(String)
    /// The server answered with an error. Retried up to `DownloadJob.maxServerFailures` times in a
    /// row while other files come through, and for as long as everything fails.
    case server(String)
}

nonisolated enum TransferOutcome: Equatable, Sendable {
    /// These bytes of the file arrived; `total` is the file's size per the server.
    case chunk(Range<Int64>, total: Int64)
    /// The server ignored Range and sent the whole file.
    case wholeFile(size: Int64)
    /// The server takes ranges but won't say how big the file is, so chunks can't be planned.
    case switchToWholeFile
    case retry(TransferFailure)
    /// Retrying can't help; the job stops with this message.
    case giveUp(String)
}

nonisolated extension DownloadJob {
    /// Judges a finished transfer. `stagedSize` is the size of the body on disk.
    func evaluate(_ response: ResponseInfo?, stagedSize: Int64?, tag: TransferTag) -> TransferOutcome {
        guard let response else { return .retry(.network("The server didn't answer.")) }
        let status = response.statusCode
        if status == 401 {
            return .giveUp("The server rejected the sign-in (HTTP 401). Sign out, sign in again, then retry.")
        }
        if (200..<300).contains(status), let type = response.contentType?.lowercased(),
           type.hasPrefix("text/") || type.contains("json")
        {
            return .retry(.server("The server sent \(type) instead of the video."))
        }

        switch status {
        case 206:
            guard let requested = tag.range, let contentRange = ContentRange(header: response.contentRange) else {
                return .retry(.server("The server answered a range request without a usable Content-Range (\(response.contentRange ?? "none"))."))
            }
            guard let total = contentRange.total ?? totalBytes else { return .switchToWholeFile }
            if let totalBytes, totalBytes != total {
                return .giveUp("The file on the server changed size (\(totalBytes) to \(total) bytes). Restart the download.")
            }
            let sent = contentRange.range
            let requestedEnd = min(requested.upperBound, total)
            // The body is exactly the range the response names, which starts within the request;
            // a server can send more than was asked.
            if sent.lowerBound >= requested.lowerBound, sent.lowerBound < requestedEnd, stagedSize == sent.count64 {
                return .chunk(sent, total: total)
            }
            // A probe reads the body only as far as it asked, whatever the response goes on to
            // send, up to the whole file: the bytes it read are the ones it asked for.
            if sent.lowerBound == requested.lowerBound, sent.upperBound >= requestedEnd,
               stagedSize == requestedEnd - requested.lowerBound
            {
                return .chunk(requested.lowerBound..<requestedEnd, total: total)
            }
            // The system's download daemon lost the connection partway, asked for the rest itself
            // (the server sent Last-Modified, so it can), and joined the pieces: the body is the
            // whole request while the last response names only the rest.
            if sent.lowerBound > requested.lowerBound, sent.upperBound == requestedEnd,
               stagedSize == requestedEnd - requested.lowerBound
            {
                return .chunk(requested.lowerBound..<requestedEnd, total: total)
            }
            if let stagedSize, stagedSize < requestedEnd - requested.lowerBound {
                return .retry(.network("The transfer was cut short."))
            }
            return .retry(.server(
                "Asked for bytes \(requested.lowerBound)–\(requested.upperBound - 1), got \(response.contentRange ?? "?") in \(stagedSize ?? 0) bytes."
            ))

        case 200:
            // The whole file, whether or not ranges were asked for: the file's stream ignores
            // Range, or has stopped honoring it.
            guard let stagedSize, stagedSize > 0 else { return .retry(.server("The server sent an empty file.")) }
            if let length = response.contentLength, length != stagedSize {
                return .retry(.network("The transfer was cut short."))
            }
            if let totalBytes, totalBytes != stagedSize {
                return .giveUp("The file on the server changed size (\(totalBytes) to \(stagedSize) bytes). Restart the download.")
            }
            return .wholeFile(size: stagedSize)

        case 404, 410:
            return .giveUp("The server doesn't have this file any more (HTTP \(status)). It may have moved: download it again from its page.")
        // A timeout, "too many requests" or a range past the end (planned from a listed size
        // that was too big) can pass; other client errors won't by being asked again.
        case 400..<500 where ![408, 416, 429].contains(status):
            return .giveUp("The server refused the download (HTTP \(status)).")
        default:
            return .retry(.server("The server answered with HTTP \(status)."))
        }
    }

    /// A single byte: enough for the server to say how big the file is and that its stream takes
    /// ranges, without downloading any of it alongside the file in hand.
    static let probeRange: Range<Int64> = 0..<1

    /// The active jobs in the order they download: the list's, which people can rearrange.
    static func queue(_ jobs: [DownloadJob]) -> [UUID] {
        queued(jobs).map(\.id)
    }

    static func queued(_ jobs: [DownloadJob]) -> [DownloadJob] {
        jobs.filter { $0.status == .active && !$0.isTransferComplete }
    }

    /// The bytes each unfinished job has so far: those in its partial file, and those `held`
    /// says its transfers hold in the session's files, running or set aside with resume data, or
    /// in staging on their way into the partial file. A partial file holds only the ranges
    /// recorded as done (`DownloadStorage.releaseUnrecorded`), so these are what the device holds.
    static func bytesSoFar(_ jobs: [DownloadJob], held: [(jobId: UUID, bytes: Int64)]) -> [UUID: Int64] {
        var bytes: [UUID: Int64] = [:]
        for job in jobs where job.status != .completed { bytes[job.id] = job.completed.byteCount }
        for (jobId, count) in held { bytes[jobId]? += count }
        return bytes
    }

    /// Whether a one-byte probe has to come first: the server hasn't answered for this file.
    /// Whether ranges work is a property of each file's stream, not of the server: Jellyfin
    /// passes remote sources and .strm files through as they come, and a proxy or CDN can treat
    /// paths differently. Chunks planned from the listed size would each fetch the whole file
    /// from a stream that ignores Range.
    var needsProbe: Bool { rangeSupport == .unknown }

    /// Its transfers have failed one after another, none coming through since.
    var isFailing: Bool { failingSince != nil }

    /// It keeps failing while other files' transfers come through, so the files behind it go
    /// first while it waits out its retries, each a single transfer, until one comes through. A
    /// file failing along with everything else (the server down, the network gone) keeps its
    /// place: then nothing yields.
    var yields: Bool { failedAloneAt != nil }

    /// The file the session works on: the first in the queue that isn't held and doesn't yield.
    static func fileInHand(_ jobs: [DownloadJob], held: Set<UUID>) -> UUID? {
        queued(jobs).first { !held.contains($0.id) && !$0.yields }?.id
    }

    /// The files whose transfers belong in the session. In front, the file in hand, with any ahead
    /// of it that yield; and while the file in hand is failing, the first file behind it that
    /// isn't waiting out a retry of its own, for one transfer: if that comes through, the trouble
    /// is the file in hand's own (`yields`), and if it fails too, nothing yields. Off screen, every
    /// file that isn't held, but of those `onlyInHand`, only one in hand.
    static func sessionFiles(_ jobs: [DownloadJob], held: Set<UUID>, queuingAhead: Bool, onlyInHand: Set<UUID> = [],
                             now: Date = .now) -> Set<UUID> {
        var files: Set<UUID> = []
        var hand: DownloadJob?
        for job in queued(jobs) where !held.contains(job.id) {
            guard let inHand = hand else {
                files.insert(job.id)
                if !job.yields { hand = job }
                continue
            }
            if queuingAhead {
                if !onlyInHand.contains(job.id) { files.insert(job.id) }
                continue
            }
            guard inHand.isFailing else { break }
            if job.yields || (job.retryAt ?? .distantPast) > now { continue }
            files.insert(job.id)
            break
        }
        return files
    }

    /// The transfers to start, up to `budget` of them, in queue order.
    ///
    /// The session holds the transfers of `sessionFiles`, never of a file `held` (by the rules, or
    /// for room). In front (`queuingAhead` false) that's the file in hand, which keeps
    /// `transfersInHand` there and is planned once the transfers other files have on the wire
    /// (`finishing`) are done: a file moved ahead takes over from the one it overtook without
    /// either losing bytes or sharing the connection. Off screen the session holds every file's
    /// transfers, so the system can carry on without the app. A file `waitingForNetwork` (the
    /// device is on a network its transfers may not use) is held in front; off screen its chunks
    /// go in for the system to start on a network they may use, but not a probe, which isn't the
    /// session's. A file that yields gets one transfer, timed for its retry, as does the file
    /// behind a failing file in hand once nothing of that is on the wire. A file that needs a
    /// probe gets only that, one probe at a time, so the server isn't asked about every file at
    /// once; a failing file's probe doesn't hold the others' back. In front, the files after the
    /// one in hand that need a probe get it in turn, so that all their chunks can go in the
    /// moment the app leaves the screen. Chunks are no bigger than `chunkLimit`, which room on
    /// the device can set (`StorageBudget`).
    static func plan(_ jobs: [DownloadJob], running: [TransferTag], finishing: Set<UUID> = [], held: Set<UUID> = [],
                     waitingForNetwork: Set<UUID> = [], onlyInHand: Set<UUID> = [], chunkLimit: Int64? = nil,
                     budget: Int, queuingAhead: Bool, now: Date = .now) -> [TransferTag] {
        let notPlanned = queuingAhead ? held : held.union(waitingForNetwork)
        let inSession = sessionFiles(jobs, held: notPlanned, queuingAhead: queuingAhead, onlyInHand: onlyInHand, now: now)
        let hand = fileInHand(jobs, held: notPlanned)
        let byId = Dictionary(jobs.map { ($0.id, $0) }) { first, _ in first }
        var tags: [TransferTag] = []
        var isProbing = running.contains { tag in
            tag.range == probeRange && byId[tag.jobId].map { !$0.isFailing } == true
        }
        for job in queued(jobs) where !notPlanned.contains(job.id) {
            guard tags.count < budget else { break }
            let id = job.id
            let claimed = running.filter { $0.jobId == id }
            let mayProbe = !waitingForNetwork.contains(id)
            /// A single transfer, while it has none.
            func single() -> [TransferTag] {
                guard claimed.isEmpty, mayProbe || !job.needsProbe else { return [] }
                return job.nextRequests(running: [], limit: 1, chunkLimit: chunkLimit).map { TransferTag(jobId: id, range: $0) }
            }
            if job.yields {
                if inSession.contains(id) { tags += single() }
                continue
            }
            guard inSession.contains(id) else {
                // After the file in hand: the next that needs a probe gets it, in turn. One waiting
                // out a retry lets the next go meanwhile.
                guard job.needsProbe, mayProbe else { continue }
                if job.isFailing, !claimed.isEmpty || (job.retryAt ?? .distantPast) > now { continue }
                if claimed.isEmpty, !isProbing {
                    tags.append(TransferTag(jobId: id, range: probeRange))
                    isProbing = true
                }
                break
            }
            if id != hand, !queuingAhead {
                // Behind the failing file in hand, to tell whether it fails alone.
                guard let hand, !finishing.contains(hand) else { continue }
                let test = single()
                tags += test
                if test.contains(where: { $0.range == probeRange }) { isProbing = true }
                continue
            }
            if job.needsProbe {
                if claimed.isEmpty, !isProbing, mayProbe {
                    tags.append(TransferTag(jobId: id, range: probeRange))
                    isProbing = true
                }
                continue
            }
            if !queuingAhead, !finishing.subtracting([id]).isEmpty { continue }
            let limit = queuingAhead ? budget - tags.count : min(budget - tags.count, transfersInHand - claimed.count)
            tags += job.nextRequests(running: claimed, limit: limit, chunkLimit: chunkLimit).map { TransferTag(jobId: id, range: $0) }
        }
        return tags
    }

    /// The transfers to start, given the ones already running for this job: a probe until the
    /// server has answered for the file, then byte ranges of `chunkSize`, or of `chunkLimit` when
    /// that's smaller, or nil for one whole-file request.
    func nextRequests(running: [TransferTag], limit: Int, chunkLimit: Int64? = nil) -> [Range<Int64>?] {
        guard status == .active, limit > 0 else { return [] }
        let size: Int64
        switch rangeSupport {
        case .unknown:
            return running.isEmpty ? [Self.probeRange] : []
        case .unsupported:
            return running.isEmpty ? [nil] : []
        case .supported:
            guard let totalBytes else { return [] }
            size = totalBytes
        }
        let chunk = chunkLimit.map { min(chunkSize, max(Self.minimumChunkSize, $0)) } ?? chunkSize
        var claimed = running.compactMap(\.range)
        var requests: [Range<Int64>?] = []
        while requests.count < limit, let gap = completed.firstGap(in: 0..<size, excluding: claimed) {
            let range = gap.lowerBound..<min(gap.upperBound, gap.lowerBound + chunk)
            requests.append(range)
            claimed.append(range)
        }
        return requests
    }

    /// The file's stream answered a range request with the whole file, so that one transfer
    /// fetches it: the ranges it had are let go, as the whole file takes their place.
    mutating func rangeIgnored() {
        rangeSupport = .unsupported
        completed = ByteRanges()
    }

    /// A transfer came through. Chunks grow by a quarter of each whole chunk that does, so after
    /// cuts they grow back at the pace bytes come through, whatever size the chunks still queued
    /// were planned at. A probe or a file's last few bytes, `wholeChunkBytes` 0, say nothing
    /// about the link.
    mutating func recordSuccess(wholeChunkBytes: Int64 = 0, now: Date = .now) {
        networkFailures = 0
        serverFailures = 0
        lastError = nil
        retryAt = nil
        serverUnreachableSince = nil
        failingSince = nil
        failedAloneAt = nil
        cameThroughAt = now
        chunkSize = min(Self.maximumChunkSize, chunkSize + wholeChunkBytes / 4)
    }

    /// A transfer whose current attempt began at `attemptStart` lost its connection after
    /// `receivedBytes`. Chunks halve, so on a link that keeps dropping they shrink until they
    /// fit between the drops. An attempt that began before the last cut says nothing new: one
    /// drop cuts every transfer under way, and the first of them already halved the size the
    /// rest were planned at. A connection that failed before any data says nothing about chunk
    /// size.
    mutating func recordCut(receivedBytes: Int64, attemptStart: Date, now: Date = .now) {
        guard receivedBytes > 0, attemptStart > (lastCutAt ?? .distantPast) else { return }
        chunkSize = max(Self.minimumChunkSize, chunkSize / 2)
        lastCutAt = now
    }

    /// The device ran out of room for a chunk of `size` bytes, written by the daemon or into the
    /// partial file, though the room it reported was enough (`StorageBudget`): what a write takes
    /// beyond its bytes, and other apps writing, can't be told beforehand. Chunks halve from that
    /// size, so near full they shrink until one fits rather than fail the same way again.
    mutating func ranOutOfSpace(writing size: Int64) {
        chunkSize = max(Self.minimumChunkSize, min(chunkSize, size) / 2)
    }

    /// Counts a failed transfer and schedules the retry. `attemptStart` is as for `recordCut`.
    /// `unreachable` says the server couldn't be reached at all, which a failure the server
    /// answered says it could. `otherArrival` is when another file's transfer last came through:
    /// after this file began failing, the trouble is its own (`yields`). Only then do the
    /// server's error answers give up on it, so that while everything fails, nothing gives up.
    mutating func recordFailure(_ failure: TransferFailure, receivedBytes: Int64, attemptStart: Date, unreachable: Bool = false,
                                otherArrival: Date? = nil, now: Date = .now) {
        let since = failingSince ?? now
        failingSince = since
        if let otherArrival, otherArrival > since, failedAloneAt == nil { failedAloneAt = now }
        switch failure {
        case .network(let message):
            networkFailures += 1
            if unreachable { serverUnreachableSince = serverUnreachableSince ?? now }
            recordCut(receivedBytes: receivedBytes, attemptStart: attemptStart, now: now)
            lastError = message
            retryAt = now.addingTimeInterval(Self.backoff(attempt: networkFailures, cap: 60))
        case .server(let message):
            serverFailures += 1
            serverUnreachableSince = nil
            lastError = message
            if serverFailures >= Self.maxServerFailures, yields {
                status = .failed
                retryAt = nil
            } else {
                retryAt = now.addingTimeInterval(Self.backoff(attempt: serverFailures, cap: 300))
            }
        }
    }

    /// 1, 2, 4, 8 … seconds, up to `cap`.
    static func backoff(attempt: Int, cap: TimeInterval) -> TimeInterval {
        min(cap, pow(2, Double(max(0, attempt - 1))))
    }

    /// Back to active from paused or failed, from where it got to, with no retry pending.
    mutating func resume() {
        status = .active
        networkFailures = 0
        serverFailures = 0
        retryAt = nil
        serverUnreachableSince = nil
        failingSince = nil
        failedAloneAt = nil
    }

    /// Back to the start, for a file that changed on the server.
    mutating func resetProgress() {
        resume()
        rangeSupport = .unknown
        totalBytes = nil
        completed = ByteRanges()
        chunkSize = Self.initialChunkSize
        lastError = nil
        lastCutAt = nil
    }

    /// Whether a transfer under way finishes when its download is paused, instead of being cut:
    /// one that can't keep its bytes (the server sent neither ETag nor Last-Modified, which
    /// resume data needs), with `received` of its `expected` bytes, when it has fetched at least
    /// as much as it has left, and that's no more than the largest chunk. Cut, it would lose more
    /// than finishing fetches; one less far along loses less than it would still fetch.
    static func finishesWhenPaused(received: Int64, expected: Int64?, canResume: Bool) -> Bool {
        guard !canResume, let expected, received > 0 else { return false }
        let left = expected - received
        return left <= received && left <= maximumChunkSize
    }
}

/// How a transfer in the session has moved, as the app looks at its task: whether the daemon
/// has it under way, and when its bytes last grew. Progress reports lag while the app is busy,
/// so the task's own count decides. A transfer waiting its turn, or timed for later, isn't
/// stalled, nor is one the daemon has finished whose report the app hasn't handled yet.
nonisolated struct TransferActivity: Equatable, Sendable {
    /// Started from resume data, whose response the task can carry before the daemon gets to it.
    let resumed: Bool
    /// What the task said it had received when last looked at.
    private(set) var bytes: Int64
    /// When the daemon was first seen working on it: a response, or bytes beyond those it had.
    private(set) var underWaySince: Date?
    /// When its bytes last grew, or it got under way.
    private(set) var lastProgress: Date

    init(bytes: Int64, resumed: Bool, now: Date) {
        self.bytes = bytes
        self.resumed = resumed
        lastProgress = now
    }

    var isUnderWay: Bool { underWaySince != nil }

    /// What its task says now: the bytes received, and whether it has a response.
    mutating func observe(bytes: Int64, hasResponse: Bool, now: Date) {
        if bytes != self.bytes {
            self.bytes = bytes
            noteProgress(now: now)
        } else if underWaySince == nil, hasResponse, !resumed {
            noteProgress(now: now)
        }
    }

    /// Bytes arrived, as a progress report says.
    mutating func noteProgress(now: Date) {
        lastProgress = now
        if underWaySince == nil { underWaySince = now }
    }

    /// Counts from now: the app has just acted on it, or couldn't look at it while suspended.
    mutating func restartClock(now: Date) {
        lastProgress = now
    }

    /// Whether a replacement carries on from its bytes, by its resume data: not when it was
    /// resumed and never got going, as the daemon can carry its wait over into the resume data.
    var carriesOnWhenReplaced: Bool { !resumed || isUnderWay }

    /// Whether the daemon runs it, has it under way and it has moved nothing for `limit`.
    func isStalled(state: URLSessionTask.State, now: Date, limit: TimeInterval) -> Bool {
        state == .running && isUnderWay && now.timeIntervalSince(lastProgress) > limit
    }
}
#endif
