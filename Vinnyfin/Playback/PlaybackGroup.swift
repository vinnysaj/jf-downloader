import AVFoundation
import CoreMedia
import Foundation
import GroupActivities
import OSLog

/// A playback as the group watching together drives it: the item it plays or loads, how it's
/// going, and the changes the group makes, which skip the group on their way to the engine.
protocol GroupPlayback: AnyObject {
    /// The server item asked for, while it loads and once it plays.
    var groupItemId: String? { get }
    var status: PlayerModel.Status { get }
    var groupPosition: Double { get }
    var rate: Float { get }
    func applyRate(_ rate: Float)
    func applySeek(to seconds: Double) async
}

extension PlayerModel: GroupPlayback {
    var groupItemId: String? { requestedItemId }
    var groupPosition: Double { clock.time }
}

/// The playback coordinator's side, as `PlaybackGroup` uses it: AVFoundation's
/// `AVDelegatingPlaybackCoordinator` connected to the SharePlay session, in `SharedCoordinator`.
protocol GroupCoordination: AnyObject {
    /// The item the coordinator matches with the group's; commands are for it.
    var currentItemIdentifier: String? { get }
    func coordinateRateChange(to rate: Float)
    func coordinateSeek(to seconds: Double)
    /// Moves to another item, proposing its timing when the viewer chose it: where it is and how
    /// fast it plays, 0 paused. Without one, the playback takes the group's.
    func transition(to itemId: String, proposing timing: GroupTiming.Proposal?)
    /// Keeps the group from driving this playback while it can't follow, as when it rebuffers.
    func beginStallSuspension() -> any GroupSuspension
    /// Has the coordinator issue the group's timing again, to bring this playback back into line.
    func reapplyCurrentItemState()
}

protocol GroupSuspension: AnyObject {
    func end()
}

/// A command the coordinator issues, for the item it names.
nonisolated enum GroupCommand: Equatable, Sendable {
    /// Play at `rate` so that `itemTime` is on screen at `hostTime`, in host clock seconds.
    case play(itemId: String, itemTime: Double, hostTime: Double, rate: Float)
    case pause(itemId: String)
    /// Move to `itemTime`; when `buffers`, be ready to play there, by `due` (host seconds) at the latest.
    case seek(itemId: String, itemTime: Double, buffers: Bool, due: Double?)
    /// Get ready to play, by `due` at the latest.
    case buffer(itemId: String, due: Double?)

    var itemId: String {
        switch self {
        case .play(let itemId, _, _, _), .pause(let itemId), .seek(let itemId, _, _, _), .buffer(let itemId, _): itemId
        }
    }
}

/// How a playback catches up with the group's timing.
nonisolated enum GroupTiming {
    struct Proposal: Equatable, Sendable {
        var position: Double
        /// 0 paused.
        var rate: Float
    }

    struct Plan: Equatable, Sendable {
        /// Nil when the playback is close enough where it is.
        var seekTo: Double?
        /// When to start playing, in host clock seconds.
        var startAt: Double
    }

    /// How far from the group's position a playback may be and still just play.
    static let tolerance: Double = 0.25
    /// How far ahead of the group a seek lands, for the time the seek itself takes; the playback
    /// starts as the group gets there.
    static let lead: Double = 1

    /// For a play command: the group plays `itemTime` at `hostTime` at `rate`; the playback is at
    /// `position` at `now`.
    static func plan(itemTime: Double, hostTime: Double, rate: Float, position: Double, now: Double) -> Plan {
        if now < hostTime {
            // The group starts later, from itemTime.
            return Plan(seekTo: abs(position - itemTime) > tolerance ? itemTime : nil, startAt: hostTime)
        }
        let groupPosition = itemTime + (now - hostTime) * Double(rate)
        if abs(position - groupPosition) <= tolerance {
            return Plan(seekTo: nil, startAt: now)
        }
        return Plan(seekTo: groupPosition + lead * Double(rate), startAt: now + lead)
    }
}

/// Drives one playback from the group watching it together, and the group from it. The viewer's
/// transport goes to the coordinator, which issues it to everyone; the coordinator's commands
/// play, pause and seek the playback; a playback that rebuffers or reloads its stream holds the
/// group back until it's ready again; and a new item the viewer starts is proposed to the group.
final class PlaybackGroup: PlaybackSharing {
    private weak var playback: (any GroupPlayback)?
    private let coordinator: any GroupCoordination
    /// The host clock, in seconds.
    private let now: () -> Double
    private let sleep: (Double) async -> Void
    /// An item the group made this playback load, which waits for the group to start it.
    var heldItemId: String?
    /// The rate the group last set, 0 for paused; nil until its first command.
    private(set) var groupRate: Float?
    /// Told when the viewer starts an item the group isn't on, which the group then moves to.
    var onItemChange: ((String) -> Void)?
    /// Told when an item the group made this playback load didn't play.
    var onFailure: ((String) -> Void)?
    private var stall: (any GroupSuspension)?
    /// Commands of the coordinator's being carried out, whose seeks rebuffer as part of them.
    private var commandsUnderway = 0
    /// A command for this item came while the playback couldn't take it, so it takes the group's
    /// timing once it can.
    private var missedCommand = false

    init(playback: any GroupPlayback, coordinator: any GroupCoordination,
         now: @escaping () -> Double = { CMClockGetTime(CMClockGetHostTimeClock()).seconds },
         sleep: @escaping (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.playback = playback
        self.coordinator = coordinator
        self.now = now
        self.sleep = sleep
    }

    /// Whether the playback is on the item the coordinator is matching with the group's.
    private var isOnGroupItem: Bool {
        guard let itemId = playback?.groupItemId else { return false }
        return coordinator.currentItemIdentifier == itemId
    }

    // MARK: The viewer's changes

    func share(_ change: SharedChange) -> Bool {
        // A playback that isn't on the group's timeline yet, still loading a new item, keeps its own.
        guard let playback, isOnGroupItem else { return false }
        switch change {
        case .rate(let rate):
            if rate != 0, groupRate == rate, !Self.isPlaying(playback.status) {
                // The group plays and this one stopped by itself, as for a call: back to where the group is.
                coordinator.reapplyCurrentItemState()
            } else {
                coordinator.coordinateRateChange(to: rate)
            }
        case .seek(let seconds):
            coordinator.coordinateSeek(to: seconds)
        }
        return true
    }

    func startsByItself(_ itemId: String?) -> Bool {
        guard let itemId else { return true }
        // What the group made this load, and a new stream of the group's item, wait for the group's timing.
        return itemId != heldItemId && itemId != coordinator.currentItemIdentifier
    }

    // MARK: Following the playback

    /// Call on every change of the playback's status or item.
    func playbackChanged() {
        guard let playback, let itemId = playback.groupItemId else { return }
        switch playback.status {
        case .preparing, .loading, .buffering:
            // Only for the group's item, and not while carrying out the group's own seek: a
            // playback leaving the item for another doesn't hold the others back.
            if isOnGroupItem, stall == nil, commandsUnderway == 0 { stall = coordinator.beginStallSuspension() }
        case .playing, .paused:
            if !isOnGroupItem {
                // A new item: the viewer's own choice proposes its timing to the group, and one the
                // group made this load takes the group's.
                let isOwnChoice = itemId != heldItemId
                let proposal = GroupTiming.Proposal(position: playback.groupPosition,
                                                    rate: playback.status == .playing ? playback.rate : 0)
                coordinator.transition(to: itemId, proposing: isOwnChoice ? proposal : nil)
                heldItemId = nil
                endStall()
                if isOwnChoice { onItemChange?(itemId) }
            } else if let stall {
                // The coordinator brings the playback back to the group's timing as the last suspension ends.
                stall.end()
                self.stall = nil
            } else if missedCommand {
                coordinator.reapplyCurrentItemState()
            }
            missedCommand = false
        case .failed(let message):
            endStall()
            if itemId == heldItemId { onFailure?(message) }
        case .ended:
            endStall()
        }
    }

    private func endStall() {
        stall?.end()
        stall = nil
    }

    /// Lets go of the playback, which plays on by itself.
    func detach() {
        endStall()
        playback = nil
    }

    // MARK: The coordinator's commands

    func handle(_ command: GroupCommand) async {
        // A command for another item is obsolete; one while loading is made up for once it's loaded.
        guard let playback, command.itemId == playback.groupItemId else { return }
        guard Self.isReady(playback.status) else {
            missedCommand = true
            return
        }
        commandsUnderway += 1
        defer { commandsUnderway -= 1 }
        switch command {
        case .play(_, let itemTime, let hostTime, let rate):
            groupRate = rate
            let plan = GroupTiming.plan(itemTime: itemTime, hostTime: hostTime, rate: rate,
                                        position: playback.groupPosition, now: now())
            if let seekTo = plan.seekTo { await playback.applySeek(to: seekTo) }
            let wait = plan.startAt - now()
            if wait > 0 { await sleep(wait) }
            playback.applyRate(rate)
        case .pause:
            groupRate = 0
            playback.applyRate(0)
        case .seek(_, let itemTime, let buffers, let due):
            await playback.applySeek(to: itemTime)
            if buffers { await waitUntilReady(by: due) }
        case .buffer(_, let due):
            await waitUntilReady(by: due)
        }
    }

    /// Returns once the playback can play, or at `due`.
    private func waitUntilReady(by due: Double?) async {
        let deadline = due ?? now() + 10
        while let playback, !Self.isReady(playback.status), now() < deadline {
            await sleep(0.1)
        }
    }

    private static func isReady(_ status: PlayerModel.Status) -> Bool {
        status == .playing || status == .paused
    }

    private static func isPlaying(_ status: PlayerModel.Status) -> Bool {
        status == .playing || status == .buffering
    }
}

/// AVFoundation's coordinator for a custom player, connected to the SharePlay session, issuing its
/// commands to a `PlaybackGroup`.
final class SharedCoordinator: NSObject, GroupCoordination, AVPlaybackCoordinatorPlaybackControlDelegate {
    private var coordinator: AVDelegatingPlaybackCoordinator!
    weak var group: PlaybackGroup?

    init(session: GroupSession<WatchTogether>) {
        super.init()
        coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
        // Everyone waits for whoever is rebuffering, and a pause stops everyone on the same frame.
        coordinator.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
        coordinator.pauseSnapsToMediaTimeOfOriginator = true
        coordinator.coordinateWithSession(session)
    }

    var currentItemIdentifier: String? { coordinator.currentItemIdentifier }

    func coordinateRateChange(to rate: Float) {
        coordinator.coordinateRateChange(to: rate, options: [])
    }

    func coordinateSeek(to seconds: Double) {
        coordinator.coordinateSeek(to: CMTime(seconds: seconds, preferredTimescale: 600), options: [])
    }

    func transition(to itemId: String, proposing timing: GroupTiming.Proposal?) {
        var timebase: CMTimebase?
        if let timing {
            let status = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                                         timebaseOut: &timebase)
            if status == noErr, let timebase {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: timing.position, preferredTimescale: 600))
                CMTimebaseSetRate(timebase, rate: Double(timing.rate))
            } else {
                Self.log.error("Couldn't make a timebase to propose (\(status)); the item takes the group's timing")
            }
        }
        coordinator.transitionToItem(withIdentifier: itemId, proposingInitialTimingBasedOn: timebase)
    }

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "shareplay")

    func beginStallSuspension() -> any GroupSuspension {
        CoordinatorSuspension(coordinator.beginSuspension(for: .stallRecovery))
    }

    func reapplyCurrentItemState() {
        coordinator.reapplyCurrentItemStateToPlaybackControlDelegate()
    }

    // MARK: AVPlaybackCoordinatorPlaybackControlDelegate

    nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
                                         didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand,
                                         completionHandler: @escaping @Sendable () -> Void) {
        perform(.play(itemId: playCommand.expectedCurrentItemIdentifier, itemTime: playCommand.itemTime.seconds,
                      hostTime: playCommand.hostClockTime.seconds, rate: playCommand.rate), then: completionHandler)
    }

    nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
                                         didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand,
                                         completionHandler: @escaping @Sendable () -> Void) {
        perform(.pause(itemId: pauseCommand.expectedCurrentItemIdentifier), then: completionHandler)
    }

    nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
                                         didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand,
                                         completionHandler: @escaping @Sendable () -> Void) {
        perform(.seek(itemId: seekCommand.expectedCurrentItemIdentifier, itemTime: seekCommand.itemTime.seconds,
                      buffers: seekCommand.shouldBufferInAnticipationOfPlayback,
                      due: seekCommand.completionDueDate.map(Self.hostSeconds)), then: completionHandler)
    }

    nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
                                         didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand,
                                         completionHandler: @escaping @Sendable () -> Void) {
        perform(.buffer(itemId: bufferingCommand.expectedCurrentItemIdentifier,
                        due: bufferingCommand.completionDueDate.map(Self.hostSeconds)), then: completionHandler)
    }

    /// The coordinator calls from a queue of its own; the group lives on the main actor. Every
    /// command is completed, an obsolete one included, as the coordinator requires.
    private nonisolated func perform(_ command: GroupCommand, then completion: @escaping @Sendable () -> Void) {
        Task { @MainActor [weak self] in
            await self?.group?.handle(command)
            completion()
        }
    }

    /// A date as host clock seconds.
    private nonisolated static func hostSeconds(_ date: Date) -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds + date.timeIntervalSinceNow
    }
}

private final class CoordinatorSuspension: GroupSuspension {
    private let suspension: AVCoordinatedPlaybackSuspension

    init(_ suspension: AVCoordinatedPlaybackSuspension) {
        self.suspension = suspension
    }

    func end() {
        suspension.end()
    }
}
