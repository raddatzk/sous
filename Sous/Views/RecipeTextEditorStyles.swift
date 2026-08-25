import SousKit
import SwiftUI

/// The two `restyle` closures `HighlightedTextEditor` runs for the recipe
/// editor: what a "# Section" heading, an ingredient line and a step look
/// like while they are still being typed.
enum RecipeTextEditorStyle {
    /// Headings sit flush left in the serif; an ingredient line is indented
    /// a few points in, with its amount and unit picked out in the accent —
    /// the same weight `IngredientLineView` gives them once the line has
    /// actually parsed, shown early instead of only after the fact.
    static func ingredients(_ attributed: NSMutableAttributedString) {
        let text = attributed.string
        resetBase(attributed)

        for line in RecipeTextHighlighting.lines(in: text) {
            if line.isHeading {
                attributed.addAttribute(.font, value: headingFont(), range: line.range)
                attributed.addAttribute(
                    .paragraphStyle,
                    value: RecipeTextHighlighting.paragraphStyle(indent: 0, spacingBefore: headingSpacing),
                    range: line.paragraphRange
                )
                continue
            }

            attributed.addAttribute(
                .paragraphStyle,
                value: RecipeTextHighlighting.paragraphStyle(indent: ingredientIndent, spacingBefore: 0),
                range: line.paragraphRange
            )
            guard let length = IngredientParser.leadingAmountAndUnitLength(in: String(line.trimmed)) else { continue }
            let amountRange = RecipeTextHighlighting.prefixRange((String(line.trimmed).prefix(length) as NSString).length, of: line)
            attributed.addAttribute(.foregroundColor, value: PlatformColor(.sousAccent), range: amountRange)
            attributed.addAttribute(.font, value: boldBodyFont(), range: amountRange)
        }
    }

    /// A step gets room to breathe from the one before it and a number of
    /// its own, drawn by the text list rather than typed — so it renumbers
    /// itself, and can never be edited into the wrong count. A heading
    /// starts a fresh list, the same restart `Recipe.stepGroups` gives the
    /// finished recipe.
    static func instructions(_ attributed: NSMutableAttributedString) {
        let text = attributed.string
        resetBase(attributed)

        var currentList = NSTextList(markerFormat: .decimal, options: 0)
        for line in RecipeTextHighlighting.lines(in: text) {
            if line.isHeading {
                currentList = NSTextList(markerFormat: .decimal, options: 0)
                attributed.addAttribute(.font, value: headingFont(), range: line.range)
                attributed.addAttribute(
                    .paragraphStyle,
                    value: RecipeTextHighlighting.paragraphStyle(indent: 0, spacingBefore: headingSpacing),
                    range: line.paragraphRange
                )
                continue
            }

            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = stepSpacing
            style.headIndent = stepIndent
            style.textLists = [currentList]
            attributed.addAttribute(.paragraphStyle, value: style, range: line.paragraphRange)
        }
    }

    private static let ingredientIndent: CGFloat = 20
    private static let stepIndent: CGFloat = 26
    private static let stepSpacing: CGFloat = 18
    private static let headingSpacing: CGFloat = 14

    private static func resetBase(_ attributed: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.font, value: bodyFont(), range: whole)
        attributed.addAttribute(.foregroundColor, value: PlatformColor(.primary), range: whole)
        attributed.addAttribute(
            .paragraphStyle, value: RecipeTextHighlighting.paragraphStyle(indent: 0, spacingBefore: 0), range: whole
        )
    }

    private static func bodyFont() -> PlatformFont { .preferredFont(forTextStyle: .body) }

    private static func boldBodyFont() -> PlatformFont {
        .boldSystemFont(ofSize: bodyFont().pointSize)
    }

    /// The same serif headline `SousStyle.groupHeading` sets for a group
    /// name once the recipe is read back — matched here in raw `UIFont`
    /// terms since this editor talks to `NSMutableAttributedString`
    /// directly, not through SwiftUI's `Font`.
    private static func headingFont() -> PlatformFont {
        #if os(iOS)
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline)
        let serif = base.withDesign(.serif) ?? base
        return UIFont(descriptor: serif, size: 0)
        #else
        let base = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .headline)
        let serif = base.withDesign(.serif) ?? base
        return NSFont(descriptor: serif, size: 0) ?? .preferredFont(forTextStyle: .headline)
        #endif
    }
}
