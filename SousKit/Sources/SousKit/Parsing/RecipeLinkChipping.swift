import Foundation

/// A recipe link as two texts: the one a recipe stores and the one an editor
/// shows.
///
/// The editor used to show the markdown as typed —
/// `[Naan](sous://recipe/9E2F…-…)` — a line of syntax and a UUID standing in
/// the middle of a sentence somebody is trying to read. Worse, it came apart
/// one character at a time: backspacing over it left `[Naan](sous` behind,
/// which is neither a link nor a name, and the recipe kept it.
///
/// So the editor is shown one string and the recipe keeps another, and the
/// two have to be held in step. That is all arithmetic over the same handful
/// of matches, which is why it lives here rather than beside the text view:
/// the mapping is the part that is easy to get subtly wrong, and it is the
/// part a test can hold still.
public enum RecipeLinkChipping {
    /// One link, as the editor will draw it.
    public struct Chip: Equatable, Sendable {
        /// What is shown in place of the whole markdown link.
        public let title: String
        /// Where it points, kept so the stored text can be written back.
        public let url: String
        /// The title's span in the *display* text, in UTF-16 units — the
        /// unit `NSAttributedString` counts in.
        public let displayRange: NSRange
    }

    /// Only this app's own scheme, and only a well-formed id: an ordinary
    /// markdown link somebody typed for a website is left as written, because
    /// hiding half of *that* would be hiding something they meant to see.
    ///
    /// Built per call — `Regex` is not `Sendable`, the same reason
    /// ``RecipeLink/referencedIDs(in:)`` builds its own.
    private static var pattern: Regex<(Substring, Substring, Substring)> {
        /\[([^\]\n]+)\]\((sous:\/\/recipe\/[0-9A-Fa-f-]{36})\)/
    }

    private struct Span {
        let range: Range<String.Index>
        let title: String
        let url: String
    }

    private static func spans(in stored: String) -> [Span] {
        stored.matches(of: pattern).map {
            Span(range: $0.range, title: String($0.1), url: String($0.2))
        }
    }

    /// What to show for `stored`, and where its chips ended up.
    public static func display(of stored: String) -> (text: String, chips: [Chip]) {
        var text = ""
        var chips: [Chip] = []
        var cursor = stored.startIndex
        for span in spans(in: stored) {
            text += stored[cursor..<span.range.lowerBound]
            chips.append(Chip(
                title: span.title,
                url: span.url,
                displayRange: NSRange(location: (text as NSString).length, length: (span.title as NSString).length)
            ))
            text += span.title
            cursor = span.range.upperBound
        }
        text += stored[cursor...]
        return (text, chips)
    }

    /// Where `offset` in the stored text falls in the display text, both
    /// counted in `Character`s.
    ///
    /// An offset inside a link's syntax has no honest answer, so it is given
    /// the chip's near edge: a cursor lands beside the chip rather than
    /// somewhere in a UUID nobody can see.
    public static func displayOffset(forStored offset: Int, in stored: String) -> Int {
        var display = 0
        var consumed = 0
        var cursor = stored.startIndex
        for span in spans(in: stored) {
            let run = stored.distance(from: cursor, to: span.range.lowerBound)
            if offset <= consumed + run { return display + (offset - consumed) }
            display += run
            consumed += run

            let linkLength = stored.distance(from: span.range.lowerBound, to: span.range.upperBound)
            if offset < consumed + linkLength { return display }
            display += span.title.count
            consumed += linkLength
            cursor = span.range.upperBound
        }
        return display + max(0, offset - consumed)
    }

    /// Where `offset` in the display text falls in the stored text, both
    /// counted in `Character`s.
    public static func storedOffset(forDisplay offset: Int, in stored: String) -> Int {
        var display = 0
        var result = 0
        var cursor = stored.startIndex
        for span in spans(in: stored) {
            let run = stored.distance(from: cursor, to: span.range.lowerBound)
            if offset <= display + run { return result + (offset - display) }
            display += run
            result += run

            let linkLength = stored.distance(from: span.range.lowerBound, to: span.range.upperBound)
            // Anywhere inside the title maps to the link's start: the chip is
            // one thing, and "halfway into Naan" is not a position the stored
            // text has.
            if offset < display + span.title.count { return result }
            display += span.title.count
            result += linkLength
            cursor = span.range.upperBound
        }
        return result + max(0, offset - display)
    }

    /// The markdown for a chip's title and target — what an edited display
    /// text is written back as.
    public static func markdown(title: String, url: String) -> String {
        "[\(title)](\(url))"
    }
}
