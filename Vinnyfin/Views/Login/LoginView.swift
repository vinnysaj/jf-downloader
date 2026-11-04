import SwiftUI

struct LoginView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var address = ServerAddress()
    @State private var username = ""
    @State private var password = ""
    @State private var check = ServerCheck.idle
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var quickConnect: QuickConnectState?
    @State private var quickConnectTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    /// Return moves through the fields in this order; on the password it signs in.
    enum Field: CaseIterable {
        case host, port, path, username, password
    }

    enum ServerCheck: Equatable {
        case idle
        case checking
        case found(name: String, version: String?)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("login.username")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                        .accessibilityIdentifier("login.password")
                } header: {
                    Text("Account")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign In")
                            if isSigningIn {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!canSignIn)
                    .accessibilityIdentifier("login.submit")
                }
                Section {
                    Button("Sign In with Quick Connect", systemImage: "number.square") {
                        Task { await startQuickConnect() }
                    }
                    .disabled(!hasValidAddress || isSigningIn)
                    .accessibilityIdentifier("login.quickConnect")
                } footer: {
                    Text("Shows a code to approve in Jellyfin on a device that's already signed in, so there's no password to type.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connect to Jellyfin")
            .sheet(item: $quickConnect, onDismiss: cancelQuickConnect) { state in
                QuickConnectSheet(code: state.code) { cancelQuickConnect() }
            }
            .onAppear(perform: prefill)
            .onChange(of: focus) { previous, _ in
                // A full address in the host field fills in the other fields once the host is
                // done, so "nas:8096" isn't cut apart at "nas:" while it's being typed.
                if previous == .host { address.splitHost() }
            }
            .task(id: address) { await checkServer() }
        }
    }

    private var serverSection: some View {
        Section {
            Picker("Protocol", selection: $address.scheme) {
                Text("HTTP").tag(ServerAddress.Scheme.http)
                Text("HTTPS").tag(ServerAddress.Scheme.https)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("login.scheme")
            LabeledContent("Host") {
                TextField("Host", text: $address.host, prompt: Text("192.168.1.10 or jf.example.com"))
                    .textContentType(.URL)
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .host)
                    .submitLabel(.next)
                    .onSubmit { focus = .port }
                    .accessibilityIdentifier("login.host")
            }
            LabeledContent("Port") {
                TextField("Port", text: $address.port, prompt: Text(String(address.scheme.defaultPort)))
                    #if !os(macOS)
                    // Has a return key, unlike the number pad.
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .focused($focus, equals: .port)
                    .submitLabel(.next)
                    .onSubmit { focus = .path }
                    .accessibilityIdentifier("login.port")
            }
            LabeledContent("Base Path") {
                TextField("Base Path", text: $address.path, prompt: Text("Optional, e.g. /jellyfin"))
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .path)
                    .submitLabel(.next)
                    .onSubmit { focus = .username }
                    .accessibilityIdentifier("login.path")
            }
        } header: {
            Text("Server")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if case .success(let url) = address.url {
                    Text(url.absoluteString).monospaced()
                }
                switch check {
                case .idle:
                    EmptyView()
                case .checking:
                    Text("Looking for the server…")
                case .found(let name, let version):
                    Label("Found \(name)\(version.map { " (Jellyfin \($0))" } ?? "")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            #if !os(tvOS)
            .textSelection(.enabled)
            #endif
        }
    }

    private var hasValidAddress: Bool {
        if case .success = address.url { return true }
        return false
    }

    private var canSignIn: Bool {
        hasValidAddress && !username.isEmpty && !isSigningIn
    }

    private func startQuickConnect() async {
        address.splitHost()
        guard case .success(let url) = address.url else { return }
        error = nil
        do {
            let state = try await accounts.startQuickConnect(serverURL: url)
            quickConnect = state
            quickConnectTask = Task {
                do {
                    try await accounts.finishQuickConnect(serverURL: url, secret: state.secret)
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                }
                quickConnect = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnect = nil
    }

    private func prefill() {
        guard address.host.isEmpty else { return }
        if let url = accounts.lastServerURL, var previous = ServerAddress(parsing: url.absoluteString) {
            // A saved http address without a port means port 80, not the form's 8096 default.
            if url.port == nil { previous.port = previous.scheme == .http ? "80" : "" }
            address = previous
        }
        if let name = accounts.lastUserName { username = name }
    }

    private func checkServer() async {
        guard case .success(let url) = address.url else {
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
            let info = try await accounts.probe(url)
            check = .found(name: info.serverName ?? url.host() ?? "server", version: info.version)
        } catch {
            if !error.isCancellation { check = .failed(error.localizedDescription) }
        }
    }

    private func signIn() async {
        address.splitHost()
        guard canSignIn else { return }
        error = nil
        let url: URL
        switch address.url {
        case .success(let valid): url = valid
        case .failure(let failure):
            error = failure.localizedDescription
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await accounts.signIn(serverURL: url, username: username, password: password)
        } catch {
            self.error = error.localizedDescription
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

