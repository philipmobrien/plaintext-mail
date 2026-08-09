import Foundation
import Network

/// A minimal IMAP client supporting single-flight commands plus IDLE.
///
/// Ordinary commands (LOGIN, SELECT, FETCH, ...) use send(): tag it,
/// wait for the matching tagged reply, collect any untagged lines seen
/// along the way. This mirrors imap_reply() from the UW IMAP reference client.
///
/// IDLE doesn't fit that shape - its tagged reply only arrives after the
/// *client* decides to send DONE, potentially long after the command was
/// issued, with an unbounded number of untagged pushes in between. So it
/// gets its own start/stop pair rather than being forced through send().
final class IMAPClient {
    private let connection: NWConnection
    private lazy var reader = LiteralAwareReader { [weak self] line in
        self?.handle(line: line)
    }
    private var tagCounter = 0

    // MARK: - Ordinary command state

    private var pendingTag: String?
    private var pendingUntagged: [IMAPResponse] = []
    private var pendingCompletion: ((IMAPResponse, [IMAPResponse]) -> Void)?

    // MARK: - IDLE state

    private var isIdling = false
    private var idleTag: String?
    private var onIdleUpdate: ((IMAPResponse) -> Void)?
    private var onIdleStarted: (() -> Void)?
    private var onIdleStopped: ((IMAPResponse) -> Void)?

    // Called once, the first time the server's unprompted greeting arrives.
    private var onGreeting: (() -> Void)?

    // Called if the connection dies unexpectedly after being established
    // (server closes it, network drops, idle timeout, etc.) - lets a caller
    // like MailSession notice and recover rather than hanging forever
    // waiting on a command whose response can now never arrive.
    var onConnectionFailed: ((Error) -> Void)?

    init(host: String, port: NWEndpoint.Port = 993) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tls)
    }

    func connect(onGreeting: @escaping () -> Void) {
        self.onGreeting = onGreeting
        connection.stateUpdateHandler = { [weak self] state in
            print("State: \(state)")
            switch state {
            case .ready:
                self?.receive()
            case .failed(let error):
                self?.onConnectionFailed?(error)
            case .cancelled:
                break // clean, intentional close (e.g. logoutAndClose) - not a failure
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// Appends a raw RFC822 message to a mailbox - used to save a copy in
    /// Sent after sending via SMTP (IMAP and SMTP are entirely separate
    /// protocols; sending a message never automatically saves a copy anywhere,
    /// that's the client's job). Uses a non-synchronizing literal (LITERAL+,
    /// which Runbox's CAPABILITY advertises) so the whole command - including
    /// raw message bytes that may contain embedded CRLFs - goes in one send,
    /// without needing to handle IMAP's "+" continuation responses, which
    /// this client doesn't otherwise support.
    func sendAppend(mailbox: String, rawMessage: String, completion: @escaping (IMAPResponse, [IMAPResponse]) -> Void) {
        precondition(pendingTag == nil, "IMAPClient is single-flight: previous command hasn't completed yet")

        tagCounter += 1
        let tag = "a\(tagCounter)"
        pendingTag = tag
        pendingUntagged = []
        pendingCompletion = completion

        let messageBytes = rawMessage.utf8.count
        let full = "\(tag) APPEND \(mailbox) (\\Seen) {\(messageBytes)+}\r\n\(rawMessage)\r\n"

        print(">>> \(tag) APPEND \(mailbox) (\\Seen) {\(messageBytes)+} [message content, \(messageBytes) bytes]")
        connection.send(content: full.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error { print("Send error: \(error)") }
        })
    }

    /// Sends an ordinary command with a fresh tag. `completion` receives the
    /// final tagged response plus every untagged response seen while waiting.
    func send(_ command: String, redactLog: Bool = false, completion: @escaping (IMAPResponse, [IMAPResponse]) -> Void) {
        precondition(pendingTag == nil, "IMAPClient is single-flight: previous command hasn't completed yet")
        precondition(!isIdling, "Can't send an ordinary command while IDLE is active - call stopIdle() first")

        tagCounter += 1
        let tag = "a\(tagCounter)"
        pendingTag = tag
        pendingUntagged = []
        pendingCompletion = completion
        sendRaw(tag: tag, command: command, redactLog: redactLog)
    }

    /// Starts an IDLE session. `onUpdate` fires for every untagged push
    /// (new mail, flag changes, etc.) received while idling. `onStarted`
    /// fires once the server confirms with its "+ idling" continuation -
    /// only after this point is the server actually watching for changes.
    func startIdle(onStarted: @escaping () -> Void, onUpdate: @escaping (IMAPResponse) -> Void) {
        precondition(pendingTag == nil, "Can't start IDLE while another command is pending")
        precondition(!isIdling, "Already idling")

        tagCounter += 1
        let tag = "a\(tagCounter)"
        idleTag = tag
        onIdleUpdate = onUpdate
        onIdleStarted = onStarted
        sendRaw(tag: tag, command: "IDLE", redactLog: false)
        // isIdling becomes true once we see the "+" continuation, not before -
        // the server hasn't necessarily started watching until it confirms.
    }

    /// Ends an active IDLE session by sending DONE. `completion` receives
    /// the final tagged OK that the server sends once IDLE terminates.
    func stopIdle(completion: @escaping (IMAPResponse) -> Void) {
        guard isIdling else {
            print("stopIdle() called but not currently idling - ignoring")
            return
        }
        onIdleStopped = completion
        let line = "DONE\r\n"
        print(">>> DONE")
        connection.send(content: line.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error { print("Send error: \(error)") }
        })
    }

    /// Sends LOGOUT and gives it a moment to be delivered before the caller
    /// exits. Best-effort - doesn't wait for the server's response, since a
    /// process that's about to exit() can't usefully wait around, but this
    /// at least gives the OS a chance to flush the bytes and close the TLS
    /// connection cleanly rather than abandoning it mid-session.
    func logoutAndClose() {
        sendRaw(tag: "logout", command: "LOGOUT", redactLog: false)
        connection.cancel()
    }

    private func sendRaw(tag: String, command: String, redactLog: Bool) {
        let full = "\(tag) \(command)\r\n"
        print(">>> \(redactLog ? "\(tag) [redacted]" : full.trimmingCharacters(in: .whitespacesAndNewlines))")
        connection.send(content: full.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                print("Send error for tag \(tag): \(error)")
            } else {
                print("(tag \(tag): send completion fired OK, \(full.utf8.count) bytes)")
            }
        })
    }

    // MARK: - Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                print("Receive error: \(error)")
                self.onConnectionFailed?(error)
                return
            }
            if let data = data, !data.isEmpty {
                self.reader.feed(data)
            }
            if isComplete {
                print("Connection closed by remote.")
                return
            }
            self.receive()
        }
    }

    private func handle(line: String) {
        print("<<< \(line)")
        guard let response = IMAPResponse.parse(line) else { return }

        // Server greeting - only relevant before any command has been sent.
        if response.isUntagged, pendingTag == nil, idleTag == nil, let greet = onGreeting {
            onGreeting = nil
            greet()
            return
        }

        // "+" continuation while waiting for IDLE to be confirmed.
        if response.isContinuation, idleTag != nil, !isIdling {
            isIdling = true
            let started = onIdleStarted
            onIdleStarted = nil
            started?()
            return
        }

        // Untagged pushes while idling go to the IDLE update handler,
        // not the ordinary pendingUntagged collection.
        if response.isUntagged, isIdling {
            onIdleUpdate?(response)
            return
        }

        if response.isUntagged {
            pendingUntagged.append(response)
            return
        }

        // Tagged response matching the IDLE tag - only expected after DONE was sent.
        if response.tag == idleTag {
            isIdling = false
            idleTag = nil
            onIdleUpdate = nil
            let stopped = onIdleStopped
            onIdleStopped = nil
            stopped?(response)
            return
        }

        if response.tag == pendingTag {
            let completion = pendingCompletion
            let untagged = pendingUntagged
            pendingTag = nil
            pendingCompletion = nil
            pendingUntagged = []
            completion?(response, untagged)
            return
        }

        print("Unexpected tag: \(response.tag) (waiting for \(pendingTag ?? idleTag ?? "nothing"))")
    }
}
