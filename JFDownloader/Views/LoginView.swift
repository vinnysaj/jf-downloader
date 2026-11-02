import SwiftUI

struct LoginView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var address = ServerAddress()
    @State private var username = ""
    @State private var password = ""
    @State private var check = ServerCheck.idle
    @State private var isSigningIn = false
    @State private var error: String?
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
                        .textInputAutocapitalization(.never)
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
            }
            .navigationTitle("Add Server")
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
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .host)
                    .submitLabel(.next)
                    .onSubmit { focus = .port }
                    .accessibilityIdentifier("login.host")
            }
            LabeledContent("Port") {
                TextField("Port", text: $address.port, prompt: Text(String(address.scheme.defaultPort)))
                    // Has a return key, unlike the number pad.
                    .keyboardType(.numbersAndPunctuation)
                    .focused($focus, equals: .port)
                    .submitLabel(.next)
                    .onSubmit { focus = .path }
                    .accessibilityIdentifier("login.port")
            }
            LabeledContent("Base Path") {
                TextField("Base Path", text: $address.path, prompt: Text("Optional, e.g. /jellyfin"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
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
            .textSelection(.enabled)
        }
    }

    private var canSignIn: Bool {
        guard case .success = address.url else { return false }
        return !username.isEmpty && !isSigningIn
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
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            check = .failed(error.localizedDescription)
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
