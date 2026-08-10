import SwiftUI

/// Redirect is deliberately minimal - unlike Compose, there's no body or
/// subject to edit, since the whole point is the original message passes
/// through completely untouched with Resent-* headers layered on top.
struct RedirectView: View {
    @ObservedObject var outbox: OutboxManager
    @ObservedObject var accountsStore: AccountsStore
    @Environment(\.dismiss) private var dismiss

    let originalMessage: Message
    let originalRaw: String
    let sentFolder: String

    @State private var from: String
    @State private var to = ""
    @StateObject private var contactsService = ContactsService()
    @State private var toSuggestions: [ContactsService.ContactMatch] = []

    init(outbox: OutboxManager, accountsStore: AccountsStore, originalMessage: Message, originalRaw: String, sentFolder: String, defaultFrom: String) {
        self.outbox = outbox
        self.accountsStore = accountsStore
        self.originalMessage = originalMessage
        self.originalRaw = originalRaw
        self.sentFolder = sentFolder
        _from = State(initialValue: defaultFrom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Redirect Message")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 2) {
                Text(originalMessage.subject)
                    .font(.headline)
                Text("From: \(originalMessage.from)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("From:").frame(width: 50, alignment: .trailing)
                Picker("", selection: $from) {
                    ForEach(accountsStore.accounts.map { $0.email }, id: \.self) { email in
                        Text(email).tag(email)
                    }
                }
                .labelsHidden()
            }

            HStack(alignment: .top) {
                Text("To:").frame(width: 50, alignment: .trailing)
                VStack(alignment: .leading, spacing: 0) {
                    TextField("", text: $to)
                        .onChange(of: to) { _, newValue in
                            let token = currentToken(in: newValue)
                            guard token.count >= 2 else { toSuggestions = []; return }
                            Task {
                                let results = await contactsService.search(token)
                                if currentToken(in: to) == token {
                                    toSuggestions = results
                                }
                            }
                        }
                    if !toSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(toSuggestions.prefix(8)) { match in
                                Button {
                                    to = match.email
                                    toSuggestions = []
                                } label: {
                                    HStack {
                                        Text(match.displayName)
                                        Text(match.email).foregroundStyle(.secondary).font(.caption)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    }
                }
            }

            Text("The message is redirected exactly as received - the recipient sees it as coming from the original sender, with a note showing you redirected it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Redirect") {
                    send()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(to.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440, height: 360)
        .task {
            contactsService.requestAccessIfNeeded()
        }
    }

    private func currentToken(in text: String) -> String {
        text.split(separator: ",", omittingEmptySubsequences: false).last?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func send() {
        guard let account = accountsStore.accounts.first(where: { $0.email == from }),
              let password = accountsStore.password(for: account) else { return }

        let rawRedirect = RedirectComposer.buildRedirect(originalRaw: originalRaw, from: from, to: to)

        outbox.enqueue(
            accountID: account.id,
            imapHost: account.imapHost, imapPort: account.imapPort,
            smtpHost: account.smtpHost, smtpPort: account.smtpPort,
            user: account.email, password: password,
            sentFolder: sentFolder,
            from: from, to: to, cc: "", subject: originalMessage.subject, markdownBody: "",
            attachments: [],
            prebuiltRawMessage: rawRedirect
        )
        dismiss()
    }
}
