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
    /// The server answered with an error. Retried up to `DownloadJob.maxServerFailures` times in a row.
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
            // a server can send more than was asked, up to the whole file for a one-byte probe.
            if sent.lowerBound >= requested.lowerBound, sent.lowerBound < requestedEnd, stagedSize == sent.count64 {
                return .chunk(sent, total: total)
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
            if rangeSupport == .supported, tag.range != nil {
                return .retry(.server("The server stopped honoring byte ranges."))
            }
            guard let stagedSize, stagedSize > 0 else { return .retry(.server("The server sent an empty file.")) }
            if let length = response.contentLength, length != stagedSize {
                return .retry(.network("The transfer was cut short."))
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

    /// A single byte: enough for the server to say how big the file is and that ranges work,
    /// without downloading any of it alongside the file in hand.
    static let probeRange: Range<Int64> = 0..<1

    /// The active jobs in the order they download: oldest first.
    static func queue(_ jobs: [DownloadJob]) -> [UUID] {
        jobs.filter { $0.status == .active && !$0.isTransferComplete }.sorted { $0.createdAt < $1.createdAt }.map(\.id)
    }

    /// Whether a one-byte probe has to come first: the server hasn't answered for this file, and
    /// either the listing gave no size or the server hasn't shown yet that it takes ranges.
    /// Chunks planned from the listed size would each fetch the whole file from a server that
    /// ignores Range.
    func needsProbe(serverTakesRanges: Bool) -> Bool {
        rangeSupport == .unknown && (sizeHint == nil || !serverTakesRanges)
    }

    /// Whether a file in the queue has shown that the server takes ranges. Unfinished files are
    /// all from the server signed in to: signing out removes them.
    static func serverTakesRanges(_ jobs: [DownloadJob]) -> Bool {
        jobs.contains { $0.status != .completed && $0.rangeSupport == .supported }
    }

    /// After this many error answers in a row, a file waiting out its retry lets the files
    /// behind it go ahead: a blip passes in the few seconds that takes, and a file the server
    /// can't serve doesn't hold the rest back for the hour its retries can take.
    static let serverFailuresBeforeYielding = 3

    func isBackingOff(at now: Date) -> Bool {
        serverFailures >= Self.serverFailuresBeforeYielding && (retryAt ?? .distantPast) > now
    }

    /// The transfers to start, up to `budget` of them, oldest file first.
    ///
    /// In front (`queuingAhead` false) the session works on one file, the oldest that isn't
    /// backing off. Off screen it holds every file's transfers, so the system can carry on
    /// without the app. A file backing off gets one transfer, timed for its retry. A file that
    /// needs a probe gets only that, one probe at a time, so the server isn't asked about every
    /// file at once. In front, the files after the one in hand that need a probe get it in turn,
    /// so that all their chunks can go in the moment the app leaves the screen.
    static func plan(_ jobs: [DownloadJob], running: [TransferTag], budget: Int, queuingAhead: Bool, now: Date = .now) -> [TransferTag] {
        let serverTakesRanges = serverTakesRanges(jobs)
        var tags: [TransferTag] = []
        var isProbing = running.contains { tag in
            tag.range == probeRange && jobs.contains { $0.id == tag.jobId && !$0.isBackingOff(at: now) }
        }
        var hasFileInHand = false
        for id in queue(jobs) {
            guard tags.count < budget, let job = jobs.first(where: { $0.id == id }) else { break }
            let claimed = running.filter { $0.jobId == id }
            let needsProbe = job.needsProbe(serverTakesRanges: serverTakesRanges)
            if job.isBackingOff(at: now) {
                if claimed.isEmpty, queuingAhead || !hasFileInHand {
                    tags += job.nextRequests(running: [], limit: 1, serverTakesRanges: serverTakesRanges).map { TransferTag(jobId: id, range: $0) }
                }
                continue
            }
            if hasFileInHand, !queuingAhead {
                guard needsProbe else { continue }
                if claimed.isEmpty, !isProbing { tags.append(TransferTag(jobId: id, range: probeRange)) }
                break
            }
            hasFileInHand = true
            if needsProbe {
                if claimed.isEmpty, !isProbing {
                    tags.append(TransferTag(jobId: id, range: probeRange))
                    isProbing = true
                }
                continue
            }
            tags += job.nextRequests(running: claimed, limit: budget - tags.count, serverTakesRanges: serverTakesRanges)
                .map { TransferTag(jobId: id, range: $0) }
        }
        return tags
    }

    /// The transfers to start, given the ones already running for this job.
    /// Each element is a byte range, or nil for one whole-file request.
    func nextRequests(running: [TransferTag], limit: Int, serverTakesRanges: Bool) -> [Range<Int64>?] {
        guard status == .active, limit > 0 else { return [] }
        let size: Int64
        switch rangeSupport {
        case .unknown:
            // Chunks from the listed size, which the first answer confirms.
            guard !needsProbe(serverTakesRanges: serverTakesRanges), let sizeHint else {
                return running.isEmpty ? [Self.probeRange] : []
            }
            size = sizeHint
        case .unsupported:
            return running.isEmpty ? [nil] : []
        case .supported:
            guard let totalBytes else { return [] }
            size = totalBytes
        }
        var claimed = running.compactMap(\.range)
        var requests: [Range<Int64>?] = []
        while requests.count < limit, let gap = completed.firstGap(in: 0..<size, excluding: claimed) {
            let range = gap.lowerBound..<min(gap.upperBound, gap.lowerBound + chunkSize)
            requests.append(range)
            claimed.append(range)
        }
        return requests
    }

    /// A transfer came through. Chunks grow by a quarter of each whole chunk that does, so after
    /// cuts they grow back at the pace bytes come through, whatever size the chunks still queued
    /// were planned at. A probe or a file's last few bytes, `wholeChunkBytes` 0, say nothing
    /// about the link.
    mutating func recordSuccess(wholeChunkBytes: Int64 = 0) {
        networkFailures = 0
        serverFailures = 0
        lastError = nil
        retryAt = nil
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

    /// Counts a failed transfer and schedules the retry. `attemptStart` is as for `recordCut`.
    mutating func recordFailure(_ failure: TransferFailure, receivedBytes: Int64, attemptStart: Date, now: Date = .now) {
        switch failure {
        case .network(let message):
            networkFailures += 1
            recordCut(receivedBytes: receivedBytes, attemptStart: attemptStart, now: now)
            lastError = message
            retryAt = now.addingTimeInterval(Self.backoff(attempt: networkFailures, cap: 60))
        case .server(let message):
            serverFailures += 1
            lastError = message
            if serverFailures >= Self.maxServerFailures {
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

    /// Back to the start, for a file that changed on the server.
    mutating func resetProgress() {
        status = .active
        rangeSupport = .unknown
        totalBytes = nil
        completed = ByteRanges()
        chunkSize = Self.initialChunkSize
        networkFailures = 0
        serverFailures = 0
        lastError = nil
        retryAt = nil
        lastCutAt = nil
    }
}
#endif
