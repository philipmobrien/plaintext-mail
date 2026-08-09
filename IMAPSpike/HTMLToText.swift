import Foundation

enum HTMLToText {

    /// Converts HTML to readable plain text: strips script/style content,
    /// turns block-level tags into line breaks (so paragraphs/list items
    /// don't run together), strips remaining tags, and decodes entities.
    /// Not a full HTML parser - good enough for displaying email bodies
    /// that have no text/plain alternative, not for anything more exacting.
    static func convert(_ html: String) -> String {
        var text = html

        // Drop hidden elements - a common trick where marketers pad the inbox
        // preview line with invisible text via style="display:none" (or
        // visibility:hidden / max-height:0 + overflow:hidden as variants).
        // Real example seen in the corpus: zero-width spaces and combining
        // marks stuffed into a hidden span purely to control the preview snippet.
        text = removeHiddenElements(text)

        // Drop script/style blocks entirely - their content is never meant to be read.
        text = removeBlock(text, tag: "script")
        text = removeBlock(text, tag: "style")

        // HTML comments (we saw a real example of these being used for
        // internal marketer notes in the corpus - never meant for the reader).
        text = removeBetween(text, open: "<!--", close: "-->")

        // Block-level tags become line breaks *before* we strip tags, so
        // paragraphs and list items don't get mashed into one run-on line.
        let blockTags = ["br", "/p", "/div", "/li", "/tr", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6", "/table"]
        for tag in blockTags {
            text = replaceTagCaseInsensitive(text, tag: tag, with: "\n")
        }
        // List items get a bullet prefix for readability.
        text = replaceTagCaseInsensitive(text, tag: "li", with: "\n• ")

        // Strip every remaining tag.
        text = stripAllTags(text)

        // Decode HTML entities.
        text = decodeEntities(text)

        // Collapse runs of blank lines and trailing whitespace per line,
        // since stripped-out tags/attributes tend to leave a lot of it behind.
        text = collapseWhitespace(text)

        return text
    }

    // MARK: - Building blocks

    /// Removes elements whose style attribute marks them as hidden
    /// (display:none, visibility:hidden). Handles the common single-level
    /// case (span/div wrapping only text, no nested tags of the same name) -
    /// good enough for the preheader-padding pattern this targets, not a
    /// general CSS-aware renderer.
    private static func removeHiddenElements(_ text: String) -> String {
        var result = text
        let pattern = #"<(\w+)\b[^>]*style\s*=\s*["'][^"']*(?:display\s*:\s*none|visibility\s*:\s*hidden)[^"']*["'][^>]*>.*?</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return result
        }
        // Repeat until no more matches - handles multiple hidden blocks in one document.
        var previousLength = -1
        while result.count != previousLength {
            previousLength = result.count
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    /// Removes an entire <tag>...</tag> block including its content, case-insensitively.
    private static func removeBlock(_ text: String, tag: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func removeBetween(_ text: String, open: String, close: String) -> String {
        var result = text
        while let openRange = result.range(of: open),
              let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result
    }

    /// Replaces occurrences of a specific tag (open, close, or self-closing) with `replacement`.
    /// e.g. tag "br" matches <br>, <br/>, <br />, case-insensitively.
    private static func replaceTagCaseInsensitive(_ text: String, tag: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*/?>",
            options: [.caseInsensitive]
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// Strips every remaining <...> tag.
    private static func stripAllTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Decodes the common named entities plus numeric (&#123;) and hex (&#x7B;) entities.
    private static func decodeEntities(_ text: String) -> String {
        var result = text

        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
            "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}", "&copy;": "©",
            "&reg;": "®", "&trade;": "™",
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric decimal entities: &#8217;
        if let regex = try? NSRegularExpression(pattern: "&#([0-9]+);") {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range).reversed() // reversed so ranges stay valid as we edit
            for match in matches {
                guard let numRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result),
                      let code = UInt32(result[numRange]),
                      let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        // Numeric hex entities: &#x2019;
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9A-Fa-f]+);") {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range).reversed()
            for match in matches {
                guard let hexRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result),
                      let code = UInt32(result[hexRange], radix: 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return result
    }

    /// Collapses 3+ consecutive newlines down to 2 (one blank line between
    /// paragraphs, not five), and trims trailing whitespace from each line.
    private static func collapseWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            line.trimmingCharacters(in: .whitespaces)
        }
        var result: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { result.append(line) } // allow one blank line, drop the rest
            } else {
                blankRun = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
