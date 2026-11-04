import Foundation

/// Where each letter's titles start in a list sorted by name, for the A–Z index, worked out from
/// the server's counts of the titles that sort before each letter, so the list needn't be loaded.
///
/// The server sorts by sort name: lowercased, without accents or a leading article ("The Matrix"
/// under M). Names starting with a digit or a symbol before "a" come first, under "#"; names
/// after "z", in other scripts, come last, under "#" too.
nonisolated struct LibraryIndex: Sendable, Equatable {
    struct Section: Sendable, Equatable {
        let letter: String
        /// Positions in the list.
        let range: Range<Int>
    }

    /// The letters the index shows, whether or not anything starts with them.
    static var alphabet: [String] { ["#"] + letters.map { $0.uppercased() } }

    /// What to ask the server to count the titles before: "a" to "z", then "{", the character
    /// after "z", which ends Z's section.
    static let boundaries = letters + ["{"]

    private static let letters = (UInt8(ascii: "a")...UInt8(ascii: "z")).map { String(UnicodeScalar($0)) }

    /// In list order; letters without titles have none.
    let sections: [Section]

    /// `countsBefore` holds, for each of `boundaries`, how many titles sort before it; `count`
    /// is the length of the list.
    init(countsBefore: [Int], count: Int) {
        precondition(countsBefore.count == Self.boundaries.count, "one count for each boundary")
        // Counts taken one at a time can disagree a little if the library changes meanwhile.
        var starts: [Int] = []
        for value in countsBefore {
            starts.append(min(count, max(starts.last ?? 0, value)))
        }
        let ranges = [0..<starts[0]]
            + Self.letters.indices.map { starts[$0]..<starts[$0 + 1] }
            + [starts[Self.letters.count]..<count]
        let letters = ["#"] + Self.letters.map { $0.uppercased() } + ["#"]
        sections = zip(letters, ranges).filter { !$0.1.isEmpty }.map { Section(letter: $0.0, range: $0.1) }
    }

    /// What to count the titles before to find where a letter starts; nil for "#", which starts
    /// the list.
    static func boundary(for letter: String) -> String? {
        let lowercased = letter.lowercased()
        return letters.contains(lowercased) ? lowercased : nil
    }

    /// The section a letter jumps to: its own, or the next one that exists. "#" goes to the
    /// titles before "a", or failing those to the ones after "z".
    func section(for letter: String) -> Section? {
        let alphabet = Self.alphabet
        guard let position = alphabet.firstIndex(of: letter) else { return nil }
        for candidate in alphabet[position...] {
            if let section = sections.first(where: { $0.letter == candidate }) { return section }
        }
        return sections.last
    }
}
