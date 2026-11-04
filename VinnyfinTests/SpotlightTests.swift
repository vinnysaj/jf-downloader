import AppIntents
import Foundation
import Testing
@testable import vinnyfin

private let session = ServerSession(
    client: JellyfinClient(serverURL: URL(string: "https://jf.example.com")!, deviceId: "d", deviceName: "iPhone", token: "tok"),
    account: AccountStore.Account(serverURL: URL(string: "https://jf.example.com")!, serverId: "server", userId: "u", userName: "Alex")
)

struct TitleEntityTests {
    @Test func describesAMovieWithItsSummaryGenresAndPoster() throws {
        let movie = MovieEntity(Samples.item("""
        {"Id":"m1","Name":"Copperline","Type":"Movie","ProductionYear":2019,"Overview":"A heist.","Genres":["Crime","Drama"],
         "ImageTags":{"Primary":"tag1"}}
        """), session: session)
        #expect(movie.id == "m1")
        #expect(movie.name == "Copperline")
        #expect(movie.year == 2019)
        #expect(movie.overview == "A heist.")
        #expect(movie.genres == ["Crime", "Drama"])
        let poster = try #require(movie.poster?.absoluteString)
        #expect(poster.contains("Items/m1/Images/Primary"))
        #expect(poster.contains("tag=tag1"))
        #expect(!poster.contains("tok"), "the token stays out of what Spotlight and Siri keep")
        #expect(movie.item.isMovie)
    }

    @Test func namesAnEpisodeWithItsShowAndPlaceAndTheShowsPoster() throws {
        let episode = EpisodeEntity(Samples.item("""
        {"Id":"e1","Name":"Half Loop","Type":"Episode","SeriesName":"Port Ellery","SeriesId":"s1","SeriesPrimaryImageTag":"stag",
         "ParentIndexNumber":1,"IndexNumber":2}
        """), session: session)
        #expect(episode.name == "Half Loop")
        #expect(episode.show == "Port Ellery")
        #expect(episode.season == 1)
        #expect(episode.number == 2)
        #expect(episode.code == "S01E02")
        #expect(try #require(episode.poster?.absoluteString).contains("Items/s1/Images/Primary"))
        #expect(episode.item.isEpisode)
    }

    @Test func tellsSiriWhichEntityAPageShows() {
        #expect(EntityIdentifier.title(Samples.movie) == EntityIdentifier(for: MovieEntity.self, identifier: "m1"))
        #expect(EntityIdentifier.title(Samples.episode) == EntityIdentifier(for: EpisodeEntity.self, identifier: "e1"))
        #expect(EntityIdentifier.title(JellyfinItem(id: "s1", name: "Port Ellery", type: "Series"))
            == EntityIdentifier(for: ShowEntity.self, identifier: "s1"))
        #expect(EntityIdentifier.title(JellyfinItem(id: "b1", name: "Box", type: "BoxSet")) == nil)
    }

    @Test func linksEachKindToItsPageAndPlayback() {
        let show = ShowEntity(item: JellyfinItem(id: "s1", name: "Port Ellery", type: "Series"), poster: nil)
        #expect(AppLink(.open, show.item).url.absoluteString == "vinnyfin://item/s1?type=Series&name=Port%20Ellery")
        let movie = MovieEntity(item: JellyfinItem(id: "m1", name: "Copperline", type: "Movie"), poster: nil)
        #expect(AppLink(.play, movie.item).url.absoluteString == "vinnyfin://play/m1?type=Movie&name=Copperline")
    }
}

struct PlaybackIntentTests {
    private func title(_ id: String, _ name: String, year: Int? = nil, type: String = "Movie") -> JellyfinItem {
        var item = JellyfinItem(id: id, name: name, type: type)
        item.productionYear = year
        return item
    }

    @Test func playsTheTitleNamedExactlyIgnoringCaseAccentsAndYear() {
        let titles = [title("1", "The Matrix Reloaded"), title("2", "The Matrix", year: 1999), title("3", "Amélie")]
        #expect(TitleMatch.best(for: "the matrix", among: titles)?.id == "2")
        #expect(TitleMatch.best(for: "The Matrix (1999)", among: titles)?.id == "2")
        #expect(TitleMatch.best(for: "amelie", among: titles)?.id == "3")
    }

    @Test func otherwisePlaysTheShortestNameThatContainsIt() {
        let titles = [title("1", "Severance: Behind the Scenes"), title("2", "Severance Season Recap"), title("3", "Other")]
        #expect(TitleMatch.best(for: "severance", among: titles)?.id == "2")
        #expect(TitleMatch.best(for: "nothing like it", among: titles)?.id == "1")
        #expect(TitleMatch.best(for: "anything", among: []) == nil)
    }

    @Test func movesOnFromAnEpisodePartwayThroughOnly() {
        let partway = Samples.item(#"{"Id":"e3","Name":"Three","Type":"Episode","UserData":{"PlaybackPositionTicks":6000000000}}"#)
        let fresh = Samples.item(#"{"Id":"e4","Name":"Four","Type":"Episode","UserData":{"PlaybackPositionTicks":0}}"#)
        #expect(ShowEpisodes.isPartway(partway))
        #expect(!ShowEpisodes.isPartway(fresh))
    }

    @Test func saysWhyThereIsNothingToPlay() {
        #expect(TitleIntentError.watchedEverything("Port Ellery").errorDescription == "You've watched every episode of Port Ellery.")
        #expect(TitleIntentError.nothingAfter(show: "Port Ellery", episode: "S02E08").errorDescription == "Port Ellery has no episode after S02E08.")
        #expect(TitleIntentError.notFound("Copperline").errorDescription == "There's nothing called Copperline on your server.")
    }

    @Test func staysWithinTheTenAppShortcutsAnAppMayHave() {
        #if os(tvOS)
        #expect(VinnyfinShortcuts.appShortcuts.count == 5)
        #else
        #expect(VinnyfinShortcuts.appShortcuts.count == 10)
        #endif
    }
}

#if !os(tvOS)
struct SpotlightPlanTests {
    @Test func putsASmallLibraryInWhole() {
        #expect(SpotlightPlan(titles: 52, episodes: 36) == .everything)
        #expect(SpotlightPlan(titles: SpotlightPlan.limit - 100, episodes: 100) == .everything)
    }

    @Test func leavesOutEpisodesNobodyIsWatchingOnceTheyTipItOver() {
        #expect(SpotlightPlan(titles: 900, episodes: 30_000) == .allTitles)
        #expect(SpotlightPlan(titles: SpotlightPlan.limit, episodes: 1) == .allTitles)
    }

    @Test func keepsToWhatsWatchedFavouritedDownloadedOrNewInABigLibrary() {
        #expect(SpotlightPlan(titles: 20_000, episodes: 0) == .personal)
        #expect(SpotlightPlan(titles: SpotlightPlan.limit + 1, episodes: 200_000) == .personal)
    }

    @Test func boundsThePersonalPlanWellBelowAWholeLibrary() {
        let most = SpotlightPlan.favouriteLimit + SpotlightPlan.watchedLimit + 2 * SpotlightPlan.recentLimit
            + 2 * SpotlightPlan.inProgressLimit
        #expect(most < SpotlightPlan.limit)
    }

    @Test func pagesThroughAListThenStops() {
        #expect(SpotlightPlan.nextPage(loaded: 0, total: nil, limit: nil) == 0..<500)
        #expect(SpotlightPlan.nextPage(loaded: 500, total: 1_200, limit: nil) == 500..<1_000)
        #expect(SpotlightPlan.nextPage(loaded: 1_000, total: 1_200, limit: nil) == 1_000..<1_200)
        #expect(SpotlightPlan.nextPage(loaded: 1_200, total: 1_200, limit: nil) == nil)
    }

    @Test func pagesOnlyAsFarAsTheLimit() {
        #expect(SpotlightPlan.nextPage(loaded: 0, total: nil, limit: 100) == 0..<100)
        #expect(SpotlightPlan.nextPage(loaded: 500, total: 5_000, limit: 1_000) == 500..<1_000)
        #expect(SpotlightPlan.nextPage(loaded: 1_000, total: 5_000, limit: 1_000) == nil)
        #expect(SpotlightPlan.nextPage(loaded: 40, total: 40, limit: 100) == nil)
    }

    @Test func asksForWhatAnEntryShowsAndSearches() {
        let query = SpotlightPlan.query(["Movie", "Series"])
        #expect(query.types == ["Movie", "Series"])
        #expect(query.fields == "Overview,Genres")
    }
}

struct SpotlightEntryTests {
    private func entry(_ json: String, priority: Int = 0) throws -> SpotlightEntry {
        try #require(SpotlightEntry(Samples.item(json), priority: priority, session: session))
    }

    @Test func takesMoviesShowsAndEpisodesOnly() {
        #expect(SpotlightEntity(Samples.item(#"{"Id":"m","Name":"M","Type":"Movie"}"#), session: session)?.kind == .movie)
        #expect(SpotlightEntity(Samples.item(#"{"Id":"s","Name":"S","Type":"Series"}"#), session: session)?.kind == .show)
        #expect(SpotlightEntity(Samples.item(#"{"Id":"e","Name":"E","Type":"Episode"}"#), session: session)?.kind == .episode)
        #expect(SpotlightEntity(Samples.item(#"{"Id":"b","Name":"B","Type":"BoxSet"}"#), session: session) == nil)
        #expect(SpotlightEntity(Samples.item(#"{"Id":"x","Name":"X","Type":"Season"}"#), session: session) == nil)
    }

    @Test func ranksWhatsBeingWatchedOrAFavouriteAboveWhatWasWatched() throws {
        #expect(try entry(#"{"Id":"m","Name":"M","Type":"Movie","UserData":{"IsFavorite":true}}"#).priority == 2)
        #expect(try entry(#"{"Id":"m","Name":"M","Type":"Movie","UserData":{"PlaybackPositionTicks":600000000}}"#).priority == 2)
        #expect(try entry(#"{"Id":"m","Name":"M","Type":"Movie","UserData":{"Played":true}}"#).priority == 1)
        #expect(try entry(#"{"Id":"m","Name":"M","Type":"Movie"}"#).priority == 0)
        #expect(try entry(#"{"Id":"m","Name":"M","Type":"Movie","UserData":{"Played":true}}"#, priority: 2).priority == 2)
        #expect(try entry(#"{"Id":"m","Name":"M","Type":"Movie"}"#).raised(to: 1).priority == 1)
        #expect(try entry(#"{"Id":"m","Name":"M","Type":"Movie"}"#, priority: 2).raised(to: 1).priority == 2)
    }

    @Test func fingerprintsWhatsWrittenAndItsRank() throws {
        let movie = try entry(#"{"Id":"m","Name":"Copperline","Type":"Movie","ProductionYear":2019}"#)
        #expect(movie.fingerprint == (try entry(#"{"Id":"m","Name":"Copperline","Type":"Movie","ProductionYear":2019}"#).fingerprint))
        #expect(movie.fingerprint.count == 16)
        #expect(movie.fingerprint != (try entry(#"{"Id":"m","Name":"Copperline","Type":"Movie","ProductionYear":2020}"#).fingerprint))
        #expect(movie.fingerprint != (try entry(#"{"Id":"m","Name":"Copperline","Type":"Movie","ImageTags":{"Primary":"new"},"ProductionYear":2019}"#).fingerprint))
        #expect(movie.fingerprint != movie.raised(to: 2).fingerprint)
        // Watch state alone, which Spotlight isn't given, doesn't call for a write.
        #expect(movie.fingerprint == (try entry(#"{"Id":"m","Name":"Copperline","Type":"Movie","ProductionYear":2019,"UserData":{"PlayCount":3}}"#).fingerprint))
    }
}

struct SpotlightLedgerTests {
    @Test func writesNewAndChangedEntriesAndDeletesTheOnesGone() {
        let changes = SpotlightLedger.Changes(
            from: [.movie: ["a": "1", "b": "2", "gone": "3"], .show: ["s": "4"]],
            to: [.movie: ["a": "1", "b": "changed", "c": "5"], .episode: ["e": "6"]]
        )
        #expect(changes.writes == [.movie: ["b", "c"], .episode: ["e"]])
        #expect(changes.deletions == [.movie: ["gone"], .show: ["s"]])
    }

    @Test func writesNothingWhenNothingChanged() {
        let same: [SpotlightEntity.Kind: [String: String]] = [.movie: ["a": "1"], .show: ["s": "2"]]
        #expect(SpotlightLedger.Changes(from: same, to: same) == SpotlightLedger.Changes(from: [:], to: [:]))
    }

    @Test func groupsFingerprintsByKind() {
        let grouped = SpotlightLedger.byKind([(.movie, "a", "1"), (.episode, "e", "2"), (.movie, "b", "3")])
        #expect(grouped == [.movie: ["a": "1", "b": "3"], .episode: ["e": "2"]])
    }

    @Test func roundTripsThroughJSONKeyedByKind() throws {
        var ledger = SpotlightLedger(account: SpotlightLedger.AccountKey(session.account))
        ledger.plan = .personal
        ledger.refreshedAt = Date(timeIntervalSince1970: 1_000_000)
        ledger.fingerprints = [.movie: ["a": "1"], .show: ["s": "2"]]
        let data = try JSONEncoder().encode(ledger)
        #expect(String(decoding: data, as: UTF8.self).contains(#""movie":{"a":"1"}"#))
        #expect(try JSONDecoder().decode(SpotlightLedger.self, from: data) == ledger)
    }

    @Test func countsWhatSpotlightHolds() {
        let status = SpotlightTitles.Status(serverId: "server", userId: "u", plan: .everything,
                                            counts: [.movie: 12, .show: 4, .episode: 1], refreshedAt: .now)
        #expect(status.summary == "12 movies, 4 shows, and 1 episode")
        let empty = SpotlightTitles.Status(serverId: "server", userId: "u", plan: .everything, counts: [:], refreshedAt: .now)
        #expect(empty.summary == "0 movies, 0 shows, and 0 episodes")
    }
}
#endif
