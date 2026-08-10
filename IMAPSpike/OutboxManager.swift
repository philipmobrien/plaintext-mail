import Foundation
import Combine

/// Owns the send queue independently of any compose window's lifecycle -
/// hitting Send dismisses the sheet immediately, and this keeps working in
/// the background. Processes one item at a time (each send is its own
/// short-lived SMTP connection, no benefit to parallelising against a
/// single mail server) and retains failed sends so they can be retried
/// without re-typing the message.
@MainActor
final class OutboxManager: ObservableObject {
    struct OutboxItem: Identifiable {
        let id = UUID()
        var subjectPreview: String
        var toPreview: String
        var status: Status

        let imapHost: String
        let imapPort: Int
        let smtpHost: String
        let smtpPort: Int
        let user: String
        let password: String
        let accountID: UUID
        let sentFolder: String
        let prebuiltRawMessage: String?
        let from: String
        let to: String
        let cc: String
        let subject: String
        let markdownBody: String
        let attachments: [ComposeAttachment]

        enum Status: Equatable {
            case sending
            case sent
            case failed(String)
        }
    }

    @Published var items: [OutboxItem] = []

    private var isProcessing = false

    func enqueue(
        accountID: UUID,
        imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int, user: String, password: String,
        sentFolder: String,
        from: String, to: String, cc: String, subject: String, markdownBody: String,
        attachments: [ComposeAttachment],
        prebuiltRawMessage: String? = nil
    ) {
        let item = OutboxItem(
            subjectPreview: subject.isEmpty ? "(no subject)" : subject,
            toPreview: to,
            status: .sending,
            imapHost: imapHost, imapPort: imapPort, smtpHost: smtpHost, smtpPort: smtpPort, user: user, password: password,
            accountID: accountID,
            sentFolder: sentFolder,
            prebuiltRawMessage: prebuiltRawMessage,
            from: from, to: to, cc: cc, subject: subject, markdownBody: markdownBody,
            attachments: attachments
        )
        items.append(item)
        processNext()
    }

    func retry(_ item: OutboxItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].status = .sending
        processNext()
    }

    func dismissItem(_ item: OutboxItem) {
        items.removeAll { $0.id == item.id }
    }

    private func processNext() {
        guard !isProcessing else { return }
        guard let index = items.firstIndex(where: { $0.status == .sending }) else { return }
        isProcessing = true

        let item = items[index]
        let session = ComposeSession()
        session.send(
            accountID: item.accountID,
            imapHost: item.imapHost, imapPort: item.imapPort, smtpHost: item.smtpHost, smtpPort: item.smtpPort,
            user: item.user, password: item.password,
            sentFolder: item.sentFolder,
            from: item.from, to: item.to, cc: item.cc, subject: item.subject, markdownBody: item.markdownBody,
            attachments: item.attachments,
            prebuiltRawMessage: item.prebuiltRawMessage
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    switch result {
                    case .success:
                        self.items[idx].status = .sent
                        // Auto-clear successful sends after a moment, rather
                        // than leaving a permanently-growing "sent" list -
                        // the real record of a sent message is the Sent
                        // mailbox itself, not the outbox.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                            self?.items.removeAll { $0.id == item.id }
                        }
                    case .failure(let error):
                        self.items[idx].status = .failed(error.localizedDescription)
                    }
                }
                self.isProcessing = false
                self.processNext()
            }
        }
    }
}
