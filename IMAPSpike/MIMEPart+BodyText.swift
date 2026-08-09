import Foundation

extension MIMEPart {
    /// Raw decoded bytes (quoted-printable/base64 reversed) without
    /// treating the result as text. Use this for attachments - decodedText
    /// runs the bytes through charset decoding, which would corrupt binary
    /// data like images or PDFs rather than just producing readable text.
    var decodedData: Data {
        switch transferEncoding.lowercased() {
        case "base64":
            let stripped = rawBody.filter { !$0.isWhitespace }
            return Data(base64Encoded: stripped) ?? Data(rawBody.utf8)
        case "quoted-printable":
            return MIMEParser.decodeQuotedPrintableData(rawBody)
        default:
            return Data(rawBody.utf8)
        }
    }

    /// One attachment found within a message's MIME tree.
    struct Attachment {
        let filename: String
        let contentType: String
        let part: MIMEPart
    }

    /// Walks the tree and collects every leaf part that looks like an
    /// attachment - identified by having a filename, via either
    /// Content-Disposition's filename= or Content-Type's name= parameter
    /// (older mail clients often only set the latter).
    func findAttachments() -> [Attachment] {
        var results: [Attachment] = []
        collectAttachments(into: &results)
        return results
    }

    private func collectAttachments(into results: inout [Attachment]) {
        if isMultipart {
            for sub in subParts { sub.collectAttachments(into: &results) }
            return
        }
        guard let filename = attachmentFilename() else { return }
        results.append(Attachment(filename: filename, contentType: contentType, part: self))
    }

    private func attachmentFilename() -> String? {
        if let disposition = header("Content-Disposition"),
           let name = Self.extractQuotedOrBareParameter(from: disposition, key: "filename") {
            return name
        }
        if let name = parameters["name"] {
            return name
        }
        return nil
    }

    /// Crude header-parameter extraction: key="value" or key=value.
    private static func extractQuotedOrBareParameter(from headerValue: String, key: String) -> String? {
        guard let range = headerValue.range(of: "\(key)=", options: .caseInsensitive) else { return nil }
        var rest = headerValue[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            if let endQuote = rest.firstIndex(of: "\"") {
                return String(rest[rest.startIndex..<endQuote])
            }
            return nil
        }
        if let semicolon = rest.firstIndex(of: ";") {
            return String(rest[rest.startIndex..<semicolon]).trimmingCharacters(in: .whitespaces)
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Walks the tree and returns the first text/plain part's decoded text,
    /// preferring it over text/html - the "best body to show" logic.
    func bestPlainText() -> String? {
        if contentType == "text/plain" { return decodedText }
        for sub in subParts {
            if let found = sub.bestPlainText() { return found }
        }
        return nil
    }

    /// Fallback for messages with no text/plain part at all: finds the
    /// first text/html part and converts it.
    func bestHTMLConvertedToText() -> String? {
        if contentType == "text/html" { return HTMLToText.convert(decodedText) }
        for sub in subParts {
            if let found = sub.bestHTMLConvertedToText() { return found }
        }
        return nil
    }

    /// The best available readable body: plain text if present, otherwise
    /// HTML converted to text, otherwise nil.
    func bestReadableBody() -> String? {
        bestPlainText() ?? bestHTMLConvertedToText()
    }
}
