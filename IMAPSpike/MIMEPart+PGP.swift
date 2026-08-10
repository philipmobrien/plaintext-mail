import Foundation

extension MIMEPart {
    /// The raw PGP-armored block to decrypt, if this message contains
    /// one - checking both real-world forms:
    /// - PGP/MIME (RFC 3156): multipart/encrypted with
    ///   protocol="application/pgp-encrypted", ciphertext in the
    ///   accompanying application/octet-stream part.
    /// - Classic inline PGP: a -----BEGIN PGP MESSAGE----- ... -----END
    ///   PGP MESSAGE----- block embedded directly in a plain-text part -
    ///   what many people (including occasional command-line gpg users)
    ///   actually produce, not just the more "correct" MIME structure.
    var pgpEncryptedBlock: String? {
        if contentType == "multipart/encrypted", parameters["protocol"]?.lowercased() == "application/pgp-encrypted" {
            for part in subParts where part.contentType == "application/octet-stream" {
                return part.decodedText
            }
        }
        if isMultipart {
            for part in subParts {
                if let found = part.pgpEncryptedBlock { return found }
            }
            return nil
        }
        let text = decodedText
        if let startRange = text.range(of: "-----BEGIN PGP MESSAGE-----"),
           let endRange = text.range(of: "-----END PGP MESSAGE-----", range: startRange.upperBound..<text.endIndex) {
            return String(text[startRange.lowerBound..<endRange.upperBound])
        }
        return nil
    }
}
