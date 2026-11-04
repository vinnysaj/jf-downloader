#if !os(tvOS)
import Foundation
import Testing
@testable import vinnyfin

/// A calendar that doesn't move with the machine running the tests.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()

private func date(hour: Int, minute: Int = 0, day: Int = 4) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
}

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
        #expect(rules.wait(for: movie, network: wifi, isOnPower: nil, now: .now) == nil)
        #expect(rules.wait(for: movie, network: cellular, isOnPower: nil, now: .now) == .wifi)
        #expect(rules.wait(for: movie, network: hotspot, isOnPower: nil, now: .now) == .wifi)
        let access = rules.access(for: movie)
        #expect(!access.allowsCellular && !access.allowsExpensive && !access.allowsConstrained)
        #expect(!access.allows(cellular) && !access.allows(hotspot) && access.allows(wifi))

        let allowed = DownloadRules(downloadsOverCellular: true)
        #expect(allowed.wait(for: movie, network: cellular, isOnPower: nil, now: .now) == nil)
        #expect(allowed.access(for: movie).allows(cellular))
    }

    @Test func alwaysHonorsLowDataMode() {
        let movie = job()
        #expect(DownloadRules(downloadsOverCellular: true).wait(for: movie, network: lowData, isOnPower: nil, now: .now) == .lowDataMode)
        #expect(!DownloadRules(downloadsOverCellular: true).access(for: movie).allows(lowData))
        // On cellular in Low Data Mode, Wi-Fi is what lets it go.
        var both = cellular
        both.isConstrained = true
        #expect(DownloadRules(downloadsOverCellular: false).wait(for: movie, network: both, isOnPower: nil, now: .now) == .wifi)
    }

    @Test func noNetworkIsntARule() {
        #expect(DownloadRules(downloadsOverCellular: false).wait(for: job(), network: offline, isOnPower: nil, now: .now) == nil)
    }

    @Test func downloadNowLiftsTheNetworkRules() {
        var urgent = job()
        urgent.downloadNowAt = .now
        let rules = DownloadRules(downloadsOverCellular: false)
        #expect(rules.access(for: urgent) == .any)
        #expect(rules.wait(for: urgent, network: cellular, isOnPower: nil, now: .now) == nil)
        #expect(rules.wait(for: urgent, network: lowData, isOnPower: nil, now: .now) == nil)
    }

    @Test func readsTheAccessARequestWasMadeWith() {
        var request = URLRequest(url: URL(filePath: "/"))
        DownloadRules(downloadsOverCellular: false).access(for: job()).apply(to: &request)
        #expect(!request.allowsCellularAccess && !request.allowsExpensiveNetworkAccess && !request.allowsConstrainedNetworkAccess)
        #expect(NetworkAccess(request) == DownloadRules(downloadsOverCellular: false).access(for: job()))
        #expect(NetworkAccess(nil) == .any)
    }
}

struct ScheduleRuleTests {
    @Test func waitsForPowerOnlyWhenTheDeviceSaysItsUnplugged() {
        let rules = DownloadRules(onlyWhileCharging: true)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: false, now: .now) == .power)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: true, now: .now) == nil)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: nil, now: .now) == nil)
    }

    @Test func waitsForTheOvernightWindow() {
        let rules = DownloadRules(overnightOnly: true)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: nil, now: date(hour: 3), calendar: utc) == nil)
        #expect(rules.wait(for: job(), network: wifi, isOnPower: nil, now: date(hour: 0, minute: 59), calendar: utc)
            == .overnight(opens: date(hour: 1)))
        #expect(rules.wait(for: job(), network: wifi, isOnPower: nil, now: date(hour: 7), calendar: utc)
            == .overnight(opens: date(hour: 1, day: 5)))
        #expect(rules.wait(for: job(), network: wifi, isOnPower: nil, now: date(hour: 22), calendar: utc)
            == .overnight(opens: date(hour: 1, day: 5)))
    }

    @Test func looksAgainWhenTheWindowOpensAndCloses() {
        let rules = DownloadRules(overnightOnly: true)
        #expect(rules.nextScheduleChange(after: date(hour: 22), calendar: utc) == date(hour: 1, day: 5))
        #expect(rules.nextScheduleChange(after: date(hour: 2), calendar: utc) == date(hour: 7))
        #expect(DownloadRules().nextScheduleChange(after: date(hour: 2), calendar: utc) == nil)
    }

    @Test func schedulesFirstThenTheNetwork() {
        let rules = DownloadRules(downloadsOverCellular: false, onlyWhileCharging: true)
        #expect(rules.wait(for: job(), network: cellular, isOnPower: false, now: .now) == .power)
        #expect(rules.wait(for: job(), network: cellular, isOnPower: true, now: .now) == .wifi)
    }

    @Test func downloadNowLiftsTheSchedule() {
        var urgent = job()
        urgent.downloadNowAt = .now
        let rules = DownloadRules(onlyWhileCharging: true, overnightOnly: true)
        #expect(rules.wait(for: urgent, network: wifi, isOnPower: false, now: date(hour: 12), calendar: utc) == nil)
    }

    /// The catch-up launch waits for what the schedule needs, unless something can go now.
    @Test func booksTheCatchUpForWhenTheRulesAllow() {
        let rules = DownloadRules(onlyWhileCharging: true, overnightOnly: true)
        let queued = [job(), job(at: 1)]
        let daytime = rules.catchUp(for: queued, now: date(hour: 15), calendar: utc)
        #expect(daytime.requiresExternalPower)
        #expect(daytime.earliestBeginDate == date(hour: 1, day: 5))
        let night = rules.catchUp(for: queued, now: date(hour: 2), calendar: utc)
        #expect(night.requiresExternalPower && night.earliestBeginDate == nil)
        var urgent = job(at: 2)
        urgent.downloadNowAt = .now
        let anyway = rules.catchUp(for: queued + [urgent], now: date(hour: 15), calendar: utc)
        #expect(!anyway.requiresExternalPower && anyway.earliestBeginDate == nil)
        let plain = DownloadRules().catchUp(for: queued, now: date(hour: 15), calendar: utc)
        #expect(!plain.requiresExternalPower && plain.earliestBeginDate == nil)
    }

    @Test @MainActor func saysPlainlyWhatItWaitsFor() {
        #expect(DownloadWait.wifi.status == "Waiting for Wi-Fi")
        #expect(DownloadWait.space(needed: 3_200_000_000).status == "Waiting for space: \(Int64(3_200_000_000).formatted(.byteCount(style: .file))) more needed")
        #expect(!DownloadWait.space(needed: 1).isRule)
        #expect(DownloadWait.power.isRule && DownloadWait.wifi.isNetwork && !DownloadWait.power.isNetwork)
    }
}

struct StorageBudgetTests {
    private func plan(_ queue: [DownloadJob], used: Int64 = 0, available: Int64? = nil, limit: Int64? = nil,
                      deletable: [StorageBudget.Deletable] = []) -> StorageBudget.Outcome {
        StorageBudget.plan(queue: queue, used: used, available: available, limit: limit, deletable: deletable)
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

    @Test func mindsTheDeviceAsWellAsTheLimit() {
        let movie = job(size: 8_000_000_000)
        #expect(plan([movie], available: 5_000_000_000).shortfalls == [movie.id: 3_000_000_000])
        #expect(plan([movie], used: 0, available: 5_000_000_000, limit: 100_000_000_000).shortfalls == [movie.id: 3_000_000_000])
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
        #expect(outcome.shortfalls == [huge.id: 30_000_000_000])
        #expect(outcome.deletions.isEmpty)
    }

    @Test func doesntHoldBackADownloadOfUnknownSize() {
        #expect(plan([job(size: nil)], available: 0, limit: 0).shortfalls.isEmpty)
    }
}

struct WatchStateTests {
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
        var job = DownloadJob(item: item, source: Samples.source)
        job.status = .completed
        job.completedAt = downloadedAt
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

    @Test func onlyFinishedDownloadsCount() {
        var unfinished = finished()
        unfinished.status = .active
        #expect(unfinished.watchState(local: entry(played: true, at: downloadedAt + 60)) == .unwatched)
    }
}

/// Reordering, Download Next and the rules as the planner sees them.
struct QueueControlTests {
    /// Three 300 MB files in 100 MB chunks, on a server that has shown it takes ranges.
    private func threeFiles() -> [DownloadJob] {
        (0..<3).map { offset in
            var file = job(at: TimeInterval(offset))
            file.chunkSize = 100_000_000
            if offset == 0 {
                file.rangeSupport = .supported
                file.totalBytes = 300_000_000
            }
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
        #expect(!plan.contains { $0.jobId == files[1].id })
        #expect(plan.allSatisfy { $0.range == DownloadJob.probeRange })
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

    @Test func keepsTheFileInHandAndAnyBackingOffAheadInTheSession() {
        var files = threeFiles()
        let now = Date.now
        files[0].serverFailures = DownloadJob.serverFailuresBeforeYielding
        files[0].retryAt = now + 60
        #expect(DownloadJob.sessionFiles(files, held: [], queuingAhead: false, now: now) == [files[0].id, files[1].id])
        #expect(DownloadJob.sessionFiles(files, held: [files[1].id], queuingAhead: false, now: now) == [files[0].id, files[2].id])
        #expect(DownloadJob.sessionFiles(files, held: [files[2].id], queuingAhead: true, now: now) == [files[0].id, files[1].id])
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
        let one = AttentionNotice([.failed(failed.id)], jobs: [failed], waits: [:], serverName: "Home")
        #expect(one.title == "Download Failed")
        #expect(one.body == "Big Test Movie (2024) couldn't download: The server refused the download (HTTP 403).")
        #expect(one.link == AppLink(.open, Samples.movie).url)

        let short = job(at: 1)
        let space = AttentionNotice([.space(short.id)], jobs: [short], waits: [short.id: .space(needed: 3_200_000_000)], serverName: nil)
        #expect(space.title == "Not Enough Space for Downloads")
        #expect(space.body.hasPrefix("Big Test Movie (2024) needs \(Int64(3_200_000_000).formatted(.byteCount(style: .file))) more space."))

        let away = AttentionNotice([.unreachable], jobs: [], waits: [:], serverName: "Home")
        #expect(away.title == "Can't Reach Home")
        #expect(away.link == nil)

        let mixed = AttentionNotice([.failed(failed.id), .unreachable], jobs: [failed], waits: [:], serverName: "Home")
        #expect(mixed.title == "Downloads Need Attention")
        #expect(mixed.link == AppLink(.open, Samples.movie).url)
    }
}
#endif
