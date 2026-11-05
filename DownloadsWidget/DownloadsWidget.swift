import ImageIO
import OSLog
import SwiftUI
import WidgetKit

/// What's downloading and how far along, and what's ready to watch offline. A download opens
/// its title's page; a title that's ready plays.
struct DownloadsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DownloadsSnapshot.widgetKind, provider: Provider()) { entry in
            DownloadsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Downloads")
        .description("What's downloading, and what's ready to watch offline.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }

    struct Entry: TimelineEntry {
        var date = Date.now
        var snapshot: DownloadsSnapshot?
        /// Why the snapshot couldn't be read.
        var failure: String?
    }

    /// One entry, the snapshot as it is: the app reloads the widget whenever it writes a new one.
    struct Provider: TimelineProvider {
        private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin.widgets", category: "Downloads")

        func placeholder(in context: Context) -> Entry {
            Entry(snapshot: .placeholder)
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(context.isPreview ? Entry(snapshot: .placeholder) : Self.entry())
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Self.entry()], policy: .never))
        }

        private static func entry() -> Entry {
            do {
                return Entry(snapshot: try DownloadsSnapshot.load())
            } catch {
                log.error("Couldn't read the downloads snapshot: \(error.localizedDescription, privacy: .public)")
                return Entry(failure: "Open vinnyfin to update its downloads.")
            }
        }
    }
}

private struct DownloadsWidgetView: View {
    let entry: DownloadsWidget.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            #if os(iOS)
            case .accessoryCircular: CircularView(snapshot: snapshot)
            case .accessoryRectangular: RectangularView(snapshot: snapshot)
            case .accessoryInline: Text(snapshot.line)
            #endif
            case .systemSmall: SmallView(snapshot: snapshot)
            default: ListView(snapshot: snapshot, rows: family == .systemLarge ? DownloadsSnapshot.listLimit * 2 : 2)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").font(.title2)
                Text(entry.failure ?? "Downloads show here.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// The download under way, or else the newest title ready to watch.
private struct SmallView: View {
    let snapshot: DownloadsSnapshot

    var body: some View {
        if let download = snapshot.current {
            VStack(alignment: .leading, spacing: 6) {
                TitleArtwork(title: download.title).frame(width: 40, height: 40)
                Spacer(minLength: 0)
                TitleText(title: download.title)
                DownloadProgress(download: download, more: snapshot.unfinishedCount - 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(download.title.openLink)
        } else if let title = snapshot.ready.first {
            VStack(alignment: .leading, spacing: 6) {
                TitleArtwork(title: title).frame(width: 40, height: 40)
                Spacer(minLength: 0)
                TitleText(title: title)
                Label(snapshot.readyCount > 1 ? "Play · \(snapshot.readyCount - 1) more ready" : "Play",
                      systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(title.playLink)
        } else {
            Nothing()
        }
    }
}

/// The downloads, then the titles ready to watch, as many as fit.
private struct ListView: View {
    let snapshot: DownloadsSnapshot
    let rows: Int

    var body: some View {
        let downloads = Array(snapshot.downloads.prefix(snapshot.ready.isEmpty ? rows : max(1, rows / 2)))
        let ready = Array(snapshot.ready.prefix(rows - downloads.count))
        if downloads.isEmpty && ready.isEmpty {
            Nothing()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(downloads) { download in
                    Link(destination: download.title.openLink) {
                        Row(title: download.title) { DownloadProgress(download: download, more: nil) }
                    }
                }
                if !downloads.isEmpty, !ready.isEmpty { Divider() }
                ForEach(ready) { title in
                    Link(destination: title.playLink) {
                        Row(title: title) {
                            Label("Ready to watch", systemImage: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private struct Row<Detail: View>: View {
        let title: DownloadsSnapshot.Title
        @ViewBuilder var detail: () -> Detail

        var body: some View {
            HStack(spacing: 10) {
                TitleArtwork(title: title).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    TitleText(title: title, lines: 1)
                    detail()
                }
            }
        }
    }
}

#if os(iOS)
private struct CircularView: View {
    let snapshot: DownloadsSnapshot

    var body: some View {
        if let download = snapshot.current, snapshot.isRunning {
            Gauge(value: Double(download.percent ?? 0), in: 0...100) {
                Image(systemName: "arrow.down")
            } currentValueLabel: {
                Text(download.percent.map { "\($0)" } ?? "–")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetURL(download.title.openLink)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: snapshot.unfinishedCount > 0 ? "pause.fill" : "play.fill")
                    Text("\(snapshot.readyCount)").font(.headline)
                }
            }
            .widgetURL(snapshot.ready.first?.playLink)
        }
    }
}

private struct RectangularView: View {
    let snapshot: DownloadsSnapshot

    var body: some View {
        if let download = snapshot.current {
            VStack(alignment: .leading, spacing: 2) {
                Label("Downloading", systemImage: "arrow.down.circle").font(.caption2)
                Text(download.title.title).font(.headline).lineLimit(1)
                DownloadProgress(download: download, more: snapshot.unfinishedCount - 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(download.title.openLink)
        } else if let title = snapshot.ready.first {
            VStack(alignment: .leading, spacing: 2) {
                Label("Ready to watch", systemImage: "play.circle").font(.caption2)
                Text(title.title).font(.headline).lineLimit(1)
                if let subtitle = title.subtitle { Text(subtitle).font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(title.playLink)
        } else {
            Label("No downloads", systemImage: "arrow.down.circle")
        }
    }
}
#endif

private struct Nothing: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.circle").font(.title2)
            Text("Nothing downloading or ready to watch.")
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TitleText: View {
    let title: DownloadsSnapshot.Title
    var lines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.title).font(.subheadline.weight(.semibold)).lineLimit(lines)
            if let subtitle = title.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// How far along, as a bar while it downloads, and how it stands.
private struct DownloadProgress: View {
    let download: DownloadsSnapshot.Download
    /// How many more downloads to mention after it.
    let more: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if download.state == .downloading, let percent = download.percent {
                ProgressView(value: Double(percent), total: 100)
            }
            Text([state, more.flatMap { $0 > 0 ? "\($0) more" : nil }].compactMap(\.self).joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var state: String {
        let percent = download.percent.map { "\($0)%" }
        return switch download.state {
        case .downloading: download.progress ?? "Downloading"
        case .queued: download.progress.map { "Waiting · \($0)" } ?? "Waiting"
        case .held: "Waits while you watch"
        case .waitingForNetwork: "Waiting for network"
        case .waiting: download.wait ?? "Waiting"
        case .paused: percent.map { "Paused · \($0)" } ?? "Paused"
        case .failed: "Stopped"
        }
    }
}

/// The title's picture as the app saved it in the app group, or a plain tile.
private struct TitleArtwork: View {
    let title: DownloadsSnapshot.Title

    var body: some View {
        // The tile takes the frame it's given; the picture fills it and is cut to it.
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: title.type == "Episode" ? "tv" : "film").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
    }

    private var image: CGImage? {
        guard title.hasArtwork, let file = DownloadsSnapshot.artworkFile(for: title.itemId),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private extension DownloadsSnapshot {
    static var placeholder: DownloadsSnapshot {
        var snapshot = DownloadsSnapshot()
        let pilot = Title(itemId: "placeholder-1", type: "Episode", name: "Pilot", title: "Pilot", subtitle: "S1 E1")
        let movie = Title(itemId: "placeholder-2", type: "Movie", name: "A Movie", title: "A Movie", subtitle: nil)
        snapshot.downloads = [Download(title: pilot, state: .downloading, percent: 45)]
        snapshot.unfinishedCount = 1
        snapshot.activeCount = 1
        snapshot.ready = [movie]
        snapshot.readyCount = 1
        return snapshot
    }
}
