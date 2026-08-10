import Foundation
import Network
import Combine
import GRDB

/// Manages one persistent IMAP connection for the app's lifetime: serializes
/// body-fetch requests, recovers from dropped connections, and owns the
/// message list + local database across multiple mailboxes (INBOX, Sent,
/// ...) - including per-mailbox deletion reconciliation and automatic
/// backfill of any envelopes the server has that aren't cached locally yet.
///
/// One MailSession per configured account (see AccountSessionManager) -
/// each gets its own separate database file and .eml cache folder, keyed
/// by accountID, so a query never needs to filter by account to stay
/// correct: a session only ever sees its own account's data by
/// construction.
@MainActor
final class MailSession: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var lastError: String?
    @Published var messages: [Message] = []
    @Published var isSyncing = false
    @Published var currentMailbox: String = "INBOX"
    @Published var discoveredFolders: [String: String] = [:]   // role -> real folder name, e.g. "sent" -> "Sent"
    @Published var allDiscoveredFolders: [DiscoveredFolder] = []
    @Published var isManuallyOffline = false

    let accountID: UUID

    init(accountID: UUID) {
        self.accountID = accountID
    }

    private var databasePath: String {
        FileManager.default.temporaryDirectory.appendingPathComponent("mail-\(accountID.uuidString).sqlite").path
    }

    private var corpusDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("eml-corpus-\(accountID.uuidString)")
    }

    enum ConnectionState {
        case disconnected, connecting, ready
    }

    private var client: IMAPClient?
    private var dbQueue: DatabaseQueue?

    private var host: String?
    private var port: Int = 993
    private var user: String?
    private var password: String?

    // What's actually SELECTed server-side right now - may lag currentMailbox
    // briefly while a switch is in flight.
    private var selectedOnServer: String?

    private var queue: [(uid: Int, mailbox: String, completion: (Result<String, Error>) -> Void)] = []
    private var pendingMailboxSelection: String?
    private var isProcessingQueue = false

    enum SessionError: Error, LocalizedError {
        case notReady
        case loginFailed(String)
        case selectFailed(String)
        case fetchFailed(String)
        case connectionLost
        case noData

        var errorDescription: String? {
            switch self {
            case .notReady: return "Not connected to the server yet."
            case .loginFailed(let text): return "Login failed: \(text)"
            case .selectFailed(let text): return "Could not open mailbox: \(text)"
            case .fetchFailed(let text): return "Fetch failed: \(text)"
            case .connectionLost: return "Connection to the server was lost. Retrying…"
            case .noData: return "No data returned for this message."
            }
        }
    }

    @Published var smartFolders: [SmartFolder] = []

    /// Loads saved smart folders - purely local, no connection needed, so
    /// this can (and should) run immediately at launch regardless of
    /// whether IMAP has connected yet.
    func loadSmartFolders() {
        guard let dbQueue = try? database() else { return }
        smartFolders = (try? dbQueue.read { db in try SmartFolder.fetchAll(db) }) ?? []
    }

    func createSmartFolder(name: String, mailboxes: [String], matchType: String, conditions: [SmartFolderCondition]) {
        guard let dbQueue = try? database(), !name.isEmpty, !mailboxes.isEmpty, !conditions.isEmpty else { return }
        let folder = SmartFolder(
            id: nil,
            name: name,
            mailboxesCSV: mailboxes.joined(separator: ","),
            matchType: matchType,
            conditionsJSON: SmartFolder.encodeConditions(conditions)
        )
        _ = try? dbQueue.write { db in try folder.insert(db) }
        loadSmartFolders()
    }

    func updateSmartFolder(id: Int64, name: String, mailboxes: [String], matchType: String, conditions: [SmartFolderCondition]) {
        guard let dbQueue = try? database(), !name.isEmpty, !mailboxes.isEmpty, !conditions.isEmpty else { return }
        let folder = SmartFolder(
            id: id,
            name: name,
            mailboxesCSV: mailboxes.joined(separator: ","),
            matchType: matchType,
            conditionsJSON: SmartFolder.encodeConditions(conditions)
        )
        _ = try? dbQueue.write { db in try folder.update(db) }
        loadSmartFolders()
    }

    func deleteSmartFolder(_ folder: SmartFolder) {
        guard let dbQueue = try? database(), let id = folder.id else { return }
        _ = try? dbQueue.write { db in try SmartFolder.deleteOne(db, key: id) }
        loadSmartFolders()
    }

    /// Queries the local cache across every mailbox this smart folder
    /// watches, combining its conditions with Any (OR) or All (AND).
    /// Built as raw SQL rather than GRDB's query builder because dynamic
    /// case-insensitive contains/does-not-contain combinations across a
    /// variable number of conditions doesn't map cleanly onto the builder
    /// DSL. Case-insensitivity is via LOWER() on both sides rather than
    /// relying on SQLite's default LIKE behaviour, which is only
    /// case-insensitive for plain ASCII.
    func messagesForSmartFolder(_ folder: SmartFolder) -> [Message] {
        guard let dbQueue = try? database() else { return [] }
        let mailboxes = folder.mailboxList
        let conditions = folder.conditions.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !mailboxes.isEmpty else { return [] }

        var whereClauses: [String] = []
        var arguments: [DatabaseValueConvertible] = []

        let mailboxPlaceholders = mailboxes.map { _ in "?" }.joined(separator: ",")
        whereClauses.append("mailbox IN (\(mailboxPlaceholders))")
        arguments.append(contentsOf: mailboxes)

        if !conditions.isEmpty {
            var condFragments: [String] = []
            for condition in conditions {
                let column: String
                switch condition.field {
                case .from: column = "\"from\""
                case .to: column = "toAlias"
                case .subject: column = "subject"
                }
                let op = condition.op == .doesNotContain ? "NOT LIKE" : "LIKE"
                condFragments.append("LOWER(\(column)) \(op) LOWER(?)")
                arguments.append("%\(condition.value)%")
            }
            let joiner = folder.matchType == "all" ? " AND " : " OR "
            whereClauses.append("(\(condFragments.joined(separator: joiner)))")
        }

        let sql = "SELECT * FROM message WHERE \(whereClauses.joined(separator: " AND ")) ORDER BY date DESC"

        return (try? dbQueue.read { db in
            try Message.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }) ?? []
    }

    /// Local query across specific mailboxes with no conditions - what
    /// "All Messages" is: essentially a fixed, non-editable smart folder.
    func messagesForMailboxes(_ mailboxes: [String]) -> [Message] {
        guard let dbQueue = try? database() else { return [] }
        return (try? dbQueue.read { db in
            try Message.filter(mailboxes.contains(Column("mailbox")))
                .order(Column("date").desc)
                .fetchAll(db)
        }) ?? []
    }

    /// Syncs several mailboxes in turn, so a view spanning them (like "All
    /// Messages") is reasonably complete rather than only showing whatever
    /// happened to be cached from mailboxes visited individually before.
    func syncMultipleMailboxes(_ mailboxes: [String], completion: @escaping () -> Void) {
        guard connectionState == .ready, !isProcessingQueue, !isSelectingMailbox else {
            completion()
            return
        }
        isProcessingQueue = true

        @MainActor func syncNext(_ remaining: [String]) {
            guard var queue = remaining.isEmpty ? nil : remaining else {
                self.isProcessingQueue = false
                self.processQueueIfNeeded()
                completion()
                return
            }
            let mailbox = queue.removeFirst()
            ensureSelected(mailbox) { [weak self] selected in
                guard selected, let self else { syncNext(queue); return }
                self.syncMailboxContents(mailbox) {
                    syncNext(queue)
                }
            }
        }
        syncNext(mailboxes)
    }

    private func database() throws -> DatabaseQueue {
        if let dbQueue { return dbQueue }
        let dbPath = databasePath
        let queue = try DatabaseSetup.makeDatabase(at: dbPath)
        dbQueue = queue
        return queue
    }

    /// Connects and logs in, then selects `initialMailbox` (INBOX by
    /// default - the app-launch case; auto-reconnect after a dropped
    /// connection passes whatever mailbox was actually being viewed, so a
    /// reconnect doesn't silently dump you back to Inbox).
    func connect(host: String, port: Int = 993, user: String, password: String, initialMailbox: String = "INBOX") {
        self.host = host
        self.port = port
        self.user = user
        self.password = password

        guard connectionState != .connecting else { return }
        connectionState = .connecting

        let portValue = NWEndpoint.Port(rawValue: UInt16(port)) ?? 993
        let client = IMAPClient(host: host, port: portValue)
        self.client = client

        client.onConnectionFailed = { [weak self] error in
            Task { @MainActor in
                self?.handleConnectionFailure(error)
            }
        }

        client.connect { [weak self] in
            client.send("LOGIN \(user) \(password)", redactLog: true) { reply, _ in
                guard reply.key == "OK" else {
                    Task { @MainActor in
                        self?.lastError = SessionError.loginFailed(reply.text).localizedDescription
                        self?.connectionState = .disconnected
                    }
                    return
                }
                Task { @MainActor in
                    self?.connectionState = .ready
                    self?.discoverFolders {
                        self?.selectMailbox(initialMailbox, isAutomaticDefault: true)
                    }
                }
            }
        }
    }

    @Published var searchResults: [Message]? // nil = not searching, [] = no matches
    @Published var isSearching = false

    /// Searches the current mailbox server-side via IMAP SEARCH (matching
    /// Subject or From) - not just what's cached locally, since the server
    /// can search messages we've never fetched envelopes for. Any matching
    /// UID we don't have locally yet gets its envelope fetched before
    /// results are shown, reusing the same fetchMissingEnvelopes used for
    /// normal mailbox sync.
    private var allSearchableMailboxes: [String] {
        var result = ["INBOX"]
        for role in ["archive", "sent", "junk", "trash"] {
            if let name = discoveredFolders[role] { result.append(name) }
        }
        return result
    }

    /// Searches every real mailbox in turn (not just whichever one happens
    /// to be selected) and merges the results. Matches how people actually
    /// think about search - "find this message" shouldn't require already
    /// knowing which folder it's in. Restores whatever mailbox was actually
    /// being viewed once the sweep finishes, so search doesn't silently
    /// switch what's on screen.
    func search(query: String, completion: @escaping () -> Void = {}) {
        guard connectionState == .ready, let client, !isProcessingQueue, !isSelectingMailbox else {
            completion()
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = nil
            completion()
            return
        }

        let originalMailbox = currentMailbox
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        isSearching = true
        isProcessingQueue = true

        var aggregated: [Message] = []

        @MainActor func searchMailbox(_ remaining: [String]) {
            guard var queue = remaining.isEmpty ? nil : remaining else {
                aggregated.sort { $0.date > $1.date }
                self.searchResults = aggregated
                self.isSearching = false
                // Restore whatever mailbox was actually being viewed before
                // this sweep started, then let anything queued behind the
                // search proceed.
                self.ensureSelected(originalMailbox) { [weak self] _ in
                    self?.currentMailbox = originalMailbox
                    self?.isProcessingQueue = false
                    self?.processQueueIfNeeded()
                    completion()
                }
                return
            }
            let mailbox = queue.removeFirst()

            ensureSelected(mailbox) { [weak self] selected in
                guard selected, let self else { searchMailbox(queue); return }

                client.send("UID SEARCH OR SUBJECT \"\(escaped)\" FROM \"\(escaped)\"") { reply, untagged in
                    Task { @MainActor in
                        guard reply.key == "OK",
                              let searchResponse = untagged.first(where: { $0.key == "SEARCH" }) else {
                            searchMailbox(queue)
                            return
                        }

                        let resultUIDs = searchResponse.text.split(separator: " ").compactMap { Int($0) }
                        guard !resultUIDs.isEmpty else { searchMailbox(queue); return }

                        let localUIDs = (try? self.database().read { db in
                            Set(try Int.fetchAll(db, sql: "SELECT uid FROM message WHERE mailbox = ?", arguments: [mailbox]))
                        }) ?? []
                        let missing = Set(resultUIDs).subtracting(localUIDs)

                        @MainActor func collect() {
                            let results = (try? self.database().read { db in
                                try Message.filter(Column("mailbox") == mailbox && resultUIDs.contains(Column("uid"))).fetchAll(db)
                            }) ?? []
                            aggregated.append(contentsOf: results)
                            searchMailbox(queue)
                        }

                        if !missing.isEmpty {
                            self.fetchMissingEnvelopes(Array(missing), mailbox: mailbox, client: client) {
                                collect()
                            }
                        } else {
                            collect()
                        }
                    }
                }
            }
        }

        searchMailbox(allSearchableMailboxes)
    }

    func clearSearch() {
        searchResults = nil
    }

    private var isSelectingMailbox = false

    /// Switches to a different mailbox: SELECTs it server-side (if not
    /// already selected), checks UIDVALIDITY, reconciles deletions, fetches
    /// any envelopes the server has that aren't cached locally yet, then
    /// loads the message list for that mailbox.
    func selectMailbox(_ mailbox: String, isAutomaticDefault: Bool = false) {
        guard connectionState == .ready, let client else { return }
        guard !isSelectingMailbox, !isProcessingQueue else {
            // An automatic default selection (connect()'s own initial
            // "open INBOX" call) must never overwrite a genuine, more
            // recent user-requested selection that's already queued here -
            // that exact collision was silently swapping a user's clicked
            // mailbox back to INBOX whenever the two happened to race.
            // A non-automatic request always queues normally regardless.
            if isAutomaticDefault, pendingMailboxSelection != nil {
                return
            }
            pendingMailboxSelection = mailbox
            return
        }

        guard mailbox != selectedOnServer else {
            currentMailbox = mailbox
            loadMessagesFromDB()
            return
        }

        isSelectingMailbox = true
        isSyncing = true
        client.send("SELECT \(mailbox)") { [weak self] reply, untagged in
            Task { @MainActor in
                guard reply.key == "OK" else {
                    self?.lastError = SessionError.selectFailed(reply.text).localizedDescription
                    self?.isSyncing = false
                    self?.isSelectingMailbox = false
                    self?.processQueueIfNeeded()
                    return
                }
                self?.selectedOnServer = mailbox
                self?.currentMailbox = mailbox

                if let uidValidityResponse = untagged.first(where: { $0.bracketedInt(named: "UIDVALIDITY") != nil }),
                   let newValidity = uidValidityResponse.bracketedInt(named: "UIDVALIDITY"),
                   let self, let dbQueue = try? self.database() {
                    _ = try? UIDValidityChecker.reconcile(mailbox: mailbox, newValidity: newValidity, dbQueue: dbQueue)
                }

                self?.syncMailboxContents(mailbox) {
                    self?.loadMessagesFromDB()
                    self?.isSyncing = false
                    self?.isSelectingMailbox = false
                    self?.processQueueIfNeeded()
                }
            }
        }
    }

    /// Re-checks real server flags for every message already cached
    /// locally in `mailbox`, not just newly-fetched ones. Without this,
    /// only messages fetched for the first time ever get a correct isSeen
    /// value - anything already cached stays stuck at whatever it was set
    /// to, even if it's since been read (or unread) via another client.
    /// Deliberately only run from the manual Sync action, not automatically
    /// on every mailbox switch - re-checking flags for a mailbox with
    /// thousands of messages every time you click it would be wasteful.
    func refreshFlags(mailbox: String, completion: @escaping () -> Void) {
        guard connectionState == .ready, let client, !isProcessingQueue, !isSelectingMailbox else {
            completion()
            return
        }
        isProcessingQueue = true

        ensureSelected(mailbox) { [weak self] selected in
            guard selected, let self else {
                self?.isProcessingQueue = false
                completion()
                return
            }
            // "1:*" is a valid UID range meaning every message currently in
            // the mailbox, regardless of gaps in the actual UID numbering.
            client.send("UID FETCH 1:* (UID FLAGS)") { reply, untagged in
                Task { @MainActor in
                    self.isProcessingQueue = false
                    guard reply.key == "OK", let dbQueue = try? self.database() else {
                        completion()
                        self.processQueueIfNeeded()
                        return
                    }

                    _ = try? dbQueue.write { db in
                        for response in untagged where response.isNumbered && response.numberedKeyword == "FETCH" {
                            guard let uid = response.fetchUID() else { continue }
                            let isSeen = response.fetchFlags().contains("\\Seen")
                            if var msg = try Message.filter(Column("mailbox") == mailbox && Column("uid") == uid).fetchOne(db),
                               msg.isSeen != isSeen {
                                msg.isSeen = isSeen
                                try msg.update(db)
                            }
                        }
                    }

                    self.loadMessagesFromDB()
                    completion()
                    self.processQueueIfNeeded()
                }
            }
        }
    }

    /// Manual re-sync of whatever mailbox is currently open - for the
    /// toolbar Sync button, catching deletions/new mail that happened while
    /// the app's been sitting connected, and now also refreshing read/unread
    /// status for messages already cached (see refreshFlags above).
    func syncNow() {
        guard connectionState == .ready else { return }
        isSyncing = true
        let mailbox = currentMailbox
        syncMailboxContents(mailbox) { [weak self] in
            self?.refreshFlags(mailbox: mailbox) {
                self?.loadMessagesFromDB()
                self?.isSyncing = false
            }
        }
    }

    /// Fetches the server's full UID list for `mailbox`, removes anything
    /// cached locally that's no longer there, and fetches envelopes for
    /// anything the server has that isn't cached locally yet.
    private func syncMailboxContents(_ mailbox: String, completion: @escaping () -> Void) {
        guard let client else { completion(); return }

        client.send("UID SEARCH ALL") { [weak self] reply, untagged in
            guard reply.key == "OK",
                  let searchResponse = untagged.first(where: { $0.key == "SEARCH" }) else {
                completion()
                return
            }
            let serverUIDs = Set(searchResponse.text.split(separator: " ").compactMap { Int($0) })

            Task { @MainActor in
                guard let self else { completion(); return }
                self.deleteMessagesNotIn(serverUIDs, mailbox: mailbox)

                let localUIDs = (try? self.database().read { db in
                    Set(try Int.fetchAll(db, sql: "SELECT uid FROM message WHERE mailbox = ?", arguments: [mailbox]))
                }) ?? []
                let missing = serverUIDs.subtracting(localUIDs)

                guard !missing.isEmpty else { completion(); return }
                self.fetchMissingEnvelopes(Array(missing), mailbox: mailbox, client: client, completion: completion)
            }
        }
    }

    private func deleteMessagesNotIn(_ serverUIDs: Set<Int>, mailbox: String) {
        guard let dbQueue = try? database() else { return }
        do {
            let localUIDs = try dbQueue.read { db in
                Set(try Int.fetchAll(db, sql: "SELECT uid FROM message WHERE mailbox = ?", arguments: [mailbox]))
            }
            let toDelete = localUIDs.subtracting(serverUIDs)
            guard !toDelete.isEmpty else { return }

            _ = try dbQueue.write { db in
                try Message.filter(Column("mailbox") == mailbox && toDelete.contains(Column("uid"))).deleteAll(db)
            }

            let corpusDir = self.corpusDirectory
            for uid in toDelete {
                try? FileManager.default.removeItem(at: corpusDir.appendingPathComponent("\(mailbox)-\(uid).eml"))
            }
            print("Reconciliation (\(mailbox)): removed \(toDelete.count) message(s) deleted server-side.")
        } catch {
            print("Reconciliation error: \(error)")
        }
    }

    /// Fetches envelopes for UIDs the server has that aren't cached locally
    /// yet - this is what makes switching to a mailbox for the first time
    /// (e.g. Sent) automatically populate it, rather than depending on the
    /// separate console-only backfill tool.
    private func fetchMissingEnvelopes(_ uids: [Int], mailbox: String, client: IMAPClient, completion: @escaping () -> Void) {
        let uidList = uids.map(String.init).joined(separator: ",")
        // BODY.PEEK[HEADER.FIELDS (...)] fetches just these header lines,
        // not the full message body - PEEK means it doesn't mark the
        // message as read as a side effect either. Cheap enough to include
        // on every envelope fetch, unlike a full body fetch would be.
        let spamHeaderFields = "BODY.PEEK[HEADER.FIELDS (X-Spam-Flag X-Spam-Status X-Spam-Score X-Spam-Level)]"
        client.send("UID FETCH \(uidList) (UID FLAGS ENVELOPE \(spamHeaderFields))") { [weak self] reply, untagged in
            Task { @MainActor in
                guard reply.key == "OK", let self, let dbQueue = try? self.database() else {
                    completion()
                    return
                }
                for response in untagged where response.isNumbered && response.numberedKeyword == "FETCH" {
                    guard let uid = response.fetchUID(),
                          let envelopeRange = response.text.range(of: "ENVELOPE ") else { continue }
                    let afterEnvelope = response.text[envelopeRange.upperBound...]
                    guard let parsed = EnvelopeParser.parse(String(afterEnvelope)) else { continue }

                    let spamSignal = response.extractSpamSignal()

                    let message = Message(
                        mailbox: mailbox,
                        uid: uid,
                        subject: parsed.subject,
                        from: parsed.fromAddress ?? "(unknown)",
                        toAlias: parsed.toAddress ?? "(unknown)",
                        date: parsed.date ?? Date(),
                        isSeen: response.fetchFlags().contains("\\Seen"),
                        isFlaggedSpam: spamSignal.isFlagged,
                        spamScore: spamSignal.score
                    )
                    _ = try? dbQueue.write { db in try message.insert(db) }
                }
                completion()
            }
        }
    }

    private func loadMessagesFromDB() {
        guard let dbQueue = try? database() else { return }
        let mailbox = currentMailbox
        messages = (try? dbQueue.read { db in
            try Message.filter(Column("mailbox") == mailbox).order(Column("date").desc).fetchAll(db)
        }) ?? []
    }

    /// Deliberately goes offline - closes the connection cleanly and, unlike
    /// an accidental drop, does NOT auto-reconnect. For situations like
    /// patchy train wifi where you don't want the app fighting to reconnect
    /// every few seconds.
    func goOffline() {
        isManuallyOffline = true
        client?.logoutAndClose()
        client = nil
        selectedOnServer = nil
        connectionState = .disconnected
    }

    /// Comes back online after a deliberate goOffline() - reconnects and
    /// restores whichever mailbox was being viewed.
    func goOnline() {
        isManuallyOffline = false
        guard let host, let user, let password else { return }
        connect(host: host, port: port, user: user, password: password, initialMailbox: currentMailbox)
    }

    /// Discovers the account's real folder names via IMAP LIST with
    /// RETURN (SPECIAL-USE), mapping standard roles (sent/trash/junk/
    /// drafts/archive) to whatever the server actually calls them - not
    /// every provider names folders the way Runbox does. Primarily trusts
    /// SPECIAL-USE flags; falls back to common name patterns for roles a
    /// server doesn't advertise a flag for (not every server supports
    /// SPECIAL-USE), so a role isn't left unmapped just because a server is
    /// older or less fully-featured.
    func discoverFolders(completion: @escaping () -> Void = {}) {
        guard connectionState == .ready, let client, !isProcessingQueue, !isSelectingMailbox else {
            completion()
            return
        }
        isProcessingQueue = true

        client.send("LIST \"\" \"*\" RETURN (SPECIAL-USE)") { [weak self] reply, untagged in
            Task { @MainActor in
                guard let self else { completion(); return }
                self.isProcessingQueue = false
                guard reply.key == "OK" else {
                    completion()
                    self.processQueueIfNeeded()
                    return
                }

                let folders = untagged.compactMap { $0.parseListResponse() }
                self.allDiscoveredFolders = folders

                var roles: [String: String] = ["inbox": "INBOX"]
                for folder in folders {
                    if folder.specialUse.contains("\\Sent") { roles["sent"] = folder.name }
                    if folder.specialUse.contains("\\Trash") { roles["trash"] = folder.name }
                    if folder.specialUse.contains("\\Junk") { roles["junk"] = folder.name }
                    if folder.specialUse.contains("\\Drafts") { roles["drafts"] = folder.name }
                    if folder.specialUse.contains("\\Archive") { roles["archive"] = folder.name }
                }

                // Fallback for servers that don't advertise SPECIAL-USE for
                // a given role - common name patterns seen across providers.
                if roles["sent"] == nil {
                    roles["sent"] = folders.first(where: { ["Sent", "Sent Items", "Sent Mail", "Sent Messages"].contains($0.name) })?.name
                }
                if roles["trash"] == nil {
                    roles["trash"] = folders.first(where: { ["Trash", "Deleted Items", "Deleted Messages"].contains($0.name) })?.name
                }
                if roles["junk"] == nil {
                    roles["junk"] = folders.first(where: { ["Junk", "Spam", "Junk E-mail"].contains($0.name) })?.name
                }
                if roles["archive"] == nil {
                    roles["archive"] = folders.first(where: { ["Archive", "All Mail"].contains($0.name) })?.name
                }
                if roles["drafts"] == nil {
                    roles["drafts"] = folders.first(where: { ["Drafts"].contains($0.name) })?.name
                }

                self.discoveredFolders = roles
                completion()
                self.processQueueIfNeeded()
            }
        }
    }

    /// Looks up the real folder name for a role (e.g. "archive"), falling
    /// back to `fallback` if discovery hasn't completed yet or didn't find
    /// that role - keeps things working at the moment of connect, before
    /// discovery's first round trip finishes, rather than needing every
    /// caller to handle a possibly-empty discoveredFolders dictionary.
    func folderName(for role: String, fallback: String) -> String {
        discoveredFolders[role] ?? fallback
    }

    private func handleConnectionFailure(_ error: Error) {
        let mailboxToRestore = currentMailbox

        connectionState = .disconnected
        client = nil
        selectedOnServer = nil
        isProcessingQueue = false
        isSelectingMailbox = false

        let pending = queue
        queue = []
        for (_, _, completion) in pending {
            completion(.failure(SessionError.connectionLost))
        }
        lastError = "\(error)"

        // Deliberate offline mode overrides auto-reconnect entirely - an
        // unexpected failure while already offline-by-choice shouldn't
        // fight against that choice.
        guard !isManuallyOffline else { return }

        // Proactively reconnect right away - e.g. after sleep/wake, the
        // network is typically already back by the time we notice the old
        // socket died, so there's usually nothing to wait for. This is a
        // single attempt, not a retry loop with backoff - if the network is
        // genuinely down, this attempt fails too and the next attempt
        // happens lazily on the next fetchBody call, same as before this fix.
        if let host, let user, let password {
            connect(host: host, port: port, user: user, password: password, initialMailbox: mailboxToRestore)
        }
    }

    /// Ensures `mailbox` is SELECTed server-side before an operation that
    /// needs it (MOVE/STORE act on whatever's currently selected). Needed
    /// because actions can now be triggered from a smart folder spanning
    /// several real mailboxes at once, not just whichever one happens to be
    /// the sidebar's current selection.
    private func ensureSelected(_ mailbox: String, completion: @escaping (Bool) -> Void) {
        guard let client else { completion(false); return }
        guard selectedOnServer != mailbox else { completion(true); return }
        client.send("SELECT \(mailbox)") { [weak self] reply, _ in
            Task { @MainActor in
                guard reply.key == "OK" else { completion(false); return }
                self?.selectedOnServer = mailbox
                self?.currentMailbox = mailbox
                completion(true)
            }
        }
    }

    /// Moves a message to a different mailbox (Archive, Trash, Spam, ...)
    /// using IMAP's MOVE extension, which Runbox supports (confirmed via
    /// its CAPABILITY response) - a single command, rather than the classic
    /// COPY + flag-as-deleted + EXPUNGE dance servers without MOVE need.
    ///
    /// Captures the message's new UID in the destination mailbox (via
    /// UIDPLUS's COPYUID response code) and inserts it into the local cache
    /// immediately, rather than waiting for the destination mailbox to next
    /// be visited/synced. This matters for smart folders spanning multiple
    /// mailboxes: without it, a moved message would briefly vanish from any
    /// smart folder until its new mailbox happened to get synced.
    func moveMessage(uid: Int, from sourceMailbox: String, to destinationMailbox: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard connectionState == .ready, let client, !isProcessingQueue, !isSelectingMailbox else {
            completion(.failure(SessionError.notReady))
            return
        }
        isProcessingQueue = true

        ensureSelected(sourceMailbox) { [weak self] selected in
            guard selected, let self else {
                self?.isProcessingQueue = false
                completion(.failure(SessionError.selectFailed("Could not open \(sourceMailbox)")))
                self?.processQueueIfNeeded()
                return
            }

            // Capture what we know about this message before it's gone
            // locally, so we can immediately re-insert it under the
            // destination mailbox once we know its new UID.
            let original = try? self.database().read { db in
                try Message.filter(Column("mailbox") == sourceMailbox && Column("uid") == uid).fetchOne(db)
            }

            client.send("UID MOVE \(uid) \(destinationMailbox)") { [weak self] reply, _ in
                Task { @MainActor in
                    self?.isProcessingQueue = false
                    guard reply.key == "OK" else {
                        completion(.failure(SessionError.fetchFailed(reply.text)))
                        self?.processQueueIfNeeded()
                        return
                    }
                    guard let self, let dbQueue = try? self.database() else {
                        completion(.success(()))
                        self?.processQueueIfNeeded()
                        return
                    }

                    _ = try? dbQueue.write { db in
                        try Message.filter(Column("mailbox") == sourceMailbox && Column("uid") == uid).deleteAll(db)
                    }

                    let corpusDir = self.corpusDirectory
                    let oldFile = corpusDir.appendingPathComponent("\(sourceMailbox)-\(uid).eml")

                    if let newUID = reply.copyUID(), let original {
                        var moved = original
                        moved.mailbox = destinationMailbox
                        moved.uid = newUID
                        _ = try? dbQueue.write { db in try moved.insert(db) }

                        // Carry the cached body over to the new location too,
                        // so it's instantly readable without a re-fetch.
                        let newFile = corpusDir.appendingPathComponent("\(destinationMailbox)-\(newUID).eml")
                        try? FileManager.default.copyItem(at: oldFile, to: newFile)
                    }
                    try? FileManager.default.removeItem(at: oldFile)

                    self.loadMessagesFromDB()
                    completion(.success(()))
                    self.processQueueIfNeeded()
                }
            }
        }
    }

    /// Toggles the \Seen flag via IMAP STORE. `markAsUnread: true` removes
    /// \Seen, `false` adds it back.
    func toggleUnread(uid: Int, in mailbox: String, markAsUnread: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard connectionState == .ready, let client, !isProcessingQueue, !isSelectingMailbox else {
            completion(.failure(SessionError.notReady))
            return
        }
        isProcessingQueue = true

        ensureSelected(mailbox) { [weak self] selected in
            guard selected else {
                self?.isProcessingQueue = false
                completion(.failure(SessionError.selectFailed("Could not open \(mailbox)")))
                self?.processQueueIfNeeded()
                return
            }
            let flagCommand = markAsUnread ? "-FLAGS" : "+FLAGS"
            client.send("UID STORE \(uid) \(flagCommand) (\\Seen)") { [weak self] reply, _ in
                Task { @MainActor in
                    self?.isProcessingQueue = false
                    guard reply.key == "OK" else {
                        completion(.failure(SessionError.fetchFailed(reply.text)))
                        self?.processQueueIfNeeded()
                        return
                    }
                    if let self, let dbQueue = try? self.database() {
                        _ = try? dbQueue.write { db in
                            if var msg = try Message.filter(Column("mailbox") == mailbox && Column("uid") == uid).fetchOne(db) {
                                msg.isSeen = !markAsUnread
                                try msg.update(db)
                            }
                        }
                    }
                    self?.loadMessagesFromDB()
                    completion(.success(()))
                    self?.processQueueIfNeeded()
                }
            }
        }
    }

    /// Permanently deletes every message in the given mailbox (default:
    /// Trash) via the classic IMAP two-step: STORE every message as
    /// \Deleted, then EXPUNGE to actually remove them. Unlike moveMessage,
    /// this is genuinely irreversible - there's no mailbox to move these
    /// back from afterward.
    /// Moves every message in `mailbox` to `destinationMailbox` in one
    /// server-side operation (e.g. "move all of Spam to Trash") - operates
    /// on the whole range (1:*), not just whatever's cached locally, same
    /// principle as emptyTrash. The destination mailbox's local cache picks
    /// up the moved messages naturally next time it's synced/visited,
    /// rather than trying to track individual new UIDs for a bulk move.
    func moveAllMessages(from mailbox: String, to destinationMailbox: String, completion: @escaping () -> Void) {
        guard connectionState == .ready, let client, !isProcessingQueue, !isSelectingMailbox else {
            completion()
            return
        }
        isProcessingQueue = true

        ensureSelected(mailbox) { [weak self] selected in
            guard selected, let self else {
                self?.isProcessingQueue = false
                completion()
                return
            }
            client.send("UID MOVE 1:* \(destinationMailbox)") { reply, _ in
                Task { @MainActor in
                    self.isProcessingQueue = false
                    guard reply.key == "OK" else {
                        completion()
                        self.processQueueIfNeeded()
                        return
                    }
                    // Everything's gone from the source mailbox now - clear
                    // its local cache entirely.
                    if let dbQueue = try? self.database() {
                        _ = try? dbQueue.write { db in
                            try Message.filter(Column("mailbox") == mailbox).deleteAll(db)
                        }
                    }
                    let corpusDir = self.corpusDirectory
                    if let files = try? FileManager.default.contentsOfDirectory(at: corpusDir, includingPropertiesForKeys: nil) {
                        for file in files where file.lastPathComponent.hasPrefix("\(mailbox)-") {
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                    self.loadMessagesFromDB()
                    completion()
                    self.processQueueIfNeeded()
                }
            }
        }
    }

    func emptyTrash(mailbox: String = "Trash", completion: @escaping (Result<Void, Error>) -> Void) {
        guard connectionState == .ready, let client, !isProcessingQueue, !isSelectingMailbox, currentMailbox == mailbox else {
            completion(.failure(SessionError.notReady))
            return
        }
        isProcessingQueue = true
        client.send("STORE 1:* +FLAGS (\\Deleted)") { [weak self] reply, _ in
            guard reply.key == "OK" else {
                Task { @MainActor in
                    self?.isProcessingQueue = false
                    completion(.failure(SessionError.fetchFailed(reply.text)))
                    self?.processQueueIfNeeded()
                }
                return
            }
            client.send("EXPUNGE") { [weak self] reply, _ in
                Task { @MainActor in
                    self?.isProcessingQueue = false
                    guard reply.key == "OK" else {
                        completion(.failure(SessionError.fetchFailed(reply.text)))
                        self?.processQueueIfNeeded()
                        return
                    }
                    if let self, let dbQueue = try? self.database() {
                        _ = try? dbQueue.write { db in
                            try Message.filter(Column("mailbox") == mailbox).deleteAll(db)
                        }
                    }
                    if let corpusDir = self?.corpusDirectory,
                       let files = try? FileManager.default.contentsOfDirectory(at: corpusDir, includingPropertiesForKeys: nil) {
                        for file in files where file.lastPathComponent.hasPrefix("\(mailbox)-") {
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                    self?.loadMessagesFromDB()
                    completion(.success(()))
                    self?.processQueueIfNeeded()
                }
            }
        }
    }

    /// Moves several messages one after another (IMAPClient is single-flight,
    /// so these can't run in parallel). Each item carries its own source
    /// mailbox - a multi-select from a smart folder can span several real
    /// mailboxes at once, not just one shared source.
    func moveMessages(items: [(uid: Int, mailbox: String)], to destinationMailbox: String, completion: @escaping () -> Void) {
        guard var queue = items.isEmpty ? nil : items else { completion(); return }
        let item = queue.removeFirst()
        moveMessage(uid: item.uid, from: item.mailbox, to: destinationMailbox) { [weak self] _ in
            self?.moveMessages(items: queue, to: destinationMailbox, completion: completion)
        }
    }

    /// Applies the same read/unread state to several messages in turn.
    /// For multi-select, using one target state for the whole batch (rather
    /// than each message toggling its own state independently) gives a
    /// predictable bulk result instead of a potentially mixed one.
    func toggleUnreadForMessages(items: [(uid: Int, mailbox: String)], markAsUnread: Bool, completion: @escaping () -> Void) {
        guard var queue = items.isEmpty ? nil : items else { completion(); return }
        let item = queue.removeFirst()
        toggleUnread(uid: item.uid, in: item.mailbox, markAsUnread: markAsUnread) { [weak self] _ in
            self?.toggleUnreadForMessages(items: queue, markAsUnread: markAsUnread, completion: completion)
        }
    }

    /// Permanently deletes specific messages (not the whole mailbox, unlike
    /// emptyTrash) - used when Backspace is pressed while already viewing
    /// Trash, where moving to Trash again isn't meaningful (a message can't
    /// be moved into the mailbox it's already in - IMAP just rejects that).
    func permanentlyDeleteMessages(uids: [Int], completion: @escaping (Result<Void, Error>) -> Void) {
        guard connectionState == .ready, let client, !isProcessingQueue, !isSelectingMailbox, !uids.isEmpty else {
            completion(.failure(SessionError.notReady))
            return
        }
        let mailbox = currentMailbox
        let uidList = uids.map(String.init).joined(separator: ",")
        isProcessingQueue = true
        client.send("UID STORE \(uidList) +FLAGS (\\Deleted)") { [weak self] reply, _ in
            guard reply.key == "OK" else {
                Task { @MainActor in
                    self?.isProcessingQueue = false
                    completion(.failure(SessionError.fetchFailed(reply.text)))
                    self?.processQueueIfNeeded()
                }
                return
            }
            client.send("EXPUNGE") { [weak self] reply, _ in
                Task { @MainActor in
                    self?.isProcessingQueue = false
                    guard reply.key == "OK" else {
                        completion(.failure(SessionError.fetchFailed(reply.text)))
                        self?.processQueueIfNeeded()
                        return
                    }
                    if let self, let dbQueue = try? self.database() {
                        _ = try? dbQueue.write { db in
                            try Message.filter(Column("mailbox") == mailbox && uids.contains(Column("uid"))).deleteAll(db)
                        }
                    }
                    if let corpusDir = self?.corpusDirectory {
                        for uid in uids {
                            try? FileManager.default.removeItem(at: corpusDir.appendingPathComponent("\(mailbox)-\(uid).eml"))
                        }
                    }
                    self?.loadMessagesFromDB()
                    completion(.success(()))
                    self?.processQueueIfNeeded()
                }
            }
        }
    }

    func fetchBody(uid: Int, mailbox: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.append((uid, mailbox, completion))

        if connectionState == .disconnected, !isManuallyOffline, let host, let user, let password {
            connect(host: host, port: port, user: user, password: password, initialMailbox: currentMailbox)
        } else {
            processQueueIfNeeded()
        }
    }

    private func processQueueIfNeeded() {
        // A mailbox switch requested while busy takes priority over
        // continuing background body-fetches - the user is actively
        // waiting to see a different mailbox, not for those to finish.
        if let pending = pendingMailboxSelection, !isSelectingMailbox, !isProcessingQueue, pending != currentMailbox {
            pendingMailboxSelection = nil
            selectMailbox(pending)
            return
        }

        guard !isProcessingQueue, !isSelectingMailbox, connectionState == .ready, let client = client, !queue.isEmpty else { return }
        isProcessingQueue = true

        let (uid, mailbox, completion) = queue.removeFirst()

        ensureSelected(mailbox) { [weak self] selected in
            guard selected else {
                completion(.failure(SessionError.selectFailed("Could not open \(mailbox)")))
                self?.isProcessingQueue = false
                self?.processQueueIfNeeded()
                return
            }

            client.send("UID FETCH \(uid) (BODY[])") { [weak self] reply, untagged in
                Task { @MainActor in
                    guard reply.key == "OK" else {
                        completion(.failure(SessionError.fetchFailed(reply.text)))
                        self?.isProcessingQueue = false
                        self?.processQueueIfNeeded()
                        return
                    }
                    guard let fetchResponse = untagged.first(where: { $0.isNumbered && $0.numberedKeyword == "FETCH" }) else {
                        completion(.failure(SessionError.noData))
                        self?.isProcessingQueue = false
                        self?.processQueueIfNeeded()
                        return
                    }

                    var raw = fetchResponse.text
                    if let bodyRange = raw.range(of: "BODY[] ") {
                        raw = String(raw[bodyRange.upperBound...])
                    }
                    if raw.hasPrefix("{"), let closeBrace = raw.firstIndex(of: "}") {
                        raw = String(raw[raw.index(after: closeBrace)...])
                    }
                    if raw.hasSuffix(")") {
                        raw.removeLast()
                    }

                    completion(.success(raw))
                    self?.isProcessingQueue = false
                    self?.processQueueIfNeeded()
                }
            }
        }
    }
}
