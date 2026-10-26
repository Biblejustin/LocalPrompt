import Foundation

/// Presentation attributes in UTF-16 coordinates of the rendered document.
public struct MarkdownRun: Equatable, Sendable {
    public let range: NSRange
    public let headingLevel: Int?
    public let bold: Bool
    public let italic: Bool
    public let code: Bool
    public let quoteDepth: Int
    public let listDepth: Int
    public let strikethrough: Bool

    public init(
        range: NSRange,
        headingLevel: Int? = nil,
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
        quoteDepth: Int = 0,
        listDepth: Int = 0,
        strikethrough: Bool = false
    ) {
        self.range = range
        self.headingLevel = headingLevel
        self.bold = bold
        self.italic = italic
        self.code = code
        self.quoteDepth = quoteDepth
        self.listDepth = listDepth
        self.strikethrough = strikethrough
    }
}

/// A reading projection of Markdown. The editor can retain the original source.
///
/// Foundation parses syntax and supplies block/inline intents. Block separators
/// and list labels are reconstructed here because AttributedString does not
/// include them in its characters. No links or images are fetched.
public struct MarkdownDocument: Equatable, Sendable {
    public let text: String
    /// Same UTF-16 length as `text`; generated decorations are replaced by spaces.
    /// This keeps speech matching and text-view highlighting in one coordinate space.
    public let trackingText: String
    public let runs: [MarkdownRun]
    /// Silent actions positioned after the preceding rendered spoken words.
    public let slideCues: [SlideCue]

    public init(source: String) {
        let prepared = Self.prepareCues(in: source)
        let renderingSource = prepared.source
        guard let parsed = try? AttributedString(
            markdown: renderingSource,
            options: .init(interpretedSyntax: .full, failurePolicy: .throwError, appliesSourcePositionAttributes: true)
        ) else {
            var builder = Builder()
            builder.append(renderingSource, block: Block(nil))
            self.init(builder: builder, markers: prepared.markers)
            return
        }

        var builder = Builder()
        var previousBlock: Block?
        var emittedListItems = Set<Int>()
        for run in parsed.runs {
            let block = Block(run.presentationIntent)
            let inline = run.inlinePresentationIntent ?? []
            if let previousBlock, previousBlock.identity != block.identity {
                builder.separate(with: block.separator(after: previousBlock), block: previousBlock)
            }

            if previousBlock?.identity != block.identity,
               let item = block.listItem,
               emittedListItems.insert(item.identity).inserted {
                builder.append(block.orderedList ? "\(item.ordinal). " : "• ", block: block, decoration: true)
            }

            // Keep intentional script line breaks, including CommonMark soft
            // breaks (which Foundation otherwise turns into spaces).
            let content = inline.contains(.softBreak) ? "\n" : String(parsed[run.range].characters)
            // Foundation's full parser flattens emphasis within link labels.
            // Reparse that exact label using its native source coordinates;
            // accept it only when its characters agree with the full parse.
            if run.link != nil,
               let position = run.markdownSourcePosition,
               let sourceRange = Range(position, in: renderingSource),
               let label = try? AttributedString(markdown: String(renderingSource[sourceRange]), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
               String(label.characters) == content {
                for labelRun in label.runs {
                    builder.append(String(label[labelRun.range].characters), block: block, inline: inline.union(labelRun.inlinePresentationIntent ?? []))
                }
            } else {
                builder.append(content, block: block, inline: inline, decoration: block.thematicBreak)
            }
            previousBlock = block
        }
        self.init(builder: builder, markers: prepared.markers)
    }

    private init(builder: Builder, markers: [String]) {
        let result = builder.removingCues(markers)
        text = result.builder.text
        trackingText = result.builder.trackingText
        runs = result.builder.runs
        if result.offsets.isEmpty {
            slideCues = []
        } else {
            let words = ScriptTracker(script: result.builder.trackingText).words
            slideCues = result.offsets.enumerated().map { id, offset in
                SlideCue(id: id, wordPosition: words.prefix { NSMaxRange($0.range) <= offset }.count)
            }
        }
    }
}

private extension MarkdownDocument {
    static func prepareCues(in source: String) -> (source: String, markers: [String]) {
        guard source.contains("[[next-slide]]") else { return (source, []) }
        let expression = try! NSRegularExpression(pattern: #"(?m)^[ \t]*\[\[next-slide\]\][ \t]*\r?$"#)
        let candidates = expression.matches(in: source, range: NSRange(location: 0, length: source.utf16.count)).map(\.range)
        guard !candidates.isEmpty, let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .throwError, appliesSourcePositionAttributes: true)
        ) else { return (source, []) }

        // Native Markdown source ranges distinguish commands from examples in
        // fenced/indented code, multiline code spans, and link labels.
        let excluded = parsed.runs.compactMap { run -> NSRange? in
            let inline = run.inlinePresentationIntent ?? []
            guard Block(run.presentationIntent).code || !inline.intersection([.code, .inlineHTML, .blockHTML]).isEmpty || run.link != nil,
                  let position = run.markdownSourcePosition,
                  let range = Range(position, in: source) else { return nil }
            return NSRange(range, in: source)
        }
        let ranges = candidates.filter { candidate in
            !excluded.contains { NSIntersectionRange(candidate, $0).length > 0 }
        }.map { (source as NSString).range(of: "[[next-slide]]", options: [], range: $0) }
        // Internal markers survive Markdown parsing, then disappear together
        // with their exact UTF-16 ranges. Avoid collisions with literal text.
        var prefix = "\u{E000}LocalPromptCue"
        while source.contains(prefix) { prefix += "X" }
        let markers = ranges.indices.map { "\(prefix)\($0)\u{E001}" }
        let prepared = NSMutableString(string: source)
        for index in ranges.indices.reversed() {
            prepared.replaceCharacters(in: ranges[index], with: markers[index])
        }
        return (prepared as String, markers)
    }

    struct Block {
        let identity: Int?
        var headingLevel: Int?
        var quoteDepth = 0
        var listDepth = 0
        var code = false
        var thematicBreak = false
        var listItem: (identity: Int, ordinal: Int)?
        var orderedList = false
        var listIdentities = Set<Int>()
        var tableIdentity: Int?
        var tableRowIdentity: Int?
        var tableHeader = false

        init(_ intent: PresentationIntent?) {
            let components = intent?.components ?? []
            identity = components.first?.identity
            for component in components {
                switch component.kind {
                case .header(let level):
                    headingLevel = level
                case .blockQuote:
                    quoteDepth += 1
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (component.identity, ordinal) }
                case .orderedList, .unorderedList:
                    if listDepth == 0 { orderedList = component.kind == .orderedList }
                    listDepth += 1
                    listIdentities.insert(component.identity)
                case .codeBlock:
                    code = true
                case .thematicBreak:
                    thematicBreak = true
                case .table:
                    tableIdentity = component.identity
                case .tableHeaderRow:
                    tableHeader = true
                    tableRowIdentity = component.identity
                case .tableRow:
                    tableRowIdentity = component.identity
                default:
                    break
                }
            }
        }

        func separator(after previous: Block) -> String {
            if let tableIdentity, tableIdentity == previous.tableIdentity {
                return tableRowIdentity == previous.tableRowIdentity ? "\t" : "\n"
            }
            if !listIdentities.isDisjoint(with: previous.listIdentities),
               listItem?.identity != previous.listItem?.identity {
                return "\n"
            }
            return "\n\n"
        }
    }

    struct Builder {
        var text = ""
        var trackingText = ""
        var runs: [MarkdownRun] = []
        var utf16Length = 0

        func removingCues(_ markers: [String]) -> (builder: Builder, offsets: [Int]) {
            guard !markers.isEmpty else { return (self, []) }
            let source = text as NSString
            let spoken = trackingText as NSString
            var removed: [NSRange] = []
            for marker in markers {
                var range = source.range(of: marker)
                guard range.location != NSNotFound else { continue }
                // Remove the command's following line break, retaining the
                // separator before it. Leading commands leave no top padding.
                while NSMaxRange(range) < source.length, source.character(at: NSMaxRange(range)) == 10 {
                    range.length += 1
                }
                removed.append(range)
            }
            removed.sort { $0.location < $1.location }
            var result = Builder()
            var offsets: [Int] = []
            var cursor = 0
            func appendRange(_ range: NSRange, to result: inout Builder) {
                guard range.length > 0 else { return }
                let outputStart = result.utf16Length
                result.text += source.substring(with: range)
                result.trackingText += spoken.substring(with: range)
                for run in runs {
                    let part = NSIntersectionRange(run.range, range)
                    guard part.length > 0 else { continue }
                    result.runs.append(MarkdownRun(
                        range: NSRange(location: outputStart + part.location - range.location, length: part.length),
                        headingLevel: run.headingLevel, bold: run.bold, italic: run.italic,
                        code: run.code, quoteDepth: run.quoteDepth, listDepth: run.listDepth,
                        strikethrough: run.strikethrough
                    ))
                }
                result.utf16Length += range.length
            }
            for range in removed {
                appendRange(NSRange(location: cursor, length: range.location - cursor), to: &result)
                offsets.append(result.utf16Length)
                cursor = NSMaxRange(range)
            }
            appendRange(NSRange(location: cursor, length: source.length - cursor), to: &result)
            return (result, offsets)
        }

        mutating func separate(with separator: String, block: Block) {
            // Code blocks already end with a newline. Do not accidentally add
            // a third blank line at the following block boundary.
            if separator.first == "\n" {
                let existing = text.reversed().prefix(while: { $0 == "\n" }).count
                let required = separator.count - existing
                if required > 0 { append(String(repeating: "\n", count: required), block: block) }
            } else {
                append(separator, block: block, decoration: true)
            }
        }

        mutating func append(
            _ value: String,
            block: Block,
            inline: InlinePresentationIntent = [],
            decoration: Bool = false
        ) {
            let length = value.utf16.count
            guard length > 0 else { return }
            text.append(value)
            trackingText.append(decoration ? String(repeating: " ", count: length) : value)
            runs.append(MarkdownRun(
                range: NSRange(location: utf16Length, length: length),
                headingLevel: block.headingLevel,
                bold: inline.contains(.stronglyEmphasized) || block.tableHeader,
                italic: inline.contains(.emphasized),
                code: block.code || inline.contains(.code),
                quoteDepth: block.quoteDepth,
                listDepth: block.listDepth,
                strikethrough: inline.contains(.strikethrough)
            ))
            utf16Length += length
        }
    }
}
