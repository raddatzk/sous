import Foundation
import SousKit
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension NSAttributedString.Key {
    /// The URL behind a chip, on exactly the characters the chip covers.
    ///
    /// This is what makes the two texts reconcilable: the editor shows
    /// "Naan", the recipe stores `[Naan](sous://recipe/…)`, and the run
    /// carrying this key is the only place that remembers which is which.
    static let sousRecipeLink = NSAttributedString.Key("sousRecipeLink")
}

/// Drawing ``RecipeLinkChipping``'s two texts into a text view, and reading
/// one of them back out.
///
/// The arithmetic lives in SousKit; this is the part that needs a
/// `UIFont`/`NSColor` to say anything at all.
enum RecipeLinkChips {
    /// The display text for `stored`, every recipe link collapsed to its
    /// title and tagged with where it points.
    ///
    /// Attributes only — the caller's own `restyle` runs over this afterwards
    /// and is free to set fonts and paragraph styles on it; see
    /// ``decorate(_:)`` for the part that has to happen last.
    static func display(_ stored: String) -> NSMutableAttributedString {
        let (text, chips) = RecipeLinkChipping.display(of: stored)
        let attributed = NSMutableAttributedString(string: text)
        for chip in chips {
            attributed.addAttribute(.sousRecipeLink, value: chip.url, range: chip.displayRange)
        }
        return attributed
    }

    /// The stored text behind `attributed` — every chip written back out as
    /// the markdown it stands for.
    static func stored(_ attributed: NSAttributedString) -> String {
        var result = ""
        attributed.enumerateAttribute(
            .sousRecipeLink, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            if let url = value as? String {
                result += RecipeLinkChipping.markdown(title: text, url: url)
            } else {
                result += text
            }
        }
        return result
    }

    /// Paints the chips, after `restyle` has had its say.
    ///
    /// Last, not first: `restyle` resets colour and font across the whole
    /// string to give a line its base look, which would wash out a chip
    /// painted before it.
    static func decorate(_ attributed: NSMutableAttributedString) {
        attributed.enumerateAttribute(
            .sousRecipeLink, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard value != nil else { return }
            attributed.addAttributes([
                .foregroundColor: PlatformColor(.sousAccent),
                .backgroundColor: PlatformColor(Color.sousAccent.opacity(0.12)),
            ], range: range)
        }
    }

    /// The chip `range` runs into, widened to the whole of it — what makes a
    /// chip delete in one press instead of shedding its brackets.
    static func expandingChips(_ range: NSRange, in attributed: NSAttributedString) -> NSRange {
        guard attributed.length > 0 else { return range }
        var result = range
        attributed.enumerateAttribute(
            .sousRecipeLink, in: NSRange(location: 0, length: attributed.length)
        ) { value, chip, _ in
            guard value != nil, NSIntersectionRange(chip, result).length > 0 else { return }
            result = NSUnionRange(result, chip)
        }
        return result
    }
}
