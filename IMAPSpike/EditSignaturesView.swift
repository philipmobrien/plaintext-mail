import SwiftUI

/// Edits each account's plain-text signature. Deliberately standalone
/// rather than folded into a general Preferences window - that's a bigger,
/// separately-scoped piece of work; this needed somewhere to live now.
struct EditSignaturesView: View {
    @ObservedObject var accountsStore: AccountsStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAccountID: UUID?
    @State private var draftText: String = ""

    var body: some View {
        HStack(spacing: 0) {
            List(accountsStore.accounts, selection: $selectedAccountID) { account in
                VStack(alignment: .leading) {
                    Text(account.displayName)
                    Text(account.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(account.id)
            }
            .frame(width: 200)
            .onChange(of: selectedAccountID) { _, newValue in
                saveCurrentDraft()
                draftText = accountsStore.accounts.first(where: { $0.id == newValue })?.signature ?? ""
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Signature")
                    .font(.headline)
                TextEditor(text: $draftText)
                    .font(.system(.body, design: .monospaced))
                    .border(Color.secondary.opacity(0.3))
                Text("Auto-appended below a \"-- \" delimiter line, the standard convention most mail clients recognise for signature blocks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .disabled(selectedAccountID == nil)
        }
        .frame(width: 560, height: 380)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") {
                    saveCurrentDraft()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .task {
            selectedAccountID = accountsStore.accounts.first?.id
            draftText = accountsStore.accounts.first?.signature ?? ""
        }
    }

    private func saveCurrentDraft() {
        guard let selectedAccountID else { return }
        accountsStore.updateSignature(for: selectedAccountID, signature: draftText)
    }
}
