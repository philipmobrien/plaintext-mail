import Foundation
import Combine

/// Manages the full set of configured accounts. Replaces the earlier
/// single-account AccountStore now that accounts can be any provider, not
/// just Runbox. Non-secret account details (host/port/email/display name)
/// persist as JSON in UserDefaults; each account's password lives
/// separately in Keychain, keyed by the account's own UUID rather than its
/// email (so renaming/changing an email address later wouldn't orphan the
/// stored password).
@MainActor
final class AccountsStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []

    private let userDefaultsKey = "MailApp.accounts"
    private let keychainService = "com.pasigraphy.MailApp.accounts"

    init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            accounts = []
            return
        }
        accounts = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    func addAccount(
        displayName: String, email: String,
        imapHost: String, imapPort: Int,
        smtpHost: String, smtpPort: Int,
        password: String
    ) {
        let account = Account(
            id: UUID(), displayName: displayName, email: email,
            imapHost: imapHost, imapPort: imapPort,
            smtpHost: smtpHost, smtpPort: smtpPort
        )
        KeychainStore.save(service: keychainService, account: account.id.uuidString, value: password)
        accounts.append(account)
        persist()
    }

    func removeAccount(_ account: Account) {
        KeychainStore.delete(service: keychainService, account: account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    func password(for account: Account) -> String? {
        KeychainStore.load(service: keychainService, account: account.id.uuidString)
    }
}
