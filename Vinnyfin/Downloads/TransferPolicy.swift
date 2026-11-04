#if !os(tvOS)
import Foundation

/// What a transfer task is for. Stored as the task's `taskDescription`, which the background
/// session keeps across app launches, so a relaunched app knows what every task carries.
nonisolated struct TransferTag: Equatable, Sendable {
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

    /// Neither the server nor the listing has said how big the file is, so its chunks wait for
    /// the answer to a probe.
    var needsProbe: Bool { rangeSupport == .unknown && sizeHint == nil }

    /// The transfers to start, given the ones already running for this job.
    /// Each element is a byte range, or nil for one whole-file request.
    func nextRequests(running: [TransferTag], limit: Int) -> [Range<Int64>?] {
        guard status == .active, limit > 0 else { return [] }
        let size: Int64
        switch rangeSupport {
        case .unknown:
            // Chunks from the listed size, which the first answer confirms (Jellyfin takes ranges);
            // without one, a probe first.
            guard let sizeHint else { return running.isEmpty ? [Self.probeRange] : [] }
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

    /// A transfer came through. Chunks grow back after cuts when it was a whole chunk; a probe
    /// or a file's last few bytes say nothing about the link.
    mutating func recordSuccess(growingChunks: Bool = true) {
        networkFailures = 0
        serverFailures = 0
        lastError = nil
        retryAt = nil
        if growingChunks { chunkSize = min(Self.maximumChunkSize, chunkSize + chunkSize / 4) }
    }

    /// A transfer lost its connection after `receivedBytes`. Chunks halve, so on a link that
    /// keeps dropping they shrink until they fit between the drops. A connection that failed
    /// before any data says nothing about chunk size.
    mutating func recordCut(receivedBytes: Int64) {
        if receivedBytes > 0 { chunkSize = max(Self.minimumChunkSize, chunkSize / 2) }
    }

    /// Counts a failed transfer and schedules the retry.
    mutating func recordFailure(_ failure: TransferFailure, receivedBytes: Int64, now: Date = .now) {
        switch failure {
        case .network(let message):
            networkFailures += 1
            recordCut(receivedBytes: receivedBytes)
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
    }
}
#endif
