import Foundation
import Observation
import OSLog

/// Jellyfin's socket, held open while the app runs in front, signed in. Over it the server
/// passes on what other devices ask this one to play and do, and, while this device is a remote
/// for another, how that one's session is going. While the socket is open, with the
/// capabilities reported, the server lists this device as one others can play to; when it
/// closes, the server drops the session at once, so a device that has gone to the background
/// leaves every Play On list. The server can't wake an app that isn't running.
@Observable
final class SessionSocket {
    enum State: Equatable {
        case closed
        case connecting
        case open
        /// Why the last attempt failed; another follows after a pause.
        case failed(String)

        var label: String {
            switch self {
            case .closed: "Off"
            case .connecting: "Connecting…"
            case .open: "On"
            case .failed(let reason): "Not Connected: \(reason)"
            }
        }
    }

    private(set) var state = State.closed

    /// Commands from other devices.
    @ObservationIgnored var onCommand: ((RemoteCommand) -> Void)?
    /// The sessions as they change, while `followsSessions` is on.
    @ObservationIgnored var onSessions: (([RemoteSession]) -> Void)?
    /// Asks the server for the sessions as they change, at most once a second.
    var followsSessions = false {
        didSet {
            guard followsSessions != oldValue, state == .open else { return }
            send(followsSessions ? .sessionsStart(delay: 0, interval: 1) : .sessionsStop)
        }
    }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// When the server last said anything, in system uptime.
    @ObservationIgnored private var lastHeard: TimeInterval = 0
    /// Half the time the server waits for word before it closes the socket.
    @ObservationIgnored private var keepAliveInterval: Double = 30

    private nonisolated static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "socket")

    /// Holds the socket open until the calling task is cancelled, connecting again, after a
    /// growing pause, whenever it fails or the server closes it.
    func run(client: JellyfinClient) async {
        var pause: Double = 1
        while !Task.isCancelled {
            state = .connecting
            do {
                try await connect(client)
                pause = 1
            } catch {
                guard !Task.isCancelled else { break }
                Self.log.notice("The socket to \(client.serverURL, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .seconds(pause))
            pause = min(pause * 2, 30)
        }
        state = .closed
    }

    /// Opens the socket, reports what this device can do, and reads it until it closes.
    private func connect(_ client: JellyfinClient) async throws {
        let socket = URLSession.shared.webSocketTask(with: client.socketRequest)
        self.socket = socket
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket { self.socket = nil }
        }
        // The server's first word, how long it waits for keep-alives, says the socket is open.
        await handle(try await socket.receive())
        try await client.reportCapabilities(ClientCapabilities())
        state = .open
        if followsSessions { send(.sessionsStart(delay: 0, interval: 1)) }
        let keepAlive = Task { await keepAlive(socket) }
        defer { keepAlive.cancel() }
        while !Task.isCancelled {
            await handle(try await socket.receive())
        }
    }

    /// Says something every `keepAliveInterval`, and gives up on a socket the server has stopped
    /// answering, which closes without a word when the network goes.
    private func keepAlive(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(keepAliveInterval))
            guard !Task.isCancelled else { return }
            if ProcessInfo.processInfo.systemUptime - lastHeard > keepAliveInterval * 2 + 5 {
                Self.log.notice("The server stopped answering the socket")
                socket.cancel(with: .abnormalClosure, reason: nil)
                return
            }
            send(.keepAlive)
        }
    }

    private func handle(_ received: URLSessionWebSocketTask.Message) async {
        lastHeard = ProcessInfo.processInfo.systemUptime
        let data: Data
        switch received {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        let message: SocketMessage
        do {
            message = try await Self.decode(data)
        } catch {
            // One message the app can't read leaves the socket and the rest of them working.
            Self.log.error("Couldn't read a socket message: \(String(describing: error), privacy: .public)")
            return
        }
        switch message {
        case .forceKeepAlive(let seconds):
            keepAliveInterval = max(5, Double(seconds) / 2)
            send(.keepAlive)
        case .sessions(let sessions):
            onSessions?(sessions)
        case .keepAlive, .other:
            break
        case .play, .playstate, .generalCommand:
            if let command = RemoteCommand(message) {
                Self.log.info("Remote command: \(String(describing: command), privacy: .public)")
                onCommand?(command)
            } else {
                Self.log.notice("Ignored a command this app doesn't obey: \(String(describing: message), privacy: .public)")
            }
        }
    }

    /// Off the main actor: the sessions a remote follows arrive every second.
    @concurrent
    private nonisolated static func decode(_ data: Data) async throws -> SocketMessage {
        try SocketMessage(json: data)
    }

    private func send(_ message: SocketMessage.Outbound) {
        guard let socket else { return }
        socket.send(.string(message.json)) { error in
            // A failed send means the socket is going; reading it fails next, and it reconnects.
            if let error { Self.log.notice("Couldn't send on the socket: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
