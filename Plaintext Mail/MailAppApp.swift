import SwiftUI
import AppKit

@main
struct MailAppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // A one-time setup action, not something reached for often -
            // the application menu (far left) is the conventional home for
            // this kind of thing, rather than cluttering the toolbar.
            CommandGroup(after: .appInfo) {
                Button("Set as Default Mail App") {
                    NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { error in
                        if let error {
                            print("Could not set as default mail app: \(error)")
                        }
                    }
                }
            }

            // Replaces the default "New Window"/"New Item" with our own
            // Compose action, so Cmd+N does the obviously-expected thing
            // in a mail client.
            CommandGroup(replacing: .newItem) {
                Button("New Message") {
                    NotificationCenter.default.post(name: .menuComposeNewMessage, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("Message") {
                Button("Reply") {
                    NotificationCenter.default.post(name: .menuReply, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Reply All") {
                    NotificationCenter.default.post(name: .menuReplyAll, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Forward") {
                    NotificationCenter.default.post(name: .menuForward, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                Button("Archive") {
                    NotificationCenter.default.post(name: .menuArchive, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Move to Junk") {
                    NotificationCenter.default.post(name: .menuMoveToJunk, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Button("Delete") {
                    NotificationCenter.default.post(name: .menuDelete, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [])

                Button("Mark as Read/Unread") {
                    NotificationCenter.default.post(name: .menuToggleUnread, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Divider()

                Button("Sync Now") {
                    NotificationCenter.default.post(name: .menuSyncNow, object: nil)
                }
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .menuShowShortcutsHelp, object: nil)
                }
            }
        }
    }
}
