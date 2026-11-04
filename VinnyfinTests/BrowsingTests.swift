import Foundation
import Testing
@testable import vinnyfin

/// Cards take the watch state a playback that ended left their titles in.
struct EndedPlaybackTests {
    @Test func putsInTheWatchStateOfWhatWasPlayedOnly() {
        var played = JellyfinItem(id: "e1", name: "Episode 1", type: "Episode")
        played.overview = "Kept as the list loaded it."
        played.userData = UserItemData(playbackPositionTicks: 0)
        var show = JellyfinItem(id: "s1", name: "Show", type: "Series")
        show.userData = UserItemData(unplayedItemCount: 8)
        let other = JellyfinItem(id: "m1", name: "Movie", type: "Movie")
        let ended = EndedPlayback(count: 1, userData: [
            "e1": UserItemData(playbackPositionTicks: 1_260_000_000, playedPercentage: 33),
            "s1": UserItemData(unplayedItemCount: 7),
        ])

        let cards = ended.applied(to: [played, show, other])
        #expect(cards.map(\.id) == ["e1", "s1", "m1"])
        #expect(cards[0].resumeSeconds == 126)
        #expect(cards[0].overview == "Kept as the list loaded it.")
        #expect(cards[1].userData?.unplayedItemCount == 7)
        #expect(cards[2] == other)
    }
}

struct LibraryIndexTests {
    /// The server's counts for a list with `leading` titles before "a", `letters` titles under
    /// each letter, and `trailing` after "z".
    private static func index(leading: Int = 0, _ letters: [String: Int], trailing: Int = 0) -> LibraryIndex {
        var before: [Int] = []
        var running = leading
        for boundary in LibraryIndex.boundaries {
            before.append(running)
            running += letters[boundary.uppercased()] ?? 0
        }
        return LibraryIndex(countsBefore: before, count: running + trailing)
    }

    @Test func sectionsFollowTheServersCounts() {
        let index = Self.index(leading: 3, ["A": 5, "C": 2, "Z": 1])
        #expect(index.sections.map(\.letter) == ["#", "A", "C", "Z"])
        #expect(index.sections.map(\.range) == [0..<3, 3..<8, 8..<10, 10..<11])
    }

    @Test func namesAfterZGoLastUnderTheNumberSign() {
        let index = Self.index(["B": 2], trailing: 4)
        #expect(index.sections.map(\.letter) == ["B", "#"])
        #expect(index.sections.last?.range == 2..<6)
    }

    @Test func jumpsToTheNextLetterThatExists() {
        let index = Self.index(leading: 1, ["A": 2, "E": 3, "H": 1])
        #expect(index.section(for: "A")?.letter == "A")
        #expect(index.section(for: "B")?.letter == "E")
        #expect(index.section(for: "#")?.range == 0..<1)
        #expect(index.section(for: "Y")?.letter == "H")
        #expect(index.section(for: "?") == nil)
    }

    @Test func theNumberSignJumpsToTheEndWhenNothingComesFirst() {
        let index = Self.index(["A": 2], trailing: 2)
        #expect(index.section(for: "#")?.range == 2..<4)
    }

    @Test func countsThatDisagreeStayInOrderAndInTheList() {
        // Counted while titles were being added: a later boundary saw fewer, the total more.
        var before = Array(repeating: 10, count: LibraryIndex.boundaries.count)
        before[1] = 8
        before[26] = 40
        let index = LibraryIndex(countsBefore: before, count: 30)
        #expect(index.sections.map(\.range) == [0..<10, 10..<30])
        #expect(index.sections.map(\.letter) == ["#", "Z"])
    }

    @Test func boundariesAreTheLettersThenTheCharacterAfterZ() {
        #expect(LibraryIndex.boundaries.count == 27)
        #expect(LibraryIndex.boundaries.first == "a")
        #expect(LibraryIndex.boundaries.last == "{")
        #expect(LibraryIndex.alphabet == ["#"] + LibraryIndex.boundaries.dropLast().map { $0.uppercased() })
    }

    @Test func aLetterStartsAfterTheTitlesBeforeItsLowercaseForm() {
        #expect(LibraryIndex.boundary(for: "M") == "m")
        #expect(LibraryIndex.boundary(for: "#") == nil)
        #expect(LibraryIndex.boundary(for: "?") == nil)
    }
}

struct PageWindowTests {
    @Test func pagesCoverTheListWithAShortLastOne() {
        let window = PageWindow(pageSize: 100, count: 250)
        #expect(window.pageCount == 3)
        #expect(window.page(containing: 199) == 1)
        #expect(window.range(of: 0) == 0..<100)
        #expect(window.range(of: 2) == 200..<250)
    }

    @Test func loadsThePageOnScreenThenTheNextThenThePrevious() {
        let window = PageWindow(pageSize: 100, count: 20_000, lookahead: 2)
        #expect(window.pagesToLoad(around: 450) == [4, 5, 3, 6, 2])
    }

    @Test func staysInsideTheList() {
        let window = PageWindow(pageSize: 100, count: 250)
        #expect(window.pagesToLoad(around: 0) == [0, 1])
        #expect(window.pagesToLoad(around: 249) == [2, 1])
        #expect(PageWindow(pageSize: 100, count: 0).pagesToLoad(around: 0).isEmpty)
    }

    @Test func keepsOnlyThePagesNearTheOneOnScreen() {
        let window = PageWindow(pageSize: 100, count: 20_000, retained: 4)
        #expect(window.keeps(8, around: 400))
        #expect(window.keeps(0, around: 400))
        #expect(!window.keeps(9, around: 400))
        // However far the list scrolls, as many pages stay.
        let kept = (0..<window.pageCount).filter { window.keeps($0, around: 15_000) }
        #expect(kept.count == 9)
    }
}

struct FocusWindowTests {
    @Test func holdsTheFirstRowsAtFirst() {
        #expect(FocusWindow().range(count: 21_000, columns: 6) == 0..<360)
        #expect(FocusWindow().range(count: 40) == 0..<40)
    }

    @Test func staysPutWhileFocusIsAwayFromItsEnds() {
        var window = FocusWindow()
        window.follow(200, count: 21_000, columns: 6)
        #expect(window.start == 0)
    }

    @Test func centersOnFocusNearItsEndAndComesBackNearItsStart() {
        var window = FocusWindow()
        window.follow(300, count: 21_000, columns: 6)
        // Focus is in row 50; the window starts 30 rows before it.
        #expect(window.range(count: 21_000, columns: 6) == 120..<480)
        window.follow(125, count: 21_000, columns: 6)
        #expect(window.start == 0)
    }

    @Test func endsWithTheListsLastRow() {
        var window = FocusWindow()
        window.follow(50, count: 70)
        #expect(window.range(count: 70) == 10..<70)
        // At the list's own end there is nowhere further to go.
        window.follow(65, count: 70)
        #expect(window.start == 10)
    }

    @Test func centersOnAJumpAtTheStartOfARow() {
        var window = FocusWindow()
        window.center(on: 5_000, count: 21_000, columns: 6)
        #expect(window.start == 4_818)
        #expect(window.range(count: 21_000, columns: 6).contains(5_000))
    }
}

@MainActor
struct LoadQueueTests {
    /// Lets the queue's tasks run until they next wait.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func runsAFewAtOnceInTheOrderWanted() {
        let queue = LoadQueue<Int>(width: 2) { _ in try? await Task.sleep(for: .seconds(30)) }
        queue.want([1, 2, 3])
        #expect(queue.underWay == [1, 2])
        #expect(queue.queued == [3])
        queue.want([2, 4, 3])
        #expect(queue.queued == [3, 4])
        queue.cancelAll()
    }

    @Test func dropsAndCancelsWhatIsNoLongerWanted() {
        let queue = LoadQueue<Int>(width: 2) { _ in try? await Task.sleep(for: .seconds(30)) }
        queue.want([1, 2, 3, 4])
        queue.retain { $0 != 1 && $0 != 4 }
        #expect(queue.underWay == [2, 3])
        #expect(queue.queued.isEmpty)
        queue.cancelAll()
        #expect(queue.underWay.isEmpty)
    }

    @Test func startsTheNextAsEachFinishes() async {
        var order: [Int] = []
        let queue = LoadQueue<Int>(width: 1) { order.append($0) }
        queue.want([1, 2, 3])
        await settle()
        #expect(order == [1, 2, 3])
        #expect(queue.underWay.isEmpty)
    }

    @Test func aLoadWantedAgainAfterCancellingIsNotCutShortByTheOldOne() async {
        var runs = 0
        let queue = LoadQueue<Int>(width: 1) { _ in
            runs += 1
            try? await Task.sleep(for: runs == 1 ? .zero : .seconds(30))
        }
        queue.want([1])
        queue.retain { _ in false }
        queue.want([1])
        await settle()
        // The first run has finished; the second is still under way.
        #expect(runs == 2)
        #expect(queue.underWay == [1])
        queue.cancelAll()
    }
}

struct HomeRowsTests {
    private static func title(_ id: String, _ type: String = "Movie", genres: [String] = []) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: "Title \(id)", type: type)
        item.genres = genres
        return item
    }

    private let inputs = HomeRows.Inputs(
        watched: [title("a", genres: ["Science Fiction"]), title("b", "Series", genres: ["Drama"]),
                  title("c", genres: ["Science Fiction", "Comedy"]), title("d")],
        favorites: [title("e"), title("a")],
        movieGenres: [GenreSize(name: "Science Fiction", count: 50), GenreSize(name: "Drama", count: 100),
                      GenreSize(name: "Comedy", count: 30), GenreSize(name: "Western", count: 10), GenreSize(name: "Tiny", count: 2)],
        showGenres: [GenreSize(name: "Drama", count: 80), GenreSize(name: "Western", count: 7)]
    )

    private func rows(_ inputs: HomeRows.Inputs, seed: UInt64 = 7) -> [HomeRow] {
        var random = SeededRandom(seed: seed)
        return HomeRows.assemble(inputs, using: &random)
    }

    @Test func theSameSeedPicksTheSameRows() {
        var inputs = inputs
        inputs.favorites = (0..<10).map { Self.title("f\($0)") }
        #expect(rows(inputs, seed: 42) == rows(inputs, seed: 42))
        let picks = Set((0..<20).map { seed in rows(inputs, seed: seed).filter { $0.id.hasPrefix("moreLike.") }.map(\.id) })
        #expect(picks.count > 1, "different seeds pick different favorites")
    }

    @Test func startsWithWhatsInProgressAndNew() {
        #expect(rows(inputs).prefix(4).map(\.id) == ["continueWatching", "nextUp", "recentMovies", "recentShows"])
    }

    @Test func becauseYouWatchedTheLastFewTitles() {
        let ids = rows(inputs).map(\.id)
        #expect(ids.filter { $0.hasPrefix("becauseYouWatched.") } == ["becauseYouWatched.a", "becauseYouWatched.b", "becauseYouWatched.c"])
        // A favorite already in a Because You Watched row gets no row of its own.
        #expect(ids.filter { $0.hasPrefix("moreLike.") } == ["moreLike.e"])
    }

    @Test func genresWatchedMostComeFirstThenTheBiggest() {
        let genres = HomeRows.rankedGenres(inputs)
        #expect(genres.map { "\($0.type) \($0.name)" } == [
            "Movie Science Fiction", "Movie Drama", "Series Drama", "Movie Comedy", "Movie Western", "Series Western",
        ])
        let rowTitles = rows(inputs).filter { $0.id.hasPrefix("genre.") }.map(\.list.title)
        #expect(rowTitles.first == "Science Fiction Movies")
        #expect(!rowTitles.contains("Tiny Movies"))
    }

    @Test func somethingDifferentIsAGenreNotWatched() {
        #expect(rows(inputs).contains { $0.id == "somethingDifferent.Western" })
        var random = SeededRandom(seed: 1)
        #expect(HomeRows.differentGenre(HomeRows.Inputs(), using: &random) == nil)
    }

    @MainActor @Test func everyRowIsDistinctAndOpensAListItsGridCanSort() {
        let rows = rows(inputs)
        #expect(Set(rows.map(\.id)).count == rows.count)
        for row in rows {
            guard case .items(let query) = row.list.source else { continue }
            #expect(LibraryGridView.Sort(query) != nil, "\(row.id) sorts by \(query.sortBy)")
        }
    }

    @Test func leavesOutRowsThereIsNothingFor() {
        let ids = rows(HomeRows.Inputs()).map(\.id)
        #expect(ids == ["continueWatching", "nextUp", "recentMovies", "recentShows", "newMovies", "topMovies",
                        "newShows", "topShows", "collections", "recentlyWatched"])
    }

    @Test func episodesStandForTheirShowsOnce() {
        var first = JellyfinItem(id: "e1", name: "Pilot", type: "Episode")
        first.seriesId = "s1"
        var second = JellyfinItem(id: "e2", name: "Two", type: "Episode")
        second.seriesId = "s1"
        var orphan = JellyfinItem(id: "e3", name: "Lost", type: "Episode")
        orphan.seriesId = "gone"
        let titles = HomeRows.titles(played: [first, Self.title("m"), second, orphan],
                                     shows: [Self.title("s1", "Series", genres: ["Drama"])])
        #expect(titles.map(\.id) == ["s1", "m"])
        #expect(titles.first?.genres == ["Drama"])
    }
}
