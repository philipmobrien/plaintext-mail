import Foundation

/// One real folder as reported by the server's IMAP LIST response, with
/// whatever flags it came back with (special-use attributes like \Sent,
/// \Trash, \Junk, \Drafts, \Archive, plus structural ones like
/// \HasNoChildren - all kept, not just the special-use ones, since the
/// full flag set may be useful later for browsing the complete folder list).
struct DiscoveredFolder {
    let name: String
    let specialUse: Set<String>
}
