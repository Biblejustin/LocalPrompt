import Foundation

/// An opt-in reading projection. It never changes the original note, opens
/// another note, or fetches a link. The ordinary Markdown renderer still owns
/// formatting and spoken-word coordinates after this projection is applied.
enum ObsidianMarkdown {
    static func readingSource(_ source: String) -> String {
        let body = removingFrontmatter(source)
        guard body.contains("[["), let protected = protectedRanges(in: body) else { return body }
        let text = body as NSString
        let expression = try! NSRegularExpression(pattern: #"\[\[([^\[\]\r\n]+)\]\]"#)
        let matches = expression.matches(in: body, range: NSRange(location: 0, length: text.length))
        let result = NSMutableString(string: body)
        for match in matches.reversed() {
            let range = match.range
            let token = text.substring(with: range)
            // Keep LocalPrompt's cue syntax for its existing context-aware
            // parser. Embedded notes remain literal; their contents are not read.
            guard token != "[[next-slide]]", !isEscaped(at: range.location, in: text),
                  range.location == 0 || ![33, 91].contains(Int(text.character(at: range.location - 1))),
                  NSMaxRange(range) == text.length || text.character(at: NSMaxRange(range)) != 93,
                  !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }

            let contents = text.substring(with: match.range(at: 1))
            let parts = contents.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts[0].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let alias = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            // Labels are text, not a second Markdown document. Escaping also
            // prevents an alias from creating a heading, link, or slide cue.
            result.replaceCharacters(in: range, with: escapedLabel(alias.isEmpty ? target : alias))
        }
        return result as String
    }

    private static func removingFrontmatter(_ source: String) -> String {
        let text = source as NSString
        let opening = try! NSRegularExpression(pattern: #"\A(?:\x{FEFF})?---[ \t]*(?:\r\n|\n|\r)"#)
        guard let start = opening.firstMatch(in: source, range: NSRange(location: 0, length: text.length)) else { return source }
        let closing = try! NSRegularExpression(pattern: #"(?m)^(?:---|\.\.\.)[ \t]*(?:\r\n|\n|\r|$)"#)
        let remainder = NSRange(location: NSMaxRange(start.range), length: text.length - NSMaxRange(start.range))
        guard let end = closing.firstMatch(in: source, range: remainder) else { return source }
        return text.substring(from: NSMaxRange(end.range))
    }

    private static func protectedRanges(in source: String) -> [NSRange]? {
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .throwError, appliesSourcePositionAttributes: true)
        ) else { return nil }
        var result: [NSRange] = []
        for run in parsed.runs {
            let codeBlock = run.presentationIntent?.components.contains { component in
                if case .codeBlock = component.kind { return true }
                return false
            } ?? false
            let inline = run.inlinePresentationIntent ?? []
            guard codeBlock || !inline.intersection([.code, .inlineHTML, .blockHTML]).isEmpty || run.link != nil else { continue }
            guard let position = run.markdownSourcePosition,
                  let range = Range(position, in: source) else { return nil }
            result.append(NSRange(range, in: source))
        }
        return result
    }

    private static func isEscaped(at position: Int, in text: NSString) -> Bool {
        var index = position
        var count = 0
        while index > 0, text.character(at: index - 1) == 92 {
            count += 1
            index -= 1
        }
        return count % 2 == 1
    }

    private static func escapedLabel(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 33...47, 58...64, 91...96, 123...126: result.append("\\")
            default: break
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
