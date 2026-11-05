#if !os(tvOS)
import Foundation

/// The parts of Jellyfin's HLS playlists a transcoded download reads. Its media playlist lists
/// every piece of the transcode up front, with the header piece (EXT-X-MAP) first; the pieces'
/// addresses are relative to the playlist's.
nonisolated struct HLSPlaylist: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let duration: Double
        let uri: String
    }

    /// A multivariant playlist's first variant, and what it says of it.
    var variantURI: String?
    var variantAttributes: String?
    /// The init segment's address.
    var mapURI: String?
    var targetDuration: Double?
    var segments: [Segment] = []
    /// EXT-X-ENDLIST: the list is complete.
    var isComplete = false

    init(_ text: String) {
        var pendingDuration: Double?
        var expectsVariant = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    expectsVariant = variantURI == nil
                    if expectsVariant { variantAttributes = String(line.dropFirst("#EXT-X-STREAM-INF:".count)) }
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    mapURI = Self.attribute("URI", in: String(line.dropFirst("#EXT-X-MAP:".count)))
                } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                    targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
                } else if line.hasPrefix("#EXTINF:") {
                    let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                    pendingDuration = Double(value.trimmingCharacters(in: .whitespaces))
                } else if line == "#EXT-X-ENDLIST" {
                    isComplete = true
                }
                continue
            }
            if expectsVariant {
                variantURI = line
                expectsVariant = false
            } else if let duration = pendingDuration {
                segments.append(Segment(duration: duration, uri: line))
                pendingDuration = nil
            }
        }
    }

    /// An attribute's value in an attribute list, unquoted.
    static func attribute(_ name: String, in list: String) -> String? {
        var remainder = Substring(list)
        while !remainder.isEmpty {
            guard let equals = remainder.firstIndex(of: "=") else { return nil }
            let key = remainder[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            var rest = remainder[remainder.index(after: equals)...]
            let value: Substring
            if rest.first == "\"" {
                rest = rest.dropFirst()
                let close = rest.firstIndex(of: "\"") ?? rest.endIndex
                value = rest[..<close]
                remainder = close < rest.endIndex ? rest[rest.index(after: close)...] : ""
            } else {
                let comma = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<comma]
                remainder = rest[comma...]
            }
            if key == name { return String(value) }
        }
        return nil
    }

    /// The value of a query parameter in an address the server handed out, case-insensitively.
    static func queryValue(_ name: String, in uri: String) -> String? {
        URLComponents(string: uri)?.queryItems?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
#endif
