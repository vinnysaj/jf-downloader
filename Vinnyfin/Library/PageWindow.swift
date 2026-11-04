import Foundation

/// Which pages of a long list to have: the one on screen and its neighbours, loaded nearest
/// first, and none far from it, so memory stays the same however long the list is.
nonisolated struct PageWindow: Sendable, Equatable {
    let pageSize: Int
    /// The length of the list.
    let count: Int
    /// Pages either side of the one on screen to load ahead of scrolling.
    var lookahead = 1
    /// Pages either side of the one on screen to keep; the rest are let go.
    var retained = 4

    var pageCount: Int { (count + pageSize - 1) / pageSize }

    func page(containing index: Int) -> Int { index / pageSize }

    func range(of page: Int) -> Range<Int> {
        page * pageSize ..< min(count, (page + 1) * pageSize)
    }

    /// The pages to load with `index` on screen, nearest first and the next before the previous,
    /// since lists are mostly scrolled forward.
    func pagesToLoad(around index: Int) -> [Int] {
        let center = page(containing: index)
        var pages = [center]
        for distance in stride(from: 1, through: lookahead, by: 1) {
            pages += [center + distance, center - distance]
        }
        return pages.filter { (0..<pageCount).contains($0) }
    }

    /// Whether to keep `page` with `index` on screen.
    func keeps(_ page: Int, around index: Int) -> Bool {
        abs(page - self.page(containing: index)) <= retained
    }
}
