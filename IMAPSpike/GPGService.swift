import Foundation

/// Wraps the local `gpg` binary (from GPG Suite/GPGTools or Homebrew) for
/// PGP decryption - shelling out to the real, battle-tested GPG
/// implementation rather than bundling a less-audited Swift crypto
/// library. PGP's whole value depends on correctly interoperating with
/// whatever the other party's own GPG setup produced; using GPG itself
/// sidesteps any compatibility risk a smaller library might carry.
enum GPGService {
    /// Common install locations across GPGTools/GPG Keychain and Homebrew
    /// (Intel and Apple Silicon differ) - checked in order, first match
    /// wins. Not hardcoded to one path since this varies by setup.
    private static let candidatePaths = [
        "/usr/local/MacGPG2/bin/gpg",
        "/usr/local/bin/gpg",
        "/opt/homebrew/bin/gpg",
        "/usr/bin/gpg",
    ]

    static var gpgPath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { gpgPath != nil }

    enum GPGError: LocalizedError {
        case notInstalled
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "GPG isn't installed or couldn't be found. Install GPG Suite (gpgtools.org) or Homebrew's gnupg package."
            case .processFailed(let message):
                return message
            }
        }
    }

    /// Decrypts a PGP-armored block, returning the plaintext. Runs off the
    /// main thread since gpg can genuinely block waiting on its own
    /// separate pinentry passphrase dialog - this app never sees or
    /// handles the passphrase itself, GPG's own trusted system does that
    /// entirely outside this process.
    static func decrypt(_ armoredText: String) async throws -> String {
        guard let gpgPath else { throw GPGError.notInstalled }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gpgPath)
            // Deliberately not setting --pinentry-mode - leaving gpg's own
            // default behavior in place, which allows gpg-agent to invoke
            // pinentry normally for a passphrase-protected key. --batch
            // suppresses other interactive terminal prompts we don't want
            // from a background process, but doesn't affect pinentry,
            // which is a separate windowed mechanism, not a stdin prompt.
            process.arguments = ["--decrypt", "--quiet", "--batch", "--yes"]

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()

            inputPipe.fileHandleForWriting.write(Data(armoredText.utf8))
            try inputPipe.fileHandleForWriting.close()

            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if process.terminationStatus != 0 {
                let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GPGError.processFailed(errorMessage?.isEmpty == false ? errorMessage! : "GPG decryption failed (exit code \(process.terminationStatus))")
            }

            return String(data: outputData, encoding: .utf8) ?? ""
        }.value
    }
}
