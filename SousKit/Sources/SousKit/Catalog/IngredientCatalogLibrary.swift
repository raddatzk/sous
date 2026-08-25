import Foundation
import Observation

/// The catalog as the app uses it: what ships with the app, plus what the
/// cook added, with the cook's version winning where both know a name.
@MainActor
@Observable
public final class IngredientCatalogLibrary {
    private let store: any IngredientCatalogStore
    private let aliasStore: (any IngredientAliasOverrideStore)?
    /// Every change here can change what a recipe's ingredients resolve to,
    /// and with that its nutrition — which is cached against the recipe's
    /// text alone and would otherwise never notice.
    private let nutritionCache: (any RecipeNutritionStore)?

    /// Everything the app knows, ready to look up.
    public private(set) var catalog: IngredientCatalog = .bundled
    /// Only the entries the cook added, which are the editable ones.
    public private(set) var ownIngredients: [CatalogIngredient] = []
    /// Extra spellings the cook taught entries that already existed, keyed by
    /// the key of the entry they belong to.
    public private(set) var aliasOverrides: [String: [String]] = [:]
    public var errorMessage: String?

    public init(
        store: any IngredientCatalogStore,
        aliasStore: (any IngredientAliasOverrideStore)? = nil,
        nutritionCache: (any RecipeNutritionStore)? = nil
    ) {
        self.store = store
        self.aliasStore = aliasStore
        self.nutritionCache = nutritionCache
    }

    /// Whether the cook's own data has been read at least once. Until it
    /// has, `catalog` is the bundled list alone — which is not what anything
    /// asking a question about a recipe should be answered from.
    private var hasLoaded = false

    public func reload() async {
        do {
            ownIngredients = try await store.ingredients()
            aliasOverrides = try await aliasStore?.overridesByKey() ?? [:]
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

    /// Two passes, because an override targets whichever entry *wins* a name,
    /// which is only known once the cook's entries have shadowed the bundled
    /// ones: merge first, then patch the survivors with their extra
    /// spellings, then index the result.
    private func rebuild() {
        let merged = IngredientCatalog(ingredients: ownIngredients + IngredientCatalog.bundled.ingredients)
        guard !aliasOverrides.isEmpty else {
            catalog = merged
            return
        }
        let patched = merged.ingredients.map { ingredient -> CatalogIngredient in
            guard let extra = aliasOverrides[ingredient.key], !extra.isEmpty else { return ingredient }
            var copy = ingredient
            copy.aliases += extra
            return copy
        }
        catalog = IngredientCatalog(ingredients: patched)
    }

    /// Teaches `ingredient` one more spelling, without touching the entry
    /// itself — the only way to widen a bundled entry, which the app replaces
    /// on every update.
    public func addAlias(_ alias: String, to ingredient: CatalogIngredient) async {
        guard let aliasStore else { return }
        do {
            try await aliasStore.addAlias(alias, toKey: ingredient.key)
            await reload()
            try await nutritionCache?.invalidateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeAlias(_ alias: String, from ingredient: CatalogIngredient) async {
        guard let aliasStore else { return }
        do {
            try await aliasStore.removeAlias(alias, fromKey: ingredient.key)
            await reload()
            try await nutritionCache?.invalidateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The spellings of `ingredient` that came from an override, and so can
    /// be taken away again — as opposed to the ones it ships with.
    public func ownAliases(of ingredient: CatalogIngredient) -> [String] {
        aliasOverrides[ingredient.key] ?? []
    }

    public func save(_ ingredient: CatalogIngredient) async {
        do {
            try await store.save(ingredient)
            await reload()
            try await nutritionCache?.invalidateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ ingredient: CatalogIngredient) async {
        do {
            try await store.delete(key: ingredient.key)
            await reload()
            try await nutritionCache?.invalidateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func isOwn(_ ingredient: CatalogIngredient) -> Bool {
        ownIngredients.contains { $0.key == ingredient.key }
    }

    /// The ingredients named in a recipe's text that the catalog does not
    /// know — what the editor offers to add.
    public func unknownIngredients(in text: String) -> [String] {
        catalog.unknownIngredients(in: text)
    }
}
