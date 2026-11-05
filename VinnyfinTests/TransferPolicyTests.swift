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
        // A server that answers a one-byte probe with the whole file, all of which arrived.
        let tag = TransferTag(jobId: UUID(), range: DownloadJob.probeRange)
        #expect(job().evaluate(partial("bytes 0-4999/5000"), stagedSize: 5000, tag: tag) == .chunk(0..<5000, total: 5000))
    }

    /// The probe reads only the byte it asked for, though the server names the whole file in
    /// Content-Range and goes on sending it.
    @Test func takesTheByteAProbeReadOfAWholeFileAnswer() {
        let tag = TransferTag(jobId: UUID(), range: DownloadJob.probeRange)
        let outcome = job().evaluate(partial("bytes 0-16177652/16177653"), stagedSize: 1, tag: tag)
        #expect(outcome == .chunk(0..<1, total: 16_177_653))
        // Nothing read is a cut, not the byte.
        #expect(job().evaluate(partial("bytes 0-16177652/16177653"), stagedSize: 0, tag: tag) == .retry(.network("The transfer was cut short.")))
        // An answer that starts elsewhere is still wrong.
        guard case .retry(.server) = job().evaluate(partial("bytes 5-16177652/16177653"), stagedSize: 1, tag: tag) else {
            Issue.record("expected a server retry")
            return
        }
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

    /// A file whose stream stops honoring Range sends itself whole: kept, if it's the size it was.
    @Test func takesAWholeFileOnceChunkingIfItsTheSameSize() {
        let tag = TransferTag(jobId: UUID(), range: 100..<200)
        let response = ResponseInfo(statusCode: 200, contentType: "video/mp4", contentLength: 5000)
        #expect(job(rangeSupport: .supported, total: 5000).evaluate(response, stagedSize: 5000, tag: tag) == .wholeFile(size: 5000))
        let resized = ResponseInfo(statusCode: 200, contentType: "video/mp4", contentLength: 6000)
        guard case .giveUp = job(rangeSupport: .supported, total: 5000).evaluate(resized, stagedSize: 6000, tag: tag)
        else { Issue.record("expected give up"); return }
    }

    /// Answered with the whole file for a range, the file takes that one transfer: its ranges go,
    /// and the next request is the whole file, once nothing else runs.
    @Test func aWholeFileForARangeTakesThePlaceOfTheRanges() {
        var file = job(rangeSupport: .supported, total: 5000)
        file.completed = ByteRanges([0..<1000])
        file.rangeIgnored()
        #expect(file.rangeSupport == .unsupported && file.completed.byteCount == 0 && file.totalBytes == 5000)
        #expect(file.nextRequests(running: [], limit: 4) == [nil])
        #expect(file.nextRequests(running: [TransferTag(jobId: file.id, range: 0..<100)], limit: 4).isEmpty)
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
    /// Whether ranges work is a property of each file's stream: a file is asked for one byte
    /// first, whatever another file has shown, listed size or not.
    @Test func probesEveryFileWhateverOthersShowed() {
        var shown = DownloadJob(item: Samples.movie, source: Samples.source, now: .now)
        shown.rangeSupport = .supported
        shown.totalBytes = 300_000_000
        shown.status = .paused
        var listed = DownloadJob(item: Samples.episode, source: Samples.source, now: .now + 1)
        listed.chunkSize = 16 << 20
        #expect(listed.needsProbe)
        #expect(listed.nextRequests(running: [], limit: 10) == [DownloadJob.probeRange])
        let probe = TransferTag(jobId: listed.id, range: DownloadJob.probeRange)
        #expect(DownloadJob.plan([shown, listed], running: [], budget: 100, queuingAhead: false) == [probe])
        #expect(DownloadJob.plan([shown, listed], running: [], budget: 100, queuingAhead: true) == [probe])
        #expect(DownloadJob.plan([shown, listed], running: [probe], budget: 100, queuingAhead: true).isEmpty)
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

    /// Room on the device can cap the chunks, but never below the smallest.
    @Test func keepsChunksWithinTheLimitRoomSets() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = .supported
        job.totalBytes = 64 << 20
        job.chunkSize = 32 << 20
        #expect(job.nextRequests(running: [], limit: 10, chunkLimit: 10 << 20).first == 0..<(10 << 20))
        #expect(job.nextRequests(running: [], limit: 10, chunkLimit: 1).first == 0..<DownloadJob.minimumChunkSize)
        #expect(job.nextRequests(running: [], limit: 10, chunkLimit: 1 << 30).count == 2)
        let plan = DownloadJob.plan([job], running: [], chunkLimit: 10 << 20, budget: 100, queuingAhead: true)
        #expect(plan.compactMap(\.range).allSatisfy { $0.count64 <= 10 << 20 } && plan.count == 7)
    }

    /// In front the file in hand keeps a few transfers in the session, topped up as they finish,
    /// so each is planned in the chunk size of the moment; off screen it all goes in.
    @Test func plansTheFileInHandAFewChunksAtATimeInFront() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = .supported
        job.totalBytes = 1 << 30
        let inFront = DownloadJob.plan([job], running: [], budget: 512, queuingAhead: false)
        #expect(inFront.count == DownloadJob.transfersInHand)
        let topUp = DownloadJob.plan([job], running: Array(inFront.dropFirst()), budget: 512, queuingAhead: false)
        #expect(topUp.count == 1)
        // The chunks grew while those were under way: the next is planned at the new size.
        job.chunkSize = DownloadJob.maximumChunkSize
        #expect(DownloadJob.plan([job], running: Array(inFront.dropLast()), budget: 512, queuingAhead: false).first?.range?.count64
            == DownloadJob.maximumChunkSize)
        #expect(DownloadJob.plan([job], running: [], budget: 512, queuingAhead: true).count == 16)
    }

    /// A chunk being written into its file stays claimed, so planning meanwhile doesn't ask for
    /// its range again, and its bytes count as the download's.
    @Test func aChunkBeingWrittenStaysClaimed() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = .supported
        job.totalBytes = 300
        job.chunkSize = DownloadJob.minimumChunkSize
        let writing = TransferTag(jobId: job.id, range: 0..<100)
        #expect(job.nextRequests(running: [writing], limit: 10) == [100..<300])
        #expect(DownloadJob.bytesSoFar([job], held: [(job.id, 100)]) == [job.id: 100])
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

    /// 300 MB files in 100 MB chunks, both confirmed by the server.
    private func twoFiles() -> (first: DownloadJob, second: DownloadJob) {
        let start = Date.now
        return (confirmed(at: start), confirmed(at: start + 1))
    }

    private func confirmed(at date: Date) -> DownloadJob {
        var file = DownloadJob(item: Samples.movie, source: Samples.source, now: date)
        file.rangeSupport = .supported
        file.totalBytes = 300_000_000
        file.chunkSize = 100_000_000
        return file
    }

    @Test func plansOneFileUnlessQueuingAhead() {
        var (first, second) = twoFiles()
        let alone = DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: false)
        #expect(alone.map(\.jobId) == [first.id, first.id, first.id])
        // The first file's last chunk under way: still nothing of the second.
        let tail = [TransferTag(jobId: first.id, range: 200_000_000..<300_000_000)]
        first.completed = ByteRanges([0..<200_000_000])
        #expect(DownloadJob.plan([first, second], running: tail, budget: 10, queuingAhead: false).isEmpty)
        // Off screen, the second file's chunks too.
        let ahead = DownloadJob.plan([first, second], running: tail, budget: 10, queuingAhead: true)
        #expect(ahead.map(\.jobId) == [second.id, second.id, second.id])
        #expect(DownloadJob.plan([first, second], running: tail, budget: 2, queuingAhead: true).count == 2)
    }

    /// In front, the next file that needs a probe gets it, so leaving the screen can queue all
    /// of its chunks at once; the one after waits.
    @Test func probesTheNextFileInFront() {
        let (first, _) = twoFiles()
        let start = first.createdAt
        let second = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 1)
        let third = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 2)
        let plan = DownloadJob.plan([first, second, third], running: [], budget: 10, queuingAhead: false)
        #expect(plan.filter { $0.jobId == first.id }.count == 3)
        #expect(plan.filter { $0.jobId != first.id } == [TransferTag(jobId: second.id, range: DownloadJob.probeRange)])
    }

    /// Off screen, a file waiting for its probe doesn't hold back files that can be planned.
    @Test func queuesAheadPastAFileWaitingForItsProbe() {
        let (first, _) = twoFiles()
        let start = first.createdAt
        let waiting = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 1)
        let ready = confirmed(at: start + 2)
        let last = DownloadJob(item: Samples.movie, source: Samples.source, now: start + 3)
        let probe = TransferTag(jobId: waiting.id, range: DownloadJob.probeRange)
        let plan = DownloadJob.plan([first, waiting, ready, last], running: [probe], budget: 100, queuingAhead: true)
        #expect(plan.contains { $0.jobId == ready.id })
        #expect(!plan.contains { $0.jobId == waiting.id || $0.jobId == last.id })
    }

    /// A probe that hangs fails at the request timeout; from then on it doesn't hold back the
    /// next file's probe, which tells whether the trouble is the file's own.
    @Test func aFailingFilesProbeDoesntHoldTheNextBack() {
        let start = Date(timeIntervalSince1970: 1000)
        var hung = DownloadJob(item: Samples.movie, source: Samples.source, now: start)
        let next = DownloadJob(item: Samples.episode, source: Samples.source, now: start + 1)
        let probe = TransferTag(jobId: hung.id, range: DownloadJob.probeRange)
        #expect(DownloadJob.plan([hung, next], running: [probe], budget: 10, queuingAhead: false, now: start).isEmpty)
        hung.recordFailure(.network("The request timed out."), receivedBytes: 0, attemptStart: start, now: start + 60)
        #expect(DownloadJob.plan([hung, next], running: [probe], budget: 10, queuingAhead: false, now: start + 61)
            == [TransferTag(jobId: next.id, range: DownloadJob.probeRange)])
    }

    /// A file that fails while another file's transfers come through yields: the files behind
    /// it go first, while it gets one transfer timed for its retry, until one comes through.
    @Test func letsTheNextFileGoAheadOfOneFailingAlone() {
        var (first, second) = twoFiles()
        let now = Date(timeIntervalSince1970: 1000)
        first.recordFailure(.server("HTTP 500"), receivedBytes: 0, attemptStart: now - 120, now: now - 120)
        #expect(first.isFailing && !first.yields)
        // While it fails, one transfer of the file behind it tests whether it fails alone.
        let testing = DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: false, now: now - 119)
        #expect(testing.filter { $0.jobId == first.id }.count == 3)
        #expect(testing.filter { $0.jobId == second.id } == [TransferTag(jobId: second.id, range: 0..<100_000_000)])
        // Not while the file in hand's own transfers are still on the wire.
        #expect(DownloadJob.plan([first, second], running: [], finishing: [first.id], budget: 10, queuingAhead: false, now: now - 119)
            .allSatisfy { $0.jobId == first.id })
        // The test came through, then the file failed again: the trouble is its own.
        second.recordSuccess(now: now - 60)
        first.recordFailure(.server("HTTP 500"), receivedBytes: 0, attemptStart: now - 30, otherArrival: second.cameThroughAt, now: now)
        #expect(first.yields)
        #expect(DownloadJob.fileInHand([first, second], held: []) == second.id)
        let plan = DownloadJob.plan([first, second], running: [], budget: 10, queuingAhead: false, now: now)
        #expect(plan.filter { $0.jobId == first.id } == [TransferTag(jobId: first.id, range: 0..<100_000_000)])
        #expect(plan.filter { $0.jobId == second.id }.compactMap(\.range) == second.nextRequests(running: [], limit: 8).compactMap(\.self))
        // Its transfer coming through puts it back in hand.
        first.recordSuccess(now: now + 300)
        #expect(!first.yields && DownloadJob.fileInHand([first, second], held: []) == first.id)
    }

    /// Everything failing together (the server down, the network gone) is no file's own
    /// trouble: nothing yields and nothing gives up, however long it lasts.
    @Test func nothingYieldsOrGivesUpWhileEverythingFails() {
        let start = Date(timeIntervalSince1970: 1000)
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        for attempt in 0..<(DownloadJob.maxServerFailures * 2) {
            let now = start + Double(attempt) * 300
            job.recordFailure(.server("HTTP 503"), receivedBytes: 0, attemptStart: now, otherArrival: start - 10, now: now)
            job.recordFailure(.network("offline"), receivedBytes: 0, attemptStart: now, unreachable: true, now: now + 1)
        }
        #expect(job.status == .active && !job.yields && job.isFailing)
    }

    @Test func requestsNothingUnlessActive() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.status = .paused
        #expect(job.nextRequests(running: [], limit: 3).isEmpty)
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

    /// A chunk the device had no room for, though it reported enough, halves the chunks from its
    /// size, so near full they shrink until one fits.
    @Test func halvesChunksFromOneThereWasNoRoomFor() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.chunkSize = DownloadJob.maximumChunkSize
        job.ranOutOfSpace(writing: 27_842_259)
        #expect(job.chunkSize == 27_842_259 / 2)
        job.ranOutOfSpace(writing: 40_000_000)
        #expect(job.chunkSize == 27_842_259 / 4)
        for _ in 0..<10 { job.ranOutOfSpace(writing: job.chunkSize) }
        #expect(job.chunkSize == DownloadJob.minimumChunkSize)
    }

    /// The server's error answers give up on a file only while it fails alone.
    @Test func givesUpAfterRepeatedServerErrorsOnlyWhileFailingAlone() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        let start = Date(timeIntervalSince1970: 1000)
        for attempt in 0..<DownloadJob.maxServerFailures {
            job.recordFailure(.server("HTTP 500"), receivedBytes: 0, attemptStart: start, now: start + Double(attempt))
        }
        #expect(job.status == .active)
        #expect(job.retryAt != nil)
        job.recordFailure(.server("HTTP 500"), receivedBytes: 0, attemptStart: start, otherArrival: start + 5, now: start + 100)
        #expect(job.status == .failed)
        #expect(job.lastError == "HTTP 500")
    }

    /// A transfer that can't keep its bytes when paused finishes if it's at least halfway and
    /// no more than a chunk is left; otherwise it's cut, or set aside with its bytes.
    @Test func finishesATransferWhenPausingWouldLoseMoreThanItFetches() {
        let chunk = DownloadJob.maximumChunkSize
        #expect(DownloadJob.finishesWhenPaused(received: 60, expected: 100, canResume: false))
        #expect(DownloadJob.finishesWhenPaused(received: 50, expected: 100, canResume: false))
        #expect(!DownloadJob.finishesWhenPaused(received: 40, expected: 100, canResume: false))
        #expect(!DownloadJob.finishesWhenPaused(received: 60, expected: 100, canResume: true))
        #expect(!DownloadJob.finishesWhenPaused(received: 0, expected: 100, canResume: false))
        #expect(!DownloadJob.finishesWhenPaused(received: 60, expected: nil, canResume: false))
        // A whole file a server sends without validators: most of it in, but more than a chunk left.
        #expect(!DownloadJob.finishesWhenPaused(received: 3 * chunk, expected: 4 * chunk + 1, canResume: false))
        #expect(DownloadJob.finishesWhenPaused(received: 3 * chunk, expected: 4 * chunk, canResume: false))
    }

    /// What the task says decides: a transfer the daemon hasn't got to, or one that's moving,
    /// whatever its progress reports lag, is never stalled.
    @Test func callsATransferStalledOnlyWhenItsUnderWayAndStill() {
        let start = Date(timeIntervalSince1970: 1000)
        let limit: TimeInterval = 45
        // Waiting its turn behind the session's four connections: no response, no bytes.
        var waiting = TransferActivity(bytes: 0, resumed: false, now: start)
        waiting.observe(bytes: 0, hasResponse: false, now: start + 600)
        #expect(!waiting.isStalled(state: .running, now: start + 600, limit: limit))
        // Under way: answered, then no more bytes for longer than the limit.
        var answered = TransferActivity(bytes: 0, resumed: false, now: start)
        answered.observe(bytes: 0, hasResponse: true, now: start + 10)
        #expect(!answered.isStalled(state: .running, now: start + 50, limit: limit))
        #expect(answered.isStalled(state: .running, now: start + 56, limit: limit))
        // Bytes the task counted, though no progress report came, keep it going.
        answered.observe(bytes: 4096, hasResponse: true, now: start + 56)
        #expect(!answered.isStalled(state: .running, now: start + 100, limit: limit))
        // Timed for later or set aside, it isn't the daemon's to stall.
        #expect(!answered.isStalled(state: .suspended, now: start + 500, limit: limit))
        #expect(!answered.isStalled(state: .completed, now: start + 500, limit: limit))
        // Started from resume data, the response it carries isn't the daemon at work; bytes are.
        var resumed = TransferActivity(bytes: 1 << 20, resumed: true, now: start)
        resumed.observe(bytes: 1 << 20, hasResponse: true, now: start + 600)
        #expect(!resumed.isUnderWay && !resumed.isStalled(state: .running, now: start + 600, limit: limit))
        resumed.observe(bytes: 2 << 20, hasResponse: true, now: start + 601)
        #expect(resumed.isUnderWay)
        // While the app couldn't look, the clock starts again when it can.
        resumed.restartClock(now: start + 2000)
        #expect(!resumed.isStalled(state: .running, now: start + 2040, limit: limit))
    }

    /// A stalled transfer's replacement carries on from its bytes, also one resumed after a
    /// pause that got going and stalled later; only one resuming never got going starts over.
    @Test func replacesAStalledTransferFromTheBytesItHas() {
        let start = Date(timeIntervalSince1970: 1000)
        var stalled = TransferActivity(bytes: 0, resumed: false, now: start)
        stalled.observe(bytes: 15 << 20, hasResponse: true, now: start + 10)
        #expect(stalled.carriesOnWhenReplaced)
        var resumedThenStalled = TransferActivity(bytes: 3 << 20, resumed: true, now: start)
        resumedThenStalled.observe(bytes: 18 << 20, hasResponse: true, now: start + 10)
        #expect(resumedThenStalled.carriesOnWhenReplaced)
        var resumedNeverGoing = TransferActivity(bytes: 3 << 20, resumed: true, now: start)
        resumedNeverGoing.observe(bytes: 3 << 20, hasResponse: true, now: start + 600)
        #expect(!resumedNeverGoing.carriesOnWhenReplaced)
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
