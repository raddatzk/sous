import Foundation
import Observation

/// The meal plan as one continuous run of days rather than a week at a time.
///
/// Planning does not happen in weekly blocks: two days ahead on Monday, then
/// nothing until the weekend. The list starts today and grows as it is
/// scrolled, so there is no boundary to bump into.
@MainActor
@Observable
public final class MealPlanLibrary {
    private let store: any MealPlanStore
    private let recipeStore: any RecipeStore

    /// How many days are added at a time.
    private static let pageLength = 28

    /// The days on screen, starting today, in order.
    public private(set) var days: [Date] = []
    public private(set) var entries: [MealPlanEntry] = []
    /// Recipes referenced by the visible days, by id.
    public private(set) var recipes: [UUID: Recipe] = [:]
    public var errorMessage: String?

    private let firstDay: Date

    public init(store: any MealPlanStore, recipeStore: any RecipeStore, today: Date = Date()) {
        self.store = store
        self.recipeStore = recipeStore
        firstDay = today.startOfDay
        days = Self.run(from: firstDay, length: Self.pageLength)
    }

    public func reload() async {
        do {
            entries = try await store.entries(for: days)

            // Only the recipes these days actually show, fetched once each.
            var resolved: [UUID: Recipe] = [:]
            for id in Set(entries.map(\.recipeID)) {
                resolved[id] = try await recipeStore.recipe(id: id)
            }
            recipes = resolved
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Extends the run further into the future, for scrolling past the end.
    public func loadMore() async {
        days = Self.run(from: firstDay, length: days.count + Self.pageLength)
        await reload()
    }

    /// Makes sure a day is part of the run, so something planned for it can
    /// be seen.
    private func extend(through day: Date) {
        let target = day.startOfDay
        guard target >= firstDay, !days.contains(target) else { return }
        let distance = Calendar.current.dateComponents([.day], from: firstDay, to: target).day ?? 0
        days = Self.run(from: firstDay, length: distance + 1)
    }

    private static func run(from start: Date, length: Int) -> [Date] {
        let calendar = Calendar.current
        return (0..<length).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)?.startOfDay
        }
    }

    /// Entries planned for a day, with their recipe where it still exists,
    /// in the order the meals happen.
    public func plan(for day: Date) -> [(entry: MealPlanEntry, recipe: Recipe?)] {
        entries
            .filter { $0.day == day.startOfDay }
            .sorted {
                $0.slot.order == $1.slot.order
                    ? $0.sortOrder < $1.sortOrder
                    : $0.slot.order < $1.slot.order
            }
            .map { ($0, recipes[$0.recipeID]) }
    }

    /// A day's entries grouped by meal, skipping meals nothing is planned for.
    public func meals(for day: Date) -> [(slot: MealSlot, items: [(entry: MealPlanEntry, recipe: Recipe?)])] {
        let all = plan(for: day)
        return MealSlot.allCases.compactMap { slot in
            let items = all.filter { $0.entry.slot == slot }
            return items.isEmpty ? nil : (slot, items)
        }
    }

    /// Plans a recipe for a day, optionally for a different number of people
    /// than the recipe is written for.
    public func add(
        _ recipe: Recipe,
        to day: Date,
        slot: MealSlot = .dinner,
        servings: Int? = nil
    ) async {
        let entry = MealPlanEntry(
            day: day,
            slot: slot,
            recipeID: recipe.id,
            servings: servings == recipe.servings ? nil : servings,
            sortOrder: plan(for: day).count
        )
        do {
            try await store.save(entry)
            // A day past the end of the run would otherwise be invisible.
            extend(through: day)
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

    /// The recipes planned for a stretch of days, for putting a few days'
    /// worth on the shopping list at once.
    public func plannedRecipes(from start: Date, through end: Date) -> [(recipe: Recipe, servings: Int)] {
        entries
            .filter { $0.day >= start.startOfDay && $0.day <= end.startOfDay }
            .compactMap { entry in
                guard let recipe = recipes[entry.recipeID] else { return nil }
                return (recipe, entry.servings ?? recipe.servings)
            }
    }
}
