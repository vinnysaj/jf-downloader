import SwiftUI

/// Signs in to a Jellyfin server, asking for the account first and the server second: a server
/// signed in to before, on this device or another of the person's, signs in with a tap, with the
/// password saved in iCloud Keychain or for the password next, and any other is asked for by its
/// address once the account is in (see `SignInFlow`).
struct LoginView: View {
    /// A sign-in to start from, such as the one a handed-off title is from.
    var offer: ServerSignIn?

    @Environment(AccountStore.self) private var accounts
    @Environment(KnownServers.self) private var knownServers
    @Environment(AppMessages.self) private var messages
    @Environment(\.dismiss) private var dismiss
    @State private var flow = SignInFlow()
    @State private var check = ServerCheck.idle
    /// The sign-in under way. There's one at a time, and going Back or to another server takes it
    /// back.
    @State private var running: Running?
    @State private var quickConnect: QuickConnectState?
    @FocusState private var focus: SignInFlow.Field?
    /// The field the cursor moves to next, which comes into view first: a form draws only the
    /// rows on screen, and a field it hasn't drawn can't take the cursor.
    @State private var nextFocus: SignInFlow.Field?

    private struct Running {
        var goal: SignInFlow.Goal
        var task: Task<Void, Never>
    }

    /// Whether a Jellyfin server answers at the server step's address, as it's typed.
    enum ServerCheck {
        case idle
        case checking
        case found(AccountStore.Server)
        case failed(String)
    }

    private static let quickConnectExplanation: LocalizedStringKey =
        "Shows a code to approve in Jellyfin on a device that's already signed in, so there's no password to type."

    var body: some View {
        NavigationStack {
            ScrollViewReader { form in
                Form {
                    switch flow.step {
                    case .account: accountStep
                    case .server: serverStep
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("Connect to Jellyfin")
                #if os(tvOS)
                .onExitCommand(perform: exitCommand)
                #else
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) { stepButton }
                }
                // Closing the sheet takes back the sign-in under way.
                .onDisappear(perform: cancelSignIn)
                #endif
                .sheet(item: $quickConnect, onDismiss: cancelSignIn) { state in
                    QuickConnectSheet(code: state.code, onCancel: cancelSignIn)
                }
                .onAppear {
                    if let next = flow.start(offer: offer, password: offer.flatMap { savedPassword(for: $0) },
                                             lastServerURL: accounts.lastServerURL, lastUserName: accounts.lastUserName) {
                        follow(next)
                    }
                }
                .onChange(of: focus) { previous, _ in
                    // A full address in the host field fills in the other fields once the host is
                    // done, so "nas:8096" isn't cut apart at "nas:" while it's being typed.
                    if previous == .host { flow.address.splitHost() }
                }
                .task(id: flow.step == .server ? flow.address : nil) { await checkServer() }
                .onChange(of: nextFocus) { _, field in
                    guard let field else { return }
                    nextFocus = nil
                    form.scrollTo(field)
                    focus = field
                }
            }
        }
    }

    #if os(tvOS)
    /// Menu on the server step goes back to the account step. The account step is the app's first
    /// screen, so there Menu leaves the app as usual.
    private var exitCommand: (@MainActor () -> Void)? {
        flow.step == .server ? back : nil
    }
    #endif

    /// The step's button, which signs in or goes on to the next step: beside Cancel in the
    /// sheet's bar, and on Apple TV, whose sheet has no bar, in the form.
    @ViewBuilder private var stepButton: some View {
        switch flow.step {
        case .account:
            Button(action: submitAccount) {
                title(flow.accountStepSignsIn ? "Sign In" : "Next",
                      isRunning: running.map { $0.goal != .quickConnect } ?? false)
            }
            .disabled(flow.trimmedUsername.isEmpty || running != nil)
            .accessibilityIdentifier("login.submit")
        case .server:
            Button(action: connect) {
                title(connectTitle, isRunning: running != nil)
            }
            .disabled(flow.address.host.trimmingCharacters(in: .whitespaces).isEmpty || running != nil)
            .accessibilityIdentifier("login.connect")
        }
    }

    // MARK: The account step

    @ViewBuilder private var accountStep: some View {
        Section {
            TextField("Username", text: $flow.username)
                .textContentType(.username)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { nextFocus = .password }
                .accessibilityIdentifier("login.username")
                .id(SignInFlow.Field.username)
            SecureField("Password", text: $flow.password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(flow.accountStepSignsIn ? .go : .next)
                .onSubmit(submitAccount)
                .accessibilityIdentifier("login.password")
                .id(SignInFlow.Field.password)
        } header: {
            Text("Account")
        } footer: {
            if let error = flow.accountError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("login.error")
            }
        }
        if let server = flow.pickedServer {
            Section {
                LabeledContent("Signing in to \(server.title)") {
                    Button("Change", action: changeServer)
                        .accessibilityIdentifier("login.changeServer")
                        .accessibilityValue(server.url.absoluteString)
                }
            }
        }
        #if os(tvOS)
        Section { stepButton }
        #endif
        Section {
            Button(action: useQuickConnect) {
                title("Use Quick Connect", systemImage: "number.square", isRunning: running?.goal == .quickConnect)
            }
            .disabled(running != nil)
            .accessibilityIdentifier("login.quickConnect")
        } footer: {
            Text(Self.quickConnectExplanation)
        }
        knownServersSection
    }

    /// The servers signed in to on the person's devices, from iCloud: one tap picks the server
    /// and fills in the user, and the password or Quick Connect does the rest.
    @ViewBuilder private var knownServersSection: some View {
        if !knownServers.signIns.isEmpty || knownServers.problem != nil {
            Section {
                ForEach(knownServers.signIns) { signIn in
                    Button {
                        choose(signIn)
                    } label: {
                        Label("Sign in to \(signIn.serverTitle) as \(signIn.userName)", systemImage: "server.rack")
                    }
                    .contextMenu {
                        Button("Forget", systemImage: "trash", role: .destructive) { knownServers.forget(signIn) }
                    }
                    .accessibilityIdentifier("login.knownServer")
                }
            } header: {
                Text("Your Servers")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Servers you've signed in to on your devices. Choosing one signs in with the password saved in iCloud Keychain; without one, enter the password or use Quick Connect.")
                    if let problem = knownServers.problem {
                        Text(problem).foregroundStyle(.orange)
                        Button("Dismiss") { knownServers.problem = nil }
                    }
                }
            }
        }
    }

    // MARK: The server step

    @ViewBuilder private var serverStep: some View {
        Section {
            Picker("Protocol", selection: Binding { flow.address.scheme } set: { flow.address.choose($0) }) {
                Text("HTTP").tag(ServerAddress.Scheme.http)
                Text("HTTPS").tag(ServerAddress.Scheme.https)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("login.scheme")
            LabeledContent("Host") {
                TextField("Host", text: $flow.address.host, prompt: Text("192.168.1.10 or jf.example.com"))
                    .labelsHidden()
                    .textContentType(.URL)
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .host)
                    .submitLabel(.next)
                    .onSubmit { nextFocus = .port }
                    .accessibilityIdentifier("login.host")
            }
            .id(SignInFlow.Field.host)
            LabeledContent("Port") {
                TextField("Port", text: $flow.address.port, prompt: Text(String(flow.address.scheme.defaultPort)))
                    .labelsHidden()
                    #if !os(macOS)
                    // Has a return key, unlike the number pad.
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .focused($focus, equals: .port)
                    .submitLabel(.next)
                    .onSubmit { nextFocus = .path }
                    .accessibilityIdentifier("login.port")
            }
            .id(SignInFlow.Field.port)
            LabeledContent("Base Path") {
                TextField("Base Path", text: $flow.address.path, prompt: Text("Optional, e.g. /jellyfin"))
                    .labelsHidden()
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .path)
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .accessibilityIdentifier("login.path")
            }
            .id(SignInFlow.Field.path)
        } header: {
            Text("Server")
        } footer: {
            serverStatus
        }
        #if os(tvOS)
        Section { stepButton }
        #endif
        if flow.offersPassword {
            Section {
                Button("Sign In with a Password", systemImage: "key", action: usePassword)
                    .accessibilityIdentifier("login.usePassword")
            }
        }
        Section {
            Button("Back", systemImage: "chevron.backward", action: back)
                .accessibilityIdentifier("login.back")
        }
    }

    /// The address as a URL, then why it didn't do, or else whether a server answers at it, and
    /// what the step's button does there.
    private var serverStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .success(let url) = flow.address.url {
                Text(url.absoluteString).monospaced()
            }
            if let error = flow.serverError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("login.error")
            } else {
                switch check {
                case .idle:
                    EmptyView()
                case .checking:
                    Text("Looking for the server…")
                case .found(let server):
                    Label(description(of: server), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if flow.isQuickConnect {
                Text(Self.quickConnectExplanation)
            } else if !flow.trimmedUsername.isEmpty {
                Text("Signs in as \(flow.trimmedUsername).")
            }
        }
        #if !os(tvOS)
        .textSelection(.enabled)
        #endif
    }

    /// "Found Home (Jellyfin 10.11.0)", and where, when it's not at the address as the fields
    /// have it.
    private func description(of server: AccountStore.Server) -> String {
        let version = server.info.version.map { " (Jellyfin \($0))" } ?? ""
        let isAtTheFields = if case .success(let url) = flow.address.url { url == server.url } else { false }
        return "Found \(server.title)\(version)\(isAtTheFields ? "" : " at \(server.url.absoluteString)")"
    }

    private var connectTitle: LocalizedStringKey {
        if flow.isQuickConnect { return "Get Code" }
        return flow.trimmedUsername.isEmpty ? "Next" : "Sign In"
    }

    /// A button's title, followed by a spinner while the sign-in it started is under way.
    private func title(_ text: LocalizedStringKey, systemImage: String? = nil, isRunning: Bool) -> some View {
        HStack {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: Actions

    private func submitAccount() {
        guard running == nil else { return }
        follow(flow.submitAccount())
    }

    private func useQuickConnect() {
        guard running == nil else { return }
        follow(flow.useQuickConnect())
    }

    private func connect() {
        guard running == nil else { return }
        follow(flow.connect())
    }

    private func choose(_ signIn: ServerSignIn) {
        cancelSignIn()
        if let next = flow.choose(signIn, password: savedPassword(for: signIn)) { follow(next) }
    }

    /// The password `signIn` last signed in with on any of the person's devices; nil when there's
    /// none, or when iCloud Keychain won't give it, which the servers' footer then says.
    private func savedPassword(for signIn: ServerSignIn) -> String? {
        do {
            return try Keychain.syncedPassword(for: signIn.id)
        } catch {
            knownServers.problem = error.localizedDescription
            return nil
        }
    }

    /// Saves the password just signed in with in iCloud Keychain, for the person's other devices.
    /// The sign-in stands either way.
    private func keepPassword(_ password: String) {
        guard let account = accounts.account else { return }
        do {
            try Keychain.setSyncedPassword(password, for: ServerSignIn(account).id)
        } catch {
            messages.show("You're signed in, but your other devices will still ask for the password. \(error.localizedDescription)")
        }
    }

    private func changeServer() {
        cancelSignIn()
        nextFocus = flow.changeServer()
    }

    private func back() {
        cancelSignIn()
        flow.back()
    }

    private func usePassword() {
        cancelSignIn()
        nextFocus = flow.usePassword()
    }

    private func follow(_ next: SignInFlow.Next) {
        switch next {
        case .focus(let field):
            nextFocus = field
        case .attempt(let attempt):
            let task = Task {
                await run(attempt)
                // A sign-in taken back has made way for the next already.
                if !Task.isCancelled { running = nil }
            }
            running = Running(goal: attempt.goal, task: task)
        }
    }

    private func cancelSignIn() {
        running?.task.cancel()
        running = nil
        quickConnect = nil
    }

    /// Finds the server, then signs in to it with the password, or shows a Quick Connect code
    /// and waits for its approval.
    private func run(_ attempt: SignInFlow.Attempt) async {
        let found: (address: ServerAddress, answer: AccountStore.Server)
        do {
            found = try await attempt.address.firstAnswer { try await accounts.findServer(at: $0) }
        } catch {
            fail(attempt, while: .findingServer, with: error)
            return
        }
        guard !Task.isCancelled else { return }
        let server = found.answer
        if let field = flow.found(server, at: found.address, for: attempt) { nextFocus = field }
        do {
            switch attempt.goal {
            case .server:
                return
            case .password(let username, let password):
                try await accounts.signIn(to: server, username: username, password: password)
                keepPassword(password)
            case .quickConnect:
                let state = try await accounts.startQuickConnect(on: server)
                guard !Task.isCancelled else { return }
                quickConnect = state
                try await accounts.finishQuickConnect(on: server, secret: state.secret)
            }
        } catch {
            fail(attempt, while: .signingIn, with: error)
            return
        }
        guard !Task.isCancelled else { return }
        quickConnect = nil
        dismiss()
    }

    private func fail(_ attempt: SignInFlow.Attempt, while stage: SignInFlow.Stage, with error: any Error) {
        guard !Task.isCancelled, !error.isCancellation else { return }
        quickConnect = nil
        if let field = flow.fail(attempt, while: stage, with: error) { nextFocus = field }
    }

    private func checkServer() async {
        guard flow.step == .server, case .success = flow.address.url else {
            check = .idle
            return
        }
        // Wait for typing to settle; a newer address cancels this check.
        do {
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            return
        }
        check = .checking
        do {
            check = .found(try await flow.address.firstAnswer { try await accounts.findServer(at: $0) }.answer)
        } catch {
            if !Task.isCancelled, !error.isCancellation { check = .failed(error.localizedDescription) }
        }
    }
}

/// The Quick Connect code, shown large while waiting for it to be approved.
private struct QuickConnectSheet: View {
    let code: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Quick Connect").font(.title2.weight(.semibold))
            Text("In Jellyfin on a signed-in device, open your profile, choose Quick Connect and enter this code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Text(code)
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .kerning(8)
                .accessibilityIdentifier("login.quickConnectCode")
            ProgressView("Waiting for approval…")
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(40)
        .presentationDetents([.medium])
    }
}
