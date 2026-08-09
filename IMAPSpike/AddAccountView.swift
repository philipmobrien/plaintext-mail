import SwiftUI
import AppKit

/// Generic account-setup form - any IMAP/SMTP server, not just Runbox.
/// Used both for first-run (no accounts configured yet) and for adding
/// further accounts later via a real "Add Account" action, not just once.
struct AddAccountView: View {
    @ObservedObject var accountsStore: AccountsStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var email = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var password = ""

    private var isValid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !imapHost.trimmingCharacters(in: .whitespaces).isEmpty &&
        !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        Int(imapPort) != nil &&
        Int(smtpPort) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account")
                .font(.title2)
                .bold()

            Form {
                TextField("Display Name", text: $displayName)
                    .help("A label for this account, e.g. \"Personal\" or \"Studio\" - shown in the sidebar")
                TextField("Email Address", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)

                Section("Incoming Mail (IMAP)") {
                    TextField("Server", text: $imapHost)
                    TextField("Port", text: $imapPort)
                }
                Section("Outgoing Mail (SMTP)") {
                    TextField("Server", text: $smtpHost)
                    TextField("Port", text: $smtpPort)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Account") {
                    guard let imapPortInt = Int(imapPort), let smtpPortInt = Int(smtpPort) else { return }
                    accountsStore.addAccount(
                        displayName: displayName.trimmingCharacters(in: .whitespaces).isEmpty ? email : displayName,
                        email: email,
                        imapHost: imapHost, imapPort: imapPortInt,
                        smtpHost: smtpHost, smtpPort: smtpPortInt,
                        password: password
                    )
                    // Switching from this form to the main window is a
                    // content change within the same window, not a new
                    // window appearing - macOS doesn't automatically bring
                    // the app to the foreground for that, unlike a genuine
                    // new-window launch, so it's done explicitly here.
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 420, height: 480)
    }
}
