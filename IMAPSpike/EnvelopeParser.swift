import Foundation

/// A parsed IMAP ENVELOPE response.
/// Structure: (date subject from sender reply-to to cc bcc in-reply-to message-id)
/// Each address field is either NIL or a list of (personal adl mailbox host) tuples.
struct ParsedEnvelope {
    var date: Date?
    var subject: String
    var fromAddress: String?   // "mailbox@host" of the first From address
    var toAddress: String?     // "mailbox@host" of the first To address - this is the alias match
    var messageId: String?
}

enum EnvelopeParser {

    /// Parses the text that follows "ENVELOPE " in a FETCH response, e.g.
    /// ("Mon, 3 Aug 2026 13:52:43 +0000" "Subject" ((...)) ((...)) ((...)) ((...)) NIL NIL NIL "<id>")
    static func parse(_ text: String) -> ParsedEnvelope? {
        var cursor = text[text.startIndex...]
        guard consume(&cursor, "(") else { return nil }

        let rawDate = parseStringOrNil(&cursor)
        let subject = parseStringOrNil(&cursor) ?? "(no subject)"
        let from = parseAddressList(&cursor)
        _ = parseAddressList(&cursor)      // sender - not stored yet
        _ = parseAddressList(&cursor)      // reply-to - not stored yet
        let to = parseAddressList(&cursor)
        _ = parseAddressList(&cursor)      // cc
        _ = parseAddressList(&cursor)      // bcc
        _ = parseStringOrNil(&cursor)      // in-reply-to
        let messageId = parseStringOrNil(&cursor)

        return ParsedEnvelope(
            date: rawDate.flatMap(parseRFC822Date),
            subject: decodeEncodedWords(subject),
            fromAddress: from.first,
            toAddress: to.first,
            messageId: messageId
        )
    }

    // MARK: - Low-level parsing

    private static func consume(_ cursor: inout Substring, _ char: Character) -> Bool {
        skipSpaces(&cursor)
        guard cursor.first == char else { return false }
        cursor.removeFirst()
        return true
    }

    private static func skipSpaces(_ cursor: inout Substring) {
        while cursor.first == " " { cursor.removeFirst() }
    }

    /// Parses a string field: quoted "...", literal {N}<N chars>, or NIL.
    private static func parseStringOrNil(_ cursor: inout Substring) -> String? {
        skipSpaces(&cursor)

        if cursor.hasPrefix("NIL") {
            cursor.removeFirst(3)
            return nil
        }

        if cursor.first == "\"" {
            cursor.removeFirst()
            var result = ""
            while let c = cursor.first, c != "\"" {
                if c == "\\" {
                    cursor.removeFirst()
                    if let escaped = cursor.first { result.append(escaped); cursor.removeFirst() }
                } else {
                    result.append(c)
                    cursor.removeFirst()
                }
            }
            if cursor.first == "\"" { cursor.removeFirst() }
            return result
        }

        if cursor.first == "{" {
            cursor.removeFirst()
            var digits = ""
            while let c = cursor.first, c.isNumber { digits.append(c); cursor.removeFirst() }
            guard cursor.first == "}" else { return nil }
            cursor.removeFirst()
            guard let length = Int(digits) else { return nil }
            let end = cursor.index(cursor.startIndex, offsetBy: min(length, cursor.count))
            let result = String(cursor[cursor.startIndex..<end])
            cursor = cursor[end...]
            return result
        }

        return nil
    }

    /// Parses an address list: NIL, or ( (personal adl mailbox host) ... )
    /// Returns "mailbox@host" for each address found.
    private static func parseAddressList(_ cursor: inout Substring) -> [String] {
        skipSpaces(&cursor)

        if cursor.hasPrefix("NIL") {
            cursor.removeFirst(3)
            return []
        }

        guard consume(&cursor, "(") else { return [] }

        var results: [String] = []
        while cursor.first == "(" {
            cursor.removeFirst()
            _ = parseStringOrNil(&cursor)          // personal name - not stored yet
            _ = parseStringOrNil(&cursor)          // adl
            let mailbox = parseStringOrNil(&cursor)
            let host = parseStringOrNil(&cursor)
            if let mailbox = mailbox, let host = host {
                results.append("\(mailbox)@\(host)")
            }
            _ = consume(&cursor, ")")
            skipSpaces(&cursor)
        }
        _ = consume(&cursor, ")")
        return results
    }

    // MARK: - Date

    private nonisolated static func parseRFC822Date(_ raw: String) -> Date? {
        // Real-world Date headers vary more than a single fixed format
        // handles: some senders omit the weekday, some use a named timezone
        // abbreviation ("GMT", "UTC") instead of a numeric offset ("+0000").
        // Try several variants rather than silently falling back to "now"
        // (which is what happens if this returns nil - the caller does
        // `parsed.date ?? Date()`, so a parse failure quietly mis-dates
        // the message as "today" with no visible sign anything went wrong).
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",   // "Mon, 3 Aug 2026 13:52:43 +0000"
            "d MMM yyyy HH:mm:ss Z",         // no weekday
            "EEE, d MMM yyyy HH:mm:ss zzz",  // named zone: "Mon, 3 Aug 2026 13:52:43 GMT"
            "d MMM yyyy HH:mm:ss zzz",       // no weekday, named zone
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Try the raw string as-is against every format.
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }

        // Then try again with any trailing "(UTC)"-style comment stripped.
        if let parenIndex = raw.firstIndex(of: "(") {
            let trimmed = raw[..<parenIndex].trimmingCharacters(in: .whitespaces)
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: trimmed) { return date }
            }
        }

        // Every format failed - flag it loudly rather than let the message
        // silently get "today"'s date. Worth adding the actual raw string
        // seen here as a new format variant once this fires.
        print("WARNING: could not parse date header: \"\(raw)\"")
        return nil
    }

    // MARK: - RFC 2047 encoded-word subjects

    /// Decodes "=?charset?Q?...?=" and "=?charset?B?...?=" sequences seen in
    /// subjects like "=?UTF-8?B?U3RlbGxlbmJvc2No4oCZcw==?= remarkable 2025s".
    /// Minimal implementation - handles the common UTF-8 Q/B cases seen so far,
    /// not the full RFC 2047 edge case set.
    /// Exposed (not private) so MIMEParser can reuse this for all headers,
    /// not just ENVELOPE subjects.
    static func decodeEncodedWordsPublic(_ input: String) -> String {
        decodeEncodedWords(input)
    }

    private static func decodeEncodedWords(_ input: String) -> String {
        var result = ""
        var remaining = input[input.startIndex...]
        var justDecodedWord = false

        while let range = remaining.range(of: "=?") {
            let between = remaining[remaining.startIndex..<range.lowerBound]
            let afterMarker = remaining[range.upperBound...]

            guard let closing = afterMarker.range(of: "?="),
                  let decoded = decodeSingleEncodedWord(String(afterMarker[afterMarker.startIndex..<closing.lowerBound])) else {
                result += between
                result += "=?"
                remaining = afterMarker
                justDecodedWord = false
                continue
            }

            // RFC 2047: whitespace-only gap between two encoded-words is a
            // line-splitting artefact, not a real space - drop it. Any other
            // gap (real text, or gap before the very first encoded-word) is kept.
            if justDecodedWord && between.allSatisfy({ $0.isWhitespace }) {
                // drop the gap entirely
            } else {
                result += between
            }

            result += decoded
            remaining = afterMarker[closing.upperBound...]
            justDecodedWord = true
        }
        result += remaining
        return result
    }

    private static func decodeSingleEncodedWord(_ body: String) -> String? {
        let parts = body.split(separator: "?", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let charset = String(parts[0])
        let encoding = String(parts[1]).uppercased()
        let text = String(parts[2])

        switch encoding {
        case "B":
            guard let data = Data(base64Encoded: text) else { return nil }
            return CharsetDecoding.decode(data, charset: charset)
        case "Q":
            let underscoresReplaced = text.replacingOccurrences(of: "_", with: " ")
            var bytes: [UInt8] = []
            var literalChars = ""
            let chars = Array(underscoresReplaced)
            var i = 0

            // Flushes any plain (non-escaped) ASCII characters collected so
            // far into the byte buffer, so escaped and literal bytes stay
            // in the correct order for charset decoding at the end.
            func flushLiteral() {
                bytes.append(contentsOf: Array(literalChars.utf8))
                literalChars = ""
            }

            while i < chars.count {
                if chars[i] == "=", i + 2 < chars.count,
                   let byte = UInt8(String([chars[i+1], chars[i+2]]), radix: 16) {
                    flushLiteral()
                    bytes.append(byte)
                    i += 3
                } else {
                    literalChars.append(chars[i])
                    i += 1
                }
            }
            flushLiteral()
            return CharsetDecoding.decode(Data(bytes), charset: charset)
        default:
            return nil
        }
    }
}
