import Foundation

extension Recipe {
    /// The ingredients scaled to `targetServings`.
    ///
    /// Scaling produces a reading of the recipe, never a rewrite: the text the
    /// user typed stays untouched, so a line the parser only partly understood
    /// cannot be damaged by viewing it at a different serving count.
    public func scaledIngredients(toServings targetServings: Int) -> [RecipeIngredient] {
        guard servings > 0, targetServings > 0, targetServings != servings else {
            return ingredients
        }
        return scaledIngredients(by: Double(targetServings) / Double(servings))
    }

    /// The ingredients with every scalable amount multiplied by `factor`.
    public func scaledIngredients(by factor: Double) -> [RecipeIngredient] {
        guard factor > 0, factor != 1 else { return ingredients }

        return ingredients.map { ingredient in
            guard ingredient.scalesWithServings, let quantity = ingredient.quantity else {
                return ingredient
            }
            var scaled = ingredient
            scaled.quantity = quantity.scaled(by: factor)
            scaled.resolvedGrams = ingredient.resolvedGrams.map { $0 * factor }
            return scaled
        }
    }
}
