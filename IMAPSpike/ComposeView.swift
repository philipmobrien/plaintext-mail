import SwiftUI
import GRDB
import AppKit
import UniformTypeIdentifiers

struct ComposeView: View {
    @ObservedObject var outbox: OutboxManager
    @ObservedObject var accountsStore: AccountsStore
    @Environment(\.dismiss) private var dismiss

    let sentFolder: String
    @State private var from: String
    @State private var to: String
    @State private var cc: String
    @State private var subject: String
    @State private var messageBody: String
    @State private var aliasOptions: [String] = []
    @State private var attachments: [ComposeAttachment] = []
    @State private var isDropTargeted = false
    @StateObject private var contactsService = ContactsService()
    @State private var toSuggestions: [ContactsService.ContactMatch] = []
    @State private var ccSuggestions: [ContactsService.ContactMatch] = []

    init(outbox: OutboxManager, accountsStore: AccountsStore, from: String, to: String = "", cc: String = "", subject: String = "", messageBody: String = "", sentFolder: String) {
        self.outbox = outbox
        self.accountsStore = accountsStore
        self.sentFolder = sentFolder
        _from = State(initialValue: from)
        _to = State(initialValue: to)
        _cc = State(initialValue: cc)
        _subject = State(initialValue: subject)
        _messageBody = State(initialValue: messageBody)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    Text("From:").frame(width: 60, alignment: .trailing)
                    Picker("", selection: $from) {
                        ForEach(aliasOptions, id: \.self) { alias in
                            Text(alias).tag(alias)
                        }
                    }
                    .labelsHidden()
                }
                HStack(alignment: .top) {
                    Text("To:").frame(width: 60, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 0) {
                        TextField("", text: $to)
                            .onChange(of: to) { _, newValue in
                                let token = currentToken(in: newValue)
                                guard token.count >= 2 else { toSuggestions = []; return }
                                Task {
                                    let results = await contactsService.search(token)
                                    // Discard if the field moved on while this search was running.
                                    if currentToken(in: to) == token {
                                        toSuggestions = results
                                    }
                                }
                            }
                        if !toSuggestions.isEmpty {
                            suggestionList(toSuggestions) { match in
                                to = inserting(match, into: to)
                                toSuggestions = []
                            }
                        }
                    }
                }
                HStack(alignment: .top) {
                    Text("Cc:").frame(width: 60, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 0) {
                        TextField("", text: $cc)
                            .onChange(of: cc) { _, newValue in
                                let token = currentToken(in: newValue)
                                guard token.count >= 2 else { ccSuggestions = []; return }
                                Task {
                                    let results = await contactsService.search(token)
                                    if currentToken(in: cc) == token {
                                        ccSuggestions = results
                                    }
                                }
                            }
                        if !ccSuggestions.isEmpty {
                            suggestionList(ccSuggestions) { match in
                                cc = inserting(match, into: cc)
                                ccSuggestions = []
                            }
                        }
                    }
                }
                HStack {
                    Text("Subject:").frame(width: 60, alignment: .trailing)
                    TextField("", text: $subject)
                }
            }
            .padding([.horizontal, .top])

            // A dedicated drop zone, always visible, deliberately separate
            // from the TextEditor below. TextEditor wraps a real NSTextView,
            // which has its own built-in drag-and-drop handling (treats a
            // dropped file as "insert as text") that wins over SwiftUI's
            // .dropDestination when both are attached to the same view -
            // same root cause as TextEditor swallowing keyboard shortcuts
            // earlier. Giving the drop target its own space that never
            // overlaps the NSTextView sidesteps the conflict entirely.
            Divider()
            attachmentDropZone

            Divider()

            TextEditor(text: $messageBody)
                .font(.system(.body, design: .monospaced))
                .padding(8)

            Divider()

            HStack {
                Button {
                    pickAttachments()
                } label: {
                    Image(systemName: "paperclip")
                }
                .help("Attach files (⌘.)")

                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") {
                    send()
                }
                .disabled(to.isEmpty || subject.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 450)
        .navigationTitle("New Message")
        .task {
            loadAliasOptions()
            contactsService.requestAccessIfNeeded()
        }
        // TextEditor (an NSTextView under the hood) swallows most keyboard
        // shortcuts - including Cmd-modified ones - before a sibling
        // Button's .keyboardShortcut ever sees them. Intercepting here, one
        // level up in the view hierarchy, is what actually works reliably.
        // Cmd+Return is the de-facto standard "send" shortcut in any
        // multi-line composer (Slack, Messages, etc) for exactly this
        // reason - plain Return has to stay newline. Cmd+Shift+S kept too,
        // for MailMate muscle memory. Cmd+. opens the attachment picker,
        // same reasoning.
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if !to.isEmpty && !subject.isEmpty { send() }
            return .handled
        }
        .onKeyPress(KeyEquivalent("s"), phases: .down) { press in
            guard press.modifiers.isSuperset(of: [.command, .shift]) else { return .ignored }
            if !to.isEmpty && !subject.isEmpty { send() }
            return .handled
        }
        .onKeyPress(KeyEquivalent("."), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            pickAttachments()
            return .handled
        }
    }

    private var attachmentDropZone: some View {
        HStack(spacing: 8) {
            if attachments.isEmpty {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                Text("Drop files here to attach, or use the paperclip / ⌘.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                    .font(.caption)
                                Text(attachment.filename)
                                    .font(.caption)
                                    .lineLimit(1)
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [4]))
                .padding(2)
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                if let attachment = try? ComposeAttachment(url: url) {
                    attachments.append(attachment)
                }
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    /// The recipient field being edited holds comma-separated addresses -
    /// only the segment after the last comma is what's actively being
    /// typed, so that's what gets matched against Contacts, not the whole
    /// field (which may already contain complete addresses).
    private func currentToken(in text: String) -> String {
        let segments = text.split(separator: ",", omittingEmptySubsequences: false)
        return segments.last?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Replaces just the in-progress last segment with the chosen contact,
    /// leaving any already-complete addresses before it untouched.
    private func inserting(_ match: ContactsService.ContactMatch, into text: String) -> String {
        var segments = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if !segments.isEmpty { segments.removeLast() }
        segments.append("\(match.displayName) <\(match.email)>")
        return segments.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }

    @ViewBuilder
    private func suggestionList(_ matches: [ContactsService.ContactMatch], onSelect: @escaping (ContactsService.ContactMatch) -> Void) -> some View {
        // Scrollable rather than a hard cutoff - a common surname can
        // easily have more matches than fit on screen at once, and an
        // arbitrary truncation to a handful risks hiding the actual person
        // being searched for.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches) { match in
                    Button {
                        onSelect(match)
                    } label: {
                        HStack {
                            Text(match.displayName)
                            Text(match.email)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let attachment = try? ComposeAttachment(url: url) {
                attachments.append(attachment)
            }
        }
    }

    /// From options are now derived from real configured accounts rather
    /// than a hardcoded list - scales naturally as more accounts get added.
    /// `from`'s initial value (e.g. from alias-aware reply defaulting) is
    /// included even if it doesn't exactly match a configured account yet,
    /// so the picker never silently drops the value it was opened with.
    private func loadAliasOptions() {
        var options = Set(accountsStore.accounts.map { $0.email })
        options.insert(from)
        aliasOptions = options.sorted()
    }

    private func send() {
        // Finds the account matching the selected From address; falls back
        // to the first configured account if none matches exactly (e.g.
        // reply/forward's alias-defaulting logic hasn't yet been made fully
        // account-aware - a later stage's job, not this one's).
        guard let account = accountsStore.accounts.first(where: { $0.email == from }) ?? accountsStore.accounts.first,
              let password = accountsStore.password(for: account) else { return }

        outbox.enqueue(
            accountID: account.id,
            imapHost: account.imapHost, imapPort: account.imapPort,
            smtpHost: account.smtpHost, smtpPort: account.smtpPort,
            user: account.email, password: password,
            sentFolder: sentFolder,
            from: from, to: to, cc: cc, subject: subject, markdownBody: messageBody,
            attachments: attachments
        )
        dismiss()
    }
}
