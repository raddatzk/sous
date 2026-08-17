import SousKit
import SwiftUI

/// One ingredient line with its three parts told apart: the amount carries the
/// accent because that is what the cook is looking for, the name reads plainly,
/// and the comment steps back.
struct IngredientLineView: View {
    let ingredient: RecipeIngredient
    var formatter = QuantityFormatter()

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

    private var name: String {
        ingredient.name
    }

    private var comment: String {
        guard let preparation = ingredient.preparation, !preparation.isEmpty else { return "" }
        return " (\(preparation))"
    }
}
