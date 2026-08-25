import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

/// A plain text editor with live syntax highlighting, recomputed after
/// every edit.
///
/// SwiftUI's own `TextEditor(text: Binding<AttributedString>)` (new as of
/// iOS/macOS 26) looks like the obvious host for this, but it silently
/// ignores paragraph-level attributes — indent, spacing before a paragraph,
/// `NSTextList` numbering. Only character-level ones (font, colour) take
/// effect. Since indent and step numbering are exactly what this editor
/// needs, it wraps `UITextView`/`NSTextView` directly instead: the same
/// `NSParagraphStyle` attributes TextKit has always understood.
struct HighlightedTextEditor: View {
    @Binding var text: String
    /// The cursor's position in `text`, in characters — read by whoever
    /// needs to know what line the cursor sits on (autocomplete, link
    /// insertion), written back here so they see the user's own typing too.
    @Binding var cursorOffset: Int?
    /// Mirrors this editor's own focus state outward — a parent view cannot
    /// hand its `@FocusState` to a child to own, so this is a plain `Bool`
    /// kept in step with it instead.
    var isFocused: Binding<Bool>?
    /// Rewrites the attributes of the passed-in string in place from its
    /// own current characters — never the characters themselves.
    let restyle: (NSMutableAttributedString) -> Void

    var body: some View {
        RepresentableTextView(text: $text, cursorOffset: $cursorOffset, isFocused: isFocused, restyle: restyle)
    }
}

/// Shared building blocks for a `restyle` closure: where each line sits in
/// the raw text, in `NSRange`s ready to hand to `NSMutableAttributedString`.
enum RecipeTextHighlighting {
    struct Line {
        /// The line with its own leading and trailing whitespace removed.
        let trimmed: Substring
        /// Whether it opens a "# Section" heading.
        let isHeading: Bool
        /// The line's own span, from its first non-whitespace character.
        let range: NSRange
        /// The line's span *including its trailing newline*. TextKit takes
        /// a paragraph's style from the attributes on its terminator, not
        /// just its visible characters — a style applied to `range` alone
        /// is ignored.
        let paragraphRange: NSRange
    }

    /// Splits `text` into `Line`s, blank lines dropped.
    static func lines(in text: String) -> [Line] {
        let totalLength = (text as NSString).length
        var offset = 0
        var result: [Line] = []
        for rawLine in text.components(separatedBy: "\n") {
            let lineLength = (rawLine as NSString).length
            defer { offset += lineLength + 1 }
            let leading = rawLine.prefix { $0 == " " || $0 == "\t" }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let leadingLength = (String(leading) as NSString).length
            let trimmedLength = (trimmed as NSString).length
            let range = NSRange(location: offset + leadingLength, length: trimmedLength)
            let paragraphEnd = min(offset + lineLength + 1, totalLength)
            let paragraphRange = NSRange(location: offset, length: max(0, paragraphEnd - offset))
            result.append(Line(trimmed: Substring(trimmed), isHeading: trimmed.hasPrefix("#"), range: range, paragraphRange: paragraphRange))
        }
        return result
    }

    /// The first `length` UTF-16 units of `line`'s own span — e.g. the
    /// amount and unit at the start of an ingredient line.
    static func prefixRange(_ length: Int, of line: Line) -> NSRange {
        NSRange(location: line.range.location, length: min(length, line.range.length))
    }

    static func paragraphStyle(indent: CGFloat, spacingBefore: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.paragraphSpacingBefore = spacingBefore
        return style
    }
}

// MARK: - Platform host

#if os(iOS)
private struct RepresentableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var cursorOffset: Int?
    var isFocused: Binding<Bool>?
    let restyle: (NSMutableAttributedString) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = .preferredFont(forTextStyle: .body)
        // This editor grows to show all of its text; only the surrounding
        // Form scrolls.
        textView.isScrollEnabled = false
        context.coordinator.apply(text: text, cursorOffset: cursorOffset, to: textView, restyle: restyle)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.syncIfNeeded(text: text, cursorOffset: cursorOffset, to: textView, restyle: restyle)
        if isFocused?.wrappedValue == true, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
    }

    /// Reports the text view's own fitting height for the Form row's
    /// proposed width, so the row grows with the content instead of the
    /// text view clipping it internally.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }

    func makeCoordinator() -> TextViewCoordinator {
        TextViewCoordinator(text: $text, cursorOffset: $cursorOffset, isFocused: isFocused)
    }
}

extension TextViewCoordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        restyleAndApply(textView.text ?? "", to: textView, preservingSelectionFrom: textView.selectedRange)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isProgrammaticChange else { return }
        cursorOffset.wrappedValue = characterOffset(for: textView.selectedRange, in: textView.text ?? "")
    }

    func textViewDidBeginEditing(_ textView: UITextView) { isFocused?.wrappedValue = true }
    func textViewDidEndEditing(_ textView: UITextView) { isFocused?.wrappedValue = false }
}
#else
private struct RepresentableTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorOffset: Int?
    var isFocused: Binding<Bool>?
    let restyle: (NSMutableAttributedString) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = true
        // This editor grows to show all of its text; only the surrounding
        // Form scrolls, so it hosts the text view directly rather than in
        // an NSScrollView.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        context.coordinator.textView = textView
        context.coordinator.apply(text: text, cursorOffset: cursorOffset, to: textView, restyle: restyle)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.syncIfNeeded(text: text, cursorOffset: cursorOffset, to: textView, restyle: restyle)
        if isFocused?.wrappedValue == true, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// Reports the text view's own fitting height for the Form row's
    /// proposed width, so the row grows with the content instead of the
    /// text view clipping it internally.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let container = nsView.textContainer,
              let layoutManager = nsView.layoutManager
        else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    func makeCoordinator() -> TextViewCoordinator {
        TextViewCoordinator(text: $text, cursorOffset: $cursorOffset, isFocused: isFocused)
    }
}

extension TextViewCoordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        restyleAndApply(textView.string, to: textView, preservingSelectionFrom: textView.selectedRange())
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isProgrammaticChange, let textView = notification.object as? NSTextView else { return }
        cursorOffset.wrappedValue = characterOffset(for: textView.selectedRange(), in: textView.string)
    }

    func textDidBeginEditing(_ notification: Notification) { isFocused?.wrappedValue = true }
    func textDidEndEditing(_ notification: Notification) { isFocused?.wrappedValue = false }
}
#endif

/// Shared by both platforms' representables — everything that isn't a
/// literal `UITextView`/`NSTextView` API difference.
final class TextViewCoordinator: NSObject {
    var text: Binding<String>
    var cursorOffset: Binding<Int?>
    var isFocused: Binding<Bool>?
    #if os(macOS)
    weak var textView: NSTextView?
    #endif
    /// The `restyle` closure from whichever call last touched the text
    /// view — `textViewDidChange`/`textDidChange` have no other way to
    /// reach it, since the delegate callback carries only the text view.
    private var currentRestyle: (NSMutableAttributedString) -> Void = { _ in }
    /// The plain text last written to the text view — compared against the
    /// external `text` binding to tell "the user is typing" apart from "a
    /// sibling view (link insertion, autocomplete) changed `text` for us",
    /// which needs a full reload instead.
    private var lastKnownText = ""
    /// Set while this coordinator is itself assigning the selected range,
    /// so the resulting selection-changed callback doesn't re-report a
    /// cursor position nobody actually moved to.
    private(set) var isProgrammaticChange = false

    init(text: Binding<String>, cursorOffset: Binding<Int?>, isFocused: Binding<Bool>?) {
        self.text = text
        self.cursorOffset = cursorOffset
        self.isFocused = isFocused
    }

    #if os(iOS)
    typealias TextView = UITextView
    #else
    typealias TextView = NSTextView
    #endif

    func apply(text: String, cursorOffset: Int?, to textView: TextView, restyle: @escaping (NSMutableAttributedString) -> Void) {
        currentRestyle = restyle
        let attributed = NSMutableAttributedString(string: text)
        restyle(attributed)
        isProgrammaticChange = true
        setAttributedText(attributed, on: textView)
        if let cursorOffset, let range = nsRange(forCharacterOffset: cursorOffset, in: text) {
            setSelection(range, on: textView)
        }
        isProgrammaticChange = false
        lastKnownText = text
    }

    func syncIfNeeded(text: String, cursorOffset: Int?, to textView: TextView, restyle: @escaping (NSMutableAttributedString) -> Void) {
        currentRestyle = restyle
        guard text != lastKnownText else { return }
        apply(text: text, cursorOffset: cursorOffset, to: textView, restyle: restyle)
    }

    /// Restyles after the user's own edit, keeping the cursor where they
    /// left it — `setAttributedText`/`setAttributedString` otherwise resets
    /// the selection to the very start.
    fileprivate func restyleAndApply(_ plain: String, to textView: TextView, preservingSelectionFrom selection: NSRange) {
        lastKnownText = plain
        text.wrappedValue = plain
        let attributed = NSMutableAttributedString(string: plain)
        currentRestyle(attributed)
        isProgrammaticChange = true
        setAttributedText(attributed, on: textView)
        let clampedLocation = min(selection.location, attributed.length)
        let clamped = NSRange(
            location: clampedLocation, length: min(selection.length, attributed.length - clampedLocation)
        )
        setSelection(clamped, on: textView)
        isProgrammaticChange = false
        cursorOffset.wrappedValue = characterOffset(for: clamped, in: plain)
    }

    #if os(iOS)
    private func setAttributedText(_ attributed: NSAttributedString, on textView: TextView) { textView.attributedText = attributed }
    private func setSelection(_ range: NSRange, on textView: TextView) { textView.selectedRange = range }
    #else
    private func setAttributedText(_ attributed: NSAttributedString, on textView: TextView) {
        textView.textStorage?.setAttributedString(attributed)
    }
    private func setSelection(_ range: NSRange, on textView: TextView) { textView.setSelectedRange(range) }
    #endif
}

/// `NSRange` is UTF-16 based; `cursorOffset` is a `Character` count, the
/// unit everything else in the editor (link insertion, autocomplete) uses.
private func characterOffset(for range: NSRange, in text: String) -> Int? {
    guard let swiftRange = Range(range, in: text) else { return nil }
    return text.distance(from: text.startIndex, to: swiftRange.lowerBound)
}

private func nsRange(forCharacterOffset offset: Int, in text: String) -> NSRange? {
    guard let index = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) else { return nil }
    return NSRange(index..<index, in: text)
}
