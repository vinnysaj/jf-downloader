import Foundation

/// A Jellyfin server address as the sign-in form edits it: protocol, host, port and base path.
nonisolated struct ServerAddress: Equatable, Sendable {
    enum Scheme: String, CaseIterable, Sendable {
        case http, https

        /// Jellyfin listens on 8096 for HTTP; HTTPS is usually a reverse proxy on 443.
        var defaultPort: Int { self == .http ? 8096 : 443 }
    }

    var scheme = Scheme.http
    var host = ""
    /// Empty means the scheme's default port.
    var port = ""
    /// Empty, or the base URL Jellyfin is configured with, e.g. "/jellyfin".
    var path = ""

    init(scheme: Scheme = .http, host: String = "", port: String = "", path: String = "") {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }

    /// Splits a full address someone typed or pasted ("jf.example.com:8920/jellyfin",
    /// "https://10.0.0.5/jf/"). Without a scheme, `defaultScheme` is assumed.
    init?(parsing text: String, defaultScheme: Scheme = .http) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "\(defaultScheme.rawValue)://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme.flatMap({ Scheme(rawValue: $0.lowercased()) }),
              let host = components.host, !host.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = host
        port = components.port.map(String.init) ?? ""
        path = Self.normalizedPath(components.path)
    }

    /// Splits a full address typed into the host field into the fields; the port and path
    /// already entered stay unless the address has its own.
    mutating func splitHost() {
        guard Self.looksLikeFullAddress(host), let parsed = ServerAddress(parsing: host, defaultScheme: scheme) else { return }
        scheme = parsed.scheme
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

    /// The base URL, or a message saying what's wrong with the address.
    var url: Result<URL, JellyfinError> {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(.invalidServerAddress("Enter the server's host name or IP address.")) }
        guard host.rangeOfCharacter(from: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":/?#@"))) == nil else {
            return .failure(.invalidServerAddress("“\(host)” isn't a host name or IP address."))
        }
        guard let portNumber, (1...65535).contains(portNumber) else {
            return .failure(.invalidServerAddress("The port has to be a number from 1 to 65535."))
        }
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        if portNumber != (scheme == .http ? 80 : 443) { components.port = portNumber }
        components.path = Self.normalizedPath(path)
        guard let url = components.url else { return .failure(.invalidServerAddress("That address isn't valid.")) }
        return .success(url)
    }

    /// "" or "/base/path": a leading slash and no trailing one.
    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : "/" + trimmed
    }
}
