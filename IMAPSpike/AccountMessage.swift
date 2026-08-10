import Foundation

/// Message.id ("mailbox|uid") is only unique within one account's own
/// database - two different accounts could easily both have an "INBOX"
/// with the same uid. This wrapper gives a genuinely unique identity for
/// the merged, cross-account All Messages view specifically, without
/// touching Message itself (which stays correct and simple for every
/// other, single-account use throughout the app).
struct AccountMessage: Identifiable, Hashable {
    let accountID: UUID
    let accountDisplayName: String
    let message: Message

    var id: String { "\(accountID.uuidString)|\(message.id)" }

    // Manual conformance based on id alone - avoids needing Message itself
    // to be Hashable (it currently isn't, and adding that conformance
    // could interact unpredictably with GRDB's FetchableRecord/
    // PersistableRecord synthesis on that type).
    static func == (lhs: AccountMessage, rhs: AccountMessage) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
