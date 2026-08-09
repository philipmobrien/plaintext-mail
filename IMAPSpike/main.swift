import Foundation
import Network
import GRDB

let corpusDir = FileManager.default.temporaryDirectory.appendingPathComponent("eml-corpus")


/// Logs out cleanly before exiting, rather than abandoning the TLS
/// connection mid-session (which can leave a stale session on the server -
/// this is exactly what caused a real, hours-long hang earlier tonight).
func cleanExit(_ client: IMAPClient, code: Int32) -> Never {
    client.logoutAndClose()
    Thread.sleep(forTimeInterval: 0.3) // give LOGOUT a moment to actually send
    exit(code)
}

// MARK: - Corpus fetch (only runs if CORPUS_UIDS is set)

/// Parses "1405,1406,1410" or "1400-1410" (or a mix) into a UID list.
func parseUIDList(_ input: String) -> [Int] {
    var result: [Int] = []
    for part in input.split(separator: ",") {
        if let dash = part.firstIndex(of: "-") {
            let lo = Int(part[part.startIndex..<dash]) ?? 0
            let hi = Int(part[part.index(after: dash)...]) ?? 0
            if lo <= hi { result.append(contentsOf: lo...hi) }
        } else if let n = Int(part) {
            result.append(n)
        }
    }
    return result
}

/// Fetches raw RFC822 source for each UID in turn and saves it as a .eml
/// file. Sequential, not parallel - IMAPClient is single-flight by design.
func buildCorpus(client: IMAPClient, uids: [Int], onComplete: @escaping () -> Void) {
    try? FileManager.default.createDirectory(at: corpusDir, withIntermediateDirectories: true)
    print("\n=== Fetching \(uids.count) message(s) into corpus at \(corpusDir.path) ===")

    func fetchNext(_ remaining: [Int]) {
        guard var queue = remaining.isEmpty ? nil : remaining else {
            print("=== Corpus fetch complete ===\n")
            onComplete()
            return
        }
        let uid = queue.removeFirst()

        client.send("UID FETCH \(uid) (BODY[])") { reply, untagged in
            guard reply.key == "OK" else {
                print("FETCH BODY[] failed for uid \(uid): \(reply.text)")
                fetchNext(queue)
                return
            }
            guard let fetchResponse = untagged.first(where: { $0.isNumbered && $0.numberedKeyword == "FETCH" }) else {
                print("No FETCH data for uid \(uid) - it may not exist at that sequence number")
                fetchNext(queue)
                return
            }

            var raw = fetchResponse.text
            if let bodyRange = raw.range(of: "BODY[] ") {
                raw = String(raw[bodyRange.upperBound...])
            }
            // Strip the leftover "{NNNN}" literal-length marker.
            if raw.hasPrefix("{"), let closeBrace = raw.firstIndex(of: "}") {
                raw = String(raw[raw.index(after: closeBrace)...])
            }
            if raw.hasSuffix(")") {
                raw.removeLast()
            }

            let fileURL = corpusDir.appendingPathComponent("\(uid).eml")
            do {
                try raw.write(to: fileURL, atomically: true, encoding: .utf8)
                print("Saved uid \(uid) -> \(fileURL.lastPathComponent) (\(raw.count) chars)")
            } catch {
                print("Failed to write uid \(uid): \(error)")
            }

            fetchNext(queue)
        }
    }

    fetchNext(uids)
}

func fetchThenTest() {
    let host = "mail.runbox.com"
    let user = ProcessInfo.processInfo.environment["IMAP_USER"] ?? ""
    let password = ProcessInfo.processInfo.environment["IMAP_PASSWORD"] ?? ""
    let requestedUIDs = parseUIDList(ProcessInfo.processInfo.environment["CORPUS_UIDS"] ?? "")

    let client = IMAPClient(host: host)
    client.connect {
        client.send("LOGIN \(user) \(password)", redactLog: true) { reply, _ in
            guard reply.key == "OK" else {
                print("Login failed: \(reply.text)")
                cleanExit(client, code: 1)
            }
            client.send("SELECT INBOX") { reply, _ in
                guard reply.key == "OK" else {
                    print("SELECT failed: \(reply.text)")
                    cleanExit(client, code: 1)
                }
                buildCorpus(client: client, uids: requestedUIDs) {
                    runParserTest()
                    cleanExit(client, code: 0)
                }
            }
        }
    }
}

/// Fetches envelopes for the most recent `count` messages and saves them to
/// the database - fills out the UI's message list with real data. Doesn't
/// fetch full bodies (that's a much heavier operation) - the reading pane
/// will show "not cached" for anything not already in the .eml corpus.
func backfillEnvelopes(count: Int) {
    let host = "mail.runbox.com"
    let user = ProcessInfo.processInfo.environment["IMAP_USER"] ?? ""
    let password = ProcessInfo.processInfo.environment["IMAP_PASSWORD"] ?? ""

    let dbPath = FileManager.default.temporaryDirectory.appendingPathComponent("mail.sqlite").path
    guard let dbQueue = try? DatabaseSetup.makeDatabase(at: dbPath) else {
        print("Could not open database")
        exit(1) // no client exists yet at this point - nothing to log out of
    }

    let client = IMAPClient(host: host)
    client.connect {
        client.send("LOGIN \(user) \(password)", redactLog: true) { reply, _ in
            guard reply.key == "OK" else {
                print("Login failed: \(reply.text)")
                cleanExit(client, code: 1)
            }
            client.send("SELECT INBOX") { reply, untagged in
                guard reply.key == "OK" else {
                    print("SELECT failed: \(reply.text)")
                    cleanExit(client, code: 1)
                }
                let messageCount = untagged
                    .first { $0.isNumbered && $0.numberedKeyword == "EXISTS" }
                    .flatMap { Int($0.key) } ?? count
                var start = max(1, messageCount - count + 1)
                var end = messageCount

                // Diagnostic override: BACKFILL_RANGE="1420:1420" lets us test
                // a specific, previously-proven-good UID instead of always the
                // newest message - helps isolate whether the hang is UID-specific.
                if let rangeOverride = ProcessInfo.processInfo.environment["BACKFILL_RANGE"] {
                    let parts = rangeOverride.split(separator: ":")
                    if parts.count == 2, let s = Int(parts[0]), let e = Int(parts[1]) {
                        start = s
                        end = e
                    }
                }

                print("Fetching envelopes \(start):\(end) (\(end - start + 1) messages)...")

                let spamHeaderFields = "BODY.PEEK[HEADER.FIELDS (X-Spam-Flag X-Spam-Status X-Spam-Score X-Spam-Level)]"
                client.send("FETCH \(start):\(end) (UID FLAGS ENVELOPE \(spamHeaderFields))") { reply, untagged in
                    guard reply.key == "OK" else {
                        print("FETCH failed: \(reply.text)")
                        cleanExit(client, code: 1)
                    }

                    var saved = 0, skipped = 0, failed = 0
                    for response in untagged where response.isNumbered && response.numberedKeyword == "FETCH" {
                        // IMPORTANT: response.key here is the message's SEQUENCE
                        // NUMBER (its position), not its UID - those are different
                        // things that happen to look similar in casual testing but
                        // diverge the moment anything's expunged. Always extract the
                        // real UID from the response's own "UID nnnn" data item.
                        guard let uid = response.fetchUID(),
                              let envelopeRange = response.text.range(of: "ENVELOPE ") else { continue }
                        let afterEnvelope = response.text[envelopeRange.upperBound...]
                        guard let parsed = EnvelopeParser.parse(String(afterEnvelope)) else {
                            failed += 1
                            continue
                        }
                        let message = Message(
                            mailbox: "INBOX",
                            uid: uid,
                            subject: parsed.subject,
                            from: parsed.fromAddress ?? "(unknown)",
                            toAlias: parsed.toAddress ?? "(unknown)",
                            date: parsed.date ?? Date(),
                            isSeen: response.fetchFlags().contains("\\Seen"),
                            isFlaggedSpam: response.extractSpamSignal().isFlagged,
                            spamScore: response.extractSpamSignal().score
                        )
                        do {
                            try dbQueue.write { db in try message.insert(db) }
                            saved += 1
                        } catch {
                            skipped += 1
                            // Only genuinely expected error is a duplicate uid (primary
                            // key violation) - print anything else so a real problem
                            // isn't silently miscounted as "already present".
                            let errorText = "\(error)"
                            if !errorText.contains("UNIQUE constraint failed") {
                                print("Insert failed for uid \(uid) (not a duplicate): \(error)")
                            }
                        }
                    }
                    print("Backfill complete: \(saved) saved, \(skipped) already present, \(failed) failed to parse.")
                    cleanExit(client, code: 0)
                }
            }
        }
    }
}

// MARK: - Parser test (always runs, against whatever is in the corpus dir)

func printTree(_ part: MIMEPart, indent: String = "") {
    if part.isMultipart {
        print("\(indent)\(part.contentType) [\(part.subParts.count) parts]")
        for sub in part.subParts {
            printTree(sub, indent: indent + "  ")
        }
    } else {
        let charset = part.parameters["charset"] ?? "?"
        print("\(indent)\(part.contentType) (charset: \(charset), encoding: \(part.transferEncoding)) - \(part.rawBody.count) raw chars")
    }
}

func findPlainText(_ part: MIMEPart) -> String? {
    if part.contentType == "text/plain" { return part.decodedText }
    for sub in part.subParts { if let found = findPlainText(sub) { return found } }
    return nil
}

func findHTMLConvertedToText(_ part: MIMEPart) -> String? {
    if part.contentType == "text/html" { return HTMLToText.convert(part.decodedText) }
    for sub in part.subParts { if let found = findHTMLConvertedToText(sub) { return found } }
    return nil
}

func runParserTest() {
    guard let files = try? FileManager.default.contentsOfDirectory(at: corpusDir, includingPropertiesForKeys: nil) else {
        print("No corpus found at \(corpusDir.path)")
        return
    }
    let emlFiles = files.filter { $0.pathExtension == "eml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    print("Found \(emlFiles.count) .eml files in corpus\n")

    for fileURL in emlFiles {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            print("Could not read \(fileURL.lastPathComponent) as UTF-8")
            continue
        }
        let message = MIMEParser.parse(raw)
        print("=== \(fileURL.lastPathComponent) ===")
        print("From: \(message.header("From") ?? "?")")
        print("Subject: \(message.header("Subject") ?? "?")")
        print("Structure:")
        printTree(message, indent: "  ")

        if let plainText = findPlainText(message) {
            print("Plain text preview: \(plainText.prefix(200).replacingOccurrences(of: "\n", with: " "))...")
        } else if let converted = findHTMLConvertedToText(message) {
            print("(converted from HTML) preview: \(converted.prefix(200).replacingOccurrences(of: "\n", with: " "))...")
        } else {
            print("No text/plain or text/html part found")
        }
        print("")
    }
}

// MARK: - SMTP spike, session 1: TLS connect + greeting + EHLO

// MARK: - SMTP spike, session 3: send a real message

/// Escapes dot-stuffing per RFC 5321: any line that starts with "." must
/// have that dot doubled, or the SMTP server will read it as the
/// end-of-message marker and silently truncate everything after it.
func dotStuff(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix(".") ? "." + $0 : String($0) }
        .joined(separator: "\n")
}

/// Sends QUIT, then force-exits shortly after regardless of whether a
/// response arrives - Runbox's server doesn't reliably send one back.
func quitAndExit(_ client: SMTPClient, code: Int32) {
    client.send("QUIT") { _ in exit(code) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(code) }
}

func sendTestMessage(client: SMTPClient, from: String, to: String, completion: @escaping (Bool) -> Void) {
    client.send("MAIL FROM:<\(from)>") { response in
        guard response.isSuccess else {
            print("MAIL FROM rejected: \(response.code) \(response.lines.first ?? "")")
            completion(false)
            return
        }
        client.send("RCPT TO:<\(to)>") { response in
            guard response.isSuccess else {
                print("RCPT TO rejected: \(response.code) \(response.lines.first ?? "")")
                completion(false)
                return
            }
            client.send("DATA") { response in
                guard response.code == "354" else {
                    print("DATA rejected: \(response.code) \(response.lines.first ?? "")")
                    completion(false)
                    return
                }

                let messageId = "<\(UUID().uuidString)@spike.local>"
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
                let dateHeader = dateFormatter.string(from: Date())

                let body = "This is a test message sent by the SMTP spike, session 3.\n\nIf you're reading this, MAIL FROM / RCPT TO / DATA all worked correctly."

                let message = """
                From: \(from)
                To: \(to)
                Subject: SMTP spike test message
                Date: \(dateHeader)
                Message-ID: \(messageId)
                MIME-Version: 1.0
                Content-Type: text/plain; charset=utf-8; markup=markdown

                \(dotStuff(body))
                """

                // Message ends with CRLF, a lone ".", then CRLF - the DATA terminator.
                let fullData = message.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n.\r\n"
                print(">>> [DATA content, \(fullData.utf8.count) bytes]")
                client.sendRawData(fullData) { response in
                    guard response.isSuccess else {
                        print("Message rejected after DATA: \(response.code) \(response.lines.first ?? "")")
                        completion(false)
                        return
                    }
                    print("Server accepted: \(response.code) \(response.lines.first ?? "")")
                    completion(true)
                }
            }
        }
    }
}

func testSMTPConnection() {
    let host = "mail.runbox.com"
    let user = ProcessInfo.processInfo.environment["IMAP_USER"] ?? ""
    let password = ProcessInfo.processInfo.environment["IMAP_PASSWORD"] ?? ""
    let client = SMTPClient(host: host)

    client.connect {
        print("\n=== Greeting received, sending EHLO ===\n")
        client.send("EHLO localhost") { response in
            print("\n=== EHLO response: code \(response.code), \(response.lines.count) lines ===")
            for line in response.lines {
                print("  capability: \(line)")
            }

            // AUTH PLAIN: base64("\0username\0password") sent as one line.
            // The leading empty field is the authorization identity (authzid),
            // conventionally left blank when it's the same as the username.
            let authString = "\0\(user)\0\(password)"
            let authBase64 = Data(authString.utf8).base64EncodedString()

            print("\n=== Sending AUTH PLAIN (credentials redacted) ===\n")
            client.send("AUTH PLAIN \(authBase64)", redactedLog: "AUTH PLAIN [redacted]") { response in
                print("\n=== AUTH response: \(response.code) \(response.lines.first ?? "") ===")
                guard response.isSuccess else {
                    print("Authentication FAILED.")
                    quitAndExit(client, code: 1)
                    return
                }
                print("Authenticated successfully.")

                let testAddress = ProcessInfo.processInfo.environment["SMTP_TEST_TO"] ?? user

                sendTestMessage(client: client, from: user, to: testAddress) { success in
                    print(success ? "\n=== Test message sent successfully ===" : "\n=== Test message FAILED to send ===")
                    quitAndExit(client, code: success ? 0 : 1)
                }
            }
        }
    }
}

// MARK: - Mailbox discovery (only runs if LIST_TEST is set)

func testListMailboxes() {
    let host = "mail.runbox.com"
    let user = ProcessInfo.processInfo.environment["IMAP_USER"] ?? ""
    let password = ProcessInfo.processInfo.environment["IMAP_PASSWORD"] ?? ""

    let client = IMAPClient(host: host)
    client.connect {
        client.send("LOGIN \(user) \(password)", redactLog: true) { reply, _ in
            guard reply.key == "OK" else {
                print("Login failed: \(reply.text)")
                exit(1)
            }
            // RETURN (SPECIAL-USE) asks the server to tag folders with their
            // special-use attribute (\Sent, \Drafts, \Trash etc) if it knows
            // them - Runbox's CAPABILITY response included SPECIAL-USE, so
            // this should give us an authoritative answer rather than a guess.
            client.send("LIST \"\" \"*\" RETURN (SPECIAL-USE)") { reply, untagged in
                print("\n=== Mailbox list ===")
                for response in untagged {
                    print(response.text)
                }
                print("\n=== LIST reply: \(reply.key) \(reply.text) ===")
                exit(0)
            }
        }
    }
}

// MARK: - Entry point

if ProcessInfo.processInfo.environment["LIST_TEST"] != nil {
    testListMailboxes()
    RunLoop.main.run()
} else if ProcessInfo.processInfo.environment["SMTP_TEST"] != nil {
    testSMTPConnection()
    RunLoop.main.run()
} else if let backfillEnv = ProcessInfo.processInfo.environment["BACKFILL_COUNT"], let count = Int(backfillEnv) {
    backfillEnvelopes(count: count)
    RunLoop.main.run()
} else if let corpusUIDsEnv = ProcessInfo.processInfo.environment["CORPUS_UIDS"], !corpusUIDsEnv.isEmpty {
    fetchThenTest()
    RunLoop.main.run()
} else {
    runParserTest()
}
