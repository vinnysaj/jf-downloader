import Foundation

/// A Jellyfin server address as the sign-in form edits it: protocol, host, port and base path.
nonisolated struct ServerAddress: Equatable, Sendable {
    enum Scheme: String, CaseIterable, Sendable {
        case http, https

        /// Jellyfin listens on 8096 for HTTP; HTTPS is usually a reverse proxy on 443.
        var defaultPort: Int { self == .http ? 8096 : 443 }
    }

    /// What's wrong with an address, which says the field to put it right in.
    enum Problem: LocalizedError, Equatable {
        case missingHost
        case invalidHost(String)
        case invalidPort
        case invalidAddress

        var errorDescription: String? {
            switch self {
            case .missingHost: "Enter the server's host name or IP address."
            case .invalidHost(let host): "“\(host)” isn't a host name or IP address."
            case .invalidPort: "The port has to be a number from 1 to 65535."
            case .invalidAddress: "That address isn't valid."
            }
        }
    }

    private(set) var scheme = Scheme.http
    /// Whether the scheme was given, by picking it, typing it with the address or saving it, rather
    /// than assumed. An address that gives neither a scheme nor a port may be on either scheme's
    /// default port (see `fallback`).
    private(set) var isSchemeGiven = false
    var host = ""
    /// Empty means the scheme's default port.
    var port = ""
    /// Empty, or the base URL Jellyfin is configured with, e.g. "/jellyfin".
    var path = ""

    /// An address on `scheme`, or without a scheme, on HTTP until it's given.
    init(scheme: Scheme? = nil, host: String = "", port: String = "", path: String = "") {
        self.scheme = scheme ?? .http
        isSchemeGiven = scheme != nil
        self.host = host
        self.port = port
        self.path = path
    }

    /// Splits a full address someone typed or pasted ("jf.example.com:8920/jellyfin",
    /// "https://10.0.0.5/jf/"). Without a scheme, it's on HTTP until one is given.
    init?(parsing text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = text.contains("://")
        if !hasScheme { text = "\(Scheme.http.rawValue)://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme.flatMap({ Scheme(rawValue: $0.lowercased()) }),
              let host = components.host, !host.isEmpty
        else { return nil }
        self.scheme = scheme
        isSchemeGiven = hasScheme
        self.host = host
        port = components.port.map(String.init) ?? ""
        path = Self.normalizedPath(components.path)
    }

    /// A server's saved URL, as the form shows it. A saved HTTP address without a port is on port
    /// 80, not the form's default of 8096.
    init?(savedURL url: URL) {
        guard var address = ServerAddress(parsing: url.absoluteString) else { return nil }
        if url.port == nil { address.port = address.scheme == .http ? "80" : "" }
        self = address
    }

    /// Picks the scheme, as the form's protocol does.
    mutating func choose(_ scheme: Scheme) {
        self.scheme = scheme
        isSchemeGiven = true
    }

    /// Splits a full address typed into the host field into the fields; the scheme, port and path
    /// already entered stay unless the address has its own.
    mutating func splitHost() {
        guard Self.looksLikeFullAddress(host), let parsed = ServerAddress(parsing: host) else { return }
        if parsed.isSchemeGiven { choose(parsed.scheme) }
        host = parsed.host
        if !parsed.port.isEmpty { port = parsed.port }
        if !parsed.path.isEmpty { path = parsed.path }
    }

    /// Whether the text looks like more than a bare host name, so it should be split up.
    static func looksLikeFullAddress(_ text: String) -> Bool {
        text.contains("://") || text.contains("/") || text.filter { $0 == ":" }.count == 1
    }

    var portNumber: Int? {
        port.isEmpty ? scheme.defaultPort : Int(port)
    }

    /// The base URL, or what's wrong with the address.
    var url: Result<URL, Problem> {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(.missingHost) }
        guard host.rangeOfCharacter(from: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":/?#@"))) == nil else {
            return .failure(.invalidHost(host))
        }
        guard let portNumber, (1...65535).contains(portNumber) else { return .failure(.invalidPort) }
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        if portNumber != (scheme == .http ? 80 : 443) { components.port = portNumber }
        components.path = Self.normalizedPath(path)
        guard let url = components.url else { return .failure(.invalidAddress) }
        return .success(url)
    }

    /// The same server on the other scheme's default port, for an address that gives neither a
    /// scheme nor a port: Jellyfin itself answers HTTP on 8096, and HTTPS is usually a reverse
    /// proxy's on 443, so a host alone may be either.
    var fallback: ServerAddress? {
        guard !isSchemeGiven, port.isEmpty else { return nil }
        return ServerAddress(scheme: scheme == .http ? .https : .http, host: host, path: path)
    }

    /// What `ask` gets from the server at this address, or when nothing answers there, at its
    /// fallback, with the address that answered. Only an address at which nothing answers moves
    /// on: a server that answers with an error, or isn't Jellyfin, has answered. When the fallback
    /// doesn't do either, the error is this address's own, as the one the form shows.
    func firstAnswer<Answer>(_ ask: (URL) async throws -> Answer) async throws -> (address: ServerAddress, answer: Answer) {
        let first = try url.get()
        do {
            return (self, try await ask(first))
        } catch let unanswered as URLError where unanswered.code != .cancelled {
            try Task.checkCancellation()
            guard let fallback, case .success(let second) = fallback.url, let answer = try? await ask(second) else {
                throw unanswered
            }
            return (fallback, answer)
        }
    }

    /// "" or "/base/path": a leading slash and no trailing one.
    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : "/" + trimmed
    }
}
