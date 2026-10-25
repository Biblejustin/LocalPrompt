import AppKit
import SwiftUI
import PromptCore

private final class ClickableScriptView: NSTextView {
    var onWordClick: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onWordClick?(characterIndexForInsertion(at: point))
    }
}

private final class PrompterScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?

    override func layout() {
        super.layout()
        // SwiftUI can update the representable before assigning its first size,
        // and resizing a window does not necessarily call updateNSView again.
        onViewportLayout?()
    }
}

struct PrompterTextView: NSViewRepresentable {
    /// Keep the next line near the audience-facing edge of the screen.
    static let readingLineInset = 12.0

    let document: MarkdownDocument
    let words: [ScriptWord]
    let position: Int
    let fontSize: Double
    let margin: Double
    let onSeek: (Int) -> Void
    var readingTopInset: Double = Self.readingLineInset

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PrompterScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        let text = ClickableScriptView()
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.isRichText = true
        // The coordinator sizes the document explicitly, including enough space
        // below the final line to keep it at the reading guide.
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.setAccessibilityLabel("Teleprompter script. Click a word to jump to it.")
        scroll.documentView = text
        let coordinator = context.coordinator
        coordinator.textView = text
        text.onWordClick = { [weak coordinator] character in
            guard let presentation = coordinator?.presentation else { return }
            if let index = presentation.words.firstIndex(where: { NSMaxRange($0.range) > character }) {
                presentation.onSeek(index)
            }
        }
        scroll.onViewportLayout = { [weak coordinator, weak scroll] in
            guard let scroll else { return }
            coordinator?.apply(to: scroll)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.presentation = self
        context.coordinator.apply(to: scroll)
    }

    final class Coordinator {
        fileprivate var textView: ClickableScriptView?
        fileprivate var presentation: PrompterTextView?
        private var lastDocument: MarkdownDocument?
        private var lastFontSize: Double?
        private var lastMargin: Double?
        private var lastViewport: NSSize?
        private var lastReadingInset: Double?
        private var lastPosition = -1
        private var isApplying = false

        fileprivate func apply(to scroll: NSScrollView) {
            guard !isApplying, let text = textView, let presentation else { return }
            let viewport = scroll.contentSize
            guard viewport.width > 0, viewport.height > 0 else { return }
            let typographyChanged = lastDocument != presentation.document || lastFontSize != presentation.fontSize
            let layoutChanged = typographyChanged || lastViewport != viewport || lastMargin != presentation.margin || lastReadingInset != presentation.readingTopInset
            guard layoutChanged || lastPosition != presentation.position else { return }
            isApplying = true
            defer { isApplying = false }
            let previousPosition = lastPosition
            lastDocument = presentation.document
            lastFontSize = presentation.fontSize
            lastMargin = presentation.margin
            lastViewport = viewport
            lastReadingInset = presentation.readingTopInset
            lastPosition = presentation.position

            let words = presentation.words
            let position = min(max(0, presentation.position), words.count)
            guard let storage = text.textStorage else { return }
            storage.beginEditing()
            if typographyChanged { storage.setAttributedString(ScriptTypography.render(presentation.document, fontSize: presentation.fontSize)) }
            ScriptTypography.applyProgress(to: storage, words: words, position: position, previousPosition: typographyChanged ? nil : previousPosition)
            storage.endEditing()
            let readingLineY = max(0, presentation.readingTopInset)
            guard let layout = text.layoutManager, let container = text.textContainer else { return }
            if layoutChanged {
                text.textContainerInset = NSSize(width: max(36, presentation.margin), height: readingLineY)
                text.frame.size.width = viewport.width
                container.containerSize = NSSize(width: max(100, viewport.width - text.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
                layout.ensureLayout(for: container)
                // Keep enough space below the last line for it to reach the
                // same top reading guide as every earlier line.
                let usedHeight = layout.usedRect(for: container).maxY
                text.frame.size.height = max(viewport.height, usedHeight + viewport.height)
            }
            guard !words.isEmpty else { return }
            let index = min(position, words.count - 1)
            let glyphs = layout.glyphRange(forCharacterRange: words[index].range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let desiredY = text.textContainerOrigin.y + rect.minY - readingLineY
            let targetY = min(max(0, desiredY), max(0, text.frame.height - viewport.height))
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = layoutChanged ? 0 : 0.2
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
