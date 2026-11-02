import Foundation

/// A set of byte ranges, kept sorted with overlapping and touching ranges merged.
nonisolated struct ByteRanges: Codable, Equatable, Sendable {
    private(set) var ranges: [Range<Int64>] = []

    init(_ ranges: [Range<Int64>] = []) {
        for range in ranges { insert(range) }
    }

    var byteCount: Int64 {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<Int64>] = []
        for existing in ranges {
            if existing.upperBound < merged.lowerBound || existing.lowerBound > merged.upperBound {
                kept.append(existing)
            } else {
                merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        kept.sort { $0.lowerBound < $1.lowerBound }
        ranges = kept
    }

    func covers(_ range: Range<Int64>) -> Bool {
        range.isEmpty || ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    /// The first stretch of `bounds` covered neither by this set nor by `claimed`.
    func firstGap(in bounds: Range<Int64>, excluding claimed: [Range<Int64>]) -> Range<Int64>? {
        var covered = self
        for range in claimed { covered.insert(range) }
        var cursor = bounds.lowerBound
        for range in covered.ranges where range.upperBound > cursor {
            if range.lowerBound > cursor { break }
            cursor = range.upperBound
        }
        guard cursor < bounds.upperBound else { return nil }
        let next = covered.ranges.first { $0.lowerBound > cursor }?.lowerBound ?? bounds.upperBound
        return cursor..<min(next, bounds.upperBound)
    }
}

extension Range<Int64> {
    nonisolated var count64: Int64 { upperBound - lowerBound }
}
