import Combine
import Foundation
import GroupActivities
import Observation
import OSLog

/// Watching a server title together with the people on a FaceTime call. Each participant plays
/// it from their own sign-in to the same server, in step: AVFoundation's playback coordinator
/// keeps the pauses, seeks and speed the same everywhere, through `PlaybackGroup`; the session's
/// activity carries the title, and so the group's move to another episode, to everyone, late
/// joiners included; and the messenger carries only who can't watch, and why.
@Observable
final class SharePlay {
    /// The group watching together, as this device's controls show it.
    struct Group: Equatable {
        var title: String
        var serverName: String
        var participantCount: Int
        /// What the participants who couldn't watch said.
        var cantWatch: [String]
    }

    /// A FaceTime call is on, so an activity started here goes to everyone on it.
    private(set) var isEligible = false
    private(set) var group: Group?
    /// Why this device couldn't join or start a group, to show.
    var problem: String?

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let player: PlayerCoordinator
    @ObservationIgnored private let stateObserver = GroupStateObserver()
    @ObservationIgnored private var session: GroupSession<WatchTogether>?
    @ObservationIgnored private var messenger: GroupSessionMessenger?
    @ObservationIgnored private var coordinator: SharedCoordinator?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var playbackGroup: PlaybackGroup?
    @ObservationIgnored private weak var attachedModel: PlayerModel?
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    /// The item the group made this device load, which waits for the group's timing.
    @ObservationIgnored private var heldItemId: String?
    /// A playback started here as a group, which plays once the session does.
    @ObservationIgnored private var pendingRequest: PlaybackRequest?
    @ObservationIgnored private var cantWatch: [UUID: CantWatch] = [:]

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "shareplay")

    init(accounts: AccountStore, player: PlayerCoordinator) {
        self.accounts = accounts
        self.player = player
    }

    /// Joins the sessions people start, here or on another device, for as long as the app runs.
    func run() async {
        let eligibility = Task {
            for await eligible in stateObserver.$isEligibleForGroupSession.values { isEligible = eligible }
        }
        defer { eligibility.cancel() }
        await Self.receiveSessions { [weak self] session in await self?.join(session) }
    }

    /// Hands each session to `join` once it's set up. Off the main actor: on Vision Pro that's
    /// where the session's system coordinator is.
    @concurrent
    private nonisolated static func receiveSessions(_ join: @escaping @MainActor (sending GroupSession<WatchTogether>) async -> Void) async {
        for await session in WatchTogether.sessions() {
            #if os(visionOS)
            // Spatial Personas sit side by side before the player's window, and share the cinema
            // when it opens.
            if let systemCoordinator = await session.systemCoordinator {
                var configuration = SystemCoordinator.Configuration()
                configuration.spatialTemplatePreference = .sideBySide
                configuration.supportsGroupImmersiveSpace = true
                systemCoordinator.configuration = configuration
            }
            #endif
            await join(session)
        }
    }

    // MARK: Starting

    /// The activity for a server title, on the server signed in to.
    func activity(itemId: String, title: String, subtitle: String? = nil) -> WatchTogether? {
        guard let account = accounts.account else { return nil }
        return WatchTogether(serverId: account.serverId, serverName: account.serverName ?? account.serverURL.host() ?? "Jellyfin",
                             itemId: itemId, title: title, subtitle: subtitle)
    }

    /// Starts watching together, with everyone on the call, playing `request` here once it has
    /// started when it isn't playing already. False when it didn't start.
    @discardableResult
    func start(_ activity: WatchTogether, playing request: PlaybackRequest? = nil) async -> Bool {
        pendingRequest = request
        do {
            if try await activity.activate() { return true }
        } catch {
            problem = "SharePlay didn't start: \(error.localizedDescription)"
        }
        pendingRequest = nil
        return false
    }

    /// What to do with a playback the viewer starts.
    enum Offer: Equatable {
        /// Play it here only.
        case playHere
        /// The group plays it, here too, as the session starts.
        case playTogether
        case cancelled
    }

    /// On a FaceTime call, asks whether to watch a server title with everyone on it, as a playback
    /// starts.
    func offer(_ request: PlaybackRequest) async -> Offer {
        guard isEligible, session == nil, case .item(let itemId, _) = request.source,
              let activity = activity(itemId: itemId, title: request.title) else { return .playHere }
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            return await start(activity, playing: request) ? .playTogether : .playHere
        case .activationDisabled:
            return .playHere
        case .cancelled:
            return .cancelled
        @unknown default:
            return .playHere
        }
    }

    func leave() {
        session?.leave()
    }

    func endForEveryone() {
        session?.end()
    }

    // MARK: The session

    private func join(_ session: GroupSession<WatchTogether>) async {
        endSession()
        let activity = session.activity
        let access = activity.access(for: accounts.account)
        let messenger = GroupSessionMessenger(session: session)
        if let refusal = activity.refusal(access), let message = CantWatch(access) {
            // Joins only to tell the others why, then leaves.
            session.join()
            do {
                try await messenger.send(message)
            } catch {
                Self.log.error("Couldn't tell the group why this device can't join: \(error.localizedDescription, privacy: .public)")
            }
            session.leave()
            problem = refusal
            return
        }
        self.session = session
        self.messenger = messenger
        cantWatch = [:]
        let coordinator = SharedCoordinator(session: session)
        self.coordinator = coordinator
        group = Group(title: activity.title, serverName: activity.serverName, participantCount: session.activeParticipants.count,
                      cantWatch: [])
        session.join()
        Self.log.info("Joined SharePlay for \(activity.title, privacy: .public), started \(session.isLocallyInitiated ? "here" : "elsewhere", privacy: .public)")
        sessionTasks = [
            Task {
                for await state in session.$state.values {
                    if case .invalidated(let reason) = state {
                        Self.log.info("SharePlay ended: \(String(describing: reason), privacy: .public)")
                        endSession()
                        return
                    }
                }
            },
            Task {
                for await participants in session.$activeParticipants.values {
                    group?.participantCount = participants.count
                    // Someone who left takes their reason with them.
                    cantWatch = cantWatch.filter { id, _ in participants.contains { $0.id == id } }
                    group?.cantWatch = cantWatch.values.map { $0.describe(serverName: activity.serverName) }
                }
            },
            Task {
                for await (message, context) in messenger.messages(of: CantWatch.self) {
                    cantWatch[context.source.id] = message
                    group?.cantWatch = cantWatch.values.map { $0.describe(serverName: activity.serverName) }
                }
            },
            Task {
                // What the group moves to next; the first is the title it started with.
                for await activity in session.$activity.values.dropFirst() {
                    group?.title = activity.title
                    follow(activity, waitsForGroup: true)
                }
            },
            Task {
                for await model in Observations({ self.player.presented }) {
                    attach(model)
                }
            },
        ]
        // Where the group started here, this device sets the group's timing as it plays.
        follow(activity, waitsForGroup: !session.isLocallyInitiated)
    }

    /// Plays what the group plays, unless it already plays here; waiting for the group's timing,
    /// or setting it.
    private func follow(_ activity: WatchTogether, waitsForGroup: Bool) {
        // The viewer's own request, with the version they picked, for the title they started the group with.
        var request: PlaybackRequest?
        if let pendingRequest, case .item(let id, _) = pendingRequest.source, id == activity.itemId { request = pendingRequest }
        pendingRequest = nil
        guard player.presented?.requestedItemId != activity.itemId else { return }
        if waitsForGroup {
            heldItemId = activity.itemId
            playbackGroup?.heldItemId = activity.itemId
        }
        let item = JellyfinItem(id: activity.itemId, name: activity.title, type: "Video")
        if let model = player.presented {
            Task { await model.play(item) }
        } else {
            player.open(request ?? .item(item))
        }
    }

    /// Drives the playback on screen from the group. Closing the player leaves the group.
    private func attach(_ model: PlayerModel?) {
        guard model !== attachedModel else { return }
        let hadPlayback = attachedModel != nil
        playbackGroup?.detach()
        attachedModel?.sharing = nil
        modelTask?.cancel()
        playbackGroup = nil
        attachedModel = model
        guard let model, let coordinator else {
            if hadPlayback { leave() }
            return
        }
        let group = PlaybackGroup(playback: model, coordinator: coordinator)
        group.heldItemId = heldItemId
        group.onItemChange = { [weak self, weak model] itemId in
            guard let model else { return }
            self?.announce(itemId, of: model)
        }
        group.onFailure = { [weak self] message in self?.tell(CantWatch(.failed(message))) }
        coordinator.group = group
        model.sharing = group
        playbackGroup = group
        modelTask = Task {
            for await _ in Observations({ model.status }) {
                group.playbackChanged()
            }
        }
    }

    /// Moves the group to the item the viewer started here.
    private func announce(_ itemId: String, of model: PlayerModel) {
        heldItemId = nil
        guard let session, session.activity.itemId != itemId, let item = model.item,
              let activity = activity(itemId: itemId, title: item.titleWithYear, subtitle: PlaybackResolver.subtitle(item)),
              activity.serverId == session.activity.serverId else { return }
        session.activity = activity
    }

    private func tell(_ message: CantWatch) {
        guard let messenger else { return }
        Task {
            do {
                try await messenger.send(message)
            } catch {
                Self.log.error("Couldn't tell the group: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func endSession() {
        for task in sessionTasks { task.cancel() }
        sessionTasks = []
        modelTask?.cancel()
        modelTask = nil
        playbackGroup?.detach()
        attachedModel?.sharing = nil
        attachedModel = nil
        playbackGroup = nil
        coordinator = nil
        messenger = nil
        session = nil
        heldItemId = nil
        group = nil
    }
}
