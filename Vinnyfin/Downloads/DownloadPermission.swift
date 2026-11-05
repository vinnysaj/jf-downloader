#if !os(tvOS)
import Foundation

/// What the server's administrator lets the signed-in account do that bears on downloads, from
/// its user policy (`GET /Users/Me`).
///
/// The server checks only some of it itself: Allow Media Downloading guards its own download
/// endpoint, which vinnyfin doesn't use (Gelato replaces it), and nothing guards a transcode
/// fetched piece by piece; transcoding video without the permission silently copies the
/// picture at full size instead. So vinnyfin holds to all of it:
///
/// - Allow Media Downloading (`EnableContentDownloading`): every download, original or transcoded.
/// - Allow video playback that requires transcoding (`EnableVideoPlaybackTranscoding`): a
///   transcoded download, which is the picture made smaller.
/// - Allow audio playback that requires transcoding (`EnableAudioPlaybackTranscoding`): a
///   transcoded download whose audio has to become AAC; audio that's copied doesn't need it.
/// - Allow media conversion (`EnableMediaConversion`): a transcoded download, which converts the
///   media for offline use. Jellyfin 12.4 reads it nowhere itself; it names exactly this.
nonisolated struct DownloadPolicy: Codable, Equatable, Sendable {
    var enableContentDownloading = true
    var enableVideoPlaybackTranscoding = true
    var enableAudioPlaybackTranscoding = true
    var enableMediaConversion = true

    enum CodingKeys: String, CodingKey {
        case enableContentDownloading = "EnableContentDownloading"
        case enableVideoPlaybackTranscoding = "EnableVideoPlaybackTranscoding"
        case enableAudioPlaybackTranscoding = "EnableAudioPlaybackTranscoding"
        case enableMediaConversion = "EnableMediaConversion"
    }

    init(enableContentDownloading: Bool = true, enableVideoPlaybackTranscoding: Bool = true,
         enableAudioPlaybackTranscoding: Bool = true, enableMediaConversion: Bool = true) {
        self.enableContentDownloading = enableContentDownloading
        self.enableVideoPlaybackTranscoding = enableVideoPlaybackTranscoding
        self.enableAudioPlaybackTranscoding = enableAudioPlaybackTranscoding
        self.enableMediaConversion = enableMediaConversion
    }

    /// A permission the server leaves out is its default, which allows it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enableContentDownloading = try container.decodeIfPresent(Bool.self, forKey: .enableContentDownloading) ?? true
        enableVideoPlaybackTranscoding = try container.decodeIfPresent(Bool.self, forKey: .enableVideoPlaybackTranscoding) ?? true
        enableAudioPlaybackTranscoding = try container.decodeIfPresent(Bool.self, forKey: .enableAudioPlaybackTranscoding) ?? true
        enableMediaConversion = try container.decodeIfPresent(Bool.self, forKey: .enableMediaConversion) ?? true
    }

    /// Why this account may not have `plan`; nil when it may.
    func refusal(for plan: DownloadPlan, serverName: String) -> String? {
        if !enableContentDownloading {
            return "\(serverName) doesn't allow downloads for your account. Its administrator can turn on Allow Media Downloading for you."
        }
        guard let request = plan.transcode else { return nil }
        if !enableVideoPlaybackTranscoding || !enableMediaConversion {
            let switchName = enableVideoPlaybackTranscoding ? "Allow Media Conversion" : "Allow Video Playback That Requires Transcoding"
            return "Every version of this is bigger than your download quality, and \(serverName) doesn't let your account make a smaller copy. Choose a version to download as it is, or ask its administrator to turn on \(switchName)."
        }
        if !request.copiesAudio, !enableAudioPlaybackTranscoding {
            return "The audio of this has to be converted for the download, and \(serverName) doesn't let your account do that. Ask its administrator to turn on Allow Audio Playback That Requires Transcoding."
        }
        return nil
    }

    /// Why this account may not download anything; nil when it may.
    func downloadRefusal(serverName: String) -> String? {
        enableContentDownloading ? nil
            : "\(serverName) doesn't allow downloads for your account. Its administrator can turn on Allow Media Downloading for you."
    }
}

/// The account may not download what was asked for; the message says why and who can change it.
nonisolated struct DownloadRefused: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The parts of `GET /Users/Me` read here.
nonisolated struct CurrentUser: Decodable, Sendable {
    let id: String
    let policy: DownloadPolicy

    enum CodingKeys: String, CodingKey {
        case id = "Id", policy = "Policy"
    }
}
#endif
