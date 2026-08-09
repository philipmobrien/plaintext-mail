import SwiftUI
import GRDB
import AppKit
import Combine

/// What's currently selected in the sidebar - either a real IMAP mailbox
/// or a locally-defined smart folder. Needed because they behave quite
/// differently: selecting a mailbox does a real IMAP SELECT + sync,
/// selecting a smart folder just runs a local SQL query across whichever
/// mailboxes it watches.
enum SidebarSelection: Hashable {
    case allMessages
    case mailbox(String)
    case smartFolder(Int64)
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

struct ContentView: View {
    @StateObject private var session = MailSession()
    @StateObject private var accountsStore = AccountsStore()
    @StateObject private var outbox = OutboxManager()
    @State private var selectedMessages: Set<Message.ID> = []
    @State private var composeTarget: ComposeTarget?
    @State private var sidebarSelection: SidebarSelection? = .mailbox("INBOX")
    @State private var showEmptyTrashConfirm = false
    @State private var searchQuery = ""
    @State private var smartFolderSheetTarget: SmartFolderSheetTarget?
    @State private var sortOption: SortOption = .dateNewest
    @State private var showShortcutsHelp = false
    @State private var dropTargetedMailbox: String?

    enum SmartFolderSheetTarget: Identifiable {
        case new
        case edit(SmartFolder)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let f): return "edit-\(f.id ?? -1)"
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

    /// Real folder names via discovery, falling back to Runbox's own naming
    /// until discovery completes (or if it ever fails) - identical to the
    /// old hardcoded values for Runbox specifically, so nothing changes
    /// visually for that account, but genuinely correct for any other.
    private var mailboxes: [(role: String, name: String, label: String, icon: String)] {
        [
            (role: "inbox", name: "INBOX", label: "Inbox", icon: "tray"),
            (role: "sent", name: session.folderName(for: "sent", fallback: "Sent"), label: "Sent", icon: "paperplane"),
            (role: "archive", name: session.folderName(for: "archive", fallback: "Archive"), label: "Archive", icon: "archivebox"),
            (role: "junk", name: session.folderName(for: "junk", fallback: "Spam"), label: "Spam", icon: "nosign"),
            (role: "trash", name: session.folderName(for: "trash", fallback: "Trash"), label: "Trash", icon: "trash"),
        ]
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
                Section("Mailboxes") {
                    ForEach(mailboxes, id: \.role) { mailbox in
                        Label(mailbox.label, systemImage: mailbox.icon)
                            .tag(SidebarSelection.mailbox(mailbox.name))
                            .listRowBackground(
                                dropTargetedMailbox == mailbox.name ? Color.accentColor.opacity(0.2) : nil
                            )
                            .dropDestination(for: String.self) { ids, _ in
                                handleDrop(ids: ids, to: mailbox.name)
                                return true
                            } isTargeted: { targeted in
                                dropTargetedMailbox = targeted ? mailbox.name : nil
                            }
                    }
                }
                Section("Smart Folders") {
                    ForEach(session.smartFolders) { folder in
                        Label(folder.name, systemImage: "gearshape.2")
                            .tag(SidebarSelection.smartFolder(folder.id ?? -1))
                            .contextMenu {
                                Button("Edit…") {
                                    smartFolderSheetTarget = .edit(folder)
                                }
                                Button("Delete", role: .destructive) {
                                    session.deleteSmartFolder(folder)
                                    if sidebarSelection == .smartFolder(folder.id ?? -1) {
                                        sidebarSelection = .mailbox("INBOX")
                                    }
                                }
                            }
                    }
                    Button {
                        smartFolderSheetTarget = .new
                    } label: {
                        Label("New Smart Folder…", systemImage: "plus")
                    }
                }
            }
            .onChange(of: sidebarSelection) { _, newValue in
                selectedMessages = []
                searchQuery = ""
                session.clearSearch()
                switch newValue {
                case .mailbox(let name):
                    session.selectMailbox(name)
                case .allMessages:
                    session.syncMultipleMailboxes(allMessagesMailboxes) { }
                case .smartFolder, .none:
                    break
                }
            }
            .navigationTitle("Mailboxes")
            .sheet(item: $smartFolderSheetTarget) { target in
                switch target {
                case .new:
                    SmartFolderFormView(session: session, existingFolder: nil)
                case .edit(let folder):
                    SmartFolderFormView(session: session, existingFolder: folder)
                }
            }
        } content: {
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
                                        .help("Flagged as spam by Runbox's own filter" + (message.spamScore.map { " (score: \(String(format: "%.1f", $0)))" } ?? ""))
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
                            Button("Reply") { composeTarget = replyTarget(for: message, replyAll: false) }
                            Button("Reply All") { composeTarget = replyTarget(for: message, replyAll: true) }
                            Button("Forward") { composeTarget = forwardTarget(for: message) }
                            Divider()
                            Button("Archive") {
                                moveOrDelete(items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "archive", fallback: "Archive"))
                            }
                            Button("Move to Junk") {
                                moveOrDelete(items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "junk", fallback: "Spam"))
                            }
                            Button("Delete") {
                                moveOrDelete(items: [(uid: message.uid, mailbox: message.mailbox)], to: session.folderName(for: "trash", fallback: "Trash"))
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
                    .disabled(session.connectionState != .ready || session.isSyncing)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        composeTarget = ComposeTarget(from: accountsStore.accounts.first?.email ?? "", to: "", cc: "", subject: "", body: "", sentFolder: session.folderName(for: "sent", fallback: "Sent"))
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
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
                }
                let trashFolder = session.folderName(for: "trash", fallback: "Trash")
                if session.currentMailbox == trashFolder, sidebarSelection == .mailbox(trashFolder) {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) {
                            showEmptyTrashConfirm = true
                        } label: {
                            Label("Empty Trash", systemImage: "trash.slash")
                        }
                        .disabled(session.messages.isEmpty)
                    }
                }
            }
            .confirmationDialog(
                "Permanently delete all \(session.messages.count) message(s) in Trash?",
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
            .sheet(item: $composeTarget) { target in
                ComposeView(outbox: outbox, accountsStore: accountsStore, from: target.from, to: target.to, cc: target.cc, subject: target.subject, messageBody: target.body, sentFolder: target.sentFolder)
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
            .sheet(isPresented: $showShortcutsHelp) {
                ShortcutsHelpView()
            }
            .task {
                session.loadSmartFolders()
                connectSession()
            }
        } detail: {
            if selectedMessages.count == 1, let id = selectedMessages.first,
               let message = displayedMessages.first(where: { $0.id == id }) {
                MessageDetailView(
                    message: message,
                    session: session,
                    onReply: { composeTarget = replyTarget(for: message, replyAll: false) },
                    onReplyAll: { composeTarget = replyTarget(for: message, replyAll: true) },
                    onForward: { composeTarget = forwardTarget(for: message) }
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

    // MARK: - Search / display helpers

    /// Smart folder results (local query) when a smart folder is selected,
    /// search results when a search is active, otherwise the normal
    /// mailbox list.
    private var allMessagesMailboxes: [String] {
        ["INBOX", session.folderName(for: "archive", fallback: "Archive"), session.folderName(for: "sent", fallback: "Sent")]
    }

    /// Search results take priority whenever a search is active, regardless
    /// of what's selected in the sidebar - otherwise a search performed
    /// while a smart folder happened to be open would be silently
    /// discarded in favour of the smart folder's own contents. Sort is
    /// applied last, uniformly, regardless of which of these sources fed
    /// the list.
    private var displayedMessages: [Message] {
        let base: [Message]
        if let searchResults = session.searchResults {
            base = searchResults
        } else if case .allMessages = sidebarSelection {
            base = session.messagesForMailboxes(allMessagesMailboxes)
        } else if case .smartFolder(let id) = sidebarSelection,
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
        if case .smartFolder(let id) = sidebarSelection,
           let folder = session.smartFolders.first(where: { $0.id == id }) {
            return "\(folder.name) (\(displayedMessages.count))"
        }
        return "\(currentMailboxLabel) (\(displayedMessages.count))"
    }

    // MARK: - Menu bar bridge

    /// All nine menu-triggered notifications merged into one publisher,
    /// rather than nine separate .onReceive calls in body - see the comment
    /// at the call site for why that mattered.
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
        switch notification.name {
        case .menuComposeNewMessage:
            composeTarget = ComposeTarget(from: accountsStore.accounts.first?.email ?? "", to: "", cc: "", subject: "", body: "", sentFolder: session.folderName(for: "sent", fallback: "Sent"))
        case .menuReply:
            if let message = selectedSingleMessage { composeTarget = replyTarget(for: message, replyAll: false) }
        case .menuReplyAll:
            if let message = selectedSingleMessage { composeTarget = replyTarget(for: message, replyAll: true) }
        case .menuForward:
            if let message = selectedSingleMessage { composeTarget = forwardTarget(for: message) }
        case .menuArchive:
            performMove(to: session.folderName(for: "archive", fallback: "Archive"))
        case .menuDelete:
            performMove(to: session.folderName(for: "trash", fallback: "Trash"))
        case .menuMoveToJunk:
            performMove(to: session.folderName(for: "junk", fallback: "Spam"))
        case .menuToggleUnread:
            performToggleUnread()
        case .menuSyncNow:
            session.syncNow()
        case .menuShowShortcutsHelp:
            showShortcutsHelp = true
        default:
            break
        }
    }

    // MARK: - Keyboard-shortcut actions

    private var selectedMessageObjects: [Message] {
        displayedMessages.filter { selectedMessages.contains($0.id) }
    }

    /// Used by menu-triggered Reply/Reply All/Forward, which - like their
    /// button equivalents in MessageDetailView - only make sense against a
    /// single selected message. nil (silently no-op) when zero or more than
    /// one message is selected.
    private var selectedSingleMessage: Message? {
        guard selectedMessages.count == 1 else { return nil }
        return selectedMessageObjects.first
    }

    /// Shared by keyboard/menu actions and drag-and-drop: moves items to a
    /// destination mailbox, except when everything's already sitting in
    /// Trash and the destination IS Trash - that's a permanent delete
    /// (moving Trash to itself is rejected as a no-op by IMAP anyway).
    private func moveOrDelete(items: [(uid: Int, mailbox: String)], to destinationMailbox: String) {
        guard !items.isEmpty else { return }
        let trashFolder = session.folderName(for: "trash", fallback: "Trash")
        if destinationMailbox == trashFolder, items.allSatisfy({ $0.mailbox == trashFolder }) {
            session.permanentlyDeleteMessages(uids: items.map { $0.uid }) { _ in }
        } else {
            session.moveMessages(items: items, to: destinationMailbox) { }
        }
    }

    private func performMove(to destinationMailbox: String) {
        let objects = selectedMessageObjects
        guard !objects.isEmpty else { return }
        selectedMessages = []
        moveOrDelete(items: objects.map { (uid: $0.uid, mailbox: $0.mailbox) }, to: destinationMailbox)
    }

    /// Parses the "mailbox|uid" id strings dragged from the message list
    /// and moves them to wherever they were dropped.
    private func handleDrop(ids: [String], to destinationMailbox: String) {
        let items: [(uid: Int, mailbox: String)] = ids.compactMap { idString in
            let parts = idString.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let uid = Int(parts[1]) else { return nil }
            return (uid: uid, mailbox: String(parts[0]))
        }
        for item in items {
            selectedMessages.remove("\(item.mailbox)|\(item.uid)")
        }
        moveOrDelete(items: items, to: destinationMailbox)
    }

    private func performToggleUnread() {
        let objects = selectedMessageObjects
        guard let first = objects.first else { return }
        let markAsUnread = first.isSeen
        let items = objects.map { (uid: $0.uid, mailbox: $0.mailbox) }
        session.toggleUnreadForMessages(items: items, markAsUnread: markAsUnread) { }
    }

    // MARK: - Compose target construction

    private func replyTarget(for message: Message, replyAll: Bool) -> ComposeTarget {
        let isSent = message.mailbox == session.folderName(for: "sent", fallback: "Sent")
        let fromDefault = isSent ? message.from : message.toAlias
        let toDefault = isSent ? message.toAlias : message.from

        var cc = ""
        if replyAll, let raw = cachedRawMessage(for: message) {
            let parsed = MIMEParser.parse(raw)
            let originalTo = extractEmailAddresses(parsed.header("To") ?? "")
            let originalCc = extractEmailAddresses(parsed.header("Cc") ?? "")
            let ownAliases = accountsStore.accounts.map { $0.email.lowercased() }
            let excluded = Set(ownAliases + [toDefault.lowercased()])
            let ccList = (originalTo + originalCc).filter { !excluded.contains($0.lowercased()) }
            var seen = Set<String>()
            let deduped = ccList.filter { seen.insert($0.lowercased()).inserted }
            cc = deduped.joined(separator: ", ")
        }
        return ComposeTarget(
            from: fromDefault,
            to: toDefault,
            cc: cc,
            subject: message.subject.hasPrefix("Re: ") ? message.subject : "Re: \(message.subject)",
            body: "",
            sentFolder: session.folderName(for: "sent", fallback: "Sent")
        )
    }

    private func forwardTarget(for message: Message) -> ComposeTarget {
        let isSent = message.mailbox == session.folderName(for: "sent", fallback: "Sent")
        let fromDefault = isSent ? message.from : message.toAlias

        var body = ""
        if let raw = cachedRawMessage(for: message) {
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
            body: body,
            sentFolder: session.folderName(for: "sent", fallback: "Sent")
        )
    }

    private func cachedRawMessage(for message: Message) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eml-corpus")
            .appendingPathComponent("\(message.mailbox)-\(message.uid).eml")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @State private var showOutboxPopover = false

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
                    connectSession()
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

    private func connectSession() {
        // Stage 1 bridge: connects using the first configured account.
        // Real per-account connections (one MailSession per account) come
        // in a later stage - this keeps the app functional on the new
        // multi-account foundation in the meantime.
        guard let account = accountsStore.accounts.first,
              let password = accountsStore.password(for: account) else { return }
        session.connect(host: account.imapHost, port: account.imapPort, user: account.email, password: password)
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
/// fetches the body live from the server via the shared MailSession,
/// caching the result to the corpus directory so future opens are instant too.
struct MessageDetailView: View {
    let message: Message
    @ObservedObject var session: MailSession
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    @StateObject private var contactsService = ContactsService()
    @State private var contactAddState: ContactAddState = .idle
    @State private var bodyText: String?
    @State private var attachments: [MIMEPart.Attachment] = []
    @State private var loadState: LoadState = .loading
    @State private var errorText: String?

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
                    MessageBodyView(text: bodyText ?? "")
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
            loadBody()
        }
        .task {
            contactsService.requestAccessIfNeeded()
        }
    }

    private var corpusFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eml-corpus")
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
        loadState = .found

        // Opening a message marks it read - standard mail client behaviour,
        // and the piece that makes the unread/read distinction actually
        // mean something day to day rather than just being decorative.
        if !message.isSeen {
            session.toggleUnread(uid: message.uid, in: message.mailbox, markAsUnread: false) { _ in }
        }
    }
}
