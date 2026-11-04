import Foundation

/// The stretch of a long list Apple TV makes, around focus. On each focus move SwiftUI stands in
/// for every row not yet made in the move's direction, as far as the list goes: across a big
/// library or a long season, seconds a move. A list that holds only a window of rows around
/// focus, which follows it, pays for the window's rows alone.
nonisolated struct FocusWindow: Sendable, Equatable {
    /// Rows the window holds.
    static let rows = 60
    /// Rows from either end of the window at which it moves to put focus back in its middle.
    static let margin = 15

    /// The first position held, at the start of a row.
    private(set) var start = 0

    /// The positions held of a list of `count`, in rows of `columns`.
    func range(count: Int, columns: Int = 1) -> Range<Int> {
        min(start, count) ..< min(count, start + Self.rows * columns)
    }

    /// With focus near an end of the window that isn't the list's, centers the window on it.
    /// Call it once scrolling stops: moved mid-scroll, the window takes the focused row off
    /// screen. A scroll position anchored to the rows keeps those on screen where they are.
    mutating func follow(_ focus: Int, count: Int, columns: Int = 1) {
        let held = range(count: count, columns: columns)
        let nearStart = focus - held.lowerBound < Self.margin * columns && held.lowerBound > 0
        let nearEnd = held.upperBound - focus <= Self.margin * columns && held.upperBound < count
        if nearStart || nearEnd { center(on: focus, count: count, columns: columns) }
    }

    /// Puts `index` in the window's middle row, or as near it as the list's ends allow.
    mutating func center(on index: Int, count: Int, columns: Int = 1) {
        let lastRow = max(0, (count - 1) / columns)
        let row = min(max(0, index / columns - Self.rows / 2), max(0, lastRow - Self.rows + 1))
        start = row * columns
    }
}
