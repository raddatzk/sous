import Foundation

extension Recipe {
    /// The ingredients scaled to `targetServings`.
    ///
    /// Scaling produces a reading of the recipe, never a rewrite: the text the
    /// cook typed stays untouched, so viewing it at a different serving count
    /// cannot damage a line.
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
    func scaledIngredients(by factor: Double, catalog: IngredientCatalog? = nil) -> [RecipeIngredient] {
        let ingredients = ingredients(readWith: catalog)
        guard factor > 0, factor != 1 else { return ingredients }

        return ingredients.map { ingredient in
            var scaled = ingredient
            scaled.quantity = ingredient.quantity?.scaled(by: factor)
            return scaled
        }
    }
}
