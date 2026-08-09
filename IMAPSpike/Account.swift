import Foundation

/// One configured mail account. Deliberately generic - no assumption about
/// which provider, unlike the earlier single-account version that hardcoded
/// Runbox's host. Password is never stored here (this struct is safe to
/// persist as plain JSON) - it's looked up from Keychain via `id` whenever
/// actually needed for a connection.
struct Account: Codable, Identifiable, Equatable {
    var id: UUID
    var displayName: String   // user-chosen label, e.g. "Personal", "Sculpture Studio"
    var email: String         // used as the IMAP/SMTP username in most setups, and as the From address
    var imapHost: String
    var imapPort: Int
    var smtpHost: String
    var smtpPort: Int
    var signature: String = ""   // plain text, auto-appended to outgoing mail from this account
}
