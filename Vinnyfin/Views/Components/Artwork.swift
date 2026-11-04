import Nuke
import NukeUI
import SwiftUI

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
