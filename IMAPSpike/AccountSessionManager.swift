import Foundation
import Combine

/// Owns one MailSession per configured account - previously there was
/// exactly one shared MailSession regardless of how many accounts existed,
/// which is why adding a second account correctly stored it but never
/// connected to or displayed it. Kept in sync with AccountsStore by the
/// owning view calling syncSessions whenever the account list changes,
/// rather than holding a direct reference to AccountsStore itself (avoids
/// property-initialization-order issues between two @StateObjects that
/// would otherwise need to reference each other).
@MainActor
final class AccountSessionManager: ObservableObject {
    @Published private(set) var sessions: [UUID: MailSession] = [:]

    func syncSessions(accounts: [Account], passwordLookup: (Account) -> String?) {
        let currentIDs = Set(accounts.map { $0.id })

        // Drop sessions for accounts that no longer exist.
        for id in sessions.keys where !currentIDs.contains(id) {
            sessions.removeValue(forKey: id)
        }

        // Create and connect a session for any account that doesn't have
        // one yet - covers both first launch (all accounts are "new") and
        // adding an account later via the Add Account button.
        for account in accounts where sessions[account.id] == nil {
            let session = MailSession(accountID: account.id)
            sessions[account.id] = session
            if let password = passwordLookup(account) {
                session.connect(host: account.imapHost, port: account.imapPort, user: account.email, password: password)
            }
        }
    }

    func session(for accountID: UUID) -> MailSession? {
        sessions[accountID]
    }
}
