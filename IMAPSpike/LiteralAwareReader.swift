import Foundation

/// Assembles raw bytes from an IMAP connection into complete logical lines,
/// correctly handling literals ({N}\r\n followed by exactly N raw octets).
///
/// A naive CRLF-only splitter breaks on any response containing a literal,
/// because the N literal bytes can themselves contain CRLF sequences that
/// aren't line terminators - they're just data. This is exactly the bug
/// session 2 exposed: message 1409's subject was sent as a literal, and
/// the plain splitter treated its continuation as an unrelated new line.
///
/// How it works: alternates between two modes.
///   - .line   : accumulate bytes until CRLF is found
///   - .literal: accumulate exactly N raw bytes, no CRLF search at all
///
/// When a chunk read in .line mode ends with "{N}", that means: the CRLF
/// terminates this chunk as normal, but immediately after it come N literal
/// bytes that belong to the *same* logical response, not a new one. So we
/// switch to .literal for N bytes, then switch back to .line to read the
/// rest of that same logical line (which may itself end in another "{N}",
/// e.g. an ENVELOPE with two literal fields).
final class LiteralAwareReader {
    private enum Mode {
        case line
        case literal(remaining: Int)
    }

    private var buffer = Data()
    private var mode: Mode = .line
    private var logicalLine = Data()
    private let onLogicalLine: (String) -> Void

    init(onLogicalLine: @escaping (String) -> Void) {
        self.onLogicalLine = onLogicalLine
    }

    /// Feed newly-received bytes in. Calls onLogicalLine for each complete
    /// logical line assembled (literals included as raw text, not surfaced
    /// separately).
    func feed(_ data: Data) {
        buffer.append(data)
        drain()
    }

    private func drain() {
        var madeProgress = true
        while madeProgress {
            madeProgress = false

            switch mode {
            case .line:
                guard let range = buffer.range(of: Data([0x0D, 0x0A])) else { return }
                let chunk = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                madeProgress = true

                if !logicalLine.isEmpty {
                    // Rejoin with a space where the literal boundary was,
                    // so IMAPResponse's space-based parsing still works.
                    logicalLine.append(0x20)
                }
                logicalLine.append(chunk)

                if let literalLength = Self.trailingLiteralLength(in: chunk) {
                    mode = .literal(remaining: literalLength)
                } else {
                    // No literal marker - this chunk completes the logical line.
                    emitLogicalLine()
                }

            case .literal(let remaining):
                guard buffer.count >= remaining else { return } // need more bytes
                let literalData = buffer.subdata(in: buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: remaining))
                buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: remaining))
                madeProgress = true

                logicalLine.append(literalData)
                mode = .line // resume looking for CRLF to finish this logical line
            }
        }
    }

    private func emitLogicalLine() {
        // Literal bytes are IMAP-server text (headers, envelope data) in
        // practice, so UTF-8 with a lossy fallback is good enough here.
        let text = String(data: logicalLine, encoding: .utf8)
            ?? String(decoding: logicalLine, as: UTF8.self)
        logicalLine.removeAll(keepingCapacity: true)
        onLogicalLine(text)
    }

    /// Returns N if `chunk` ends with a literal marker "{N}", else nil.
    /// e.g. "* 1409 FETCH (ENVELOPE (\"...\" {83}" -> 83
    private static func trailingLiteralLength(in chunk: Data) -> Int? {
        guard let text = String(data: chunk, encoding: .utf8),
              text.hasSuffix("}"),
              let openBrace = text.lastIndex(of: "{") else { return nil }

        let numberPart = text[text.index(after: openBrace)..<text.index(before: text.endIndex)]
        return Int(numberPart)
    }
}
