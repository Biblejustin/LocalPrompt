import AppKit
import PromptCore

/// Turns Markdown semantics into native text. Progress only changes foreground
/// colors, so emphasis and block layout survive every recognition update.
enum ScriptTypography {
    static let unread = NSColor(white: 0.92, alpha: 1)
    static let read = NSColor(white: 0.42, alpha: 1)
    static let current = NSColor(red: 0.42, green: 0.9, blue: 0.7, alpha: 1)

    static func render(_ document: MarkdownDocument, fontSize: Double) -> NSAttributedString {
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = fontSize * 0.28
        baseParagraph.paragraphSpacing = fontSize * 0.25
        let content = NSMutableAttributedString(string: document.text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: unread,
            .paragraphStyle: baseParagraph
        ])
        for run in document.runs {
            guard run.range.length > 0, NSMaxRange(run.range) <= content.length else { continue }
            let headingScale: Double
            switch run.headingLevel {
            case 1: headingScale = 1.3
            case 2: headingScale = 1.15
            case 3: headingScale = 1.07
            default: headingScale = 1
            }
            let pointSize = fontSize * headingScale * (run.code ? 0.92 : 1)
            let weight: NSFont.Weight = run.bold || run.headingLevel != nil ? .bold : .regular
            var font = run.code
                ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
                : NSFont.systemFont(ofSize: pointSize, weight: weight)
            if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            content.addAttribute(.font, value: font, range: run.range)
            let paragraph = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            let quoteIndent = Double(run.quoteDepth) * fontSize * 0.65
            let listIndent = Double(run.listDepth) * fontSize * 0.65
            paragraph.firstLineHeadIndent = quoteIndent + max(0, listIndent - fontSize * 0.55)
            paragraph.headIndent = quoteIndent + listIndent
            if run.headingLevel != nil {
                paragraph.paragraphSpacingBefore = fontSize * 0.15
                paragraph.paragraphSpacing = fontSize * 0.3
            }
            content.addAttribute(.paragraphStyle, value: paragraph, range: run.range)
            if run.code {
                content.addAttribute(.backgroundColor, value: NSColor(white: 1, alpha: 0.045), range: run.range)
            }
            if run.strikethrough {
                content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
            }
        }
        return content
    }

    static func applyProgress(to text: NSMutableAttributedString, words: [ScriptWord], position: Int, previousPosition: Int?) {
        let position = min(max(0, position), words.count)
        let readEnd = position > 0 ? NSMaxRange(words[position - 1].range) : 0
        if let previousPosition {
            let previous = min(max(0, previousPosition), words.count)
            let previousReadEnd = previous > 0 ? NSMaxRange(words[previous - 1].range) : 0
            if position < previous {
                let previousCurrentEnd = previous < words.count ? NSMaxRange(words[previous].range) : previousReadEnd
                text.addAttribute(.foregroundColor, value: unread, range: NSRange(location: readEnd, length: max(0, previousCurrentEnd - readEnd)))
            } else if readEnd > previousReadEnd {
                text.addAttribute(.foregroundColor, value: read, range: NSRange(location: previousReadEnd, length: readEnd - previousReadEnd))
            }
        } else if readEnd > 0 {
            text.addAttribute(.foregroundColor, value: read, range: NSRange(location: 0, length: readEnd))
        }
        if position < words.count {
            text.addAttribute(.foregroundColor, value: current, range: words[position].range)
        }
    }
}
