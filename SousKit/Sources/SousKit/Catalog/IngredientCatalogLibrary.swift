import Foundation
import Observation

/// The catalog as the app uses it: what ships with the app, plus what the
/// cook added, with the cook's version winning where both know a name.
@MainActor
@Observable
public final class IngredientCatalogLibrary {
    private let store: any IngredientCatalogStore

    /// Everything the app knows, ready to look up.
    public private(set) var catalog: IngredientCatalog = .bundled
    /// Only the entries the cook added, which are the editable ones.
    public private(set) var ownIngredients: [CatalogIngredient] = []
    public var errorMessage: String?

    public init(store: any IngredientCatalogStore) {
        self.store = store
    }

    public func reload() async {
        do {
            ownIngredients = try await store.ingredients()
            rebuild()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The cook's entries come first, so a name they defined overrides the
    /// bundled one rather than the other way round.
    private func rebuild() {
        catalog = IngredientCatalog(ingredients: ownIngredients + IngredientCatalog.bundled.ingredients)
    }

    public func save(_ ingredient: CatalogIngredient) async {
        do {
            try await store.save(ingredient)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ ingredient: CatalogIngredient) async {
        do {
            try await store.delete(key: ingredient.key)
            await reload()
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
        var seen = Set<String>()
        return IngredientParser.parse(text).compactMap { ingredient in
            let name = ShoppingItem.displayName(for: ingredient.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2,
                  // A link points at a recipe, not at something to look up.
                  RecipeLink.referencedIDs(in: ingredient.name).isEmpty,
                  catalog.ingredient(for: name) == nil,
                  seen.insert(IngredientCatalog.normalize(name)).inserted
            else { return nil }
            return name
        }
    }
}
