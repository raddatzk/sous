import Foundation
import Observation

/// The view-facing state of the meal plan: one week at a time, with the
/// recipes behind its entries resolved for display.
@MainActor
@Observable
public final class MealPlanLibrary {
    private let store: any MealPlanStore
    private let recipeStore: any RecipeStore

    /// The week being shown, seven days starting on its first weekday.
    public private(set) var days: [Date]
    public private(set) var entries: [MealPlanEntry] = []
    /// Recipes referenced by the current week, by id.
    public private(set) var recipes: [UUID: Recipe] = [:]
    public var errorMessage: String?

    public init(store: any MealPlanStore, recipeStore: any RecipeStore, today: Date = Date()) {
        self.store = store
        self.recipeStore = recipeStore
        days = today.weekDays
    }

    public func reload() async {
        do {
            entries = try await store.entries(for: days)

            // Only the recipes this week actually shows, fetched once each.
            var resolved: [UUID: Recipe] = [:]
            for id in Set(entries.map(\.recipeID)) {
                resolved[id] = try await recipeStore.recipe(id: id)
            }
            recipes = resolved
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func showWeek(offset: Int) async {
        guard let anchor = days.first else { return }
        days = anchor.addingWeeks(offset).weekDays
        await reload()
    }

    public func showCurrentWeek(today: Date = Date()) async {
        days = today.weekDays
        await reload()
    }

    /// Entries planned for a day, with their recipe where it still exists.
    public func plan(for day: Date) -> [(entry: MealPlanEntry, recipe: Recipe?)] {
        entries
            .filter { $0.day == day.startOfDay }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0, recipes[$0.recipeID]) }
    }

    public func add(_ recipe: Recipe, to day: Date) async {
        let entry = MealPlanEntry(
            day: day,
            recipeID: recipe.id,
            sortOrder: plan(for: day).count
        )
        do {
            try await store.save(entry)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func remove(_ entry: MealPlanEntry) async {
        do {
            try await store.delete(id: entry.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Every recipe on the plan, paired with the servings it is planned for —
    /// what a shopping list is built from.
    public var plannedRecipes: [(recipe: Recipe, servings: Int)] {
        entries.compactMap { entry in
            guard let recipe = recipes[entry.recipeID] else { return nil }
            return (recipe, entry.servings ?? recipe.servings)
        }
    }
}
