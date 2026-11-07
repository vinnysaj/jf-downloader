#if os(iOS) || os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import Security
import Testing
import UniformTypeIdentifiers
@testable import vinnyfin
import WidgetKit

struct UpNextWidgetTests {
    private static let episodePartway = Samples.item("""
    {"Id":"e7","Name":"The Long Night","Type":"Episode","SeriesName":"Port Ellery","SeriesId":"s1",
     "ParentIndexNumber":2,"IndexNumber":3,"RunTimeTicks":30000000000,
     "UserData":{"PlaybackPositionTicks":12000000000,"PlayedPercentage":40,"Played":false}}
    """)
    private static let moviePartway = Samples.item("""
    {"Id":"m2","Name":"Copperline","Type":"Movie","ProductionYear":2019,"RunTimeTicks":54000000000,
     "UserData":{"PlaybackPositionTicks":18000000000,"Played":false}}
    """)
    private static let nextEpisode = Samples.item("""
    {"Id":"e8","Name":"Morning","Type":"Episode","SeriesName":"Port Ellery","ParentIndexNumber":2,"IndexNumber":4}
    """)

    @Test func aTileSaysWhatHomesLandscapeCardSays() {
        let tiles = UpNextWidgets.tiles(from: [Self.episodePartway, Self.moviePartway, Self.nextEpisode], limit: 8)
        #expect(tiles.map(\.title) == ["Port Ellery", "Copperline", "Port Ellery"])
        #expect(tiles[0].detail == "S02E03 · The Long Night")
        #expect(tiles[1].detail == Self.moviePartway.cardDetail)
        #expect(tiles[1].detail.hasSuffix(" left"))
        #expect(tiles[2].detail == "S02E04 · Morning")
        #expect(tiles.map(\.progress) == [0.4, 1.0 / 3.0, nil])
        #expect(tiles.allSatisfy { $0.artwork == nil })
    }

    @Test func aTilePlaysItsTitleFromWhereItWasLeft() throws {
        let tile = try #require(UpNextWidgets.tiles(from: [Self.episodePartway], limit: 1).first)
        #expect(tile.playLink == AppLink(.play, Self.episodePartway).url)
        let link = try #require(AppLink(tile.playLink))
        #expect(link.action == .play)
        #expect(link.itemId == "e7")
        #expect(link.type == "Episode")
        // The app plays a link as Resume does: the server's version and position, not the start.
        let request = PlaybackRequest.item(link.item)
        #expect(request.source == .item(id: "e7", mediaSourceId: nil))
        #expect(!request.startFromBeginning)
    }

    @Test func showsOnlyTitlesThatPlayAsManyAsFit() {
        let season = JellyfinItem(id: "season", name: "Season 1", type: "Season")
        let tiles = UpNextWidgets.tiles(from: [season, Self.episodePartway, Self.moviePartway, Self.nextEpisode], limit: 2)
        #expect(tiles.map(\.itemId) == ["e7", "m2"])
    }

    @Test func tellsASignInTheServerTurnedAwayFromAServerOutOfReach() {
        #expect(UpNextWidgets.content(for: JellyfinError.http(status: 401, body: ""), server: "Den")
            == .sessionEnded(server: "Den"))
        let offline = URLError(.cannotConnectToHost)
        #expect(UpNextWidgets.content(for: offline, server: "Den")
            == .unreachable(server: "Den", reason: offline.localizedDescription))
        let failing = JellyfinError.http(status: 500, body: "")
        #expect(UpNextWidgets.content(for: failing, server: "Den")
            == .unreachable(server: "Den", reason: failing.localizedDescription))
    }

    @Test func asksAgainSoonerAfterAFailureAndNotAtAllUntilSignedIn() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(UpNextWidgets.refreshDate(for: .tiles([]), now: now) == now.addingTimeInterval(30 * 60))
        #expect(UpNextWidgets.refreshDate(for: .unreachable(server: "Den", reason: "x"), now: now) == now.addingTimeInterval(15 * 60))
        #expect(UpNextWidgets.refreshDate(for: .signInProblem("x"), now: now) == now.addingTimeInterval(15 * 60))
        #expect(UpNextWidgets.refreshDate(for: .signedOut, now: now) == nil)
        #expect(UpNextWidgets.refreshDate(for: .sessionEnded(server: "Den"), now: now) == nil)
    }

    @Test func laysOutAsManyTitlesAsEachSizeHolds() {
        let shapes = [WidgetFamily.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge].map(UpNextWidgets.Layout.init)
        #expect(shapes.map(\.count) == [1, 2, 4, 8])
        #expect(shapes.map(\.columns) == [1, 2, 2, 4])
        #expect(shapes.allSatisfy { $0.showsPictures })
        #if os(iOS)
        for family in [WidgetFamily.accessoryCircular, .accessoryRectangular, .accessoryInline] {
            let layout = UpNextWidgets.Layout(family)
            #expect(layout.count == 1)
            #expect(layout.pictureWidth(inWidgetWidth: 172, scale: 3) == nil)
        }
        #endif
    }

    @Test func asksForPicturesAtTheWidthDrawn() {
        // An iPhone's small and medium widgets, 170 and 364 points wide, on a 3x screen.
        #expect(UpNextWidgets.Layout(.systemSmall).pictureWidth(inWidgetWidth: 170, scale: 3) == 414)
        #expect(UpNextWidgets.Layout(.systemMedium).pictureWidth(inWidgetWidth: 364, scale: 3) == 480)
        #expect(UpNextWidgets.Layout(.systemLarge).pictureWidth(inWidgetWidth: 364, scale: 3) == 480)
        // An iPad's extra large widget, four across, on a 2x screen.
        #expect(UpNextWidgets.Layout(.systemExtraLarge).pictureWidth(inWidgetWidth: 715, scale: 2) == 324)
    }

    @Test func keepsPicturesWithinTheEntrysBudget() {
        let tiles = UpNextWidgets.tiles(from: [Self.episodePartway, Self.moviePartway, Self.nextEpisode], limit: 3)
        let pictures = ["e7": Data(count: 150), "m2": Data(count: 300), "e8": Data(count: 50)]
        let shown = UpNextWidgets.withArtwork(tiles, pictures: pictures, budget: 400)
        #expect(shown.map { $0.artwork?.count } == [150, nil, 50])
        #expect(UpNextWidgets.withArtwork(tiles, pictures: [:]).allSatisfy { $0.artwork == nil })
    }

    @Test func scalesAPictureDownToASmallJPEG() throws {
        let picture = try Self.png(width: 1600, height: 900)
        let source = try #require(CGImageSourceCreateWithData(picture as CFData, nil))
        let jpeg = try #require(WidgetArtwork.jpeg(from: source, maxPixelSize: 480, quality: UpNextWidgets.artworkQuality))
        let scaled = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(scaled) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(scaled, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 480)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 270)
        #expect(jpeg.count < 40_000)
    }

    @Test func turnsAwayWhatIsntAPicture() throws {
        let source = try #require(CGImageSourceCreateWithData(Data("not a picture".utf8) as CFData, nil))
        #expect(WidgetArtwork.jpeg(from: source, maxPixelSize: 480, quality: 0.75) == nil)
    }

    /// A picture with something in it, as a server would send.
    private static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for band in 0..<8 {
            context.setFillColor(red: Double(band) / 8, green: Double(7 - band) / 8, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: band * width / 8, y: 0, width: width / 8, height: height))
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// The Keychain's two places for a token, in the real Keychain of the signed app the tests run in.
struct KeychainPlacesTests {
    /// The app's own place is apart from the app group's: launching moves a token from the first
    /// to the second and then deletes the first, which would otherwise take the moved token with it.
    @Test func theAppGroupsTokenIsntTheAppsOwn() throws {
        let server = "KeychainPlacesTests-\(UUID().uuidString)"
        try Keychain.setToken("shared", for: server)
        defer { try? Keychain.deleteToken(for: server) }
        #expect(try Keychain.appToken(for: server) == nil)
        try Keychain.deleteAppToken(for: server)
        #expect(try Keychain.token(for: server) == "shared")
    }
}

/// Moving a sign-in kept where only the app read it to the app group, where the widgets read it.
/// Each test has its own pair of defaults suites, removed after it.
final class SignInMoveTests {
    private let suiteName = "SignInMoveTests-\(UUID().uuidString)"
    private let account = AccountStore.Account(serverURL: URL(string: "http://den.local:8096")!, serverId: "server-1",
                                               serverName: "Den", userId: "u", userName: "alex")

    deinit {
        for suffix in ["-app", "-shared"] {
            UserDefaults(suiteName: suiteName + suffix)?.removePersistentDomain(forName: suiteName + suffix)
        }
    }

    private func suites() throws -> (app: UserDefaults, shared: UserDefaults) {
        (try #require(UserDefaults(suiteName: suiteName + "-app")), try #require(UserDefaults(suiteName: suiteName + "-shared")))
    }

    /// The token moves before the defaults, which move only once it has.
    @Test func movesTheTokenOfTheAppsSignInThenTheDefaults() throws {
        let (app, shared) = try suites()
        app.set(try JSONEncoder().encode(account), forKey: "account")
        app.set("device-1", forKey: "deviceId")
        var moved: [String] = []
        try AccountStore.moveSignIn(from: app, to: shared, isInAppGroup: true) { serverId in
            #expect(shared.object(forKey: "account") == nil)
            moved.append(serverId)
        }
        #expect(moved == ["server-1"])
        #expect(shared.data(forKey: "account") != nil)
        #expect(shared.string(forKey: "deviceId") == "device-1")
        #expect(app.object(forKey: "account") == nil)
    }

    /// A build the group isn't granted to would write the group's defaults to a file of its own,
    /// which a build that has the group never reads.
    @Test func movesNothingWithoutTheAppGroup() throws {
        let (app, shared) = try suites()
        app.set(try JSONEncoder().encode(account), forKey: "account")
        #expect(throws: SignInMoveError.notInAppGroup) {
            try AccountStore.moveSignIn(from: app, to: shared, isInAppGroup: false) { _ in Issue.record("The token moved") }
        }
        #expect(app.data(forKey: "account") != nil)
        #expect(shared.object(forKey: "account") == nil)
    }

    @Test func leavesTheDefaultsWhereTheyAreWhenTheTokenCantMove() throws {
        let (app, shared) = try suites()
        app.set(try JSONEncoder().encode(account), forKey: "account")
        app.set("device-1", forKey: "deviceId")
        #expect(throws: KeychainError.self) {
            try AccountStore.moveSignIn(from: app, to: shared, isInAppGroup: true) { _ in
                throw KeychainError(message: "Couldn't save the sign-in to the Keychain", status: errSecMissingEntitlement)
            }
        }
        #expect(app.data(forKey: "account") != nil)
        #expect(app.string(forKey: "deviceId") == "device-1")
        #expect(shared.object(forKey: "account") == nil)
    }

    /// The defaults moved on an earlier launch; the token goes now, by the group's sign-in.
    @Test func movesTheTokenOfASignInAlreadyInTheGroup() throws {
        let (app, shared) = try suites()
        shared.set(try JSONEncoder().encode(account), forKey: "account")
        var moved: [String] = []
        try AccountStore.moveSignIn(from: app, to: shared, isInAppGroup: true) { moved.append($0) }
        #expect(moved == ["server-1"])
    }

    @Test func movesTheSignInsDefaultsAndNothingElse() throws {
        let (app, shared) = try suites()
        app.set(Data("account".utf8), forKey: "account")
        app.set("device-1", forKey: "deviceId")
        app.set(URL(string: "http://den.local:8096")!, forKey: "lastServer")
        app.set("alex", forKey: "lastUserName")
        app.set(true, forKey: "autoplayNextEpisode")
        AccountStore.moveDefaults(from: app, to: shared)
        #expect(shared.data(forKey: "account") == Data("account".utf8))
        #expect(shared.string(forKey: "deviceId") == "device-1")
        #expect(shared.url(forKey: "lastServer") == URL(string: "http://den.local:8096"))
        #expect(shared.string(forKey: "lastUserName") == "alex")
        #expect(shared.object(forKey: "autoplayNextEpisode") == nil)
        for key in AccountStore.sharedKeys {
            #expect(app.object(forKey: key) == nil, "\(key)")
        }
        #expect(app.bool(forKey: "autoplayNextEpisode"))
    }

    @Test func aSecondMoveLeavesTheGroupAsItIs() throws {
        let (app, shared) = try suites()
        app.set("device-1", forKey: "deviceId")
        AccountStore.moveDefaults(from: app, to: shared)
        shared.set("alex", forKey: "lastUserName")
        AccountStore.moveDefaults(from: app, to: shared)
        #expect(shared.string(forKey: "deviceId") == "device-1")
        #expect(shared.string(forKey: "lastUserName") == "alex")
    }

    @Test func whatTheAppSavedSinceReplacesTheGroups() throws {
        let (app, shared) = try suites()
        shared.set("old-user", forKey: "lastUserName")
        app.set("new-user", forKey: "lastUserName")
        AccountStore.moveDefaults(from: app, to: shared)
        #expect(shared.string(forKey: "lastUserName") == "new-user")
    }

    /// The Keychain's two places, in memory, with the calls made to them.
    private final class Places {
        var original: String?
        var shared: String?
        var writeFails = false
        /// What reading the shared place returns after a write, when it differs from what was written.
        var readsBack: String??
        var calls: [String] = []

        func move() throws {
            try AccountStore.moveToken(
                read: { calls.append("read"); return original },
                readShared: { calls.append("readShared"); return shared },
                writeShared: { token in
                    calls.append("write")
                    if writeFails { throw KeychainError(message: "Couldn't save the sign-in to the Keychain", status: errSecMissingEntitlement) }
                    shared = readsBack ?? token
                },
                deleteOriginal: { calls.append("delete"); original = nil }
            )
        }
    }

    @Test func copiesTheTokenReadsItBackThenDeletesTheOriginal() throws {
        let places = Places()
        places.original = "token"
        try places.move()
        #expect(places.shared == "token")
        #expect(places.original == nil)
        #expect(places.calls == ["read", "readShared", "write", "readShared", "delete"])
    }

    @Test func keepsTheOriginalWhenTheCopyFails() {
        let places = Places()
        places.original = "token"
        places.writeFails = true
        #expect(throws: KeychainError.self) { try places.move() }
        #expect(places.original == "token")
        #expect(!places.calls.contains("delete"))
    }

    @Test func keepsTheOriginalWhenTheCopyReadsBackDifferently() {
        let places = Places()
        places.original = "token"
        places.readsBack = .some(nil)
        #expect(throws: SignInMoveError.copyDiffers) { try places.move() }
        #expect(places.original == "token")
        #expect(!places.calls.contains("delete"))
    }

    @Test func onlyDeletesTheOriginalWhenTheGroupHasItAlready() throws {
        let places = Places()
        places.original = "token"
        places.shared = "token"
        try places.move()
        #expect(places.calls == ["read", "readShared", "delete"])
        #expect(places.original == nil)
    }

    @Test func replacesAnOlderTokenInTheGroup() throws {
        let places = Places()
        places.original = "new"
        places.shared = "old"
        try places.move()
        #expect(places.shared == "new")
        #expect(places.original == nil)
    }

    @Test func doesNothingOnceEverythingHasMoved() throws {
        let places = Places()
        places.shared = "token"
        try places.move()
        #expect(places.calls == ["read"])
        #expect(places.shared == "token")
    }

    @MainActor
    @Test func aSavedSignInWithoutItsTokenSaysSoInsteadOfSigningIn() throws {
        let (_, shared) = try suites()
        let account = AccountStore.Account(serverURL: URL(string: "http://den.local:8096")!, serverId: "server-\(UUID().uuidString)",
                                           serverName: "Den", userId: "u", userName: "alex")
        shared.set(try JSONEncoder().encode(account), forKey: "account")
        let accounts = AccountStore(defaults: shared)
        #expect(accounts.session == nil)
        #expect(accounts.savedSignInProblem != nil)
    }
}
#endif
