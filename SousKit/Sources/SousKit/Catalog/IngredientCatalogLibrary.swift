import Foundation
import Observation

/// The catalog as the app uses it: what ships with the app, plus everything
/// the cook has decided, with the cook's word winning where both know a name.
///
/// Since phase 4 this is also where the vocabulary lives — the one table that
/// used to be four. Two libraries read it (nutrition and shopping), but only
/// this one writes it, so there is a single place that knows what an
/// ingredient is and a single place that has to remember to drop the caches.
@MainActor
@Observable
public final class IngredientCatalogLibrary {
    private let store: any VocabularyStore
    /// Every change here can change what a recipe's ingredients resolve to,
    /// and with that its nutrition — which is cached against the recipe's
    /// text alone and would otherwise never notice.
    private let nutritionCache: (any RecipeNutritionStore)?

    /// Everything the app knows, ready to look up.
    public private(set) var catalog: IngredientCatalog = .bundled
    /// Everything the cook has said about an ingredient, by normalized name.
    public private(set) var vocabulary: [String: IngredientVocabularyEntry] = [:]
    public var errorMessage: String?

    public init(
        store: any VocabularyStore,
        nutritionCache: (any RecipeNutritionStore)? = nil
    ) {
        self.store = store
        self.nutritionCache = nutritionCache
    }

    /// Whether the cook's own data has been read at least once. Until it
    /// has, `catalog` is the bundled list alone — which is not what anything
    /// asking a question about a recipe should be answered from.
    private var hasLoaded = false

    public func reload() async {
        do {
            let entries = try await store.entries()
            vocabulary = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            rebuild()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the cook's data if nobody has yet.
    ///
    /// Everything that resolves an ingredient — the shopping list, the
    /// unknown-ingredient badge, nutrition — needs the full catalog, not only
    /// the two screens that happen to `reload()` on appearing. Cheap to call
    /// from any of them, since it does nothing once the data is in.
    public func ensureLoaded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    /// Two passes, because an entry that only *adds* to a shipped word has to
    /// find out which word wins its name first: merge the cook's own
    /// ingredients in front of the bundled ones, then patch the survivors
    /// with the spellings, aisles and variety relations the vocabulary holds
    /// for them, then index the result.
    private func rebuild() {
        let own = vocabulary.values
            .filter(\.isOwnIngredient)
            .map { $0.catalogIngredient(fallback: nil) }
            .sorted { $0.name < $1.name }
        let merged = IngredientCatalog(ingredients: own + IngredientCatalog.bundled.ingredients)

        guard vocabulary.values.contains(where: { !$0.isOwnIngredient }) else {
            catalog = merged
            return
        }
        let patched = merged.ingredients.map { ingredient -> CatalogIngredient in
            guard let entry = vocabulary[ingredient.key], !entry.isOwnIngredient else { return ingredient }
            return entry.catalogIngredient(fallback: ingredient)
        }
        catalog = IngredientCatalog(ingredients: patched)
    }

    // MARK: - Reading

    public var entries: [IngredientVocabularyEntry] {
        vocabulary.values.sorted { $0.name < $1.name }
    }

    /// What the cook has said about `name`, if anything.
    public func entry(for name: String) -> IngredientVocabularyEntry? {
        vocabulary[IngredientCatalog.normalize(catalog.canonicalName(for: name))]
    }

    /// Only the entries the cook added, which are the editable ones.
    public var ownIngredients: [CatalogIngredient] {
        entries.filter(\.isOwnIngredient).map { $0.catalogIngredient(fallback: nil) }
    }

    public func isOwn(_ ingredient: CatalogIngredient) -> Bool {
        vocabulary[ingredient.key]?.isOwnIngredient == true
    }

    /// The spellings of `ingredient` the cook taught it, as opposed to the
    /// ones it ships with.
    public func ownAliases(of ingredient: CatalogIngredient) -> [String] {
        guard let entry = vocabulary[ingredient.key], !entry.isOwnIngredient else { return [] }
        return entry.aliases
    }

    public var pantryKeys: Set<String> {
        Set(vocabulary.values.filter(\.isPantry).map(\.key))
    }

    /// Where each ingredient is bought, keyed like `pantryKeys` — only the
    /// entries where the cook named a store.
    public var preferredStores: [String: String] {
        vocabulary.values.reduce(into: [:]) { result, entry in
            if let store = entry.preferredStore { result[entry.key] = store }
        }
    }

    /// The ingredients named in a recipe's text that the catalog does not
    /// know — what the editor offers to add.
    public func unknownIngredients(in text: String) -> [String] {
        catalog.unknownIngredients(in: text)
    }

    // MARK: - Writing

    /// Reads, changes and writes one entry, then rebuilds and — unless the
    /// change was one no sum can see — drops the cached recipe figures.
    ///
    /// Every write goes through here, which is what keeps the invalidation
    /// from being something each new mutation has to remember. A pantry flag
    /// is the one exception that skips it: which shelf an ingredient is
    /// hunted on has never moved a calorie.
    private func mutate(
        _ name: String,
        affectsNutrition: Bool = true,
        _ change: (inout IngredientVocabularyEntry) -> Void
    ) async {
        let key = IngredientCatalog.normalize(name)
        guard !key.isEmpty else { return }
        var entry = vocabulary[key] ?? IngredientVocabularyEntry(name: name)
        change(&entry)
        do {
            _ = try await store.save(entry)
            await reload()
            if affectsNutrition { try await nutritionCache?.invalidateAll() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func save(_ ingredient: CatalogIngredient) async {
        await mutate(ingredient.name) { entry in
            entry.name = ingredient.name
            entry.isOwnIngredient = true
            entry.aliases = ingredient.aliases
            // As written, so that a variety saved without one keeps
            // inheriting rather than freezing today's resolved aisle.
            entry.category = ingredient.ownCategory
            entry.parentName = ingredient.parentName
        }
    }

    /// Takes back an ingredient the cook added. What else the entry held —
    /// a spelling taught to it, its pantry flag — goes with it: the entry
    /// *was* the ingredient.
    public func delete(_ ingredient: CatalogIngredient) async {
        do {
            try await store.delete(key: ingredient.key)
            await reload()
            try await nutritionCache?.invalidateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Teaches `ingredient` one more spelling. For a bundled entry this is
    /// the only way to widen it, since the app replaces it on every update.
    public func addAlias(_ alias: String, to ingredient: CatalogIngredient) async {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { return }
        await mutate(ingredient.name) { entry in
            if entry.name.isEmpty { entry.name = ingredient.name }
            let known = Set(entry.aliases.map(IngredientCatalog.normalize))
            guard !known.contains(IngredientCatalog.normalize(alias)) else { return }
            entry.aliases.append(alias)
        }
    }

    public func removeAlias(_ alias: String, from ingredient: CatalogIngredient) async {
        let normalized = IngredientCatalog.normalize(alias)
        await mutate(ingredient.name) { entry in
            entry.aliases.removeAll { IngredientCatalog.normalize($0) == normalized }
        }
    }

    /// The cook's call that an ingredient is a shelf staple.
    public func setPantry(_ flagged: Bool, name: String) async {
        await mutate(name, affectsNutrition: false) { entry in
            entry.isPantry = flagged
        }
    }

    /// Where an ingredient is bought and what to know at the shelf. Empty
    /// strings clear — a store preference taken back is an entry with
    /// nothing to say, and the store sweeps it like any other.
    public func setShoppingPreferences(store: String?, note: String?, name: String) async {
        let trimmedStore = store?.trimmingCharacters(in: .whitespaces)
        let trimmedNote = note?.trimmingCharacters(in: .whitespaces)
        await mutate(name, affectsNutrition: false) { entry in
            entry.preferredStore = trimmedStore?.isEmpty == false ? trimmedStore : nil
            entry.shoppingNote = trimmedNote?.isEmpty == false ? trimmedNote : nil
        }
    }

    /// Files an ingredient as a variety of another — or takes the relation
    /// back with `nil`. One level: the store refuses a parent that is itself
    /// a variety.
    public func setParent(_ parentName: String?, of name: String) async {
        await mutate(name) { entry in
            if entry.name.isEmpty { entry.name = name }
            entry.parentName = parentName
        }
    }

    /// Writes one basis decision. The nutrition library calls this rather
    /// than reaching for the store: one writer, one invalidation.
    public func setBasis(_ assignment: BasisAssignment?, state: IngredientState, of name: String) async {
        await mutate(name) { entry in
            if entry.name.isEmpty { entry.name = name }
            entry.bases[state.rawValue] = assignment
            // Answering the question retires it, whichever way it is
            // answered — that is what makes "bewusst ohne" an answer.
            if assignment != nil { entry.needsBasisReview = false }
        }
    }

    /// What one piece of an ingredient weighs, as the cook corrected it.
    public func setUnitWeight(_ grams: Double?, unit: IngredientUnit, of name: String) async {
        await mutate(name) { entry in
            if entry.name.isEmpty { entry.name = name }
            entry.unitWeightsGrams[unit.symbol] = grams
        }
    }
}
