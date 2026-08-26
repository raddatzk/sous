import Foundation

/// Turns planned recipes into a shopping capture: one plan entry per recipe,
/// one demand per ingredient line.
public enum ShoppingListBuilder {
    /// How deep a chain of linked recipes is followed. A curry references its
    /// naan, which might reference a spice mix; beyond that it is a loop or a
    /// mistake.
    private static let maxLinkDepth = 3

    /// Builds the capture for a set of planned recipes.
    ///
    /// - Parameter resolve: looks up a linked recipe by id. Linked recipes
    ///   contribute their own ingredients — "1 Portion Naan" means flour and
    ///   yeast on the list, not a jar of naan. Their demands hang on the
    ///   *parent's* plan entry, so the portion stepper takes them along;
    ///   the subrecipe's title stays on them as the origin they read as.
    public static func build(
        from planned: [(recipe: Recipe, servings: Int)],
        catalog: IngredientCatalog = .bundled,
        resolve: (UUID) -> Recipe?
    ) -> ShoppingCapture {
        var capture = ShoppingCapture()

        for entry in planned {
            let planEntry = ShoppingPlanEntry(
                recipeID: entry.recipe.id,
                title: entry.recipe.title,
                servingsCaptured: entry.servings
            )
            capture.planEntries.append(planEntry)
            collect(
                recipe: entry.recipe,
                servings: entry.servings,
                origin: entry.recipe.title,
                planEntryID: planEntry.id,
                scales: true,
                depth: 0,
                visited: [],
                catalog: catalog,
                resolve: resolve,
                into: &capture
            )
        }
        return capture
    }

    private static func collect(
        recipe: Recipe,
        servings: Int,
        origin: String,
        planEntryID: UUID,
        scales: Bool,
        depth: Int,
        visited: Set<UUID>,
        catalog: IngredientCatalog,
        resolve: (UUID) -> Recipe?,
        into capture: inout ShoppingCapture
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
                    planEntryID: planEntryID,
                    // A naan wanted "as written" does not grow with the
                    // curry, and neither does anything a non-scaling line
                    // pulled in.
                    scales: scales && portions(of: ingredient) != nil && ingredient.scalesWithServings,
                    depth: depth + 1,
                    visited: seen,
                    catalog: catalog,
                    resolve: resolve,
                    into: &capture
                )
                continue
            }

            add(
                ingredient,
                from: origin,
                planEntryID: planEntryID,
                scales: scales,
                catalog: catalog,
                into: &capture
            )
        }
    }

    private static func portions(of ingredient: RecipeIngredient) -> Int? {
        guard let quantity = ingredient.quantity, quantity.unit == .portion else { return nil }
        return max(1, Int(quantity.amount.rounded()))
    }

    private static func add(
        _ ingredient: RecipeIngredient,
        from origin: String,
        planEntryID: UUID,
        scales: Bool,
        catalog: IngredientCatalog,
        into capture: inout ShoppingCapture
    ) {
        let written = ShoppingItem.displayName(for: ingredient.name)
        let key = ShoppingItem.key(for: ingredient.name, catalog: catalog)
        guard !key.isEmpty else { return }

        let known = catalog.ingredient(for: written)
        capture.demands.append(CapturedShoppingDemand(
            key: key,
            // A known ingredient is shown under its catalog name, so the
            // list reads consistently however the recipes spell it.
            displayName: known?.name ?? written,
            category: known?.category,
            demand: ShoppingDemand(
                planEntryID: planEntryID,
                lineID: ingredient.id,
                originTitle: origin,
                // The heading takes the catalog's spelling; the demand keeps
                // the cook's, so a variety is still readable underneath it.
                writtenName: written,
                quantity: ingredient.quantity,
                state: ingredient.state,
                scales: scales && ingredient.scalesWithServings && ingredient.quantity != nil
            )
        ))
    }
}
