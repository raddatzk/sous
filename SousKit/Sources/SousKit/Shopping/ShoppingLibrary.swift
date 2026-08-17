import Foundation
import Observation

/// The view-facing shopping list: what the planned week needs, plus whatever
/// was added by hand, with ticks remembered across rebuilds.
@MainActor
@Observable
public final class ShoppingLibrary {
    private let mealPlan: MealPlanLibrary
    private let recipeStore: any RecipeStore
    private let store: any ShoppingListStore

    public private(set) var items: [ShoppingItem] = []
    public var errorMessage: String?

    public init(
        mealPlan: MealPlanLibrary,
        recipeStore: any RecipeStore,
        store: any ShoppingListStore
    ) {
        self.mealPlan = mealPlan
        self.recipeStore = recipeStore
        self.store = store
    }

    /// Rebuilds the list from the week the plan is currently showing.
    public func reload() async {
        do {
            await mealPlan.reload()

            // Linked recipes contribute their own ingredients, so the builder
            // needs to look them up; they are fetched once up front.
            let planned = mealPlan.plannedRecipes
            var known: [UUID: Recipe] = [:]
            for entry in planned {
                known[entry.recipe.id] = entry.recipe
                try await resolveLinks(of: entry.recipe, into: &known)
            }

            let generated = ShoppingListBuilder.build(from: planned) { known[$0] }
            let manual = try await store.manualItems()
            let checked = try await store.checkedKeys()

            var combined = generated
            for item in manual where !combined.contains(where: { $0.key == item.key }) {
                combined.append(item)
            }
            items = combined.map { item in
                var copy = item
                copy.isChecked = checked.contains(item.key)
                return copy
            }
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

    /// Adds a line typed by hand, parsed like an ingredient so "2 kg
    /// Kartoffeln" arrives with its amount.
    public func addItem(_ line: String) async {
        let ingredient = IngredientParser.parseLine(line)
        guard !ingredient.name.isEmpty else { return }
        do {
            try await store.addManualItem(name: ingredient.name, quantity: ingredient.quantity)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeManual(_ item: ShoppingItem) async {
        do {
            try await store.removeManualItem(key: item.key)
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
}
