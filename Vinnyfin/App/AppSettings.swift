import Foundation
import Observation

/// The choices in Settings, kept in UserDefaults.
@Observable
final class AppSettings {
    nonisolated enum SubtitleMode: String, CaseIterable, Identifiable, Sendable {
        /// Never, unless picked in the player.
        case off
        /// Only forced tracks, which translate signs and foreign dialogue.
        case forcedOnly
        /// Whenever the audio isn't in the subtitle language.
        case smart
        /// Always, in the subtitle language.
        case always

        var id: Self { self }

        var label: String {
            switch self {
            case .off: "Off"
            case .forcedOnly: "Forced Only"
            case .smart: "When the Audio Is Foreign"
            case .always: "Always"
            }
        }
    }

    nonisolated enum Appearance: String, CaseIterable, Identifiable, Sendable {
        /// Light or dark with the system.
        case system
        case light
        case dark

        var id: Self { self }

        var label: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// The browsing screens' look; the player is always dark.
    var appearance: Appearance { didSet { store(appearance.rawValue, Keys.appearance) } }
    var streamingQuality: VideoQuality { didSet { store(streamingQuality.rawValue, Keys.streamingQuality) } }
    /// Lets the server scale a version down when none matches `streamingQuality`.
    var allowTranscoding: Bool { didSet { store(allowTranscoding, Keys.allowTranscoding) } }
    var downloadQuality: VideoQuality { didSet { store(downloadQuality.rawValue, Keys.downloadQuality) } }
    /// Deletes a downloaded episode once it has been watched, here or on another device.
    var deleteWatchedEpisodes: Bool { didSet { store(deleteWatchedEpisodes, Keys.deleteWatchedEpisodes) } }
    /// How many episodes a new smart download keeps ahead.
    var smartDownloadCount: Int { didSet { store(smartDownloadCount, Keys.smartDownloadCount) } }
    var autoplayNextEpisode: Bool { didSet { store(autoplayNextEpisode, Keys.autoplayNextEpisode) } }
    /// Offers to skip intros, recaps, previews and credits the server has marked.
    var showSkipButtons: Bool { didSet { store(showSkipButtons, Keys.showSkipButtons) } }
    /// ISO 639-2 code, such as "eng"; empty plays the file's default track.
    var audioLanguage: String { didSet { store(audioLanguage, Keys.audioLanguage) } }
    var subtitleLanguage: String { didSet { store(subtitleLanguage, Keys.subtitleLanguage) } }
    var subtitleMode: SubtitleMode { didSet { store(subtitleMode.rawValue, Keys.subtitleMode) } }
    /// Relative to the standard size.
    var subtitleScale: Double { didSet { store(subtitleScale, Keys.subtitleScale) } }
    /// Switches the TV's frame rate and dynamic range to the video's (Apple TV).
    var matchContent: Bool { didSet { store(matchContent, Keys.matchContent) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let appearance = "settings.appearance"
        static let streamingQuality = "settings.streamingQuality"
        static let allowTranscoding = "settings.allowTranscoding"
        static let downloadQuality = "settings.downloadQuality"
        static let deleteWatchedEpisodes = "settings.deleteWatchedEpisodes"
        static let smartDownloadCount = "settings.smartDownloadCount"
        static let autoplayNextEpisode = "settings.autoplayNextEpisode"
        // Named for when it only covered intros; renaming it would reset everyone's choice.
        static let showSkipButtons = "settings.showSkipIntro"
        static let audioLanguage = "settings.audioLanguage"
        static let subtitleLanguage = "settings.subtitleLanguage"
        static let subtitleMode = "settings.subtitleMode"
        static let subtitleScale = "settings.subtitleScale"
        static let matchContent = "settings.matchContent"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Keys.appearance).flatMap(Appearance.init) ?? .system
        streamingQuality = defaults.string(forKey: Keys.streamingQuality).flatMap(VideoQuality.init) ?? .original
        allowTranscoding = defaults.object(forKey: Keys.allowTranscoding) as? Bool ?? true
        downloadQuality = defaults.string(forKey: Keys.downloadQuality).flatMap(VideoQuality.init) ?? .fullHD
        deleteWatchedEpisodes = defaults.object(forKey: Keys.deleteWatchedEpisodes) as? Bool ?? true
        smartDownloadCount = defaults.object(forKey: Keys.smartDownloadCount) as? Int ?? 10
        autoplayNextEpisode = defaults.object(forKey: Keys.autoplayNextEpisode) as? Bool ?? true
        showSkipButtons = defaults.object(forKey: Keys.showSkipButtons) as? Bool ?? true
        audioLanguage = defaults.string(forKey: Keys.audioLanguage) ?? ""
        subtitleLanguage = defaults.string(forKey: Keys.subtitleLanguage) ?? "eng"
        subtitleMode = defaults.string(forKey: Keys.subtitleMode).flatMap(SubtitleMode.init) ?? .forcedOnly
        subtitleScale = defaults.object(forKey: Keys.subtitleScale) as? Double ?? 1
        matchContent = defaults.object(forKey: Keys.matchContent) as? Bool ?? true
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// Languages offered for audio and subtitles, by their ISO 639-2 codes.
    nonisolated static let languages: [(code: String, name: String)] = {
        let codes = ["eng", "spa", "fre", "ger", "ita", "por", "dut", "swe", "nor", "dan", "fin", "pol", "rus", "ukr",
                     "tur", "ara", "heb", "hin", "jpn", "kor", "chi", "tha", "vie", "ind", "gre", "cze", "hun", "rum"]
        return codes.map { ($0, displayName(for: $0)) }.sorted { $0.1 < $1.1 }
    }()

    nonisolated static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Jellyfin and Matroska tag languages with ISO 639-2 (B) codes.
    nonisolated static func threeLetterCode(for twoLetter: String) -> String {
        let map = ["en": "eng", "es": "spa", "fr": "fre", "de": "ger", "it": "ita", "pt": "por", "nl": "dut",
                   "sv": "swe", "nb": "nor", "no": "nor", "da": "dan", "fi": "fin", "pl": "pol", "ru": "rus",
                   "uk": "ukr", "tr": "tur", "ar": "ara", "he": "heb", "hi": "hin", "ja": "jpn", "ko": "kor",
                   "zh": "chi", "th": "tha", "vi": "vie", "id": "ind", "el": "gre", "cs": "cze", "hu": "hun", "ro": "rum"]
        return map[twoLetter] ?? twoLetter
    }

    /// Whether two language tags name the same language: "eng", "en" and "en-US" all do.
    nonisolated static func sameLanguage(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        func normalized(_ tag: String) -> String {
            let base = tag.lowercased().split(separator: "-").first.map(String.init) ?? tag.lowercased()
            let aliases = ["fra": "fre", "deu": "ger", "nld": "dut", "zho": "chi", "ces": "cze", "ell": "gre", "ron": "rum"]
            let three = base.count == 2 ? threeLetterCode(for: base) : base
            return aliases[three] ?? three
        }
        return normalized(lhs) == normalized(rhs)
    }
}
