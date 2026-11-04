#if !os(tvOS)
import Foundation
import Testing
@testable import vinnyfin

struct ByteRangesTests {
    @Test func mergesOverlappingAndTouchingRanges() {
        var ranges = ByteRanges()
        ranges.insert(10..<20)
        ranges.insert(30..<40)
        ranges.insert(20..<30)
        ranges.insert(5..<12)
        #expect(ranges.ranges == [5..<40])
        #expect(ranges.byteCount == 35)
    }

    @Test func keepsDisjointRangesSorted() {
        let ranges = ByteRanges([50..<60, 0..<10, 20..<30])
        #expect(ranges.ranges == [0..<10, 20..<30, 50..<60])
        #expect(ranges.covers(20..<30))
        #expect(!ranges.covers(9..<21))
    }

    @Test func findsTheFirstUnclaimedGap() {
        let done = ByteRanges([0..<10, 30..<40])
        #expect(done.firstGap(in: 0..<100, excluding: []) == 10..<30)
        #expect(done.firstGap(in: 0..<100, excluding: [10..<30]) == 40..<100)
        #expect(done.firstGap(in: 0..<40, excluding: [10..<30]) == nil)
        #expect(ByteRanges().firstGap(in: 0..<5, excluding: [2..<3]) == 0..<2)
        #expect(done.firstGap(in: 0..<35, excluding: [10..<20]) == 20..<30)
    }
}

struct HeaderParsingTests {
    @Test func parsesContentRange() {
        let header = ContentRange(header: "bytes 100-199/1000")
        #expect(header?.range == 100..<200)
        #expect(header?.total == 1000)
        #expect(ContentRange(header: "bytes 0-0/*")?.total == nil)
        #expect(ContentRange(header: "bytes 5-4/10") == nil)
        #expect(ContentRange(header: "bytes 0-10/10") == nil)
        #expect(ContentRange(header: "items 0-1/2") == nil)
        #expect(ContentRange(header: nil) == nil)
    }

    @Test func transferTagRoundTrips() {
        let id = UUID()
        let ranged = TransferTag(jobId: id, range: 1024..<2048)
        #expect(TransferTag(encoded: ranged.encoded) == ranged)
        #expect(ranged.rangeHeader == "bytes=1024-2047")
        let whole = TransferTag(jobId: id, range: nil)
        #expect(TransferTag(encoded: whole.encoded) == whole)
        #expect(whole.rangeHeader == nil)
        #expect(TransferTag(encoded: "not a tag") == nil)
        #expect(TransferTag(encoded: "\(id.uuidString) 10 5") == nil)
        #expect(TransferTag(encoded: nil) == nil)
    }

    @Test func extensionFromResponse() {
        #expect(ResponseInfo(statusCode: 200, contentType: "video/x-matroska").videoExtension == "mkv")
        #expect(ResponseInfo(statusCode: 200, contentType: "video/mp4; charset=binary").videoExtension == "mp4")
        #expect(ResponseInfo(statusCode: 200, contentType: "application/octet-stream", suggestedFilename: "Movie.2024.m2ts").videoExtension == "m2ts")
        #expect(ResponseInfo(statusCode: 200, contentType: "application/octet-stream", suggestedFilename: "stream").videoExtension == nil)
    }
}

struct EvaluateTests {
    private func job(rangeSupport: DownloadJob.RangeSupport = .unknown, total: Int64? = nil) -> DownloadJob {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = rangeSupport
        job.totalBytes = total
        return job
    }

    private func partial(_ header: String, type: String = "video/x-matroska") -> ResponseInfo {
        ResponseInfo(statusCode: 206, contentRange: header, contentType: type)
    }

    @Test func acceptsTheFirstChunkAndLearnsTheSize() {
        let tag = TransferTag(jobId: UUID(), range: 0..<100)
        let outcome = job().evaluate(partial("bytes 0-99/5000"), stagedSize: 100, tag: tag)
        #expect(outcome == .chunk(0..<100, total: 5000))
    }

    @Test func acceptsAShortLastChunk() {
        let tag = TransferTag(jobId: UUID(), range: 4900..<5100)
        let outcome = job(rangeSupport: .supported, total: 5000).evaluate(partial("bytes 4900-4999/5000"), stagedSize: 100, tag: tag)
        #expect(outcome == .chunk(4900..<5000, total: 5000))
    }

    @Test func retriesATruncatedChunk() {
        let tag = TransferTag(jobId: UUID(), range: 0..<100)
        let outcome = job().evaluate(partial("bytes 0-99/5000"), stagedSize: 60, tag: tag)
        #expect(outcome == .retry(.network("The transfer was cut short.")))
    }

    @Test func acceptsAChunkTheSystemResumedItself() {
        // The daemon fetched 0-39 on one connection and 40-99 on the next; the file holds 0-99.
        let tag = TransferTag(jobId: UUID(), range: 0..<100)
        let outcome = job(rangeSupport: .supported, total: 5000).evaluate(partial("bytes 40-99/5000"), stagedSize: 100, tag: tag)
        #expect(outcome == .chunk(0..<100, total: 5000))
    }

    @Test func acceptsLessThanAskedFor() {
        let tag = TransferTag(jobId: UUID(), range: 0..<100)
        let outcome = job(rangeSupport: .supported, total: 5000).evaluate(partial("bytes 0-49/5000"), stagedSize: 50, tag: tag)
        #expect(outcome == .chunk(0..<50, total: 5000))
    }

    @Test func acceptsMoreThanAskedFor() {
        // A server that answers a one-byte probe with the whole file.
        let tag = TransferTag(jobId: UUID(), range: DownloadJob.probeRange)
        #expect(job().evaluate(partial("bytes 0-4999/5000"), stagedSize: 5000, tag: tag) == .chunk(0..<5000, total: 5000))
    }

    @Test func retriesTheWrongRange() {
        let tag = TransferTag(jobId: UUID(), range: 100..<200)
        let outcome = job(rangeSupport: .supported, total: 5000).evaluate(partial("bytes 0-99/5000"), stagedSize: 100, tag: tag)
        guard case .retry(.server) = outcome else { Issue.record("expected a server retry, got \(outcome)"); return }
    }

    @Test func givesUpWhenTheFileChangesSize() {
        let tag = TransferTag(jobId: UUID(), range: 100..<200)
        let outcome = job(rangeSupport: .supported, total: 5000).evaluate(partial("bytes 100-199/6000"), stagedSize: 100, tag: tag)
        guard case .giveUp = outcome else { Issue.record("expected give up, got \(outcome)"); return }
    }

    @Test func takesAWholeFileWhenRangeIsIgnored() {
        let tag = TransferTag(jobId: UUID(), range: 0..<100)
        let response = ResponseInfo(statusCode: 200, contentType: "video/mp4", contentLength: 5000)
        #expect(job().evaluate(response, stagedSize: 5000, tag: tag) == .wholeFile(size: 5000))
        #expect(job().evaluate(response, stagedSize: 4000, tag: tag) == .retry(.network("The transfer was cut short.")))
    }

    @Test func refusesAWholeFileOnceChunking() {
        let tag = TransferTag(jobId: UUID(), range: 100..<200)
        let response = ResponseInfo(statusCode: 200, contentType: "video/mp4", contentLength: 5000)
        guard case .retry(.server) = job(rangeSupport: .supported, total: 5000).evaluate(response, stagedSize: 5000, tag: tag)
        else { Issue.record("expected a server retry"); return }
    }

    @Test func switchesToWholeFileWithoutATotal() {
        let tag = TransferTag(jobId: UUID(), range: 0..<100)
        #expect(job().evaluate(partial("bytes 0-99/*"), stagedSize: 100, tag: tag) == .switchToWholeFile)
    }

    @Test func treatsErrorPagesAsServerErrors() {
        let tag = TransferTag(jobId: UUID(), range: 0..<100)
        let page = ResponseInfo(statusCode: 200, contentType: "text/html; charset=utf-8", contentLength: 100)
        guard case .retry(.server) = job().evaluate(page, stagedSize: 100, tag: tag) else { Issue.record("expected a server retry"); return }
        guard case .retry(.server) = job().evaluate(ResponseInfo(statusCode: 503), stagedSize: 10, tag: tag) else { Issue.record("expected a server retry"); return }
        guard case .giveUp = job().evaluate(ResponseInfo(statusCode: 401), stagedSize: 10, tag: tag) else { Issue.record("expected give up"); return }
        #expect(job().evaluate(nil, stagedSize: nil, tag: tag) == .retry(.network("The server didn't answer.")))
    }
}

struct SchedulingTests {
    @Test func plansFromTheListedSize() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.chunkSize = 100_000_000
        // 300 MB listed: three chunks right away, before the server has said anything.
        #expect(job.nextRequests(running: [], limit: 10) == [0..<100_000_000, 100_000_000..<200_000_000, 200_000_000..<300_000_000])
        #expect(!job.needsProbe)
    }

    @Test func probesWithOneRequestFirstWithoutAListedSize() {
        var source = Samples.source
        source.size = nil
        let job = DownloadJob(item: Samples.movie, source: source)
        #expect(job.needsProbe)
        #expect(job.nextRequests(running: [], limit: 10) == [DownloadJob.probeRange])
        #expect(TransferTag(jobId: job.id, range: DownloadJob.probeRange).rangeHeader == "bytes=0-0")
        #expect(job.nextRequests(running: [TransferTag(jobId: job.id, range: 0..<10)], limit: 10).isEmpty)
    }

    @Test func plansChunksAroundDoneAndRunningRanges() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = .supported
        job.totalBytes = 100
        job.chunkSize = 30
        job.completed = ByteRanges([0..<30])
        let running = [TransferTag(jobId: job.id, range: 30..<60)]
        #expect(job.nextRequests(running: running, limit: 5) == [60..<90, 90..<100])
        #expect(job.nextRequests(running: running, limit: 1) == [60..<90])
    }

    @Test func requestsTheWholeFileWithoutRangeSupport() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = .unsupported
        #expect(job.nextRequests(running: [], limit: 3) == [nil])
    }

    @Test func queuesFilesOldestFirst() {
        let start = Date.now
        var first = DownloadJob(item: Samples.movie, source: Samples.source, now: start)
        var second = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 1)
        let third = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 2)
        #expect(DownloadJob.queue([second, third, first]) == [first.id, second.id, third.id])
        first.status = .paused
        #expect(DownloadJob.queue([first, second, third]) == [second.id, third.id])
        // A job whose bytes are all in is being published, not transferred.
        second.rangeSupport = .supported
        second.totalBytes = 10
        second.completed = ByteRanges([0..<10])
        #expect(DownloadJob.queue([first, second, third]) == [third.id])
        #expect(DownloadJob.queue([first, second]).isEmpty)
    }

    @Test func plansOneFileUnlessQueuingAhead() {
        let start = Date.now
        var first = DownloadJob(item: Samples.movie, source: Samples.source, now: start)
        var second = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 1)
        first.chunkSize = 100_000_000
        second.chunkSize = 100_000_000
        // 300 MB each: three chunks a file.
        let alone = DownloadJob.plan([second, first], running: [], budget: 10, queuingAhead: false)
        #expect(alone.map(\.jobId) == [first.id, first.id, first.id])
        // The first file's last chunk under way: still nothing of the second.
        let tail = [TransferTag(jobId: first.id, range: 200_000_000..<300_000_000)]
        first.completed = ByteRanges([0..<200_000_000])
        #expect(DownloadJob.plan([first, second], running: tail, budget: 10, queuingAhead: false).isEmpty)
        let ahead = DownloadJob.plan([first, second], running: tail, budget: 10, queuingAhead: true)
        #expect(ahead.map(\.jobId) == [second.id, second.id, second.id])
        #expect(DownloadJob.plan([first, second], running: tail, budget: 2, queuingAhead: true).count == 2)
    }

    @Test func queuesNothingAheadOfAFileOfUnknownSize() {
        let start = Date.now
        var unknown = Samples.source
        unknown.size = nil
        let first = DownloadJob(item: Samples.movie, source: unknown, now: start)
        let second = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 1)
        let plan = DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: true)
        #expect(plan == [TransferTag(jobId: first.id, range: DownloadJob.probeRange)])
    }

    @Test func requestsNothingUnlessActive() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.status = .paused
        #expect(job.nextRequests(running: [], limit: 3).isEmpty)
    }

    @Test func shrinksChunksOnlyWhenCutOffMidTransfer() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        let start = job.chunkSize
        let now = Date(timeIntervalSince1970: 1000)
        job.recordFailure(.network("refused"), receivedBytes: 0, now: now)
        #expect(job.chunkSize == start)
        #expect(job.retryAt == now.addingTimeInterval(1))
        job.recordFailure(.network("dropped"), receivedBytes: 500, now: now)
        #expect(job.chunkSize == start / 2)
        #expect(job.retryAt == now.addingTimeInterval(2))
        for _ in 0..<40 { job.recordFailure(.network("dropped"), receivedBytes: 1, now: now) }
        #expect(job.chunkSize == DownloadJob.minimumChunkSize)
        #expect(job.retryAt == now.addingTimeInterval(60))
        #expect(job.status == .active)
        job.recordSuccess()
        #expect(job.networkFailures == 0)
        #expect(job.retryAt == nil)
        #expect(job.chunkSize > DownloadJob.minimumChunkSize)
    }

    @Test func givesUpAfterRepeatedServerErrors() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        for _ in 0..<(DownloadJob.maxServerFailures - 1) { job.recordFailure(.server("HTTP 500"), receivedBytes: 0) }
        #expect(job.status == .active)
        #expect(job.retryAt != nil)
        job.recordFailure(.server("HTTP 500"), receivedBytes: 0)
        #expect(job.status == .failed)
        #expect(job.lastError == "HTTP 500")
    }

    @Test func backoffDoublesUpToTheCap() {
        #expect((1...8).map { DownloadJob.backoff(attempt: $0, cap: 60) } == [1, 2, 4, 8, 16, 32, 60, 60])
    }
}
#endif
