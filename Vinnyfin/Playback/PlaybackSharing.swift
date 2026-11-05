import AetherEngine
import Foundation

/// A change the viewer makes to a playback that a group watching together applies to everyone.
nonisolated enum SharedChange: Equatable, Sendable {
    /// 0 pauses.
    case rate(Float)
    case seek(Double)
}

/// What a playback watched together with others goes through: the viewer's play, pause, seek and
/// speed changes go to the group, which applies them to every playback, this one's included,
/// through `PlayerModel`'s group commands.
protocol PlaybackSharing: AnyObject {
    /// Takes a change the viewer made here to the group. False leaves it to this playback alone.
    func share(_ change: SharedChange) -> Bool
    /// Whether a stream of the item starts playing as it loads, or loads paused and waits for the
    /// group to start it where the others are.
    func startsByItself(_ itemId: String?) -> Bool
}

/// Matches the server's stream indices, which other devices send and the server is told, with
/// the player's track ids. An embedded track's id is its index in the file, as the server's is;
/// the engine numbers external subtitles from a base of its own in the order they were loaded,
/// which is the server's order when it serves them, and they are matched by language otherwise.
nonisolated struct StreamIndexMap: Sendable {
    private var trackForStream: [Int: Int] = [:]
    private var streamForTrack: [Int: Int] = [:]

    init(streams: [MediaStream], tracks: [TrackInfo]) {
        let embedded = streams.filter { $0.isExternal != true }.compactMap(\.index)
        for track in tracks where !track.isExternal && embedded.contains(track.id) {
            link(stream: track.id, track: track.id)
        }
        let externalStreams = streams.filter { $0.type == "Subtitle" && $0.isExternal == true }
        let externalTracks = tracks.filter(\.isExternal).sorted { $0.id < $1.id }
        if externalStreams.count == externalTracks.count {
            for (stream, track) in zip(externalStreams, externalTracks) {
                if let index = stream.index { link(stream: index, track: track.id) }
            }
        } else {
            let candidates = externalTracks.map(TrackChooser.Candidate.init)
            for stream in externalStreams {
                guard let index = stream.index, let wanted = TrackChooser.Candidate(stream),
                      let track = TrackChooser.same(as: wanted, in: candidates), streamForTrack[track] == nil else { continue }
                link(stream: index, track: track)
            }
        }
    }

    private mutating func link(stream: Int, track: Int) {
        trackForStream[stream] = track
        streamForTrack[track] = stream
    }

    func trackId(forStream index: Int) -> Int? { trackForStream[index] }
    func streamIndex(forTrack id: Int) -> Int? { streamForTrack[id] }
}
