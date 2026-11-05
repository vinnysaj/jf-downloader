#if !os(tvOS)
#if !os(macOS)
import UIKit
#endif
import Foundation
import Observation
import OSLog

/// What `TranscodedDownloads` needs of the download queue it works for (`DownloadManager`).
protocol TranscodeHost: AnyObject {
    var jobs: [DownloadJob] { get }
    var isInFront: Bool { get }
    /// Transfers wait for a playback.
    var isPausedForPlayback: Bool { get }
    /// What plays streams the server's transcode.
    var isPlaybackTranscoding: Bool { get }
    /// Changes a job and saves the list; nothing when it's gone.
    func changeJob(_ id: UUID, _ change: (inout DownloadJob) -> Void)
    /// Plans the queue again.
    func transcodesChanged()
    /// Drops the job's transfers and everything it collected, to start from nothing.
    func startOver(_ id: UUID, because reason: String)
    /// Stops the job, with a message for the user.
    func stopJob(_ id: UUID, because message: String)
    /// Something the job asked the server for failed: counted as its transfers' failures are,
    /// so a transcode failing while other downloads come through yields to them.
    func transcodeFailed(_ id: UUID, _ failure: TransferFailure)
    /// The device had no room to write the job's download: it waits for room, never fails for
    /// that (`StorageBudget`).
    func outOfSpace(_ id: UUID, error: any Error)
}

/// The server's side of transcoded downloads, and the parts of them transfers alone can't do.
///
/// A transcoded download asks the server, as a device of its own (`TranscodeIdentity`), for an
/// HLS transcode of the version in fragmented MP4, with the size, bitrate, audio and burned-in
/// subtitles fixed when it was queued (`TranscodeRequest`). The queue fetches its pieces through
/// its background session like a file's chunks, as many at a time as the server can serve
/// (`SegmentPlanner`), and they join the job's partial file in order, the init segment first,
/// each where it follows on from the file by its own timestamps (`TranscodeTimeline`): the
/// server's playlist lists pieces at a length it doesn't cut them at, and doesn't say how many
/// there are. The joined file is checked, and indexed for players, before the download counts
/// as done (`TranscodeVerifier`, `FlattenedMP4`).
///
/// The server stops a transcode a minute after it last heard about it, deleting what it made,
/// and requests in flight don't count; so while the app runs and the download is the one in
/// hand, it pings the transcode every 25 seconds and asks the server how far it has got, which
/// is what the window of pieces follows (`TranscodeServer`). It keeps pinging while a playback
/// holds downloads, unless that playback streams a server transcode, which would then share the
/// server with this one. When the server isn't transcoding (it finished, failed, or was stopped
/// while the app was suspended; it restarted, which a piece refused or answered with 503 tells
/// before the server can), whether it still has the pieces left shows only by asking: the first
/// missing piece is asked for alone, and it comes from what the server kept, or from its
/// transcode started again where the request asks, at a clean cut of the file's last pictures,
/// which then shows as running. Either way the transcode's init segment is fetched once the
/// piece is in and compared with the one kept, and the download starts over if it differs; the
/// pieces that came meanwhile wait for that. A server still not transcoding then has the pieces
/// left, and they're all asked for at once.
///
/// A transcode started again that doesn't take over from the file, as one of an MPEG-TS source
/// starting at a keyframe after the cut asked for can't, is stopped and started again further
/// back. The end is where two runs of the transcode end: the one that got there, and the one
/// asking past it starts.
///
/// The account's permissions are looked at before the transcode starts and again after a gap,
/// with the version's tag: a version that changed on the server starts the download over. Once
/// the download is done or removed, the server's copy is deleted.
@Observable
final class TranscodedDownloads {
    /// What's known now about a transcoded download's server side, for the queue and its views.
    struct Live: Equatable {
        /// What the server said last.
        var server = TranscodeServer.unknown
        var throttle = ThrottleWatch()
        var activity: Activity?
        /// The piece last asked for alone to find out whether the server has the pieces left,
        /// and when it, or the init segment that started the transcode, came: the server has
        /// `TranscodeServer.progressLag` from then to show it transcoding.
        var probe: Int?
        var probedAt: Date?
        /// The server has been seen transcoding since a piece was last asked for alone.
        var seenRunning = false
        /// The latest piece of the server's transcode that came, and where its picture starts in
        /// seconds of the transcode's timeline: its later pieces follow at about the length the
        /// server cuts them.
        var anchor: Anchor?
        /// Which attempt at starting the server's transcode again the next is
        /// (`TranscodeTimeline.restartCut`): one further back each time one doesn't take over
        /// from the file.
        var searchLevel = 0
        /// Where the file ended, in seconds of the transcode's timeline, when a run of the
        /// server's transcode was last seen to end, by the next starting: a run ending there
        /// again is the end. Not a run the app stopped.
        var runEndedAt: Double?
        /// Where the last piece left out of the file ends: the next piece of its run starts there.
        var skippedEnd: Double?
        /// The app is stopping the server's transcode to start it again; pieces asked for before
        /// `restartedAt` are from the run stopped.
        var isRestarting = false
        var restartedAt: Date?
        /// The next piece asked for alone starts the transcode again for the app, which isn't
        /// the server stopping.
        var restartIsOwn = false

        struct Anchor: Equatable {
            var piece: Int
            var time: Double
        }

        /// Takes in what the server said. What was asked for alone, or the init segment, tells
        /// that a server not transcoding kept the pieces only until the server is seen
        /// transcoding or going down: after that, it's asked again. While it stays down, what
        /// came since is waited on, as the server can't say it's transcoding until it knows the
        /// device again.
        mutating func observe(_ server: TranscodeServer) {
            switch server {
            case .running:
                seenRunning = true
                probedAt = nil
            case .gone where self.server != .gone:
                probedAt = nil
            case .gone, .ended, .unknown:
                break
            }
            self.server = server
        }
    }

    enum Activity: Equatable {
        case preparing
        case checkingInit
        case checkingFile
    }

    /// By job.
    private(set) var live: [UUID: Live] = [:]

    @ObservationIgnored weak var host: (any TranscodeHost)?
    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let storage: DownloadStorage
    /// For playlists and init segments, which are small and wanted at once.
    @ObservationIgnored private let session: URLSession
    /// The one piece of work each job has under way that holds its pieces back: preparing,
    /// fetching or checking the init segment, checking the joined file.
    @ObservationIgnored private var work: [UUID: Task<Void, Never>] = [:]
    /// Joining pieces into the file, one run after another per job.
    @ObservationIgnored private var assembling: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var playlists: [UUID: HLSPlaylist] = [:]
    @ObservationIgnored private var headers: [UUID: (data: Data, parsed: FragmentedMP4.Header)] = [:]
    /// Where each job's file ends, track by track, read from the file once a run.
    @ObservationIgnored private var timelines: [UUID: TranscodeTimeline] = [:]
    /// Jobs whose files on disk this run has squared with what the job says.
    @ObservationIgnored private var reconciled: Set<UUID> = []
    /// The transcoded download in hand, which the heartbeat keeps alive.
    @ObservationIgnored private var currentJobId: UUID?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var polling: Set<UUID> = []
    /// When the server last said how far each job's transcode has got.
    @ObservationIgnored private var polledAt: [UUID: Date] = [:]
    /// Requests to delete the server's copies, for signing out to wait for.
    @ObservationIgnored private var cleanups: [Task<Void, Never>] = []
    @ObservationIgnored private var policy: (value: DownloadPolicy, fetchedAt: Date)?
    @ObservationIgnored private var retryTimer: Task<Void, Never>?

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "downloads")

    /// Seconds between pings: the server stops a transcode a minute after the last.
    static let pingInterval = 25
    /// Seconds between looks at how far the server has got, in front; three times that otherwise.
    static let pollInterval = 5
    /// Permissions and the version's tag are looked at again after this long without contact.
    static let recheckAfter: TimeInterval = 30 * 60
    /// How long the account's permissions, once fetched, stand for a new download.
    static let policyLifetime: TimeInterval = 5 * 60
    /// The server deletes a stopped transcode's files a moment after stopping it (1.5 s); a
    /// request before then could be answered from them.
    static let restartPause: Duration = .seconds(3)

    init(accounts: AccountStore, storage: DownloadStorage) {
        self.accounts = accounts
        self.storage = storage
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": TranscodeIdentity.userAgent, "Accept-Encoding": "identity"]
        session = URLSession(configuration: configuration)
    }

    /// What a transcoded download's server is doing, said beside how much of it is here: for
    /// its row, the Downloads widget and the Live Activity. Nil for other downloads, and while
    /// nothing is worth saying.
    func note(for job: DownloadJob) -> String? {
        guard let state = job.transcode, job.status == .active, !job.isTransferComplete else { return nil }
        return Self.note(for: state, live: live[job.id], serverIsCurrent: knownServer(of: job.id, now: .now) != .unknown)
    }

    /// `serverIsCurrent` whether what the server said last is recent enough to go by: it isn't
    /// asked about a download that waits its turn.
    static func note(for state: TranscodeState, live: Live?, serverIsCurrent: Bool) -> String? {
        switch live?.activity {
        case .preparing: return state.fileLength > 0 ? "Server starting the transcode" : "Asking the server for a transcode"
        case .checkingInit: return "Checking the server's transcode"
        case .checkingFile: return "Checking the download"
        case nil: break
        }
        if live?.isRestarting == true { return "Server starting the transcode again" }
        let mends = state.mends?.count ?? 0
        if mends > 0 { return mends == 1 ? "Mending 1 piece" : "Mending \(mends) pieces" }
        if state.isCollected { return "Checking the download" }
        guard serverIsCurrent else { return nil }
        if live?.throttle.isThrottled == true { return "Server paused until the download catches up" }
        guard case .running(let position) = live?.server, let runtime = state.runtimeSeconds, runtime > 0 else { return nil }
        return "Server preparing \(Int(min(99, max(0, position / runtime * 100))))%"
    }

    /// The notes of the downloads that have one, by job.
    func notes(for jobs: [DownloadJob]) -> [UUID: String] {
        var notes: [UUID: String] = [:]
        for job in jobs { notes[job.id] = note(for: job) }
        return notes
    }

    /// The server as downloads' own device, the same for every request of every download.
    private var client: JellyfinClient? {
        guard let app = accounts.client else { return nil }
        return JellyfinClient(serverURL: app.serverURL, deviceId: TranscodeIdentity.deviceId(appDeviceId: app.deviceId),
                              deviceName: app.deviceName, token: app.token, clientName: TranscodeIdentity.clientName,
                              userAgent: TranscodeIdentity.userAgent)
    }

    private func job(_ id: UUID) -> DownloadJob? {
        host?.jobs.first { $0.id == id }
    }

    // MARK: Planning

    /// The pieces each transcoded download may have the session fetch now, which `DownloadJob.plan`
    /// takes as a file's chunks. The first transcoded download in the session that doesn't yield
    /// (`DownloadJob.yields`) has the server work on it; any other there, one that yields or the
    /// one behind a failing download in hand, gets a single piece to tell whether it comes through,
    /// which is all the plan takes of it. Starts what has to come first: preparing the transcode,
    /// its init segment, a check.
    ///
    /// `claimed` are the pieces transfers have under way or awaiting a report; pieces set aside
    /// with resume data aren't claimed, so they carry on only when the window lets them.
    func windows(for jobs: [DownloadJob], claimed: [TransferTag], inSession: Set<UUID>, queuingAhead: Bool,
                 bytesPerSecond: [UUID: Double], now: Date = .now) -> [UUID: [Int]] {
        let transcodes = DownloadJob.queued(jobs).filter { $0.transcode != nil && inSession.contains($0.id) }
        let current = transcodes.first { !$0.yields }
        follow(current?.id)
        var windows: [UUID: [Int]] = [:]
        for job in transcodes {
            let own = Set(claimed.compactMap { $0.jobId == job.id ? $0.segment : nil })
            let segments: [Int]
            if job.id == current?.id {
                segments = window(for: job, claimed: own, queuingAhead: queuingAhead, bytesPerSecond: bytesPerSecond[job.id], now: now)
            } else if job.yields || (!queuingAhead && current?.isFailing == true) {
                segments = testWindow(for: job, claimed: own, now: now)
            } else {
                continue
            }
            if !segments.isEmpty { windows[job.id] = segments }
        }
        return windows
    }

    /// The job's state once nothing but pieces holds it back: starts what has to come first,
    /// once any retry it waits out is due.
    private func readyForPieces(_ job: DownloadJob, now: Date) -> TranscodeState? {
        guard reconcile(job), work[job.id] == nil, live[job.id]?.isRestarting != true, let current = self.job(job.id),
              let state = current.transcode
        else { return nil }
        let retryDue = (current.retryAt ?? .distantPast) <= now
        if !state.isPrepared || isDueForCheck(state, now: now) {
            if retryDue { begin(.prepare, for: job.id) }
            return nil
        }
        if state.fileLength == 0 {
            if retryDue { begin(.fetchInit, for: job.id) }
            return nil
        }
        if assembling[job.id] == nil, hasAppendable(state) { assemble(job.id) }
        if state.isCollected {
            if !state.isVerified, assembling[job.id] == nil { begin(.verify, for: job.id) }
            return nil
        }
        return state
    }

    /// Pieces beside the file that can go into it now: the next it takes, or one to mend it.
    private func hasAppendable(_ state: TranscodeState) -> Bool {
        let ready = state.collected.subtracting(state.unchecked)
        return ready.contains(state.appended) || (state.mends ?? [:]).keys.contains { ready.contains($0) }
    }

    /// The pieces the transcode in hand may have fetched now.
    private func window(for job: DownloadJob, claimed: Set<Int>, queuingAhead: Bool, bytesPerSecond: Double?, now: Date) -> [Int] {
        guard let state = readyForPieces(job, now: now) else { return [] }
        let server = knownServer(of: job.id, now: now)
        if server == .unknown {
            pollSoon(job.id)
            return []
        }
        if server.position != nil, state.needsInitCheck, !state.unchecked.isEmpty {
            // The init segment of the transcode as it runs now, which the piece came from.
            begin(.checkInit, for: job.id)
            return []
        }
        if server.position == nil, let probedAt = live[job.id]?.probedAt {
            // What was asked for alone came, and the server isn't transcoding, or was last seen
            // not knowing the device: once it has had the time to show a transcode the request
            // started, it sent what it had kept.
            let settled = probedAt.addingTimeInterval(TranscodeServer.progressLag)
            guard let polled = polledAt[job.id], polled >= settled else {
                pollSoon(job.id, after: settled.timeIntervalSince(now))
                return []
            }
            if server != .gone, state.needsInitCheck {
                begin(.checkInit, for: job.id)
                return []
            }
            // The init segment that started it came, and the transcode didn't: it's to be started again.
            live[job.id]?.probedAt = nil
        }
        let isHeld = state.isHeld(at: now) && !state.needsInitCheck
        var limit: Int?
        switch server {
        case .ended where isHeld && !queuingAhead:
            limit = max(0, SegmentPlanner.finishedBatch - claimed.count)
        case .running where queuingAhead:
            let bitrate = Double((state.videoBitrate ?? state.request.videoBitrate) + (state.audioBitrate ?? state.request.audioBitrate))
            limit = SegmentPlanner.fetchable(within: TranscodeServer.killDelay, bytesPerSecond: bytesPerSecond,
                                             bytesPerSegment: bitrate * state.pieceLength / 8)
        default:
            break
        }
        let window = SegmentPlanner.window(next: state.appended, end: state.pieceCount, mends: Array((state.mends ?? [:]).keys),
                                           collected: state.collected, claimed: claimed, server: server,
                                           serverPiece: serverPiece(of: job.id, state: state, position: server.position),
                                           lastPiece: lastPiece(of: state), isHeld: isHeld, mayAskAhead: !queuingAhead,
                                           pieceLength: state.pieceLength, limit: limit)
        if window.isProbe, let segment = window.segments.first, !beginProbe(job.id, segment: segment, state: state) { return [] }
        return window.segments
    }

    /// One piece for a transcoded download that isn't in hand, to tell whether its transfers
    /// come through: the first it's missing, which the server sends from what it kept or makes
    /// again, so the transcode's init segment is to be checked before it counts.
    private func testWindow(for job: DownloadJob, claimed: Set<Int>, now: Date) -> [Int] {
        guard claimed.isEmpty, let state = readyForPieces(job, now: now), let segment = firstOutstanding(of: state) else { return [] }
        if !state.needsInitCheck { host?.changeJob(job.id) { $0.transcode?.needsInitCheck = true } }
        return [segment]
    }

    private func firstOutstanding(of state: TranscodeState) -> Int? {
        (state.mends ?? [:]).keys.filter { !state.collected.contains($0) }.min()
            ?? (state.appended..<(state.pieceCount ?? Int.max)).lazy.first { !state.collected.contains($0) }
    }

    /// The piece the server's transcode is making, from how far it has got: counted from the
    /// latest piece of its run that came, or from where the file ends.
    private func serverPiece(of id: UUID, state: TranscodeState, position: Double?) -> Int? {
        guard let position else { return nil }
        let anchor = live[id]?.anchor ?? Live.Anchor(piece: state.appended, time: state.contentEnd ?? state.timelineOrigin ?? 0)
        let time = (state.timelineOrigin ?? 0) + position
        return anchor.piece + Int(((time - anchor.time) / state.pieceLength).rounded(.down))
    }

    /// The last piece the title's length surely leaves room for: the ones after are asked for one
    /// at a time, as asking for a piece past the transcode's end starts it again near the end.
    private func lastPiece(of state: TranscodeState) -> Int? {
        guard let runtime = state.runtimeSeconds, let origin = state.timelineOrigin else { return nil }
        let end = origin + runtime - TranscodeTimeline.serverEndLimit - state.pieceLength
        return SegmentPlanner.piece(at: end, next: state.appended, contentEnd: state.contentEnd ?? origin, pieceLength: state.pieceLength)
    }

    /// Notes the piece about to be asked for alone, whose transcode's init segment is to be
    /// checked once it's in. False when the server's transcode stopped with the file ending at
    /// the same place three times in a row, which stops the job.
    private func beginProbe(_ id: UUID, segment: Int, state: TranscodeState) -> Bool {
        let seenRunning = live[id]?.seenRunning ?? false
        let isOwn = live[id]?.restartIsOwn ?? false
        live[id, default: Live()].probe = segment
        live[id, default: Live()].probedAt = nil
        live[id, default: Live()].seenRunning = false
        live[id, default: Live()].restartIsOwn = false
        let position = state.downloadPosition
        var stops = 0
        host?.changeJob(id) { job in
            job.transcode?.needsInitCheck = true
            if !isOwn { stops = job.transcode?.noteStop(at: position, seenRunning: seenRunning) ?? 0 }
        }
        Self.log.info("""
            [\(id.uuidString.prefix(8))] The server isn't transcoding: asking for piece \(segment) alone, which it has kept or makes again \
            from \(state.contentEnd ?? 0) s\(isOwn ? "" : " (\(stops) time(s) with the file ending there)")
            """)
        guard stops >= 3 else { return true }
        host?.stopJob(id, because: """
            The server's transcode stopped \(Self.clock(position)) in, three times in a row. \
            Retry to try again, or download a version as it is.
            """)
        return false
    }

    static func clock(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
    }

    /// The server's transcode as last seen, unless that was too long ago to go by.
    private func knownServer(of id: UUID, now: Date) -> TranscodeServer {
        guard let polledAt = polledAt[id], now.timeIntervalSince(polledAt) < Self.staleAfter, let server = live[id]?.server else {
            return .unknown
        }
        return server
    }

    /// What the server said goes stale after this long: in front it's asked every few seconds,
    /// and the app may have been suspended since.
    static let staleAfter: TimeInterval = 4 * Double(pollInterval)

    /// Whether a piece handed to the session that hasn't started yet may stay there.
    func mayKeep(_ segment: Int, of job: DownloadJob, now: Date = .now) -> Bool {
        guard let state = job.transcode else { return true }
        if live[job.id]?.isRestarting == true || state.pieceCount.map({ segment >= $0 }) == true { return false }
        let server = knownServer(of: job.id, now: now)
        guard server != .unknown else { return true }
        return SegmentPlanner.mayStay(segment, firstOutstanding: firstOutstanding(of: state), server: server,
                                      serverPiece: serverPiece(of: job.id, state: state, position: server.position),
                                      lastPiece: lastPiece(of: state), isHeld: state.isHeld(at: now) && !state.needsInitCheck,
                                      pieceLength: state.pieceLength)
    }

    /// The request for a piece, addressed with the sign-in's token as it is now. Should it start
    /// the server's transcode again, it asks for it to start where the piece can take over from
    /// the file (`runtimeTicks`).
    func request(for segment: Int, of job: DownloadJob) -> URLRequest? {
        guard let client, let state = job.transcode, let base = state.playlistBase, let playlist = playlist(for: job.id),
              let uri = Self.segmentURI(segment, in: playlist, startTicks: startTicks(for: segment, of: job.id, state: state)),
              let url = Self.address(base + uri, client: client)
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(TranscodeIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    /// Where a piece's request asks the server to start its transcode, if it has to start it to
    /// make the piece, in ticks of 100 ns from the title's start: a piece to mend the file at the
    /// piece's own start, any other at a clean cut of the file's last pictures
    /// (`TranscodeTimeline.restartPoint`), and before any piece is in, at the start.
    private func startTicks(for segment: Int, of id: UUID, state: TranscodeState) -> Int64 {
        guard let timeline = timelines[id] else { return 0 }
        let seconds: Double
        if let mend = state.mends?[segment] {
            let halfFrame = Double(timeline.video.sampleDuration) / Double(timeline.video.timescale) / 2
            seconds = mend.start - timeline.originSeconds - halfFrame
        } else {
            let runtimeEnd = state.runtimeSeconds.map { timeline.originSeconds + $0 }
            seconds = timeline.seekTime(for: timeline.restartCut(attempt: live[id]?.searchLevel ?? 0, runtimeEnd: runtimeEnd))
        }
        return Int64((max(0, seconds) * 10_000_000).rounded(.down))
    }

    /// Piece `index`'s address, relative to the playlist's: as listed, or past the list, the last
    /// one listed with its number; asking the server, should it have to start its transcode to
    /// make it, to start at `startTicks`.
    static func segmentURI(_ index: Int, in playlist: HLSPlaylist, startTicks: Int64) -> String? {
        guard let last = playlist.segments.last, index >= 0 else { return nil }
        let listed = playlist.segments.indices.contains(index) ? playlist.segments[index].uri : last.uri
        guard var components = URLComponents(string: listed) else { return nil }
        if !playlist.segments.indices.contains(index) {
            let name = components.percentEncodedPath.split(separator: "/").last.map(String.init) ?? ""
            guard let dot = name.lastIndex(of: "."), Int(name[..<dot]) != nil else { return nil }
            let renamed = "\(index)\(name[dot...])"
            components.percentEncodedPath = String(components.percentEncodedPath.dropLast(name.count)) + renamed
        }
        var items = (components.percentEncodedQueryItems ?? []).filter { $0.name.caseInsensitiveCompare("runtimeTicks") != .orderedSame }
        items.append(URLQueryItem(name: "runtimeTicks", value: String(startTicks)))
        components.percentEncodedQueryItems = items
        return components.string
    }

    /// A playlist address on the server, with the sign-in's current token in place of the one
    /// it was listed with: the server keys the transcode on the address's other parts.
    static func address(_ path: String, client: JellyfinClient) -> URL? {
        guard let url = client.absoluteURL(serverPath: path), var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name.caseInsensitiveCompare("ApiKey") != .orderedSame }
        if let token = client.token { items.append(URLQueryItem(name: "ApiKey", value: token)) }
        components.queryItems = items
        return components.url
    }

    private func playlist(for id: UUID) -> HLSPlaylist? {
        if let playlist = playlists[id] { return playlist }
        guard let playlist = try? storage.loadPlaylist(for: id) else { return nil }
        playlists[id] = playlist
        return playlist
    }

    /// Squares the job with its files once a run: pieces left beside the file that it doesn't
    /// count, or counts as appended, go; a piece it counts that isn't there is fetched again; a
    /// job whose playlist went is prepared again; an index a check of the file left in it, cut
    /// off, comes out again; and where the file ends is read from it. False when the file itself
    /// can't be trusted, and the job starts over.
    private func reconcile(_ job: DownloadJob) -> Bool {
        guard !reconciled.contains(job.id), let state = job.transcode else { return true }
        reconciled.insert(job.id)
        let folder = storage.transcodeFolder(for: job.id)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let mends = state.mends ?? [:]
        func isBeside(_ index: Int) -> Bool { index >= state.appended || mends[index] != nil }
        var sideBytes: Int64 = 0
        for file in files where file.pathExtension == "m4s" {
            guard let index = Int(file.deletingPathExtension().lastPathComponent), state.collected.contains(index), isBeside(index) else {
                discard(file)
                continue
            }
            sideBytes += storage.size(of: file)
        }
        if state.fileLength > 0 { sideBytes += storage.size(of: storage.initFile(for: job.id)) }
        // A piece it counts that isn't there is fetched again.
        let missing = state.collected.filter { isBeside($0) && !FileManager.default.fileExists(atPath: storage.segmentFile($0, for: job.id).path) }
        let partial = storage.partialFile(for: job.id)
        let partialLength = storage.size(of: partial)
        let playlistGone = state.isPrepared && playlist(for: job.id) == nil
        let header = state.fileLength > 0 ? header(for: job.id) : nil
        if (state.fileLength > 0 && header == nil) || partialLength < state.fileLength {
            Self.log.error("[\(job.id.uuidString.prefix(8))] The joined file is shorter than recorded or its init segment is gone")
            // Not while the queue is being planned.
            Task { [weak self] in self?.restartFromNothing(job.id, because: "Part of the download went missing from this device.") }
            return false
        }
        var timeline: TranscodeTimeline?
        if let header, !state.isVerified {
            do {
                try FlattenedMP4.undo(partial, header: header.data, length: state.fileLength)
                let pieces = try storage.transcodedPieces(for: job.id, header: header.parsed, length: state.fileLength)
                timeline = TranscodeTimeline(pieces: pieces, header: header.parsed, cutInterval: state.pieceLength)
            } catch {
                Self.log.error("[\(job.id.uuidString.prefix(8))] The joined file can't be read: \(error.localizedDescription, privacy: .public)")
                Task { [weak self] in
                    self?.restartFromNothing(job.id, because: "The download's file on this device can't be read (\(error.localizedDescription)).")
                }
                return false
            }
        }
        timelines[job.id] = timeline
        let origin = timeline?.originSeconds
        let end = timeline?.end
        if sideBytes != state.sideBytes || !missing.isEmpty || playlistGone || origin != state.timelineOrigin || end != state.contentEnd {
            host?.changeJob(job.id) { job in
                job.transcode?.sideBytes = sideBytes
                job.transcode?.collected.subtract(IndexSet(missing))
                job.transcode?.unchecked.subtract(IndexSet(missing))
                if playlistGone { job.transcode?.playSessionId = nil }
                if job.transcode?.isVerified == false {
                    job.transcode?.timelineOrigin = origin
                    job.transcode?.contentEnd = end
                }
            }
        }
        return true
    }

    // MARK: Pieces

    enum SegmentOutcome: Equatable {
        case collected
        case retry(TransferFailure)
        case giveUp(String)
        /// Not wanted any more.
        case dropped
        /// No room on the device to keep it, which the host was told: it's asked for again once
        /// there's room.
        case noRoom
    }

    enum SegmentResponse: Equatable {
        case body
        case retry(TransferFailure)
        case giveUp(String)
    }

    /// Judges a finished piece's response. The body is the whole piece: the response asked for
    /// none of it in particular, or the system carried on a cut-off transfer from its bytes and
    /// joined the two.
    static func evaluate(_ response: ResponseInfo?, stagedSize: Int64?, segment: Int) -> SegmentResponse {
        guard let response else { return .retry(.network("The server didn't answer.")) }
        let status = response.statusCode
        if status == 401 {
            return .giveUp("The server rejected the sign-in (HTTP 401). Sign out, sign in again, then retry.")
        }
        if (200..<300).contains(status), let type = response.contentType?.lowercased(), type.hasPrefix("text/") || type.contains("json") {
            return .retry(.server("The server sent \(type) instead of piece \(segment) of the video."))
        }
        switch status {
        case 200:
            guard let stagedSize, stagedSize > 0 else { return .retry(.server("The server sent piece \(segment) empty.")) }
            if let length = response.contentLength, length != stagedSize { return .retry(.network("The transfer was cut short.")) }
            return .body
        case 206:
            guard let range = ContentRange(header: response.contentRange), let total = range.total else {
                return .retry(.server("The server answered for piece \(segment) without a usable Content-Range."))
            }
            guard range.range.upperBound == total, stagedSize == total else { return .retry(.network("The transfer was cut short.")) }
            return .body
        case 404:
            // The server deletes a stopped transcode's pieces a moment after stopping it, and a
            // request that comes in between can lose the piece it started making again.
            return .retry(.server("The server didn't have piece \(segment) yet (HTTP 404)."))
        case 400..<500 where ![408, 429].contains(status):
            return .giveUp("The server refused piece \(segment) of the transcode (HTTP \(status)).")
        default:
            return .retry(.server("The server answered with HTTP \(status)."))
        }
    }

    /// A piece's transfer, asked for at `requestedAt`, came back with a response: checks the
    /// piece and keeps it beside the file, and joins what can be joined.
    func accept(_ finished: TransferDelegate.Finished, segment: Int, of job: DownloadJob, requestedAt: Date?) async -> SegmentOutcome {
        let staged = finished.stagedFile
        guard let state = job.transcode, segment >= state.appended || state.mends?[segment] != nil,
              state.pieceCount.map({ segment < $0 }) ?? true
        else {
            discard(staged)
            return .dropped
        }
        if let restartedAt = live[job.id]?.restartedAt, (requestedAt ?? .distantPast) < restartedAt || live[job.id]?.isRestarting == true {
            // From the run the app stopped, or the server's answer to the stop.
            discard(staged)
            return .dropped
        }
        switch Self.evaluate(finished.response, stagedSize: finished.stagedSize, segment: segment) {
        case .retry(let failure):
            discard(staged)
            switch finished.response?.statusCode {
            case 404:
                // Not there after all: the pieces left aren't waiting on the server.
                if state.heldSince != nil { host?.changeJob(job.id) { $0.transcode?.heldSince = nil } }
                pollSoon(job.id)
            case 503:
                serverDown(job.id)
            default:
                break
            }
            return .retry(failure)
        case .giveUp(let message):
            discard(staged)
            return .giveUp(message)
        case .body:
            break
        }
        guard let staged else { return .retry(.network("Piece \(segment) didn't arrive.")) }
        if live[job.id]?.probe == segment {
            // The piece asked for alone came: from what the server kept, or from its transcode
            // started again, which shows by the time it has settled.
            live[job.id]?.probe = nil
            live[job.id]?.probedAt = .now
            pollSoon(job.id, after: TranscodeServer.progressLag)
        }
        guard !state.collected.contains(segment) else {
            discard(staged)
            return .collected
        }
        guard let header = header(for: job.id) else {
            discard(staged)
            restartFromNothing(job.id, because: "The download's init segment went missing from this device.")
            return .dropped
        }
        let piece: FragmentedMP4.Piece
        let size: Int64
        do {
            let data = try Data(contentsOf: staged)
            size = Int64(data.count)
            piece = try FragmentedMP4.piece(data, header: header.parsed)
        } catch {
            discard(staged)
            return .retry(.server("Piece \(segment) came damaged: \(error.localizedDescription)"))
        }
        // A piece without pictures is the server's past the end of the picture, which ends the
        // transcode where it comes; any other starts with a keyframe.
        if !piece.isEmpty, !piece.startsWithSync {
            discard(staged)
            return .retry(.server("Piece \(segment) came without a keyframe to start from."))
        }
        do {
            try storage.keepSegment(staged, segment, for: job.id)
        } catch {
            discard(staged)
            guard !StorageBudget.isOutOfSpace(error) else {
                host?.outOfSpace(job.id, error: error)
                return .noRoom
            }
            return .giveUp("Couldn't save the download: \(error.localizedDescription)")
        }
        if let start = piece.videoStart, segment >= live[job.id]?.anchor?.piece ?? 0 {
            live[job.id, default: Live()].anchor = Live.Anchor(piece: segment, time: start)
        }
        let lapsed = state.isLapsed(at: .now)
        host?.changeJob(job.id) { job in
            guard var transcode = job.transcode else { return }
            transcode.collected.insert(segment)
            transcode.sideBytes += size
            if lapsed { transcode.needsInitCheck = true }
            if transcode.needsInitCheck { transcode.unchecked.insert(segment) }
            job.transcode = transcode
        }
        if self.job(job.id)?.transcode?.needsInitCheck == true {
            // The init segment is checked first.
            host?.transcodesChanged()
        } else {
            assemble(job.id)
        }
        return .collected
    }

    private func header(for id: UUID) -> (data: Data, parsed: FragmentedMP4.Header)? {
        if let header = headers[id] { return header }
        guard let data = try? storage.savedHeader(for: id), let parsed = try? FragmentedMP4.header(data) else { return nil }
        headers[id] = (data, parsed)
        return (data, parsed)
    }

    /// Joins the pieces that can be joined, after any run under way: pieces fetched again to
    /// mend the file first, then those after the file's end.
    private func assemble(_ id: UUID) {
        let previous = assembling[id]
        let task = Task { [weak self] in
            await previous?.value
            await self?.assembleNow(id)
        }
        assembling[id] = task
        Task { [weak self] in
            await task.value
            guard let self, assembling[id] == task else { return }
            assembling[id] = nil
            // The check of the whole file waits for the joining to be done.
            if job(id)?.transcode?.isCollected == true { host?.transcodesChanged() }
        }
    }

    private func assembleNow(_ id: UUID) async {
        guard let header = header(for: id) else { return }
        guard await mend(id, header: header), let state = job(id)?.transcode, state.pieceCount == nil else { return }
        var judge = TranscodeJudge(timeline: timelines[id], runEndedAt: live[id]?.runEndedAt, skippedEnd: live[id]?.skippedEnd,
                                   header: header.parsed, cutInterval: state.pieceLength, runtime: state.runtimeSeconds)
        var next = state.appended
        var outcome: TranscodeJudge.Outcome?
        while outcome == nil, state.collected.contains(next), !state.unchecked.contains(next) {
            let piece: FragmentedMP4.Piece
            do {
                piece = try outline(of: next, for: id, header: header.parsed)
            } catch {
                Self.log.error("[\(id.uuidString.prefix(8))] Piece \(next) beside the file can't be read: \(error.localizedDescription, privacy: .public)")
                let file = storage.segmentFile(next, for: id)
                let size = storage.size(of: file)
                discard(file)
                host?.changeJob(id) { job in
                    job.transcode?.collected.remove(next)
                    job.transcode?.sideBytes -= size
                }
                break
            }
            outcome = judge.take(piece, number: next)
            if judge.joining.last == next || judge.skipping.last == next { next += 1 }
        }
        live[id, default: Live()].runEndedAt = judge.runEndedAt
        live[id, default: Live()].skippedEnd = judge.skippedEnd
        let joining = judge.joining
        let skipping = judge.skipping
        if !joining.isEmpty || !skipping.isEmpty {
            let bytes = { (pieces: [Int]) in pieces.reduce(Int64(0)) { $0 + self.storage.size(of: self.storage.segmentFile($1, for: id)) } }
            let joinedBytes = bytes(joining)
            let skippedBytes = bytes(skipping)
            do {
                let length = joining.isEmpty ? state.fileLength : try await storage.appendSegments(joining, for: id, after: state.fileLength)
                let timeline = judge.timeline
                timelines[id] = timeline
                host?.changeJob(id) { job in
                    guard var transcode = job.transcode else { return }
                    transcode.appended = next
                    transcode.fileLength = length
                    transcode.sideBytes -= joinedBytes + skippedBytes
                    if !skipping.isEmpty { transcode.skipped = (transcode.skipped ?? IndexSet()).union(IndexSet(skipping)) }
                    transcode.timelineOrigin = timeline?.originSeconds
                    transcode.contentEnd = timeline?.end
                    job.transcode = transcode
                }
                try storage.removeSegments(joining + skipping, for: id)
            } catch {
                writeFailed(id, error)
                return
            }
            if !joining.isEmpty { live[id]?.searchLevel = 0 }
            let origin = judge.timeline?.originSeconds ?? 0
            for takeover in judge.takeovers {
                Self.log.info("""
                    [\(id.uuidString.prefix(8))] Piece \(takeover.piece) takes over from the file at \(takeover.at - origin) s; \
                    the file reached \(takeover.fileEnd - origin) s
                    """)
            }
            if !skipping.isEmpty {
                Self.log.info("[\(id.uuidString.prefix(8))] Left out pieces \(skipping.map(String.init).joined(separator: ", "), privacy: .public): the file has them already")
            }
        }
        switch outcome {
        case .gap:
            Self.log.notice("""
                [\(id.uuidString.prefix(8))] Piece \(next) doesn't take over from the file, which ends at \(judge.timeline?.end ?? 0) s: \
                starting the transcode again further back
                """)
            restartTranscode(id, deeper: true)
        case .end(let count):
            endTranscode(id, count: count)
        case nil:
            break
        }
    }

    /// The timing of a piece kept beside the file.
    private func outline(of segment: Int, for id: UUID, header: FragmentedMP4.Header) throws -> FragmentedMP4.Piece {
        let file = storage.segmentFile(segment, for: id)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        let pieces = try FragmentedMP4.outlines(count: length, from: 0, header: header) { range in
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: range.count) ?? Data()
        }
        guard pieces.count == 1, let piece = pieces.first else { throw FragmentedMP4.Problem(message: "It holds \(pieces.count) pieces.") }
        return piece
    }

    /// Puts pieces fetched again in the file. One that covers what the piece in its place did
    /// goes there; one that doesn't, from a transcode started again, takes over from the file
    /// cut back to where that piece started, which goes on from it as from any. False when
    /// writing the file failed.
    private func mend(_ id: UUID, header: (data: Data, parsed: FragmentedMP4.Header)) async -> Bool {
        guard let state = job(id)?.transcode, let mends = state.mends else { return true }
        for (segment, mend) in mends.sorted(by: { $0.key < $1.key }) where state.collected.contains(segment) && !state.unchecked.contains(segment) {
            guard let current = job(id)?.transcode, let place = current.mends?[segment] else { continue }
            let pieceSize = storage.size(of: storage.segmentFile(segment, for: id))
            do {
                let piece = try outline(of: segment, for: id, header: header.parsed)
                let matches = place.end.map { end in
                    abs((piece.videoStart ?? .nan) - place.start) < 0.001 && abs((piece.videoEnd ?? .nan) - end) < 0.001
                } ?? false
                guard matches else {
                    try cutBack(id, to: segment, at: place.bytes.lowerBound, header: header)
                    return true
                }
                let length = try await storage.replaceSegment(segment, for: id, at: place.bytes)
                try storage.removeSegments([segment], for: id)
                let shift = length - current.fileLength
                host?.changeJob(id) { job in
                    guard var transcode = job.transcode else { return }
                    transcode.mends?[segment] = nil
                    for (other, otherPlace) in transcode.mends ?? [:] where otherPlace.bytes.lowerBound >= mend.bytes.upperBound {
                        transcode.mends?[other]?.bytes = (otherPlace.bytes.lowerBound + shift)..<(otherPlace.bytes.upperBound + shift)
                    }
                    if transcode.mends?.isEmpty == true { transcode.mends = nil }
                    transcode.fileLength = length
                    transcode.sideBytes -= pieceSize
                    job.transcode = transcode
                }
                Self.log.info("[\(id.uuidString.prefix(8))] Put piece \(segment) in place again")
            } catch {
                writeFailed(id, error)
                return false
            }
        }
        return true
    }

    /// Cuts the file back to `length` bytes, where piece `segment` started, to go on from there
    /// with the piece fetched again beside it.
    private func cutBack(_ id: UUID, to segment: Int, at length: Int64, header: (data: Data, parsed: FragmentedMP4.Header)) throws {
        guard let state = job(id)?.transcode else { return }
        try storage.truncateTranscodedFile(for: id, to: length)
        let pieces = try storage.transcodedPieces(for: id, header: header.parsed, length: length)
        let timeline = TranscodeTimeline(pieces: pieces, header: header.parsed, cutInterval: state.pieceLength)
        timelines[id] = timeline
        live[id]?.runEndedAt = nil
        live[id]?.skippedEnd = nil
        Self.log.notice("[\(id.uuidString.prefix(8))] Piece \(segment) came back different: the file goes on from there")
        host?.changeJob(id) { job in
            guard var transcode = job.transcode else { return }
            transcode.appended = segment
            transcode.fileLength = length
            transcode.mends = nil
            transcode.pieceCount = nil
            transcode.collected = IndexSet(transcode.collected.filter { $0 <= segment })
            transcode.unchecked = IndexSet(transcode.unchecked.filter { $0 <= segment })
            transcode.skipped = transcode.skipped.map { IndexSet($0.filter { $0 < segment }) }
            transcode.timelineOrigin = timeline?.originSeconds
            transcode.contentEnd = timeline?.end
            job.transcode = transcode
        }
    }

    /// The transcode ends with the file: two of its runs ended there, or the server sent a piece
    /// past the end of the picture. Short of the title's length by more than its header can
    /// overstate it, the server stops there instead, and it's started again; three times, and
    /// the job stops.
    private func endTranscode(_ id: UUID, count: Int) {
        guard let state = job(id)?.transcode, let timeline = timelines[id] else { return }
        let reached = timeline.end - timeline.originSeconds
        if let runtime = state.runtimeSeconds, reached < runtime - TranscodeVerifier.shortfallAllowed(runtime: runtime) {
            var stops = 0
            host?.changeJob(id) { stops = $0.transcode?.noteStop(at: reached, seenRunning: true) ?? 0 }
            Self.log.notice("[\(id.uuidString.prefix(8))] The server's transcode ends at \(reached) s of \(runtime) s (\(stops) time(s))")
            guard stops < 3 else {
                host?.stopJob(id, because: """
                    The server's transcode ends \(Self.clock(reached)) in each time, but the title runs \(Self.clock(runtime)). \
                    Retry to try again, or download a version as it is.
                    """)
                return
            }
            restartTranscode(id, deeper: false)
            return
        }
        Self.log.info("[\(id.uuidString.prefix(8))] The transcode ends at \(reached) s, with piece \(count - 1)")
        let beside = state.collected.filter { $0 >= count && state.mends?[$0] == nil }
        let besideBytes = beside.reduce(Int64(0)) { $0 + storage.size(of: storage.segmentFile($1, for: id)) }
        do {
            try storage.removeSegments(beside, for: id)
        } catch {
            writeFailed(id, error)
            return
        }
        host?.changeJob(id) { job in
            guard var transcode = job.transcode else { return }
            transcode.pieceCount = count
            transcode.appended = max(transcode.appended, count)
            transcode.collected.subtract(IndexSet(beside))
            transcode.unchecked.subtract(IndexSet(beside))
            transcode.sideBytes -= besideBytes
            transcode.stopsAtSamePlace = 0
            job.transcode = transcode
        }
        host?.transcodesChanged()
    }

    /// Stops the server's transcode and has the next piece start it again, at the next clean cut
    /// of the file `deeper` back, or at the latest, once the server has deleted what the stopped
    /// one made; past those, where the file's last run started. When that doesn't take over
    /// either, the job stops.
    private func restartTranscode(_ id: UUID, deeper: Bool) {
        guard let client, let playSessionId = job(id)?.transcode?.playSessionId, holdForRestart(id, deeper: deeper) else { return }
        Task { [weak self] in
            do {
                try await client.stopTranscoding(playSessionId: playSessionId)
            } catch {
                // The piece asked for next starts it again all the same, the server's own run
                // being past it.
                Self.log.notice("[\(id.uuidString.prefix(8))] Couldn't stop the server's transcode: \(error.localizedDescription, privacy: .public)")
            }
            try? await Task.sleep(for: Self.restartPause)
            self?.restarted(id)
        }
    }

    /// Holds the job's pieces while its server transcode is stopped to start again: false, with
    /// nothing held, when one is being stopped already or the attempts have run out, which stops
    /// the job. The pieces the server hasn't answered are taken back before it's stopped
    /// (`mayKeep`): the first of them to reach it after would start it again where that one
    /// asked, numbering its pieces from there, and leave them behind on the server when the
    /// piece asked for next starts it where it should be.
    func holdForRestart(_ id: UUID, deeper: Bool) -> Bool {
        guard let state = job(id)?.transcode, live[id]?.isRestarting != true else { return false }
        let level = deeper ? (live[id]?.searchLevel ?? 0) + 1 : 0
        guard level < TranscodeTimeline.restartAttempts else {
            host?.stopJob(id, because: """
                The server's transcode can't pick up where the download got to, \(Self.clock(state.downloadPosition)) in: each time it \
                starts again there, it starts too late. Retry to try again, or download a version as it is.
                """)
            return false
        }
        var live = self.live[id] ?? Live()
        live.searchLevel = level
        live.isRestarting = true
        live.restartedAt = .now
        live.restartIsOwn = true
        live.anchor = nil
        // The run stopped didn't end by itself, and what it made goes.
        live.runEndedAt = nil
        live.skippedEnd = nil
        self.live[id] = live
        host?.transcodesChanged()
        return true
    }

    /// The server's transcode was stopped: the pieces beside the file came from it and go, and
    /// the next is asked for alone.
    private func restarted(_ id: UUID) {
        guard let state = job(id)?.transcode else { return }
        let beside = state.collected.filter { $0 >= state.appended && state.mends?[$0] == nil }
        let besideBytes = beside.reduce(Int64(0)) { $0 + storage.size(of: storage.segmentFile($1, for: id)) }
        do {
            try storage.removeSegments(beside, for: id)
        } catch {
            writeFailed(id, error)
            return
        }
        host?.changeJob(id) { job in
            job.transcode?.collected.subtract(IndexSet(beside))
            job.transcode?.unchecked.subtract(IndexSet(beside))
            job.transcode?.sideBytes -= besideBytes
            job.transcode?.heldSince = nil
        }
        live[id]?.isRestarting = false
        live[id]?.server = .ended
        live[id]?.probedAt = nil
        polledAt[id] = .now
        host?.transcodesChanged()
    }

    /// Writing the file failed: with no room, the job waits and tries again; otherwise it stops.
    private func writeFailed(_ id: UUID, _ error: any Error) {
        if StorageBudget.isOutOfSpace(error) {
            Self.log.notice("[\(id.uuidString.prefix(8))] No room to join pieces; waiting")
            host?.outOfSpace(id, error: error)
            scheduleRetry(after: 30)
        } else {
            host?.stopJob(id, because: "Couldn't write the download to storage: \(error.localizedDescription)")
        }
    }

    private func discard(_ file: URL?) {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Self.log.error("Couldn't delete \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Work

    private enum Step: String {
        case prepare, fetchInit, checkInit, verify
    }

    private func begin(_ step: Step, for id: UUID) {
        guard work[id] == nil else { return }
        let task = Task { [weak self] in
            #if !os(macOS)
            let backgroundTime = BackgroundTime(named: "Transcoded download")
            defer { backgroundTime.end() }
            #endif
            guard let self else { return }
            switch step {
            case .prepare: await self.prepare(id)
            case .fetchInit: await self.fetchInit(id)
            case .checkInit: await self.checkInit(id)
            case .verify: await self.verify(id)
            }
        }
        work[id] = task
        Task { [weak self] in
            await task.value
            // A step that started the job over has already handed it to the next step, which
            // would otherwise run twice.
            guard let self, self.work[id] == task else { return }
            self.work[id] = nil
            self.host?.transcodesChanged()
        }
    }

    /// A step failed for a reason that passes: counted as the job's transfers' failures are,
    /// and tried again once the job's retry is due.
    private func stepFailed(_ id: UUID, _ step: Step, _ error: any Error) {
        Self.log.error("[\(id.uuidString.prefix(8))] \(step.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        if case JellyfinError.http(let status, _) = error, status == 401 {
            host?.stopJob(id, because: "The server rejected the sign-in (HTTP 401). Sign out, sign in again, then retry.")
            return
        }
        let failure: TransferFailure = if error is URLError { .network(Self.describe(error)) } else { .server(error.localizedDescription) }
        host?.transcodeFailed(id, failure)
        if let retryAt = job(id)?.retryAt { scheduleRetry(after: max(1, retryAt.timeIntervalSinceNow)) }
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retryTimer?.cancel()
        retryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.host?.transcodesChanged()
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let code = (error as? URLError)?.code else { return error.localizedDescription }
        return switch code {
        case .notConnectedToInternet: "No internet connection."
        case .timedOut: "The connection stalled."
        case .networkConnectionLost: "The connection dropped."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: "Couldn't reach the server."
        default: error.localizedDescription
        }
    }

    private func isDueForCheck(_ state: TranscodeState, now: Date) -> Bool {
        guard state.isPrepared else { return false }
        let lastContact = max(state.lastPing ?? .distantPast, state.checkedAt ?? .distantPast)
        return now.timeIntervalSince(lastContact) > Self.recheckAfter
    }

    /// Before the transcode starts, and after a gap: the account still may, and the version is
    /// the one the pieces so far came from. Then, to start, the server is told about the
    /// downloads' device, asked for the transcode, and its playlists are kept.
    private func prepare(_ id: UUID) async {
        guard let client, let userId = accounts.account?.userId, let job = job(id), let state = job.transcode else { return }
        live[id, default: Live()].activity = .preparing
        defer { live[id]?.activity = nil }
        let serverName = accounts.account?.serverTitle ?? "The server"
        do {
            let user: CurrentUser = try await client.currentUser()
            policy = (user.policy, .now)
            let source = job.item?.mediaSources?.first ?? MediaSource(id: job.mediaSourceId)
            if let refusal = user.policy.refusal(for: .transcode(source, state.request), serverName: serverName) {
                host?.stopJob(id, because: refusal)
                return
            }
            if state.isPrepared {
                let item = try await client.item(id: job.itemId, userId: userId)
                let current = item.mediaSources?.first { $0.id == job.mediaSourceId }
                if let tag = state.sourceTag, let currentTag = current?.eTag, tag != currentTag {
                    restartFromNothing(id, because: "The version changed on the server since the download started.")
                    return
                }
                host?.changeJob(id) { job in
                    job.transcode?.checkedAt = .now
                    job.recordSuccess()
                }
                live[id, default: Live()].server = .unknown
                return
            }
            try await client.reportCapabilities(ClientCapabilities(PlayableMediaTypes: [], SupportedCommands: [], SupportsMediaControl: false))
            let info = try await client.playbackInfo(itemId: job.itemId, userId: userId,
                                                     request: state.request.playbackInfo(userId: userId, mediaSourceId: job.mediaSourceId))
            let served = info.mediaSources.first { $0.id == job.mediaSourceId } ?? info.mediaSources.first
            if let tag = state.sourceTag, let currentTag = served?.eTag, tag != currentTag {
                restartFromNothing(id, because: "The version changed on the server since the download started.")
                return
            }
            guard let path = served?.transcodingUrl, let playSessionId = info.playSessionId,
                  var masterURL = Self.address(path, client: client)
            else {
                host?.stopJob(id, because: "\(serverName) wouldn't transcode this\(info.errorCode.map { " (\($0))" } ?? ""). Choose a version to download as it is.")
                return
            }
            if HLSPlaylist.queryValue("SegmentLength", in: masterURL.absoluteString) == nil {
                masterURL.append(queryItems: [URLQueryItem(name: "SegmentLength", value: String(TranscodeRequest.segmentLength))])
            }
            let master = HLSPlaylist(try await text(at: masterURL))
            guard let variant = master.variantURI, let mainURL = URL(string: variant, relativeTo: masterURL)?.absoluteURL else {
                throw FragmentedMP4.Problem(message: "The server's playlist names no stream.")
            }
            let mainText = try await text(at: mainURL)
            let playlist = HLSPlaylist(mainText)
            guard playlist.mapURI != nil, !playlist.segments.isEmpty else {
                throw FragmentedMP4.Problem(message: "The server's playlist lists no pieces.")
            }
            try storage.savePlaylist(mainText, for: id)
            playlists[id] = playlist
            let base = Self.basePath(of: masterURL, server: client.serverURL)
            Self.log.info("""
                [\(id.uuidString.prefix(8))] Transcode ready: play session \(playSessionId, privacy: .public), \(playlist.segments.count) \
                pieces listed, \(master.variantAttributes ?? "", privacy: .public)
                """)
            host?.changeJob(id) { job in
                guard var transcode = job.transcode else { return }
                transcode.playSessionId = playSessionId
                transcode.playlistBase = base
                transcode.sourceTag = served?.eTag ?? transcode.sourceTag
                transcode.videoBitrate = HLSPlaylist.queryValue("VideoBitrate", in: path).flatMap(Int.init)
                // Copied audio keeps the stream's own bitrate; the address names the encoder's ceiling.
                let copiesAudio = HLSPlaylist.queryValue("AudioCodec", in: path)?.lowercased() == "copy"
                transcode.audioBitrate = copiesAudio ? nil : HLSPlaylist.queryValue("AudioBitrate", in: path).flatMap(Int.init)
                transcode.variant = master.variantAttributes
                transcode.checkedAt = .now
                // A new play session is a new transcode on the server, which has made nothing yet.
                transcode.heldSince = nil
                if !transcode.collected.isEmpty { transcode.needsInitCheck = true }
                job.transcode = transcode
                job.recordSuccess()
            }
            live[id] = Live()
        } catch {
            stepFailed(id, .prepare, error)
        }
    }

    /// The path the playlists sit under, from the server's address: "videos/<id>/".
    static func basePath(of playlist: URL, server: URL) -> String {
        let folder = playlist.deletingLastPathComponent().path
        let root = server.path
        let relative = folder.hasPrefix(root) ? String(folder.dropFirst(root.count)) : folder
        let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }

    private func initURL(for id: UUID) -> URL? {
        guard let client, let state = job(id)?.transcode, let base = state.playlistBase, let map = playlist(for: id)?.mapURI else { return nil }
        return Self.address(base + map, client: client)
    }

    /// The init segment of a transcode starting from nothing: asking for it starts the server's
    /// transcode at the beginning. It begins the file, and says whether the picture kept HDR.
    private func fetchInit(_ id: UUID) async {
        guard let url = initURL(for: id) else { return }
        live[id, default: Live()].activity = .preparing
        defer { live[id]?.activity = nil }
        do {
            let data = try await self.data(at: url)
            let parsed = try FragmentedMP4.header(data)
            guard job(id)?.transcode?.fileLength == 0 else { return }
            try storage.beginTranscodedFile(header: data, for: id)
            headers[id] = (data, parsed)
            timelines[id] = nil
            host?.changeJob(id) { job in
                job.transcode?.fileLength = Int64(data.count)
                job.transcode?.sideBytes += Int64(data.count)
                job.transcode?.videoRangeType = parsed.videoRangeType
                job.recordSuccess()
            }
            // Asking for it started the transcode, which shows by the time it has settled.
            live[id, default: Live()].probedAt = .now
            pollSoon(id, after: TranscodeServer.progressLag)
        } catch {
            stepFailed(id, .fetchInit, error)
        }
    }

    /// The server's transcode may have started again: its init segment, now made again, has to
    /// describe the tracks the file starts with, decoded the same way, for the pieces after to
    /// join it (`FragmentedMP4.decodeAlike`). Asked for once a piece has come since, so the
    /// server has it rather than starting a transcode to make it; a server not transcoding then
    /// has the pieces left (`TranscodeState.heldSince`).
    private func checkInit(_ id: UUID) async {
        guard let url = initURL(for: id), let saved = header(for: id) else { return }
        live[id, default: Live()].activity = .checkingInit
        defer { live[id]?.activity = nil }
        do {
            let data = try await self.data(at: url)
            guard try FragmentedMP4.decodeAlike(data, saved.data) else {
                Self.log.error("[\(id.uuidString.prefix(8))] The restarted transcode's init segment differs (\(data.count) bytes, was \(saved.data.count))")
                restartFromNothing(id, because: "The server's transcode came back different from before.")
                return
            }
            let now = Date.now
            let isHeld = live[id]?.probedAt != nil && knownServer(of: id, now: now) == .ended
            Self.log.info("""
                [\(id.uuidString.prefix(8))] The server's init segment matches the one kept\
                \(isHeld ? "; it isn't transcoding, so it has the pieces left" : "")
                """)
            live[id]?.probe = nil
            live[id]?.probedAt = nil
            host?.changeJob(id) { job in
                job.transcode?.needsInitCheck = false
                job.transcode?.unchecked = IndexSet()
                job.transcode?.initCheckedAt = now
                if isHeld {
                    job.transcode?.heldSince = now
                    job.transcode?.stopsAtSamePlace = 0
                }
                job.recordSuccess()
            }
            assemble(id)
        } catch {
            stepFailed(id, .checkInit, error)
        }
    }

    /// Checks the joined file and indexes it in place (`TranscodeVerifier`). Bad pieces are
    /// fetched again, twice at most; anything else wrong stops the job with what it has kept,
    /// which a later build can check again without fetching it again.
    private func verify(_ id: UUID) async {
        guard let state = job(id)?.transcode, state.pieceCount != nil else { return }
        guard let header = header(for: id) else {
            restartFromNothing(id, because: "The download's init segment went missing from this device.")
            return
        }
        live[id, default: Live()].activity = .checkingFile
        defer { live[id]?.activity = nil }
        let started = ContinuousClock.now
        let outcome: TranscodeVerifier.Outcome
        do {
            outcome = try await TranscodeVerifier.verify(storage.partialFile(for: id), header: header.data, runtime: state.runtimeSeconds)
        } catch {
            writeFailed(id, error)
            return
        }
        let took = ContinuousClock.now - started
        switch outcome {
        case .good(let length, let openSeconds, let videoRangeType):
            Self.log.info("""
                [\(id.uuidString.prefix(8))] The download checks out in \(took.formatted(.units(allowed: [.seconds, .milliseconds]))): \
                \(length) bytes, which open in \(Int(openSeconds * 1000)) ms
                """)
            host?.changeJob(id) { job in
                job.transcode?.isVerified = true
                job.transcode?.verifyFailure = nil
                job.transcode?.repairRounds = 0
                if let videoRangeType { job.transcode?.videoRangeType = videoRangeType }
                job.totalBytes = length
            }
        case .badPieces(let places, let reason):
            Self.log.error("[\(id.uuidString.prefix(8))] The joined file didn't check out: \(reason, privacy: .public)")
            guard state.repairRounds < 2 else {
                host?.stopJob(id, because: "The download still didn't check out after fetching the pieces again: \(reason). \(Self.kept)")
                return
            }
            let numbers = Array(state.piecesInFile)
            var mends: [Int: TranscodeState.Mend] = [:]
            for (place, bad) in places where numbers.indices.contains(place) {
                mends[numbers[place]] = TranscodeState.Mend(bytes: bad.bytes, start: bad.start, end: bad.end)
            }
            guard !mends.isEmpty else {
                host?.stopJob(id, because: "The download didn't check out: \(reason) \(Self.kept)")
                return
            }
            host?.changeJob(id) { job in
                job.transcode?.mends = mends
                job.transcode?.collected.subtract(IndexSet(mends.keys))
                job.transcode?.repairRounds += 1
                job.transcode?.verifyFailure = reason
            }
        case .endsEarly(let delivered, let runtime):
            Self.log.error("[\(id.uuidString.prefix(8))] The transcode ends at \(delivered) s of \(runtime) s")
            host?.stopJob(id, because: """
                The server's transcode ends \(Self.clock(delivered)) in, but the title runs \(Self.clock(runtime)). \
                Retry to try again, or download a version as it is.
                """)
        case .unmendable(let reason):
            Self.log.error("[\(id.uuidString.prefix(8))] The joined file didn't check out: \(reason, privacy: .public)")
            host?.stopJob(id, because: "The download didn't check out: \(reason) \(Self.kept)")
        }
    }

    /// What a download that didn't check out keeps, said after why.
    private static let kept = "What it fetched is kept, so an update to vinnyfin can check it again without fetching it again; Retry checks it again now."

    /// Drops everything the job has collected and the server's transcode, to start over; after
    /// two start-overs, a third stops it instead, saying why.
    private func restartFromNothing(_ id: UUID, because reason: String) {
        guard let job = job(id), let state = job.transcode else { return }
        guard state.startOvers < 2 else {
            host?.stopJob(id, because: "\(reason) It started over twice already; Retry starts it again.")
            return
        }
        stopServerTranscode(of: job)
        forgetLocally(id)
        host?.startOver(id, because: reason)
    }

    // MARK: Keeping the transcode alive

    private func follow(_ id: UUID?) {
        currentJobId = id
        guard id != nil, heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            await self?.beat()
            self?.heartbeat = nil
        }
    }

    /// Pings the transcode in hand and looks at how far the server has got, for as long as
    /// there's one to keep alive.
    private func beat() async {
        var tick = 0
        while !Task.isCancelled, let id = currentJobId, let host,
              let job = job(id), job.status == .active, let state = job.transcode, state.isPrepared, !job.isTransferComplete {
            // Pieces the server has kept need nothing kept alive.
            let pinging = !state.isHeld(at: .now) && !(host.isPausedForPlayback && host.isPlaybackTranscoding)
            if pinging, tick % (Self.pingInterval / Self.pollInterval) == 0 { await ping(id) }
            if tick % (host.isInFront ? 1 : 3) == 0 { await poll(id) }
            tick += 1
            try? await Task.sleep(for: .seconds(Self.pollInterval))
        }
    }

    private func ping(_ id: UUID) async {
        guard let client, let playSessionId = job(id)?.transcode?.playSessionId else { return }
        do {
            try await client.pingPlaySession(playSessionId)
            let now = Date.now
            host?.changeJob(id) { $0.transcode?.lastPing = now }
        } catch {
            Self.log.notice("[\(id.uuidString.prefix(8))] Ping failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A piece's request found the server down, refusing connections, or starting up (HTTP
    /// 503): once it's back it has forgotten the transcode, and asking for the pieces out in
    /// whatever order they reach it would start its transcode at one of them, and again at
    /// each earlier one. Taken as gone until the server says otherwise, so they're taken back
    /// and the first missing piece is asked for alone, which starts the transcode there.
    func serverDown(_ id: UUID) {
        guard job(id)?.transcode != nil, live[id]?.server != .gone else { return }
        Self.log.notice("[\(id.uuidString.prefix(8))] The server is down or starting up")
        live[id, default: Live()].server = .gone
        live[id]?.probedAt = nil
        polledAt[id] = .now
        if job(id)?.transcode?.heldSince != nil { host?.changeJob(id) { $0.transcode?.heldSince = nil } }
        host?.transcodesChanged()
    }

    private func pollSoon(_ id: UUID, after delay: TimeInterval = 0) {
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await self?.poll(id)
        }
    }

    private func poll(_ id: UUID) async {
        guard !polling.contains(id), let client, job(id)?.transcode?.isPrepared == true else { return }
        polling.insert(id)
        defer { polling.remove(id) }
        do {
            let sessions: [TranscodingSession] = try await client.sessions(deviceId: client.deviceId)
            let own = sessions.first { $0.deviceId == client.deviceId }
            observe(sessionFound: own != nil, transcoding: own?.transcodingInfo, for: id, now: .now)
        } catch {
            Self.log.notice("[\(id.uuidString.prefix(8))] Couldn't ask how far the server has got: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Takes in what the server said about the transcode. Transcoding after it was seen not to
    /// be, or behind where it was, it started again without this download seeing it, and its
    /// init segment may differ; transcoding at all, the pieces left aren't waiting on it.
    private func observe(sessionFound: Bool, transcoding: TranscodingInfo?, for id: UUID, now: Date) {
        guard let state = job(id)?.transcode, live[id]?.isRestarting != true else { return }
        var live = self.live[id] ?? Live()
        let previous = live.server
        let server = TranscodeServer.interpret(sessionFound: sessionFound, transcoding: transcoding, runtime: state.runtimeSeconds)
        var change: ((inout TranscodeState) -> Void)?
        switch server {
        case .running(let position):
            let startedAfresh = switch previous {
            case .ended, .gone: true
            case .running(let before): position + state.pieceLength < before
            case .unknown: false
            }
            // Before any piece is in, a start is the first.
            let restarted = startedAfresh && !state.collected.isEmpty
            if restarted { Self.log.notice("[\(id.uuidString.prefix(8))] The server's transcode started again at \(Int(position)) s") }
            let checks = restarted && !state.needsInitCheck
            if checks || state.heldSince != nil {
                change = { transcode in
                    transcode.heldSince = nil
                    if checks { transcode.needsInitCheck = true }
                }
            }
        case .gone:
            if previous != .gone {
                Self.log.notice("[\(id.uuidString.prefix(8))] The server doesn't know the downloads' device: it restarted")
                if state.heldSince != nil { change = { $0.heldSince = nil } }
            }
            // On each look that finds it forgotten: the last telling may not have got through,
            // or came before a restart the app had already taken the server to be down for.
            register()
        case .ended, .unknown:
            break
        }
        let wasStale = knownServer(of: id, now: now) == .unknown
        polledAt[id] = now
        live.observe(server)
        live.throttle.observe(position: server.position, downloadPosition: state.downloadPosition, now: now)
        self.live[id] = live
        if let change {
            host?.changeJob(id) { job in
                guard var transcode = job.transcode else { return }
                change(&transcode)
                job.transcode = transcode
            }
        }
        // The window moves a piece at a time; a piece asked for alone waits on this.
        let length = state.pieceLength
        func step(_ server: TranscodeServer) -> TranscodeServer {
            server.position.map { .running(position: ($0 / length).rounded(.down)) } ?? server
        }
        if wasStale || step(previous) != step(server) || live.probedAt != nil { host?.transcodesChanged() }
    }

    /// Tells the server about the downloads' device again, which it forgets when it restarts:
    /// without it, it doesn't say how far a transcode has got.
    private func register() {
        guard let client else { return }
        Task {
            do {
                try await client.reportCapabilities(ClientCapabilities(PlayableMediaTypes: [], SupportedCommands: [], SupportsMediaControl: false))
            } catch {
                Self.log.notice("Couldn't tell the server about the downloads' device: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Leaving

    /// The job is done with, finished or not: the server's copy and what's kept for it here go.
    func leave(_ job: DownloadJob) {
        guard job.transcode != nil else { return }
        stopServerTranscode(of: job)
        forgetLocally(job.id)
        do {
            try storage.removeTranscodeFiles(for: job.id)
        } catch {
            Self.log.error("Couldn't delete the pieces of \(job.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func forgetLocally(_ id: UUID) {
        work.removeValue(forKey: id)?.cancel()
        live[id] = nil
        playlists[id] = nil
        headers[id] = nil
        timelines[id] = nil
        polledAt[id] = nil
        reconciled.remove(id)
        if currentJobId == id { currentJobId = nil }
    }

    /// Deletes the server's copy of the job's transcode, which it would otherwise keep for a
    /// day once finished.
    private func stopServerTranscode(of job: DownloadJob) {
        guard let client, let playSessionId = job.transcode?.playSessionId else { return }
        let title = job.title
        cleanups.append(Task {
            do {
                try await client.stopTranscoding(playSessionId: playSessionId)
                Self.log.info("Deleted the server's transcode of \(title, privacy: .public)")
            } catch {
                Self.log.notice("Couldn't delete the server's transcode of \(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    /// Waits for the server's copies of transcodes left to be deleted, as signing out does
    /// before the sign-in goes.
    func finishCleanups() async {
        let pending = cleanups
        cleanups = []
        for task in pending { await task.value }
    }

    // MARK: Permissions

    /// Why the account may not have `plan`, from its permissions as the server last gave them,
    /// asked for again when they're older than a few minutes. Nil when it may, or when the
    /// server can't be asked now: a transcode asks again before it starts, and every download
    /// once the app is back in front after a while.
    func refusal(for plan: DownloadPlan) async -> String? {
        let serverName = accounts.account?.serverTitle ?? "The server"
        do {
            return try await currentPolicy().refusal(for: plan, serverName: serverName)
        } catch {
            Self.log.notice("Couldn't look at the account's permissions: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A transcoded download someone asked for, waiting for them to agree to what it takes, with
    /// the version that downloads as it is instead.
    struct Proposal: Identifiable {
        let id = UUID()
        let item: JellyfinItem
        let plan: DownloadPlan
        let original: DownloadPlan

        /// What the alert asking says.
        var message: String {
            let quality = plan.transcode?.quality.label ?? "the download quality"
            return "Every version of \(item.name) is bigger than \(quality). The server can make one: \(plan.summary). "
                + "It takes longer than a version as it is, as the server works through the whole title while it downloads."
        }
    }

    var proposal: Proposal?

    private func currentPolicy(maxAge: TimeInterval = policyLifetime) async throws -> DownloadPolicy {
        if let policy, Date.now.timeIntervalSince(policy.fetchedAt) < maxAge { return policy.value }
        guard let client else { throw JellyfinError.invalidCredentials }
        let user: CurrentUser = try await client.currentUser()
        policy = (user.policy, .now)
        return user.policy
    }

    /// Looks at whether the account may still download, after `recheckAfter` without looking,
    /// and stops what's queued when it no longer may.
    func recheckPolicy() async {
        guard let host, host.jobs.contains(where: { $0.status == .active }), let account = accounts.account else { return }
        do {
            let policy = try await currentPolicy(maxAge: Self.recheckAfter)
            guard let refusal = policy.downloadRefusal(serverName: account.serverTitle) else { return }
            for job in host.jobs where job.status == .active { host.stopJob(job.id, because: refusal) }
        } catch {
            Self.log.notice("Couldn't look at the account's permissions: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Data

    private func data(at url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(TranscodeIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw JellyfinError.http(status: http.statusCode, body: String(decoding: body.prefix(200), as: UTF8.self))
        }
        return body
    }

    private func text(at url: URL) async throws -> String {
        String(decoding: try await data(at: url), as: UTF8.self)
    }
}

extension DownloadManager {
    /// Downloads an item someone asked for, as their settings say unless they picked a version:
    /// a version as it is straight away, a transcode once they've agreed to what it takes
    /// (`TranscodedDownloads.proposal`). Returns why it can't be downloaded, to tell them.
    func download(_ item: JellyfinItem, picked: MediaSource? = nil, settings: AppSettings) async -> String? {
        guard let plan = DownloadPlanner.plan(for: item, picked: picked, settings: settings) else {
            return "The server lists no versions of \(item.name) to download."
        }
        if let refusal = await transcodes.refusal(for: plan) { return refusal }
        if plan.transcode != nil {
            // The smallest version, which downloads with Transcode When No Version Fits off.
            let original = VersionChooser.choose(from: item.mediaSources ?? [], quality: settings.downloadQuality)
                .map(DownloadPlan.original) ?? .original(plan.source)
            transcodes.proposal = TranscodedDownloads.Proposal(item: item, plan: plan, original: original)
        } else {
            enqueue(item, plan: plan, startedByUser: true)
        }
        return nil
    }
}
#endif
