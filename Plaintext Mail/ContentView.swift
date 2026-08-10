import SwiftUI
import GRDB
import AppKit
import Combine

/// What's currently selected in the sidebar - either a real IMAP mailbox
/// or a locally-defined smart folder, both scoped to a specific account
/// now that multiple accounts exist. Needed because they behave quite
/// differently: selecting a mailbox does a real IMAP SELECT + sync,
/// selecting a smart folder just runs a local SQL query across whichever
/// mailboxes it watches - and because each account has its own separate
/// database, a smart folder's numeric ID is only unique within its own
/// account, hence carrying accountID alongside it here too.
enum SidebarSelection: Hashable {
    case allMessages
    case mailbox(accountID: UUID, name: String)
    case smartFolder(accountID: UUID, id: Int64)
}

enum SortOption: String, CaseIterable, Identifiable {
    case dateNewest = "Date (Newest First)"
    case dateOldest = "Date (Oldest First)"
    case senderAZ = "Sender (A–Z)"
    case senderZA = "Sender (Z–A)"
    case recipientAZ = "Recipient (A–Z)"
    case recipientZA = "Recipient (Z–A)"

    var id: String { rawValue }
}

/// Shared by ContentView's menu-bar bridge (keyboard shortcuts, which can
/// fire regardless of which view currently has focus) and
/// MailboxContentColumn's own row-level context menus/drag-and-drop - a
/// free function taking `session` explicitly, rather than a method on
/// either type, so both call the exact same logic with no duplication.
/// Moves items to a destination mailbox, except when everything's already
/// sitting in Trash and the destination IS Trash - that's a permanent
/// delete (moving Trash to itself is rejected as a no-op by IMAP anyway).
func moveOrDelete(session: MailSession, items: [(uid: Int, mailbox: String)], to destinationMailbox: String) {
    guard !items.isEmpty else { return }
    let trashFolder = session.folderName(for: "trash", fallback: "Trash")
    if destinationMailbox == trashFolder, items.allSatisfy({ $0.mailbox == trashFolder }) {
        session.permanentlyDeleteMessages(uids: items.map { $0.uid }) { _ in }
    } else {
        session.moveMessages(items: items, to: destinationMailbox) { }
    }
}

struct ContentView: View {
    @StateObject private var sessionManager = AccountSessionManager()
    @StateObject private var multiSessionObserver = MultiSessionObserver()
    @StateObject private var accountsStore = AccountsStore()
    @StateObject private var outbox = OutboxManager()
    @State private var selectedMessages: Set<Message.ID> = []
    @State private var selectedAccountMessage: AccountMessage?
    @State private var composeTarget: ComposeTarget?
    @State private var redirectTarget: RedirectTarget?
    @State private var sidebarSelection: SidebarSelection?
    @State private var showEmptyTrashConfirm = false
    @State private var searchQuery = ""
    @State private var smartFolderSheetTarget: SmartFolderSheetTarget?
    @State private var sortOption: SortOption = .dateNewest
    @State private var showShortcutsHelp = false
    @State private var showEditSignatures = false
    @State private var showAddAccount = false
    @State private var dropTargetedMailbox: String?

    enum SmartFolderSheetTarget: Identifiable {
        case new(accountID: UUID)
        case edit(accountID: UUID, folder: SmartFolder)
        var id: String {
            switch self {
            case .new(let accountID): return "new-\(accountID)"
            case .edit(let accountID, let f): return "edit-\(accountID)-\(f.id ?? -1)"
            }
        }
    }

    struct ComposeTarget: Identifiable {
        let id = UUID()
        let from: String
        let to: String
        let cc: String
        let subject: String
        let body: String
        let sentFolder: String
    }

    struct RedirectTarget: Identifiable {
        let id = UUID()
        let message: Message
        let raw: String
        let sentFolder: String
        let defaultFrom: String
    }

    /// Real folder names via discovery, falling back to Runbox's own naming
    /// until discovery completes (or if it ever fails) - identical to the
    /// old hardcoded values for Runbox specifically, so nothing changes
    /// visually for that account, but genuinely correct for any other.
    /// Now takes an account explicitly, since each account has its own
    /// session and its own discovered folder names.
    private func mailboxes(for accountID: UUID) -> [(role: String, name: String, label: String, icon: String)] {
        guard let session = sessionManager.session(for: accountID) else { return [] }
        return [
            (role: "inbox", name: "INBOX", label: "Inbox", icon: "tray"),
            (role: "sent", name: session.folderName(for: "sent", fallback: "Sent"), label: "Sent", icon: "paperplane"),
            (role: "archive", name: session.folderName(for: "archive", fallback: "Archive"), label: "Archive", icon: "archivebox"),
            (role: "junk", name: session.folderName(for: "junk", fallback: "Spam"), label: "Spam", icon: "nosign"),
            (role: "trash", name: session.folderName(for: "trash", fallback: "Trash"), label: "Trash", icon: "trash"),
        ]
    }

    /// The session matching whatever's currently selected - used for
    /// routing actions (menu-bar shortcuts, sidebar's own onChange) to the
    /// right account. NOT used for display any more - MailboxContentColumn
    /// holds its own direct @ObservedObject reference for that, since
    /// routing actions correctly doesn't require reactive observation the
    /// way rendering does. "All Messages" is deliberately scoped to the
    /// first configured account for now - a genuinely cross-account
    /// unified view is separate, later work.
    private var currentSession: MailSession? {
        switch sidebarSelection {
        case .mailbox(let accountID, _), .smartFolder(let accountID, _):
            return sessionManager.session(for: accountID)
        case .allMessages, nil:
            guard let firstAccount = accountsStore.accounts.first else { return nil }
            return sessionManager.session(for: firstAccount.id)
        }
    }

    /// The account matching currentSession, when there is one.
    private var currentAccount: Account? {
        switch sidebarSelection {
        case .mailbox(let accountID, _), .smartFolder(let accountID, _):
            return accountsStore.accounts.first(where: { $0.id == accountID })
        case .allMessages, nil:
            return accountsStore.accounts.first
        }
    }

    var body: some View {
        if !accountsStore.accounts.isEmpty {
            mainWindow
        } else {
            AddAccountView(accountsStore: accountsStore)
        }
    }

    private var mainWindow: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label("All Messages", systemImage: "tray.full")
                    .tag(SidebarSelection.allMessages)
                ForEach(accountsStore.accounts) { account in
                    Section(account.displayName) {
                        ForEach(mailboxes(for: account.id), id: \.role) { mailbox in
                            Label(mailbox.label, systemImage: mailbox.icon)
                                .tag(SidebarSelection.mailbox(accountID: account.id, name: mailbox.name))
                                .listRowBackground(
                                    dropTargetedMailbox == mailbox.name ? Color.accentColor.opacity(0.2) : nil
                                )
                                .dropDestination(for: String.self) { ids, _ in
                                    handleDrop(ids: ids, to: mailbox.name, accountID: account.id)
                                    return true
                                } isTargeted: { targeted in
                                    dropTargetedMailbox = targeted ? mailbox.name : nil
                                }
                                .contextMenu {
                                    if mailbox.role == "trash" {
                                        Button("Empty Trash", role: .destructive) {
                                            showEmptyTrashConfirm = true
                                        }
                                    } else if mailbox.role == "junk" {
                                        Button("Move All to Trash") {
                                            let trashFolder = mailboxes(for: account.id).first(where: { $0.role == "trash" })?.name ?? "Trash"
                                            sessionManager.session(for: account.id)?.moveAllMessages(from: mailbox.name, to: trashFolder) { }
                                        }
                                    }
                                    // No context menu items for other mailboxes -
                                    // deliberately scoped to just these two.
                                }
                        }
                        if let session = sessionManager.session(for: account.id), !session.smartFolders.isEmpty {
                            ForEach(session.smartFolders) { folder in
                                Label(folder.name, systemImage: "gearshape.2")
                                    .tag(SidebarSelection.smartFolder(accountID: account.id, id: folder.id ?? -1))
                                    .contextMenu {
                                        Button("Edit…") {
                                            smartFolderSheetTarget = .edit(accountID: account.id, folder: folder)
                                        }
                                        Button("Delete", role: .destructive) {
                                            session.deleteSmartFolder(folder)
                                            if sidebarSelection == .smartFolder(accountID: account.id, id: folder.id ?? -1) {
                                                sidebarSelection = .mailbox(accountID: account.id, name: "INBOX")
                                            }
                                        }
                                    }
                            }
                        }
                        Button {
                            smartFolderSheetTarget = .new(accountID: account.id)
                        } label: {
                            Label("New Smart Folder…", systemImage: "plus")
                        }
                    }
                }
            }
            .onChange(of: sidebarSelection) { _, newValue in
                selectedMessages = []
                selectedAccountMessage = nil
                searchQuery = ""
                currentSession?.clearSearch()
                switch newValue {
                case .mailbox(let accountID, let name):
                    sessionManager.session(for: accountID)?.selectMailbox(name)
                case .allMessages:
                    for account in accountsStore.accounts {
                        sessionManager.session(for: account.id)?.syncMultipleMailboxes(allMessagesMailboxes(for: account.id)) { }
                    }
                case .smartFolder, .none:
                    break
                }
            }
            .navigationTitle("Mailboxes")
            .sheet(item: $smartFolderSheetTarget) { target in
                switch target {
                case .new(let accountID):
                    if let session = sessionManager.session(for: accountID) {
                        SmartFolderFormView(session: session, existingFolder: nil)
                    }
                case .edit(let accountID, let folder):
                    if let session = sessionManager.session(for: accountID) {
                        SmartFolderFormView(session: session, existingFolder: folder)
                    }
                }
            }
        } content: {
            Group {
                if case .allMessages = sidebarSelection {
                    AllMessagesColumn(
                        sessionManager: sessionManager,
                        multiSessionObserver: multiSessionObserver,
                        accountsStore: accountsStore,
                        outbox: outbox,
                        selectedAccountMessage: $selectedAccountMessage,
                        composeTarget: $composeTarget,
                        redirectTarget: $redirectTarget,
                        onReply: { accountMessage in
                            composeTarget = replyTarget(for: accountMessage.message, replyAll: false, accountID: accountMessage.accountID, session: sessionManager.session(for: accountMessage.accountID))
                        },
                        onReplyAll: { accountMessage in
                            composeTarget = replyTarget(for: accountMessage.message, replyAll: true, accountID: accountMessage.accountID, session: sessionManager.session(for: accountMessage.accountID))
                        },
                        onForward: { accountMessage in
                            composeTarget = forwardTarget(for: accountMessage.message, accountID: accountMessage.accountID, session: sessionManager.session(for: accountMessage.accountID))
                        },
                        onComposeNew: {
                            let newMessageFrom = accountsStore.accounts.first?.email ?? ""
                            composeTarget = ComposeTarget(from: newMessageFrom, to: "", cc: "", subject: "", body: signatureBlock(for: newMessageFrom), sentFolder: "Sent")
                        },
                        onSyncAllSessions: { syncAllSessions() }
                    )
                } else if let session = currentSession, let account = currentAccount {
                    MailboxContentColumn(
                        session: session,
                        accountsStore: accountsStore,
                        outbox: outbox,
                        selectedMessages: $selectedMessages,
                        composeTarget: $composeTarget,
                        redirectTarget: $redirectTarget,
                        searchQuery: $searchQuery,
                        sortOption: $sortOption,
                        showEmptyTrashConfirm: $showEmptyTrashConfirm,
                        sidebarSelection: sidebarSelection,
                        currentAccount: account,
                        mailboxes: mailboxes(for: account.id),
                        allMessagesMailboxes: allMessagesMailboxes(for: account.id),
                        onReply: { message in composeTarget = replyTarget(for: message, replyAll: false, accountID: account.id, session: session) },
                        onReplyAll: { message in composeTarget = replyTarget(for: message, replyAll: true, accountID: account.id, session: session) },
                        onForward: { message in composeTarget = forwardTarget(for: message, accountID: account.id, session: session) },
                        onComposeNew: {
                            let newMessageFrom = currentAccount?.email ?? accountsStore.accounts.first?.email ?? ""
                            composeTarget = ComposeTarget(from: newMessageFrom, to: "", cc: "", subject: "", body: signatureBlock(for: newMessageFrom), sentFolder: currentSession?.folderName(for: "sent", fallback: "Sent") ?? "Sent")
                        },
                        onSyncAllSessions: { syncAllSessions() }
                    )
                } else {
                    Text("No messages found")
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showShortcutsHelp) {
                ShortcutsHelpView()
            }
            .sheet(isPresented: $showEditSignatures) {
                EditSignaturesView(accountsStore: accountsStore)
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountView(accountsStore: accountsStore)
            }
            .sheet(item: $composeTarget) { target in
                ComposeView(outbox: outbox, accountsStore: accountsStore, from: target.from, to: target.to, cc: target.cc, subject: target.subject, messageBody: target.body, sentFolder: target.sentFolder)
            }
            .sheet(item: $redirectTarget) { target in
                RedirectView(
                    outbox: outbox, accountsStore: accountsStore,
                    originalMessage: target.message, originalRaw: target.raw,
                    sentFolder: target.sentFolder, defaultFrom: target.defaultFrom
                )
            }
            // Shortcuts that act on the current selection now live in the
            // real menu bar (MailAppApp.swift) rather than as hidden
            // buttons here - the menu bridges to these same action
            // functions via NotificationCenter. Merged into one publisher
            // rather than nine separate .onReceive modifiers - nine chained
            // onto an already-large view expression pushed Swift's type
            // checker past its complexity limit ("unable to type-check this
            // expression in reasonable time"), and this is cleaner besides.
            .onReceive(menuNotificationPublisher) { handleMenuNotification($0) }
            .task {
                syncAllSessions()
                if sidebarSelection == nil, let firstAccount = accountsStore.accounts.first {
                    sidebarSelection = .mailbox(accountID: firstAccount.id, name: "INBOX")
                }
            }
            .onChange(of: accountsStore.accounts) { _, _ in
                syncAllSessions()
            }
        } detail: {
            if case .allMessages = sidebarSelection, let accountMessage = selectedAccountMessage,
               let session = sessionManager.session(for: accountMessage.accountID) {
                MessageDetailView(
                    message: accountMessage.message,
                    accountID: accountMessage.accountID,
                    session: session,
                    onReply: { composeTarget = replyTarget(for: accountMessage.message, replyAll: false, accountID: accountMessage.accountID, session: session) },
                    onReplyAll: { composeTarget = replyTarget(for: accountMessage.message, replyAll: true, accountID: accountMessage.accountID, session: session) },
                    onForward: { composeTarget = forwardTarget(for: accountMessage.message, accountID: accountMessage.accountID, session: session) },
                    onRedirect: {
                        if let raw = cachedRawMessage(for: accountMessage.message, accountID: accountMessage.accountID) {
                            let isSent = accountMessage.message.mailbox == session.folderName(for: "sent", fallback: "Sent")
                            let defaultFrom = isSent ? accountMessage.message.from : accountMessage.message.toAlias
                            redirectTarget = RedirectTarget(
                                message: accountMessage.message,
                                raw: raw,
                                sentFolder: session.folderName(for: "sent", fallback: "Sent"),
                                defaultFrom: defaultFrom
                            )
                        }
                    }
                )
            } else if selectedMessages.count == 1, let id = selectedMessages.first,
               let accountID = currentAccount?.id, let session = currentSession,
               let message = findSelectedMessage(id: id, session: session) {
                MessageDetailView(
                    message: message,
                    accountID: accountID,
                    session: session,
                    onReply: { composeTarget = replyTarget(for: message, replyAll: false, accountID: accountID, session: session) },
                    onReplyAll: { composeTarget = replyTarget(for: message, replyAll: true, accountID: accountID, session: session) },
                    onForward: { composeTarget = forwardTarget(for: message, accountID: accountID, session: session) },
                    onRedirect: {
                        if let raw = cachedRawMessage(for: message, accountID: accountID) {
                            let isSent = message.mailbox == session.folderName(for: "sent", fallback: "Sent")
                            let defaultFrom = isSent ? message.from : message.toAlias
                            redirectTarget = RedirectTarget(
                                message: message,
                                raw: raw,
                                sentFolder: session.folderName(for: "sent", fallback: "Sent"),
                                defaultFrom: defaultFrom
                            )
                        }
                    }
                )
            } else if selectedMessages.count > 1 {
                Text("\(selectedMessages.count) messages selected")
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a message")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers needed by the sidebar itself and by construction of
    // the content/detail columns - these route to the right session by
    // account ID, which is correct even without reactive observation,
    // since they're called fresh at the moment of use, not cached.

    /// Finds a selected message by ID across whichever source is currently
    /// active - search results, a smart folder's broader query, or the
    /// plain current-mailbox list - mirroring the same branching
    /// MailboxContentColumn uses for its own displayedMessages, so the
    /// detail pane can correctly find a message regardless of which view
    /// it was selected from, not just the current mailbox.
    private func findSelectedMessage(id: Message.ID, session: MailSession) -> Message? {
        if let searchResults = session.searchResults {
            return searchResults.first(where: { $0.id == id })
        }
        if case .allMessages = sidebarSelection, let accountID = currentAccount?.id {
            return session.messagesForMailboxes(allMessagesMailboxes(for: accountID)).first(where: { $0.id == id })
        }
        if case .smartFolder(_, let folderID) = sidebarSelection,
           let folder = session.smartFolders.first(where: { $0.id == folderID }) {
            return session.messagesForSmartFolder(folder).first(where: { $0.id == id })
        }
        return session.messages.first(where: { $0.id == id })
    }

    private func allMessagesMailboxes(for accountID: UUID) -> [String] {
        guard let session = sessionManager.session(for: accountID) else { return ["INBOX"] }
        return ["INBOX", session.folderName(for: "archive", fallback: "Archive"), session.folderName(for: "sent", fallback: "Sent")]
    }

    private func handleDrop(ids: [String], to destinationMailbox: String, accountID: UUID) {
        let items: [(uid: Int, mailbox: String)] = ids.compactMap { idString in
            let parts = idString.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let uid = Int(parts[1]) else { return nil }
            return (uid: uid, mailbox: String(parts[0]))
        }
        for item in items {
            selectedMessages.remove("\(item.mailbox)|\(item.uid)")
        }
        guard let session = sessionManager.session(for: accountID) else { return }
        moveOrDelete(session: session, items: items, to: destinationMailbox)
    }

    private func signatureBlock(for email: String) -> String {
        guard let account = accountsStore.accounts.first(where: { $0.email == email }),
              !account.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return "\n\n-- \n\(account.signature)\n"
    }

    private func syncAllSessions() {
        sessionManager.syncSessions(accounts: accountsStore.accounts, passwordLookup: { accountsStore.password(for: $0) })
        for session in sessionManager.sessions.values {
            session.loadSmartFolders()
        }
        multiSessionObserver.observe(sessions: sessionManager.sessions)
    }

    private func replyTarget(for message: Message, replyAll: Bool, accountID: UUID, session: MailSession?) -> ComposeTarget {
        let isSent = message.mailbox == (session?.folderName(for: "sent", fallback: "Sent") ?? "Sent")
        let fromDefault = isSent ? message.from : message.toAlias
        let toDefault = isSent ? message.toAlias : message.from

        var cc = ""
        var quotedBody = ""
        if let raw = cachedRawMessage(for: message, accountID: accountID) {
            let parsed = MIMEParser.parse(raw)

            // Standard reply-quoting convention (unlike Forward's plain
            // separator) - a reply thread can go many rounds, and without
            // some way to visually separate new text from what came
            // before, a multi-round conversation turns unreadable.
            let originalBody = parsed.bestReadableBody() ?? ""
            // Normalize \r\n and bare \r to \n first - some content uses
            // bare \r alone as a line ending, which .split(separator: "\n")
            // doesn't recognize at all. Without this, such a block gets
            // treated as one single "line" by the split, so it only gets
            // one "> " prefix at the very start - the embedded \r
            // characters still render as visual line breaks in the text
            // editor, making everything past the first line look
            // unprefixed even though it was technically all one line as
            // far as the splitting logic was concerned.
            let normalizedBody = originalBody
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let realignedBody = realignAttributionLines(normalizedBody)
            let quotedLines = realignedBody.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            let senderName = parsed.header("From") ?? message.from
            let dateHeader = parsed.header("Date") ?? ""
            quotedBody = "\n\nOn \(dateHeader), \(senderName) wrote:\n\(quotedLines)"

            if replyAll {
                let originalTo = extractEmailAddresses(parsed.header("To") ?? "")
                let originalCc = extractEmailAddresses(parsed.header("Cc") ?? "")
                let ownAliases = accountsStore.accounts.map { $0.email.lowercased() }
                let excluded = Set(ownAliases + [toDefault.lowercased()])
                let ccList = (originalTo + originalCc).filter { !excluded.contains($0.lowercased()) }
                var seen = Set<String>()
                let deduped = ccList.filter { seen.insert($0.lowercased()).inserted }
                cc = deduped.joined(separator: ", ")
            }
        }
        return ComposeTarget(
            from: fromDefault,
            to: toDefault,
            cc: cc,
            subject: message.subject.hasPrefix("Re: ") ? message.subject : "Re: \(message.subject)",
            body: signatureBlock(for: fromDefault) + quotedBody,
            sentFolder: session?.folderName(for: "sent", fallback: "Sent") ?? "Sent"
        )
    }

    /// Within already-quoted content from earlier reply rounds, an
    /// embedded "On [date], [sender] wrote:" attribution line should sit
    /// at the quote depth of what it introduces, not what precedes it -
    /// the conventional way mail clients format nested attributions.
    /// Best-effort: matches the common "On ... wrote:" phrasing: not every
    /// possible mail client's exact wording, since there's real variety
    /// across clients here.
    private func realignAttributionLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        for line in lines {
            var depth = 0
            var rest = Substring(line)
            while rest.hasPrefix(">") {
                depth += 1
                rest = rest.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            }
            let bareContent = String(rest)
            let isAttribution = bareContent.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil
            if isAttribution {
                depth += 1
            }
            result.append(String(repeating: "> ", count: depth) + bareContent)
        }
        return result.joined(separator: "\n")
    }

    private func forwardTarget(for message: Message, accountID: UUID, session: MailSession?) -> ComposeTarget {
        let isSent = message.mailbox == (session?.folderName(for: "sent", fallback: "Sent") ?? "Sent")
        let fromDefault = isSent ? message.from : message.toAlias

        var body = ""
        if let raw = cachedRawMessage(for: message, accountID: accountID) {
            let parsed = MIMEParser.parse(raw)
            let originalBody = parsed.bestReadableBody() ?? ""
            body = """


            ---------- Forwarded message ----------
            From: \(parsed.header("From") ?? message.from)
            Date: \(parsed.header("Date") ?? "")
            Subject: \(parsed.header("Subject") ?? message.subject)
            To: \(parsed.header("To") ?? "")

            \(originalBody)
            """
        }
        return ComposeTarget(
            from: fromDefault,
            to: "",
            cc: "",
            subject: message.subject.hasPrefix("Fwd: ") ? message.subject : "Fwd: \(message.subject)",
            body: signatureBlock(for: fromDefault) + body,
            sentFolder: session?.folderName(for: "sent", fallback: "Sent") ?? "Sent"
        )
    }

    private func cachedRawMessage(for message: Message, accountID: UUID) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eml-corpus-\(accountID.uuidString)")
            .appendingPathComponent("\(message.mailbox)-\(message.uid).eml")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Menu bar bridge

    private var menuNotificationPublisher: AnyPublisher<Notification, Never> {
        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: .menuComposeNewMessage),
            NotificationCenter.default.publisher(for: .menuReply),
            NotificationCenter.default.publisher(for: .menuReplyAll),
            NotificationCenter.default.publisher(for: .menuForward),
            NotificationCenter.default.publisher(for: .menuArchive),
            NotificationCenter.default.publisher(for: .menuDelete),
            NotificationCenter.default.publisher(for: .menuMoveToJunk),
            NotificationCenter.default.publisher(for: .menuToggleUnread),
            NotificationCenter.default.publisher(for: .menuSyncNow),
            NotificationCenter.default.publisher(for: .menuShowShortcutsHelp)
        ).eraseToAnyPublisher()
    }

    private func handleMenuNotification(_ notification: Notification) {
        // In All Messages, selection lives in selectedAccountMessage (a
        // separate cross-account identity), not the regular per-mailbox
        // selectedMessages - route based on which one actually applies,
        // rather than always assuming the regular one.
        if case .allMessages = sidebarSelection {
            handleMenuNotificationForAllMessages(notification)
            return
        }

        guard let session = currentSession else { return }
        let selectedInSession = selectedMessages.compactMap { id in
            session.messages.first(where: { $0.id == id })
        }
        switch notification.name {
        case .menuComposeNewMessage:
            let newMessageFrom = currentAccount?.email ?? accountsStore.accounts.first?.email ?? ""
            composeTarget = ComposeTarget(from: newMessageFrom, to: "", cc: "", subject: "", body: signatureBlock(for: newMessageFrom), sentFolder: session.folderName(for: "sent", fallback: "Sent"))
        case .menuReply:
            if selectedInSession.count == 1, let accountID = currentAccount?.id { composeTarget = replyTarget(for: selectedInSession[0], replyAll: false, accountID: accountID, session: session) }
        case .menuReplyAll:
            if selectedInSession.count == 1, let accountID = currentAccount?.id { composeTarget = replyTarget(for: selectedInSession[0], replyAll: true, accountID: accountID, session: session) }
        case .menuForward:
            if selectedInSession.count == 1, let accountID = currentAccount?.id { composeTarget = forwardTarget(for: selectedInSession[0], accountID: accountID, session: session) }
        case .menuArchive:
            selectedMessages = []
            moveOrDelete(session: session, items: selectedInSession.map { (uid: $0.uid, mailbox: $0.mailbox) }, to: session.folderName(for: "archive", fallback: "Archive"))
        case .menuDelete:
            selectedMessages = []
            moveOrDelete(session: session, items: selectedInSession.map { (uid: $0.uid, mailbox: $0.mailbox) }, to: session.folderName(for: "trash", fallback: "Trash"))
        case .menuMoveToJunk:
            selectedMessages = []
            moveOrDelete(session: session, items: selectedInSession.map { (uid: $0.uid, mailbox: $0.mailbox) }, to: session.folderName(for: "junk", fallback: "Spam"))
        case .menuToggleUnread:
            if let first = selectedInSession.first {
                session.toggleUnreadForMessages(items: selectedInSession.map { (uid: $0.uid, mailbox: $0.mailbox) }, markAsUnread: first.isSeen) { }
            }
        case .menuSyncNow:
            session.syncNow()
        case .menuShowShortcutsHelp:
            showShortcutsHelp = true
        default:
            break
        }
    }

    private func handleMenuNotificationForAllMessages(_ notification: Notification) {
        guard let accountMessage = selectedAccountMessage,
              let session = sessionManager.session(for: accountMessage.accountID) else {
            // No cross-account message selected - only these two make
            // sense with nothing selected.
            switch notification.name {
            case .menuComposeNewMessage:
                let newMessageFrom = accountsStore.accounts.first?.email ?? ""
                composeTarget = ComposeTarget(from: newMessageFrom, to: "", cc: "", subject: "", body: signatureBlock(for: newMessageFrom), sentFolder: "Sent")
            case .menuSyncNow:
                syncAllSessions()
            case .menuShowShortcutsHelp:
                showShortcutsHelp = true
            default:
                break
            }
            return
        }
        let message = accountMessage.message
        switch notification.name {
        case .menuComposeNewMessage:
            let newMessageFrom = accountsStore.accounts.first?.email ?? ""
            composeTarget = ComposeTarget(from: newMessageFrom, to: "", cc: "", subject: "", body: signatureBlock(for: newMessageFrom), sentFolder: session.folderName(for: "sent", fallback: "Sent"))
        case .menuReply:
            composeTarget = replyTarget(for: message, replyAll: false, accountID: accountMessage.accountID, session: session)
        case .menuReplyAll:
            composeTarget = replyTarget(for: message, replyAll: true, accountID: accountMessage.accountID, session: session)
        case .menuForward:
            composeTarget = forwardTarget(for: message, accountID: accountMessage.accountID, session: session)
        case .menuArchive:
            selectedAccountMessage = nil
            moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "archive", fallback: "Archive"))
        case .menuDelete:
            selectedAccountMessage = nil
            moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "trash", fallback: "Trash"))
        case .menuMoveToJunk:
            selectedAccountMessage = nil
            moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "junk", fallback: "Spam"))
        case .menuToggleUnread:
            session.toggleUnreadForMessages(items: [(uid: message.uid, mailbox: message.mailbox)], markAsUnread: message.isSeen) { }
        case .menuSyncNow:
            syncAllSessions()
        case .menuShowShortcutsHelp:
            showShortcutsHelp = true
        default:
            break
        }
    }
}

/// The merged, genuinely cross-account view - Inbox+Archive+Sent pulled
/// from every configured account at once, not just the first. Scoped
/// deliberately smaller than MailboxContentColumn: single-message
/// selection only (no multi-select bulk actions spanning different
/// accounts at once), no drag-and-drop between accounts, no search - each
/// judged not essential for a first version, and each addable later
/// without disturbing this shape. Reply/Forward/Archive/Delete/Mark as
/// Read all work directly on whichever message is selected, correctly
/// routed to that message's own account.
struct AllMessagesColumn: View {
    @ObservedObject var sessionManager: AccountSessionManager
    @ObservedObject var multiSessionObserver: MultiSessionObserver
    @ObservedObject var accountsStore: AccountsStore
    @ObservedObject var outbox: OutboxManager
    @Binding var selectedAccountMessage: AccountMessage?
    @Binding var composeTarget: ContentView.ComposeTarget?
    @Binding var redirectTarget: ContentView.RedirectTarget?
    let onReply: (AccountMessage) -> Void
    let onReplyAll: (AccountMessage) -> Void
    let onForward: (AccountMessage) -> Void
    let onComposeNew: () -> Void
    let onSyncAllSessions: () -> Void

    @State private var sortOption: SortOption = .dateNewest
    @State private var showOutboxPopover = false

    private var displayedMessages: [AccountMessage] {
        var all: [AccountMessage] = []
        for account in accountsStore.accounts {
            guard let session = sessionManager.session(for: account.id) else { continue }
            let mailboxNames = ["INBOX", session.folderName(for: "archive", fallback: "Archive"), session.folderName(for: "sent", fallback: "Sent")]
            let messages = session.messagesForMailboxes(mailboxNames)
            all.append(contentsOf: messages.map { AccountMessage(accountID: account.id, accountDisplayName: account.displayName, message: $0) })
        }
        return sorted(all)
    }

    private func sorted(_ messages: [AccountMessage]) -> [AccountMessage] {
        switch sortOption {
        case .dateNewest: return messages.sorted { $0.message.date > $1.message.date }
        case .dateOldest: return messages.sorted { $0.message.date < $1.message.date }
        case .senderAZ: return messages.sorted { $0.message.from.localizedCaseInsensitiveCompare($1.message.from) == .orderedAscending }
        case .senderZA: return messages.sorted { $0.message.from.localizedCaseInsensitiveCompare($1.message.from) == .orderedDescending }
        case .recipientAZ: return messages.sorted { $0.message.toAlias.localizedCaseInsensitiveCompare($1.message.toAlias) == .orderedAscending }
        case .recipientZA: return messages.sorted { $0.message.toAlias.localizedCaseInsensitiveCompare($1.message.toAlias) == .orderedDescending }
        }
    }

    var body: some View {
        Group {
            if displayedMessages.isEmpty {
                Text("No messages found")
                    .foregroundStyle(.secondary)
            } else {
                List(selection: $selectedAccountMessage) {
                    ForEach(displayedMessages) { accountMessage in
                        let message = accountMessage.message
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                if message.isFlaggedSpam {
                                    Image(systemName: "exclamationmark.shield.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                }
                                Text(message.subject)
                                    .font(.headline)
                                    .fontWeight(message.isSeen ? .regular : .semibold)
                                    .lineLimit(1)
                            }
                            HStack {
                                Text(message.from)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(accountMessage.accountDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                                Text(message.date, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(accountMessage)
                        .contextMenu {
                            Button("Reply") { onReply(accountMessage) }
                            Button("Reply All") { onReplyAll(accountMessage) }
                            Button("Forward") { onForward(accountMessage) }
                            Divider()
                            if let session = sessionManager.session(for: accountMessage.accountID) {
                                Button("Archive") {
                                    moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "archive", fallback: "Archive"))
                                }
                                Button("Move to Junk") {
                                    moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "junk", fallback: "Spam"))
                                }
                                Button("Delete") {
                                    moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "trash", fallback: "Trash"))
                                }
                                Divider()
                                Button(message.isSeen ? "Mark as Unread" : "Mark as Read") {
                                    session.toggleUnreadForMessages(items: [(uid: message.uid, mailbox: message.mailbox)], markAsUnread: message.isSeen) { }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("All Messages (\(displayedMessages.count))")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onSyncAllSessions()
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Sync every account now - checks for new mail and deletions, and refreshes read/unread status")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onComposeNew()
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .help("New Message (⌘N)")
            }
            if !outbox.items.isEmpty {
                ToolbarItem(placement: .status) {
                    Button {
                        showOutboxPopover = true
                    } label: {
                        let sendingCount = outbox.items.filter { $0.status == .sending }.count
                        let failedCount = outbox.items.filter { if case .failed = $0.status { return true }; return false }.count
                        if failedCount > 0 {
                            Label("\(failedCount) failed to send", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        } else if sendingCount > 0 {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Sending \(sendingCount)…")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showOutboxPopover) {
                        Text("Outbox").font(.headline).padding()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort messages by date, sender, or recipient")
            }
        }
    }
}

/// The message list, search, and toolbar for whichever mailbox/smart
/// folder is currently selected - holds a direct @ObservedObject
/// reference to the active session, the same proven pattern
/// MessageDetailView already used correctly. This is the fix for a real,
/// subtle bug: AccountSessionManager.sessions is a @Published dictionary,
/// but SwiftUI only observes changes to the dictionary itself (a session
/// added/removed) - it does NOT propagate when a MailSession *inside* that
/// dictionary changes its own @Published properties. Reading
/// session.messages through a plain computed property (as ContentView
/// used to) meant the underlying data updated correctly but the view had
/// no reliable signal to re-render, producing a persistent "shows what I
/// selected previously" symptom. A direct @ObservedObject here fixes that
/// at the source, for whichever session is actually active.
struct MailboxContentColumn: View {
    @ObservedObject var session: MailSession
    @ObservedObject var accountsStore: AccountsStore
    @ObservedObject var outbox: OutboxManager
    @Binding var selectedMessages: Set<Message.ID>
    @Binding var composeTarget: ContentView.ComposeTarget?
    @Binding var redirectTarget: ContentView.RedirectTarget?
    @Binding var searchQuery: String
    @Binding var sortOption: SortOption
    @Binding var showEmptyTrashConfirm: Bool
    let sidebarSelection: SidebarSelection?
    let currentAccount: Account
    let mailboxes: [(role: String, name: String, label: String, icon: String)]
    let allMessagesMailboxes: [String]
    let onReply: (Message) -> Void
    let onReplyAll: (Message) -> Void
    let onForward: (Message) -> Void
    let onComposeNew: () -> Void
    let onSyncAllSessions: () -> Void

    @State private var showOutboxPopover = false

    private var displayedMessages: [Message] {
        let base: [Message]
        if let searchResults = session.searchResults {
            base = searchResults
        } else if case .allMessages = sidebarSelection {
            base = session.messagesForMailboxes(allMessagesMailboxes)
        } else if case .smartFolder(_, let id) = sidebarSelection,
                  let folder = session.smartFolders.first(where: { $0.id == id }) {
            base = session.messagesForSmartFolder(folder)
        } else {
            base = session.messages
        }
        return sorted(base)
    }

    private func sorted(_ messages: [Message]) -> [Message] {
        switch sortOption {
        case .dateNewest: return messages.sorted { $0.date > $1.date }
        case .dateOldest: return messages.sorted { $0.date < $1.date }
        case .senderAZ: return messages.sorted { $0.from.localizedCaseInsensitiveCompare($1.from) == .orderedAscending }
        case .senderZA: return messages.sorted { $0.from.localizedCaseInsensitiveCompare($1.from) == .orderedDescending }
        case .recipientAZ: return messages.sorted { $0.toAlias.localizedCaseInsensitiveCompare($1.toAlias) == .orderedAscending }
        case .recipientZA: return messages.sorted { $0.toAlias.localizedCaseInsensitiveCompare($1.toAlias) == .orderedDescending }
        }
    }

    private var currentMailboxLabel: String {
        mailboxes.first(where: { $0.name == session.currentMailbox })?.label ?? session.currentMailbox
    }

    private var contentTitle: String {
        if session.searchResults != nil {
            return "Search Results (\(displayedMessages.count))"
        }
        if case .allMessages = sidebarSelection {
            return "All Messages (\(displayedMessages.count))"
        }
        if case .smartFolder(_, let id) = sidebarSelection,
           let folder = session.smartFolders.first(where: { $0.id == id }) {
            return "\(folder.name) (\(displayedMessages.count))"
        }
        return "\(currentMailboxLabel) (\(displayedMessages.count))"
    }

    private var selectedMessageObjects: [Message] {
        displayedMessages.filter { selectedMessages.contains($0.id) }
    }

    private func performMove(to destinationMailbox: String) {
        let objects = selectedMessageObjects
        guard !objects.isEmpty else { return }
        selectedMessages = []
        moveOrDelete(session: session, items: objects.map { (uid: $0.uid, mailbox: $0.mailbox) }, to: destinationMailbox)
    }

    private func performToggleUnread() {
        let objects = selectedMessageObjects
        guard let first = objects.first else { return }
        let items = objects.map { (uid: $0.uid, mailbox: $0.mailbox) }
        session.toggleUnreadForMessages(items: items, markAsUnread: first.isSeen) { }
    }

    var body: some View {
        Group {
            if displayedMessages.isEmpty {
                Text(session.searchResults != nil ? "No matching messages" : "No messages found")
                    .foregroundStyle(.secondary)
            } else {
                List(displayedMessages, selection: $selectedMessages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if message.isFlaggedSpam {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                    .help("Flagged as spam by the server's own filter" + (message.spamScore.map { " (score: \(String(format: "%.1f", $0)))" } ?? ""))
                            }
                            Text(message.subject)
                                .font(.headline)
                                .fontWeight(message.isSeen ? .regular : .semibold)
                                .lineLimit(1)
                        }
                        HStack {
                            Text(message.from)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(message.date, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(message.id)
                    .draggable(message.id)
                    .contextMenu {
                        Button("Reply") { onReply(message) }
                        Button("Reply All") { onReplyAll(message) }
                        Button("Forward") { onForward(message) }
                        Divider()
                        Button("Archive") {
                            moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "archive", fallback: "Archive"))
                        }
                        Button("Move to Junk") {
                            moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "junk", fallback: "Spam"))
                        }
                        Button("Delete") {
                            moveOrDelete(session: session, items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "trash", fallback: "Trash"))
                        }
                        Divider()
                        Button(message.isSeen ? "Mark as Unread" : "Mark as Read") {
                            session.toggleUnreadForMessages(
                                items: [(uid: message.uid, mailbox: message.mailbox)],
                                markAsUnread: message.isSeen
                            ) { }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search \(currentMailboxLabel)")
        .onSubmit(of: .search) {
            session.search(query: searchQuery)
        }
        .onChange(of: searchQuery) { _, newValue in
            if newValue.isEmpty { session.clearSearch() }
        }
        .navigationTitle(contentTitle)
        .toolbar {
            ToolbarItem(placement: .status) {
                connectionStatusView
            }
            if !outbox.items.isEmpty {
                ToolbarItem(placement: .status) {
                    outboxIndicator
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.syncNow()
                } label: {
                    if session.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .help("Sync this mailbox now - checks for new mail and deletions, and refreshes read/unread status")
                .disabled(session.connectionState != .ready || session.isSyncing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onComposeNew()
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .help("New Message (⌘N)")
                // Cmd+N is owned by the real menu bar now (MailAppApp.swift's
                // CommandGroup replacing .newItem) - declaring it here too
                // would risk a double-registration conflict.
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort messages by date, sender, or recipient")
            }
            if session.currentMailbox == session.folderName(for: "trash", fallback: "Trash"),
               sidebarSelection == .mailbox(accountID: currentAccount.id, name: session.folderName(for: "trash", fallback: "Trash")) {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showEmptyTrashConfirm = true
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                    .disabled(session.messages.isEmpty)
                    .help("Permanently delete everything in Trash - this cannot be undone")
                }
            }
        }
        .confirmationDialog(
            "Permanently delete all messages in Trash?",
            isPresented: $showEmptyTrashConfirm,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                session.emptyTrash(mailbox: session.folderName(for: "trash", fallback: "Trash")) { _ in }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var outboxIndicator: some View {
        Button {
            showOutboxPopover = true
        } label: {
            let sendingCount = outbox.items.filter { $0.status == .sending }.count
            let failedCount = outbox.items.filter { if case .failed = $0.status { return true }; return false }.count
            if failedCount > 0 {
                Label("\(failedCount) failed to send", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if sendingCount > 0 {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Sending \(sendingCount)…")
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showOutboxPopover) {
            outboxPopoverContent
        }
    }

    private var outboxPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outbox")
                .font(.headline)
                .padding()

            if outbox.items.isEmpty {
                Text("Nothing pending.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(outbox.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            statusIcon(for: item.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.subjectPreview).font(.subheadline).lineLimit(1)
                                Text("To: \(item.toPreview)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if case .failed = item.status {
                                Button("Retry") { outbox.retry(item) }
                                    .controlSize(.small)
                            }
                            Button {
                                outbox.dismissItem(item)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        if case .failed(let errorText) = item.status {
                            Text(errorText)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
        .frame(width: 340)
    }

    @ViewBuilder
    private func statusIcon(for status: OutboxManager.OutboxItem.Status) -> some View {
        switch status {
        case .sending:
            ProgressView().controlSize(.small)
        case .sent:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch session.connectionState {
        case .disconnected:
            if session.isManuallyOffline {
                Button {
                    session.goOnline()
                } label: {
                    Label("Offline (tap to reconnect)", systemImage: "airplane")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("You went offline deliberately - tap to reconnect")
            } else {
                Button {
                    onSyncAllSessions()
                } label: {
                    Label("Offline - tap to retry", systemImage: "wifi.slash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(session.lastError ?? "Not connected")
            }
        case .connecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
            }
        case .ready:
            Button {
                session.goOffline()
            } label: {
                Label("Connected", systemImage: "checkmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .help("Tap to go offline")
        }
    }
}

/// Sheet for creating or editing a smart folder: name, one or more
/// conditions (each targeting From/To/Subject with contains/does-not-contain,
/// always case-insensitive) combined with Any (OR) or All (AND), and which
/// real mailboxes to watch. `existingFolder` nil means create mode;
/// otherwise the form is pre-filled and Save updates it in place.
struct SmartFolderFormView: View {
    @ObservedObject var session: MailSession
    @Environment(\.dismiss) private var dismiss

    let existingFolder: SmartFolder?

    @State private var name: String
    @State private var matchType: String
    @State private var conditions: [SmartFolderCondition]
    @State private var includeInbox: Bool
    @State private var includeArchive: Bool
    @State private var includeSent: Bool
    @State private var includeSpam: Bool
    @State private var includeTrash: Bool

    init(session: MailSession, existingFolder: SmartFolder?) {
        self.session = session
        self.existingFolder = existingFolder

        _name = State(initialValue: existingFolder?.name ?? "")
        _matchType = State(initialValue: existingFolder?.matchType ?? "any")
        _conditions = State(initialValue: existingFolder?.conditions.isEmpty == false
            ? existingFolder!.conditions
            : [SmartFolderCondition(field: .from, value: "")])

        let mailboxes = Set(existingFolder?.mailboxList ?? ["INBOX", session.folderName(for: "archive", fallback: "Archive"), session.folderName(for: "sent", fallback: "Sent")])
        _includeInbox = State(initialValue: mailboxes.contains("INBOX"))
        _includeArchive = State(initialValue: mailboxes.contains(session.folderName(for: "archive", fallback: "Archive")))
        _includeSent = State(initialValue: mailboxes.contains(session.folderName(for: "sent", fallback: "Sent")))
        _includeSpam = State(initialValue: mailboxes.contains(session.folderName(for: "junk", fallback: "Spam")))
        _includeTrash = State(initialValue: mailboxes.contains(session.folderName(for: "trash", fallback: "Trash")))
    }

    private var hasValidConditions: Bool {
        conditions.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var hasAnyMailbox: Bool {
        includeInbox || includeArchive || includeSent || includeSpam || includeTrash
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(existingFolder == nil ? "New Smart Folder" : "Edit Smart Folder")
                .font(.title2)
                .bold()

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Match")
                    Picker("", selection: $matchType) {
                        Text("Any").tag("any")
                        Text("All").tag("all")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .labelsHidden()
                    Text("of the following:")
                    Spacer()
                }
                .font(.subheadline)

                ForEach($conditions) { $condition in
                    HStack(spacing: 8) {
                        Picker("", selection: $condition.field) {
                            ForEach(SmartFolderCondition.Field.allCases, id: \.self) { field in
                                Text(field.rawValue).tag(field)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)

                        Picker("", selection: $condition.op) {
                            ForEach(SmartFolderCondition.Operator.allCases, id: \.self) { op in
                                Text(op.rawValue).tag(op)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)

                        TextField("", text: $condition.value)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            conditions.removeAll { $0.id == condition.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(conditions.count <= 1)
                    }
                }

                Button {
                    conditions.append(SmartFolderCondition(field: .from, value: ""))
                } label: {
                    Label("Add condition", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Include messages from")
                    .font(.subheadline)
                Toggle("Inbox", isOn: $includeInbox)
                Toggle("Archive", isOn: $includeArchive)
                Toggle("Sent", isOn: $includeSent)
                Toggle("Spam", isOn: $includeSpam)
                Toggle("Trash", isOn: $includeTrash)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                Button(existingFolder == nil ? "Create" : "Save") {
                    var mailboxes: [String] = []
                    if includeInbox { mailboxes.append("INBOX") }
                    if includeArchive { mailboxes.append(session.folderName(for: "archive", fallback: "Archive")) }
                    if includeSent { mailboxes.append(session.folderName(for: "sent", fallback: "Sent")) }
                    if includeSpam { mailboxes.append(session.folderName(for: "junk", fallback: "Spam")) }
                    if includeTrash { mailboxes.append(session.folderName(for: "trash", fallback: "Trash")) }

                    if let existingFolder, let id = existingFolder.id {
                        session.updateSmartFolder(id: id, name: name, mailboxes: mailboxes, matchType: matchType, conditions: conditions)
                    } else {
                        session.createSmartFolder(name: name, mailboxes: mailboxes, matchType: matchType, conditions: conditions)
                    }
                    dismiss()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || !hasValidConditions || !hasAnyMailbox)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

/// Shown via Help → Keyboard Shortcuts - a plain, readable reference,
/// since knowing the shortcuts exist is exactly what someone unfamiliar
/// with this app (a family member, say) wouldn't otherwise have any way
/// to discover.
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let shortcuts: [(action: String, keys: String)] = [
        ("New Message", "⌘N"),
        ("Reply", "⌘R"),
        ("Reply All", "⌘⇧R"),
        ("Forward", "⌘⇧F"),
        ("Send (while composing)", "⌘Return  or  ⌘⇧S"),
        ("Attach a file (while composing)", "⌘."),
        ("Archive selected message(s)", "⌘⇧A"),
        ("Move selected message(s) to Junk", "⌘⇧J"),
        ("Delete / move to Trash", "Delete"),
        ("Mark as read / unread", "⌘⇧U"),
        ("Select all messages in this list", "⌘A"),
        ("Extend selection", "Shift-click"),
        ("Add/remove from selection", "⌘-click"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(shortcuts, id: \.action) { shortcut in
                    HStack {
                        Text(shortcut.action)
                        Spacer()
                        Text(shortcut.keys)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 420)
    }
}

/// Splits a header value like "Jane Doe <jane@x.com>, Someone <s@y.com>"
/// into bare email addresses. A pragmatic parser, not a fully RFC 5322
/// compliant one - splits on top-level commas and pulls out <...> contents
/// where present, which covers the vast majority of real-world headers.
func extractEmailAddresses(_ headerValue: String) -> [String] {
    headerValue.split(separator: ",").compactMap { part -> String? in
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: open)..<close])
        }
        return trimmed
    }
}

/// Extracts both the display name and bare email from a single "Name
/// <email>" or bare "email" header value - unlike extractEmailAddresses,
/// which only returns the email, discarding any name. Used for Add to
/// Contacts, where the name matters.
func extractNameAndEmail(_ headerValue: String) -> (name: String?, email: String) {
    let trimmed = headerValue.trimmingCharacters(in: .whitespaces)
    if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">") {
        let email = String(trimmed[trimmed.index(after: open)..<close])
        var namePart = String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        if namePart.hasPrefix("\""), namePart.hasSuffix("\""), namePart.count >= 2 {
            namePart = String(namePart.dropFirst().dropLast())
        }
        return (namePart.isEmpty ? nil : namePart, email)
    }
    return (nil, trimmed)
}

/// Renders message body text with three readability fixes over a flat
/// Text block: real paragraph spacing, a larger more legible size, and raw
/// URLs replaced with short clickable labels instead of dumping the full
/// messy tracking-link text inline.
struct MessageBodyView: View {
    let text: String

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(linkified(paragraph))
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Caps line length at 80% of the available panel width for
        // readability, and stays responsive as the window/panel resizes -
        // containerRelativeFrame rather than GeometryReader, since
        // GeometryReader inside a ScrollView tends to fight the view's
        // natural content-height sizing.
        .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in width * 0.8 }
        .textSelection(.enabled)
    }

    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func linkified(_ paragraph: String) -> AttributedString {
        guard let detector = Self.linkDetector else { return AttributedString(paragraph) }

        let nsText = paragraph as NSString
        let matches = detector.matches(in: paragraph, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return AttributedString(paragraph) }

        var result = AttributedString()
        var lastIndex = 0

        for match in matches {
            guard let url = match.url else { continue }
            let range = match.range

            if range.location > lastIndex {
                let plainText = nsText.substring(with: NSRange(location: lastIndex, length: range.location - lastIndex))
                result += AttributedString(plainText)
            }

            let label = url.host?.replacingOccurrences(of: "www.", with: "") ?? "link"
            var linkRun = AttributedString(label)
            linkRun.link = url
            linkRun.foregroundColor = .accentColor
            linkRun.underlineStyle = .single
            result += linkRun

            lastIndex = range.location + range.length
        }

        if lastIndex < nsText.length {
            result += AttributedString(nsText.substring(from: lastIndex))
        }

        return result
    }
}

/// Shows every attachment found in a message, with Open (via the default
/// app, using a temp file) and Save… (via a real save dialog) for each.
/// Decoding happens lazily per-attachment, only when actually opened/saved -
/// no need to decode every attachment's bytes just to list filenames.
struct AttachmentListView: View {
    let attachments: [MIMEPart.Attachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Attachments (\(attachments.count))")
                .font(.subheadline)
                .bold()

            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                HStack {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    Text(attachment.filename)
                    Spacer()
                    Text(sizeLabel(for: attachment))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open") { open(attachment) }
                    Button("Save…") { save(attachment) }
                }
            }
        }
    }

    private func sizeLabel(for attachment: MIMEPart.Attachment) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.part.decodedData.count), countStyle: .file)
    }

    private func open(_ attachment: MIMEPart.Attachment) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.filename)
        do {
            try attachment.part.decodedData.write(to: tempURL)
            NSWorkspace.shared.open(tempURL)
        } catch {
            print("Could not open attachment \(attachment.filename): \(error)")
        }
    }

    private func save(_ attachment: MIMEPart.Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try attachment.part.decodedData.write(to: url)
        } catch {
            print("Could not save attachment \(attachment.filename): \(error)")
        }
    }
}

/// Reading pane: checks the .eml corpus first (instant), and if not found,
/// fetches the body live from the server via the given account's
/// MailSession, caching the result to that account's own corpus directory
/// so future opens are instant too.
struct MessageDetailView: View {
    let message: Message
    let accountID: UUID
    @ObservedObject var session: MailSession
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    let onRedirect: () -> Void
    @StateObject private var contactsService = ContactsService()
    @State private var contactAddState: ContactAddState = .idle
    @State private var bodyText: String?
    @State private var attachments: [MIMEPart.Attachment] = []
    @State private var loadState: LoadState = .loading
    @State private var errorText: String?
    @State private var pgpBlock: String?
    @State private var decryptedText: String?
    @State private var isDecrypting = false
    @State private var decryptError: String?

    enum LoadState {
        case loading, found, fetchingLive, failed
    }

    enum ContactAddState {
        case idle, added, alreadyExists
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(message.subject)
                        .font(.title2)
                        .bold()
                    Spacer()
                    Button { onReply() } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    Button { onReplyAll() } label: {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    Button { onForward() } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    Button { onRedirect() } label: {
                        Label("Redirect", systemImage: "arrowshape.bounce.right")
                    }
                    Button { addSenderToContacts() } label: {
                        switch contactAddState {
                        case .idle: Label("Add to Contacts", systemImage: "person.crop.circle.badge.plus")
                        case .added: Label("Added", systemImage: "checkmark.circle.fill")
                        case .alreadyExists: Label("Already in Contacts", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    .disabled(contactAddState != .idle)
                    // Shortcuts for these now live in the real menu bar
                    // (MailAppApp.swift), which acts on whatever's selected -
                    // declaring them here too would risk a double-registration
                    // conflict. The buttons stay clickable exactly as before.
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("From: \(message.from)")
                    Text("To: \(message.toAlias)")
                    Text("Mailbox: \(message.mailbox)")
                    Text(message.date, style: .date) + Text(" ") + Text(message.date, style: .time)
                    if let score = message.spamScore {
                        HStack(spacing: 4) {
                            if message.isFlaggedSpam {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundStyle(.orange)
                            }
                            Text("Spam score: \(String(format: "%.1f", score))")
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Divider()

                switch loadState {
                case .loading:
                    ProgressView()
                case .fetchingLive:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Fetching from server…")
                    }
                    .foregroundStyle(.secondary)
                case .found:
                    if let pgpBlock {
                        if let decryptedText {
                            MessageBodyView(text: decryptedText)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.secondary)
                                    Text("This message is PGP-encrypted")
                                        .font(.subheadline)
                                }
                                if isDecrypting {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Decrypting…")
                                    }
                                    .foregroundStyle(.secondary)
                                } else {
                                    Button("Decrypt") {
                                        decryptPGP(pgpBlock)
                                    }
                                }
                                if let decryptError {
                                    Text(decryptError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(12)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        MessageBodyView(text: bodyText ?? "")
                    }
                    if !attachments.isEmpty {
                        AttachmentListView(attachments: attachments)
                    }
                case .failed:
                    Text("Couldn't load this message: \(errorText ?? "unknown error")")
                        .foregroundStyle(.red)
                        .italic()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: message.id) {
            contactAddState = .idle
            pgpBlock = nil
            decryptedText = nil
            isDecrypting = false
            decryptError = nil
            loadBody()
        }
        .task {
            contactsService.requestAccessIfNeeded()
        }
    }

    /// Each account has its own separate .eml cache folder now, hence
    /// needing accountID to find the right one.
    private var corpusFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eml-corpus-\(accountID.uuidString)")
            .appendingPathComponent("\(message.mailbox)-\(message.uid).eml")
    }

    private func loadBody() {
        loadState = .loading

        if let raw = try? String(contentsOf: corpusFileURL, encoding: .utf8) {
            displayParsed(raw)
            return
        }

        guard session.connectionState == .ready else {
            loadState = .failed
            errorText = "Not connected to the server yet."
            return
        }

        loadState = .fetchingLive
        session.fetchBody(uid: message.uid, mailbox: message.mailbox) { result in
            switch result {
            case .success(let raw):
                try? FileManager.default.createDirectory(
                    at: corpusFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? raw.write(to: corpusFileURL, atomically: true, encoding: .utf8)
                displayParsed(raw)
            case .failure(let error):
                loadState = .failed
                errorText = "\(error)"
            }
        }
    }

    private func addSenderToContacts() {
        let (name, email) = extractNameAndEmail(message.from)
        Task {
            if await contactsService.contactExists(withEmail: email) {
                contactAddState = .alreadyExists
                return
            }
            let success = await contactsService.addContact(name: name, email: email)
            contactAddState = success ? .added : .idle
        }
    }

    private func displayParsed(_ raw: String) {
        let parsed = MIMEParser.parse(raw)
        bodyText = parsed.bestReadableBody() ?? "(No readable body found in this message.)"
        attachments = parsed.findAttachments()
        pgpBlock = parsed.pgpEncryptedBlock
        loadState = .found

        // Opening a message marks it read - standard mail client behaviour,
        // and the piece that makes the unread/read distinction actually
        // mean something day to day rather than just being decorative.
        if !message.isSeen {
            session.toggleUnread(uid: message.uid, in: message.mailbox, markAsUnread: false) { _ in }
        }
    }

    private func decryptPGP(_ block: String) {
        isDecrypting = true
        decryptError = nil
        Task {
            do {
                decryptedText = try await GPGService.decrypt(block)
            } catch {
                decryptError = error.localizedDescription
            }
            isDecrypting = false
        }
    }
}
