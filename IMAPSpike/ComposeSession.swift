import Foundation
import Network
import Combine
import GRDB
import UniformTypeIdentifiers

/// A file attached to an outgoing message. Reads the file's bytes eagerly
/// at pick-time (drag-drop or file picker) rather than keeping just a URL
/// around, since the source file could move/disappear before Send is
/// actually pressed.
struct ComposeAttachment: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
    let mimeType: String

    init(url: URL) throws {
        self.filename = url.lastPathComponent
        self.data = try Data(contentsOf: url)
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            self.mimeType = mime
        } else {
            self.mimeType = "application/octet-stream"
        }
    }
}

/// Manages one SMTP connection per send, then separately appends a copy of
/// the sent message to the Sent mailbox via IMAP - sending and saving are
/// two entirely different protocols and connections; SMTP never keeps a
/// copy of anything you send, that's the client's job.
@MainActor
final class ComposeSession: ObservableObject {
    @Published var isSending = false
    @Published var lastError: String?

    enum SendError: Error, LocalizedError {
        case authFailed(String)
        case rejected(String)
        var errorDescription: String? {
            switch self {
            case .authFailed(let text): return "Authentication failed: \(text)"
            case .rejected(let text): return "Server rejected the message: \(text)"
            }
        }
    }

    func send(
        accountID: UUID,
        imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int, user: String, password: String,
        sentFolder: String,
        from: String, to: String, cc: String, subject: String, markdownBody: String,
        attachments: [ComposeAttachment] = [],
        prebuiltRawMessage: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        isSending = true
        lastError = nil

        let toRecipients = extractEmailAddresses(to)
        let ccRecipients = extractEmailAddresses(cc)
        let allRecipients = toRecipients + ccRecipients

        // Composed once - the exact same bytes go out over SMTP and, on
        // success, get archived via IMAP APPEND. If a pre-built raw message
        // is supplied (Redirect - the original message untouched, with
        // Resent-* headers layered on top), that's used verbatim instead of
        // building a fresh message from the compose fields.
        let rawMessage = prebuiltRawMessage ?? MessageComposer.compose(from: from, to: to, cc: cc, subject: subject, markdownBody: markdownBody, attachments: attachments)

        let smtpPortValue = NWEndpoint.Port(rawValue: UInt16(smtpPort)) ?? 465
        let client = SMTPClient(host: smtpHost, port: smtpPortValue)
        client.connect {
            client.send("EHLO localhost") { _ in
                let authString = "\0\(user)\0\(password)"
                let authBase64 = Data(authString.utf8).base64EncodedString()

                client.send("AUTH PLAIN \(authBase64)", redactedLog: "AUTH PLAIN [redacted]") { response in
                    guard response.isSuccess else {
                        Task { @MainActor in
                            self.finishSMTP(client, .failure(SendError.authFailed(response.lines.first ?? response.code)), completion)
                        }
                        return
                    }

                    self.sendComposedMessage(client: client, from: from, recipients: allRecipients, rawMessage: rawMessage) { result in
                        Task { @MainActor in
                            self.finishSMTP(client, result, completion)

                            if case .success = result {
                                self.appendToSent(accountID: accountID, host: imapHost, port: imapPort, user: user, password: password, sentFolder: sentFolder, rawMessage: rawMessage)
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishSMTP(_ client: SMTPClient, _ result: Result<Void, Error>, _ completion: @escaping (Result<Void, Error>) -> Void) {
        client.send("QUIT") { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { }

        isSending = false
        if case .failure(let error) = result {
            lastError = error.localizedDescription
        }
        completion(result)
    }

    /// Sends MAIL FROM once, then one RCPT TO per recipient (To and Cc
    /// alike - the Cc: header is purely cosmetic display, SMTP delivery
    /// needs an explicit RCPT TO for every actual recipient regardless of
    /// which header they're listed under), then the message body.
    private func sendComposedMessage(
        client: SMTPClient, from: String, recipients: [String], rawMessage: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !recipients.isEmpty else {
            completion(.failure(SendError.rejected("No recipients")))
            return
        }

        client.send("MAIL FROM:<\(from)>") { response in
            guard response.isSuccess else {
                completion(.failure(SendError.rejected(response.lines.first ?? response.code)))
                return
            }

            func sendNextRecipient(_ remaining: [String]) {
                guard var queue = remaining.isEmpty ? nil : remaining else {
                    // All recipients accepted - proceed to DATA.
                    client.send("DATA") { response in
                        guard response.code == "354" else {
                            completion(.failure(SendError.rejected(response.lines.first ?? response.code)))
                            return
                        }
                        let fullData = rawMessage.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n.\r\n"
                        client.sendRawData(fullData) { response in
                            guard response.isSuccess else {
                                completion(.failure(SendError.rejected(response.lines.first ?? response.code)))
                                return
                            }
                            completion(.success(()))
                        }
                    }
                    return
                }
                let recipient = queue.removeFirst()
                client.send("RCPT TO:<\(recipient)>") { response in
                    guard response.isSuccess else {
                        completion(.failure(SendError.rejected("Recipient \(recipient) rejected: \(response.lines.first ?? response.code)")))
                        return
                    }
                    sendNextRecipient(queue)
                }
            }
            sendNextRecipient(recipients)
        }
    }

    /// Best-effort: saves a copy to Sent via a fresh, short-lived IMAP
    /// connection. Failure here doesn't affect the already-successful send -
    /// the message went out either way - so this only logs, never surfaces
    /// as a user-facing error.
    private func appendToSent(accountID: UUID, host: String, port: Int, user: String, password: String, sentFolder: String, rawMessage: String) {
        let portValue = NWEndpoint.Port(rawValue: UInt16(port)) ?? 993
        let client = IMAPClient(host: host, port: portValue)
        client.connect {
            client.send("LOGIN \(user) \(password)", redactLog: true) { reply, _ in
                guard reply.key == "OK" else {
                    print("Save-to-Sent: login failed: \(reply.text)")
                    return
                }
                client.sendAppend(mailbox: sentFolder, rawMessage: rawMessage) { reply, _ in
                    guard reply.key == "OK" else {
                        print("Save-to-Sent: APPEND failed: \(reply.text)")
                        return
                    }
                    print("Save-to-Sent: appended successfully (\(reply.text))")

                    Task { @MainActor in
                        if let uid = reply.appendUID() {
                            self.insertSentMessageLocally(accountID: accountID, uid: uid, mailbox: sentFolder, rawMessage: rawMessage)
                        }
                    }
                }
            }
        }
    }

    private func insertSentMessageLocally(accountID: UUID, uid: Int, mailbox: String, rawMessage: String) {
        guard let dbQueue = try? DatabaseSetup.makeDatabase(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("mail-\(accountID.uuidString).sqlite").path
        ) else { return }

        let parsed = MIMEParser.parse(rawMessage)
        let subject = parsed.header("Subject") ?? "(no subject)"
        let from = parsed.header("From") ?? ""
        let to = parsed.header("To") ?? "(unknown)"

        let message = Message(
            mailbox: mailbox,
            uid: uid,
            subject: subject,
            from: from,
            toAlias: to,
            date: Date(),
            isSeen: true
        )
        _ = try? dbQueue.write { db in try message.insert(db) }

        let corpusDir = FileManager.default.temporaryDirectory.appendingPathComponent("eml-corpus-\(accountID.uuidString)")
        try? FileManager.default.createDirectory(at: corpusDir, withIntermediateDirectories: true)
        try? rawMessage.write(to: corpusDir.appendingPathComponent("\(mailbox)-\(uid).eml"), atomically: true, encoding: .utf8)
    }
}

/// Builds a Redirect - distinct from Forward, this preserves the original
/// message completely untouched (headers and body both), and layers new
/// Resent-* headers (RFC 5322 §3.6.6) on top. The recipient's client shows
/// it as coming from the original sender, with the Resent-* headers noting
/// who redirected it and when - the correct, standards-based mechanism for
/// this, not a hack built on top of the ordinary Forward flow.
enum RedirectComposer {
    static func buildRedirect(originalRaw: String, from: String, to: String) -> String {
        let messageId = "<\(UUID().uuidString)@personal-mail-client>"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let dateHeader = dateFormatter.string(from: Date())

        let resentHeaders = """
        Resent-From: \(from)
        Resent-To: \(to)
        Resent-Date: \(dateHeader)
        Resent-Message-ID: \(messageId)
        """

        return resentHeaders + "\n" + originalRaw
    }
}

/// Builds the raw RFC 822 source for an outgoing message: markdown as the
/// text/plain part (tagged markup=markdown, matching MailMate's own
/// convention we spotted in earlier sent messages). With attachments,
/// wraps everything in multipart/mixed: the markdown body as one part,
/// each attachment base64-encoded as its own part with correct
/// Content-Type/Content-Disposition/filename headers.
enum MessageComposer {
    static func compose(
        from: String, to: String, cc: String, subject: String, markdownBody: String,
        attachments: [ComposeAttachment] = []
    ) -> String {
        let messageId = "<\(UUID().uuidString)@personal-mail-client>"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let dateHeader = dateFormatter.string(from: Date())
        let ccLine = cc.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "Cc: \(cc)\n"

        let headers = """
        From: \(from)
        To: \(to)
        \(ccLine)Subject: \(subject)
        Date: \(dateHeader)
        Message-ID: \(messageId)
        MIME-Version: 1.0
        """

        guard !attachments.isEmpty else {
            let stuffedBody = dotStuffForCompose(markdownBody)
            return """
            \(headers)
            Content-Type: text/plain; charset=utf-8; markup=markdown

            \(stuffedBody)
            """
        }

        let boundary = "----ComposeBoundary-\(UUID().uuidString)"
        var parts: [String] = []

        parts.append("""
        --\(boundary)
        Content-Type: text/plain; charset=utf-8; markup=markdown

        \(dotStuffForCompose(markdownBody))
        """)

        for attachment in attachments {
            // Standard MIME line length (76 chars) for base64 content -
            // avoids overly long lines that some relays mishandle.
            let base64 = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            parts.append("""
            --\(boundary)
            Content-Type: \(attachment.mimeType); name="\(attachment.filename)"
            Content-Disposition: attachment; filename="\(attachment.filename)"
            Content-Transfer-Encoding: base64

            \(base64)
            """)
        }

        let bodySection = parts.joined(separator: "\n") + "\n--\(boundary)--"

        return """
        \(headers)
        Content-Type: multipart/mixed; boundary="\(boundary)"

        \(bodySection)
        """
    }

    private static func dotStuffForCompose(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(".") ? "." + $0 : String($0) }
            .joined(separator: "\n")
    }
}
