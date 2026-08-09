import Foundation
import GRDB

/// One cached message header/envelope, scoped to a specific mailbox.
///
/// Primary key is (mailbox, uid) together, not uid alone - a UID is only
/// guaranteed unique *within* one mailbox (per its own UIDVALIDITY epoch).
/// Sent and INBOX can easily have overlapping UID numbers referring to
/// completely different messages, so uid alone isn't a safe identity once
/// more than one mailbox is involved.
struct Message: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var mailbox: String       // e.g. "INBOX", "Sent"
    var uid: Int              // IMAP UID - stable identifier within a UIDVALIDITY epoch, but only within this mailbox
    var subject: String
    var from: String
    var toAlias: String       // which of your addresses this was sent to
    var date: Date
    var isSeen: Bool
    var isFlaggedSpam: Bool = false  // from Runbox's own X-Spam-Flag/X-Spam-Status header
    var spamScore: Double?           // from Runbox's own X-Spam-Score/X-Spam-Status header, if present

    static let databaseTableName = "message"

    // SwiftUI's Identifiable conformance - combines mailbox+uid since
    // neither alone is a safe unique identity across mailboxes.
    var id: String { "\(mailbox)|\(uid)" }
}

enum DatabaseSetup {
    /// Opens (creating if needed) the local SQLite store and runs migrations.
    static func makeDatabase(at path: String) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(path: path)

        var migrator = DatabaseMigrator()

        migrator.registerMigration("createMessage") { db in
            try db.create(table: "message") { t in
                t.column("uid", .integer).notNull().primaryKey()
                t.column("subject", .text).notNull()
                t.column("from", .text).notNull()
                t.column("toAlias", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("isSeen", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("createMailboxState") { db in
            try db.create(table: "mailboxState") { t in
                t.column("mailboxName", .text).notNull().primaryKey()
                t.column("uidValidity", .integer).notNull()
            }
        }

        // Adds mailbox support: message rows now belong to a specific
        // mailbox (INBOX, Sent, ...), with (mailbox, uid) as the composite
        // primary key rather than uid alone. This recreates the table rather
        // than trying to preserve existing rows - acceptable at this stage
        // since the local cache is trivially rebuildable from the server via
        // backfill, and every prior row implicitly meant "INBOX" anyway.
        migrator.registerMigration("addMailboxSupport") { db in
            try db.drop(table: "message")
            try db.create(table: "message") { t in
                t.column("mailbox", .text).notNull()
                t.column("uid", .integer).notNull()
                t.column("subject", .text).notNull()
                t.column("from", .text).notNull()
                t.column("toAlias", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("isSeen", .boolean).notNull().defaults(to: false)
                t.primaryKey(["mailbox", "uid"])
            }
        }

        // Smart folders: saved, named filters spanning several real
        // mailboxes at once. Purely local - no IMAP concept of a "smart
        // folder" exists, this just drives a query over the local message
        // cache. Superseded by richer conditions below (v2), but kept as a
        // migration step since some installs will already have the v1 table.
        migrator.registerMigration("createSmartFolder") { db in
            try db.create(table: "smartFolder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("mailboxesCSV", .text).notNull()
                t.column("criteria", .text).notNull()
            }
        }

        // v2: replaces the single keyword with a proper list of conditions
        // (each targeting From/To/Subject) combined with Any (OR) or All
        // (AND) - needed for real cases like "from any of several related
        // addresses", which a single keyword field can't express.
        migrator.registerMigration("smartFolderConditions") { db in
            try db.drop(table: "smartFolder")
            try db.create(table: "smartFolder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("mailboxesCSV", .text).notNull()
                t.column("matchType", .text).notNull()       // "any" or "all"
                t.column("conditionsJSON", .text).notNull()  // JSON-encoded [SmartFolderCondition]
            }
        }

        // Adds server-computed spam signal (Runbox's own SpamAssassin-based
        // X-Spam-Flag/X-Spam-Score/X-Spam-Status headers, fetched alongside
        // envelope data) - additive, no need to recreate the table for two
        // new nullable/defaulted columns.
        migrator.registerMigration("addSpamHeaders") { db in
            try db.alter(table: "message") { t in
                t.add(column: "isFlaggedSpam", .boolean).notNull().defaults(to: false)
                t.add(column: "spamScore", .double)
            }
        }

        try migrator.migrate(dbQueue)
        return dbQueue
    }
}

/// One condition within a smart folder, e.g. "From contains alice@x.com".
/// Matching is always case-insensitive - there's no toggle for it, since
/// that's the only behaviour actually wanted here.
struct SmartFolderCondition: Codable, Identifiable, Equatable {
    enum Field: String, Codable, CaseIterable {
        case from = "From"
        case to = "To"
        case subject = "Subject"
    }
    enum Operator: String, Codable, CaseIterable {
        case contains = "contains"
        case doesNotContain = "does not contain"
    }

    var id = UUID()
    var field: Field
    var op: Operator = .contains
    var value: String
}

/// A saved, named filter spanning one or more real mailboxes, matching
/// several conditions combined with Any (OR) or All (AND). Purely local -
/// selecting one queries the cached `message` table rather than doing
/// anything over IMAP, which is what makes it possible for a message to
/// keep showing up here even as it moves between the real mailboxes this
/// smart folder is watching.
struct SmartFolder: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var name: String
    var mailboxesCSV: String
    var matchType: String
    var conditionsJSON: String

    static let databaseTableName = "smartFolder"

    var mailboxList: [String] { mailboxesCSV.split(separator: ",").map(String.init) }

    var conditions: [SmartFolderCondition] {
        (try? JSONDecoder().decode([SmartFolderCondition].self, from: Data(conditionsJSON.utf8))) ?? []
    }

    static func encodeConditions(_ conditions: [SmartFolderCondition]) -> String {
        (try? JSONEncoder().encode(conditions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

/// One row per tracked mailbox, remembering the last UIDVALIDITY we saw.
/// If a server-reported UIDVALIDITY ever doesn't match what's stored here,
/// every existing UID in that mailbox may now mean something different -
/// the only safe response is to wipe the local cache for that mailbox and
/// refetch from scratch.
struct MailboxState: Codable, FetchableRecord, PersistableRecord {
    var mailboxName: String
    var uidValidity: Int

    static let databaseTableName = "mailboxState"
}

enum UIDValidityResult {
    case unchanged
    case firstTimeSeen
    case changedAndWiped(previous: Int, new: Int)
}

enum UIDValidityChecker {
    /// Compares `newValidity` against what's stored for `mailbox`. If it has
    /// changed, wipes cached messages for *that mailbox only* (their UIDs
    /// are no longer trustworthy) and records the new value. Safe to call on
    /// every SELECT - a no-op when nothing has changed.
    static func reconcile(mailbox: String, newValidity: Int, dbQueue: DatabaseQueue) throws -> UIDValidityResult {
        try dbQueue.write { db in
            if let existing = try MailboxState.fetchOne(db, key: mailbox) {
                if existing.uidValidity == newValidity {
                    return .unchanged
                }
                // Changed - wipe cached messages for THIS mailbox only, not
                // every mailbox's cache, and store the new value.
                try Message.filter(Column("mailbox") == mailbox).deleteAll(db)
                var updated = existing
                updated.uidValidity = newValidity
                try updated.update(db)
                return .changedAndWiped(previous: existing.uidValidity, new: newValidity)
            } else {
                let state = MailboxState(mailboxName: mailbox, uidValidity: newValidity)
                try state.insert(db)
                return .firstTimeSeen
            }
        }
    }
}
