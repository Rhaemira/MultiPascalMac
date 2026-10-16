// Created by Amirali Yazdani on 10/16/26.
#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI

/// A native AppKit source editor. The line-number gutter is an NSRulerView
/// attached to the very same NSScrollView as the text view, so its vertical
/// position is driven by the editor's scroll position rather than a separate
/// SwiftUI ScrollView.
struct PascalCodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        // Install a TextKit 1 layout stack explicitly. This keeps the ruler's
        // NSLayoutManager glyph geometry available across macOS SDK versions.
        // `usesTextLayoutManager` is not a public NSTextView property in all
        // supported SDKs, so do not rely on it.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: CGFloat(1600), height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        let textView = PascalNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat(1600), height: CGFloat.greatestFiniteMagnitude)
            container.lineFragmentPadding = 0
        }

        textView.refreshSyntaxHighlighting()
        scrollView.documentView = textView
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak scrollView] _ in
            // This observer is explicitly delivered on the main queue. Tell
            // Swift 6 that the AppKit operation is safe on the main actor.
            MainActor.assumeIsolated {
                scrollView?.verticalRulerView?.needsDisplay = true
            }
        }

        let ruler = PascalLineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler
        ruler.refreshLineCount()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PascalNSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.refreshSyntaxHighlighting()
            // Preserve the caret/selection as much as possible during external updates.
            textView.selectedRanges = selection.map { range in
                let safeLocation = min(range.rangeValue.location, (text as NSString).length)
                let safeLength = min(range.rangeValue.length, (text as NSString).length - safeLocation)
                return NSValue(range: NSRange(location: safeLocation, length: safeLength))
            }
        }
        (scrollView.verticalRulerView as? PascalLineNumberRuler)?.refreshLineCount()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PascalCodeEditor
        fileprivate weak var ruler: PascalLineNumberRuler?
        var scrollObserver: NSObjectProtocol?

        init(_ parent: PascalCodeEditor) { self.parent = parent }

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PascalNSTextView else { return }
            parent.text = textView.string
            textView.refreshSyntaxHighlighting()
            ruler?.refreshLineCount()
        }
    }
}

private final class PascalNSTextView: NSTextView {
    /// Lightweight lexical coloring for the MPWin/Pascal dialect. Parsing and
    /// diagnostics remain owned by MPWinCore; this is editor presentation only.
    func refreshSyntaxHighlighting() {
        guard let storage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard fullRange.length > 0 else { return }

        let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        storage.beginEditing()
        storage.addAttributes([.font: codeFont, .foregroundColor: NSColor.textColor], range: fullRange)

        func paint(_ pattern: String, color: NSColor,
                   options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
                if let range = match?.range, range.length > 0 {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
        }

        let words: NSRegularExpression.Options = [.caseInsensitive]
        paint("\\b(program|architecture|const|type|var|shared|procedure|function|begin|end|if|then|else|case|of|while|do|repeat|until|for|to|downto|forall|grouping|fork|join|port|with|array|record|channel|spinlock|integer|real|boolean|char|nil|true|false)\\b",
              color: .systemPurple, options: words)
        paint("\\b(abs|sqr|odd|chr|ord|succ|pred|round|trunc|sin|cos|exp|ln|sqrt|arctan|eof|eoln|read|readln|write|writeln|new|dispose|lock|unlock|duration|seqtime|clock)\\b",
              color: .systemBlue, options: words)
        paint("%[A-Za-z][A-Za-z0-9]*", color: .systemPink, options: [.caseInsensitive])
        paint("\\b[0-9]+(?:\\.[0-9]+)?\\b", color: .systemOrange)
        paint("'(?:''|[^'])*'", color: .systemGreen)
        paint("\\{[\\s\\S]*?\\}|\\(\\*[\\s\\S]*?\\*\\)|//[^\\r\\n]*",
              color: .secondaryLabelColor)
        storage.endEditing()
        typingAttributes = [.font: codeFont, .foregroundColor: NSColor.textColor]
    }

    override func keyDown(with event: NSEvent) {
        // Standard editor shortcuts are left to AppKit.
        super.keyDown(with: event)
    }
}

private final class PascalLineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    func refreshLineCount() {
        guard let textView else { return }
        let lineCount = max(1, (textView.string as NSString).components(separatedBy: "\n").count)
        let digits = max(2, String(lineCount).count)
        let desiredThickness = CGFloat(digits) * 8.5 + 19
        if abs(ruleThickness - desiredThickness) > 0.5 {
            ruleThickness = desiredThickness
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let source = textView.string as NSString
        let lineHeight = max(1, textView.font?.boundingRectForFont.height ?? 16)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let textOrigin = textView.textContainerOrigin
        // NSRulerView is only as tall as the viewport, not the whole document.
        // Convert from text-view coordinates to ruler coordinates so scrolling,
        // flipped coordinate systems, and text insets are handled by AppKit.
        var lineStart = 0
        var lineNumber = 1

        // Draw logical line numbers against the text layout, not against a
        // second independently scrolling view. Wrapped source lines therefore
        // retain one number and the gutter tracks the editor automatically.
        while lineStart < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: lineStart, length: 0))
            let characterIndex = min(lineStart, max(0, source.length - 1))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil,
                                                          withoutAdditionalLayout: false)
            let textY = fragment.minY + textOrigin.y
                + max(0, (fragment.height - lineHeight) / 2)
            let y = convert(NSPoint(x: 0, y: textY), from: textView).y
            if y + lineHeight >= rect.minY && y <= rect.maxY {
                let label = NSAttributedString(string: String(lineNumber), attributes: attributes)
                let labelSize = label.size()
                label.draw(at: NSPoint(x: ruleThickness - labelSize.width - 9,
                                       y: y + (lineHeight - labelSize.height) / 2))
            }
            lineNumber += 1
            if lineEnd <= lineStart { break }
            lineStart = lineEnd
        }

        // NSTextView has an extra fragment for the empty line after a final newline.
        if source.length == 0 || (source.length > 0 && source.character(at: source.length - 1) == 10) {
            let extraRect = layoutManager.extraLineFragmentRect
            if !extraRect.isEmpty {
                let y = convert(NSPoint(x: 0, y: extraRect.minY + textOrigin.y),
                                from: textView).y
                if y + lineHeight >= rect.minY && y <= rect.maxY {
                    let label = NSAttributedString(string: String(lineNumber), attributes: attributes)
                    let labelSize = label.size()
                    label.draw(at: NSPoint(x: ruleThickness - labelSize.width - 9,
                                           y: y + (lineHeight - labelSize.height) / 2))
                }
            }
        }
    }
}

#endif
