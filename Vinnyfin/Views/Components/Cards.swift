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

/// Watched, or for a show the episodes left to watch.
struct WatchBadge: View {
    let item: JellyfinItem

    var body: some View {
        if item.isSeries, let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            Text(String(unplayed))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint, in: .capsule)
                .foregroundStyle(.white)
        } else if item.isPlayed {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .tint)
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
                Text(item.isEpisode ? (item.seriesName ?? item.name) : item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card.\(item.name)")
    }

    private var detail: String {
        if item.isEpisode {
            return [item.episodeCode, item.name].compactMap(\.self).joined(separator: " · ")
        }
        if let resume = item.resumeSeconds, let total = item.runtimeSeconds, total > resume {
            return "\(Duration.seconds(total - resume).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left"
        }
        return item.premiereYearText ?? ""
    }
}

/// A titled row of cards that scrolls sideways.
struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    let cardWidth: CGFloat
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .edgePadding()
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                    ForEach(items) { item in
                        card(item).frame(width: cardWidth)
                    }
                }
                .scrollTargetLayout()
                .edgePadding()
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
}

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
