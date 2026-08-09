# Architecture notes

Hard-won constraints. These aren't style preferences - several of them were
discovered via real, painful bugs, and violating them will reintroduce those
bugs.

## IMAP identity: UID vs sequence number

**Never trust an untagged FETCH response's leading number (`response.key`)
as a message's identity.** That number is the message's *sequence number*
(its position in the mailbox), not its UID. They look similar in casual
single-session testing but are fundamentally different: sequence numbers
shift whenever anything is expunged, UIDs never do.

This conflation caused a real bug that wiped the entire local database:
`UID SEARCH ALL` correctly returned real UIDs (five-digit numbers), but
everything stored locally had been sequence numbers (small numbers, 1..N).
Reconciliation saw zero overlap and deleted everything.

**Rule:** whenever a message's real identity is needed, either:
- Prefix the command with `UID` (`UID FETCH`, `UID MOVE`, `UID STORE`,
  `UID SEARCH`) when selecting *by* a known UID, or
- Explicitly request `UID` as a data item in a sequence-range `FETCH` and
  extract it via `IMAPResponse.fetchUID()` - never via `response.key`.

`IMAPResponse.fetchUID()` / `.copyUID()` / `.appendUID()` are the sanctioned
ways to get a real UID out of a response. `response.key` is a sequence
number in FETCH responses; don't use it for identity.

## Message identity in the local database

Primary key is `(mailbox, uid)` together, not `uid` alone. A UID is only
unique *within* a mailbox - the same UID number can (and does) mean
completely different messages in INBOX vs Sent vs Archive.

Corpus `.eml` cache files on disk are named `{mailbox}-{uid}.eml` for the
same reason - a bare `{uid}.eml` would collide across mailboxes.

## IMAPClient is single-flight

Only one command can be in flight at a time on a given `IMAPClient`
connection - it has no support for pipelining or concurrent commands.
`MailSession` enforces this with two guard flags, `isProcessingQueue` and
`isSelectingMailbox`, checked before starting *any* new operation (fetch,
move, toggle-unread, search, sync, mailbox-switch). Any new operation added
to `MailSession` must respect both guards or it risks tripping the
`IMAPClient` precondition (`"IMAPClient is single-flight"`) and crashing.

`ensureSelected(_:completion:)` does a `SELECT` only if not already
selected, but it does **not** set its own busy guard - it assumes the
caller is already holding `isProcessingQueue` (or equivalent). Never call
it bare from outside an already-guarded operation.

## Mailbox-dependent field semantics

`Message.toAlias` means different things depending on which mailbox a
message is in:
- **INBOX / Archive / Spam / Trash**: `toAlias` is *your own* alias - the
  address the message was sent to.
- **Sent**: `toAlias` is the *recipient's* address (someone else) - you
  sent it, so the "To" field naturally isn't you.

Reply/Reply All/Forward's From/To defaulting logic branches on
`message.mailbox == "Sent"` specifically because of this. Any new feature
that reads `toAlias` needs to account for which case it's in.

## Moving messages: capture the destination UID immediately

`moveMessage` uses IMAP's `MOVE` extension (Runbox supports it), and
captures the message's *new* UID in the destination mailbox via the
`UIDPLUS` `COPYUID` response code, inserting it into the local cache for
the destination mailbox right away - not waiting for that mailbox's next
sync. This matters for Smart Folders and "All Messages", which query the
local cache directly: without the immediate insert, a message moved from
INBOX to Archive would briefly vanish from any view spanning both mailboxes
until Archive happened to be synced again.

## SwiftUI TextEditor swallows things

`TextEditor` wraps a real `NSTextView`, which has its own built-in
handling for both keyboard shortcuts and drag-and-drop that takes priority
over SwiftUI modifiers attached directly to it:

- **Keyboard shortcuts**: a `.keyboardShortcut()` on a sibling `Button`
  won't reliably fire while a `TextEditor` has focus. Fixed via
  `.onKeyPress()` on a *container* around the TextEditor (Compose's
  Send/attach shortcuts), or via the app's real menu bar `.commands`
  (main-window shortcuts), bridged to view logic via `NotificationCenter`
  since `.commands` lives in a different scope than the view's `@State`.
- **Drag-and-drop**: a `.dropDestination()` attached to the `TextEditor`
  itself gets overridden by NSTextView's native "insert dropped file as
  text" behavior. Fixed by giving the drop target its own dedicated zone
  that never overlaps the TextEditor's bounds (Compose's attachment strip).

## Swift concurrency gotchas

- A local `func` defined *inside* a `Task { @MainActor in ... }` closure
  does **not** automatically inherit that isolation under strict
  concurrency checking, even though it's lexically nested inside it. Mark
  such nested functions `@MainActor` explicitly if they touch
  actor-isolated state. (Real bug hit twice: `finishUp()` in `search()`,
  `collect()` in the same function.)
- A single SwiftUI view's `body` with too many chained modifiers
  (particularly many `.onReceive()` calls) can push the type checker past
  its complexity budget ("unable to type-check this expression in
  reasonable time"). Merge multiple `.onReceive` calls into one via
  `Publishers.MergeMany(...)` rather than chaining many separately, and
  keep `body` itself from growing an unbounded number of modifiers -
  extract logic into separate functions/computed properties instead of
  inlining it all.

## Credentials (current known shortcut)

Login currently uses `IMAP_USER`/`IMAP_PASSWORD` environment variables set
on the Xcode scheme - **not** proper Keychain storage. This is why the app
can't currently be launched standalone (double-click, no Xcode) - a real
double-clickable build has no scheme to inject those variables. Building
Keychain-based storage is a prerequisite for standalone launch, not a
separate, independent task.

## Runbox-specific facts (confirmed, not guessed)

- IMAP: `mail.runbox.com`, port 993, TLS.
- SMTP: `mail.runbox.com`, port 465 (direct TLS, no STARTTLS needed).
- Auth: `AUTH PLAIN`.
- Real folder names (confirmed via webmail, not MailMate's translated
  labels): `Sent`, `Archive`, `Spam` (not "Junk"), `Trash` (not "Deleted
  Messages" - that's MailMate's own display label for the same folder).
- Capabilities confirmed present: `LITERAL+`, `UIDPLUS`, `MOVE`,
  `SPECIAL-USE`, `CONDSTORE`, `QRESYNC`, `IDLE`.
- SMTP outgoing can be disabled by Runbox until the account's alternate
  email is validated or it's on a paid plan - a real possible cause if SMTP
  ever fails where IMAP doesn't.
- Runbox's own spam filtering: SpamAssassin plus a trainable component.
  Incoming mail is stamped with `X-Spam-Flag` / `X-Spam-Status` /
  `X-Spam-Score` headers before delivery, regardless of client. Whether a
  plain IMAP `MOVE` in/out of the Spam folder actually trains their filter
  (the way their webmail's dedicated "Not Spam" button does) is
  **unconfirmed** - worth testing or asking Runbox directly before relying
  on it.

## Envelope fetches: what's requested and why

A single `FETCH`/`UID FETCH` for envelope data requests three things
together, in one round trip:
- `ENVELOPE` - subject/from/to/date (parsed by `EnvelopeParser`)
- `FLAGS` - for real `isSeen` (`\Seen` presence), not a guess
- `BODY.PEEK[HEADER.FIELDS (X-Spam-Flag X-Spam-Status X-Spam-Score
  X-Spam-Level)]` - Runbox's own spam signal, fetched as a lightweight
  header-only block (not the full body), `.PEEK` so it doesn't mark the
  message read as a side effect

This only runs at *first fetch* time for a given message - it is not
re-checked on every sync. `refreshFlags()` (manual Sync only, not automatic
mailbox switches, since it sweeps the whole mailbox) re-checks `\Seen` for
already-cached messages; spam headers are not currently re-swept the same
way.
