import OSLog
import TVServices

/// Fills the Top Shelf from the signed-in server each time the system asks. Signed out, or with
/// the server out of reach, it hands back nothing, and the system shows the app's Top Shelf image.
nonisolated final class ContentProvider: TVTopShelfContentProvider {
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin.topshelf", category: "content")

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        // The account store lives on the main actor, as it does in the app.
        guard let session = await MainActor.run(body: { AccountStore().session }) else {
            Self.log.info("Not signed in, so the system shows the Top Shelf image.")
            return nil
        }
        let client = session.client
        let userId = session.userId
        let limit = TopShelf.itemsPerSection
        do {
            async let resume = client.resumeItems(userId: userId, limit: limit)
            async let nextUp = client.nextUp(userId: userId, limit: limit)
            async let movies = client.latest(userId: userId, types: ["Movie"], limit: limit)
            async let shows = client.latestShows(userId: userId, limit: limit)
            return try await TopShelf.content(resume: resume, nextUp: nextUp, latestMovies: movies,
                                              latestShows: shows, session: session)
        } catch {
            Self.log.error("Couldn't load the Top Shelf from \(client.serverURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
