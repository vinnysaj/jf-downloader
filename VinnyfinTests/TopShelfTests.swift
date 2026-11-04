import Foundation
import Testing
@testable import vinnyfin
#if os(tvOS)
import TVServices
#endif

struct AppLinkTests {
    @Test func roundTripsATitlesPageAndItsPlayback() throws {
        for action in [AppLink.Action.open, .play] {
            let link = AppLink(action, Samples.episode)
            #expect(AppLink(link.url) == link)
        }
        #expect(AppLink(.open, Samples.movie).url.absoluteString == "vinnyfin://item/m1?type=Movie&name=Big%20Test%20Movie")
        #expect(AppLink(.play, Samples.movie).url.absoluteString == "vinnyfin://play/m1?type=Movie&name=Big%20Test%20Movie")
    }

    @Test func keepsNamesWithURLCharactersIntact() throws {
        let item = JellyfinItem(id: "abc123", name: "Fast & Furious = 2+2? #1 / Été", type: "Movie")
        let link = try #require(AppLink(AppLink(.open, item).url))
        #expect(link.name == item.name)
        #expect(link.itemId == "abc123")
    }

    @Test func describesTheTitleForItsPage() throws {
        let link = try #require(AppLink(URL(string: "vinnyfin://item/s1?type=Series&name=Port%20Ellery")!))
        #expect(link.action == .open)
        #expect(link.item.id == "s1")
        #expect(link.item.isSeries)
        #expect(link.item.name == "Port Ellery")
    }

    @Test func readsTheSchemeAndActionInAnyCase() {
        #expect(AppLink(URL(string: "VINNYFIN://PLAY/m1?type=Movie&name=x")!)?.action == .play)
    }

    @Test func turnsDownOtherURLs() {
        let others = [
            "https://jf.example.com/item/m1?type=Movie&name=x",
            "vinnyfin://settings/m1?type=Movie&name=x",
            "vinnyfin://item?type=Movie&name=x",
            "vinnyfin://item/?type=Movie&name=x",
            "vinnyfin://item/m1/extra?type=Movie&name=x",
            "vinnyfin://item/m1?name=x",
            "vinnyfin://item/m1?type=&name=x",
            "vinnyfin://item/m1?type=Movie",
        ]
        for other in others {
            #expect(AppLink(URL(string: other)!) == nil, "\(other)")
        }
        #expect(AppLink(URL(filePath: "/tmp/movie.mkv")) == nil)
    }
}

#if os(tvOS)
struct TopShelfContentTests {
    private let session = ServerSession(
        client: JellyfinClient(serverURL: URL(string: "https://jf.example.com")!, deviceId: "d", deviceName: "Apple TV", token: "tok"),
        account: AccountStore.Account(serverURL: URL(string: "https://jf.example.com")!, serverId: "server", userId: "u", userName: "Alex")
    )

    private let movieInProgress = Samples.item("""
    {"Id":"m1","Name":"Big Test Movie","Type":"Movie","RunTimeTicks":60000000000,"ImageTags":{"Primary":"p","Thumb":"t"},
     "UserData":{"PlaybackPositionTicks":24000000000,"PlayedPercentage":40}}
    """)
    private let episodeInProgress = Samples.item("""
    {"Id":"e1","Name":"Pilot","Type":"Episode","SeriesName":"Test Show","SeriesId":"s1","ParentIndexNumber":1,"IndexNumber":2,
     "ImageTags":{"Primary":"still"},"UserData":{"PlaybackPositionTicks":1,"PlayedPercentage":25}}
    """)
    private let nextEpisode = Samples.item("""
    {"Id":"e2","Name":"Second","Type":"Episode","SeriesName":"Other Show","SeriesId":"s2","ParentIndexNumber":2,"IndexNumber":1}
    """)
    private let newMovie = Samples.item(#"{"Id":"m2","Name":"New Movie","Type":"Movie","ImageTags":{"Primary":"p2"}}"#)
    private let newShow = Samples.item(#"{"Id":"s3","Name":"New Show","Type":"Series","ImageTags":{"Primary":"p3"}}"#)

    @Test func putsWhatsInProgressFirstAndShowsEachTitleOnce() throws {
        let content = try #require(TopShelf.content(
            resume: [movieInProgress, episodeInProgress], nextUp: [episodeInProgress, nextEpisode],
            latestMovies: [movieInProgress, newMovie], latestShows: [newShow], session: session
        ))
        #expect(content.sections.map(\.title) == ["Up Next", "Recently Added Movies", "Recently Added Shows"])
        #expect(content.sections.map { $0.items.map(\.identifier) } == [["m1", "e1", "e2"], ["m2"], ["s3"]])
        #expect(content.sections[0].items.allSatisfy { $0.imageShape == .hdtv })
        #expect(content.sections[1].items.allSatisfy { $0.imageShape == .poster })
    }

    @Test func namesEpisodesByTheirShowAndShowsHowFarAlongTheyAre() throws {
        let content = try #require(TopShelf.content(resume: [episodeInProgress, movieInProgress], nextUp: [nextEpisode],
                                                    latestMovies: [], latestShows: [], session: session))
        let items = try #require(content.sections.first?.items)
        #expect(items.map(\.title) == ["Test Show · S01E02", "Big Test Movie", "Other Show · S02E01"])
        #expect(items.map(\.playbackProgress) == [0.25, 0.4, 0])
    }

    @Test func showsEpisodeStillsInUpNextAndPostersForWhatsNew() throws {
        let content = try #require(TopShelf.content(resume: [episodeInProgress], nextUp: [], latestMovies: [newMovie],
                                                    latestShows: [], session: session))
        let width = Int(TVTopShelfSectionedContent.imageSize(for: .hdtv).width * 2)
        #expect(content.sections[0].items[0].imageURL(for: .screenScale2x)
            == session.client.imageURL(itemId: "e1", tag: "still", maxWidth: width))
        let posterWidth = Int(TVTopShelfSectionedContent.imageSize(for: .poster).width)
        #expect(content.sections[1].items[0].imageURL(for: .screenScale1x)
            == session.client.imageURL(itemId: "m2", tag: "p2", maxWidth: posterWidth))
    }

    @Test func opensThePageOnSelectAndPlaysOnPlay() throws {
        let content = try #require(TopShelf.content(resume: [movieInProgress], nextUp: [], latestMovies: [],
                                                    latestShows: [newShow], session: session))
        let movie = content.sections[0].items[0]
        #expect(movie.displayAction?.url == AppLink(.open, movieInProgress).url)
        #expect(movie.playAction?.url == AppLink(.play, movieInProgress).url)
        let show = content.sections[1].items[0]
        #expect(show.displayAction?.url == AppLink(.open, newShow).url)
        #expect(show.playAction == nil)
    }

    @Test func leavesOutEmptyRowsAndHasNothingForAnEmptyLibrary() throws {
        let content = try #require(TopShelf.content(resume: [], nextUp: [], latestMovies: [newMovie], latestShows: [], session: session))
        #expect(content.sections.map(\.title) == ["Recently Added Movies"])
        #expect(TopShelf.content(resume: [], nextUp: [], latestMovies: [], latestShows: [], session: session) == nil)
    }

    @Test func keepsEachRowToItsSize() throws {
        let movies = (0..<30).map { JellyfinItem(id: "m\($0)", name: "Movie \($0)", type: "Movie") }
        let content = try #require(TopShelf.content(resume: [], nextUp: [], latestMovies: movies, latestShows: [], session: session))
        #expect(content.sections[0].items.count == TopShelf.itemsPerSection)
    }
}
#endif
