import Foundation
import Testing
@testable import vinnyfin

/// A movie with a 4K and a 1080p version, as Jellyfin 12.4 lists it after a playback stepped
/// down to the 1080p version and stopped there at 3:30: the movie lists that version first,
/// while its own user data keeps 2:30, where the 4K version stopped.
struct VersionPlayedLastTests {
    let movie: JellyfinItem
    /// The 1080p version's own user data, as the server gives it.
    let alternate: UserItemData

    private let ownId = "2bbfee523d051d10b55753c530d83ac9"
    private let alternateId = "04ab28e4a01eb6e6715bd19765a03fa4"

    init() throws {
        movie = try JSONDecoder().decode(JellyfinItem.self, from: Samples.fixture("movie-resumed-on-alternate"))
        alternate = try JSONDecoder().decode(UserItemData.self, from: Data("""
        {"PlayedPercentage":49.997262054697,"PlaybackPositionTicks":2100000000,"PlayCount":2,"IsFavorite":false,
         "LastPlayedDate":"2026-11-04T20:52:25.5981076Z","Played":false}
        """.utf8))
    }

    @Test func findsTheVersionListedAheadOfTheMoviesOwn() {
        #expect(movie.mediaSources?.map(\.id) == [alternateId, ownId])
        #expect(movie.versionPlayedLast?.id == alternateId)
    }

    @Test func putsTheMoviesOwnVersionFirstAgain() {
        let shown = movie.withOwnVersionFirst(positionFrom: alternate)
        #expect(shown.mediaSources?.map(\.id) == [ownId, alternateId])
        #expect(shown.versionPlayedLast == nil)
    }

    @Test func resumesWhereTheVersionPlayedLastGotTo() {
        #expect(movie.resumeSeconds == 150)
        let shown = movie.withOwnVersionFirst(positionFrom: alternate)
        #expect(shown.resumeSeconds == 210)
        #expect(shown.progress == alternate.playedPercentage.map { $0 / 100 })
    }

    @Test func keepsTheMoviesOwnWatchedCountAndFavorite() {
        var favorite = movie
        favorite.userData?.isFavorite = true
        let shown = favorite.withOwnVersionFirst(positionFrom: alternate)
        #expect(shown.isFavorite)
        #expect(!shown.isPlayed)
        #expect(shown.userData?.playCount == 2)
    }

    @Test func startsTheNextPlaybackAtTheBestVersionTheQualityAllows() throws {
        let sources = try #require(movie.withOwnVersionFirst(positionFrom: alternate).mediaSources)
        #expect(VersionChooser.choose(from: sources, quality: .original)?.id == ownId)
        #expect(VersionChooser.choose(from: sources, quality: .uhd)?.id == ownId)
        #expect(VersionChooser.choose(from: sources, quality: .fullHD)?.id == alternateId)
        // As the server lists them, Best Available would have stayed on the 1080p version.
        #expect(VersionChooser.choose(from: movie.mediaSources ?? [], quality: .original)?.id == alternateId)
    }

    @Test func aStepDownDoesntChangeWhatTheNextPlaybackStartsWith() throws {
        let shown = movie.withOwnVersionFirst(positionFrom: alternate)
        let sources = try #require(shown.mediaSources)
        let first = try #require(VersionChooser.planStreaming(sources: sources, preferred: nil, quality: .original, allowTranscoding: true))
        #expect(first == .direct(sources[0]))
        // A link of 2 Mb/s carries the 1080p version (0.95 Mb/s) but not the 4K one (3.6 Mb/s).
        let stepped = VersionChooser.planStepDown(from: first, bitrate: nil, throughput: 2_000_000, sources: sources, allowTranscoding: true)
        #expect(stepped?.source.id == alternateId)
        // The server then lists the 1080p version first, which `movie` is.
        let next = movie.withOwnVersionFirst(positionFrom: alternate)
        #expect(VersionChooser.planStreaming(sources: next.mediaSources ?? [], preferred: nil, quality: .original,
                                             allowTranscoding: true) == first)
        #expect(next.resumeSeconds == 210)
    }

    @Test func leavesAnItemWhoseOwnVersionLeadsAsItIs() {
        var ownFirst = movie
        ownFirst.mediaSources = movie.mediaSources?.reversed()
        #expect(ownFirst.versionPlayedLast == nil)
    }

    @Test func takesAnAlternateVersionListingItselfFirstForWhatItIs() {
        // The 1080p version asked for by its own id lists itself first.
        var version = JellyfinItem(id: alternateId, name: "Two Versions", type: "Movie")
        version.mediaSources = movie.mediaSources
        #expect(version.versionPlayedLast == nil)
    }

    @Test func keepsTheServersOrderBehindTheItemsOwnVersion() {
        // Gelato's streams: the server moved stream "c", partway through, ahead of the movie's own "a".
        let streams = [
            version("c", "1080p WEB", height: 1080), version("a", "4K REMUX", height: 2160),
            version("b", "1080p BluRay", height: 1080), version("d", "720p", height: 720),
        ]
        var gelato = JellyfinItem(id: "a", name: "Streamed", type: "Movie")
        gelato.mediaSources = streams
        #expect(gelato.versionPlayedLast?.id == "c")
        #expect(gelato.withOwnVersionFirst(positionFrom: alternate).mediaSources?.map(\.id) == ["a", "c", "b", "d"])
    }

    private func version(_ id: String, _ name: String, height: Int) -> MediaSource {
        var source = MediaSource(id: id, name: name)
        var video = MediaStream(type: "Video")
        video.width = height * 16 / 9
        video.height = height
        source.mediaStreams = [video]
        return source
    }
}

/// Resume and Next Up name the version that was played, or the next episode's matching version;
/// lists show the item the versions belong to.
struct ListedItemTests {
    private func item(_ id: String, versions: [String]) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: id, type: "Episode")
        item.mediaSources = versions.map { MediaSource(id: $0) }
        return item
    }

    @Test func findsTheItemAnAlternateVersionBelongsTo() {
        let listed = [item("e1", versions: ["e1", "e1-1080"]), item("e2", versions: ["e2", "e2-1080"])]
        #expect(JellyfinItem(id: "e2-1080", name: "", type: "Episode").listedItem(among: listed)?.id == "e2")
        #expect(JellyfinItem(id: "e1", name: "", type: "Episode").listedItem(among: listed)?.id == "e1")
        #expect(JellyfinItem(id: "m1", name: "", type: "Movie").listedItem(among: listed) == nil)
    }
}
