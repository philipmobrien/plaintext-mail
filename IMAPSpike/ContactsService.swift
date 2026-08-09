import Foundation
import Contacts
import Combine

/// Wraps macOS's real Contacts framework (CNContactStore) - a proper
/// sanctioned API for this, not AppleScript automation. Handles
/// authorization, name/email search for compose autocomplete, and
/// duplicate-safe adding of a message's sender.
///
/// All the actual CNContactStore work runs off the main thread via
/// Task.detached - Apple documents these calls (especially enumerating the
/// whole address book, which search() does) as unsafe to run inline on the
/// main thread. CNContactStore itself is documented thread-safe for
/// concurrent reads, so dispatching to a detached task and returning plain
/// value types back is safe.
@MainActor
final class ContactsService: ObservableObject {
    private let store = CNContactStore()
    @Published var authorizationGranted = false

    struct ContactMatch: Identifiable {
        let id = UUID()
        let displayName: String
        let email: String
    }

    /// Checks current authorization and requests it if never asked before.
    /// Safe to call repeatedly - only actually prompts once, the first time
    /// status is .notDetermined.
    func requestAccessIfNeeded() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            authorizationGranted = true
        case .notDetermined:
            store.requestAccess(for: .contacts) { [weak self] granted, _ in
                Task { @MainActor in self?.authorizationGranted = granted }
            }
        default:
            authorizationGranted = false
        }
    }

    /// Searches contacts by name OR email address - Apple's own
    /// predicateForContacts(matchingName:) only searches name fields, never
    /// email content, but people reasonably expect typing part of an email
    /// to work too. No built-in "email contains X" predicate exists, so
    /// this enumerates contacts (lightweight keys only) and filters
    /// client-side, capping the scan once there are enough matches to show.
    func search(_ query: String) async -> [ContactMatch] {
        guard authorizationGranted else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedQuery.isEmpty else { return [] }

        let store = self.store
        return await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                // CNContactFormatter needs more than given/family name to
                // build a full name (middleName, prefixes/suffixes, etc,
                // depending on locale) - guessing which fields it needs and
                // fetching only those crashes with
                // CNPropertyNotFetchedException the moment it touches one
                // we didn't include. This asks the formatter itself what it
                // needs, rather than guessing.
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            ]

            var results: [ContactsService.ContactMatch] = []
            var seenEmails = Set<String>()

            let fetchRequest = CNContactFetchRequest(keysToFetch: keys)
            try? store.enumerateContacts(with: fetchRequest) { contact, stop in
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                let nameMatches = name.lowercased().contains(trimmedQuery)

                for labeledEmail in contact.emailAddresses {
                    let email = labeledEmail.value as String
                    let emailMatches = email.lowercased().contains(trimmedQuery)
                    guard nameMatches || emailMatches else { continue }
                    guard !seenEmails.contains(email.lowercased()) else { continue }
                    seenEmails.insert(email.lowercased())
                    results.append(ContactsService.ContactMatch(displayName: name.isEmpty ? email : name, email: email))
                }

                if results.count >= 25 { stop.pointee = true }
            }

            // enumerateContacts has no inherent useful order - sort so the
            // dropdown shows a sensible, predictable slice.
            return results.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }.value
    }

    /// True if some contact already has this email - avoids creating a
    /// duplicate when adding a message's sender.
    func contactExists(withEmail email: String) async -> Bool {
        guard authorizationGranted else { return false }
        let store = self.store
        return await Task.detached {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            let keys: [CNKeyDescriptor] = [CNContactEmailAddressesKey as CNKeyDescriptor]
            return (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?.isEmpty == false
        }.value
    }

    /// Adds a new contact from a name/email pair (typically a message
    /// sender). Checks for an existing match first - a `false` result means
    /// either it already existed or the save failed, not distinguished
    /// further since the UI treats both as "nothing to do".
    func addContact(name: String?, email: String) async -> Bool {
        guard authorizationGranted else { return false }
        guard await !contactExists(withEmail: email) else { return false }

        let store = self.store
        return await Task.detached {
            let contact = CNMutableContact()
            if let name, !name.isEmpty {
                let parts = name.split(separator: " ", maxSplits: 1)
                contact.givenName = String(parts.first ?? "")
                if parts.count > 1 { contact.familyName = String(parts[1]) }
            } else {
                contact.givenName = email
            }
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]

            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            do {
                try store.execute(request)
                return true
            } catch {
                print("Could not save contact: \(error)")
                return false
            }
        }.value
    }
}
