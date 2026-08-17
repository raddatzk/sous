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
                    resolve: resolve,
                    into: &accumulator,
                    order: &order
                )
                continue
            }

            add(ingredient, from: origin, into: &accumulator, order: &order)
        }
    }

    private static func portions(of ingredient: RecipeIngredient) -> Int? {
        guard let quantity = ingredient.quantity, quantity.unit == .portion else { return nil }
        return max(1, Int(quantity.amount.rounded()))
    }

    private static func add(
        _ ingredient: RecipeIngredient,
        from origin: String,
        into accumulator: inout [String: ShoppingItem],
        order: inout [String]
    ) {
        let key = ShoppingItem.key(for: ingredient.name)
        guard !key.isEmpty else { return }

        if accumulator[key] == nil {
            order.append(key)
            accumulator[key] = ShoppingItem(
                key: key,
                name: ShoppingItem.displayName(for: ingredient.name)
            )
        }

        guard var item = accumulator[key] else { return }
        if let quantity = ingredient.quantity {
            item.quantities = merged(item.quantities, adding: quantity)
        }

        // The same amount is also kept under the recipe that wants it, so the
        // list can be grouped by dish as well as by ingredient.
        if let index = item.sources.firstIndex(where: { $0.recipeTitle == origin }) {
            if let quantity = ingredient.quantity {
                item.sources[index].quantities = merged(item.sources[index].quantities, adding: quantity)
            }
        } else {
            item.sources.append(ShoppingSource(
                recipeTitle: origin,
                quantities: ingredient.quantity.map { [$0] } ?? []
            ))
        }
        accumulator[key] = item
    }

    /// Adds an amount to the ones already gathered.
    ///
    /// Only amounts bought in the same measure are combined: 300 g and 0,2 kg
    /// make 500 g. Everything else is written side by side, the way Mela does
    /// it — "100 g + 3 EL" is honest, while a converted "135 ml" would be a
    /// number nobody asked for. Spoons in particular are a cooking measure,
    /// not a shopping one: 2 EL and 1 TL stay as they are.
    static func merged(_ quantities: [Quantity], adding quantity: Quantity) -> [Quantity] {
        var result = quantities

        if let group = quantity.unit.shoppingGroup,
           let index = result.firstIndex(where: { $0.unit.shoppingGroup == group }) {
            let existing = result[index]
            guard let converted = quantity.converted(to: existing.unit) else { return result }
            result[index] = Quantity(existing.amount + converted.amount, existing.unit)
            return result
        }

        // Outside those groups only identical units add up.
        if let index = result.firstIndex(where: { $0.unit == quantity.unit }) {
            result[index] = Quantity(result[index].amount + quantity.amount, quantity.unit)
            return result
        }

        result.append(quantity)
        return result
    }
}
