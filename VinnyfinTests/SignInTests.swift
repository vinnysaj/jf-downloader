import Foundation
import Testing
@testable import vinnyfin

private enum SignIn {
    static let home = ServerSignIn(serverId: "home", serverName: "Home", address: URL(string: "http://nas.local:8096")!,
                                   userId: "u1", userName: "Alex")
    static let homeAddress = ServerAddress(scheme: .http, host: "nas.local", port: "8096")

    /// The server that answered at `url`.
    static func server(_ url: String, named name: String? = "Home") -> AccountStore.Server {
        AccountStore.Server(url: URL(string: url)!, info: PublicSystemInfo(serverName: name, version: "10.11.0", id: "home"))
    }

    /// The flow on the account step with `home` picked and its user filled in.
    static func pickedHome() -> SignInFlow {
        var flow = SignInFlow()
        _ = flow.start(offer: home, lastServerURL: nil, lastUserName: nil)
        return flow
    }

    /// The attempt a step's button starts.
    static func attempt(_ next: SignInFlow.Next) throws -> SignInFlow.Attempt {
        guard case .attempt(let attempt) = next else { throw Unexpected(next: next) }
        return attempt
    }

    struct Unexpected: Error {
        let next: SignInFlow.Next
    }
}

struct DemoAccountTests {
    @Test func signsInToTheDemoServer() throws {
        #expect(try SignInFlow.demoServer.url.get() == URL(string: "https://jftest.vinnysaj.net")!)
        #expect(SignInFlow.demoServer.fallback == nil)
    }

    @Test func knowsTheDemoAccountByItsUsernameInAnyCaseAndItsPasswordExactly() {
        #expect(SignInFlow.isDemoAccount(username: "apple", password: "apple"))
        #expect(SignInFlow.isDemoAccount(username: "  Apple\n", password: "apple"))
        #expect(SignInFlow.isDemoAccount(username: "APPLE", password: "apple"))
        #expect(!SignInFlow.isDemoAccount(username: "apple", password: "Apple"))
        #expect(!SignInFlow.isDemoAccount(username: "apple", password: " apple"))
        #expect(!SignInFlow.isDemoAccount(username: "apple", password: ""))
        #expect(!SignInFlow.isDemoAccount(username: "apples", password: "apple"))
        #expect(!SignInFlow.isDemoAccount(username: "", password: "apple"))
    }

    @Test func theDemoAccountSignsInToTheDemoServerWhateverServerIsPicked() throws {
        var flow = SignIn.pickedHome()
        flow.username = " Apple "
        flow.password = "apple"
        let attempt = try SignIn.attempt(flow.submitAccount())
        #expect(attempt == SignInFlow.Attempt(address: SignInFlow.demoServer, goal: .password(username: "apple", password: "apple"),
                                              isDemo: true))

        var fresh = SignInFlow()
        fresh.username = "apple"
        fresh.password = "apple"
        #expect(try SignIn.attempt(fresh.submitAccount()).isDemo)
        #expect(fresh.step == .account)
    }

    @Test func theDemoAccountsErrorsStayOnTheAccountStep() throws {
        var flow = SignIn.pickedHome()
        flow.username = "apple"
        flow.password = "apple"
        let attempt = try SignIn.attempt(flow.submitAccount())

        #expect(flow.fail(attempt, while: .findingServer, with: URLError(.cannotFindHost)) == nil)
        #expect(flow.step == .account)
        #expect(flow.accountError == URLError(.cannotFindHost).localizedDescription)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)

        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials) == .password)
        #expect(flow.step == .account)
    }

    @Test func theDemoServerAnsweringLeavesThePickedServer() throws {
        var flow = SignIn.pickedHome()
        flow.username = "apple"
        flow.password = "apple"
        let attempt = try SignIn.attempt(flow.submitAccount())
        let demo = SignIn.server("https://jftest.vinnysaj.net", named: "Demo")
        #expect(flow.found(demo, at: SignInFlow.demoServer, for: attempt) == nil)
        #expect(flow.pickedServer?.title == "Home")
    }
}

struct SignInFlowTests {
    @Test func startsFromTheOfferedSignInWithTheCursorInThePassword() {
        var flow = SignInFlow()
        #expect(flow.start(offer: SignIn.home, lastServerURL: URL(string: "http://other.local"), lastUserName: "Sam") == .password)
        #expect(flow.pickedServer == SignInFlow.PickedServer(address: SignIn.homeAddress, url: SignIn.home.address, title: "Home"))
        #expect(flow.username == "Alex")
        #expect(flow.step == .account)
    }

    @Test func startsFromTheLastSignInOnlyOnce() {
        var flow = SignInFlow()
        #expect(flow.start(offer: nil, lastServerURL: URL(string: "http://nas.local:8096"), lastUserName: "Alex") == nil)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
        #expect(flow.pickedServer?.title == "nas.local")
        #expect(flow.username == "Alex")

        flow.username = "Sam"
        _ = flow.start(offer: nil, lastServerURL: URL(string: "http://nas.local:8096"), lastUserName: "Alex")
        #expect(flow.username == "Sam")
    }

    @Test func choosingAServerPicksItAndFillsInTheUser() {
        var flow = SignInFlow()
        flow.password = "typed"
        #expect(flow.choose(SignIn.home) == .password)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
        #expect(flow.username == "Alex")
        #expect(flow.password.isEmpty)
    }

    @Test func theAccountStepSignsInToThePickedServer() throws {
        var flow = SignIn.pickedHome()
        flow.password = "secret"
        #expect(try SignIn.attempt(flow.submitAccount())
            == SignInFlow.Attempt(address: SignIn.homeAddress, goal: .password(username: "Alex", password: "secret")))
    }

    @Test func withoutAServerTheAccountStepAsksForOneCarryingTheAccount() throws {
        var flow = SignInFlow()
        #expect(flow.submitAccount() == .focus(.username))
        #expect(flow.step == .account)

        flow.username = " Alex "
        flow.password = "secret"
        #expect(flow.submitAccount() == .focus(.host))
        #expect(flow.step == .server)
        #expect(!flow.isQuickConnect)

        flow.address.host = "https://jf.example.com/jellyfin"
        let attempt = try SignIn.attempt(flow.connect())
        #expect(attempt.goal == .password(username: "Alex", password: "secret"))
        #expect(attempt.address == ServerAddress(scheme: .https, host: "jf.example.com", path: "/jellyfin"))
        #expect(flow.address == attempt.address)
    }

    @Test func anAddressThatIsntOneStaysOnTheServerStepAtTheFieldAtFault() {
        var flow = SignInFlow()
        flow.username = "Alex"
        _ = flow.submitAccount()
        flow.address.host = "nas.local"
        flow.address.port = "99999"
        #expect(flow.connect() == .focus(.port))
        #expect(flow.serverError == ServerAddress.Problem.invalidPort.localizedDescription)
        flow.address.port = ""
        flow.address.host = "nas local"
        #expect(flow.connect() == .focus(.host))
        #expect(flow.step == .server)
    }

    @Test func aPickedServerThatDoesntAnswerGoesToTheServerStepWithItsAddress() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        let error = URLError(.cannotConnectToHost)
        #expect(flow.fail(attempt, while: .findingServer, with: error) == .host)
        #expect(flow.step == .server)
        #expect(!flow.isQuickConnect)
        #expect(flow.address == SignIn.homeAddress)
        #expect(flow.serverError == error.localizedDescription)
        #expect(flow.accountError == nil)
        // The server stays picked, for Back.
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
    }

    @Test func aPickedServerThatIsntJellyfinGoesToTheServerStep() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        let error = JellyfinError.notJellyfin(SignIn.home.address)
        #expect(flow.fail(attempt, while: .findingServer, with: error) == .host)
        #expect(flow.step == .server)
        #expect(flow.serverError == error.localizedDescription)
    }

    @Test func aWrongPasswordOnTheAccountStepStaysThereWithTheCursorInThePassword() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        #expect(flow.found(SignIn.server("http://nas.local:8096"), at: SignIn.homeAddress, for: attempt) == nil)
        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials) == .password)
        #expect(flow.step == .account)
        #expect(flow.accountError == "Wrong username or password.")
    }

    @Test func aWrongPasswordOnTheServerStepGoesBackToTheAccountWithTheServerPicked() throws {
        var flow = SignInFlow()
        flow.username = "Alex"
        _ = flow.submitAccount()
        flow.address.host = "nas.local"
        let attempt = try SignIn.attempt(flow.connect())
        // Nothing answered on HTTP, so the server answered at the fallback, which the fields keep.
        let fallback = try #require(attempt.address.fallback)
        #expect(flow.found(SignIn.server("https://nas.local"), at: fallback, for: attempt) == nil)
        #expect(flow.address == fallback)
        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials) == .password)
        #expect(flow.step == .account)
        #expect(flow.accountError == "Wrong username or password.")
        #expect(flow.pickedServer == SignInFlow.PickedServer(address: fallback, url: URL(string: "https://nas.local")!, title: "Home"))
        // Signing in again goes to the server that answered.
        #expect(try SignIn.attempt(flow.submitAccount()).address == fallback)
    }

    @Test func aServerThatDoesntAnswerStaysOnTheServerStep() throws {
        var flow = SignInFlow()
        flow.username = "Alex"
        _ = flow.submitAccount()
        flow.address.host = "nas.local"
        let attempt = try SignIn.attempt(flow.connect())
        #expect(flow.fail(attempt, while: .findingServer, with: URLError(.timedOut)) == .host)
        #expect(flow.step == .server)
        #expect(flow.address == ServerAddress(host: "nas.local"))
        #expect(flow.serverError == URLError(.timedOut).localizedDescription)
        #expect(flow.pickedServer == nil)
        // The error is about that address, and goes as it changes.
        flow.address.host = "nas.lan"
        #expect(flow.serverError == nil)
    }

    @Test func otherErrorsStayOnTheirStep() throws {
        let error = JellyfinError.http(status: 500, body: "")
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        _ = flow.found(SignIn.server("http://nas.local:8096"), at: SignIn.homeAddress, for: attempt)
        #expect(flow.fail(attempt, while: .signingIn, with: error) == nil)
        #expect(flow.step == .account)
        #expect(flow.accountError == error.localizedDescription)

        _ = flow.changeServer()
        let fromServer = try SignIn.attempt(flow.connect())
        _ = flow.found(SignIn.server("http://nas.local:8096"), at: SignIn.homeAddress, for: fromServer)
        #expect(flow.fail(fromServer, while: .signingIn, with: error) == nil)
        #expect(flow.step == .server)
        #expect(flow.serverError == error.localizedDescription)
    }

    @Test func theServerStepWithoutAUsernamePicksTheServerForTheAccountStep() throws {
        var flow = SignIn.pickedHome()
        flow.username = ""
        #expect(flow.changeServer() == .host)
        #expect(flow.address == SignIn.homeAddress)
        flow.address.host = "jf.example.com"
        flow.address.port = ""
        let attempt = try SignIn.attempt(flow.connect())
        #expect(attempt.goal == .server)
        let answered = ServerAddress(host: "jf.example.com")
        #expect(flow.found(SignIn.server("http://jf.example.com:8096", named: "Family"), at: answered, for: attempt) == .username)
        #expect(flow.step == .account)
        #expect(flow.pickedServer?.title == "Family")
        #expect(flow.pickedServer?.address == answered)
    }

    @Test func backKeepsThePickedServerAndChangeStartsFromIt() {
        var flow = SignIn.pickedHome()
        _ = flow.changeServer()
        flow.address.host = "elsewhere.local"
        flow.back()
        #expect(flow.step == .account)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
        _ = flow.changeServer()
        #expect(flow.address == SignIn.homeAddress)
    }

    @Test func quickConnectAsksForTheServerOrGoesStraightToTheCode() throws {
        var fresh = SignInFlow()
        #expect(fresh.useQuickConnect() == .focus(.host))
        #expect(fresh.step == .server)
        #expect(fresh.isQuickConnect)
        fresh.address.host = "nas.local"
        #expect(try SignIn.attempt(fresh.connect()).goal == .quickConnect)

        var picked = SignIn.pickedHome()
        #expect(try SignIn.attempt(picked.useQuickConnect()) == SignInFlow.Attempt(address: SignIn.homeAddress, goal: .quickConnect))
        #expect(picked.step == .account)
    }

    @Test func quickConnectTurnedOffOffersThePasswordWithTheServerPicked() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.useQuickConnect())
        _ = flow.found(SignIn.server("http://nas.local:8096"), at: SignIn.homeAddress, for: attempt)
        #expect(flow.fail(attempt, while: .signingIn, with: JellyfinError.quickConnectDisabled) == nil)
        #expect(flow.step == .server)
        #expect(flow.isQuickConnect)
        #expect(flow.offersPassword)
        #expect(flow.address == SignIn.homeAddress)
        #expect(flow.serverError == JellyfinError.quickConnectDisabled.localizedDescription)

        #expect(flow.usePassword() == .password)
        #expect(flow.step == .account)
        #expect(!flow.offersPassword)
        #expect(flow.pickedServer?.address == SignIn.homeAddress)
    }

    @Test func aQuickConnectServerThatDoesntAnswerStaysInQuickConnect() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.useQuickConnect())
        #expect(flow.fail(attempt, while: .findingServer, with: URLError(.cannotConnectToHost)) == .host)
        #expect(flow.step == .server)
        #expect(flow.isQuickConnect)
        #expect(try SignIn.attempt(flow.connect()).goal == .quickConnect)
    }

    @Test func startingAgainClearsTheLastError() throws {
        var flow = SignIn.pickedHome()
        let attempt = try SignIn.attempt(flow.submitAccount())
        _ = flow.fail(attempt, while: .signingIn, with: JellyfinError.invalidCredentials)
        _ = flow.submitAccount()
        #expect(flow.accountError == nil)
    }
}
