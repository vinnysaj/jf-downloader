import Nuke
import NukeUI
import SwiftUI

extension EnvironmentValues {
    /// Set inside the signed-in part of the app.
    @Entry var session: ServerSession?
}

/// An image from the server, cached in memory and on disk, filling a frame of a fixed shape.
/// One that didn't load because the server couldn't be reached, or was too busy to send it, is
/// loaded again while it's on screen, waiting longer each time.
struct Artwork: View {
    let url: URL?
    /// Nil fills whatever frame it's given.
    var aspectRatio: CGFloat? = 2.0 / 3.0
    var cornerRadius: CGFloat = 10
    var placeholder = "film"
    var contentMode = ContentMode.fill
    /// How many times the image has been loaded again since `url` was set.
    @State private var retries = 0
    /// How long to wait before loading it again, after a failure worth trying again.
    @State private var retryDelay: Duration?

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
            .onCompletion { result in
                if case .failure(let error) = result, Self.isWorthRetrying(error) {
                    retryDelay = Self.delay(beforeRetry: retries + 1)
                } else {
                    retryDelay = nil
                }
            }
            .id(retries)
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: retryDelay) {
            guard let retryDelay else { return }
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                // Off screen; LazyImage loads it again when it's back.
                return
            }
            self.retryDelay = nil
            retries += 1
        }
        .onChange(of: url) {
            retries = 0
            retryDelay = nil
        }
    }

    /// Whether loading again might get the image that failed with `error`: the server couldn't be
    /// reached, or answered that it's too busy or took too long. It won't when the server says
    /// there's no such image, or sends one that isn't an image.
    nonisolated static func isWorthRetrying(_ error: any Error) -> Bool {
        guard case ImagePipeline.Error.dataLoadingFailed(let failure) = error else { return false }
        switch failure {
        case DataLoader.Error.statusCodeUnacceptable(let status): return status == 408 || status == 429 || status >= 500
        case let failure as URLError: return failure.code != .cancelled
        default: return false
        }
    }

    /// How long to wait before the `retry`th load again: a second, doubling each time up to half a
    /// minute.
    nonisolated static func delay(beforeRetry retry: Int) -> Duration {
        .seconds(min(pow(2, Double(retry - 1)), 30))
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
