import Foundation
import Testing
@testable import vinnyfin

enum Samples {
    static let movie = item("""
    {"Id":"m1","Name":"Big Test Movie","Type":"Movie","ProductionYear":2024}
    """)
    static let episode = item("""
    {"Id":"e1","Name":"Pilot: Part 1/2","Type":"Episode","SeriesName":"Test Show","ParentIndexNumber":1,"IndexNumber":2}
    """)
    static let source: MediaSource = {
        var source = MediaSource(id: "s1", name: "1080p")
        source.path = "/media/movie.mkv"
        source.protocol = "File"
        source.container = "mkv"
        source.size = 300_000_000
        return source
    }()

    static func item(_ json: String) -> JellyfinItem {
        do {
            return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
        } catch {
            fatalError("sample item doesn't decode: \(error)")
        }
    }

    static func fixture(_ name: String) throws -> Data {
        final class Anchor {}
        let bundle = Bundle(for: Anchor.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }
}

struct JellyfinDecodingTests {
    @Test func decodesAMovieWithTwoLocalVersions() throws {
        let movie = try JSONDecoder().decode(JellyfinItem.self, from: Samples.fixture("movie-two-versions"))
        #expect(movie.type == "Movie")
        let sources = try #require(movie.mediaSources)
        #expect(sources.map(\.name) == ["1080p", "720p"])
        #expect(sources.map(\.fileExtension) == ["mkv", "mp4"])
        #expect(sources[0].plausibleSize == 300_748_302)
        #expect(sources[0].videoStream?.displayTitle == "1080p H264 SDR")
    }

    @Test func decodesARemoteStreamWithoutTrustingItsSize() throws {
        // A .strm source behaves like a Gelato stream: an http path and the pointer file's size.
        let movie = try JSONDecoder().decode(JellyfinItem.self, from: Samples.fixture("movie-remote-strm"))
        let source = try #require(movie.mediaSources?.first)
        #expect(source.protocol == "Http")
        #expect(source.plausibleSize == nil)
        #expect(source.fileExtension == "mkv")
    }

    @Test func decodesEpisodes() throws {
        let page = try JSONDecoder().decode(ItemsPage.self, from: Samples.fixture("episodes"))
        #expect(page.items.count == 5)
        #expect(page.items.map(\.episodeCode) == ["S01E01", "S01E02", "S01E03", "S01E04", "S01E05"])
    }
}

#if !os(tvOS)
struct NamingTests {
    @Test func namesMoviesWithTheirYear() {
        #expect(DownloadJob.destinationStem(for: Samples.movie) == "Big Test Movie (2024)")
        let titled = Samples.item(#"{"Id":"m2","Name":"Heat (1995)","Type":"Movie","ProductionYear":1995}"#)
        #expect(DownloadJob.destinationStem(for: titled) == "Heat (1995)")
    }

    @Test func namesEpisodesTheWayMediaPlayersExpect() {
        #expect(DownloadJob.destinationStem(for: Samples.episode) == "Test Show/Season 01/Test Show - S01E02 - Pilot Part 1 2")
    }

    @Test func sanitizesPathCharacters() {
        #expect(DownloadJob.sanitize("  a/b:c?  d. ") == "a b c d")
    }
}
#endif

struct AddressTests {
    @Test func buildsServerURLsFromTheFormFields() throws {
        #expect(try ServerAddress(host: "192.168.1.5").url.get().absoluteString == "http://192.168.1.5:8096")
        #expect(try ServerAddress(scheme: .https, host: "jf.example.com").url.get().absoluteString == "https://jf.example.com")
        #expect(try ServerAddress(scheme: .https, host: "jf.example.com", port: "8920", path: "jellyfin/").url.get().absoluteString == "https://jf.example.com:8920/jellyfin")
        #expect(try ServerAddress(scheme: .http, host: "nas.local", port: "80").url.get().absoluteString == "http://nas.local")
        #expect(throws: JellyfinError.self) { try ServerAddress(host: "").url.get() }
        #expect(throws: JellyfinError.self) { try ServerAddress(host: "nas.local", port: "99999").url.get() }
        #expect(throws: JellyfinError.self) { try ServerAddress(host: "nas local").url.get() }
    }

    @Test func splitsPastedAddresses() {
        #expect(ServerAddress(parsing: "https://jf.example.com:8920/jellyfin/") == ServerAddress(scheme: .https, host: "jf.example.com", port: "8920", path: "/jellyfin"))
        #expect(ServerAddress(parsing: "10.0.0.5:8096") == ServerAddress(scheme: .http, host: "10.0.0.5", port: "8096"))
        #expect(ServerAddress(parsing: "nas.local/jf", defaultScheme: .https) == ServerAddress(scheme: .https, host: "nas.local", path: "/jf"))
        #expect(ServerAddress(parsing: "ftp://nope") == nil)
        var typed = ServerAddress(scheme: .https, host: "nas.local:8920", path: "/jellyfin")
        typed.splitHost()
        #expect(typed == ServerAddress(scheme: .https, host: "nas.local", port: "8920", path: "/jellyfin"))
        #expect(ServerAddress.looksLikeFullAddress("nas.local") == false)
        #expect(ServerAddress.looksLikeFullAddress("nas.local:8096"))
        #expect(ServerAddress.looksLikeFullAddress("https://nas.local"))
    }

    @Test func buildsStaticStreamURLs() {
        let client = JellyfinClient(serverURL: URL(string: "https://jf.example.com/base")!, deviceId: "d", deviceName: "iPhone", token: "tok")
        let url = client.streamURL(itemId: "item", mediaSourceId: "source")
        #expect(url.absoluteString == "https://jf.example.com/base/Videos/item/stream?ApiKey=tok&mediaSourceId=source&static=true")
    }

    @Test func matchesTheSameReleaseAcrossEpisodes() {
        func source(_ id: String, _ name: String) -> MediaSource {
            MediaSource(id: id, name: name)
        }
        let picked = source("a", "[RD+] 2160p HDR10 REMUX GroupX")
        let candidates = [source("1", "[RD+] 1080p WEB-DL GroupY"), source("2", "[RD+] 2160p HDR10 REMUX GroupX"), source("3", "720p")]
        #expect(picked.closestMatch(in: candidates)?.id == "2")
        #expect(source("z", "zzz").closestMatch(in: candidates) == nil)
    }
}

#if !os(tvOS)
struct StorageTests {
    private func makeStorage() throws -> DownloadStorage {
        let base = FileManager.default.temporaryDirectory.appending(path: "StorageTests-\(UUID().uuidString)")
        let storage = DownloadStorage(finished: base.appending(path: "Finished"), root: base.appending(path: "Root"))
        try storage.prepare()
        return storage
    }

    private func chunk(_ bytes: [UInt8], in storage: DownloadStorage) throws -> URL {
        let url = storage.staging.appending(path: UUID().uuidString)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func assemblesChunksArrivingOutOfOrder() async throws {
        let storage = try makeStorage()
        let content = (0..<250).map { UInt8($0 % 251) }
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.totalBytes = 250

        for (start, end) in [(200, 250), (0, 100), (100, 200)] {
            try await storage.writeChunk(try chunk(Array(content[start..<end]), in: storage), into: job.id, at: Int64(start))
        }
        let path = try storage.publish(job)
        #expect(path == "Big Test Movie (2024).mkv")
        #expect(try Data(contentsOf: storage.finished.appending(path: path)) == Data(content))
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.staging.path).isEmpty)
    }

    @Test func truncatesBytesPastTheEnd() async throws {
        let storage = try makeStorage()
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.totalBytes = 10
        try await storage.writeChunk(try chunk(Array(repeating: 7, count: 20), in: storage), into: job.id, at: 0)
        let path = try storage.publish(job)
        #expect(try Data(contentsOf: storage.finished.appending(path: path)).count == 10)
    }

    @Test func picksAFreeNameForASecondCopy() async throws {
        let storage = try makeStorage()
        var paths: [String] = []
        for _ in 0..<3 {
            var job = DownloadJob(item: Samples.episode, source: Samples.source)
            job.totalBytes = 1
            try await storage.writeChunk(try chunk([1], in: storage), into: job.id, at: 0)
            paths.append(try storage.publish(job))
        }
        #expect(paths == [
            "Test Show/Season 01/Test Show - S01E02 - Pilot Part 1 2.mkv",
            "Test Show/Season 01/Test Show - S01E02 - Pilot Part 1 2 - 1080p.mkv",
            "Test Show/Season 01/Test Show - S01E02 - Pilot Part 1 2 2.mkv",
        ])
    }

    @Test func savesAndLoadsJobs() throws {
        let storage = try makeStorage()
        var job = DownloadJob(item: Samples.movie, source: Samples.source)
        job.rangeSupport = .supported
        job.totalBytes = 1000
        job.completed = ByteRanges([0..<100, 500..<600])
        try storage.saveJobs([job])
        let loaded = try storage.loadJobs()
        #expect(loaded.count == 1)
        #expect(loaded[0].completed == job.completed)
        #expect(loaded[0].destinationStem == job.destinationStem)
    }

    /// A relaunch reads back what the session was handed, to wait for those transfers' reports.
    @Test func savesAndLoadsTheTransfersHandedOut() throws {
        let storage = try makeStorage()
        #expect(try storage.loadHandedOut().isEmpty)
        let jobId = UUID()
        let tags: Set = [TransferTag(jobId: jobId, range: 0..<100), TransferTag(jobId: jobId, range: nil)]
        try storage.saveHandedOut(tags)
        #expect(Set(try storage.loadHandedOut()) == tags)
    }

    /// Ranges held for a playback keep their resume data across a kill until released.
    @Test func keepsHeldResumeDataUntilRemoved() throws {
        let storage = try makeStorage()
        let first = TransferTag(jobId: UUID(), range: 0..<100)
        let second = TransferTag(jobId: UUID(), range: 100..<200)
        try storage.saveHeld(Data([1]), for: first)
        try storage.saveHeld(Data([2]), for: second)
        #expect(try storage.loadHeld() == [first: Data([1]), second: Data([2])])
        try storage.removeHeld { $0.jobId == first.jobId }
        #expect(try storage.loadHeld() == [second: Data([2])])
        try storage.removeHeld { _ in true }
        #expect(try storage.loadHeld().isEmpty)
    }
}
#endif
