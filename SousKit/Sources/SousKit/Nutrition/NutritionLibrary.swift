import Foundation
import Observation

/// The view-facing nutrition for a recipe — computed once per recipe (and
/// its linked sub-recipes) and cached from then on, the same shape as
/// ``ShoppingLibrary`` resolving links before handing off to a builder.
///
/// It owns no storage of its own any more: what a cook has said about an
/// ingredient's basis lives in the vocabulary, which
/// ``IngredientCatalogLibrary`` reads and writes. This one turns those
/// decisions into the table the aggregator computes against.
@MainActor
@Observable
public final class NutritionLibrary {
    private let store: any RecipeNutritionStore
    private let recipeStore: any RecipeStore
    private let catalogLibrary: IngredientCatalogLibrary
    /// The shipped rows, injectable so a test can compute against fixtures.
    private let bls: BLSCatalog

    public var errorMessage: String?

    public init(
        store: any RecipeNutritionStore,
        recipeStore: any RecipeStore,
        catalogLibrary: IngredientCatalogLibrary,
        bls: BLSCatalog = .bundled
    ) {
        self.store = store
        self.recipeStore = recipeStore
        self.catalogLibrary = catalogLibrary
        self.bls = bls
    }

    private var catalog: IngredientCatalog { catalogLibrary.catalog }

    /// What the shipped data calls itself — what a figure names as its
    /// source, and what a confirmation records as the release it was made
    /// against.
    public var datasetVersion: String {
        bls.source.datasetVersion.isEmpty ? CatalogNutrition.blsSource : bls.source.datasetVersion
    }

    /// The bundled table with the cook's vocabulary laid over it.
    ///
    /// Recomputed whenever the vocabulary changes rather than on demand:
    /// merging re-indexes every bundled entry, and the catalog browser asks
    /// for this once per visible row.
    public private(set) var nutritionCatalog: NutritionCatalog = .bundled

    /// Rebuilds the table and drops every cached recipe total.
    ///
    /// The cache is keyed on recipe text and the shipped data, neither of
    /// which a confirmation touches — so nothing would notice on its own that
    /// a figure just stopped being provisional. Done here rather than left to
    /// the catalog library's own invalidation, because this library is the
    /// one that holds the cache: a decision taken through it must not depend
    /// on somebody else having been wired up with it.
    private func settle() async {
        rebuild()
        try? await store.invalidateAll()
    }

    /// Rebuilt from the vocabulary the catalog library holds. Called after
    /// every write there, and once on load.
    public func reload() async {
        await catalogLibrary.reload()
        rebuild()
    }

    private func rebuild() {
        let overrides = catalogLibrary.entries.compactMap {
            $0.nutritionOverride(bls: bls, source: datasetVersion)
        }
        nutritionCatalog = overrides.isEmpty ? .bundled : NutritionCatalog.bundled.merging(overrides)
    }

    /// Reads the cook's own decisions, and the catalog they are keyed by, if
    /// nobody has yet — computing a recipe against half the data would not
    /// just show the wrong total, it would cache it.
    public func ensureLoaded() async {
        await catalogLibrary.ensureLoaded()
        rebuild()
    }

    // MARK: - The basis of one ingredient

    /// What `name` currently resolves to, shipped values and the cook's
    /// decisions taken together.
    public func nutrition(forName name: String) -> CatalogNutrition? {
        nutritionCatalog.nutrition(forCanonicalName: catalog.canonicalName(for: name))
    }

    /// The cook's own entry for `name`, if there is one — what tells an entry
    /// form apart from a read-only display of bundled values.
    public func ownNutrition(forCanonicalName name: String) -> CatalogNutrition? {
        guard let entry = catalogLibrary.entry(for: name),
              entry.bases.values.contains(where: { $0.values != nil })
        else { return nil }
        return entry.nutritionOverride(bls: bls, source: datasetVersion)
    }

    /// Whether anybody has answered the basis question for `name`.
    public func basisStatus(forName name: String) -> NutritionBasis.Status? {
        nutrition(forName: name)?.basis(for: .unspecified)?.status
    }

    /// Whether the re-key onto SBLS codes never found a row for this name.
    ///
    /// The stamp phase 3 wrote and nobody read. It does not stop anything —
    /// the cook's numbers work by name, which is the compatibility path — but
    /// it is a question standing open, and the ingredient form is where it
    /// gets asked.
    public func needsBasisReview(forName name: String) -> Bool {
        catalogLibrary.entry(for: name)?.needsBasisReview == true
    }

    /// Records what a cook typed for one ingredient, and drops every cached
    /// recipe total — the cache knows only about recipe text, so without this
    /// a recipe already looked at would keep its old, incomplete figure.
    public func saveIngredientNutrition(_ nutrition: CatalogNutrition) async {
        let values = nutrition.bases[IngredientState.unspecified.rawValue]?.values
            ?? nutrition.bases.values.first?.values
        guard let values else { return }
        // Filed under the name the catalog resolved to, not the one typed:
        // numbers entered for "Tomaten" are numbers for the ingredient, and
        // an entry keyed by a spelling would be a second vocabulary word.
        let name = catalog.canonicalName(for: nutrition.name)
        await catalogLibrary.setBasis(
            .ownValues(
                values,
                // The code the numbers stand in for, kept so a data update
                // can still tell the cook if that row has gone.
                code: catalogLibrary.entry(for: name)?
                    .bases[IngredientState.unspecified.rawValue]?.code,
                source: nutrition.source
            ),
            state: .unspecified,
            of: name
        )
        if let perPiece = nutrition.unitWeightsGrams[IngredientUnit.piece.symbol] {
            await catalogLibrary.setUnitWeight(perPiece, unit: .piece, of: name)
        }
        await settle()
    }

    public func deleteIngredientNutrition(name: String) async {
        let name = catalog.canonicalName(for: name)
        await catalogLibrary.setBasis(nil, state: .unspecified, of: name)
        await catalogLibrary.setUnitWeight(nil, unit: .piece, of: name)
        await settle()
    }

    /// The cook picked a row: the mapping is settled, for every recipe.
    public func confirmBasis(code: String, state: IngredientState = .unspecified, forName name: String) async {
        await catalogLibrary.setBasis(
            .confirmed(
                code: code,
                catalogName: bls.entry(for: code)?.name,
                datasetVersion: datasetVersion
            ),
            state: state,
            of: catalog.canonicalName(for: name)
        )
        await settle()
    }

    /// The cook accepted what was proposed, whatever it was — the one-tap
    /// half of the batch flow.
    public func confirmProposedBasis(forName name: String, state: IngredientState = .unspecified) async {
        guard let basis = nutrition(forName: name)?.basis(for: state), let code = basis.code else { return }
        await confirmBasis(code: code, state: state, forName: name)
    }

    /// The cook decided there are no values for this, on purpose. A settled
    /// answer: it stops counting as a defect and stops being asked about.
    public func setDeliberatelyWithoutBasis(forName name: String, state: IngredientState = .unspecified) async {
        await catalogLibrary.setBasis(
            .deliberatelyWithout, state: state, of: catalog.canonicalName(for: name)
        )
        await settle()
    }

    /// Takes a decision back, leaving whatever the shipped data proposes.
    public func clearBasis(forName name: String, state: IngredientState = .unspecified) async {
        await catalogLibrary.setBasis(nil, state: state, of: catalog.canonicalName(for: name))
        await settle()
    }

    /// The rows the picker offers for `name`: what the synonym table already
    /// knows, then everything the catalog's own names turn up, deduplicated
    /// and never longer than a person will read.
    public func candidates(forName name: String, limit: Int = 30) -> [BLSEntry] {
        let canonical = catalog.canonicalName(for: name)
        let entry = nutritionCatalog.nutrition(forCanonicalName: canonical)
        var seen = Set<String>()
        var rows: [BLSEntry] = []
        for code in entry?.candidateCodes ?? [] {
            guard let row = bls.entry(for: code), seen.insert(row.code).inserted else { continue }
            rows.append(row)
        }
        for row in bls.search(canonical, limit: limit) where seen.insert(row.code).inserted {
            rows.append(row)
        }
        // The written word rarely is the catalog's; searching the parent as
        // well is what gives a variety something to choose from.
        if rows.count < limit, let parent = catalog.ingredient(for: canonical)?.parentName {
            for row in bls.search(parent, limit: limit) where seen.insert(row.code).inserted {
                rows.append(row)
            }
        }
        return Array(rows.prefix(limit))
    }

    public func row(forCode code: String) -> BLSEntry? { bls.entry(for: code) }

    /// The catalog entry a written name stands for — what an ingredient form
    /// opened from a picker edits. A name nothing knows becomes a new entry,
    /// which is exactly what typing values for it will make it.
    public func catalogIngredient(forName name: String) -> CatalogIngredient {
        catalog.ingredient(for: name) ?? CatalogIngredient(name: name, category: .other)
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
