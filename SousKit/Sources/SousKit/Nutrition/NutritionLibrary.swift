import Foundation
import Observation

/// The view-facing nutrition for a recipe — computed once per recipe (and
/// its linked sub-recipes) and cached from then on, the same shape as
/// ``ShoppingLibrary`` resolving links before handing off to a builder.
@MainActor
@Observable
public final class NutritionLibrary {
    private let store: any RecipeNutritionStore
    private let recipeStore: any RecipeStore
    /// Kept so a cook's own catalog additions resolve like the bundled ones.
    private let catalogLibrary: IngredientCatalogLibrary?

    public init(
        store: any RecipeNutritionStore,
        recipeStore: any RecipeStore,
        catalogLibrary: IngredientCatalogLibrary? = nil
    ) {
        self.store = store
        self.recipeStore = recipeStore
        self.catalogLibrary = catalogLibrary
    }

    private var catalog: IngredientCatalog {
        catalogLibrary?.catalog ?? .bundled
    }

    /// The nutrition for `recipe` at `servings` (the recipe's own count if
    /// omitted) — from cache when nothing relevant has changed, computed and
    /// cached otherwise.
    public func nutrition(for recipe: Recipe, servings: Int? = nil) async -> RecipeNutrition? {
        let servings = servings ?? recipe.servings
        guard servings > 0 else { return nil }

        var known: [UUID: Recipe] = [recipe.id: recipe]
        await resolveLinks(of: recipe, into: &known)
        // Captured as an immutable snapshot: `resolve` crosses into the
        // nutrition store's actor, which requires a `@Sendable` closure —
        // a `var` dictionary cannot be captured by reference into one.
        let resolved = known
        let resolve: @Sendable (UUID) -> Recipe? = { resolved[$0] }

        if let cached = try? await store.nutrition(for: recipe, resolve: resolve), cached.servings == servings {
            return cached
        }

        let total = NutritionAggregator.aggregate(
            recipe: recipe, servings: servings, catalog: catalog, nutritionCatalog: .bundled, resolve: resolve
        )
        let perPortion = total.scaled(by: 1 / Double(servings))
        let result = RecipeNutrition(
            perPortion: perPortion, servings: servings, nrf93Score: NRF93Score.score(for: perPortion)
        )
        try? await store.save(result, for: recipe, resolve: resolve)
        return result
    }

    /// Follows links a level at a time so the aggregator can resolve them —
    /// matches `ShoppingLibrary.resolveLinks(of:into:depth:)`.
    private func resolveLinks(of recipe: Recipe, into known: inout [UUID: Recipe], depth: Int = 0) async {
        guard depth < 3 else { return }
        for id in recipe.linkedRecipeIDs where known[id] == nil {
            guard let linked = try? await recipeStore.recipe(id: id) else { continue }
            known[id] = linked
            await resolveLinks(of: linked, into: &known, depth: depth + 1)
        }
    }
}
