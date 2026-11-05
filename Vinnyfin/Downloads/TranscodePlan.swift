#if !os(tvOS)
import Foundation

/// How a download gets its file: a version as it is, or, when every version is bigger than the
/// download quality and Transcode When No Version Fits is on, the server's transcode of the best
/// version down to it (`TranscodedDownloads`).
nonisolated enum DownloadPlan: Equatable, Sendable {
    case original(MediaSource)
    case transcode(MediaSource, TranscodeRequest)

    /// The version downloaded, or transcoded from.
    var source: MediaSource {
        switch self {
        case .original(let source), .transcode(let source, _): source
        }
    }

    var transcode: TranscodeRequest? {
        if case .transcode(_, let request) = self { request } else { nil }
    }

    /// What the download is, before it's queued: "1080p · 4.2 GB" for a version, "Transcoded
    /// 720p · about 1.2 GB" for a transcode.
    var summary: String {
        switch self {
        case .original(let source):
            let resolution = VersionTraits(source).resolutionClass.map(VersionTraits.label(forResolution:))
            return [resolution, source.plausibleSize.map(DownloadEstimate.text)].compactMap(\.self).joined(separator: " · ")
        case .transcode(_, let request):
            return request.summary
        }
    }

    /// The bytes it's expected to take, when that can be told.
    var expectedBytes: Int64? {
        switch self {
        case .original(let source): source.plausibleSize
        case .transcode(_, let request): request.estimatedBytes
        }
    }
}

nonisolated enum DownloadPlanner {
    /// What to download of a title at `quality`. The best version that fits, untouched, as
    /// `VersionChooser` picks it; when every version is known to be bigger, a transcode of the best
    /// one (the most for the server to work from) if `transcodeWhenNoneFits`, and otherwise the
    /// smallest version as it is. A version someone picked downloads as it is.
    static func plan(sources: [MediaSource], picked: MediaSource? = nil, quality: VideoQuality, transcodeWhenNoneFits: Bool,
                     choices: TranscodeChoices) -> DownloadPlan? {
        if let picked { return .original(picked) }
        guard let chosen = VersionChooser.choose(from: sources, quality: quality) else { return nil }
        guard transcodeWhenNoneFits, let cap = quality.maxHeight, let resolution = VersionTraits(chosen).resolutionClass,
              resolution > cap, let best = bestVersion(of: sources)
        else { return .original(chosen) }
        return .transcode(best, TranscodeRequest(source: best, quality: quality, choices: choices))
    }

    /// What to download of an item by the person's settings, unless they picked a version:
    /// every way of downloading takes this path.
    @MainActor
    static func plan(for item: JellyfinItem, picked: MediaSource? = nil, settings: AppSettings) -> DownloadPlan? {
        plan(sources: item.mediaSources ?? [], picked: picked, quality: settings.downloadQuality,
             transcodeWhenNoneFits: settings.transcodeDownloads, choices: TranscodeChoices(settings))
    }

    /// The version with the most picture, then the highest bitrate, the first of equals.
    static func bestVersion(of sources: [MediaSource]) -> MediaSource? {
        sources.enumerated().max { lhs, rhs in
            let (left, right) = (VersionTraits(lhs.element), VersionTraits(rhs.element))
            return (left.resolutionClass ?? 0, left.bitrate ?? 0, -lhs.offset) < (right.resolutionClass ?? 0, right.bitrate ?? 0, -rhs.offset)
        }?.element
    }
}

/// The streams a transcoded download takes, from the person's settings unless they chose.
nonisolated struct TranscodeChoices: Equatable, Sendable {
    /// ISO 639-2, such as "eng"; empty takes the version's default audio.
    var audioLanguage = ""
    /// The picture-based subtitle stream to burn in: `.automatic` follows the subtitle settings.
    var burnIn = BurnIn.automatic
    var subtitleMode = AppSettings.SubtitleMode.off
    var subtitleLanguage = ""

    enum BurnIn: Equatable, Sendable {
        /// The stream the subtitle settings pick, when it's picture-based.
        case automatic
        case none
        case stream(Int)
    }
}

extension TranscodeChoices {
    /// The person's audio and subtitle settings.
    init(_ settings: AppSettings, burnIn: BurnIn = .automatic) {
        self.init(audioLanguage: settings.audioLanguage, burnIn: burnIn, subtitleMode: settings.subtitleMode,
                  subtitleLanguage: settings.subtitleLanguage)
    }
}

/// What a transcoded download asks of the server, fixed for the life of the download: the server
/// keys its transcode on it, and its pieces only join if every one was made the same way.
nonisolated struct TranscodeRequest: Codable, Equatable, Sendable {
    var quality: VideoQuality
    var maxHeight: Int
    var maxWidth: Int
    /// The video bitrate asked for, in bits per second; the server takes it as a ceiling.
    var videoBitrate: Int
    /// The audio's: the stream's own when it's copied, else what the server encodes it at.
    var audioBitrate: Int
    var audioStreamIndex: Int?
    /// The audio stays as it is (AAC, AC-3, E-AC-3, FLAC, ALAC); other codecs become AAC.
    var copiesAudio: Bool
    /// The picture-based subtitle stream burned into the picture, if any.
    var burnedSubtitleIndex: Int?
    var burnedSubtitleName: String?
    /// Seconds per piece the server makes (HLS segments).
    var segmentLength: Int
    var runtimeTicks: Int64?
    /// The source is HDR. The server keeps it only where it copies the picture as it is; where
    /// it encodes it again, Jellyfin 10.11 maps it to SDR (`tonemapx`), HEVC or not, unless its
    /// hardware keeps HDR, which the transcode's init segment shows (`TranscodeState.videoRangeType`).
    var isHDR: Bool
    /// The server is expected to copy the picture as it is: the version's codec, dynamic range,
    /// size and bitrate all fit what's asked, and nothing is burned in. Nil for downloads queued
    /// before this was worked out.
    var copiesPicture: Bool?

    /// Three-second pieces: the restart window is 24 / length pieces, so this one leaves the most
    /// room, and seeks in the finished file land on a keyframe at most three seconds away.
    static let segmentLength = 3

    init(source: MediaSource, quality: VideoQuality, choices: TranscodeChoices) {
        self.quality = quality
        let height = quality.maxHeight ?? 2160
        maxHeight = height
        maxWidth = height * 16 / 9
        let audio = Self.audioStream(in: source, language: choices.audioLanguage)
        audioStreamIndex = audio?.index
        copiesAudio = audio.map(Self.isCopyable) ?? true
        audioBitrate = Self.audioBitrate(of: audio, copied: copiesAudio)
        let sourceVideo = source.videoStream?.bitRate ?? source.bitrate.map { max(0, $0 - (audio?.bitRate ?? 0)) }
        // A source smaller than the target gives the server nothing to spend the rest on.
        videoBitrate = min(quality.transcodeBitrate, sourceVideo.flatMap { $0 > 100_000 ? $0 : nil } ?? .max)
        let burned = Self.burnedSubtitle(in: source, audio: audio, choices: choices)
        burnedSubtitleIndex = burned?.index
        burnedSubtitleName = burned.map { $0.title ?? $0.displayTitle ?? $0.language ?? "Subtitles" }
        segmentLength = Self.segmentLength
        runtimeTicks = source.runTimeTicks
        isHDR = Self.isHDR(source.videoStream)
        copiesPicture = burned == nil && Self.fitsAsItIs(source.videoStream, maxWidth: maxWidth, maxHeight: maxHeight,
                                                          bitrate: videoBitrate, sourceBitrate: sourceVideo)
    }

    /// Whether the server can copy `video` into the transcode as it is, by the device profile
    /// (`deviceProfile`): HEVC in SDR, HDR10 or HLG, or H.264 in SDR, within the size, at no more
    /// than the bitrate asked for.
    static func fitsAsItIs(_ video: MediaStream?, maxWidth: Int, maxHeight: Int, bitrate: Int, sourceBitrate: Int?) -> Bool {
        guard let video, let width = video.width, let height = video.height, let sourceBitrate else { return false }
        let range = video.videoRangeType?.uppercased() ?? "SDR"
        let codecFits = switch video.codec?.lowercased() {
        case "hevc", "h265": ["SDR", "HDR10", "HLG"].contains(range)
        case "h264", "avc": range == "SDR"
        default: false
        }
        return codecFits && width <= maxWidth && height <= maxHeight && sourceBitrate <= bitrate
    }

    /// What the server is asked to stay under: the video's bitrate plus the audio's, which it
    /// takes the audio's out of again.
    var maxStreamingBitrate: Int { videoBitrate + audioBitrate }

    var runtimeSeconds: Double? { runtimeTicks.map { Double($0) / 10_000_000 } }

    /// Bitrate times running time.
    var estimatedBytes: Int64? {
        runtimeSeconds.map { Int64(Double(maxStreamingBitrate) * $0 / 8) }
    }

    /// "Transcoded 720p", for the version line; "Transcoded 720p SDR" for an HDR source the
    /// server is to encode again.
    var label: String { "Transcoded \(quality.label)\(isHDR && copiesPicture == false ? " SDR" : "")" }

    /// "Transcoded 720p · about 1.2 GB".
    var summary: String {
        guard let estimatedBytes else { return label }
        return "\(label) · about \(DownloadEstimate.text(estimatedBytes))"
    }

    // MARK: Streams

    /// The person's audio language, else the version's default, else its first.
    static func audioStream(in source: MediaSource, language: String) -> MediaStream? {
        let audio = source.audioStreams
        if !language.isEmpty, let match = audio.first(where: { AppSettings.sameLanguage($0.language, language) }) { return match }
        return audio.first { $0.index == source.defaultAudioStreamIndex } ?? audio.first
    }

    /// Codecs an MP4 carries and every device here plays, which the server copies as they are.
    static let copyableAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "flac", "alac"]

    static func isCopyable(_ stream: MediaStream) -> Bool {
        copyableAudioCodecs.contains(stream.codec?.lowercased() ?? "")
    }

    /// A copied stream's own bitrate; AAC at 192 kb/s for stereo and 384 kb/s for more channels.
    static func audioBitrate(of stream: MediaStream?, copied: Bool) -> Int {
        guard let stream else { return 0 }
        if copied, let bitRate = stream.bitRate, bitRate > 0 { return bitRate }
        if copied { return 640_000 }
        return (stream.channels ?? 2) > 2 ? 384_000 : 192_000
    }

    static let pictureSubtitleCodecs: Set<String> = ["pgssub", "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "xsub"]

    static func isPictureBased(_ stream: MediaStream) -> Bool {
        pictureSubtitleCodecs.contains(stream.codec?.lowercased() ?? "")
    }

    /// The picture-based subtitle stream to burn in. Automatic burns in the one the subtitle
    /// settings pick when that one is picture-based, and nothing when they pick text (which comes
    /// as a file beside the download) or nothing.
    static func burnedSubtitle(in source: MediaSource, audio: MediaStream?, choices: TranscodeChoices) -> MediaStream? {
        let pictures = source.subtitleStreams.filter(isPictureBased)
        switch choices.burnIn {
        case .none:
            return nil
        case .stream(let index):
            return pictures.first { $0.index == index }
        case .automatic:
            let candidates = source.subtitleStreams.compactMap(TrackChooser.Candidate.init)
            guard let pick = TrackChooser.subtitle(from: candidates, audioLanguage: audio?.language, mode: choices.subtitleMode,
                                                   language: choices.subtitleLanguage)
            else { return nil }
            return pictures.first { $0.index == pick }
        }
    }

    static func isHDR(_ video: MediaStream?) -> Bool {
        guard let video else { return false }
        if video.videoRange?.uppercased() == "HDR" { return true }
        return ["HDR10", "HDR10PLUS", "HLG", "DOVI", "DOVIWITHHDR10", "DOVIWITHHLG"].contains(video.videoRangeType?.uppercased() ?? "")
    }

    // MARK: Asking the server

    /// What the server is told this download plays: one HLS profile in fragmented MP4, HEVC
    /// where the server's administrator lets it encode HEVC and H.264 otherwise, the size and
    /// bitrate caps, the audio copied when it can be, and picture-based subtitles burned in when
    /// asked for. HEVC in HDR10 or HLG is allowed so a picture that fits is copied as it is, HDR
    /// and all; one encoded again comes out SDR (`isHDR`). Text subtitles are fetched as files of
    /// their own.
    var deviceProfile: DeviceProfile {
        let size = [
            DeviceProfile.ProfileCondition(Condition: "LessThanEqual", Property: "Height", Value: String(maxHeight), IsRequired: true),
            DeviceProfile.ProfileCondition(Condition: "LessThanEqual", Property: "Width", Value: String(maxWidth), IsRequired: true),
        ]
        let range = { (types: String) in
            DeviceProfile.ProfileCondition(Condition: "EqualsAny", Property: "VideoRangeType", Value: types, IsRequired: false)
        }
        return DeviceProfile(
            MaxStreamingBitrate: maxStreamingBitrate,
            MaxStaticBitrate: maxStreamingBitrate,
            TranscodingProfiles: [
                DeviceProfile.TranscodingProfile(
                    Container: "mp4", Type: "Video", VideoCodec: "hevc,h264", AudioCodec: "aac,ac3,eac3,flac,alac",
                    Protocol: "hls", Context: "Streaming", MaxAudioChannels: "8", MinSegments: 1
                ),
            ],
            CodecProfiles: [
                DeviceProfile.CodecProfile(Type: "Video", Codec: nil, Conditions: size),
                DeviceProfile.CodecProfile(Type: "Video", Codec: "hevc", Conditions: [range("SDR|HDR10|HLG")]),
                DeviceProfile.CodecProfile(Type: "Video", Codec: "h264", Conditions: [range("SDR")]),
            ],
            SubtitleProfiles: Self.pictureSubtitleCodecs.sorted().map { DeviceProfile.SubtitleProfile(Format: $0, Method: "Encode") }
        )
    }

    /// The PlaybackInfo request: this version only, transcoding only, the audio and subtitles
    /// named outright (-1 for none, or the server picks one by its own settings).
    func playbackInfo(userId: String, mediaSourceId: String) -> PlaybackInfoRequest {
        var request = PlaybackInfoRequest(
            UserId: userId,
            MediaSourceId: mediaSourceId,
            MaxStreamingBitrate: maxStreamingBitrate,
            StartTimeTicks: 0,
            AudioStreamIndex: audioStreamIndex,
            SubtitleStreamIndex: burnedSubtitleIndex ?? -1,
            DeviceProfile: deviceProfile
        )
        request.AllowAudioStreamCopy = copiesAudio
        return request
    }
}

// MARK: The transcoded file

extension TranscodeState {
    /// What a piece is expected to weigh, from the bitrates the server settled on.
    var expectedSegmentBytes: Int64 {
        Int64(Double((videoBitrate ?? request.videoBitrate) + (audioBitrate ?? request.audioBitrate)) * pieceLength / 8)
    }

    /// The version line: "Transcoded 1080p", with the dynamic range the transcode came in once
    /// its init segment says, where that's HDR or the source's was ("Transcoded 1080p SDR",
    /// "Transcoded 2160p HDR10"); until then what the request expects.
    nonisolated var label: String {
        guard let videoRangeType else { return request.label }
        let base = "Transcoded \(request.quality.label)"
        if videoRangeType != "SDR" { return "\(base) \(videoRangeType)" }
        return request.isHDR ? "\(base) SDR" : base
    }

    /// The stream the server makes, from its playlist: the codec of `CODECS`' first entry
    /// ("avc1…" is H.264, "hvc1…" or "hev1…" HEVC), and `RESOLUTION`.
    var variantVideoCodec: String? {
        guard let codecs = variant.flatMap({ HLSPlaylist.attribute("CODECS", in: $0) }), let first = codecs.split(separator: ",").first
        else { return nil }
        if first.hasPrefix("avc") { return "h264" }
        if first.hasPrefix("hvc") || first.hasPrefix("hev") { return "hevc" }
        return String(first)
    }

    var variantSize: (width: Int, height: Int)? {
        guard let resolution = variant.flatMap({ HLSPlaylist.attribute("RESOLUTION", in: $0) }) else { return nil }
        let sides = resolution.lowercased().split(separator: "x").compactMap { Int($0) }
        return sides.count == 2 ? (sides[0], sides[1]) : nil
    }

    /// The item as its transcoded file plays: the one version lists the file's streams as the
    /// file numbers them, the picture and then the audio, followed by the text subtitles saved
    /// beside it, numbered after those; and the subtitle files by those numbers.
    func playback(of item: JellyfinItem?, subtitleFiles: [Int: URL]) -> (JellyfinItem?, [Int: URL]) {
        guard var item, let original = item.mediaSources?.first else { return (item, subtitleFiles) }
        var source = original
        source.container = "mp4"
        source.bitrate = (videoBitrate ?? request.videoBitrate) + (audioBitrate ?? request.audioBitrate)
        var streams: [MediaStream] = []
        if var video = original.videoStream {
            video.index = 0
            video.codec = variantVideoCodec ?? video.codec
            video.width = variantSize?.width ?? video.width
            video.height = variantSize?.height ?? video.height
            video.bitRate = videoBitrate ?? request.videoBitrate
            if let videoRangeType {
                video.videoRangeType = videoRangeType
                video.videoRange = videoRangeType == "SDR" ? "SDR" : "HDR"
            }
            streams.append(video)
        }
        let audio = request.audioStreamIndex.flatMap { index in original.audioStreams.first { $0.index == index } }
        if var audio {
            audio.index = 1
            audio.isDefault = true
            if !request.copiesAudio {
                audio.codec = "aac"
                audio.bitRate = audioBitrate ?? request.audioBitrate
            }
            streams.append(audio)
        }
        var files: [Int: URL] = [:]
        for stream in original.subtitleStreams {
            guard let index = stream.index, let file = subtitleFiles[index] else { continue }
            var saved = stream
            saved.index = streams.count
            saved.isExternal = true
            files[streams.count] = file
            streams.append(saved)
        }
        source.mediaStreams = streams
        source.defaultAudioStreamIndex = audio == nil ? nil : 1
        source.defaultSubtitleStreamIndex = nil
        item.mediaSources = [source]
        return (item, files)
    }
}

/// Who a transcoded download is to the server, the same for every request of the download.
nonisolated enum TranscodeIdentity {
    /// The server keys a transcode's files on the User-Agent as well as the device and play
    /// session, so every request of a download sends this one, which no app or system update
    /// changes; the default names both and would orphan the files the server has made.
    static let userAgent = "vinnyfin-download/1"

    /// Downloads ask the server as a device of their own: the server lists a transcode's
    /// progress per device, which a playback transcoding at the same time would otherwise
    /// overwrite, and the session it lists for this one is gone only once the server restarts.
    static func deviceId(appDeviceId: String) -> String { "\(appDeviceId)-downloads" }

    /// The name the server lists the downloads' session under. The device's own name stays,
    /// as a different one would rename the device's sign-in on the server.
    static let clientName = "vinnyfin Downloads"
}
#endif
