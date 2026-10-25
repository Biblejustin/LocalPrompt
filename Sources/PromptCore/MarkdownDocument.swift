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

    public init(source: String) {
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .throwError, appliesSourcePositionAttributes: true)
        ) else {
            text = source
            trackingText = source
            runs = source.isEmpty ? [] : [MarkdownRun(range: NSRange(location: 0, length: source.utf16.count))]
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
               let sourceRange = Range(position, in: source),
               let label = try? AttributedString(markdown: String(source[sourceRange]), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
               String(label.characters) == content {
                for labelRun in label.runs {
                    builder.append(String(label[labelRun.range].characters), block: block, inline: inline.union(labelRun.inlinePresentationIntent ?? []))
                }
            } else {
                builder.append(content, block: block, inline: inline, decoration: block.thematicBreak)
            }
            previousBlock = block
        }
        text = builder.text
        trackingText = builder.trackingText
        runs = builder.runs
    }
}

private extension MarkdownDocument {
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
