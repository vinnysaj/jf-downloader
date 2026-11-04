import Foundation
import GroupActivities
import Testing
@testable import vinnyfin

/// A playback the group drives, which does what it's told at once.
private final class FakePlayback: GroupPlayback {
    var groupItemId: String?
    var status = PlayerModel.Status.playing
    var groupPosition: Double = 0
    var rate: Float = 1
    private(set) var applied: [String] = []
    /// What a seek leaves the status at, as a stream that has to fill again would.
    var statusAfterSeek: PlayerModel.Status?
    /// Told as a seek changes the status, while the group's command is still underway.
    var onSeek: (() -> Void)?

    init(item: String?) {
        groupItemId = item
    }

    func applyRate(_ rate: Float) {
        applied.append("rate \(rate)")
        if rate == 0 {
            status = .paused
        } else {
            self.rate = rate
            status = .playing
        }
    }

    func applySeek(to seconds: Double) async {
        applied.append("seek \(seconds)")
        groupPosition = seconds
        if let statusAfterSeek { status = statusAfterSeek }
        onSeek?()
    }
}

/// The coordinator's side, recording what the group was asked to do.
private final class FakeCoordinator: GroupCoordination {
    final class Suspension: GroupSuspension {
        private(set) var ended = false
        func end() { ended = true }
    }

    var currentItemIdentifier: String?
    private(set) var calls: [String] = []
    private(set) var suspensions: [Suspension] = []
    private(set) var proposals: [GroupTiming.Proposal?] = []

    func coordinateRateChange(to rate: Float) { calls.append("rate \(rate)") }
    func coordinateSeek(to seconds: Double) { calls.append("seek \(seconds)") }

    func transition(to itemId: String, proposing timing: GroupTiming.Proposal?) {
        calls.append("transition \(itemId)")
        proposals.append(timing)
        currentItemIdentifier = itemId
    }

    func beginStallSuspension() -> any GroupSuspension {
        calls.append("suspend")
        let suspension = Suspension()
        suspensions.append(suspension)
        return suspension
    }

    func reapplyCurrentItemState() { calls.append("reapply") }
}

/// The host clock, which moves only when the group sleeps.
private final class FakeClock {
    var now: Double = 1000
}

private func makeGroup(_ playback: FakePlayback, _ coordinator: FakeCoordinator, clock: FakeClock = FakeClock()) -> PlaybackGroup {
    PlaybackGroup(playback: playback, coordinator: coordinator, now: { clock.now }, sleep: { clock.now += $0 })
}

struct GroupTimingTests {
    @Test func aLaterStartWaitsForItsTime() {
        let plan = GroupTiming.plan(itemTime: 30, hostTime: 105, rate: 1, position: 30.1, now: 100)
        #expect(plan == .init(seekTo: nil, startAt: 105))
    }

    @Test func aLaterStartFromElsewhereSeeksThereFirst() {
        let plan = GroupTiming.plan(itemTime: 30, hostTime: 105, rate: 1, position: 12, now: 100)
        #expect(plan == .init(seekTo: 30, startAt: 105))
    }

    @Test func closeEnoughJustPlays() {
        let plan = GroupTiming.plan(itemTime: 30, hostTime: 100, rate: 1, position: 32.1, now: 102)
        #expect(plan == .init(seekTo: nil, startAt: 102))
    }

    @Test func farBehindSeeksAheadAndStartsAsTheGroupGetsThere() {
        let plan = GroupTiming.plan(itemTime: 30, hostTime: 100, rate: 1, position: 10, now: 104)
        #expect(plan == .init(seekTo: 34 + GroupTiming.lead, startAt: 104 + GroupTiming.lead))
    }

    @Test func countsTheGroupsSpeed() {
        let plan = GroupTiming.plan(itemTime: 30, hostTime: 100, rate: 2, position: 10, now: 104)
        #expect(plan == .init(seekTo: 38 + 2 * GroupTiming.lead, startAt: 104 + GroupTiming.lead))
    }
}

struct PlaybackGroupTests {
    @Test func theViewersTransportGoesToTheGroup() {
        let playback = FakePlayback(item: "movie")
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let group = makeGroup(playback, coordinator)
        #expect(group.share(.rate(0)))
        #expect(group.share(.seek(42)))
        #expect(group.share(.rate(1.5)))
        #expect(coordinator.calls == ["rate 0.0", "seek 42.0", "rate 1.5"])
    }

    @Test func aPlaybackOffTheGroupsItemKeepsItsOwnTransport() {
        let playback = FakePlayback(item: "loading-next")
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        #expect(!makeGroup(playback, coordinator).share(.rate(0)))
        #expect(coordinator.calls.isEmpty)
    }

    @Test func playingAgainAfterStoppingByItselfRejoinsTheGroup() async {
        let playback = FakePlayback(item: "movie")
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let group = makeGroup(playback, coordinator)
        await group.handle(.play(itemId: "movie", itemTime: 0, hostTime: 1000, rate: 1))
        // An interruption, such as a call, paused the engine; the group plays on.
        playback.status = .paused
        #expect(group.share(.rate(1)))
        #expect(coordinator.calls == ["reapply"])
    }

    @Test func whatTheGroupLoadsWaitsForItsTiming() {
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let group = makeGroup(FakePlayback(item: "movie"), coordinator)
        group.heldItemId = "episode-2"
        #expect(!group.startsByItself("episode-2"))
        // A new stream of the same title, as after a step down in quality.
        #expect(!group.startsByItself("movie"))
        #expect(group.startsByItself("something-else"))
        #expect(group.startsByItself(nil))
    }

    @Test func theViewersOwnTitleMovesTheGroupFromWhereItIs() {
        let playback = FakePlayback(item: "episode-2")
        playback.groupPosition = 12
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "episode-1"
        let group = makeGroup(playback, coordinator)
        var announced: [String] = []
        group.onItemChange = { announced.append($0) }
        group.playbackChanged()
        #expect(coordinator.calls == ["transition episode-2"])
        #expect(coordinator.proposals == [GroupTiming.Proposal(position: 12, rate: 1)])
        #expect(announced == ["episode-2"])
    }

    @Test func aTitleTheGroupMadeThisLoadTakesTheGroupsTiming() {
        let playback = FakePlayback(item: "episode-2")
        playback.status = .paused
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "episode-1"
        let group = makeGroup(playback, coordinator)
        group.heldItemId = "episode-2"
        var announced: [String] = []
        group.onItemChange = { announced.append($0) }
        group.playbackChanged()
        #expect(coordinator.calls == ["transition episode-2"])
        #expect(coordinator.proposals == [nil])
        #expect(announced.isEmpty)
        #expect(group.heldItemId == nil)
    }

    @Test func rebufferingHoldsTheGroupUntilItCanPlay() {
        let playback = FakePlayback(item: "movie")
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let group = makeGroup(playback, coordinator)
        playback.status = .buffering
        group.playbackChanged()
        // A reload for a lower quality goes through loading, under the same suspension.
        playback.status = .loading
        group.playbackChanged()
        #expect(coordinator.calls == ["suspend"])
        playback.status = .paused
        group.playbackChanged()
        #expect(coordinator.suspensions.map(\.ended) == [true])
        // Ending the suspension brings back the group's timing; nothing more is asked.
        #expect(coordinator.calls == ["suspend"])
    }

    @Test func theGroupsOwnSeekDoesntHoldItBack() async {
        let playback = FakePlayback(item: "movie")
        playback.statusAfterSeek = .buffering
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let group = makeGroup(playback, coordinator)
        playback.onSeek = { group.playbackChanged() }
        await group.handle(.seek(itemId: "movie", itemTime: 300, buffers: false, due: nil))
        playback.status = .playing
        group.playbackChanged()
        #expect(coordinator.calls.isEmpty)
        #expect(playback.applied == ["seek 300.0"])
    }

    @Test func playsWhenAndWhereTheGroupDoes() async {
        let playback = FakePlayback(item: "movie")
        playback.status = .paused
        playback.groupPosition = 10
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let clock = FakeClock()
        let group = makeGroup(playback, coordinator, clock: clock)
        await group.handle(.play(itemId: "movie", itemTime: 30, hostTime: 996, rate: 1))
        #expect(playback.applied == ["seek \(34 + GroupTiming.lead)", "rate 1.0"])
        #expect(clock.now == 1000 + GroupTiming.lead)
        #expect(group.groupRate == 1)
    }

    @Test func pausesWithTheGroup() async {
        let playback = FakePlayback(item: "movie")
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let group = makeGroup(playback, coordinator)
        await group.handle(.pause(itemId: "movie"))
        #expect(playback.applied == ["rate 0.0"])
        #expect(playback.status == .paused)
        #expect(group.groupRate == 0)
    }

    @Test func aCommandForAnotherItemIsObsolete() async {
        let playback = FakePlayback(item: "movie")
        let coordinator = FakeCoordinator()
        let group = makeGroup(playback, coordinator)
        await group.handle(.pause(itemId: "previous-episode"))
        #expect(playback.applied.isEmpty)
    }

    @Test func aCommandMissedWhileLoadingIsMadeUpForOnceLoaded() async {
        let playback = FakePlayback(item: "movie")
        playback.status = .loading
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let group = makeGroup(playback, coordinator)
        await group.handle(.pause(itemId: "movie"))
        #expect(playback.applied.isEmpty)
        playback.status = .paused
        group.playbackChanged()
        #expect(coordinator.calls.last == "reapply")
        // Once.
        group.playbackChanged()
        #expect(coordinator.calls.filter { $0 == "reapply" }.count == 1)
    }

    @Test func aBufferingSeekWaitsUntilThePlaybackIsReady() async {
        let playback = FakePlayback(item: "movie")
        playback.statusAfterSeek = .buffering
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let clock = FakeClock()
        let group = makeGroup(playback, coordinator, clock: clock)
        await group.handle(.seek(itemId: "movie", itemTime: 60, buffers: true, due: 1002))
        // Never ready: it gives up at the due time.
        #expect(clock.now >= 1002)
        #expect(clock.now < 1002.2)
    }

    @Test func tellsTheGroupWhenItsTitleDidntPlay() {
        let playback = FakePlayback(item: "episode-2")
        playback.status = .failed("The server didn't answer.")
        let coordinator = FakeCoordinator()
        let group = makeGroup(playback, coordinator)
        group.heldItemId = "episode-2"
        var failures: [String] = []
        group.onFailure = { failures.append($0) }
        group.playbackChanged()
        #expect(failures == ["The server didn't answer."])
    }

    @Test func lettingGoEndsTheHold() {
        let playback = FakePlayback(item: "movie")
        let coordinator = FakeCoordinator()
        coordinator.currentItemIdentifier = "movie"
        let group = makeGroup(playback, coordinator)
        playback.status = .buffering
        group.playbackChanged()
        group.detach()
        #expect(coordinator.suspensions.map(\.ended) == [true])
        #expect(!group.share(.rate(0)))
    }
}

struct WatchTogetherTests {
    private let activity = WatchTogether(serverId: "server-1", serverName: "Home", itemId: "movie", title: "Big Buck Bunny (2008)", subtitle: nil)

    private func account(serverId: String, name: String? = "Home", url: String = "http://home.local:8096") -> AccountStore.Account {
        AccountStore.Account(serverURL: URL(string: url)!, serverId: serverId, serverName: name, userId: "user", userName: "together")
    }

    @Test func letsInAnyoneOnTheSameServerAtAnyAddress() {
        #expect(activity.access(for: account(serverId: "server-1", url: "https://home.example.com")) == .allowed)
        #expect(activity.refusal(.allowed) == nil)
    }

    @Test func saysWhySomeoneElseCantJoin() {
        #expect(activity.access(for: nil) == .notSignedIn)
        #expect(activity.access(for: account(serverId: "server-2", name: "Friends")) == .otherServer("Friends"))
        #expect(activity.refusal(.notSignedIn) == "Big Buck Bunny (2008) is playing from Home. Sign in to Home in vinnyfin to watch together.")
        #expect(activity.refusal(.otherServer("Friends"))?.contains("signed in to Friends") == true)
    }

    @Test func tellsTheGroupWhoCantWatchAndWhy() throws {
        #expect(CantWatch(.allowed) == nil)
        let message = try #require(CantWatch(WatchTogether.Access.otherServer("Friends")))
        let decoded = try JSONDecoder().decode(CantWatch.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
        #expect(decoded.describe(serverName: "Home") == "Someone is signed in to a different server than Home.")
        #expect(CantWatch(.failed("No connection")).describe(serverName: "Home") == "It didn't play for someone: No connection")
    }

    @Test func describesItselfToFaceTime() {
        let metadata = activity.metadata
        #expect(metadata.type == .watchTogether)
        #expect(metadata.title == "Big Buck Bunny (2008)")
        #expect(metadata.supportsContinuationOnTV)
    }
}
