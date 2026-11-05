import Foundation

/// One signed-in app on one device, as `GET /Sessions` and the socket's `Sessions` message list
/// it: what it can be asked to do and what it's playing.
nonisolated struct RemoteSession: Decodable, Identifiable, Equatable, Sendable {
    struct PlayState: Decodable, Equatable, Sendable {
        var positionTicks: Int64?
        var isPaused = false
        var canSeek = false
        var audioStreamIndex: Int?
        /// -1, or nil, when subtitles are off.
        var subtitleStreamIndex: Int?
        var mediaSourceId: String?

        enum CodingKeys: String, CodingKey {
            case positionTicks = "PositionTicks", isPaused = "IsPaused", canSeek = "CanSeek"
            case audioStreamIndex = "AudioStreamIndex", subtitleStreamIndex = "SubtitleStreamIndex"
            case mediaSourceId = "MediaSourceId"
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            positionTicks = try container.decodeIfPresent(Int64.self, forKey: .positionTicks)
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
            canSeek = try container.decodeIfPresent(Bool.self, forKey: .canSeek) ?? false
            audioStreamIndex = try container.decodeIfPresent(Int.self, forKey: .audioStreamIndex)
            subtitleStreamIndex = try container.decodeIfPresent(Int.self, forKey: .subtitleStreamIndex)
            mediaSourceId = try container.decodeIfPresent(String.self, forKey: .mediaSourceId)
        }
    }

    let id: String
    var client: String
    var deviceName: String
    var deviceId: String
    var userName: String?
    var supportsRemoteControl: Bool
    var playableMediaTypes: [String]
    /// `GeneralCommandType` names, such as "SetSubtitleStreamIndex".
    var supportedCommands: [String]
    var nowPlayingItem: JellyfinItem?
    /// The streams of the version playing, which the server puts on the item it reports.
    var nowPlayingStreams: [MediaStream]
    var playState: PlayState

    enum CodingKeys: String, CodingKey {
        case id = "Id", client = "Client", deviceName = "DeviceName", deviceId = "DeviceId", userName = "UserName"
        case supportsRemoteControl = "SupportsRemoteControl", playableMediaTypes = "PlayableMediaTypes"
        case supportedCommands = "SupportedCommands", nowPlayingItem = "NowPlayingItem", playState = "PlayState"
    }

    private struct Streams: Decodable {
        var mediaStreams: [MediaStream]?
        enum CodingKeys: String, CodingKey { case mediaStreams = "MediaStreams" }
    }

    init(id: String, client: String, deviceName: String, deviceId: String, supportsRemoteControl: Bool = true,
         playableMediaTypes: [String] = ["Video"], supportedCommands: [String] = []) {
        self.id = id
        self.client = client
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.supportsRemoteControl = supportsRemoteControl
        self.playableMediaTypes = playableMediaTypes
        self.supportedCommands = supportedCommands
        nowPlayingStreams = []
        playState = PlayState()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        client = try container.decodeIfPresent(String.self, forKey: .client) ?? ""
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        userName = try container.decodeIfPresent(String.self, forKey: .userName)
        supportsRemoteControl = try container.decodeIfPresent(Bool.self, forKey: .supportsRemoteControl) ?? false
        playableMediaTypes = try container.decodeIfPresent([String].self, forKey: .playableMediaTypes) ?? []
        supportedCommands = try container.decodeIfPresent([String].self, forKey: .supportedCommands) ?? []
        nowPlayingItem = try container.decodeIfPresent(JellyfinItem.self, forKey: .nowPlayingItem)
        nowPlayingStreams = try container.decodeIfPresent(Streams.self, forKey: .nowPlayingItem)?.mediaStreams ?? []
        playState = try container.decodeIfPresent(PlayState.self, forKey: .playState) ?? PlayState()
    }

    var isVinnyfin: Bool { client.hasPrefix(JellyfinClient.clientName) }

    var position: Double { Double(playState.positionTicks ?? 0) / 10_000_000 }

    func supports(_ command: GeneralCommandName) -> Bool { supportedCommands.contains(command.rawValue) }
}

/// The `GeneralCommandType`s this app sends or obeys, by the names the server uses.
nonisolated enum GeneralCommandName: String, Sendable {
    case setAudioStreamIndex = "SetAudioStreamIndex"
    case setSubtitleStreamIndex = "SetSubtitleStreamIndex"
    case play = "Play"
    case playState = "PlayState"
}

/// What a session tells the server it can do, which makes it a target of remote control while
/// its socket is open.
nonisolated struct ClientCapabilities: Encodable, Sendable {
    var PlayableMediaTypes = ["Video"]
    var SupportedCommands: [String] = [
        GeneralCommandName.setAudioStreamIndex, .setSubtitleStreamIndex, .play, .playState,
    ].map(\.rawValue)
    var SupportsMediaControl = true
    var SupportsPersistentIdentifier = true
}

/// A general command, such as a subtitle change, as it's sent to `/Sessions/{id}/Command` and
/// arrives over the socket.
nonisolated struct GeneralCommand: Codable, Equatable, Sendable {
    var name: String
    var arguments: [String: String]

    enum CodingKeys: String, CodingKey {
        case name = "Name", arguments = "Arguments"
    }

    init(_ name: GeneralCommandName, arguments: [String: String] = [:]) {
        self.name = name.rawValue
        self.arguments = arguments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
    }
}

/// The transport commands of `/Sessions/{id}/Playing/{command}`, by the server's names.
nonisolated enum PlaystateCommand: String, Codable, Sendable {
    case stop = "Stop", pause = "Pause", unpause = "Unpause", playPause = "PlayPause"
    case nextTrack = "NextTrack", previousTrack = "PreviousTrack", seek = "Seek"
    case rewind = "Rewind", fastForward = "FastForward"
}

/// A message from the server over `/socket`. Kinds this app has no use for are kept by name.
nonisolated enum SocketMessage: Equatable, Sendable {
    struct PlayRequest: Decodable, Equatable, Sendable {
        var itemIds: [String]
        var startPositionTicks: Int64?
        var playCommand: String
        var mediaSourceId: String?
        var audioStreamIndex: Int?
        var subtitleStreamIndex: Int?
        var startIndex: Int?

        enum CodingKeys: String, CodingKey {
            case itemIds = "ItemIds", startPositionTicks = "StartPositionTicks", playCommand = "PlayCommand"
            case mediaSourceId = "MediaSourceId", audioStreamIndex = "AudioStreamIndex"
            case subtitleStreamIndex = "SubtitleStreamIndex", startIndex = "StartIndex"
        }
    }

    struct PlaystateRequest: Decodable, Equatable, Sendable {
        var command: String
        var seekPositionTicks: Int64?

        enum CodingKeys: String, CodingKey {
            case command = "Command", seekPositionTicks = "SeekPositionTicks"
        }
    }

    /// The server closes a socket that says nothing for this long, in seconds.
    case forceKeepAlive(Int)
    case keepAlive
    case play(PlayRequest)
    case playstate(PlaystateRequest)
    case generalCommand(GeneralCommand)
    case sessions([RemoteSession])
    case other(String)

    private struct Envelope: Decodable {
        let messageType: String
        enum CodingKeys: String, CodingKey { case messageType = "MessageType" }
    }

    private struct Payload<Data: Decodable>: Decodable {
        let data: Data
        enum CodingKeys: String, CodingKey { case data = "Data" }
    }

    init(json: Data) throws {
        let decoder = JSONDecoder()
        let type = try decoder.decode(Envelope.self, from: json).messageType
        switch type {
        case "ForceKeepAlive": self = .forceKeepAlive(try decoder.decode(Payload<Int>.self, from: json).data)
        case "KeepAlive": self = .keepAlive
        case "Play": self = .play(try decoder.decode(Payload<PlayRequest>.self, from: json).data)
        case "Playstate": self = .playstate(try decoder.decode(Payload<PlaystateRequest>.self, from: json).data)
        case "GeneralCommand": self = .generalCommand(try decoder.decode(Payload<GeneralCommand>.self, from: json).data)
        case "Sessions": self = .sessions(try decoder.decode(Payload<[RemoteSession]>.self, from: json).data)
        default: self = .other(type)
        }
    }

    /// What this app sends over the socket: keep-alives, and asking for the sessions as they change.
    enum Outbound: Equatable, Sendable {
        case keepAlive
        /// Updates at most every `interval` seconds, the first after `delay`.
        case sessionsStart(delay: Double, interval: Double)
        case sessionsStop

        var json: String {
            switch self {
            case .keepAlive:
                #"{"MessageType":"KeepAlive"}"#
            case .sessionsStart(let delay, let interval):
                #"{"MessageType":"SessionsStart","Data":"\#(Int(delay * 1000)),\#(Int(interval * 1000))"}"#
            case .sessionsStop:
                #"{"MessageType":"SessionsStop"}"#
            }
        }
    }
}

/// What another device asks the player here to do, worked out from the server's messages.
nonisolated enum RemoteCommand: Equatable, Sendable {
    /// Plays a server item from `start` seconds, in the version and with the streams given, when given.
    case play(itemId: String, start: Double, mediaSourceId: String?, audioStreamIndex: Int?, subtitleStreamIndex: Int?)
    case pause
    case unpause
    case togglePause
    case stop
    case seek(Double)
    case skip(Double)
    case nextEpisode
    case previousEpisode
    case audioStream(Int)
    /// Nil turns subtitles off.
    case subtitleStream(Int?)

    /// How far Rewind and Fast Forward move, as the player's own skip buttons do.
    static let skipInterval: Double = 10

    /// Nil for messages that aren't commands, and for commands this app doesn't obey, such as
    /// queueing an item to play later.
    init?(_ message: SocketMessage) {
        switch message {
        case .play(let request):
            guard request.playCommand == "PlayNow" else { return nil }
            let index = request.startIndex ?? 0
            guard request.itemIds.indices.contains(index) else { return nil }
            // A start the controller leaves out is the beginning, as every Jellyfin player reads it.
            self = .play(itemId: request.itemIds[index], start: Double(request.startPositionTicks ?? 0) / 10_000_000,
                         mediaSourceId: request.mediaSourceId, audioStreamIndex: request.audioStreamIndex,
                         subtitleStreamIndex: request.subtitleStreamIndex)
        case .playstate(let request):
            switch PlaystateCommand(rawValue: request.command) {
            case .stop: self = .stop
            case .pause: self = .pause
            case .unpause: self = .unpause
            case .playPause: self = .togglePause
            case .nextTrack: self = .nextEpisode
            case .previousTrack: self = .previousEpisode
            case .rewind: self = .skip(-Self.skipInterval)
            case .fastForward: self = .skip(Self.skipInterval)
            case .seek:
                guard let ticks = request.seekPositionTicks else { return nil }
                self = .seek(Double(ticks) / 10_000_000)
            case nil: return nil
            }
        case .generalCommand(let command):
            guard let index = command.arguments["Index"].flatMap(Int.init) else { return nil }
            switch GeneralCommandName(rawValue: command.name) {
            case .setAudioStreamIndex: self = .audioStream(index)
            case .setSubtitleStreamIndex: self = .subtitleStream(index < 0 ? nil : index)
            default: return nil
            }
        case .forceKeepAlive, .keepAlive, .sessions, .other:
            return nil
        }
    }
}

/// A session this app can send a playback to, named and placed for the Play On list.
nonisolated struct PlayTarget: Identifiable, Equatable, Sendable {
    let session: RemoteSession

    var id: String { session.id }
    var name: String { session.deviceName.isEmpty ? session.client : session.deviceName }
    var isAppleTV: Bool { session.client == JellyfinClient.clientName(for: .tvOS) }

    /// The device's symbol: vinnyfin says what it runs on, and the web app is a browser.
    var symbol: String {
        switch session.client {
        case JellyfinClient.clientName(for: .tvOS): "appletv"
        case JellyfinClient.clientName(for: .iOS): "ipad.and.iphone"
        case JellyfinClient.clientName(for: .macOS): "laptopcomputer"
        case JellyfinClient.clientName(for: .visionOS): "visionpro"
        case let client where client.localizedCaseInsensitiveContains("web"): "globe"
        default: "tv"
        }
    }

    /// The app, and whose it is when that isn't the person asking.
    func detail(signedInAs userName: String?) -> String {
        var parts = [session.isVinnyfin ? "vinnyfin" : session.client]
        if let owner = session.userName, let userName, owner.caseInsensitiveCompare(userName) != .orderedSame {
            parts.append(owner)
        }
        if let playing = session.nowPlayingItem {
            parts.append("Playing \(playing.isEpisode ? (playing.seriesName ?? playing.name) : playing.name)")
        }
        return parts.joined(separator: " · ")
    }

    /// The sessions that can take a video now, other than this device's: vinnyfin on Apple TV
    /// first, then vinnyfin elsewhere, then other apps, each by name. The server lists a session
    /// as controllable only while its app holds the socket open.
    static func targets(from sessions: [RemoteSession], excludingDeviceId deviceId: String) -> [PlayTarget] {
        sessions
            .filter { $0.deviceId != deviceId && $0.supportsRemoteControl && $0.playableMediaTypes.contains("Video") }
            .map(PlayTarget.init)
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    private var rank: Int {
        if isAppleTV { 0 } else if session.isVinnyfin { 1 } else { 2 }
    }
}

/// A vinnyfin device the Play On list has shown before. While the app there is closed the server
/// doesn't list it, so the list names it as one to open first.
nonisolated struct KnownDevice: Codable, Equatable, Identifiable, Sendable {
    let deviceId: String
    var name: String
    var isAppleTV: Bool
    var symbol: String

    var id: String { deviceId }

    /// `known` with every vinnyfin device among `targets` in it, under the name it has now; Apple
    /// TVs first, then by name.
    static func remembering(_ targets: [PlayTarget], in known: [KnownDevice]) -> [KnownDevice] {
        var byId = Dictionary(known.map { ($0.deviceId, $0) }) { first, _ in first }
        for target in targets where target.session.isVinnyfin {
            byId[target.session.deviceId] = KnownDevice(deviceId: target.session.deviceId, name: target.name,
                                                       isAppleTV: target.isAppleTV, symbol: target.symbol)
        }
        return byId.values.sorted { lhs, rhs in
            if lhs.isAppleTV != rhs.isAppleTV { return lhs.isAppleTV }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.deviceId < rhs.deviceId : order == .orderedAscending
        }
    }

    /// The known devices that aren't among `targets`.
    static func absent(from targets: [PlayTarget], in known: [KnownDevice]) -> [KnownDevice] {
        let present = Set(targets.map(\.session.deviceId))
        return known.filter { !present.contains($0.deviceId) }
    }
}
