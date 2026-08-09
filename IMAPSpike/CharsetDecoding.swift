import Foundation

enum CharsetDecoding {
    /// Decodes `data` using the named IANA/MIME charset (e.g. "iso-8859-1",
    /// "windows-1252", "iso-8859-13", "utf-8"). Falls back to UTF-8, then to
    /// a lossy UTF-8 decode if even that fails - so this never returns nil,
    /// it always produces *something* readable rather than losing the message.
    static func decode(_ data: Data, charset: String?) -> String {
        if let charset = charset, let encoding = foundationEncoding(for: charset) {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self) // final fallback: lossy, never fails
    }

    /// Maps an IANA/MIME charset name to a Foundation String.Encoding via
    /// CFString's built-in charset table. This covers a much wider range
    /// than Foundation's own String.Encoding cases directly expose -
    /// iso-8859-1 through iso-8859-16, windows-1250 through 1258, gb2312,
    /// shift-jis, koi8-r, and so on - all the charsets real-world mail
    /// actually uses, not just the handful with dedicated Swift constants.
    private static func foundationEncoding(for charset: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        guard nsEncoding != UInt(kCFStringEncodingInvalidId) else { return nil }
        return String.Encoding(rawValue: nsEncoding)
    }
}
