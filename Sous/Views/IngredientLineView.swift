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
        Text(amount)
            .foregroundStyle(.tint)
            .fontWeight(.medium)
        + Text(amount.isEmpty ? "" : " ")
        + Text(name)
        + Text(comment)
            .foregroundStyle(.secondary)
    }

    private var amount: String {
        ingredient.quantity.map { formatter.string(for: $0) } ?? ""
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
