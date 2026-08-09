# Decisions and rationale

Choices made along the way, and why - so they don't get accidentally
re-litigated or reversed without knowing what they were solving.

## Markdown-first, not HTML

Outgoing plain-text messages are tagged `Content-Type: text/plain;
charset=utf-8; markup=markdown` - matching a convention already observed in
the user's own MailMate-sent messages. No HTML alternative part is built.
This was the whole original motivation for the project: writing in
markdown, fingers never leaving the keyboard.

Incoming HTML is converted to plain text (`HTMLToText`), never rendered as
real HTML. This was a deliberate choice, not a missing feature - the user
doesn't care about seeing HTML formatting. **If real HTML rendering is ever
built**, it must default to blocking remote images/trackers (MailMate-style
"N external resources blocked" bar) from day one, not bolted on after a
`WKWebView` is already loading everything eagerly - our current text-only
approach is accidentally private (nothing ever fetches remote content), and
a real HTML renderer would need to earn that same property on purpose.

## Reading pane presentation

Body text: paragraph-spaced (split on blank lines, not relying on `\n\n`
rendering with enough visual gap), 15pt system font with added line
spacing, width capped at 80% of the panel (responsive via
`containerRelativeFrame`, not `GeometryReader` - the latter fights a
ScrollView's natural content-height sizing). Chosen for readability
specifically raised as an eyesight concern.

Raw URLs in plain-text bodies (common in newsletter/marketing mail, often
long tracking-redirect links) are replaced with short clickable domain
labels via `NSDataDetector`, rather than shown in full. Clicking still goes
to the real (possibly tracking) URL - this only cleans up what's
*displayed*, it doesn't and can't strip a sender's own tracking
infrastructure.

## Smart Folders

Deliberately simpler than MailMate's full condition-builder: one Any/OR or
All/AND combinator, conditions target From/To/Subject only (header-level,
not body text - message bodies aren't indexed locally), operator is
contains/does-not-contain, always case-insensitive (no toggle - that's the
only behaviour wanted). Stored as JSON in a `conditionsJSON` column rather
than a relational conditions table, since the model is simple enough not to
need one.

Purely local/client-side - there's no IMAP concept of a "smart folder".
Selecting one runs a SQL query across whichever real mailboxes it watches.

"All Messages" is a **fixed, non-editable** smart folder over
INBOX+Archive+Sent specifically (excludes Spam/Trash) - built because it
was explicitly requested as a standing view, not as a template for more
fixed views.

## Outbox / sending

Hitting Send in the compose window enqueues the message and dismisses the
sheet **immediately** - it does not wait for the SMTP round trip. Actual
delivery happens in `OutboxManager`, owned at the app level (`ContentView`)
so it outlives any individual compose sheet. This was a direct fix for a
real annoyance: the old blocking behaviour meant closing/using the app
while a send was in flight wasn't possible.

Failed sends stay in the outbox with a Retry option (keeps the original
message rather than losing it). Successful sends auto-clear from the
outbox popover after ~2 seconds - the real record of what was sent is the
Sent mailbox itself (via IMAP `APPEND`), not the outbox, which is only ever
meant to show *in-flight* state.

## Keyboard shortcuts live in the real menu bar

Originally implemented as hidden `Button`s with `.keyboardShortcut()`
scattered across views. Replaced with a real macOS menu bar
(`MailAppApp.swift`'s `.commands`), bridged to `ContentView`'s action
functions via `NotificationCenter`. Two reasons: (1) real menu-bar
shortcuts are more robust against `TextEditor` swallowing them than the
hidden-button approach was, and (2) it gives genuine discoverability - a
family member with no memory of the shortcuts can still find "Archive" in
the Message menu, or open Help → Keyboard Shortcuts.

## Attachments

Outgoing: hand-built `multipart/mixed`, base64 with standard 76-character
line wrapping, `Content-Disposition: attachment; filename="..."`. MIME type
guessed from the file extension via `UTType`.

Incoming: attachments are detected by walking the parsed MIME tree for leaf
parts with a filename (via `Content-Disposition` or `Content-Type`'s
`name=`). Decoding is **lazy** - happens only when the user clicks Open or
Save on a specific attachment, not eagerly for every attachment just to
list them.

## Spam: header-surfacing chosen over building a classifier or SpamSieve integration

Given Runbox already runs SpamAssassin server-side and stamps every message
with spam-score headers regardless of client, the cheapest high-value move
was reading those headers (`X-Spam-Flag`/`X-Spam-Score`/`X-Spam-Status`)
and surfacing them in the UI - not building a local Bayesian classifier
from scratch (would take a long time to reach comparable accuracy to a
tool with years of tuning behind it) or integrating with SpamSieve (would
require building real AppleScript scriptability into the app, then either
vendor SDK access or reverse-engineering their existing MailMate/Mail.app
scripts - a substantial standalone project, not ruled out, just deferred).

Reviewing/tuning Runbox's own server-side filter settings directly
(allowlist, the Spam/Maybe-Spam split pattern from their docs) was
explicitly deferred to be revisited once the rest of the build settles.

## App icon

User-supplied circular badge design on a white square background,
deliberately **not** cropped/scaled to fill the canvas edge-to-edge despite
that being the more common macOS convention (full-bleed artwork, letting
the OS's own rounding do the shape work). Reviewed both options directly
and chose the badge-in-a-tile look on purpose - not an oversight.
