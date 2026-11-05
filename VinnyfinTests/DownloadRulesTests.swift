#if !os(tvOS)
import Foundation
import Testing
@testable import vinnyfin

private func job(_ item: JellyfinItem = Samples.movie, size: Int64? = 300_000_000, at offset: TimeInterval = 0) -> DownloadJob {
    var source = Samples.source
    source.size = size
    return DownloadJob(item: item, source: source, now: Date(timeIntervalSince1970: 1_000_000 + offset))
}

private let wifi = NetworkConditions(isReachable: true, isExpensive: false, isConstrained: false, usesCellular: false)
private let cellular = NetworkConditions(isReachable: true, isExpensive: true, isConstrained: false, usesCellular: true)
private let hotspot = NetworkConditions(isReachable: true, isExpensive: true, isConstrained: false, usesCellular: false)
private let lowData = NetworkConditions(isReachable: true, isExpensive: false, isConstrained: true, usesCellular: false)
private let offline = NetworkConditions(isReachable: false, isExpensive: false, isConstrained: false, usesCellular: false)

struct NetworkRuleTests {
    @Test func keepsDownloadsOffCellularAndHotspotsUnlessAllowed() {
        let rules = DownloadRules(downloadsOverCellular: false)
        let movie = job()
        #expect(rules.wait(for: movie, network: wifi, isOnPower: nil) == nil)
        #expect(rules.wait(for: movie, network: cellular, isOnPower: nil) == .wifi)
        #expect(rules.wait(for: movie, network: hotspot, isOnPower: nil) == .wifi)
        let access = rules.access(for: movie)
        #expect(!access.allowsCellular && !access.allowsExpensive && !access.allowsConstrained)
        #expect(!access.allows(cellular) && !access.allows(hotspot) && access.allows(wifi))

        let allowed = DownloadRules(downloadsOverCellular: true)
        #expect(allowed.wait(for: movie, network: cellular, isOnPower: nil) == nil)
        #expect(allowed.access(for: movie).allows(cellular))
    }

    @Test func alwaysHonorsLowDataMode() {
        let movie = job()
        #expect(DownloadRules(downloadsOverCellular: true).wait(for: movie, network: lowData, isOnPower: nil) == .lowDataMode)
        #expect(!DownloadRules(downloadsOverCellular: true).access(for: movie).allows(lowData))
        // On cellular in Low Data Mode, Wi-Fi is what lets it go.
        var both = cellular
        both.isConstrained = true
        #expect(DownloadRules(downloadsOverCellular: false).wait(for: movie, network: both, isOnPower: nil) == .wifi)
    }

    @Test func noNetworkIsntARule() {
        #expect(DownloadRules(downloadsOverCellular: false).wait(for: job(), network: offline, isOnPower: nil) == nil)
    }

    @Test func downloadNowLiftsTheNetworkRules() {
        var urgent = job()
        urgent.downloadNowAt = .now
        let rules = DownloadRules(downloadsOverCellular: false)
        #expect(rules.access(for: urgent) == .any)
        #expect(rules.wait(for: urgent, network: cellular, isOnPower: nil) == nil)
        #expect(rules.wait(for: urgent, network: lowData, isOnPower: nil) == nil)
    }

    @Test func readsTheAccessARequestWasMadeWith() {
        var request = URLRequest(url: URL(filePath: "/"))
        DownloadRules(downloadsOverCellular: false).access(for: job()).apply(to: &request)
        #expect(!request.allowsCellularAccess && !request.allowsExpensiveNetworkAccess && !request.allowsConstrainedNetworkAccess)
        #expect(NetworkAccess(request) == DownloadRules(downloadsOverCellular: false).access(for: job()))
        #expect(NetworkAccess(nil) == .any)
    }

    /// A transfer made Wi-Fi only, carried on from its resume data, stays Wi-Fi only; once the
    /// file may use cellular and the device is on it, it would wait for good.
    @Test func findsATransferStrandedByTheNetworksItWasMadeWith() {
        let wifiOnly = DownloadRules(downloadsOverCellular: false).access(for: job())
        let nowAllowed = DownloadRules(downloadsOverCellular: true).access(for: job())
        #expect(wifiOnly.isStranded(on: cellular, fileAccess: nowAllowed))
        #expect(!wifiOnly.isStranded(on: cellular, fileAccess: wifiOnly))
        #expect(!wifiOnly.isStranded(on: wifi, fileAccess: nowAllowed))
        #expect(!wifiOnly.isStranded(on: offline, fileAccess: nowAllowed))
        // Download Now lifts the rules for the file, not for its transfers made before.
        var urgent = job()
        urgent.downloadNowAt = .now
        #expect(wifiOnly.isStranded(on: lowData, fileAccess: DownloadRules(downloadsOverCellular: false).access(for: urgent)))
    }
}

struct PowerRuleTests {
    @Test func waitsForPowerOnlyWhenTheDeviceSaysItsUnplugged() {
        let rules = DownloadRules(onlyWhileCharging: true)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: false) == .power)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: true) == nil)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: nil) == nil)
    }

    @Test func powerFirstThenTheNetwork() {
        let rules = DownloadRules(downloadsOverCellular: false, onlyWhileCharging: true)
        #expect(rules.wait(for: job(), network: cellular, isOnPower: false) == .power)
        #expect(rules.wait(for: job(), network: cellular, isOnPower: true) == .wifi)
    }

    @Test func downloadNowLiftsOnlyWhileCharging() {
        var urgent = job()
        urgent.downloadNowAt = .now
        let rules = DownloadRules(downloadsOverCellular: false, onlyWhileCharging: true)
        #expect(rules.wait(for: urgent, network: cellular, isOnPower: false) == nil)
    }

    /// The catch-up launch waits for power for Only While Charging, and for nothing else, unless
    /// something can go now.
    @Test func booksTheCatchUpForPowerOnly() {
        let queued = [job(), job(at: 1)]
        #expect(DownloadRules(onlyWhileCharging: true).catchUpRequiresExternalPower(for: queued))
        var urgent = job(at: 2)
        urgent.downloadNowAt = .now
        #expect(!DownloadRules(onlyWhileCharging: true).catchUpRequiresExternalPower(for: queued + [urgent]))
        #expect(!DownloadRules().catchUpRequiresExternalPower(for: queued))
    }

    /// Overnight Only is gone: someone who had it on isn't held back by the clock, and nothing in
    /// the rules waits on the time of day.
    @Test @MainActor func aStoredOvernightOnlyHoldsNothingBack() throws {
        let suite = "net.vinnysaj.vinnyfin.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "settings.downloadOvernightOnly")
        defaults.set(true, forKey: "settings.downloadOnlyWhileCharging")
        let rules = DownloadRules(AppSettings(defaults: defaults))
        #expect(rules == DownloadRules(downloadsOverCellular: false, onlyWhileCharging: true))
        #expect(rules.wait(for: job(), network: wifi, isOnPower: true) == nil)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: false) == .power)
    }

    @Test @MainActor func saysPlainlyWhatItWaitsFor() {
        #expect(DownloadWait.wifi.status == "Waiting for Wi-Fi")
        #expect(DownloadWait.space(needed: 3_200_000_000).status == "Waiting for space: \(Int64(3_200_000_000).formatted(.byteCount(style: .file))) more needed")
        #expect(!DownloadWait.space(needed: 1).isRule)
        #expect(DownloadWait.power.isRule && DownloadWait.wifi.isNetwork && !DownloadWait.power.isNetwork)
        #expect(DownloadWait.wifi.next == "then waits for Wi-Fi")
        #expect(DownloadWait.lowDataMode.next == "then waits while Low Data Mode is on")
    }

    /// The system has no way to hold a transfer it has until the device is plugged in, so with
    /// Only While Charging, off screen only the file in hand goes to the system.
    @Test func handsTheSystemOnlyTheFileInHandWhileChargingIsARule() {
        let rules = DownloadRules(onlyWhileCharging: true)
        var urgent = job(at: 2)
        urgent.downloadNowAt = .now
        #expect(rules.waitsForPower(job()) && !rules.waitsForPower(urgent) && !DownloadRules().waitsForPower(job()))
        let files = (0..<3).map { offset in
            var file = job(at: TimeInterval(offset))
            file.rangeSupport = .supported
            file.totalBytes = 300_000_000
            return file
        }
        let bound = Set(files.filter(rules.waitsForPower).map(\.id))
        #expect(DownloadJob.sessionFiles(files, held: [], queuingAhead: true, onlyInHand: bound) == [files[0].id])
        #expect(DownloadJob.sessionFiles(files, held: [files[0].id], queuingAhead: true, onlyInHand: bound) == [files[1].id])
        let plan = DownloadJob.plan(files + [urgent], running: [], onlyInHand: bound, budget: 100, queuingAhead: true)
        #expect(Set(plan.map(\.jobId)) == [files[0].id, urgent.id])
    }
}

struct StorageBudgetTests {
    private func plan(_ queue: [DownloadJob], bytesSoFar: [UUID: Int64] = [:], used: Int64 = 0, available: Int64? = nil,
                      limit: Int64? = nil, deletable: [StorageBudget.Deletable] = []) -> StorageBudget.Outcome {
        StorageBudget.plan(queue: queue, bytesSoFar: bytesSoFar, used: used, available: available, limit: limit, deletable: deletable)
    }

    @Test func letsEverythingGoWithoutALimitOrAnAnswer() {
        #expect(plan([job(), job(at: 1)]) == StorageBudget.Outcome())
    }

    @Test func keepsRoomForEachDownloadInTurn() {
        let first = job(size: 3_000_000_000)
        let second = job(size: 4_000_000_000, at: 1)
        let third = job(size: 1_000_000_000, at: 2)
        // 45 of 50 GB used: the first fits; the second needs 2 GB more; the third still fits.
        let outcome = plan([first, second, third], used: 45_000_000_000, limit: 50_000_000_000)
        #expect(outcome.shortfalls == [second.id: 2_000_000_000])
        #expect(outcome.deletions.isEmpty)
    }

    @Test func countsWhatAPartialDownloadAlreadyHas() {
        var started = job(size: 10_000_000_000)
        started.completed = ByteRanges([0..<6_000_000_000])
        // Its 6 GB are in `used` already; the 4 GB left fit in 5 GB free.
        #expect(plan([started], used: 6_000_000_000, available: 5_000_000_000, limit: 20_000_000_000).shortfalls.isEmpty)
    }

    @Test func countsWhatAPausedDownloadHoldsInResumeData() {
        var paused = job(size: 10_000_000_000)
        paused.completed = ByteRanges([0..<2_000_000_000])
        // 2 GB in the partial file and 4 GB in the session's files: 4 GB to go, in 5 GB free.
        let bytesSoFar = [paused.id: 6_000_000_000 as Int64]
        #expect(plan([paused], bytesSoFar: bytesSoFar, used: 6_000_000_000, available: 5_000_000_000).shortfalls.isEmpty)
        #expect(plan([paused], used: 6_000_000_000, available: 5_000_000_000).shortfalls == [paused.id: 3_000_000_000 + writing])
    }

    /// Writing a chunk into the partial file holds its bytes twice for a moment.
    private let writing = DownloadJob.minimumChunkSize

    @Test func mindsTheDeviceAsWellAsTheLimit() {
        let movie = job(size: 8_000_000_000)
        #expect(plan([movie], available: 5_000_000_000).shortfalls == [movie.id: 3_000_000_000 + writing])
        #expect(plan([movie], used: 0, available: 5_000_000_000, limit: 100_000_000_000).shortfalls == [movie.id: 3_000_000_000 + writing])
    }

    /// A download in chunks fits on the device only with room to write the smallest chunk
    /// besides; one in a single transfer is written by the system where it lands.
    @Test func keepsRoomOnTheDeviceToWriteAChunk() {
        let movie = job(size: 1_000_000_000)
        #expect(plan([movie], available: 1_000_000_000).shortfalls == [movie.id: writing])
        #expect(plan([movie], available: 1_000_000_000 + writing).shortfalls.isEmpty)
        var whole = movie
        whole.rangeSupport = .unsupported
        #expect(plan([whole], available: 1_000_000_000).shortfalls.isEmpty)
        // Under the limit, the copy is on the device only.
        #expect(plan([movie], used: 0, limit: 1_000_000_000).shortfalls.isEmpty)
    }

    /// Near full, chunks are planned no bigger than the room the queue leaves on the device, so
    /// the moment a chunk is held twice doesn't overrun it.
    @Test func shrinksTheChunksToTheRoomLeft() {
        let movie = job(size: 1_000_000_000)
        #expect(plan([movie], available: 1_000_000_000 + (10 << 20)).chunkLimit == 10 << 20)
        #expect(plan([movie], available: 1_000_000_000 + writing).chunkLimit == writing)
        #expect(plan([movie], available: 10_000_000_000).chunkLimit == nil)
        #expect(plan([movie], limit: 1_000_000_000 + writing).chunkLimit == nil)
        // A download that doesn't fit keeps no room, so the one behind it sizes the chunks.
        let huge = job(size: 40_000_000_000, at: 1)
        #expect(plan([huge, movie], available: 1_000_000_000 + (20 << 20)).chunkLimit == 20 << 20)
    }

    @Test func tellsAFullDeviceFromOtherErrors() {
        #expect(StorageBudget.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        #expect(StorageBudget.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))))
        #expect(StorageBudget.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(StorageBudget.isOutOfSpace(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile,
                                                   userInfo: [NSUnderlyingErrorKey: underlying])))
        #expect(!StorageBudget.isOutOfSpace(URLError(.networkConnectionLost)))
        #expect(!StorageBudget.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
    }

    @Test func deletesTheOldestWatchedFirstAndOnlyAsManyAsNeeded() {
        let movie = job(size: 5_000_000_000)
        let oldest = StorageBudget.Deletable(id: UUID(), bytes: 2_000_000_000)
        let older = StorageBudget.Deletable(id: UUID(), bytes: 2_000_000_000)
        let newest = StorageBudget.Deletable(id: UUID(), bytes: 2_000_000_000)
        let outcome = plan([movie], used: 48_000_000_000, limit: 50_000_000_000, deletable: [oldest, older, newest])
        #expect(outcome.deletions == [oldest.id, older.id])
        #expect(outcome.shortfalls.isEmpty)
    }

    @Test func deletesNothingWhenThatWouldntMakeEnoughRoom() {
        let huge = job(size: 40_000_000_000)
        let small = job(size: 1_000_000_000, at: 1)
        let watched = StorageBudget.Deletable(id: UUID(), bytes: 2_000_000_000)
        let outcome = plan([huge, small], available: 10_000_000_000, deletable: [watched])
        #expect(outcome.shortfalls == [huge.id: 30_000_000_000 + writing])
        #expect(outcome.deletions.isEmpty)
    }

    @Test func doesntHoldBackADownloadOfUnknownSize() {
        #expect(plan([job(size: nil)], available: 0, limit: 0).shortfalls.isEmpty)
    }
}

struct WatchStateTests {
    /// When the download was queued, which watching counts from.
    private let downloadedAt = Date(timeIntervalSince1970: 2_000_000)

    private func finished(played: Bool? = nil, positionTicks: Int64? = nil, lastPlayed: Date? = nil) -> DownloadJob {
        var item = Samples.episode
        if played != nil || lastPlayed != nil || positionTicks != nil {
            var data = UserItemData()
            data.played = played
            data.playbackPositionTicks = positionTicks
            data.lastPlayedDate = lastPlayed?.formatted(.iso8601)
            item.userData = data
        }
        var job = DownloadJob(item: item, source: Samples.source, now: downloadedAt)
        job.status = .completed
        job.completedAt = downloadedAt + 86_400
        return job
    }

    private func entry(played: Bool, position: Double = 0, at date: Date) -> WatchHistory.Entry {
        WatchHistory.Entry(position: position, duration: 1000, played: played, updatedAt: date, needsSync: false)
    }

    @Test func watchedHereSinceTheDownload() {
        let later = downloadedAt + 3600
        #expect(finished().watchState(local: entry(played: true, at: later)) == .watched(at: later))
    }

    @Test func watchedElsewhereSinceTheDownload() {
        let later = downloadedAt + 7200
        #expect(finished(played: true, positionTicks: 0, lastPlayed: later).watchState(local: nil) == .watched(at: later))
    }

    @Test func keepsOneDownloadedToWatchAgain() {
        // Watched before it was downloaded, not since.
        #expect(finished(played: true, lastPlayed: downloadedAt - 3600).watchState(local: nil) == .unwatched)
        #expect(finished().watchState(local: entry(played: true, at: downloadedAt - 60)) == .unwatched)
    }

    @Test func keepsOnePartlyWatched() {
        #expect(finished().watchState(local: entry(played: false, position: 300, at: downloadedAt + 60)) == .inProgress)
        // A rewatch partway through on the TV, after this device finished it: the latest decides.
        let rewatch = finished(played: true, positionTicks: 3_000_000_000, lastPlayed: downloadedAt + 7200)
        #expect(rewatch.watchState(local: entry(played: true, at: downloadedAt + 3600)) == .inProgress)
    }

    /// Watching while it downloads counts: once it finishes, it's a download already watched,
    /// not one kept to watch again.
    @Test func watchedWhileItDownloadedCounts() {
        var unfinished = finished()
        unfinished.status = .active
        unfinished.completedAt = nil
        #expect(unfinished.watchState(local: entry(played: true, at: downloadedAt + 60)) == .watched(at: downloadedAt + 60))
        var done = unfinished
        done.status = .completed
        done.completedAt = downloadedAt + 86_400
        #expect(done.watchState(local: entry(played: true, at: downloadedAt + 60)) == .watched(at: downloadedAt + 60))
    }

    /// Smart downloads drop a show's queued episodes watched since they were queued, and keep
    /// the rest: finished downloads, other shows', films, and episodes watched before.
    @Test func findsTheQueuedEpisodesWatchedSinceTheyWereQueued() {
        func episode(_ id: String, of show: String, lastPlayed: Date? = nil, status: DownloadJob.Status = .active) -> DownloadJob {
            let played = lastPlayed.map { #","UserData":{"Played":true,"LastPlayedDate":"\#($0.formatted(.iso8601))"}"# } ?? ""
            let item = Samples.item(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeriesId":"\#(show)","SeriesName":"\#(show)"\#(played)}"#)
            var job = DownloadJob(item: item, source: Samples.source, now: downloadedAt)
            job.status = status
            return job
        }
        let watchedHere = episode("here", of: "show")
        let watchedThere = episode("there", of: "show", lastPlayed: downloadedAt + 120)
        let watchedBefore = episode("before", of: "show", lastPlayed: downloadedAt - 60)
        let unwatched = episode("unwatched", of: "show")
        let done = episode("done", of: "show", status: .completed)
        let otherShow = episode("other", of: "another")
        let film = DownloadJob(item: Samples.movie, source: Samples.source, now: downloadedAt)
        let local: (String) -> WatchHistory.Entry? = { id in
            ["here", "done", "other", "m1"].contains(id) ? self.entry(played: true, at: downloadedAt + 60) : nil
        }
        let jobs = [watchedHere, watchedThere, watchedBefore, unwatched, done, otherShow, film]
        #expect(DownloadJob.watchedWhileQueued(jobs, ofShows: ["show"], local: local).map(\.id) == [watchedHere.id, watchedThere.id])
    }
}

/// Reordering, Download Next and the rules as the planner sees them.
struct QueueControlTests {
    /// Three 300 MB files in 100 MB chunks, each shown by the server to take ranges.
    private func threeFiles() -> [DownloadJob] {
        (0..<3).map { offset in
            var file = job(at: TimeInterval(offset))
            file.chunkSize = 100_000_000
            file.rangeSupport = .supported
            file.totalBytes = 300_000_000
            return file
        }
    }

    @Test func plansTheFirstInTheListWhateverItsAge() {
        let files = threeFiles()
        let reordered = [files[2], files[0], files[1]]
        #expect(DownloadJob.plan(reordered, running: [], budget: 10, queuingAhead: false).allSatisfy { $0.jobId == files[2].id })
    }

    /// The file moved ahead waits for the overtaken one's transfers on the wire to finish, so
    /// they share no connection; probes of later files still go, and off screen nothing waits.
    @Test func aFileMovedAheadWaitsForTheTransfersOnTheWire() {
        let files = threeFiles()
        let reordered = [files[1], files[0], files[2]]
        let finishing = [TransferTag(jobId: files[0].id, range: 0..<100_000_000)]
        let plan = DownloadJob.plan(reordered, running: finishing, finishing: [files[0].id], budget: 10, queuingAhead: false)
        #expect(plan.isEmpty)
        let unprobed = job(at: 3)
        let probing = DownloadJob.plan(reordered + [unprobed], running: finishing, finishing: [files[0].id], budget: 10, queuingAhead: false)
        #expect(probing == [TransferTag(jobId: unprobed.id, range: DownloadJob.probeRange)])
        let afterwards = DownloadJob.plan(reordered, running: [], finishing: [], budget: 10, queuingAhead: false)
        #expect(afterwards.allSatisfy { $0.jobId == files[1].id } && !afterwards.isEmpty)
        let ahead = DownloadJob.plan(reordered, running: finishing, finishing: [files[0].id], budget: 10, queuingAhead: true)
        #expect(ahead.contains { $0.jobId == files[1].id })
        // Its own transfers on the wire don't hold the file in hand back.
        let own = DownloadJob.plan(files, running: finishing, finishing: [files[0].id], budget: 10, queuingAhead: false)
        #expect(own.filter { $0.jobId == files[0].id }.count == 2)
    }

    @Test func skipsWhatTheScheduleOrRoomHolds() {
        let files = threeFiles()
        let plan = DownloadJob.plan(files, running: [], held: [files[0].id], budget: 10, queuingAhead: false)
        #expect(!plan.isEmpty && plan.allSatisfy { $0.jobId == files[1].id })
        let ahead = DownloadJob.plan(files, running: [], held: [files[0].id], budget: 10, queuingAhead: true)
        #expect(!ahead.contains { $0.jobId == files[0].id })
    }

    /// In front a file waiting for a network it may use isn't planned; off screen its chunks go
    /// in for the system to start on one, but never a probe, which isn't the session's.
    @Test func handsTheSystemWhatWaitsForANetworkOnlyOffScreen() {
        let files = threeFiles()
        let inFront = DownloadJob.plan(files, running: [], waitingForNetwork: [files[0].id], budget: 10, queuingAhead: false)
        #expect(!inFront.contains { $0.jobId == files[0].id })
        let ahead = DownloadJob.plan(files, running: [], waitingForNetwork: Set(files.map(\.id)), budget: 10, queuingAhead: true)
        #expect(ahead.filter { $0.jobId == files[0].id }.count == 3)
        var unsized = job(size: nil, at: 5)
        unsized.chunkSize = 100_000_000
        let probe = DownloadJob.plan([unsized], running: [], waitingForNetwork: [unsized.id], budget: 10, queuingAhead: true)
        #expect(probe.isEmpty)
    }

    @Test func keepsTheFileInHandAndAnyYieldingAheadInTheSession() {
        var files = threeFiles()
        let now = Date(timeIntervalSince1970: 5_000_000)
        files[0].failingSince = now - 100
        files[0].failedAloneAt = now - 10
        files[0].retryAt = now + 60
        #expect(DownloadJob.sessionFiles(files, held: [], queuingAhead: false, now: now) == [files[0].id, files[1].id])
        #expect(DownloadJob.sessionFiles(files, held: [files[1].id], queuingAhead: false, now: now) == [files[0].id, files[2].id])
        #expect(DownloadJob.sessionFiles(files, held: [files[2].id], queuingAhead: true, now: now) == [files[0].id, files[1].id])
    }

    /// While the file in hand fails, the first file behind it that isn't waiting out a retry of
    /// its own goes into the session too, for one transfer that tells whether it fails alone.
    @Test func testsTheFileBehindAFailingFileInHand() {
        var files = threeFiles()
        let now = Date(timeIntervalSince1970: 5_000_000)
        #expect(DownloadJob.sessionFiles(files, held: [], queuingAhead: false, now: now) == [files[0].id])
        files[0].failingSince = now - 100
        files[0].retryAt = now + 60
        #expect(DownloadJob.sessionFiles(files, held: [], queuingAhead: false, now: now) == [files[0].id, files[1].id])
        files[1].failingSince = now - 50
        files[1].retryAt = now + 30
        #expect(DownloadJob.sessionFiles(files, held: [], queuingAhead: false, now: now) == [files[0].id, files[2].id])
    }

    @Test func tagsOverlapWithinAFileOnly() {
        let id = UUID()
        #expect(TransferTag(jobId: id, range: 0..<10).overlaps(TransferTag(jobId: id, range: 5..<15)))
        #expect(!TransferTag(jobId: id, range: 0..<10).overlaps(TransferTag(jobId: id, range: 10..<15)))
        #expect(TransferTag(jobId: id, range: nil).overlaps(TransferTag(jobId: id, range: 10..<15)))
        #expect(!TransferTag(jobId: id, range: 0..<10).overlaps(TransferTag(jobId: UUID(), range: 0..<10)))
    }

    @Test func resumingClearsTheRetryButKeepsTheBytes() {
        var paused = job()
        paused.status = .failed
        paused.serverFailures = 5
        paused.retryAt = .now + 60
        paused.serverUnreachableSince = .now
        paused.completed = ByteRanges([0..<100])
        paused.resume()
        #expect(paused.status == .active && paused.serverFailures == 0 && paused.retryAt == nil && paused.serverUnreachableSince == nil)
        #expect(paused.completed.byteCount == 100)
    }

    @Test func timesHowLongTheServerHasBeenOutOfReach() {
        var file = job()
        let start = Date(timeIntervalSince1970: 5_000_000)
        file.recordFailure(.network("Couldn't reach the server."), receivedBytes: 0, attemptStart: start, unreachable: true, now: start)
        file.recordFailure(.network("Couldn't reach the server."), receivedBytes: 0, attemptStart: start, unreachable: true, now: start + 60)
        #expect(file.serverUnreachableSince == start)
        file.recordFailure(.server("HTTP 503"), receivedBytes: 0, attemptStart: start, now: start + 120)
        #expect(file.serverUnreachableSince == nil)
        file.recordFailure(.network("Couldn't reach the server."), receivedBytes: 0, attemptStart: start, unreachable: true, now: start + 180)
        file.recordSuccess()
        #expect(file.serverUnreachableSince == nil)
    }
}

/// What a download's row says it's doing.
@MainActor
struct JobStatusTests {
    private let now = Date(timeIntervalSince1970: 5_000_000)

    /// `speed`, when given, from transfers under way unless `transferring` says otherwise.
    private func status(_ job: DownloadJob, speed: Double? = nil, transferring: Bool? = nil, waits: [UUID: DownloadWait] = [:],
                        held: Bool = false, reachable: Bool = true, inHand: UUID? = nil, waitsOn: [DownloadJob] = []) -> JobStatus {
        JobStatus.of(job, bytesPerSecond: speed, isTransferring: transferring ?? (speed != nil), waits: waits,
                     isPausedForPlayback: held, isNetworkReachable: reachable, fileInHand: inHand, waitsOn: waitsOn, now: now)
    }

    /// Bytes arriving come first, with what the download waits for once they're in.
    @Test func saysBytesArriveWhileTheyDo() {
        let file = job()
        #expect(status(file, speed: 2_000_000, inHand: file.id) == .arriving(bytesPerSecond: 2_000_000, next: nil))
        // Transfers under way finishing a file that's no longer in hand.
        #expect(status(file, speed: 2_000_000, inHand: UUID()) == .arriving(bytesPerSecond: 2_000_000, next: "then queued"))
        #expect(status(file, speed: 2_000_000, waits: [file.id: .wifi], inHand: UUID())
            == .arriving(bytesPerSecond: 2_000_000, next: "then waits for Wi-Fi"))
        // A trickle under a kilobyte a second isn't worth saying.
        #expect(status(file, speed: 10, inHand: UUID()) == .queued)
        var paused = file
        paused.status = .paused
        #expect(status(paused, speed: 2_000_000) == .pausing(bytesPerSecond: 2_000_000))
        #expect(status(paused) == .paused)
        // The smoothed speed lingers a moment after the last transfer stops: that's no longer bytes arriving.
        #expect(status(paused, speed: 500_000, transferring: false) == .paused)
        #expect(status(file, speed: 500_000, transferring: false, waits: [file.id: .wifi], inHand: UUID()) == .waiting(.wifi))
    }

    @Test func saysWhatADownloadWaitsFor() {
        let file = job()
        #expect(status(file, waits: [file.id: .power], inHand: file.id) == .waiting(.power))
        #expect(status(file, reachable: false, inHand: file.id) == .offline)
        #expect(status(file, held: true, inHand: file.id) == .heldForPlayback)
        #expect(status(file, inHand: UUID()) == .queued)
        #expect(status(file, inHand: file.id) == .waitingForServer)
        let overtaken = job(Samples.episode, at: 1)
        #expect(status(file, inHand: file.id, waitsOn: [overtaken]) == .startingAfter(overtaken.shortName))
    }

    /// A file failing alone says so, and that the downloads after it go first meanwhile.
    @Test func saysAFileYieldsWhileItFailsAlone() {
        var file = job()
        file.recordFailure(.server("HTTP 500"), receivedBytes: 0, attemptStart: now - 100, now: now - 100)
        file.recordFailure(.server("HTTP 500"), receivedBytes: 0, attemptStart: now - 50, otherArrival: now - 60, now: now - 1)
        let retryAt = file.retryAt
        #expect(status(file, inHand: UUID()) == .retrying(at: retryAt, error: "HTTP 500", othersGoFirst: true))
        // Its retry due, it still yields until a transfer comes through.
        file.retryAt = now - 1
        #expect(status(file, inHand: UUID()) == .retrying(at: nil, error: "HTTP 500", othersGoFirst: true))
        // Failing with everything else, it keeps its place.
        var inOutage = job(at: 1)
        inOutage.recordFailure(.network("offline"), receivedBytes: 0, attemptStart: now, now: now)
        #expect(status(inOutage, inHand: inOutage.id) == .retrying(at: inOutage.retryAt, error: "offline", othersGoFirst: false))
    }
}

struct DownloadNotificationTests {
    private func episode(_ number: Int, series: String = "Port Ellery", seriesId: String = "series-1") -> DownloadJob {
        let item = Samples.item("""
        {"Id":"ep\(number)-\(seriesId)","Name":"Episode \(number)","Type":"Episode","SeriesName":"\(series)","SeriesId":"\(seriesId)","ParentIndexNumber":1,"IndexNumber":\(number)}
        """)
        return DownloadJob(item: item, source: Samples.source)
    }

    @Test func groupsAShowsEpisodesThatFinishTogether() {
        let notices = ReadyNotice.notices(for: [episode(1), episode(2), episode(3), job()], delivered: [:])
        #expect(notices.count == 2)
        #expect(notices[0].body == "3 episodes of Port Ellery are ready to watch offline.")
        #expect(notices[0].link == AppLink(.open, JellyfinItem(id: "series-1", name: "Port Ellery", type: "Series")).url)
        #expect(notices[1].body == "Big Test Movie (2024) is ready to watch offline.")
        #expect(notices[1].link == AppLink(.open, Samples.movie).url)
        #expect(!notices[0].isUpdate)
    }

    @Test func namesASingleEpisodeAndOpensIt() {
        let notice = ReadyNotice.notices(for: [episode(3)], delivered: [:])[0]
        #expect(notice.body == "Port Ellery S01E03 is ready to watch offline.")
        #expect(AppLink(notice.link)?.itemId == "ep3-series-1")
    }

    /// A show's notification still showing counts on, and updates quietly.
    @Test func countsOnFromTheNotificationStillShowing() {
        let first = ReadyNotice.notices(for: [episode(1), episode(2)], delivered: [:])[0]
        let next = ReadyNotice.notices(for: [episode(3)], delivered: [first.identifier: first.itemIds])[0]
        #expect(next.identifier == first.identifier)
        #expect(next.body == "3 episodes of Port Ellery are ready to watch offline.")
        #expect(next.isUpdate)
        // Downloading one again doesn't count it twice.
        #expect(ReadyNotice.notices(for: [episode(3)], delivered: [next.identifier: next.itemIds])[0].itemIds.count == 3)
    }

    @Test func keepsShowsApart() {
        let notices = ReadyNotice.notices(for: [episode(1), episode(1, series: "Harbor Lights", seriesId: "series-2")], delivered: [:])
        #expect(notices.map(\.identifier).count == 2)
        #expect(Set(notices.map(\.identifier)).count == 2)
    }

    @Test func findsWhatNeedsAttention() {
        var failed = job()
        failed.status = .failed
        let short = job(at: 1)
        var unreachable = job(at: 2)
        let now = Date(timeIntervalSince1970: 9_000_000)
        unreachable.serverUnreachableSince = now - DownloadAttention.unreachableLimit - 1
        let jobs = [failed, short, unreachable]
        let waits: [UUID: DownloadWait] = [short.id: .space(needed: 1_000)]
        #expect(DownloadAttention.current(jobs: jobs, waits: waits, isNetworkReachable: true, now: now)
            == [.failed(failed.id), .space(short.id), .unreachable])
        // Offline, waiting says nothing about the server.
        #expect(!DownloadAttention.current(jobs: jobs, waits: waits, isNetworkReachable: false, now: now).contains(.unreachable))
        // Not yet an hour.
        unreachable.serverUnreachableSince = now - 60
        #expect(!DownloadAttention.current(jobs: [unreachable], waits: [:], isNetworkReachable: true, now: now).contains(.unreachable))
        for attention in [DownloadAttention.failed(failed.id), .space(short.id), .unreachable] {
            #expect(DownloadAttention(key: attention.key) == attention)
        }
        #expect(DownloadAttention(key: "nonsense") == nil)
    }

    @Test func saysWhatNeedsDoing() {
        var failed = job()
        failed.status = .failed
        failed.lastError = "The server refused the download (HTTP 403)."
        let one = AttentionNotice([.failed(failed.id)], jobs: [failed], waits: [:], serverName: "Home", hasStorageLimit: false)
        #expect(one.title == "Download Failed")
        #expect(one.body == "Big Test Movie (2024) couldn't download: The server refused the download (HTTP 403).")
        #expect(one.link == AppLink(.open, Samples.movie).url)

        let short = job(at: 1)
        let space = AttentionNotice([.space(short.id)], jobs: [short], waits: [short.id: .space(needed: 3_200_000_000)], serverName: nil,
                                    hasStorageLimit: false)
        #expect(space.title == "Not Enough Space for Downloads")
        #expect(space.body.hasPrefix("Big Test Movie (2024) needs \(Int64(3_200_000_000).formatted(.byteCount(style: .file))) more space."))
        #expect(!space.body.contains("storage limit"))
        let underLimit = AttentionNotice([.space(short.id)], jobs: [short], waits: [short.id: .space(needed: 3_200_000_000)], serverName: nil,
                                         hasStorageLimit: true)
        #expect(underLimit.body.hasSuffix("raise the storage limit in vinnyfin's settings."))

        let away = AttentionNotice([.unreachable], jobs: [], waits: [:], serverName: "Home", hasStorageLimit: false)
        #expect(away.title == "Can't Reach Home")
        #expect(away.link == nil)

        let mixed = AttentionNotice([.failed(failed.id), .unreachable], jobs: [failed], waits: [:], serverName: "Home", hasStorageLimit: false)
        #expect(mixed.title == "Downloads Need Attention")
        #expect(mixed.link == AppLink(.open, Samples.movie).url)
    }
}
#endif
