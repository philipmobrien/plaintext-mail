# Plaintext Mail

A native macOS IMAP/SMTP email client, built from the protocol level up in Swift and SwiftUI - no third-party mail SDK, no Electron, no background sync daemon.

Markdown-first, keyboard-first, and light enough to actually notice the difference in Activity Monitor.

## Why this exists

Built after watching a third-party mail client (paired with a licensed spam-filtering add-on) quietly become one of the heaviest battery draws on my machine, for what amounts to periodically checking a few IMAP mailboxes.

This client talks to the mail server directly - IMAP for reading, SMTP for sending - and does nothing else in the background.

It's also unapologetically markdown-first: compose in plain text, no rich HTML editor, no formatting toolbar. Reading pane strips HTML down to readable text (and, as a side effect, never loads a single remote image or tracking pixel, since it never fetches HTML content at all).

## Features

- Multi-account, multi-provider, genuinely simultaneous - any IMAP/SMTP server, not tied to one provider. Real per-account sync, its own sidebar section per account, and a merged "All Messages" view spanning every account at once, not just the first one configured.
- Real folder names (Sent/Trash/Junk/Archive/Drafts) are discovered automatically via IMAP `LIST` + `SPECIAL-USE`, not guessed.
- Three-pane interface: sidebar, message list, reading pane
- Compose in markdown, with attachments (drag-and-drop or file picker)
- Background sending - hitting Send doesn't block the app, with retry on failure
- Reply / Reply All / Forward / Redirect, alias-aware (multiple addresses per account handled correctly for From/To defaulting). Redirect is a genuinely different operation from Forward - preserves the original sender's identity via RFC 5322 `Resent-*` headers, rather than showing as forwarded by you.
- Proper reply quoting, including correct indentation for already-nested quote chains from earlier rounds of replying
- Per-account signatures, auto-appended to new messages/replies/forwards
- Real read/unread tracking against the server's own `\Seen` flag
- Multi-select, drag-and-drop between mailboxes, right-click context menus (on messages and on mailboxes - Empty Trash, Move All to Trash), full keyboard shortcut set with a real macOS menu bar and Help
- Smart Folders: saved filters spanning multiple mailboxes within one account, with AND/OR condition matching
- Cross-mailbox search
- Surfaces the mail server's own spam-classification headers (`X-Spam-Score` etc.) rather than re-implementing spam filtering
- Contacts integration: autocomplete recipients, add senders as new contacts
- PGP decryption via a local GPG installation - both PGP/MIME and classic inline `-----BEGIN PGP MESSAGE-----` blocks. Signing/encrypting outgoing mail isn't built yet - see Status below.
- Credentials stored in macOS Keychain - nothing sensitive touches disk in plain text

## Requirements

- macOS (recent - built and tested on a current release)
- Xcode (recent - built with SwiftUI features from the last couple of major macOS releases)
- [GRDB.swift](https://github.com/groue/GRDB.swift) (Swift Package Manager dependency, already configured in the project)

## Getting started

1. Clone the repo and open the `.xcodeproj` in Xcode.
2. Build and run the `Plaintext Mail` target (the `IMAPSpike` target is a command-line diagnostic tool used during development - not needed for normal use).
3. **Set your signing team before your first build** - see "Code signing" below. Skipping this works fine at first, but causes a real annoyance later.
4. On first launch, you'll be asked to add an account: display name, email, IMAP host/port, SMTP host/port, and password. Any standard IMAP/SMTP provider should work.
5. Password is stored in Keychain; everything else in `UserDefaults`.

## Code signing

Xcode's default local-build signing ("Sign to Run Locally") generates a genuinely different signing identity on every rebuild. Since Keychain access is tied to that identity, this means **every rebuild forgets your saved account password** - the app looks like it's never been configured, even though nothing was actually lost.

**Fix: sign in to Xcode with your own Apple ID and select it as your Team** (target → Signing & Capabilities → Team → "Your Name (Personal Team)" - free, no paid developer account needed). This gives a stable identity across rebuilds on your own machine, so Keychain access persists as expected. Expect one more re-entry of your account details right after making this change specifically (it's itself a new identity, different from whatever "Sign to Run Locally" was using) - after that, it should hold across every future rebuild.

**If you're building this for someone else to use on their own separate Mac** (not just running it yourself): building it fresh from source on *their* machine, with *their* own Apple ID signing it, works cleanly and indefinitely. Handing them a pre-built binary to install, signed under a free Personal Team, does not - Apple's free tier ties on-device installation to a roughly 7-day provisioning window per registered device, meant for testing rather than ongoing personal use. Building locally sidesteps that path entirely, since nothing is being installed onto a separate registered device in the first place. A real (paid) Apple Developer ID certificate removes this constraint entirely, and is the correct approach if you want to distribute an already-built copy rather than have people build it themselves.

## PGP decryption

Reading PGP-encrypted mail requires a local GPG installation - this app shells out to the real `gpg` binary rather than bundling a crypto library of its own, since PGP's whole value depends on correctly interoperating with whatever the sender's own GPG setup produced. [GPG Suite](https://gpgtools.org) or Homebrew's `gnupg` package both work; a few common install locations are checked automatically. If a message contains PGP content (either proper PGP/MIME or a classic inline `-----BEGIN PGP MESSAGE-----` block), a Decrypt button appears in the reading pane - tapping it may trigger GPG's own separate passphrase dialog, which this app never sees or handles directly.

Signing or encrypting outgoing mail isn't built yet.

## Project structure / further reading

This was built incrementally, session by session, with a real amount of hard-won debugging along the way. Three documents capture the parts worth knowing before changing anything:

- **`ARCHITECTURE.md`** - hard technical constraints discovered through real bugs (IMAP UID vs sequence-number handling, single-flight connection discipline, mailbox-dependent field semantics, SwiftUI gotchas). Read this before touching sync logic.
- **`DECISIONS.md`** - choices made and why, so they don't get accidentally re-litigated.
- **`BACKLOG.md`** - what's done, what's outstanding, roughly in priority order.

## Status

Actively developed, daily-driver quality for its author, not a finished product. Known gaps: no Drafts support yet, PGP decryption only (no signing/encrypting outgoing mail), Smart Folders are per-account rather than spanning accounts, full message-body search was deliberately not built (header/subject/sender search covers the actual daily need), single-machine personal use by default (not code-signed or notarized for wider distribution - see Code Signing above for what that involves).

## License

MIT - see `LICENSE`.
