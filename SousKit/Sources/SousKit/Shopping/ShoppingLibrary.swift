import Foundation
import Observation

/// The view-facing shopping list.
///
/// The list is what it is; nothing changes it but adding, ticking, and
/// clearing. Recipes and whole weeks are put on it deliberately.
@MainActor
@Observable
public final class ShoppingLibrary {
    private let store: any ShoppingListStore
    private let recipeStore: any RecipeStore

    public private(set) var items: [ShoppingItem] = []
    public var errorMessage: String?
    /// Set after something was added, so the interface can say what happened.
    public var lastAddition: String?

    public init(store: any ShoppingListStore, recipeStore: any RecipeStore) {
        self.store = store
        self.recipeStore = recipeStore
    }

    public func reload() async {
        do {
            items = try await store.items()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Puts a recipe's ingredients on the list, at the servings it is being
    /// cooked for. Linked recipes contribute what they are made of.
    public func add(_ recipe: Recipe, servings: Int? = nil) async {
        await add([(recipe, servings ?? recipe.servings)], describing: recipe.title)
    }

    /// Puts everything planned for a set of days on the list.
    public func add(planned: [(recipe: Recipe, servings: Int)], describing description: String) async {
        await add(planned, describing: description)
    }

    private func add(_ planned: [(Recipe, Int)], describing description: String) async {
        do {
            var known: [UUID: Recipe] = [:]
            for entry in planned {
                known[entry.0.id] = entry.0
                try await resolveLinks(of: entry.0, into: &known)
            }

            let built = ShoppingListBuilder.build(
                from: planned.map { (recipe: $0.0, servings: $0.1) }
            ) { known[$0] }

            try await store.add(built)
            await reload()
            lastAddition = description
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Follows links a level at a time so the builder can resolve them.
    private func resolveLinks(of recipe: Recipe, into known: inout [UUID: Recipe], depth: Int = 0) async throws {
        guard depth < 3 else { return }
        for id in recipe.linkedRecipeIDs where known[id] == nil {
            guard let linked = try await recipeStore.recipe(id: id) else { continue }
            known[id] = linked
            try await resolveLinks(of: linked, into: &known, depth: depth + 1)
        }
    }

    /// Adds a line typed by hand, parsed like an ingredient so "2 kg
    /// Kartoffeln" arrives with its amount.
    public func addItem(_ line: String) async {
        let ingredient = IngredientParser.parseLine(line)
        let name = ShoppingItem.displayName(for: ingredient.name)
        guard !name.isEmpty else { return }

        let item = ShoppingItem(
            key: ShoppingItem.key(for: ingredient.name),
            name: name,
            quantities: ingredient.quantity.map { [$0] } ?? []
        )
        do {
            try await store.add([item])
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggle(_ item: ShoppingItem) async {
        do {
            try await store.setChecked(!item.isChecked, key: item.key)
            if let index = items.firstIndex(where: { $0.key == item.key }) {
                items[index].isChecked.toggle()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func remove(_ item: ShoppingItem) async {
        do {
            try await store.remove(key: item.key)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearChecked() async {
        do {
            try await store.clearChecked()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var openItems: [ShoppingItem] { items.filter { !$0.isChecked } }
    public var checkedItems: [ShoppingItem] { items.filter(\.isChecked) }

    /// The open items grouped by the recipe that wants them, with the amount
    /// that recipe asks for. An ingredient two dishes need appears under both.
    public var byRecipe: [(recipe: String, items: [ShoppingItem])] {
        var order: [String] = []
        var grouped: [String: [ShoppingItem]] = [:]

        for item in items {
            for source in item.sources {
                if grouped[source.recipeTitle] == nil {
                    order.append(source.recipeTitle)
                    grouped[source.recipeTitle] = []
                }
                // Shown with this recipe's share, not the combined total.
                var portion = item
                portion.quantities = source.quantities
                grouped[source.recipeTitle]?.append(portion)
            }
            if item.isManual {
                let own = "Von Hand"
                if grouped[own] == nil {
                    order.append(own)
                    grouped[own] = []
                }
                grouped[own]?.append(item)
            }
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}
