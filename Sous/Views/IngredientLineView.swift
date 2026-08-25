import SousKit
import SwiftUI

/// One ingredient line with its three parts told apart: the amount carries the
/// accent because that is what the cook is looking for, the name reads plainly,
/// and the comment steps back.
///
/// The name goes through the markdown parser so that a linked recipe — "1
/// Portion [Naan](sous://recipe/…)" — is a link right there in the list,
/// where the cook is reading, rather than only in a section further down.
struct IngredientLineView: View {
    let ingredient: RecipeIngredient
    var formatter = QuantityFormatter(locale: .sous)

    var body: some View {
        // Interpolated rather than added together: `Text + Text` is
        // deprecated as of the 26 SDKs, and interpolation keeps each part's
        // own styling the way the sum did.
        Text("\(amountText)\(amount.isEmpty ? "" : " ")\(name)\(trailingPhraseText)\(commentText)")
    }

    /// The amount carries the accent, so it is its own styled run.
    private var amountText: Text {
        Text(amount)
            .foregroundStyle(.tint)
            .fontWeight(.medium)
    }

    /// "nach Geschmack" is the amount written in words, so it wears the
    /// amount's accent — just after the name, where it was typed.
    private var trailingPhraseText: Text {
        guard let phrase = ingredient.unquantifiedPhrase, phrase.placement == .afterName else {
            return Text("")
        }
        return Text(" \(phrase.phrase)")
            .foregroundStyle(.tint)
            .fontWeight(.medium)
    }

    private var commentText: Text {
        Text(comment)
            .foregroundStyle(.secondary)
    }

    private var amount: String {
        if let quantity = ingredient.quantity { return formatter.string(for: quantity) }
        // "etwas Salz" — the words sit where a number would, styled like one.
        if let phrase = ingredient.unquantifiedPhrase, phrase.placement == .beforeName {
            return phrase.phrase
        }
        return ""
    }

    private var name: AttributedString {
        (try? AttributedString(
            markdown: ingredient.name,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(ingredient.name)
    }

    private var comment: AttributedString {
        guard let preparation = ingredient.preparation, !preparation.isEmpty else {
            return AttributedString("")
        }
        return AttributedString(" (\(preparation))")
    }
}
