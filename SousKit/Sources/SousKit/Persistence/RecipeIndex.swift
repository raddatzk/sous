import Foundation

/// The two denormalized fields a stored recipe carries beside its content —
/// what it can be searched by, and what it can be filtered by.
///
/// Free of any persistence framework, because there are now two stores that
/// write them: the SwiftData one the local half of the app keeps using, and
/// the Core Data one the shared CloudKit database requires. Two copies of
/// this derivation would mean the same library answering the same search
/// differently depending on which store happened to hold it, and the
/// divergence would show up as a recipe that cannot be found rather than as
/// a failure anyone could read.
public enum RecipeIndex {
    /// The ingredients a recipe can be filtered by — each line's own key and,
    /// for a variety, its parent's as well.
    ///
    /// Both, because a recipe calling for Cocktailtomaten *is* a recipe with
    /// tomatoes in it. Filtering by "Tomate" and not finding it would be the
    /// swallowing the variety relation exists to prevent, in the other
    /// direction: the shopping list keeps them apart, the library keeps them
    /// together.
    public static func ingredientKeys(for recipe: Recipe, catalog: IngredientCatalog) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for ingredient in recipe.ingredients {
            let name = ShoppingItem.displayName(for: ingredient.name)
            let own = ShoppingItem.key(for: ingredient.name, catalog: catalog)
            var resolved = catalog.ingredient(for: name)
            var headKey: String?
            if resolved == nil, let head = StepAmountResolver.headWord(of: name) {
                // "1 kleiner Hokkaido" — the catalog knows the head noun,
                // not the phrase. The same reach the step matcher has.
                resolved = catalog.ingredient(for: head)
                headKey = resolved.map(\.key)
            }
            let parent = resolved?.parentName.map(IngredientCatalog.normalize)
            for key in [own, headKey, parent].compactMap({ $0 }) {
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                keys.append(key)
            }
        }
        return keys
    }

    public static func searchText(
        for recipe: Recipe,
        variantGroupTitle: String? = nil,
        catalog: IngredientCatalog = .bundled
    ) -> String {
        var parts = [recipe.title]
        if let variantGroupTitle, !variantGroupTitle.isEmpty {
            parts.append(variantGroupTitle)
        }
        parts.append(contentsOf: recipe.categories)
        parts.append(contentsOf: recipe.ingredients.map(\.name))
        // The canonical keys as well, parents included — typing "Kürbis"
        // into the search field must find the recipe whose list only ever
        // says "Hokkaido", the same reach the ingredient filter has always
        // had through `ingredientKeys`.
        parts.append(contentsOf: ingredientKeys(for: recipe, catalog: catalog))
        return parts.joined(separator: " ").lowercased()
    }
}
