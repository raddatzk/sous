import Foundation

/// Turns planned recipes into a shopping list.
public enum ShoppingListBuilder {
    /// How deep a chain of linked recipes is followed. A curry references its
    /// naan, which might reference a spice mix; beyond that it is a loop or a
    /// mistake.
    private static let maxLinkDepth = 3

    /// Builds the list for a set of planned recipes.
    ///
    /// - Parameter resolve: looks up a linked recipe by id. Linked recipes
    ///   contribute their own ingredients — "1 Portion Naan" means flour and
    ///   yeast on the list, not a jar of naan.
    public static func build(
        from planned: [(recipe: Recipe, servings: Int)],
        catalog: IngredientCatalog = .bundled,
        resolve: (UUID) -> Recipe?
    ) -> [ShoppingItem] {
        var accumulator: [String: ShoppingItem] = [:]
        var order: [String] = []

        for entry in planned {
            collect(
                recipe: entry.recipe,
                servings: entry.servings,
                origin: entry.recipe.title,
                depth: 0,
                visited: [],
                catalog: catalog,
                resolve: resolve,
                into: &accumulator,
                order: &order
            )
        }
        return order.compactMap { accumulator[$0] }
    }

    private static func collect(
        recipe: Recipe,
        servings: Int,
        origin: String,
        depth: Int,
        visited: Set<UUID>,
        catalog: IngredientCatalog,
        resolve: (UUID) -> Recipe?,
        into accumulator: inout [String: ShoppingItem],
        order: inout [String]
    ) {
        var seen = visited
        seen.insert(recipe.id)

        for ingredient in recipe.scaledIngredients(toServings: servings) {
            // A linked recipe contributes what it is made of, not itself.
            if depth < maxLinkDepth,
               let linkedID = RecipeLink.referencedIDs(in: ingredient.name).first,
               !seen.contains(linkedID),
               let linked = resolve(linkedID) {
                collect(
                    recipe: linked,
                    // "2 Portionen Naan" means the naan recipe at two
                    // servings; without an amount, it is taken as written.
                    servings: portions(of: ingredient) ?? linked.servings,
                    origin: linked.title,
                    depth: depth + 1,
                    visited: seen,
                    catalog: catalog,
                    resolve: resolve,
                    into: &accumulator,
                    order: &order
                )
                continue
            }

            add(ingredient, from: origin, catalog: catalog, into: &accumulator, order: &order)
        }
    }

    private static func portions(of ingredient: RecipeIngredient) -> Int? {
        guard let quantity = ingredient.quantity, quantity.unit == .portion else { return nil }
        return max(1, Int(quantity.amount.rounded()))
    }

    private static func add(
        _ ingredient: RecipeIngredient,
        from origin: String,
        catalog: IngredientCatalog,
        into accumulator: inout [String: ShoppingItem],
        order: inout [String]
    ) {
        let written = ShoppingItem.displayName(for: ingredient.name)
        let key = ShoppingItem.key(for: ingredient.name, catalog: catalog)
        guard !key.isEmpty else { return }

        if accumulator[key] == nil {
            order.append(key)
            let known = catalog.ingredient(for: written)
            accumulator[key] = ShoppingItem(
                key: key,
                // A known ingredient is shown under its catalog name, so the
                // list reads consistently however the recipes spell it.
                name: known?.name ?? written,
                category: known?.category
            )
        }

        guard var item = accumulator[key] else { return }

        // Amounts are kept per recipe; the line's total follows from them.
        if let index = item.sources.firstIndex(where: { $0.recipeTitle == origin }) {
            if let quantity = ingredient.quantity {
                item.sources[index].quantities = item.sources[index].quantities.adding(quantity)
            }
        } else {
            item.sources.append(ShoppingSource(
                recipeTitle: origin,
                quantities: ingredient.quantity.map { [$0] } ?? []
            ))
        }
        accumulator[key] = item
    }

}
