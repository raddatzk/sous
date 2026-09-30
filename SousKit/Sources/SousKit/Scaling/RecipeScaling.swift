import Foundation

extension Recipe {
    /// The ingredients scaled to `targetServings`.
    ///
    /// Scaling produces a reading of the recipe, never a rewrite: the text the
    /// user typed stays untouched, so a line the parser only partly understood
    /// cannot be damaged by viewing it at a different serving count.
    ///
    /// `catalog` is what the lines are read against — see
    /// ``Recipe/ingredients(readWith:)``.
    public func scaledIngredients(
        toServings targetServings: Int, catalog: IngredientCatalog? = nil
    ) -> [RecipeIngredient] {
        guard servings > 0, targetServings > 0, targetServings != servings else {
            return ingredients(readWith: catalog)
        }
        return scaledIngredients(by: Double(targetServings) / Double(servings), catalog: catalog)
    }

    /// The ingredients with every scalable amount multiplied by `factor`.
    public func scaledIngredients(by factor: Double, catalog: IngredientCatalog? = nil) -> [RecipeIngredient] {
        let ingredients = ingredients(readWith: catalog)
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
