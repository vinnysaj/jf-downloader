import AetherEngine
import CoreGraphics
import Foundation
import Testing
@testable import vinnyfin

/// An episode as the server lists it with everything a download keeps beside the file.
private enum Extras {
    static let item = Samples.item("""
    {"Id":"e1","Name":"Pilot","Type":"Episode","SeriesId":"show","SeriesName":"Test Show","SeriesPrimaryImageTag":"sp",
     "ParentIndexNumber":1,"IndexNumber":1,"ImageTags":{"Primary":"p","Logo":"l"},"BackdropImageTags":[],
     "ParentBackdropItemId":"show","ParentBackdropImageTags":["b"],
     "Trickplay":{"e1":{
       "240":{"Width":240,"Height":135,"TileWidth":10,"TileHeight":10,"ThumbnailCount":150,"Interval":10000},
       "320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":150,"Interval":10000},
       "640":{"Width":640,"Height":360,"TileWidth":10,"TileHeight":10,"ThumbnailCount":150,"Interval":10000}}},
     "Chapters":[{"StartPositionTicks":0,"Name":"Opening","ImageTag":"c0"},
                 {"StartPositionTicks":6000000000,"Name":" "},
                 {"StartPositionTicks":12000000000,"Name":"Credits","ImageTag":"c2"}],
     "MediaSources":[{"Id":"e1","Name":"1080p","Size":300000000,"Path":"/media/pilot.mkv","MediaStreams":[
       {"Type":"Subtitle","Index":1,"Codec":"subrip","Language":"eng","IsExternal":false},
       {"Type":"Subtitle","Index":2,"Codec":"subrip","Language":"eng","IsExternal":true},
       {"Type":"Subtitle","Index":3,"Codec":"subrip","Language":"eng","IsExternal":true,"IsForced":true},
       {"Type":"Subtitle","Index":4,"Codec":"ass","Language":"fre","IsExternal":true,"IsHearingImpaired":true},
       {"Type":"Subtitle","Index":5,"Codec":"subrip","Language":"eng","IsExternal":true,"Title":"Commentary"},
       {"Type":"Subtitle","Index":6,"Codec":"webvtt","IsExternal":true}]}]}
    """)

    #if !os(tvOS)
    static let storage = DownloadStorage(finished: URL(filePath: "/tmp/Finished"), root: URL(filePath: "/tmp/Root"))

    static func job(saved: Bool = false, now: Date = .now) -> DownloadJob {
        var job = DownloadJob(item: item, source: item.mediaSources![0], now: now)
        if saved { job.savedPath = "Test Show/Season 01/Test Show - S01E01 - Pilot.mkv" }
        return job
    }

    /// The job once its look-up has taken the version's segments and chapters.
    static func lookedUp(_ job: DownloadJob, at date: Date = .now) -> DownloadJob {
        var job = job
        job.segments = []
        job.extrasItemId = job.versionItemId
        job.extrasCheckedAt = date
        return job
    }
    #endif

    /// The same episode with a second version, which is an item of its own.
    static let withAlternate: JellyfinItem = {
        var episode = Extras.item
        episode.mediaSources?.append(MediaSource(id: "v2", name: "720p"))
        return episode
    }()
}

#if !os(tvOS)
struct DownloadExtrasTests {
    @Test func plansArtworkPreviewsAndChapterPicturesFromTheStart() {
        let job = Extras.job()
        let files = DownloadExtras.files(for: job, storage: Extras.storage)
        let folder = Extras.storage.extrasFolder(for: job.id)
        #expect(files.map(\.remote) == [
            .artwork(itemId: "e1", kind: .primary, tag: "p", width: 600),
            .artwork(itemId: "show", kind: .backdrop, tag: "b", width: 1280),
            .artwork(itemId: "e1", kind: .logo, tag: "l", width: 900),
            .artwork(itemId: "show", kind: .primary, tag: "sp", width: 600),
            .trickplaySheet(itemId: "e1", mediaSourceId: "e1", width: 320, index: 0),
            .trickplaySheet(itemId: "e1", mediaSourceId: "e1", width: 320, index: 1),
            .chapterImage(itemId: "e1", index: 0, tag: "c0"),
            .chapterImage(itemId: "e1", index: 2, tag: "c2"),
        ])
        // The show's backdrop is saved as the episode's own; the show's poster is shared.
        #expect(files[1].local == Extras.storage.artworkFile(itemId: "e1", kind: .backdrop))
        #expect(files.map(\.isOwn) == [true, true, true, false, true, true, true, true])
        #expect(files[5].local == folder.appending(path: "Trickplay/320/1.jpg"))
        #expect(files[7].local == folder.appending(path: "Chapters/2-c2.jpg"))
    }

    @Test func savesExternalSubtitlesBesideThePublishedFile() {
        let subtitles = DownloadExtras.files(for: Extras.job(saved: true), storage: Extras.storage).filter {
            if case .subtitle = $0.remote { true } else { false }
        }
        let folder = Extras.storage.finished.appending(path: "Test Show/Season 01")
        // The embedded track (1) stays in the file; two English SRTs share a name, so they're numbered.
        #expect(subtitles.map(\.local) == [
            folder.appending(path: "Test Show - S01E01 - Pilot.eng.2.srt"),
            folder.appending(path: "Test Show - S01E01 - Pilot.eng.forced.srt"),
            folder.appending(path: "Test Show - S01E01 - Pilot.fre.sdh.ass"),
            folder.appending(path: "Test Show - S01E01 - Pilot.eng.5.srt"),
            folder.appending(path: "Test Show - S01E01 - Pilot.und.vtt"),
        ])
        #expect(subtitles.first?.remote == .subtitle(itemId: "e1", mediaSourceId: "e1", streamIndex: 2, format: "srt"))
    }

    @Test func looksUpThenTakesEachMissingFileThenStops() {
        var job = Extras.job(saved: true)
        #expect(DownloadExtras.nextStep(for: job, storage: Extras.storage, exists: { _ in false }, now: .now) == .lookUp)
        job = Extras.lookedUp(job)
        let files = DownloadExtras.files(for: job, storage: Extras.storage)
        let first = DownloadExtras.nextStep(for: job, storage: Extras.storage, exists: { _ in false }, now: .now)
        #expect(first == .file(files[0]))
        let have = Set(files.dropLast().map(\.local))
        #expect(DownloadExtras.nextStep(for: job, storage: Extras.storage, exists: { have.contains($0) }, now: .now) == .file(files.last!))
        #expect(DownloadExtras.nextStep(for: job, storage: Extras.storage, exists: { _ in true }, now: .now) == nil)
    }

    @Test func keepsTheDownloadedVersionsOwnChaptersAndSegments() {
        let alternate = Extras.withAlternate.mediaSources![1]
        var job = DownloadJob(item: Extras.withAlternate, source: alternate)
        // The item lists its own version's chapters, so the other version's wait for the look-up.
        #expect(job.item?.chapters == nil)
        #expect(job.versionItemId == "v2")
        job = Extras.lookedUp(job)
        #expect(!DownloadExtras.needsLookUp(job, now: .now))
        job.item?.chapters = Extras.item.chapters
        let pictures = DownloadExtras.files(for: job, storage: Extras.storage).compactMap { file -> String? in
            if case .chapterImage(let itemId, _, _) = file.remote { itemId } else { nil }
        }
        #expect(pictures == ["v2", "v2"])
        // Saved when segments and chapters were the item's own version's, it's looked up again.
        job.extrasItemId = nil
        #expect(DownloadExtras.needsLookUp(job, now: .now))
    }

    @Test func looksTheItemUpAgainWhileItLacksPreviewsForAWeek() {
        let queued = Date(timeIntervalSince1970: 1_000_000)
        var job = Extras.job(now: queued)
        #expect(DownloadExtras.needsLookUp(job, now: queued), "never looked up")
        job = Extras.lookedUp(job, at: queued)
        #expect(!DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(3_600)))
        #expect(DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(2 * 86_400)), "a chapter has no picture yet")
        let pictured = job.item?.chapters?.filter { $0.imageTag != nil }
        job.item?.chapters = pictured
        #expect(!DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(2 * 86_400)))
        job.item?.trickplay = nil
        #expect(!DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(3_600)))
        #expect(DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(2 * 86_400)))
        #expect(!DownloadExtras.needsLookUp(job, now: queued.addingTimeInterval(8 * 86_400)))
    }

    @Test func handsPlaybackOnlyTheFilesOnDisk() {
        let job = Extras.job(saved: true)
        let files = DownloadExtras.files(for: job, storage: Extras.storage)
        let sheet = Extras.storage.extrasFolder(for: job.id).appending(path: "Trickplay/320/0.jpg")
        let subtitle = files.first { $0.remote == .subtitle(itemId: "e1", mediaSourceId: "e1", streamIndex: 4, format: "ass") }!.local
        let saved = DownloadExtras.saved(for: job, storage: Extras.storage) { $0 == sheet || $0 == subtitle }
        #expect(saved.trickplaySheets == [0: sheet])
        #expect(saved.subtitles == [4: subtitle])
        #expect(saved.chapterImages.isEmpty)
    }
}
#endif

struct PlaybackExtrasTests {
    @Test func listsChaptersOnlyForTheItemsOwnVersion() {
        let client = JellyfinClient(serverURL: URL(string: "https://jf.example.com")!, deviceId: "d", deviceName: "iPhone", token: "tok")
        let item = Extras.withAlternate
        let own = PlaybackResolver.chapters(of: item, playing: item.mediaSources![0], client: client)
        #expect(own.map(\.name) == ["Opening", "Chapter 2", "Credits"])
        #expect(own.first?.image?.path() == "/Items/e1/Images/Chapter/0")
        #expect(PlaybackResolver.chapters(of: item, playing: item.mediaSources![1], client: client).isEmpty)
    }

    @Test func picksTheSmallestPreviewsAtLeastThePlayersWidth() {
        #expect(TrickplayTiles.width(among: [240, 320, 640]) == 320)
        #expect(TrickplayTiles.width(among: [480, 640]) == 480)
        #expect(TrickplayTiles.width(among: [160, 240]) == 240)
        #expect(TrickplayTiles.width(among: [Int]()) == nil)
    }

    @Test func findsEachThumbnailOnItsSheet() throws {
        let tiles = try #require(TrickplayTiles.of(Extras.item, sourceId: "e1") { _, index in URL(filePath: "/sheet\(index).jpg") })
        #expect(tiles.sheets.count == 2)
        #expect(tiles.thumbnail(at: 0)?.sheet == 0)
        #expect(tiles.thumbnail(at: 0)?.rect == CGRect(x: 0, y: 0, width: 320, height: 180))
        // 125 seconds is the 13th thumbnail: third across, second down.
        #expect(tiles.thumbnail(at: 125)?.rect == CGRect(x: 640, y: 180, width: 320, height: 180))
        #expect(tiles.thumbnail(at: 1_005)?.sheet == 1)
        #expect(tiles.thumbnail(at: 1_005)?.rect == CGRect(x: 0, y: 0, width: 320, height: 180))
        // Past the end, the last thumbnail.
        #expect(tiles.thumbnail(at: 99_999)?.rect == CGRect(x: 2_880, y: 720, width: 320, height: 180))
        #expect(TrickplayTiles.of(Extras.item, sourceId: "e1") { _, index in index == 0 ? URL(filePath: "/a") : nil } == nil)
        #expect(TrickplayTiles.of(Extras.item, sourceId: "other") { _, _ in URL(filePath: "/a") } == nil)
    }

    @Test func namesChaptersAndFindsTheOnePlaying() {
        let chapters = ChapterMark.of(Extras.item) { index, _ in URL(filePath: "/chapter\(index).jpg") }
        #expect(chapters.map(\.name) == ["Opening", "Chapter 2", "Credits"])
        #expect(chapters.map(\.image) == [URL(filePath: "/chapter0.jpg"), nil, URL(filePath: "/chapter2.jpg")])
        #expect(ChapterMark.current(in: chapters, at: 0)?.index == 0)
        #expect(ChapterMark.current(in: chapters, at: 900)?.index == 1)
        #expect(ChapterMark.current(in: chapters, at: 5_000)?.index == 2)
    }

    @Test func offersOnlyTheServersSubtitleFiles() {
        let source = Extras.item.mediaSources![0]
        let tracks = ExternalSubtitleTrack.of(source) { _, index, format in
            index == 6 ? nil : URL(filePath: "/sub\(index).\(format)")
        }
        #expect(tracks.map(\.url) == [2, 3, 4, 5].map { index in
            URL(filePath: "/sub\(index).\(index == 4 ? "ass" : "srt")")
        })
        #expect(tracks.map(\.isForced) == [false, true, false, false])
        #expect(tracks[2].isHearingImpaired)
        #expect(tracks[3].name == "Commentary")
    }
}

#if !os(tvOS)
struct DownloadEstimateTests {
    private func source(_ size: Int64?) -> MediaSource {
        var source = MediaSource(id: UUID().uuidString)
        source.size = size
        return source
    }

    @Test func addsUpTheListedSizes() {
        let estimate = DownloadEstimate([source(2_000_000_000), source(1_500_000_000), nil])
        #expect(estimate.count == 2)
        #expect(estimate.bytes == 3_500_000_000)
        #expect(estimate.summary(noun: "episode", plural: "episodes") == "2 episodes, \(DownloadEstimate.text(3_500_000_000))")
        #expect(estimate.fits(in: 4_000_000_000))
        #expect(estimate.fits(in: nil))
        #expect(estimate.shortfall(space: 4_000_000_000) == nil)
        #expect(estimate.shortfall(space: 1_000_000_000)?.hasPrefix("Only \(DownloadEstimate.text(1_000_000_000)) is free") == true)
    }

    @Test func saysWhichSizesArentListed() {
        let some = DownloadEstimate([source(2_000_000_000), source(nil), source(500)])
        #expect(some.unknownCount == 2)
        #expect(some.summary(noun: "episode", plural: "episodes")
            == "3 episodes, at least \(DownloadEstimate.text(2_000_000_000)): 2 sizes aren't listed")
        #expect(DownloadEstimate([source(nil)]).summary(noun: "episode", plural: "episodes") == "1 episode, sizes not listed")
        #expect(DownloadEstimate([]).summary(noun: "episode", plural: "episodes") == "No episodes")
    }
}

struct DownloadsSnapshotTests {
    private static let start = Date(timeIntervalSince1970: 2_000_000)

    private func job(_ id: String, _ status: DownloadJob.Status, minutesIn: Double, total: Int64? = 1_000, done: Int64 = 0) -> DownloadJob {
        var item = Samples.item(#"{"Id":"\#(id)","Name":"Episode \#(id)","Type":"Episode","SeriesName":"Show","ParentIndexNumber":1,"IndexNumber":1}"#)
        item.mediaSources = [Samples.source]
        var job = DownloadJob(item: item, source: Samples.source, now: Self.start.addingTimeInterval(minutesIn * 60))
        job.status = status
        job.totalBytes = total
        if done > 0 { job.completed.insert(0..<done) }
        if status == .completed { job.completedAt = Self.start.addingTimeInterval(minutesIn * 60) }
        return job
    }

    @Test func listsDownloadsInQueueOrderAndUnwatchedOnesReady() {
        // Moved to the front of the queue, "first" downloads before the older "second".
        let jobs = [
            job("paused", .paused, minutesIn: 0, done: 100),
            job("first", .active, minutesIn: 2, done: 450),
            job("second", .active, minutesIn: 1),
            job("old", .completed, minutesIn: 3, done: 1_000),
            job("new", .completed, minutesIn: 4, done: 1_000),
            job("seen", .completed, minutesIn: 5, done: 1_000),
        ]
        let snapshot = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: jobs[1].id, isHeldForPlayback: false,
                                         isNetworkReachable: true, isWatched: { $0.itemId == "seen" })
        #expect(snapshot.downloads.map(\.id) == ["first", "second", "paused"])
        #expect(snapshot.downloads.map(\.state) == [.downloading, .queued, .paused])
        #expect(snapshot.downloads.map(\.percent) == [45, 0, 10])
        #expect(snapshot.unfinishedCount == 3)
        #expect(snapshot.activeCount == 2)
        #expect(snapshot.ready.map(\.id) == ["new", "old"])
        #expect(snapshot.readyCount == 2)
        #expect(snapshot.current?.title.playLink == URL(string: "vinnyfin://play/first?type=Episode&name=Episode%20first"))
        #expect(snapshot.summary
            == "Episode first is downloading, 45% done, with 1 more after it. 1 download is paused or stopped. 2 downloads are ready to watch offline.")
        #expect(snapshot.line == "Episode first 45% · 1 more")
        #expect(snapshot.isRunning)
    }

    @Test func saysWhyDownloadsWait() {
        let jobs = [job("a", .active, minutesIn: 0, total: nil)]
        let held = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: true,
                                     isNetworkReachable: true, isWatched: { _ in false })
        #expect(held.downloads.first?.state == .held)
        // Not begun: the listed size stands in for the one the server will give.
        #expect(held.downloads.first?.percent == 0)
        #expect(held.summary == "Downloads wait while you watch. Episode a is next. Nothing new is ready to watch offline.")
        let offline = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: false,
                                        isNetworkReachable: false, isWatched: { _ in false })
        #expect(offline.downloads.first?.state == .waitingForNetwork)
        let ruled = DownloadsSnapshot(jobs: jobs, receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: false,
                                      isNetworkReachable: true, waits: [jobs[0].id: DownloadWait.wifi.status], isWatched: { _ in false })
        #expect(ruled.downloads.first?.state == .waiting)
        #expect(ruled.downloads.first?.wait == "Waiting for Wi-Fi")
        #expect(ruled.summary == "Episode a is next. Waiting for Wi-Fi. Nothing new is ready to watch offline.")
        let none = DownloadsSnapshot(jobs: [], receivedBytes: [:], downloadingJobId: nil, isHeldForPlayback: false,
                                     isNetworkReachable: true, isWatched: { _ in false })
        #expect(none.summary == "Nothing is downloading. Nothing new is ready to watch offline.")
        #expect(none.line == "No downloads")
        #expect(!none.isRunning)
    }

    @Test func reloadsSoonForChangesAndOnceAMinuteForProgress() {
        let jobs = [job("a", .active, minutesIn: 0)]
        func snapshot(received: Int64, status: DownloadJob.Status = .active) -> DownloadsSnapshot {
            var changed = jobs
            changed[0].status = status
            return DownloadsSnapshot(jobs: changed, receivedBytes: [changed[0].id: received], downloadingJobId: changed[0].id,
                                     isHeldForPlayback: false, isNetworkReachable: true, isWatched: { _ in false },
                                     now: Self.start.addingTimeInterval(Double(received)))
        }
        let written = snapshot(received: 100)
        let at = Self.start
        #expect(snapshot(received: 100).writeDate(after: nil, writtenAt: at) == .distantPast)
        // Only the time it was taken differs.
        #expect(snapshot(received: 100).writeDate(after: written, writtenAt: at) == nil)
        #expect(snapshot(received: 200).writeDate(after: written, writtenAt: at)
            == at.addingTimeInterval(DownloadsSnapshot.progressReloadInterval))
        #expect(snapshot(received: 100, status: .paused).writeDate(after: written, writtenAt: at)
            == at.addingTimeInterval(DownloadsSnapshot.changeReloadInterval))
    }

    @Test func roundTripsThroughJSON() throws {
        var snapshot = DownloadsSnapshot(jobs: [job("a", .active, minutesIn: 0, done: 10)], receivedBytes: [:], downloadingJobId: nil,
                                         isHeldForPlayback: false, isNetworkReachable: true, isWatched: { _ in false })
        var title = try #require(snapshot.downloads.first?.title)
        title.hasArtwork = true
        snapshot.ready = [title]
        let decoded = try JSONDecoder().decode(DownloadsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }
}

struct IntentSummaryTests {
    private func episode(_ number: Int) -> JellyfinItem {
        Samples.item(#"{"Id":"e\#(number)","Name":"Episode \#(number)","Type":"Episode","ParentIndexNumber":2,"IndexNumber":\#(number)}"#)
    }

    @Test func saysWhichEpisodesWereQueued() {
        #expect(IntentSummaries.queued([episode(4)], of: "Test Show", asked: 3) == "Downloading S02E04 of Test Show.")
        #expect(IntentSummaries.queued([episode(4), episode(5), episode(6)], of: "Test Show", asked: 3)
            == "Downloading 3 episodes of Test Show: S02E04, S02E05, and S02E06.")
        #expect(IntentSummaries.queued([], of: "Test Show", asked: 3) == "The next 3 episodes of Test Show are already downloaded or on their way.")
        #expect(IntentSummaries.queued([], of: "Test Show", asked: 1) == "The next episode of Test Show is already downloaded or on its way.")
    }

    @Test func countsWhatPausedAndResumed() {
        #expect(IntentSummaries.paused(0) == "Nothing is downloading.")
        #expect(IntentSummaries.paused(2) == "Paused 2 downloads.")
        #expect(IntentSummaries.resumed(1) == "Resumed 1 download.")
        #expect(IntentSummaries.resumed(0) == "No downloads are paused.")
    }

    @Test func saysAMovieIsAlreadyThere() {
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.status = .completed
        #expect(IntentSummaries.alreadyThere(job) == "\(job.title) is already downloaded.")
        #expect(IntentSummaries.movieQueued(nil, name: "Big Test Movie", source: Samples.source, isOneOfSeveral: true)
            == "Downloading Big Test Movie: 1080p, \(DownloadEstimate.text(300_000_000)).")
        #expect(IntentSummaries.movieQueued(nil, name: "Big Test Movie", source: Samples.source, isOneOfSeveral: false)
            == "Downloading Big Test Movie: \(DownloadEstimate.text(300_000_000)).")
    }
}
#endif
