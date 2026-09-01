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

    /// Which state a decision about `name` has to be written under, for a
    /// line that asked for `state`.
    ///
    /// Not simply the line's state, and that is the whole point. A basis is
    /// stored per state and read with a fallback (`CatalogNutrition.basis`),
    /// so the question a cook is looking at is not always filed where the
    /// line stands: "Kartoffeln, gegart" whose entry has only an
    /// `unspecified` basis is *answered* by that basis, and an answer written
    /// under `cooked` would leave the one being repaired untouched — orphaned
    /// mapping and all. Conversely a line whose own state does have a basis
    /// must edit that one and not the general row.
    ///
    /// The fallback order here mirrors `CatalogNutrition.basis(for:)`
    /// exactly; where nothing is stored at all, the line's own state stands,
    /// because that is what the cook is looking at.
    public func basisState(
        forName name: String, asking state: IngredientState = .unspecified
    ) -> IngredientState {
        guard let entry = nutrition(forName: name) else { return state }
        if entry.hasOwnBasis(for: state) { return state }
        for fallback in IngredientState.displayOrder where entry.hasOwnBasis(for: fallback) {
            return fallback
        }
        return state
    }

    /// Whether anybody has answered the basis question for `name`.
    public func basisStatus(forName name: String) -> NutritionBasis.Status? {
        nutrition(forName: name)?.basis(for: .unspecified)?.status
    }

    /// Whether a question about this word's basis is standing open.
    ///
    /// Two things write this stamp, and the distinction matters to whoever
    /// prints it: phase 3's re-key, when a name matched no row at all, and
    /// phase 6's reconciliation, when the row a mapping *did* point at is
    /// gone from a new release. Neither stops anything — the cook's numbers
    /// work by name, which is the compatibility path — but both are questions,
    /// and the ingredient form is where they get asked. Which of the two it
    /// is, ``orphanedCatalogNames(forName:)`` answers.
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
        // The code the numbers stand in for, kept so a data update can still
        // tell the cook if that row has gone — and since phase 6 with the
        // same two stamps a confirmation carries, so that "gone" can name
        // what it was and say which release it was last seen in. Own values
        // never orphan; what they lose is the note, not the numbers.
        let replaced = catalogLibrary.entry(for: name)?
            .bases[IngredientState.unspecified.rawValue]
        let code = replaced?.code
        // A row that still resolves is stamped as of now; one that does not
        // keeps whatever the last confirmation remembered, because that is
        // the release the name it carries was true in.
        let row = code.flatMap { bls.entry(for: $0) }
        await catalogLibrary.setBasis(
            .ownValues(
                values,
                code: code,
                catalogName: row?.name ?? replaced?.catalogName,
                datasetVersion: row == nil ? replaced?.datasetVersion : datasetVersion,
                source: nutrition.source
            ),
            state: .unspecified,
            of: name
        )
        for (symbol, grams) in nutrition.unitWeightsGrams {
            await catalogLibrary.setUnitWeight(grams, unit: IngredientUnit(symbol: symbol), of: name)
        }
        await settle()
    }

    /// Takes back the numbers, and only the numbers.
    ///
    /// The piece weight used to go with them, which made no sense in either
    /// direction: what an onion weighs is not a nutrition value, and losing
    /// it because the cook withdrew their calories was a second decision
    /// nobody asked for. Measures are edited on their own now — see
    /// ``setUnitWeight(_:unit:forName:)``.
    public func deleteIngredientNutrition(name: String) async {
        let name = catalog.canonicalName(for: name)
        await catalogLibrary.setBasis(nil, state: .unspecified, of: name)
        await settle()
    }

    /// What one of `unit` weighs for this ingredient, as the cook corrected
    /// it — "my onions are bigger", and equally "an Esslöffel of my honey is
    /// 25 g". `nil` takes the correction back, leaving whatever the measure
    /// table says.
    ///
    /// Any unit, not only `Stk.`: the storage was always a dictionary keyed
    /// by unit symbol, and the concept asks for exactly this ("the cook can
    /// override any value on their ingredient"). A weight written here beats
    /// the density for that unit — see `NutritionResolver.resolve`.
    public func setUnitWeight(_ grams: Double?, unit: IngredientUnit, forName name: String) async {
        await catalogLibrary.setUnitWeight(grams, unit: unit, of: catalog.canonicalName(for: name))
        await settle()
    }

    /// What the app currently believes one of `unit` weighs for `name`,
    /// shipped table and the cook's correction taken together — what a
    /// correction field starts out showing.
    public func unitWeight(_ unit: IngredientUnit, forName name: String) -> Double? {
        nutrition(forName: name)?.unitWeightsGrams[unit.symbol]
    }

    /// Whether the weight for `unit` is the cook's own rather than the
    /// shipped one — what tells a correction from a default in the form.
    public func hasOwnUnitWeight(_ unit: IngredientUnit, forName name: String) -> Bool {
        catalogLibrary.entry(for: name)?.unitWeightsGrams[unit.symbol] != nil
    }

    /// The cook picked a row: the mapping is settled, for every recipe.
    ///
    /// Numbers already typed for this ingredient survive the pick. The two
    /// directions used to disagree: ``saveIngredientNutrition(_:)`` carries
    /// the code across so own values remember the row they stand in for, but
    /// this one built a fresh assignment with no `values` at all, and
    /// `setBasis` replaces the whole slot — so typing values and *then*
    /// naming their row silently threw the values away, while doing it the
    /// other way round kept both. A cook picking a row is saying which row
    /// their numbers stand in for; the way to go back to the table's own
    /// numbers is "Zurücknehmen", which says so.
    public func confirmBasis(code: String, state: IngredientState = .unspecified, forName name: String) async {
        let name = catalog.canonicalName(for: name)
        let row = bls.entry(for: code)
        let existing = catalogLibrary.entry(for: name)?.bases[state.rawValue]
        let assignment: BasisAssignment = if let values = existing?.values {
            .ownValues(
                values,
                code: code,
                catalogName: row?.name,
                datasetVersion: datasetVersion,
                source: existing?.source ?? CatalogNutrition.ownSource
            )
        } else {
            .confirmed(code: code, catalogName: row?.name, datasetVersion: datasetVersion)
        }
        await catalogLibrary.setBasis(assignment, state: state, of: name)
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

    /// The rows a typed query finds — the free search beside the proposals.
    ///
    /// Deliberately not the same question as ``candidates(forName:limit:)``.
    /// That one asks *what could this word mean*, and every route it takes
    /// starts from a name the app already holds: the curation's codes, the
    /// kitchen word, the parent, the remembered name of an orphan. This one
    /// asks *I know the row, let me find it* — and it is the only way in for
    /// a word whose catalog row shares no spelling with it. Without it,
    /// Zimt's whole offer was breakfast cereal at 424 kcal or nothing at all.
    ///
    /// Short queries come back empty rather than with the first forty rows of
    /// the table: `BLSCatalog.search` wants three characters, and a list that
    /// changes completely on the third keystroke is worse than one that waits
    /// for it.
    public func search(_ query: String, limit: Int = 30) -> [BLSEntry] {
        bls.search(query, limit: limit)
    }

    /// The rows the picker offers for `name`: what the synonym table already
    /// knows, then everything the catalog's own names turn up, deduplicated
    /// and never longer than a person will read.
    public func candidates(forName name: String, limit: Int = 30) -> [BLSEntry] {
        let canonical = catalog.canonicalName(for: name)
        let entry = nutritionCatalog.nutrition(forCanonicalName: canonical)
        // A word that has been answered has nothing to propose. Every route
        // below is a *guess* at what the word might mean, and guessing at a
        // settled question is how Zimt came to be offered breakfast cereal at
        // 424 kcal. The free search stays open for a cook who disagrees —
        // this only stops the app from volunteering.
        if entry?.basis(for: .unspecified)?.status == .deliberatelyWithout { return [] }
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
        // The successor proposal of concept §7. A code that vanished took its
        // row with it, but not the name that row had when the cook confirmed
        // it — and that name is catalog language, which the kitchen word is
        // not: "Schmelzkäse, mind. 45 % Fett i. Tr." finds its neighbours,
        // "Schmelzkäse" alone finds fewer of them. No reverse index is needed
        // for this; the mapping sits in a vocabulary entry whose own name is
        // the kitchen word, and the remembered name sits beside it.
        if rows.count < limit {
            for remembered in orphanedCatalogNames(forName: canonical) {
                for row in bls.search(remembered, limit: limit)
                where seen.insert(row.code).inserted {
                    rows.append(row)
                }
            }
        }
        return Array(rows.prefix(limit))
    }

    /// Every mapping in the vocabulary that points at a row the shipped data
    /// no longer has, with the state it is filed under — the whole of what
    /// decision D allows the app to report after a data change, and nothing
    /// besides. Changed values are not in here because they are not looked
    /// for: they flow into the sums silently, which is the decision.
    ///
    /// Computed off the loaded vocabulary rather than off the reconciliation
    /// pass's report, so it shortens as the cook answers and empties itself
    /// entirely if a later release brings a row back.
    public var orphanedIngredients: [NutritionCoverage.OpenIngredient] {
        catalogLibrary.entries.flatMap { entry in
            IngredientState.displayOrder.compactMap { state in
                guard entry.bases[state.rawValue]?.isOrphaned(in: bls) == true else { return nil }
                return NutritionCoverage.OpenIngredient(name: entry.name, state: state)
            }
        }
    }

    /// What the vanished rows behind `name` were called — the "beruhte auf:
    /// …" of an orphaned mapping, read live off the vocabulary rather than
    /// out of a cached coverage, so it disappears by itself the moment the
    /// mapping is repaired or the row comes back.
    public func orphanedCatalogNames(forName name: String) -> [String] {
        catalogLibrary.entry(for: name)?.orphanedCatalogNames(in: bls) ?? []
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
