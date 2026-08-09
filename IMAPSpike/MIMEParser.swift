import Foundation

/// A single parsed MIME part - either a leaf (text, image, attachment) or a
/// container (multipart/*) holding further parts. The top-level message
/// parses to a MIMEPart too, since a message *is* just a part with no
/// parent.
struct MIMEPart {
    var headers: [(name: String, value: String)]
    var contentType: String          // e.g. "text/plain", "multipart/alternative"
    var parameters: [String: String] // e.g. ["charset": "utf-8", "boundary": "..."]
    var transferEncoding: String     // e.g. "quoted-printable", "base64", "7bit"
    var rawBody: String              // body before transfer-decoding, empty for multipart containers
    var subParts: [MIMEPart]         // populated only for multipart/* containers

    var isMultipart: Bool { contentType.hasPrefix("multipart/") }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The body with Content-Transfer-Encoding reversed (quoted-printable /
    /// base64 decoded back to text) and the correct charset applied. Only
    /// meaningful for leaf parts.
    var decodedText: String {
        switch transferEncoding.lowercased() {
        case "quoted-printable":
            let data = MIMEParser.decodeQuotedPrintableData(rawBody)
            return CharsetDecoding.decode(data, charset: parameters["charset"])
        case "base64":
            let stripped = rawBody.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: stripped) else { return rawBody }
            return CharsetDecoding.decode(data, charset: parameters["charset"])
        default: // 7bit, 8bit, binary, or unspecified - already plain text.
            // NOTE: if this ever contains genuine non-UTF-8 raw bytes (rare -
            // QP/base64 exist precisely to avoid relying on raw 8-bit transport),
            // those bytes were already lossily converted to UTF-8 back at the
            // IMAP fetch layer, before this parser ever saw them. Not fixable
            // here without changing that layer to preserve raw Data throughout.
            return rawBody
        }
    }
}

enum MIMEParser {

    /// Parses a raw .eml file's full text (headers + body) into a MIMEPart tree.
    static func parse(_ raw: String) -> MIMEPart {
        // Defensive: strip a leftover IMAP literal-length marker like "{6035}"
        // if the corpus file still has one from before this was fixed at the
        // fetching stage. Real .eml files never start with "{".
        var raw = raw
        if raw.hasPrefix("{"), let closeBrace = raw.firstIndex(of: "}") {
            raw = String(raw[raw.index(after: closeBrace)...])
        }

        // Normalise line endings once, up front - removes any ambiguity
        // between \r\n and \n in the header/body split and header parsing
        // that follow, rather than juggling both everywhere.
        raw = raw.replacingOccurrences(of: "\r\n", with: "\n")

        let (headerBlock, body) = splitHeadersAndBody(raw)
        let headers = parseHeaders(headerBlock)
        let contentTypeHeader = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "text/plain"
        let (contentType, parameters) = parseContentType(contentTypeHeader)
        let transferEncoding = headers.first { $0.name.caseInsensitiveCompare("Content-Transfer-Encoding") == .orderedSame }?.value.trimmingCharacters(in: .whitespaces) ?? "7bit"

        if contentType.hasPrefix("multipart/"), let boundary = parameters["boundary"] {
            let subPartTexts = splitOnBoundary(body, boundary: boundary)
            let subParts = subPartTexts.map { parse($0) }
            return MIMEPart(headers: headers, contentType: contentType, parameters: parameters,
                             transferEncoding: transferEncoding, rawBody: "", subParts: subParts)
        } else {
            return MIMEPart(headers: headers, contentType: contentType, parameters: parameters,
                             transferEncoding: transferEncoding, rawBody: body, subParts: [])
        }
    }

    // MARK: - Header / body split

    /// Headers end at the first blank line (CRLF CRLF, or LF LF as a fallback
    /// for the odd message that isn't strictly CRLF-terminated).
    private static func splitHeadersAndBody(_ raw: String) -> (String, String) {
        if let range = raw.range(of: "\n\n") {
            return (String(raw[raw.startIndex..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        return (raw, "") // no body found - malformed, but don't crash
    }

    // MARK: - Header parsing (with folding + RFC 2047)

    /// Parses a header block into (name, value) pairs. Handles folding -
    /// continuation lines start with a space or tab and belong to the
    /// previous header (e.g. multi-line Content-Type, folded Subject).
    private static func parseHeaders(_ block: String) -> [(name: String, value: String)] {
        var result: [(String, String)] = []
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }

        for line in lines {
            if line.isEmpty { continue }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !result.isEmpty {
                // Continuation of the previous header - fold with a single space.
                result[result.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colonIndex = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colonIndex])
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                result.append((name, value))
            }
            // Lines with neither a colon nor a leading space are malformed - skip.
        }

        // Decode RFC 2047 encoded-words in every header value, not just Subject -
        // From/To display names can be encoded too (we saw this with a real sender's display name earlier).
        return result.map { (name: $0.0, value: EnvelopeParser.decodeEncodedWordsPublic($0.1)) }
    }

    // MARK: - Content-Type parsing

    /// Parses "multipart/alternative; boundary=\"...\"; charset=utf-8" into
    /// ("multipart/alternative", ["boundary": "...", "charset": "utf-8"]).
    private static func parseContentType(_ header: String) -> (String, [String: String]) {
        let parts = splitRespectingQuotes(header, separator: ";")
        guard let first = parts.first else { return ("text/plain", [:]) }
        let contentType = first.trimmingCharacters(in: .whitespaces).lowercased()

        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            var value = kv[1]
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            params[key] = value
        }
        return (contentType, params)
    }

    /// Splits on `separator`, but not when inside double quotes - needed
    /// because boundary values can (rarely) contain semicolons.
    private static func splitRespectingQuotes(_ text: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for char in text {
            if char == "\"" { inQuotes.toggle() }
            if char == separator && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }

    // MARK: - Multipart boundary splitting

    /// Splits a multipart body on "--boundary" markers. The part before the
    /// first marker (the "this is a MIME message" preamble) is discarded,
    /// as is anything after the final "--boundary--" (the epilogue).
    private static func splitOnBoundary(_ body: String, boundary: String) -> [String] {
        let marker = "--\(boundary)"
        var pieces = body.components(separatedBy: marker)
        guard pieces.count > 1 else { return [] } // no boundary found - malformed

        pieces.removeFirst() // preamble before the first boundary

        // The last piece starts with "--" (the closing boundary) followed by
        // the epilogue - strip that "--" and anything after it.
        if let last = pieces.last, let closingRange = last.range(of: "--") {
            pieces[pieces.count - 1] = String(last[last.startIndex..<closingRange.lowerBound])
        }

        return pieces.map { piece -> String in
            var p = piece
            // Each piece starts with a newline right after the boundary marker - trim it.
            if p.hasPrefix("\n") { p.removeFirst() }
            return p
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Quoted-printable decoding

    /// Decodes quoted-printable: "=XX" hex escapes, and "=\n" soft line
    /// breaks (which mean "this isn't really a line break, just here for
    /// line-length reasons" - remove them entirely). Returns raw bytes
    /// rather than a String, because we don't yet know the charset here -
    /// that's applied by the caller via CharsetDecoding.
    static func decodeQuotedPrintableData(_ text: String) -> Data {
        var result = Data()
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "=" {
                // Soft line break: "=\n" (already normalised from "=\r\n" upstream).
                if i + 1 < chars.count, chars[i+1] == "\n" {
                    i += 2
                    continue
                }
                // Hex escape: "=XX"
                if i + 2 < chars.count,
                   let byte = UInt8(String([chars[i+1], chars[i+2]]), radix: 16) {
                    result.append(byte)
                    i += 3
                    continue
                }
                // Malformed "=" not followed by valid hex or a line break - keep literally.
                result.append(contentsOf: Array("=".utf8))
                i += 1
            } else {
                result.append(contentsOf: Array(String(chars[i]).utf8))
                i += 1
            }
        }
        return result
    }
}
