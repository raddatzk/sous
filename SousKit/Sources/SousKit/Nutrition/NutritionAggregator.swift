import Foundation

/// Sums a recipe's nutrition from its ingredients, following linked
/// sub-recipes the same way `ShoppingListBuilder` follows them for a
/// shopping list — a curry's linked naan contributes flour and yeast, not a
/// generic "1 portion" placeholder.
public enum NutritionAggregator {
    /// A curry references its naan, which might reference a spice mix;
    /// beyond that it is a loop or a mistake. Matches `ShoppingListBuilder`.
    private static let maxLinkDepth = 3

    /// The total nutrition for `recipe` at `servings` — across every
    /// portion, not per portion; the caller divides by `servings` for that.
    public static func aggregate(
        recipe: Recipe,
        servings: Int,
        catalog: IngredientCatalog = .bundled,
        nutritionCatalog: NutritionCatalog = .bundled,
        resolve: (UUID) -> Recipe?
    ) -> NutritionInfo {
        collect(
            recipe: recipe, servings: servings, depth: 0, visited: [],
            catalog: catalog, nutritionCatalog: nutritionCatalog, resolve: resolve
        )
    }

    private static func collect(
        recipe: Recipe,
        servings: Int,
        depth: Int,
        visited: Set<UUID>,
        catalog: IngredientCatalog,
        nutritionCatalog: NutritionCatalog,
        resolve: (UUID) -> Recipe?
    ) -> NutritionInfo {
        var seen = visited
        seen.insert(recipe.id)

        var total = NutritionInfo.zero
        for ingredient in recipe.scaledIngredients(toServings: servings) {
            // A linked recipe contributes what it is made of, not itself.
            if depth < maxLinkDepth,
               let linkedID = RecipeLink.referencedIDs(in: ingredient.name).first,
               !seen.contains(linkedID),
               let linked = resolve(linkedID) {
                total = total + collect(
                    recipe: linked,
                    servings: portions(of: ingredient) ?? linked.servings,
                    depth: depth + 1,
                    visited: seen,
                    catalog: catalog,
                    nutritionCatalog: nutritionCatalog,
                    resolve: resolve
                )
                continue
            }

            guard let grams = NutritionResolver.resolvedGrams(
                for: ingredient, catalog: catalog, nutritionCatalog: nutritionCatalog
            ) else { continue }

            let canonicalName = catalog.canonicalName(for: ingredient.name)
            guard let perHundredGrams = nutritionCatalog.nutrition(forCanonicalName: canonicalName)?
                .nutrition(for: ingredient.state)
            else { continue }

            total = total + perHundredGrams.scaled(byGrams: grams)
        }
        return total
    }

    /// "2 Portionen Naan" means the naan recipe at two servings; without an
    /// amount, it is taken as written. Matches `ShoppingListBuilder.portions`.
    private static func portions(of ingredient: RecipeIngredient) -> Int? {
        guard let quantity = ingredient.quantity, quantity.unit == .portion else { return nil }
        return max(1, Int(quantity.amount.rounded()))
    }
}
