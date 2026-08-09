import Foundation
import Network

/// Minimal SMTP client, built the same way the IMAP spike was: prove the
/// protocol handshake works before layering anything else on top.
///
/// SMTP is simpler than IMAP in one useful way - no tags, no literals.
/// Every response is either a single line "250 OK" or a multi-line block
/// where all but the last line use a dash after the code ("250-FIRST",
/// "250-SECOND", "250 LAST"). No byte-counted literals to worry about,
/// so a plain CRLF line reader is enough here - LiteralAwareReader's
/// complexity genuinely isn't needed for this protocol.
final class SMTPClient {
    private let connection: NWConnection
    private var buffer = Data()
    private var onGreeting: (() -> Void)?
    private var pendingCompletion: ((SMTPResponse) -> Void)?
    private var pendingCode: String?

    struct SMTPResponse {
        let code: String        // e.g. "250"
        let lines: [String]     // all lines' text, greeting/EHLO responses can be multi-line
        var isSuccess: Bool { code.hasPrefix("2") || code.hasPrefix("3") }
    }

    init(host: String, port: NWEndpoint.Port = 465) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tls)
    }

    func connect(onGreeting: @escaping () -> Void) {
        self.onGreeting = onGreeting
        connection.stateUpdateHandler = { [weak self] state in
            print("State: \(state)")
            if case .ready = state {
                self?.receive()
            }
        }
        connection.start(queue: .main)
    }

    /// Sends raw content as-is (no extra CRLF appended) and waits for the
    /// response - used for the DATA block, whose content already ends with
    /// its own "\r\n.\r\n" terminator, unlike ordinary commands.
    func sendRawData(_ content: String, completion: @escaping (SMTPResponse) -> Void) {
        pendingCompletion = completion
        pendingCode = nil
        connection.send(content: content.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error { print("Send error: \(error)") }
        })
    }

    /// Sends one command and waits for its response (single or multi-line).
    /// `redactedLog`, if given, is printed instead of the real command -
    /// use for AUTH commands, which carry base64-encoded credentials.
    func send(_ command: String, redactedLog: String? = nil, completion: @escaping (SMTPResponse) -> Void) {
        pendingCompletion = completion
        pendingCode = nil
        let full = "\(command)\r\n"
        print(">>> \(redactedLog ?? command)")
        connection.send(content: full.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error { print("Send error: \(error)") }
        })
    }

    // MARK: - Receiving

    private var collectedLines: [String] = []

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                print("Receive error: \(error)")
                return
            }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drainLines()
            }
            if isComplete {
                print("Connection closed by remote.")
                return
            }
            self.receive()
        }
    }

    private func drainLines() {
        while let range = buffer.range(of: Data([0x0D, 0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8) {
                handle(line: line)
            }
        }
    }

    private func handle(line: String) {
        print("<<< \(line)")
        // SMTP response line shape: "250-text" (more lines follow) or "250 text" (last line).
        guard line.count >= 4 else { return }
        let code = String(line.prefix(3))
        let separator = line[line.index(line.startIndex, offsetBy: 3)]
        let text = String(line.dropFirst(4))

        collectedLines.append(text)

        if separator == " " {
            // Last line of this response.
            let response = SMTPResponse(code: code, lines: collectedLines)
            collectedLines = []

            if pendingCompletion == nil, onGreeting != nil {
                // Unprompted greeting on connect - not a reply to any command we sent.
                let greet = onGreeting
                onGreeting = nil
                greet?()
                return
            }

            let completion = pendingCompletion
            pendingCompletion = nil
            completion?(response)
        }
        // else: separator == "-", more lines coming, keep collecting.
    }
}
