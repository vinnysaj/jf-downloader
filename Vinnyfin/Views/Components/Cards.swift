import SwiftUI

/// Sizes that differ by how far away the screen is.
enum Metrics {
    #if os(tvOS)
    static let posterWidth: CGFloat = 230
    static let landscapeWidth: CGFloat = 470
    static let gridSpacing: CGFloat = 48
    static let edge: CGFloat = 80
    #elseif os(visionOS)
    static let posterWidth: CGFloat = 170
    static let landscapeWidth: CGFloat = 330
    static let gridSpacing: CGFloat = 24
    static let edge: CGFloat = 32
    #elseif os(macOS)
    static let posterWidth: CGFloat = 160
    static let landscapeWidth: CGFloat = 300
    static let gridSpacing: CGFloat = 20
    static let edge: CGFloat = 24
    #else
    static let posterWidth: CGFloat = 116
    static let landscapeWidth: CGFloat = 270
    static let gridSpacing: CGFloat = 14
    static let edge: CGFloat = 16
    #endif

    /// The player's controls from the screen's sides, inside the safe area. A TV's safe area is
    /// already its overscan margin.
    static var playerInset: CGFloat {
        #if os(tvOS)
        0
        #else
        edge
        #endif
    }
}

/// A poster with its title, watch state and download state.
struct PosterCard: View {
    let item: JellyfinItem
    var showsTitle = true
    @Environment(\.session) private var session
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: session?.poster(item), aspectRatio: 2.0 / 3.0, placeholder: item.isSeries ? "tv" : "film")
                .overlay(alignment: .topTrailing) { WatchBadge(item: item).padding(6) }
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressBar(fraction: progress).padding(6)
                    }
                }
                #if !os(tvOS)
                .overlay(alignment: .bottomLeading) {
                    if item.progress == nil, downloads.isDownloaded(item.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .font(.callout)
                            .padding(6)
                            .accessibilityLabel("Downloaded")
                    }
                }
                #endif
            if showsTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.caption.weight(.medium)).lineLimit(1)
                    if let year = item.premiereYearText {
                        Text(year).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("poster.\(item.name)")
    }
}

/// Watched, or for a show the episodes left to watch: white on blue, the tint elsewhere. Apple
/// TV's tint and accent color are white, which hid the badge's white text and checkmark.
struct WatchBadge: View {
    let item: JellyfinItem

    var body: some View {
        if item.isSeries, let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            Text(String(unplayed))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue, in: .capsule)
                .foregroundStyle(.white)
        } else if item.isPlayed {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .blue)
                .font(.callout)
                .accessibilityLabel("Watched")
        }
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.black.opacity(0.45))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("\(Int(fraction * 100))% watched")
    }
}

/// A 16:9 card for Continue Watching and Next Up: the episode's still, its show and number.
struct LandscapeCard: View {
    let item: JellyfinItem
    @Environment(\.session) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: session?.landscape(item), aspectRatio: 16.0 / 9.0, placeholder: "play.rectangle")
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressBar(fraction: progress).padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.titleName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.cardDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card.\(item.name)")
    }
}

extension BrowseList.Style {
    var cardWidth: CGFloat { self == .poster ? Metrics.posterWidth : Metrics.landscapeWidth }
}

/// The shape of a card while its title loads, the size of the card it stands for.
struct CardPlaceholder: View {
    let style: BrowseList.Style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(style == .poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                .background(.quaternary, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("A Title Loading").font(style == .poster ? .caption.weight(.medium) : .subheadline.weight(.medium))
                Text("2000").font(style == .poster ? .caption2 : .caption)
            }
            .redacted(reason: .placeholder)
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// A titled row of cards that scrolls sideways. With a list to see all of, its title leads
/// there; on Apple TV, where focus moves along the cards, a card at the row's end does.
struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    var seeAll: BrowseList?
    let items: [Item]
    let cardWidth: CGFloat
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, Metrics.edge)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                    ForEach(items) { item in
                        card(item).frame(width: cardWidth)
                    }
                    #if os(tvOS)
                    if let seeAll {
                        NavigationLink(value: seeAll) { SeeAllCard(style: seeAll.style) }
                            .buttonStyle(.artwork)
                            .frame(width: cardWidth)
                            .accessibilityIdentifier("shelf.\(title).all")
                    }
                    #endif
                }
                .scrollTargetLayout()
                .padding(.horizontal, Metrics.edge)
                #if os(tvOS)
                .padding(.vertical, 30)
                #endif
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    @ViewBuilder private var header: some View {
        let text = Text(title).font(.title3.weight(.semibold))
        #if os(tvOS)
        text
        #else
        if let seeAll {
            NavigationLink(value: seeAll) {
                HStack(spacing: 4) {
                    text
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows all of them")
            .accessibilityIdentifier("shelf.\(title)")
        } else {
            text
        }
        #endif
    }
}

/// A row's title and the shapes of its cards while they load, as tall as the row will be.
struct ShelfPlaceholder: View {
    private struct Slot: Identifiable {
        let id: Int
    }

    let title: String
    let style: BrowseList.Style

    var body: some View {
        Shelf(title: title, items: (0..<8).map(Slot.init), cardWidth: style.cardWidth) { _ in
            CardPlaceholder(style: style)
                #if os(tvOS)
                // Holds focus while the row loads, so it goes to Home rather than the sidebar.
                .focusable()
                #endif
        }
        #if !os(tvOS)
        // On Apple TV that would keep focus from the cards too.
        .scrollDisabled(true)
        #endif
    }
}

#if os(tvOS)
/// The end of an Apple TV row: opens the whole list.
private struct SeeAllCard: View {
    let style: BrowseList.Style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(style == .poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                .background(.quaternary, in: .rect(cornerRadius: 10))
                .overlay {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                }
            Text("See All").font(.caption.weight(.medium))
        }
        .contentShape(.rect)
    }
}
#endif

/// What a version offers: 4K, HDR, Dolby Vision, Atmos, surround.
struct MediaBadges: View {
    let source: MediaSource

    var body: some View {
        let badges = Self.badges(for: source)
        if !badges.isEmpty {
            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func badges(for source: MediaSource) -> [String] {
        var badges: [String] = []
        switch VersionTraits(source).resolutionClass {
        case let height? where height >= 2160: badges.append("4K")
        case let height? where height >= 1080: badges.append("HD")
        default: break
        }
        let range = source.videoStream?.videoRangeType?.uppercased() ?? ""
        let name = (source.name ?? "").uppercased()
        if range.hasPrefix("DOVI") || name.contains("DOLBY VISION") || name.contains(" DV") {
            badges.append("Dolby Vision")
        } else if range.contains("HDR10PLUS") || name.contains("HDR10+") {
            badges.append("HDR10+")
        } else if range.contains("HDR") || name.contains("HDR") {
            badges.append("HDR")
        } else if range.contains("HLG") {
            badges.append("HLG")
        }
        let audio = source.audioStreams.first
        let audioText = [audio?.audioSpatialFormat, audio?.profile, audio?.displayTitle, source.name].compactMap(\.self).joined(separator: " ").lowercased()
        if audioText.contains("atmos") {
            badges.append("Atmos")
        } else if audioText.contains("dts:x") || audioText.contains("dtsx") {
            badges.append("DTS:X")
        }
        if let channels = audio?.channels, channels >= 6 {
            badges.append(channels >= 8 ? "7.1" : "5.1")
        }
        return badges
    }
}
