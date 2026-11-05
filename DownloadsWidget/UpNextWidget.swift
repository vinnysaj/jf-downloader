import ImageIO
import OSLog
import SwiftUI
import WidgetKit

/// What's partway through on the signed-in server, as Home's Continue Watching row lists it.
struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration { upNextConfiguration(.continueWatching) }
}

/// The next episode of each show in progress, as Home's Next Up row lists it.
struct NextUpWidget: Widget {
    var body: some WidgetConfiguration { upNextConfiguration(.nextUp) }
}

/// A widget for one of Home's rows: each title plays from where it was left.
private func upNextConfiguration(_ row: UpNextWidgets.Row) -> some WidgetConfiguration {
    StaticConfiguration(kind: row.kind, provider: UpNextProvider(row: row)) { entry in
        UpNextView(entry: entry)
            .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(row.title)
    .description(row.description)
    .supportedFamilies(upNextFamilies)
}

private var upNextFamilies: [WidgetFamily] {
    #if os(iOS)
    [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    #else
    [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    #endif
}

nonisolated struct UpNextEntry: TimelineEntry {
    var date = Date.now
    let row: UpNextWidgets.Row
    let content: UpNextWidgets.Content
}

/// One entry, the row as the server lists it now, with the pictures the widget draws: a widget
/// can't load anything once it's on screen. It asks again after a while, sooner after a failure,
/// and whenever the app has it reload.
nonisolated struct UpNextProvider: TimelineProvider {
    let row: UpNextWidgets.Row
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin.widgets", category: "UpNext")

    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(row: row, content: .tiles(Self.samples(row, count: UpNextWidgets.Layout(context.family).count)))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (UpNextEntry) -> Void) {
        guard !context.isPreview else { return completion(placeholder(in: context)) }
        let request = Request(context, row: row)
        Task { completion(await Self.entry(for: request)) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<UpNextEntry>) -> Void) {
        let request = Request(context, row: row)
        Task {
            let entry = await Self.entry(for: request)
            let refresh = UpNextWidgets.refreshDate(for: entry.content, now: entry.date)
            completion(Timeline(entries: [entry], policy: refresh.map { .after($0) } ?? .never))
        }
    }

    /// What an entry is for: the row, and the widget's family and size.
    private struct Request: Sendable {
        let row: UpNextWidgets.Row
        let layout: UpNextWidgets.Layout
        /// How wide its pictures are drawn, in pixels; nil when it draws none.
        let pictureWidth: Int?

        init(_ context: TimelineProviderContext, row: UpNextWidgets.Row) {
            self.row = row
            layout = UpNextWidgets.Layout(context.family)
            // The sharpest screen the widget may be drawn on.
            #if os(macOS)
            let fallbackScale = 2.0
            #else
            let fallbackScale = 3.0
            #endif
            let scale = context.environmentVariants.displayScale?.max().map(Double.init) ?? fallbackScale
            pictureWidth = layout.pictureWidth(inWidgetWidth: Double(context.displaySize.width), scale: scale)
        }
    }

    private static func entry(for request: Request) async -> UpNextEntry {
        // The account store lives on the main actor, as it does in the app.
        let (session, problem) = await MainActor.run {
            let accounts = AccountStore()
            return (accounts.session, accounts.savedSignInProblem)
        }
        guard let session else {
            if let problem { log.error("Can't use the saved sign-in: \(problem, privacy: .public)") }
            return UpNextEntry(row: request.row, content: problem.map { .signInProblem($0) } ?? .signedOut)
        }
        do {
            let items = try await session.client.page(of: request.row.source, userId: session.userId,
                                                      startIndex: 0, limit: request.layout.count).items
            let tiles = UpNextWidgets.tiles(from: items, limit: request.layout.count)
            guard let width = request.pictureWidth else { return UpNextEntry(row: request.row, content: .tiles(tiles)) }
            let shown = Set(tiles.map(\.itemId))
            let pictures = await pictures(of: items.filter { shown.contains($0.id) }, width: width, session: session)
            return UpNextEntry(row: request.row, content: .tiles(UpNextWidgets.withArtwork(tiles, pictures: pictures)))
        } catch {
            log.error("Couldn't load \(request.row.title, privacy: .public) from \(session.client.serverURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return UpNextEntry(row: request.row, content: UpNextWidgets.content(for: error, server: session.account.serverTitle))
        }
    }

    /// Each title's wide picture, as Home's cards show it, asked for at the width drawn and kept
    /// as a small JPEG. A title whose picture can't be had goes without.
    private static func pictures(of items: [JellyfinItem], width: Int, session: ServerSession) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self) { group in
            for item in items {
                guard let url = session.landscape(item, width: width) else { continue }
                group.addTask { (item.id, await picture(at: url, width: width)) }
            }
            var pictures: [String: Data] = [:]
            for await (itemId, picture) in group {
                pictures[itemId] = picture
            }
            return pictures
        }
    }

    private static func picture(at url: URL, width: Int) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.error("The server answered \(url, privacy: .public) with HTTP \(http.statusCode)")
                return nil
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let picture = WidgetArtwork.jpeg(from: source, maxPixelSize: width, quality: UpNextWidgets.artworkQuality)
            else {
                log.error("Couldn't read the picture at \(url, privacy: .public)")
                return nil
            }
            return picture
        } catch {
            log.error("Couldn't load the picture at \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Titles shaped like the row's, for the widget gallery and while the widget first loads.
    private static func samples(_ row: UpNextWidgets.Row, count: Int) -> [UpNextWidgets.Tile] {
        (1...count).map { number in
            var item = JellyfinItem(id: "placeholder-\(number)", name: "Episode \(number)", type: "Episode")
            item.seriesName = "A Show"
            item.parentIndexNumber = 1
            item.indexNumber = number
            if row == .continueWatching { item.userData = UserItemData(playedPercentage: Double(20 + 15 * number)) }
            return UpNextWidgets.Tile(item)
        }
    }
}

// MARK: Views

private struct UpNextView: View {
    let entry: UpNextEntry

    var body: some View {
        switch entry.content {
        case .tiles(let tiles) where !tiles.isEmpty:
            TilesView(row: entry.row, tiles: tiles)
        case .tiles:
            Notice(symbol: "checkmark.circle", message: entry.row.emptyMessage)
        case .signedOut:
            Notice(symbol: "person.crop.circle", message: "Sign in to vinnyfin to see what's up next.", short: "Sign in to vinnyfin")
        case .signInProblem(let problem):
            Notice(symbol: "person.crop.circle.badge.exclamationmark", message: "\(problem) Open vinnyfin to sign in.",
                   short: "Open vinnyfin to sign in")
        case .sessionEnded(let server):
            Notice(symbol: "person.crop.circle.badge.exclamationmark",
                   message: "Signed out of \(server). Open vinnyfin to sign in again.", short: "Signed out")
        case .unreachable(let server, let reason):
            Notice(symbol: "wifi.exclamationmark", message: "Can't reach \(server).", detail: reason, short: "Can't reach \(server)")
        }
    }
}

/// The titles: one with its picture in a small widget and side by side in the bigger ones, under
/// the row's name in the biggest; text alone on the Lock Screen.
private struct TilesView: View {
    let row: UpNextWidgets.Row
    let tiles: [UpNextWidgets.Tile]
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular: CircularView(tile: tiles[0])
        case .accessoryRectangular: RectangularView(row: row, tile: tiles[0])
        case .accessoryInline:
            Label("\(tiles[0].title) · \(tiles[0].detail)", systemImage: "play.fill")
                .widgetURL(tiles[0].playLink)
        #endif
        case .systemSmall:
            TileView(tile: tiles[0], isLarge: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .widgetURL(tiles[0].playLink)
        default:
            grid
        }
    }

    private var grid: some View {
        let layout = UpNextWidgets.Layout(family)
        let rows = stride(from: 0, to: layout.count, by: layout.columns).map { start in
            (start..<start + layout.columns).map { $0 < tiles.count ? tiles[$0] : nil }
        }
        return VStack(alignment: .leading, spacing: UpNextWidgets.Layout.spacing) {
            if layout.count > layout.columns {
                Text(row.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: UpNextWidgets.Layout.spacing) {
                    ForEach(rows[index].indices, id: \.self) { column in
                        if let tile = rows[index][column] {
                            Link(destination: tile.playLink) { TileView(tile: tile, isLarge: false) }
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A title as Home's landscape cards show it: its picture with how far through it is, its name
/// and what's next of it.
private struct TileView: View {
    let tile: UpNextWidgets.Tile
    /// Alone in a small widget, in bigger type.
    let isLarge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(data: tile.artwork)
                .overlay(alignment: .bottom) {
                    if let progress = tile.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 5)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(tile.title)
                    .font(isLarge ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .lineLimit(1)
                Text(tile.detail)
                    .font(isLarge ? .caption : .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(isLarge ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A title's picture, 16:9, or a plain tile without one.
private struct Artwork: View {
    let data: Data?

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                        .scaledToFill()
                } else {
                    Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
    }

    private var image: CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

#if os(iOS)
/// How far through the first title is, around a play symbol.
private struct CircularView: View {
    let tile: UpNextWidgets.Tile

    var body: some View {
        Group {
            if let progress = tile.progress {
                Gauge(value: progress) {
                    Image(systemName: "play.fill")
                } currentValueLabel: {
                    Image(systemName: "play.fill")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "play.fill").font(.title3)
                }
            }
        }
        .widgetURL(tile.playLink)
        .accessibilityLabel("Play \(tile.title), \(tile.detail)")
    }
}

private struct RectangularView: View {
    let row: UpNextWidgets.Row
    let tile: UpNextWidgets.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tile.title).font(.headline).lineLimit(1)
            Text(tile.detail).font(.caption).lineLimit(1)
            if let progress = tile.progress {
                ProgressView(value: progress).progressViewStyle(.linear)
            } else {
                Label(row.title, systemImage: "play.fill").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(tile.playLink)
    }
}
#endif

/// Why there are no titles to show, in place of them. A tap opens the app.
private struct Notice: View {
    let symbol: String
    let message: String
    var detail: String?
    /// The message in a few words, for the Lock Screen.
    var short: String?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol).font(.title3)
            }
            .accessibilityLabel(short ?? message)
        case .accessoryRectangular:
            Label(short ?? message, systemImage: symbol)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(short ?? message, systemImage: symbol)
        #endif
        default:
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(message).font(.caption)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
