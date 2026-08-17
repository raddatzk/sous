import Foundation

extension Recipe {
    /// The same recipe with its amounts scaled to `targetServings`.
    ///
    /// Identity is preserved — this is a view of the recipe, not a new one —
    /// so the result must not be persisted over the original.
    public func scaled(toServings targetServings: Int) -> Recipe {
        guard servings > 0, targetServings > 0, targetServings != servings else {
            return self
        }
        var scaled = scaled(by: Double(targetServings) / Double(servings))
        scaled.servings = targetServings
        return scaled
    }

    /// The same recipe with every scalable amount multiplied by `factor`.
    public func scaled(by factor: Double) -> Recipe {
        guard factor > 0, factor != 1 else { return self }
        var copy = self
        copy.ingredients = ingredients.map { ingredient in
            guard ingredient.scalesWithServings, let quantity = ingredient.quantity else {
                return ingredient
            }
            var scaled = ingredient
            scaled.quantity = quantity.scaled(by: factor)
            // Grams resolved for the original amount no longer apply.
            scaled.resolvedGrams = ingredient.resolvedGrams.map { $0 * factor }
            return scaled
        }
        return copy
    }
}
