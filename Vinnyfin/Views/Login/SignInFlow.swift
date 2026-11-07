import Foundation

/// The sign-in screen's two steps, what's entered in them, and where each outcome takes them.
/// The account step asks who is signing in and the server step where. A sign-in that fails goes
/// to the step whose fields can put it right, and names the field that needs attention there.
nonisolated struct SignInFlow: Sendable {
    enum Step: Hashable, Sendable {
        case account, server
    }

    /// Return moves through each step's fields in this order, and signs in from the last.
    enum Field: Hashable, Sendable {
        case username, password, host, port, path
    }

    /// The server the account step signs in to, and what it's called there.
    struct PickedServer: Equatable, Sendable {
        var address: ServerAddress
        var url: URL
        var title: String
    }

    /// What a sign-in asks of the server once it answers.
    enum Goal: Equatable, Sendable {
        /// Signing in, with the username and password as they were when it started.
        case password(username: String, password: String)
        /// A Quick Connect code to approve on a device that's signed in.
        case quickConnect
        /// Only its answer, so that the account step signs in to it.
        case server
    }

    /// One sign-in: the address it goes to, and what for.
    struct Attempt: Equatable, Sendable {
        var address: ServerAddress
        var goal: Goal
        /// The demo account's, whose errors stay on the account step: its server has no fields
        /// to put right.
        var isDemo = false
    }

    /// What a step's button leads to: a sign-in to run, or a field to fill in first.
    enum Next: Equatable, Sendable {
        case attempt(Attempt)
        case focus(Field)
    }

    /// What a sign-in was doing when it failed.
    enum Stage: Sendable {
        /// Waiting for a server to answer at the address.
        case findingServer
        /// Signing in to the server that answered, or getting its Quick Connect code approved.
        case signingIn
    }

    /// What a failure says is wrong, which says the step to put it right on.
    private enum Problem: Equatable {
        /// No Jellyfin server answers at the address, or it isn't an address; the field is the
        /// one at fault.
        case address(Field)
        case credentials
        case quickConnectOff
        case other
    }

    private(set) var step = Step.account
    /// Whether the server step's button gets a Quick Connect code, rather than signing in with
    /// the password.
    private(set) var isQuickConnect = false
    var username = ""
    var password = ""
    /// The server step's fields.
    var address = ServerAddress()
    private(set) var pickedServer: PickedServer?
    private(set) var accountError: String?
    /// The server step's error, with the address it's about.
    private var serverProblem: (message: String, address: ServerAddress)?
    /// Quick Connect is off on the server, so the server step offers the password in its place.
    private(set) var offersPassword = false
    private var hasStarted = false

    /// The server step's error, while the address is the one it's about.
    var serverError: String? {
        guard let serverProblem, serverProblem.address == address else { return nil }
        return serverProblem.message
    }

    /// The username as it's sent, without the spaces around it.
    var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the account step's button signs in, to the demo server or the server picked,
    /// rather than going on to ask for the server.
    var accountStepSignsIn: Bool {
        pickedServer != nil || Self.isDemoAccount(username: username, password: password)
    }

    // MARK: Starting

    /// Starts from a server offered to sign in to, such as the one a handed-off title is from,
    /// with its password if there's one saved, else from the last sign-in on this device. Only
    /// the first call does, so the screen appearing again leaves what's been entered.
    mutating func start(offer: ServerSignIn?, password: String?, lastServerURL: URL?, lastUserName: String?) -> Next? {
        guard !hasStarted else { return nil }
        hasStarted = true
        if let offer { return choose(offer, password: password) }
        if let lastServerURL, let address = ServerAddress(savedURL: lastServerURL) {
            pickedServer = PickedServer(address: address, url: lastServerURL,
                                        title: lastServerURL.host() ?? lastServerURL.absoluteString)
        }
        username = lastUserName ?? ""
        return nil
    }

    /// Picks a server someone signed in to, with their username. With the password they last
    /// signed in with there, saved in iCloud Keychain on any of their devices, it signs in;
    /// without one, the password is next.
    mutating func choose(_ signIn: ServerSignIn, password: String?) -> Next? {
        guard let address = ServerAddress(savedURL: signIn.address) else {
            accountError = "\(signIn.address.absoluteString) isn't a server address vinnyfin can use."
            return nil
        }
        show(.account)
        pickedServer = PickedServer(address: address, url: signIn.address, title: signIn.serverTitle)
        username = signIn.userName
        self.password = password ?? ""
        guard password != nil else { return .focus(.password) }
        return begin(Attempt(address: address, goal: credentials))
    }

    // MARK: The account step

    /// The account step's button. The demo account signs in to the demo server, and any other to
    /// the server picked; without one, the server step asks for its address.
    mutating func submitAccount() -> Next {
        guard !trimmedUsername.isEmpty else { return .focus(.username) }
        if Self.isDemoAccount(username: username, password: password) {
            return begin(Attempt(address: Self.demoServer, goal: .password(username: Self.demoUserName, password: password),
                                 isDemo: true))
        }
        if let pickedServer { return begin(Attempt(address: pickedServer.address, goal: credentials)) }
        show(.server)
        return .focus(.host)
    }

    /// Quick Connect from the account step: a code from the server picked, or without one, the
    /// server step asks for its address.
    mutating func useQuickConnect() -> Next {
        if let pickedServer { return begin(Attempt(address: pickedServer.address, goal: .quickConnect)) }
        show(.server, quickConnect: true)
        return .focus(.host)
    }

    /// The server step, to change the server picked, starting from its address.
    mutating func changeServer() -> Field {
        if let pickedServer { address = pickedServer.address }
        show(.server)
        return .host
    }

    // MARK: The server step

    /// The server step's button. Once a server answers at the address, the password signs in to
    /// it or Quick Connect gets a code from it; without a username, the account step asks for one.
    mutating func connect() -> Next {
        address.splitHost()
        if case .failure(let problem) = address.url {
            show(.server, quickConnect: isQuickConnect)
            serverProblem = (problem.localizedDescription, address)
            return .focus(Self.field(for: problem))
        }
        let goal = isQuickConnect ? .quickConnect : trimmedUsername.isEmpty ? .server : credentials
        return begin(Attempt(address: address, goal: goal))
    }

    /// Back to the account step, with the server as it was picked.
    mutating func back() {
        show(.account)
    }

    /// The password in place of Quick Connect, which is off on the server: the account step, with
    /// the server picked.
    mutating func usePassword() -> Field {
        show(.account)
        return trimmedUsername.isEmpty ? .username : .password
    }

    // MARK: Outcomes

    /// The server answered at `address`: it's the one the account step signs in to, and the
    /// server step keeps the address it answered at. An attempt for the server alone ends on the
    /// account step, for the username.
    mutating func found(_ server: AccountStore.Server, at address: ServerAddress, for attempt: Attempt) -> Field? {
        guard !attempt.isDemo else { return nil }
        pickedServer = PickedServer(address: address, url: server.url, title: server.title)
        if step == .server { self.address = address }
        guard attempt.goal == .server else { return nil }
        show(.account)
        return .username
    }

    /// Shows why an attempt failed on the step whose fields can put it right, and names the field
    /// that needs attention there. An address no Jellyfin server answers at goes to the server
    /// step, with the address in its fields; a wrong username or password goes to the account
    /// step, the server staying picked; Quick Connect turned off goes to the server step, which
    /// offers the password in its place. Anything else stays where it is, as do all of the demo
    /// account's errors.
    mutating func fail(_ attempt: Attempt, while stage: Stage, with error: any Error) -> Field? {
        let message = error.localizedDescription
        let problem = Self.problem(in: error, while: stage)
        if attempt.isDemo {
            accountError = message
            return problem == .credentials ? .password : nil
        }
        switch problem {
        case .address(let field):
            if step == .account { address = attempt.address }
            show(.server, quickConnect: attempt.goal == .quickConnect)
            serverProblem = (message, address)
            return field
        case .credentials:
            show(.account)
            accountError = message
            return .password
        case .quickConnectOff:
            if step == .account { address = attempt.address }
            show(.server, quickConnect: true)
            serverProblem = (message, address)
            offersPassword = true
            return nil
        case .other:
            switch step {
            case .account: accountError = message
            case .server: serverProblem = (message, address)
            }
            return nil
        }
    }

    private static func problem(in error: any Error, while stage: Stage) -> Problem {
        switch (stage, error) {
        case (.findingServer, let problem as ServerAddress.Problem): .address(field(for: problem))
        case (.findingServer, _): .address(.host)
        case (.signingIn, JellyfinError.invalidCredentials): .credentials
        case (.signingIn, JellyfinError.quickConnectDisabled): .quickConnectOff
        case (.signingIn, _): .other
        }
    }

    private static func field(for problem: ServerAddress.Problem) -> Field {
        problem == .invalidPort ? .port : .host
    }

    private var credentials: Goal { .password(username: trimmedUsername, password: password) }

    /// Starts an attempt; the last one's errors go.
    private mutating func begin(_ attempt: Attempt) -> Next {
        accountError = nil
        serverProblem = nil
        offersPassword = false
        return .attempt(attempt)
    }

    /// Goes to a step, without the errors either step showed.
    private mutating func show(_ step: Step, quickConnect: Bool = false) {
        self.step = step
        isQuickConnect = step == .server && quickConnect
        accountError = nil
        serverProblem = nil
        offersPassword = false
    }

    // MARK: The demo account

    /// The demo server, which App Review signs in to. App Store Connect gives reviewers a username
    /// and password and nothing else, so the demo account signs in there whatever server is picked.
    static let demoServer = ServerAddress(scheme: .https, host: "jftest.vinnysaj.net")
    static let demoUserName = "apple"
    private static let demoPassword = "apple"

    /// Whether the username and password are the demo account's: the username in any case and
    /// without the spaces around it, the password exactly.
    static func isDemoAccount(username: String, password: String) -> Bool {
        username.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(demoUserName) == .orderedSame
            && password == demoPassword
    }
}
