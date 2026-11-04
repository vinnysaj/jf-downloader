import AetherEngine
import CoreGraphics
import Foundation

/// A playback's scrub previews: one width of a version's thumbnails, and where each sheet of
/// them is, the server's for a stream and the saved files for a download.
nonisolated struct TrickplayTiles: Equatable, Sendable {
    let info: TrickplayInfo
    let sheets: [URL]

    /// The width the player shows previews at, in pixels: the smallest the server made at least
    /// this wide, else its widest. Downloads keep this width.
    static let preferredWidth = 320

    static func width(among available: some Collection<Int>) -> Int? {
        available.filter { $0 >= preferredWidth }.min() ?? available.max()
    }

    /// The width of the version's previews the player uses, and its layout. Nil when the server
    /// made none.
    static func info(of item: JellyfinItem, sourceId: String) -> TrickplayInfo? {
        guard let widths = item.trickplay?[sourceId] else { return nil }
        let available = widths.compactMap { Int($0.key) }
        return width(among: available).flatMap { widths[String($0)] }
    }

    /// The version's previews, with each sheet's URL from `sheet`. Nil when the server made none
    /// or a sheet has no URL, such as one a download hasn't saved yet.
    static func of(_ item: JellyfinItem, sourceId: String, sheet: (TrickplayInfo, Int) -> URL?) -> TrickplayTiles? {
        guard let info = info(of: item, sourceId: sourceId), info.sheetCount > 0 else { return nil }
        var sheets: [URL] = []
        for index in 0..<info.sheetCount {
            guard let url = sheet(info, index) else { return nil }
            sheets.append(url)
        }
        return TrickplayTiles(info: info, sheets: sheets)
    }

    /// The thumbnail for `seconds`: its sheet, and where on the sheet it is, in pixels.
    func thumbnail(at seconds: Double) -> (sheet: Int, rect: CGRect)? {
        guard info.thumbnailCount > 0, info.interval > 0, info.tileWidth > 0, seconds.isFinite else { return nil }
        let index = min(info.thumbnailCount - 1, max(0, Int(seconds * 1000) / info.interval))
        let sheet = index / info.thumbnailsPerSheet
        guard sheet < sheets.count else { return nil }
        let place = index % info.thumbnailsPerSheet
        let column = place % info.tileWidth
        let row = place / info.tileWidth
        return (sheet, CGRect(x: column * info.width, y: row * info.height, width: info.width, height: info.height))
    }
}

/// A chapter as the player lists it.
nonisolated struct ChapterMark: Equatable, Sendable, Identifiable {
    /// Its place among the item's chapters, which the server numbers its pictures by.
    let index: Int
    let start: Double
    let name: String
    let image: URL?

    var id: Int { index }

    /// How wide the player asks for chapter pictures, in pixels. Downloads keep this width.
    static let imageWidth = 480

    /// The item's chapters in order, with each picture's URL from `image`.
    static func of(_ item: JellyfinItem, image: (Int, Chapter) -> URL?) -> [ChapterMark] {
        let chapters = item.chapters ?? []
        return chapters.enumerated()
            .map { index, chapter in
                let name = chapter.name?.trimmingCharacters(in: .whitespaces) ?? ""
                return ChapterMark(index: index, start: chapter.start, name: name.isEmpty ? "Chapter \(index + 1)" : name,
                                   image: chapter.imageTag == nil ? nil : image(index, chapter))
            }
            .sorted { $0.start < $1.start }
    }

    /// The chapter playing at `seconds`.
    static func current(in chapters: [ChapterMark], at seconds: Double) -> ChapterMark? {
        chapters.last { $0.start <= seconds }
    }
}

nonisolated extension ExternalSubtitleTrack {
    /// The subtitle files the server keeps next to the version's media, with each file's URL from
    /// `file`: the server's for a stream, the saved copy for a download. Streams it has no URL for
    /// are left out. Embedded subtitles come with the media itself.
    static func of(_ source: MediaSource, file: (MediaStream, _ index: Int, _ format: String) -> URL?) -> [ExternalSubtitleTrack] {
        source.subtitleStreams.compactMap { stream in
            guard stream.isExternal == true, let index = stream.index else { return nil }
            let format = PlaybackResolver.subtitleFormat(for: stream.codec)
            guard let url = file(stream, index, format) else { return nil }
            return ExternalSubtitleTrack(
                url: url,
                name: stream.title ?? stream.displayTitle,
                language: stream.language,
                isForced: stream.isForced ?? false,
                isHearingImpaired: stream.isHearingImpaired ?? false,
                isDefault: stream.isDefault ?? false,
                formatHint: format
            )
        }
    }
}
