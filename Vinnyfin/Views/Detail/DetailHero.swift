import SwiftUI

/// The top of a detail screen: the backdrop full width, fading into the page, with the title
/// (as its logo when there is one), the facts line and the actions over it.
struct DetailHero<Actions: View>: View {
    let item: JellyfinItem
    var eyebrow: String?
    var badgesSource: MediaSource?
    @ViewBuilder let actions: () -> Actions

    @Environment(\.session) private var session
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: backdropURL, aspectRatio: nil, cornerRadius: 0, placeholder: item.isSeries ? "tv" : "film")
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .horizontal)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.35),
                            .init(color: Color.pageBackground.opacity(0.75), location: 0.7),
                            .init(color: Color.pageBackground, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            VStack(alignment: .leading, spacing: 10) {
                if let eyebrow {
                    Text(eyebrow).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                title
                Text(Self.facts(for: item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let badgesSource { MediaBadges(source: badgesSource) }
                actions()
                    .padding(.top, 4)
            }
            .edgePadding()
            .padding(.bottom, 8)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var heroHeight: CGFloat {
        #if os(tvOS)
        760
        #elseif os(macOS) || os(visionOS)
        460
        #else
        440
        #endif
    }

    private var backdropURL: URL? {
        #if !os(tvOS)
        if let saved = downloads.artworkURL(itemId: item.id, kind: .backdrop), session == nil || !downloads.isNetworkReachable {
            return saved
        }
        #endif
        return session?.backdrop(item) ?? session?.landscape(item)
    }

    @ViewBuilder private var title: some View {
        if let logo = session?.logo(item, width: 900) {
            Artwork(url: logo, aspectRatio: nil, cornerRadius: 0, placeholder: "", contentMode: .fit)
                .frame(maxWidth: logoWidth, maxHeight: logoHeight, alignment: .leading)
                .accessibilityLabel(item.isEpisode ? (item.seriesName ?? item.name) : item.name)
            if item.isEpisode {
                Text(item.name).font(.title2.weight(.bold))
            }
        } else {
            Text(item.name)
                .font(.largeTitle.weight(.bold))
                .lineLimit(3)
                .minimumScaleFactor(0.7)
        }
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        620
        #else
        320
        #endif
    }

    private var logoHeight: CGFloat {
        #if os(tvOS)
        200
        #else
        110
        #endif
    }

    /// "2024 · PG-13 · 2h 9m · ★ 7.8 · Action, Drama"
    static func facts(for item: JellyfinItem) -> String {
        var parts: [String] = []
        if item.isEpisode, let code = item.episodeCode { parts.append(code) }
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.officialRating { parts.append(rating) }
        if item.isSeries, let count = item.childCount { parts.append(count == 1 ? "1 Season" : "\(count) Seasons") }
        if !item.isSeries, let runtime = item.runtimeText { parts.append(runtime) }
        if let score = item.communityRating { parts.append("★ \(score.formatted(.number.precision(.fractionLength(1))))") }
        if let genres = item.genres?.prefix(3), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

extension Color {
    /// The page behind content, which hero artwork fades into.
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
        // Black like a theater in the dark, rather than the system's gray.
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
        #elseif os(visionOS)
        Color.black
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// The overview, with the tagline above it.
struct OverviewText: View {
    let item: JellyfinItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tagline = item.taglines?.first, !tagline.isEmpty {
                Text(tagline).font(.headline)
            }
            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 4)
                    #if !os(tvOS)
                    .onTapGesture { withAnimation { expanded.toggle() } }
                    #endif
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
    }
}

/// The cast, with their pictures.
struct CastShelf: View {
    let people: [Person]
    @Environment(\.session) private var session

    var body: some View {
        let cast = people.filter { $0.type == "Actor" || $0.type == "GuestStar" }.prefix(20)
        if !cast.isEmpty {
            Shelf(title: "Cast", items: Array(cast), cardWidth: castWidth) { person in
                VStack(spacing: 6) {
                    Artwork(url: session?.person(person), aspectRatio: 1, cornerRadius: castWidth / 2, placeholder: "person.fill")
                    Text(person.name).font(.caption.weight(.medium)).lineLimit(1)
                    if let role = person.role, !role.isEmpty {
                        Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                #if os(tvOS)
                .focusable()
                #endif
            }
        }
    }

    private var castWidth: CGFloat {
        #if os(tvOS)
        160
        #else
        88
        #endif
    }
}
