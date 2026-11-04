import Foundation
import Observation

/// A list from the server of any length, loaded a page at a time around what's on screen: it
/// opens with its first page, holds a few pages however long it is, and sorted by name learns
/// where each letter starts without loading the rest.
@MainActor @Observable
final class PagedItems {
    static let pageSize = 100
    /// Requests at once, for pages and for the letter counts.
    static let width = 3

    let source: JellyfinClient.ItemSource
    /// The length of the list, once the first page is in.
    private(set) var count: Int?
    /// Where each letter starts, for a list sorted by name, once the server has counted.
    private(set) var index: LibraryIndex?
    /// Why the list, a page of it or its index couldn't be loaded.
    private(set) var problem: String?
    private var pages: [Int: [JellyfinItem]] = [:]

    @ObservationIgnored private let client: JellyfinClient
    @ObservationIgnored private let userId: String
    @ObservationIgnored private var window: PageWindow?
    @ObservationIgnored private var lastShown = 0
    /// Pages that failed, left alone until `retry()` so scrolling doesn't keep asking for them.
    @ObservationIgnored private var failed: Set<Int> = []
    @ObservationIgnored private var isCancelled = false
    @ObservationIgnored private var indexing: Task<Void, Never>?
    @ObservationIgnored private lazy var queue = LoadQueue<Int>(width: Self.width) { [weak self] page in
        await self?.loadPage(page)
    }

    init(source: JellyfinClient.ItemSource, client: JellyfinClient, userId: String) {
        self.source = source
        self.client = client
        self.userId = userId
    }

    /// Whether the list is in name order, so an A–Z index can jump through it.
    var isSortedByName: Bool {
        guard case .items(let query) = source else { return false }
        return query.sortBy == "SortName" && query.ascending
    }

    /// The item at a position, or nil while its page isn't loaded.
    func item(at index: Int) -> JellyfinItem? {
        guard let window else { return nil }
        let page = window.page(containing: index)
        guard let items = pages[page] else { return nil }
        let offset = index - window.range(of: page).lowerBound
        return items.indices.contains(offset) ? items[offset] : nil
    }

    /// The first page, which says how long the list is; sorted by name, the index then loads
    /// behind it. What goes wrong is kept in `problem`; cancelled, the list stays empty.
    func load() async {
        do {
            let page = try await client.page(of: source, userId: userId, startIndex: 0, limit: Self.pageSize)
            window = PageWindow(pageSize: Self.pageSize, count: page.totalRecordCount)
            pages = [0: page.items]
            count = page.totalRecordCount
            problem = nil
            loadIndex()
        } catch {
            if !error.isCancellation { problem = error.localizedDescription }
        }
    }

    /// For a list sorted by name, where each letter starts: the server counts the titles before
    /// each, a few counts at a time, while the list is already on screen.
    private func loadIndex() {
        guard isSortedByName, index == nil, !isCancelled else { return }
        indexing?.cancel()
        indexing = Task { await countLetters() }
    }

    private func countLetters() async {
        guard isSortedByName, case .items(let query) = source, let count else { return }
        let client = client
        let userId = userId
        let queries = LibraryIndex.boundaries.map { boundary in
            var counting = query
            counting.nameLessThan = boundary
            return counting
        }
        do {
            let counts = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                var counts = Array(repeating: 0, count: queries.count)
                var pending = queries.enumerated().makeIterator()
                for _ in 0..<Self.width {
                    guard let (position, counting) = pending.next() else { break }
                    group.addTask { (position, try await client.count(userId: userId, counting)) }
                }
                while let (position, value) = try await group.next() {
                    counts[position] = value
                    if let (position, counting) = pending.next() {
                        group.addTask { (position, try await client.count(userId: userId, counting)) }
                    }
                }
                return counts
            }
            index = LibraryIndex(countsBefore: counts, count: count)
        } catch {
            if !error.isCancellation { problem = "Couldn't load the index: \(error.localizedDescription)" }
        }
    }

    /// Where a letter's titles start, or the next letter's if it has none: from the index once
    /// it's in, counted on the spot before then. Nil if it can't be found out; why is in `problem`.
    func start(of letter: String) async -> Int? {
        if let index { return index.section(for: letter)?.range.lowerBound }
        guard isSortedByName, case .items(var query) = source, let count, count > 0 else { return nil }
        guard let boundary = LibraryIndex.boundary(for: letter) else { return 0 }
        query.nameLessThan = boundary
        do {
            // Nothing from this letter on: the jump goes to the end.
            return min(try await client.count(userId: userId, query), count - 1)
        } catch {
            if !error.isCancellation { problem = "Couldn't find \(letter): \(error.localizedDescription)" }
            return nil
        }
    }

    /// A position came on screen: loads the pages around it and lets go of those far from it.
    func show(_ index: Int) {
        guard let window, !isCancelled else { return }
        lastShown = index
        queue.retain { window.keeps($0, around: index) }
        queue.want(window.pagesToLoad(around: index).filter { pages[$0] == nil && !failed.contains($0) })
        for page in pages.keys where !window.keeps(page, around: index) {
            pages.removeValue(forKey: page)
        }
    }

    /// Asks again for what failed: pages around what's on screen, and the index.
    func retry() {
        failed.removeAll()
        problem = nil
        show(lastShown)
        loadIndex()
    }

    /// Swaps in an item whose watch state changed.
    func replace(_ item: JellyfinItem) {
        for (page, items) in pages {
            if let position = items.firstIndex(where: { $0.id == item.id }) {
                pages[page]?[position] = item
            }
        }
    }

    /// Stops loading: the list is being replaced.
    func cancel() {
        isCancelled = true
        queue.cancelAll()
        indexing?.cancel()
    }

    private func loadPage(_ page: Int) async {
        guard let window else { return }
        let range = window.range(of: page)
        do {
            let result = try await client.page(of: source, userId: userId, startIndex: range.lowerBound, limit: range.count)
            // Scrolled far away meanwhile: the page would be let go at once.
            guard !isCancelled, window.keeps(page, around: lastShown) else { return }
            pages[page] = result.items
        } catch {
            guard !error.isCancellation else { return }
            failed.insert(page)
            problem = error.localizedDescription
        }
    }
}
