import Foundation
import Testing
@testable import vinnyfin
#if !os(tvOS)
import SwiftUI
#endif

/// iCloud's key-value store as a dictionary, recording what's written to it.
private final class MemoryCloud: CloudKeyValues {
    var values: [String: Any] = [:]
    private(set) var writes: [String] = []

    func object(forKey key: String) -> Any? { values[key] }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
        writes.append(key)
    }

    func removeObject(forKey key: String) {
        values[key] = nil
        writes.append(key)
    }

    var dictionaryRepresentation: [String: Any] { values }
}

private enum Continuity {
    static let home = ServerSignIn(serverId: "home", serverName: "Home", address: URL(string: "http://nas.local:8096")!,
                                   userId: "u1", userName: "Alex")
    static let homeAccount = AccountStore.Account(serverURL: URL(string: "http://nas.local:8096")!, serverId: "home",
                                                  serverName: "Home", userId: "u1", userName: "Alex")

    static func defaults() -> UserDefaults {
        let name = "continuity-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

struct HandoffTests {
    @Test func carriesAPlaybackAndItsPositionToTheOtherDevice() throws {
        let handoff = Handoff(link: AppLink(.play, Samples.episode, position: 1234.7), signIn: Continuity.home)
        let activity = NSUserActivity(activityType: Handoff.activityType)
        handoff.describe(activity)

        #expect(activity.title == "Pilot: Part 1/2")
        #expect(activity.isEligibleForHandoff)
        #expect(activity.requiredUserInfoKeys == Set(handoff.userInfo.keys))
        let received = try #require(Handoff(activity))
        #expect(received == handoff)
        #expect(received.link.action == .play)
        #expect(received.link.position == 1234)
        #expect(received.signIn.address.absoluteString == "http://nas.local:8096")
    }

    @Test func carriesATitlesPage() throws {
        let handoff = Handoff(link: AppLink(.open, Samples.movie), signIn: Continuity.home)
        let received = try #require(Handoff(userInfo: handoff.userInfo))
        #expect(received.link == AppLink(.open, Samples.movie))
        #expect(received.link.position == nil)
    }

    @Test func turnsDownAnotherAppsActivityAndAnIncompleteOne() {
        let other = NSUserActivity(activityType: "com.example.reading")
        other.userInfo = Handoff(link: AppLink(.open, Samples.movie), signIn: Continuity.home).userInfo
        #expect(Handoff(other) == nil)

        let complete = Handoff(link: AppLink(.open, Samples.movie), signIn: Continuity.home).userInfo
        for key in ["link", "serverId", "serverAddress", "userId", "userName"] {
            var missing = complete
            missing[key] = nil
            #expect(Handoff(userInfo: missing) == nil, "without \(key)")
        }
        var notALink = complete
        notALink["link"] = "https://example.com"
        #expect(Handoff(userInfo: notALink) == nil)
        // The server's name is only for saying where the title is from.
        var unnamed = complete
        unnamed["serverName"] = nil
        #expect(Handoff(userInfo: unnamed)?.signIn.serverTitle == "nas.local")
    }

    @Test func pointsABrowserAtJellyfinsPageForTheTitle() {
        var signIn = Continuity.home
        #expect(Handoff(link: AppLink(.open, Samples.movie), signIn: signIn).webpageURL?.absoluteString
            == "http://nas.local:8096/web/#/details?id=m1&serverId=home")
        signIn.address = URL(string: "https://example.com/jellyfin")!
        #expect(Handoff(link: AppLink(.play, Samples.movie), signIn: signIn).webpageURL?.absoluteString
            == "https://example.com/jellyfin/web/#/details?id=m1&serverId=home")
    }

    @Test func saysHowThisDevicesSignInDiffers() {
        let handoff = Handoff(link: AppLink(.play, Samples.movie, position: 60), signIn: Continuity.home)
        #expect(handoff.mismatch(with: Continuity.homeAccount) == nil)
        #expect(handoff.mismatch(with: nil) == .notSignedIn)

        var otherUser = Continuity.homeAccount
        otherUser.userId = "u2"
        otherUser.userName = "Sam"
        #expect(handoff.mismatch(with: otherUser) == .otherUser(otherUser))

        var otherServer = Continuity.homeAccount
        otherServer.serverId = "work"
        otherServer.serverName = "Work"
        #expect(handoff.mismatch(with: otherServer) == .otherServer(otherServer))

        #expect(handoff.explanation(for: .notSignedIn, on: "iPad")
            == "“Big Test Movie” is from Home, signed in as Alex. This iPad isn't signed in.")
        #expect(handoff.explanation(for: .otherServer(otherServer), on: "Mac")
            == "“Big Test Movie” is from Home, signed in as Alex. This Mac is signed in to Work as Alex, and switching signs it out there.")
        #expect(handoff.explanation(for: .otherUser(otherUser), on: "iPhone")
            == "“Big Test Movie” is from Home, signed in as Alex. This iPhone is signed in to it as Sam, and switching signs Sam out.")
        #expect(handoff.signInTitle(for: .notSignedIn) == "Sign In to Home")
        #expect(handoff.signInTitle(for: .otherServer(otherServer)) == "Switch to Home")
        #expect(handoff.signInTitle(for: .otherUser(otherUser)) == "Switch to Alex")
    }

    @Test func linksCarryThePositionInWholeSeconds() throws {
        let link = AppLink(.play, Samples.movie, position: 3599.9)
        #expect(link.url.absoluteString == "vinnyfin://play/m1?type=Movie&name=Big%20Test%20Movie&position=3599")
        #expect(AppLink(link.url) == link)
        // A position that isn't a time into the title is left out.
        let odd = try #require(AppLink(URL(string: "vinnyfin://play/m1?type=Movie&name=x&position=-5")!))
        #expect(odd.position == nil)
        #expect(AppLink(URL(string: "vinnyfin://play/m1?type=Movie&name=x&position=soon")!)?.position == nil)
        #expect(AppLink(.play, Samples.movie, position: .infinity).position == nil)
    }

    @Test func resumesWhereTheOtherDeviceWasOrLaterOnTheServer() {
        let handedOff = PlaybackRequest.item(Samples.movie, continuingFrom: 600)
        #expect(handedOff.start(resuming: nil) == 600)
        #expect(handedOff.start(resuming: 300) == 600)
        #expect(handedOff.start(resuming: 900) == 900)
        let plain = PlaybackRequest.item(Samples.movie)
        #expect(plain.start(resuming: 300) == 300)
        #expect(plain.start(resuming: nil) == nil)
    }
}

struct SettingsSyncTests {
    @Test func settingsThatSuitOneDeviceStayOnIt() {
        for key in ["settings.streamingQuality", "settings.downloadQuality", "settings.smartDownloadCount", "settings.matchContent"] {
            #expect(!AppSettings.syncs(key), "\(key)")
        }
        for key in ["settings.appearance", "settings.allowTranscoding", "settings.adaptiveQuality", "settings.deleteWatchedEpisodes",
                    "settings.autoplayNextEpisode", "settings.showSkipIntro", "settings.audioLanguage", "settings.subtitleLanguage",
                    "settings.subtitleMode", "settings.subtitleScale"] {
            #expect(AppSettings.syncs(key), "\(key)")
        }
    }

    @Test func aNewSettingFollowsThePersonUnlessMarkedDeviceOnly() {
        #expect(AppSettings.syncs("settings.somethingAddedLater"))
        // Keys that aren't settings never go to iCloud this way.
        #expect(!AppSettings.syncs("deviceId"))
        #expect(!AppSettings.syncs("server.home"))
    }

    @Test func iCloudWinsForWhatItHasAndGetsWhatItLacks() {
        let merge = SettingsMerge(
            local: ["settings.appearance": "dark", "settings.audioLanguage": "eng", "settings.subtitleScale": 1.25,
                    "settings.streamingQuality": "fullHD", "deviceId": "abc"],
            cloud: ["settings.appearance": "light", "settings.subtitleScale": 1.25, "settings.autoplayNextEpisode": false,
                    "settings.matchContent": false],
            syncs: AppSettings.syncs
        )
        #expect(NSDictionary(dictionary: merge.adopted).isEqual(to: ["settings.appearance": "light", "settings.autoplayNextEpisode": false]))
        #expect(NSDictionary(dictionary: merge.uploaded).isEqual(to: ["settings.audioLanguage": "eng"]))
    }

    @Test func aChoiceGoesToICloudUnlessItStaysOnTheDevice() {
        let cloud = MemoryCloud()
        let settings = AppSettings(defaults: Continuity.defaults(), cloud: cloud)
        settings.appearance = .dark
        settings.subtitleMode = .always
        settings.streamingQuality = .fullHD
        settings.smartDownloadCount = 3
        #expect(cloud.writes == ["settings.appearance", "settings.subtitleMode"])
        #expect(cloud.values["settings.appearance"] as? String == "dark")
    }

    @Test func anotherDevicesChoiceAppliesAtOnceWithoutGoingBack() {
        let cloud = MemoryCloud()
        let defaults = Continuity.defaults()
        let settings = AppSettings(defaults: defaults, cloud: cloud)
        cloud.values = ["settings.appearance": "dark", "settings.autoplayNextEpisode": false, "settings.streamingQuality": "fullHD"]
        settings.cloudChanged(["settings.appearance", "settings.autoplayNextEpisode", "settings.streamingQuality"])
        #expect(settings.appearance == .dark)
        #expect(!settings.autoplayNextEpisode)
        // The streaming quality is this device's own.
        #expect(settings.streamingQuality == .original)
        #expect(cloud.writes.isEmpty)
        // And it's kept here for the next launch.
        #expect(AppSettings(defaults: defaults).appearance == .dark)
    }

    @Test func aWholeStoreFromICloudReconcilesWithWhatsHere() {
        let cloud = MemoryCloud()
        let defaults = Continuity.defaults()
        let settings = AppSettings(defaults: defaults, cloud: cloud)
        settings.subtitleLanguage = "ger"
        settings.matchContent = false
        // A first download from iCloud, or another Apple Account, replaces its keys.
        cloud.values = ["settings.subtitleScale": 1.5]
        settings.reconcileWithCloud()
        #expect(settings.subtitleScale == 1.5)
        #expect(cloud.values["settings.subtitleLanguage"] as? String == "ger")
        #expect(cloud.values["settings.matchContent"] == nil)
    }

    @Test func readsWhatICloudSaysChanged() {
        #expect(CloudChange(userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange,
                                       NSUbiquitousKeyValueStoreChangedKeysKey: ["settings.appearance"]]) == .changed(["settings.appearance"]))
        #expect(CloudChange(userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreInitialSyncChange]) == .replaced)
        #expect(CloudChange(userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreAccountChange]) == .replaced)
        #expect(CloudChange(userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreQuotaViolationChange]) == .full)
        #expect(CloudChange(userInfo: nil) == nil)
    }
}

struct KnownServerTests {
    private func store(_ cloud: MemoryCloud) -> KnownServers {
        KnownServers(accounts: AccountStore(defaults: Continuity.defaults()), cloud: cloud)
    }

    @Test func remembersEachPersonOnAServerUnderTheServersKey() throws {
        let cloud = MemoryCloud()
        let servers = store(cloud)
        servers.remember(Continuity.homeAccount)
        var sam = Continuity.homeAccount
        sam.userId = "u2"
        sam.userName = "Sam"
        servers.remember(sam)

        #expect(servers.signIns.map(\.userName) == ["Alex", "Sam"])
        #expect(Array(cloud.values.keys) == ["server.home"])
        let saved = try #require(cloud.values["server.home"] as? Data)
        let text = try #require(String(data: saved, encoding: .utf8))
        #expect(!text.localizedCaseInsensitiveContains("token"))
        #expect(!text.localizedCaseInsensitiveContains("password"))
    }

    @Test func aServerThatMovedMovesForEveryoneOnIt() {
        let sam = ServerSignIn(serverId: "home", serverName: "Home", address: URL(string: "http://nas.local:8096")!,
                               userId: "u2", userName: "Sam")
        var moved = Continuity.home
        moved.address = URL(string: "https://jf.example.com")!
        moved.serverName = "Family"
        let server = KnownServers.remembering(moved, on: [Continuity.home, sam])
        #expect(server.count == 2)
        #expect(server.allSatisfy { $0.address == moved.address && $0.serverName == "Family" })
    }

    @Test func rememberingTheSameSignInAgainWritesNothing() {
        let cloud = MemoryCloud()
        let servers = store(cloud)
        servers.remember(Continuity.homeAccount)
        servers.remember(Continuity.homeAccount)
        #expect(cloud.writes == ["server.home"])
    }

    @Test func forgettingTheLastPersonForgetsTheServer() {
        let cloud = MemoryCloud()
        let servers = store(cloud)
        servers.remember(Continuity.homeAccount)
        servers.forget(Continuity.home)
        #expect(servers.signIns.isEmpty)
        #expect(cloud.values.isEmpty)
    }

    @Test func readsWhatOtherDevicesSavedAndSaysWhatItCant() throws {
        let cloud = MemoryCloud()
        cloud.values = [
            "server.home": try JSONEncoder().encode([Continuity.home]),
            "server.garbled": Data("not json".utf8),
            "settings.appearance": "dark",
        ]
        let servers = store(cloud)
        #expect(servers.signIns == [Continuity.home])
        #expect(servers.problem?.contains("garbled") == true)
    }

    @Test func fillsInTheFormFromASavedAddress() throws {
        #expect(ServerAddress(savedURL: URL(string: "http://nas.local")!) == ServerAddress(scheme: .http, host: "nas.local", port: "80"))
        #expect(ServerAddress(savedURL: URL(string: "https://jf.example.com/jellyfin")!)
            == ServerAddress(scheme: .https, host: "jf.example.com", port: "", path: "/jellyfin"))
        #expect(try ServerAddress(savedURL: URL(string: "http://10.0.0.5:8096")!)?.url.get() == URL(string: "http://10.0.0.5:8096")!)
    }

    @Test func knowsWhoIsSignedInWhere() {
        #expect(Continuity.home.isSignedIn(as: Continuity.homeAccount))
        #expect(!Continuity.home.isSignedIn(as: nil))
        var other = Continuity.homeAccount
        other.userId = "u2"
        #expect(!Continuity.home.isSignedIn(as: other))
    }
}

#if !os(tvOS)
struct KeyboardCommandTests {
    @Test func thePlayerTakesKeysWithoutModifiers() {
        #expect(PlayerCommand.playPause.shortcut == KeyboardShortcut(.space, modifiers: []))
        #expect(PlayerCommand.skipBack.shortcut == KeyboardShortcut(.leftArrow, modifiers: []))
        #expect(PlayerCommand.skipForward.shortcut == KeyboardShortcut(.rightArrow, modifiers: []))
        #expect(PlayerCommand.fullScreen.shortcut == KeyboardShortcut("f", modifiers: []))
        #expect(PlayerCommand.close.shortcut == KeyboardShortcut(.escape, modifiers: []))
        #expect(PlayerCommand.allCases.allSatisfy { $0.shortcut.modifiers.isEmpty })
    }

    @Test func thePlayerFindsTheCommandForAKey() {
        #expect(PlayerCommand.pressed(.space, modifiers: []) == .playPause)
        #expect(PlayerCommand.pressed(.leftArrow, modifiers: []) == .skipBack)
        #expect(PlayerCommand.pressed("n", modifiers: []) == .nextEpisode)
        #expect(PlayerCommand.pressed(.escape, modifiers: []) == .close)
        // ⌘F is the Go menu's Search, not full screen.
        #expect(PlayerCommand.pressed("f", modifiers: .command) == nil)
        #expect(PlayerCommand.keys.count == PlayerCommand.allCases.count)
    }

    @Test func theTabsTakeCommandAndTheirPlace() {
        #expect(TabCommand.allCases.map(\.destination) == [.home, .movies, .shows, .downloads, .search])
        #expect(TabCommand.allCases.map(\.shortcut.key.character) == ["1", "2", "3", "4", "f"])
        #expect(TabCommand.allCases.allSatisfy { $0.shortcut.modifiers == .command })
    }

    @Test func noTwoCommandsShareAKey() {
        let shortcuts = PlayerCommand.allCases.map(\.shortcut) + TabCommand.allCases.map(\.shortcut)
        #expect(Set(shortcuts.map { "\($0.key.character)-\($0.modifiers.rawValue)" }).count == shortcuts.count)
    }
}
#endif
