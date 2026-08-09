# Backlog

## Done

**Core sync engine (Phase 0-2)**
- TLS IMAP protocol spike, tag-matched command dispatch, literal-aware byte
  reading
- GRDB/SQLite local cache, UIDVALIDITY safety (per-mailbox wipe on mismatch)
- Full MIME parsing: multipart trees, QP/base64 decode, charset decoding
  (headers and bodies), HTML→text fallback with tracking-pixel stripping
- IDLE proven in the console spike (not yet wired into the live app)

**App (Phase 3+)**
- Three-pane SwiftUI window, GRDB-backed message list
- Live IMAP body fetch on message selection, with local `.eml` caching
- Multi-mailbox: Inbox, Sent, Archive, Spam, Trash - each independently
  synced, with automatic first-visit envelope backfill
- Reconciliation: detects and removes locally-cached messages that were
  deleted server-side
- Connection resilience: auto-reconnect on unexpected drop (restores the
  mailbox you were viewing), manual "go offline" toggle that suppresses
  auto-reconnect, visible offline/retry indicator

**Sending**
- SMTP send (AUTH PLAIN), Sent-folder archiving via IMAP `APPEND` with
  `UIDPLUS` capturing the real new UID for immediate local caching
- Cc support with correct per-recipient `RCPT TO`
- Reply / Reply All (mailbox-aware From/To defaulting, Cc built from
  original To+Cc minus your own aliases) / Forward (plain separator, no `>`
  quoting)
- Attachments: drag-and-drop (dedicated drop zone) + ⌘. file picker on
  send; Open/Save with lazy decode on receive
- Outbox: background sending, doesn't block the compose window, retry on
  failure

**Organization**
- Smart Folders: multiple conditions, Any/All, contains/does-not-contain,
  case-insensitive, editable
- "All Messages" fixed view (Inbox+Archive+Sent)
- Cross-mailbox search (sweeps all 5 real mailboxes, merges and sorts
  results)
- Sort menu (date/sender/recipient, both directions)
- Multi-select (⌘A / Shift-range / ⌘-click), with Archive/Trash/Spam/mark-
  unread all operating on the whole selection
- Empty Trash (manual, confirmed, permanent)
- Real read/unread tracking against server `\Seen` flag (not assumed);
  opening a message marks it read server-side; manual toggle-unread
  shortcut
- Runbox's own spam-score headers surfaced (badge in list, score in detail
  pane)

**Polish**
- Real macOS menu bar + Help → Keyboard Shortcuts
- Word wrap, paragraph spacing, larger readable font, compact clickable
  links instead of raw tracking URLs
- App icon wired into the asset catalog
- `ARCHITECTURE.md` / `DECISIONS.md` / `BACKLOG.md` (this)

## Outstanding

**From the Eudora feature review - confirmed wanted**
- Signatures - reusable sign-off text auto-appended to outgoing mail
- Redirect (distinct from Forward) - resends a message preserving the
  *original* sender's identity, rather than showing as forwarded by you.
  The correct standards-based mechanism is RFC 5322's Resent-* headers
  (Resent-From, Resent-To, Resent-Date etc layered on top of the
  untouched original message), not a hack built on the existing Forward
  flow.
- PGP signing/encryption - explicitly opt-in per message or per account,
  never default/automatic. Needs a real scoping decision before starting:
  macOS has no built-in PGP support, so this means either a third-party
  Swift crypto library or shelling out to a local GPG installation if
  present - a genuine architectural choice, not a quick add.

**Explicitly declined, not being built (Eudora features deliberately not wanted)**
- Active mail filtering/rules on arrival (move/flag/auto-reply as mail
  comes in) - deliberately declined: manual sorting is preferred, to
  avoid missing things an automated rule silently filed away
- Conversation threading - deliberately declined, strong preference
  against it
- Vacation/auto-reply, stationery/templates, multi-window mailbox views,
  Eudora-style nicknames (superseded by real Contacts integration),
  MoodWatch, legacy encoding support (BinHex/UUencode) - all reviewed,
  none wanted


**In progress / next up**
- **Drag-and-drop between mailboxes** - must include Inbox as a valid drop
  target, not just Archive/Trash/Spam, to cover moving a false-positive
  back out of Spam (real case hit: an over-zealous SpamAssassin catch).

**Queued, sequenced together**
- Keychain-based credential storage (replaces the `IMAP_USER`/
  `IMAP_PASSWORD` environment-variable bridge)
- Standalone launch / exportable `.app` - blocked on the above, since a
  double-clicked app has no Xcode scheme to inject credentials

**Bigger, separately-scoped pieces**
- Multi-account support - several more real accounts across different
  domains, "with separation" - closer in scope to the
  original sync-engine phases than a quick feature
- Drafts - a real stateful lifecycle (create/update/list/reopen/delete),
  explicitly bigger than Sent's one-shot archive-on-send
- Full body-text search (currently header/subject/from only - message
  bodies aren't indexed locally)

**Low priority (flagged, not wanted urgently)**
- Browse other existing real IMAP folders beyond the 5 already wired up
  (Archives, Deferred, Junk Drawer, Notes, Queue, Stuff, Sub-test)
- Create new real IMAP folders from within the app
- Preferences window (⌘,) - personal single-user tool, low urgency

**Spam, revisit later**
- Review/tune Runbox's own server-side filter settings directly (allowlist,
  the Spam/Maybe-Spam split pattern) - explicitly deferred to "the end of
  the build"
- Confirm whether a plain IMAP `MOVE` in/out of Spam actually trains
  Runbox's filter the same way their webmail's "Not Spam" button does
- SpamSieve AppleScript integration - real but substantial (needs genuine
  scriptability built into the app, plus vendor SDK or reverse-engineered
  scripting)
