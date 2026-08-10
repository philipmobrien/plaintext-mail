import Foundation
import Combine

/// SwiftUI only observes changes to a @Published collection itself (a
/// session added or removed) - not to a MailSession's own @Published
/// properties once it's stored inside that collection, the same root
/// cause behind an earlier, more consequential bug in single-account
/// mailbox switching. This does the same job MailboxContentColumn's direct
/// @ObservedObject does for one session, but for several at once: it
/// subscribes to each session's own objectWillChange and re-publishes its
/// own whenever any of them fires, giving a view a single object it can
/// correctly observe for "did any of these accounts' messages change".
@MainActor
final class MultiSessionObserver: ObservableObject {
    private var cancellables: [UUID: AnyCancellable] = [:]

    func observe(sessions: [UUID: MailSession]) {
        cancellables = sessions.mapValues { session in
            session.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
}
