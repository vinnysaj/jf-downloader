import Foundation

/// Items split into lettered sections for the A–Z index, by sort name ("The Matrix" under M).
nonisolated struct LibraryIndex<Item: Identifiable & Sendable>: Sendable {
    struct Section: Identifiable, Sendable {
        let letter: String
        let items: [Item]
        var id: String { letter }
    }

    /// The letters the index shows, whether or not anything starts with them.
    static var alphabet: [String] { ["#"] + (65...90).map { String(UnicodeScalar($0)!) } }

    let sections: [Section]

    /// `items` must already be sorted by `name`.
    init(_ items: [Item], name: (Item) -> String) {
        var sections: [Section] = []
        var currentLetter: String?
        var current: [Item] = []
        for item in items {
            let letter = Self.letter(for: name(item))
            if letter != currentLetter {
                if let currentLetter, !current.isEmpty { sections.append(Section(letter: currentLetter, items: current)) }
                currentLetter = letter
                current = []
            }
            current.append(item)
        }
        if let currentLetter, !current.isEmpty { sections.append(Section(letter: currentLetter, items: current)) }
        // A server's sort can put "#" titles anywhere; they go first, together.
        let numbered = sections.filter { $0.letter == "#" }.flatMap(\.items)
        let lettered = sections.filter { $0.letter != "#" }
        self.sections = (numbered.isEmpty ? [] : [Section(letter: "#", items: numbered)]) + lettered
    }

    /// The section a letter jumps to: its own, or the next one that exists.
    func section(for letter: String) -> Section? {
        let alphabet = Self.alphabet
        guard let position = alphabet.firstIndex(of: letter) else { return nil }
        for candidate in alphabet[position...] {
            if let section = sections.first(where: { $0.letter == candidate }) { return section }
        }
        return sections.last
    }

    /// The letter an item files under: its first letter without accents, or "#".
    static func letter(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US")).uppercased()
        guard let scalar = folded.unicodeScalars.first, (65...90).contains(scalar.value) else { return "#" }
        return String(scalar)
    }
}
