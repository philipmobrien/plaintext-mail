import Foundation

/// The menu bar (defined at the App level) and ContentView's action logic
/// (defined at the View level) live in different scopes with no direct
/// access to each other - NotificationCenter is the standard, lightweight
/// way to bridge them without restructuring where state lives.
extension Notification.Name {
    static let menuComposeNewMessage = Notification.Name("menuComposeNewMessage")
    static let menuReply = Notification.Name("menuReply")
    static let menuReplyAll = Notification.Name("menuReplyAll")
    static let menuForward = Notification.Name("menuForward")
    static let menuArchive = Notification.Name("menuArchive")
    static let menuDelete = Notification.Name("menuDelete")
    static let menuMoveToJunk = Notification.Name("menuMoveToJunk")
    static let menuToggleUnread = Notification.Name("menuToggleUnread")
    static let menuSyncNow = Notification.Name("menuSyncNow")
    static let menuShowShortcutsHelp = Notification.Name("menuShowShortcutsHelp")
}
