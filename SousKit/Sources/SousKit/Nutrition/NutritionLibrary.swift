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
    private let nutritionStore: (any CatalogNutritionStore)?

    /// Nutrition the cook entered by hand, for ingredients BLS does not
    /// cover — or covers with numbers they disagree with.
    public private(set) var ownNutrition: [CatalogNutrition] = []
    public var errorMessage: String?

    public init(
        store: any RecipeNutritionStore,
        recipeStore: any RecipeStore,
        catalogLibrary: IngredientCatalogLibrary? = nil,
        nutritionStore: (any CatalogNutritionStore)? = nil
    ) {
        self.store = store
        self.recipeStore = recipeStore
        self.catalogLibrary = catalogLibrary
        self.nutritionStore = nutritionStore
    }

    private var catalog: IngredientCatalog {
        catalogLibrary?.catalog ?? .bundled
    }

    /// The bundled table with the cook's own entries laid over it.
    ///
    /// Stored rather than computed on demand: merging re-indexes every
    /// bundled entry, and the catalog browser asks for this once per visible
    /// row. It only changes when `ownNutrition` does.
    public private(set) var nutritionCatalog: NutritionCatalog = .bundled

    private var hasLoaded = false

    public func reload() async {
        do {
            ownNutrition = try await nutritionStore?.all() ?? []
            nutritionCatalog = ownNutrition.isEmpty ? .bundled : NutritionCatalog.bundled.merging(ownNutrition)
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the cook's own numbers, and the catalog they are keyed by, if
    /// nobody has yet — computing a recipe against half the data would not
    /// just show the wrong total, it would cache it.
    public func ensureLoaded() async {
        await catalogLibrary?.ensureLoaded()
        guard !hasLoaded else { return }
        await reload()
    }

    /// Records what a cook typed for one ingredient, and drops every cached
    /// recipe total — the cache knows only about recipe text, so without this
    /// a recipe already looked at would keep its old, incomplete figure.
    public func saveIngredientNutrition(_ nutrition: CatalogNutrition) async {
        guard let nutritionStore else { return }
        do {
            try await nutritionStore.save(nutrition)
            await reload()
            try await store.invalidateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteIngredientNutrition(name: String) async {
        guard let nutritionStore else { return }
        do {
            try await nutritionStore.delete(canonicalName: name)
            await reload()
            try await store.invalidateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The cook's own entry for `name`, if there is one — what tells an entry
    /// form apart from a read-only display of bundled values.
    public func ownNutrition(forCanonicalName name: String) -> CatalogNutrition? {
        let key = IngredientCatalog.normalize(name)
        return ownNutrition.first { IngredientCatalog.normalize($0.name) == key }
    }

    /// The nutrition for `recipe` at `servings` (the recipe's own count if
    /// omitted) — from cache when nothing relevant has changed, computed and
    /// cached otherwise.
    public func nutrition(for recipe: Recipe, servings: Int? = nil) async -> RecipeNutrition? {
        let servings = servings ?? recipe.servings
        guard servings > 0 else { return nil }
        await ensureLoaded()

        var known: [UUID: Recipe] = [recipe.id: recipe]
        await resolveLinks(of: recipe, into: &known)
        // Captured as an immutable snapshot: `resolve` crosses into the
        // nutrition store's actor, which requires a `@Sendable` closure —
        // a `var` dictionary cannot be captured by reference into one.
        let resolved = known
        let resolve: @Sendable (UUID) -> Recipe? = { resolved[$0] }

        if let cached = try? await store.nutrition(for: recipe, servings: servings, resolve: resolve) {
            return cached
        }

        let report = NutritionAggregator.aggregate(
            recipe: recipe, servings: servings, catalog: catalog,
            nutritionCatalog: nutritionCatalog, resolve: resolve
        )
        let perPortion = report.total.scaled(by: 1 / Double(servings))
        let result = RecipeNutrition(
            perPortion: perPortion, servings: servings,
            nrf93Score: NRF93Score.score(for: perPortion), coverage: report.coverage
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
