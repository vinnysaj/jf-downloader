import Nuke
import NukeUI
import SwiftUI

/// The signed-in server, for the screens that browse it.
struct ServerSession {
    let client: JellyfinClient
    let account: AccountStore.Account

    var userId: String { account.userId }

    func poster(_ item: JellyfinItem, width: Int = 400) -> URL? {
        if item.isEpisode, item.primaryImageTag == nil, let seriesId = item.seriesId {
            return client.imageURL(itemId: seriesId, tag: item.seriesPrimaryImageTag, maxWidth: width)
        }
        return client.imageURL(itemId: item.id, tag: item.primaryImageTag, maxWidth: width)
    }

    /// The show's poster for an episode, the item's own otherwise.
    func seriesPoster(_ item: JellyfinItem, width: Int = 400) -> URL? {
        guard item.isEpisode, let seriesId = item.seriesId else { return poster(item, width: width) }
        return client.imageURL(itemId: seriesId, tag: item.seriesPrimaryImageTag, maxWidth: width)
    }

    func backdrop(_ item: JellyfinItem, width: Int = 1920) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return client.imageURL(itemId: item.id, kind: .backdrop, tag: tag, maxWidth: width)
        }
        if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return client.imageURL(itemId: parent, kind: .backdrop, tag: tag, maxWidth: width)
        }
        return nil
    }

    /// A wide picture for a landscape card: an episode's still, else a thumb or backdrop.
    func landscape(_ item: JellyfinItem, width: Int = 800) -> URL? {
        if item.isEpisode, let tag = item.primaryImageTag {
            return client.imageURL(itemId: item.id, tag: tag, maxWidth: width)
        }
        if let tag = item.imageTags?["Thumb"] {
            return client.imageURL(itemId: item.id, kind: .thumb, tag: tag, maxWidth: width)
        }
        if let parent = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return client.imageURL(itemId: parent, kind: .thumb, tag: tag, maxWidth: width)
        }
        return backdrop(item, width: width) ?? poster(item, width: width)
    }

    func logo(_ item: JellyfinItem, width: Int = 800) -> URL? {
        if let tag = item.imageTags?["Logo"] {
            return client.imageURL(itemId: item.id, kind: .logo, tag: tag, maxWidth: width)
        }
        if let parent = item.parentLogoItemId, let tag = item.parentLogoImageTag {
            return client.imageURL(itemId: parent, kind: .logo, tag: tag, maxWidth: width)
        }
        return nil
    }

    func person(_ person: Person, width: Int = 300) -> URL? {
        person.primaryImageTag.map { client.imageURL(itemId: person.id, tag: $0, maxWidth: width) }
    }
}

extension EnvironmentValues {
    /// Set inside the signed-in part of the app.
    @Entry var session: ServerSession?
}

/// An image from the server, cached in memory and on disk, filling a frame of a fixed shape.
struct Artwork: View {
    let url: URL?
    /// Nil fills whatever frame it's given.
    var aspectRatio: CGFloat? = 2.0 / 3.0
    var cornerRadius: CGFloat = 10
    var placeholder = "film"
    var contentMode = ContentMode.fill

    var body: some View {
        Group {
            if let aspectRatio {
                Color.clear.aspectRatio(aspectRatio, contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .overlay {
            LazyImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: contentMode)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            if state.isLoading {
                                EmptyView()
                            } else {
                                Image(systemName: placeholder).font(.title2).foregroundStyle(.tertiary)
                            }
                        }
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

enum ImageCache {
    /// A disk cache for artwork, so lists come back instantly and scroll without refetching.
    static func configure() {
        var configuration = ImagePipeline.Configuration.withDataCache(name: "net.vinnysaj.vinnyfin.images", sizeLimit: 800 << 20)
        configuration.isProgressiveDecodingEnabled = false
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
    }
}
