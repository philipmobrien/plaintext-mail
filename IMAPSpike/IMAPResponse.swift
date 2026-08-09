import Foundation

/// A parsed IMAP server response line, split into its three logical parts.
///
/// Every line an IMAP server sends decomposes into tag + key + text:
///   a3 OK Fetch completed.          -> tag: "a3",  key: "OK",    text: "Fetch completed."
///   * 1410 EXISTS                   -> tag: "*",   key: "1410",  text: "EXISTS"
///   * OK [UIDVALIDITY 123] valid    -> tag: "*",   key: "OK",    text: "[UIDVALIDITY 123] valid"
///   + Ready for more                -> tag: "+",   key: "",      text: "Ready for more"
///
/// This mirrors imap_parse_reply() from the UW IMAP reference client (via
/// Eudora's imap4r1.c) - splitting on the first two spaces rather than
/// prefix-matching whole lines, which is what Phase 0's spike did and why
/// it broke on SELECT's several "* OK [...]" lines.
struct IMAPResponse {
    let tag: String
    let key: String
    let text: String

    /// True if this is an untagged response ("*") - the kind that carries
    /// mailbox state (EXISTS, FETCH, FLAGS, etc.) rather than a direct
    /// reply to a specific command.
    var isUntagged: Bool { tag == "*" }

    /// True if this is a continuation request ("+") - the server is
    /// asking for more data, e.g. mid-literal or during AUTHENTICATE.
    var isContinuation: Bool { tag == "+" }

    /// True if the key is purely numeric, e.g. "* 1410 EXISTS" or "* 1401 FETCH (...)".
    /// In these cases the "key" we split on is actually a message sequence
    /// number, and the real keyword (EXISTS, FETCH, ...) is the first word of `text`.
    var isNumbered: Bool { !key.isEmpty && Int(key) != nil }

    /// For numbered responses, the actual keyword after the number.
    /// e.g. "* 1410 EXISTS" -> "EXISTS"
    var numberedKeyword: String? {
        guard isNumbered else { return nil }
        return text.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    /// Extracts an integer from a bracketed response-code, e.g. for
    /// "* OK [UIDVALIDITY 1557330953] UIDs valid", calling
    /// bracketedInt(named: "UIDVALIDITY") returns 1557330953.
    /// Returns nil if this response doesn't contain that response-code.
    func bracketedInt(named name: String) -> Int? {
        guard let openBracket = text.range(of: "[\(name) "),
              let closeBracket = text.range(of: "]", range: openBracket.upperBound..<text.endIndex) else {
            return nil
        }
        let numberText = text[openBracket.upperBound..<closeBracket.lowerBound]
        return Int(numberText)
    }

    /// For a MOVE/COPY response with UIDPLUS support, e.g.
    /// "[COPYUID 1557330953 1420 8842] Completed", extracts the message's
    /// new UID in the destination mailbox (the third number - first is
    /// UIDVALIDITY, second is the source UID, third is the destination UID).
    func copyUID() -> Int? {
        guard let openBracket = text.range(of: "[COPYUID "),
              let closeBracket = text.range(of: "]", range: openBracket.upperBound..<text.endIndex) else {
            return nil
        }
        let inner = text[openBracket.upperBound..<closeBracket.lowerBound]
        let parts = inner.split(separator: " ")
        guard parts.count == 3 else { return nil }
        return Int(parts[2])
    }

    /// For an APPEND response with UIDPLUS support, e.g.
    /// "[APPENDUID 1557330953 12345] APPEND completed", extracts the new
    /// message's UID (the second number - the first is UIDVALIDITY).
    /// Returns nil if the server didn't include this (UIDPLUS not supported,
    /// or some other reason) - the caller should treat that as "unknown for
    /// now, will show up on next sync" rather than an error.
    func appendUID() -> Int? {
        guard let openBracket = text.range(of: "[APPENDUID "),
              let closeBracket = text.range(of: "]", range: openBracket.upperBound..<text.endIndex) else {
            return nil
        }
        let inner = text[openBracket.upperBound..<closeBracket.lowerBound]
        let parts = inner.split(separator: " ")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }
    /// Extracts Runbox's own spam signal from a FETCH response that
    /// included BODY.PEEK[HEADER.FIELDS (X-Spam-Flag X-Spam-Status
    /// X-Spam-Score X-Spam-Level)] - a lightweight header-only fetch, not
    /// the full message body. Robust to which of these headers a given
    /// message actually has (not all providers/setups stamp all of them);
    /// scans line by line rather than assuming an exact header set or an
    /// exact boundary for where the block ends, since minor trailing
    /// protocol syntax after the header block doesn't match any of the
    /// prefixes being searched for anyway.
    func extractSpamSignal() -> (isFlagged: Bool, score: Double?) {
        guard let headerFieldsRange = text.range(of: "HEADER.FIELDS"),
              let closeBracket = text.range(of: "]", range: headerFieldsRange.upperBound..<text.endIndex) else {
            return (false, nil)
        }
        var rest = text[closeBracket.upperBound...]
        // Strip the leading "{N}" literal-length marker, same pattern used
        // elsewhere for BODY[] content.
        if rest.hasPrefix(" {") || rest.hasPrefix("{") {
            if rest.firstIndex(of: "{") != nil, let closeBrace = rest.firstIndex(of: "}") {
                rest = rest[rest.index(after: closeBrace)...]
            }
        }
        let headerBlock = String(rest)

        var isFlagged = false
        var score: Double?

        for rawLine in headerBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()

            if lower.hasPrefix("x-spam-flag:") {
                let value = line.dropFirst("x-spam-flag:".count).trimmingCharacters(in: .whitespaces)
                if value.uppercased().hasPrefix("YES") { isFlagged = true }
            } else if lower.hasPrefix("x-spam-score:") {
                let value = line.dropFirst("x-spam-score:".count).trimmingCharacters(in: .whitespaces)
                score = Double(value)
            } else if lower.hasPrefix("x-spam-status:") {
                let value = line.dropFirst("x-spam-status:".count)
                if value.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("YES") { isFlagged = true }
                if score == nil, let scoreRange = value.range(of: "score=") {
                    let afterScore = value[scoreRange.upperBound...]
                    let digits = afterScore.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
                    score = Double(digits)
                }
            }
        }
        return (isFlagged, score)
    }

    /// Parses a single "* LIST (flags) "delimiter" name" untagged response.
    /// The delimiter is always quoted; the name is only quoted if it needs
    /// to be (contains spaces or other specials) - a bare single-word name
    /// like "Sent" or "Trash" appears unquoted. An earlier version of this
    /// parser wrongly assumed the name was always the last quoted token,
    /// which meant it extracted the *delimiter* as the name for every
    /// plain-named folder (real bug: multiple folders all "named" "." -
    /// caught via a SwiftUI duplicate-ID warning). This version walks the
    /// structure properly: flags, then delimiter, then name, each handled
    /// whether quoted or bare.
    func parseListResponse() -> DiscoveredFolder? {
        guard key == "LIST" else { return nil }
        guard let flagsStart = text.firstIndex(of: "("),
              let flagsEnd = text.firstIndex(of: ")") else { return nil }
        let flagsText = text[text.index(after: flagsStart)..<flagsEnd]
        let flags = Set(flagsText.split(separator: " ").map(String.init))

        var rest = String(text[text.index(after: flagsEnd)...]).trimmingCharacters(in: .whitespaces)

        // Delimiter: a quoted single character, or the literal NIL - skip past it.
        if rest.hasPrefix("\"") {
            let afterOpen = rest.dropFirst()
            guard let closeIdx = afterOpen.firstIndex(of: "\"") else { return nil }
            rest = String(afterOpen[afterOpen.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
        } else if rest.hasPrefix("NIL") {
            rest = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        // What's left is the name - quoted (take the content between quotes)
        // or bare (take it as-is).
        let name: String
        if rest.hasPrefix("\"") {
            let afterOpen = rest.dropFirst()
            guard let closeIdx = afterOpen.firstIndex(of: "\"") else { return nil }
            name = String(afterOpen[afterOpen.startIndex..<closeIdx])
        } else {
            name = rest.trimmingCharacters(in: .whitespaces)
        }

        guard !name.isEmpty else { return nil }
        return DiscoveredFolder(name: name, specialUse: flags)
    }

    /// Extracts the set of flags from a FETCH response's FLAGS (...) data
    /// item, e.g. "FETCH (UID 22605 FLAGS (\Seen \Answered) ENVELOPE (...))"
    /// -> ["\Seen", "\Answered"]. Only meaningful if FLAGS was actually
    /// requested as part of the FETCH data items.
    func fetchFlags() -> Set<String> {
        guard let flagsRange = text.range(of: "FLAGS (") else { return [] }
        let afterFlags = text[flagsRange.upperBound...]
        guard let closeParen = afterFlags.firstIndex(of: ")") else { return [] }
        let flagsText = afterFlags[afterFlags.startIndex..<closeParen]
        return Set(flagsText.split(separator: " ").map(String.init))
    }

    /// For a FETCH response's text (e.g. "FETCH (UID 22605 ENVELOPE (...))"),
    /// extracts the real IMAP UID from the "UID nnnn" data item.
    ///
    /// This is deliberately distinct from `key`, which for FETCH responses
    /// is the message's SEQUENCE NUMBER (its position in the mailbox) - NOT
    /// its UID. The two look similar in casual single-session testing (a
    /// freshly SELECTed mailbox's early sequence numbers are small integers,
    /// same shape as UIDs), but they are fundamentally different concepts:
    /// sequence numbers shift whenever anything is expunged, UIDs never do.
    /// Conflating them is exactly what caused a real, mailbox-emptying bug -
    /// always use fetchUID(), never `key`, when you need a message's actual
    /// stable identity.
    func fetchUID() -> Int? {
        guard let uidRange = text.range(of: "UID ") else { return nil }
        let afterUID = text[uidRange.upperBound...]
        let digits = afterUID.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// Parses a raw line (already stripped of CRLF) into an IMAPResponse.
    /// Returns nil only for a genuinely empty line, which shouldn't happen
    /// in practice but is handled rather than force-unwrapped.
    static func parse(_ line: String) -> IMAPResponse? {
        guard !line.isEmpty else { return nil }

        // Split into at most 3 pieces: tag, key, rest-of-line.
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard let tag = parts.first else { return nil }

        // Continuation ("+") often has no separate key - the rest is straight text.
        if tag == "+" {
            let text = parts.count > 1 ? parts[1...].joined(separator: " ") : ""
            return IMAPResponse(tag: "+", key: "", text: text)
        }

        guard parts.count >= 2 else {
            // Tag with nothing else - malformed for our purposes, but don't crash.
            return IMAPResponse(tag: String(tag), key: "", text: "")
        }

        let key = String(parts[1])
        let text = parts.count > 2 ? String(parts[2]) : ""
        return IMAPResponse(tag: String(tag), key: key.uppercased(), text: text)
    }
}
