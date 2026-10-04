import Foundation
import Observation

/// The view-facing nutrition for a recipe — computed once per recipe (and
/// its linked sub-recipes) and cached from then on, the same shape as
/// ``ShoppingLibrary`` resolving links before handing off to a builder.
///
/// It owns no storage of its own: the data set's table, with the household's
/// local answers laid over it by ``IngredientCatalogLibrary``, is the table
/// the aggregator computes against.
@MainActor
@Observable
public final class NutritionLibrary {
    private let store: any RecipeNutritionStore
    private let recipeStore: any RecipeStore
    private let catalogLibrary: IngredientCatalogLibrary
    /// The household the figures are computed for — part of the cache key.
    /// Injectable because ``ActiveHousehold/id`` is process-wide, and tests
    /// run side by side.
    private let household: @MainActor () -> UUID?

    public var errorMessage: String?

    public init(
        store: any RecipeNutritionStore,
        recipeStore: any RecipeStore,
        catalogLibrary: IngredientCatalogLibrary,
        household: @escaping @MainActor () -> UUID? = { ActiveHousehold.id }
    ) {
        self.store = store
        self.recipeStore = recipeStore
        self.catalogLibrary = catalogLibrary
        self.household = household
    }

    private var catalog: IngredientCatalog { catalogLibrary.catalog }

    /// The data set's table with the household's local answers laid over
    /// it.
    ///
    /// Recomputed whenever the answers change rather than on demand: laying
    /// them over re-indexes the table, and the drilldown asks for this once
    /// per visible row.
    public private(set) var nutritionCatalog: NutritionCatalog = .current

    /// Rebuilt from the answers the catalog library holds. Called once on
    /// load.
    public func reload() async {
        await catalogLibrary.reload()
        rebuild()
    }

    /// The local answers over the data set — a household's answer is the
    /// last word (INGREDIENTS-DATA §3 B).
    ///
    /// Skipped while the catalog library has not rebuilt since: this runs at
    /// the start of every recipe's lookup.
    private func rebuild() {
        guard builtFromRevision != catalogLibrary.revision else { return }
        builtFromRevision = catalogLibrary.revision
        nutritionCatalog = catalogLibrary.appliedAnswers.nutrition(over: catalogLibrary.dataSet.nutrition)
        answersFingerprint = catalogLibrary.localAnswers.fingerprint
    }

    private var builtFromRevision = -1
    /// What the household has said about its ingredients, digested.
    private var answersFingerprint = ""

    /// The cache key's second half: which household, and what it has said.
    /// A household switch, an answer written here, or one synced in from
    /// another device each make a different key — so a cached figure is
    /// never one computed against other answers.
    public var cacheContext: String {
        "\(household()?.uuidString ?? "none")|\(answersFingerprint)"
    }

    /// Rebuilds everything a household's figures rest on, and drops the
    /// cached ones — what a household switch calls. The cache key alone
    /// would already miss; clearing as well keeps another household's
    /// figures from lingering in the store.
    public func householdDidChange() async {
        await catalogLibrary.reload()
        rebuild()
        do {
            try await store.invalidateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the household's answers, and the catalog they are keyed by, if
    /// nobody has yet — computing a recipe against half the data would not
    /// just show the wrong total, it would cache it.
    public func ensureLoaded() async {
        await catalogLibrary.ensureLoaded()
        rebuild()
    }

    // MARK: - The basis of one ingredient

    /// What `name` currently resolves to, the data set's values and the
    /// household's answers taken together.
    public func nutrition(forName name: String) -> CatalogNutrition? {
        nutritionCatalog.nutrition(forCanonicalName: catalog.canonicalName(for: name))
    }

    /// What one of `unit` weighs for `name`, as the household weighed it —
    /// "my onions are bigger", and equally "an Esslöffel of my honey is
    /// 25 g". Written as an own weight of the name's local answer, which
    /// beats the catalog's weight for that unit (§3 B). `nil` takes it back.
    public func setUnitWeight(_ grams: Double?, unit: IngredientUnit, forName name: String) async {
        await catalogLibrary.setLocalWeight(grams, unit: unit, of: name)
        rebuild()
    }

    /// What the app currently believes one of `unit` weighs for `name`,
    /// the catalog's table and the household's weight taken together — what
    /// a correction field starts out showing.
    public func unitWeight(_ unit: IngredientUnit, forName name: String) -> Double? {
        nutrition(forName: name)?.unitWeightsGrams[unit.symbol]
    }

    /// Whether the weight for `unit` is the household's own rather than the
    /// catalog's — what tells a correction from a default.
    public func hasOwnUnitWeight(_ unit: IngredientUnit, forName name: String) -> Bool {
        guard let trace = catalogLibrary.localTrace(for: name), trace.status == .applied else { return false }
        return trace.answer.weights[unit.symbol] != nil
    }

    // MARK: - Recipes

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

        let context = cacheContext
        if let cached = try? await store.nutrition(
            for: recipe, servings: servings, context: context, resolve: resolve
        ) {
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
        do {
            try await store.save(result, for: recipe, context: context, resolve: resolve)
        } catch {
            errorMessage = error.localizedDescription
        }
        return result
    }

    /// Follows links a level at a time so the aggregator can resolve them —
    /// matches `ShoppingLibrary.resolveLinks(of:into:depth:)`.
    private func resolveLinks(of recipe: Recipe, into known: inout [UUID: Recipe], depth: Int = 0) async {
        guard depth < RecipeLink.maxDepth else { return }
        for id in recipe.linkedRecipeIDs where known[id] == nil {
            guard let linked = try? await recipeStore.recipe(id: id) else { continue }
            known[id] = linked
            await resolveLinks(of: linked, into: &known, depth: depth + 1)
        }
    }
}
