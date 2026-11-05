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
    @Test func plansFromTheListedSizeOnceTheServerTakesRanges() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.chunkSize = 100_000_000
        // 300 MB listed: three chunks right away, once another file has shown ranges work.
        #expect(job.nextRequests(running: [], limit: 10, serverTakesRanges: true) == [0..<100_000_000, 100_000_000..<200_000_000, 200_000_000..<300_000_000])
        #expect(!job.needsProbe(serverTakesRanges: true))
        // Until then, one byte: chunks would each fetch the whole file from a server that ignores Range.
        #expect(job.needsProbe(serverTakesRanges: false))
        #expect(job.nextRequests(running: [], limit: 10, serverTakesRanges: false) == [DownloadJob.probeRange])
    }

    @Test func probesWithOneRequestFirstWithoutAListedSize() {
        var source = Samples.source
        source.size = nil
        let job = DownloadJob(item: Samples.movie, source: source)
        #expect(job.needsProbe(serverTakesRanges: true))
        #expect(job.nextRequests(running: [], limit: 10, serverTakesRanges: true) == [DownloadJob.probeRange])
        #expect(TransferTag(jobId: job.id, range: DownloadJob.probeRange).rangeHeader == "bytes=0-0")
        #expect(job.nextRequests(running: [TransferTag(jobId: job.id, range: 0..<10)], limit: 10, serverTakesRanges: true).isEmpty)
    }

    @Test func plansChunksAroundDoneAndRunningRanges() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = .supported
        job.totalBytes = 100
        job.chunkSize = 30
        job.completed = ByteRanges([0..<30])
        let running = [TransferTag(jobId: job.id, range: 30..<60)]
        #expect(job.nextRequests(running: running, limit: 5, serverTakesRanges: true) == [60..<90, 90..<100])
        #expect(job.nextRequests(running: running, limit: 1, serverTakesRanges: true) == [60..<90])
    }

    @Test func requestsTheWholeFileWithoutRangeSupport() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = .unsupported
        #expect(job.nextRequests(running: [], limit: 3, serverTakesRanges: false) == [nil])
    }

    /// The list's order, whatever order the files were queued in: people rearrange it.
    @Test func queuesFilesInListOrder() {
        let start = Date.now
        var first = DownloadJob(item: Samples.movie, source: Samples.source, now: start)
        var second = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 1)
        let third = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 2)
        #expect(DownloadJob.queue([first, second, third]) == [first.id, second.id, third.id])
        #expect(DownloadJob.queue([second, third, first]) == [second.id, third.id, first.id])
        first.status = .paused
        #expect(DownloadJob.queue([first, second, third]) == [second.id, third.id])
        // A job whose bytes are all in is being published, not transferred.
        second.rangeSupport = .supported
        second.totalBytes = 10
        second.completed = ByteRanges([0..<10])
        #expect(DownloadJob.queue([first, second, third]) == [third.id])
        #expect(DownloadJob.queue([first, second]).isEmpty)
    }

    /// A paused download's bytes in resume data count with its partial file's; a finished
    /// download's file is counted elsewhere, and a forgotten one's leftovers not at all.
    @Test func countsTheBytesTransfersHoldWithThePartialFile() {
        var paused = DownloadJob(item: Samples.movie, source: Samples.source)
        paused.status = .paused
        paused.completed = ByteRanges([0..<1])
        var running = DownloadJob(item: Samples.movie, source: Samples.source)
        running.completed = ByteRanges([0..<100])
        var finished = DownloadJob(item: Samples.movie, source: Samples.source)
        finished.status = .completed
        finished.completed = ByteRanges([0..<300])
        let held: [(jobId: UUID, bytes: Int64)] = [
            (paused.id, 2_000), (paused.id, 1_500), (running.id, 50), (finished.id, 10), (UUID(), 999),
        ]
        #expect(DownloadJob.bytesSoFar([paused, running, finished], held: held) == [paused.id: 3_501, running.id: 150])
    }

    /// 300 MB files in 100 MB chunks, the first confirmed by the server.
    private func twoFiles() -> (first: DownloadJob, second: DownloadJob) {
        let start = Date.now
        var first = DownloadJob(item: Samples.movie, source: Samples.source, now: start)
        var second = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 1)
        first.rangeSupport = .supported
        first.totalBytes = 300_000_000
        first.chunkSize = 100_000_000
        second.chunkSize = 100_000_000
        return (first, second)
    }

    @Test func plansOneFileUnlessQueuingAhead() {
        var (first, second) = twoFiles()
        let alone = DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: false)
        #expect(alone.map(\.jobId) == [first.id, first.id, first.id])
        // The first file's last chunk under way: still nothing of the second.
        let tail = [TransferTag(jobId: first.id, range: 200_000_000..<300_000_000)]
        first.completed = ByteRanges([0..<200_000_000])
        #expect(DownloadJob.plan([first, second], running: tail, budget: 10, queuingAhead: false).isEmpty)
        // Off screen, the second file's chunks from its listed size, the server having shown it takes ranges.
        let ahead = DownloadJob.plan([first, second], running: tail, budget: 10, queuingAhead: true)
        #expect(ahead.map(\.jobId) == [second.id, second.id, second.id])
        #expect(DownloadJob.plan([first, second], running: tail, budget: 2, queuingAhead: true).count == 2)
    }

    /// A server that ignores Range would send the whole file for every chunk planned from the
    /// listed size, so until one file has shown ranges work, a file gets one request.
    @Test func asksForOneByteUntilTheServerHasShownItTakesRanges() {
        let start = Date.now
        let first = DownloadJob(item: Samples.movie, source: Samples.source, now: start)
        let second = DownloadJob(item: Samples.episode, source: Samples.source, now: start + 1)
        let probe = TransferTag(jobId: first.id, range: DownloadJob.probeRange)
        #expect(DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: true) == [probe])
        #expect(DownloadJob.plan([first, second], running: [probe], budget: 10, queuingAhead: true).isEmpty)
    }

    /// In front, the next file that needs a probe gets it, so leaving the screen can queue all
    /// of its chunks at once; the one after waits.
    @Test func probesTheNextFileInFront() {
        let (first, _) = twoFiles()
        var unknown = Samples.source
        unknown.size = nil
        let start = first.createdAt
        let listed = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 1)
        let second = DownloadJob(item: Samples.movie, source: unknown, now: start + 2)
        let third = DownloadJob(item: Samples.movie, source: unknown, now: start + 3)
        let plan = DownloadJob.plan([first, listed, second, third], running: [], budget: 10, queuingAhead: false)
        #expect(plan.filter { $0.jobId == first.id }.count == 3)
        #expect(plan.filter { $0.jobId != first.id } == [TransferTag(jobId: second.id, range: DownloadJob.probeRange)])
    }

    /// Off screen, a file waiting for its probe doesn't hold back files that can be planned.
    @Test func queuesAheadPastAFileWaitingForItsProbe() {
        let (first, _) = twoFiles()
        var unknown = Samples.source
        unknown.size = nil
        let start = first.createdAt
        let waiting = DownloadJob(item: Samples.movie, source: unknown, now: start + 1)
        let listed = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 2)
        let last = DownloadJob(item: Samples.movie, source: unknown, now: start + 3)
        let probe = TransferTag(jobId: waiting.id, range: DownloadJob.probeRange)
        let plan = DownloadJob.plan([first, waiting, listed, last], running: [probe], budget: 100, queuingAhead: true)
        #expect(plan.contains { $0.jobId == listed.id })
        #expect(!plan.contains { $0.jobId == waiting.id || $0.jobId == last.id })
    }

    /// A file the server keeps refusing lets the next one go ahead while it waits out its retry,
    /// with one transfer timed for the retry.
    @Test func letsTheNextFileGoAheadOfOneBackingOff() {
        var (first, second) = twoFiles()
        let now = Date.now
        first.serverFailures = DownloadJob.serverFailuresBeforeYielding
        first.retryAt = now + 60
        second.rangeSupport = .supported
        second.totalBytes = 300_000_000
        let plan = DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: false, now: now)
        #expect(plan.filter { $0.jobId == first.id } == [TransferTag(jobId: first.id, range: 0..<100_000_000)])
        #expect(plan.filter { $0.jobId == second.id }.count == 3)
        // One blip doesn't reshuffle the queue.
        first.serverFailures = 1
        #expect(DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: false, now: now).allSatisfy { $0.jobId == first.id })
        // Once the retry is due, the file is back in hand.
        first.serverFailures = DownloadJob.serverFailuresBeforeYielding
        #expect(DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: false, now: now + 61).allSatisfy { $0.jobId == first.id })
    }

    @Test func requestsNothingUnlessActive() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.status = .paused
        #expect(job.nextRequests(running: [], limit: 3, serverTakesRanges: true).isEmpty)
    }

    @Test func givesUpOnClientErrorsThatAskingAgainWontFix() {
        let tag = TransferTag(jobId: UUID(), range: 0..<100)
        for status in [400, 403, 404, 410] {
            guard case .giveUp = job().evaluate(ResponseInfo(statusCode: status), stagedSize: 0, tag: tag) else {
                Issue.record("expected HTTP \(status) to give up")
                continue
            }
        }
        for status in [408, 416, 429, 500, 503] {
            guard case .retry(.server) = job().evaluate(ResponseInfo(statusCode: status), stagedSize: 0, tag: tag) else {
                Issue.record("expected HTTP \(status) to be retried")
                continue
            }
        }
    }

    private func job() -> DownloadJob { DownloadJob(item: Samples.movie, source: Samples.source) }

    @Test func shrinksChunksOnlyWhenCutOffMidTransfer() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        let start = job.chunkSize
        let now = Date(timeIntervalSince1970: 1000)
        job.recordFailure(.network("refused"), receivedBytes: 0, attemptStart: now, now: now)
        #expect(job.chunkSize == start)
        #expect(job.retryAt == now.addingTimeInterval(1))
        job.recordFailure(.network("dropped"), receivedBytes: 500, attemptStart: now, now: now + 1)
        #expect(job.chunkSize == start / 2)
        #expect(job.retryAt == now.addingTimeInterval(3))
        for attempt in 2..<42 {
            let began = now + Double(attempt)
            job.recordFailure(.network("dropped"), receivedBytes: 1, attemptStart: began, now: began + 0.5)
        }
        #expect(job.chunkSize == DownloadJob.minimumChunkSize)
        #expect(job.status == .active)
        job.recordSuccess(wholeChunkBytes: job.chunkSize)
        #expect(job.networkFailures == 0)
        #expect(job.retryAt == nil)
        #expect(job.chunkSize > DownloadJob.minimumChunkSize)
    }

    /// One drop cuts every transfer under way; the chunk size halves once for it, not once each.
    @Test func halvesOnceForADropThatCutsSeveralTransfers() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        let start = job.chunkSize
        let began = Date(timeIntervalSince1970: 1000)
        for offset in 0..<4 {
            job.recordCut(receivedBytes: 1_000_000, attemptStart: began, now: began + 30 + Double(offset) / 10)
        }
        #expect(job.chunkSize == start / 2)
        // A transfer started after that cut and dropped too says the smaller size is still too big.
        job.recordCut(receivedBytes: 1_000_000, attemptStart: began + 31, now: began + 60)
        #expect(job.chunkSize == start / 4)
    }

    /// Chunks grow by a quarter of each whole chunk that comes through, so small chunks queued
    /// before a cut grow the size back at the pace bytes arrive, and a probe or a file's tail don't.
    @Test func growsBackByAQuarterOfEachWholeChunk() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.chunkSize = DownloadJob.minimumChunkSize
        job.recordSuccess()
        #expect(job.chunkSize == DownloadJob.minimumChunkSize)
        for _ in 0..<60 { job.recordSuccess(wholeChunkBytes: DownloadJob.minimumChunkSize) }
        #expect(job.chunkSize == 16 << 20)
        for _ in 0..<1000 { job.recordSuccess(wholeChunkBytes: DownloadJob.maximumChunkSize) }
        #expect(job.chunkSize == DownloadJob.maximumChunkSize)
    }

    @Test func givesUpAfterRepeatedServerErrors() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        for _ in 0..<(DownloadJob.maxServerFailures - 1) { job.recordFailure(.server("HTTP 500"), receivedBytes: 0, attemptStart: .now) }
        #expect(job.status == .active)
        #expect(job.retryAt != nil)
        job.recordFailure(.server("HTTP 500"), receivedBytes: 0, attemptStart: .now)
        #expect(job.status == .failed)
        #expect(job.lastError == "HTTP 500")
    }

    @Test func backoffDoublesUpToTheCap() {
        #expect((1...8).map { DownloadJob.backoff(attempt: $0, cap: 60) } == [1, 2, 4, 8, 16, 32, 60, 60])
    }

    /// The session holds a whole 4K file, once its chunks have grown, and the next file too.
    @Test @MainActor func theBudgetQueuesAWhole4KFileAndTheNext() {
        let start = Date.now
        var large = DownloadJob(item: Samples.movie, source: Samples.source, now: start)
        large.rangeSupport = .supported
        large.totalBytes = 20 << 30
        large.chunkSize = DownloadJob.maximumChunkSize
        let next = DownloadJob(item: Samples.episode, source: Samples.source, now: start + 1)
        let plan = DownloadJob.plan([large, next], running: [], budget: DownloadManager.maxQueuedTransfers, queuingAhead: true)
        #expect(plan.count { $0.jobId == large.id } == 320)
        #expect(plan.contains { $0.jobId == next.id })
        #expect(plan.count <= DownloadManager.maxQueuedTransfers)
    }

    /// At the starting chunk size, the budget is 8 GB of one file.
    @Test @MainActor func theBudgetStopsAtEightGigabytesOfStartingChunks() {
        var large = DownloadJob(item: Samples.movie, source: Samples.source)
        large.rangeSupport = .supported
        large.totalBytes = 60 << 30
        let plan = DownloadJob.plan([large], running: [], budget: DownloadManager.maxQueuedTransfers, queuingAhead: true)
        #expect(plan.count == DownloadManager.maxQueuedTransfers)
        #expect(plan.compactMap(\.range).reduce(0) { $0 + $1.count64 } == 8 << 30)
    }
}
#endif
