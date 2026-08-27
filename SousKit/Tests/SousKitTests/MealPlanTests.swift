import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Meal plan")
struct MealPlanTests {
    private func makeStore(_ backend: StoreBackend) throws -> any MealPlanStore {
        try backend.makeMealPlanStore()
    }

    private var monday: Date {
        Date(timeIntervalSince1970: 1_755_734_400).startOfDay
    }

    @Test("A day is stored as a date, not a moment")
    func daysAreNormalized() {
        let morning = Date(timeIntervalSince1970: 1_755_756_000)
        let evening = Date(timeIntervalSince1970: 1_755_799_000)

        let first = MealPlanEntry(day: morning, recipeID: UUID())
        let second = MealPlanEntry(day: evening, recipeID: UUID())

        #expect(first.day == second.day)
    }

    @Test("A week has seven consecutive days")
    func weekDays() {
        let days = monday.weekDays

        #expect(days.count == 7)
        #expect(days == days.sorted())
        #expect(Calendar.current.dateComponents([.day], from: days[0], to: days[6]).day == 6)
    }


    @Test("Entries come back for the days they were planned on", arguments: StoreBackend.allCases)
    func storeAndFetch(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let recipeID = UUID()
        let days = monday.weekDays

        try await store.save(MealPlanEntry(day: days[0], recipeID: recipeID))
        try await store.save(MealPlanEntry(day: days[3], recipeID: recipeID, sortOrder: 0))
        try await store.save(MealPlanEntry(day: days[3], recipeID: UUID(), sortOrder: 1))

        let entries = try await store.entries(for: days)
        #expect(entries.count == 3)
        #expect(entries.map(\.day) == [days[0], days[3], days[3]])
    }

    @Test("Other weeks are left out", arguments: StoreBackend.allCases)
    func weekIsolation(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let thisWeek = monday.weekDays
        let nextWeek = monday.addingWeeks(1).weekDays

        try await store.save(MealPlanEntry(day: thisWeek[2], recipeID: UUID()))
        try await store.save(MealPlanEntry(day: nextWeek[2], recipeID: UUID()))

        #expect(try await store.entries(for: thisWeek).count == 1)
        #expect(try await store.entries(for: nextWeek).count == 1)
    }

    @Test("Saving twice updates the entry rather than adding one", arguments: StoreBackend.allCases)
    func saveIsIdempotent(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let days = monday.weekDays
        var entry = MealPlanEntry(day: days[1], recipeID: UUID())

        try await store.save(entry)
        entry.servings = 6
        try await store.save(entry)

        let entries = try await store.entries(for: days)
        #expect(entries.count == 1)
        #expect(entries[0].servings == 6)
    }

    @Test("A removed entry disappears from the plan", arguments: StoreBackend.allCases)
    func deletion(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let days = monday.weekDays
        let entry = MealPlanEntry(day: days[4], recipeID: UUID())

        try await store.save(entry)
        try await store.delete(id: entry.id)

        #expect(try await store.entries(for: days).isEmpty)
    }
}

@MainActor
@Suite("Planning from a recipe")
struct MealPlanLibraryTests {
    private func makeLibrary(_ backend: StoreBackend) throws -> (MealPlanLibrary, any RecipeStore) {
        let stores = try backend.makeStores()
        let plan = MealPlanLibrary(store: stores.mealPlan, recipeStore: stores.recipes)
        return (plan, stores.recipes)
    }

@Test("The plan runs from today onwards, and grows when scrolled", arguments: StoreBackend.allCases)
    func continuousRun(_ backend: StoreBackend) async throws {
        let (plan, _) = try makeLibrary(backend)

        #expect(plan.days.first == Date().startOfDay)
        #expect(plan.days.count == 28)
        #expect(plan.days == plan.days.sorted())

        await plan.loadMore()
        #expect(plan.days.count == 56)
        // Still one unbroken run, no gaps.
        #expect(Calendar.current.dateComponents(
            [.day], from: plan.days[0], to: plan.days[55]
        ).day == 55)
    }

    @Test("A recipe planned for today shows up on today", arguments: StoreBackend.allCases)
    func planningForToday(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2)
        try await recipes.save(recipe)

        await plan.add(recipe, to: Date())

        let today = plan.plan(for: Date())
        #expect(today.map(\.recipe?.title) == ["Salat"])
        // Cooked as written, so no separate serving count is stored.
        #expect(today[0].entry.servings == nil)
    }

    @Test("Planning for a different number of people is remembered", arguments: StoreBackend.allCases)
    func planningWithServings(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2)
        try await recipes.save(recipe)

        await plan.add(recipe, to: Date(), servings: 6)

        #expect(plan.plan(for: Date())[0].entry.servings == 6)
        #expect(plan.plannedRecipes.first?.servings == 6)
    }

    @Test("Servings on an already-planned meal can be changed, without duplicating it", arguments: StoreBackend.allCases)
    func changingServings(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2)
        try await recipes.save(recipe)

        await plan.add(recipe, to: Date())
        let entry = try #require(plan.plan(for: Date()).first?.entry)

        await plan.setServings(entry, to: 4, for: recipe)

        let updated = try #require(plan.plan(for: Date()).first)
        #expect(updated.entry.id == entry.id)
        #expect(updated.entry.servings == 4)

        // Back to how the recipe is written, so nothing overrides it.
        await plan.setServings(updated.entry, to: 2, for: recipe)
        #expect(plan.plan(for: Date()).first?.entry.servings == nil)
    }

    @Test("Planning beyond the end of the run extends it", arguments: StoreBackend.allCases)
    func planningPastTheEnd(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2)
        try await recipes.save(recipe)

        let farOff = try #require(Calendar.current.date(byAdding: .day, value: 40, to: Date()))
        await plan.add(recipe, to: farOff)

        // Otherwise the recipe would sit past the end, invisible.
        #expect(plan.days.contains(farOff.startOfDay))
        #expect(plan.plan(for: farOff).count == 1)
    }

    @Test("A stretch of days can be read on its own, for shopping", arguments: StoreBackend.allCases)
    func plannedRecipesInRange(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let today = Recipe(title: "Heute", servings: 2)
        let later = Recipe(title: "Später", servings: 2)
        try await recipes.save(today)
        try await recipes.save(later)

        let inThreeDays = try #require(Calendar.current.date(byAdding: .day, value: 3, to: Date()))
        await plan.add(today, to: Date())
        await plan.add(later, to: inThreeDays)

        let nextTwoDays = try #require(Calendar.current.date(byAdding: .day, value: 1, to: Date()))
        #expect(plan.plannedRecipes(from: Date(), through: nextTwoDays).map(\.recipe.title) == ["Heute"])
        #expect(plan.plannedRecipes(from: Date(), through: inThreeDays).count == 2)
    }

    @Test("An accepted proposal is written in one go: pool meals move, new picks appear", arguments: StoreBackend.allCases)
    func applyingAProposal(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let pooled = Recipe(title: "Vorgemerkt", servings: 2)
        let fresh = Recipe(title: "Neu", servings: 2)
        let undated = Recipe(title: "In die Sammlung", servings: 2)
        for recipe in [pooled, fresh, undated] { try await recipes.save(recipe) }

        await plan.add(pooled, to: nil, servings: 6)
        let entry = try #require(plan.pool.first)
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: Date()))

        await plan.apply([
            (day: Date(), kind: .seatPoolEntry(entry)),
            (day: tomorrow, kind: .addRecipe(fresh)),
            (day: nil, kind: .addRecipe(undated)),
        ])

        // The pool meal kept its identity and its six servings on the move.
        let seated = try #require(plan.plan(for: Date()).first)
        #expect(seated.entry.id == entry.id)
        #expect(seated.entry.servings == 6)
        #expect(seated.entry.slot == .dinner)
        #expect(plan.plan(for: tomorrow).map(\.recipe?.title) == ["Neu"])
        // The seated entry left the pool; the undated pick arrived in it.
        #expect(plan.pool.map(\.recipeID) == [undated.id])
    }
}

@MainActor
@Suite("Meals of the day")
struct MealSlotTests {
    private func makeLibrary(_ backend: StoreBackend) throws -> (MealPlanLibrary, any RecipeStore) {
        let stores = try backend.makeStores()
        let plan = MealPlanLibrary(store: stores.mealPlan, recipeStore: stores.recipes)
        return (plan, stores.recipes)
    }

    @Test("A day's entries come back in the order the meals happen", arguments: StoreBackend.allCases)
    func mealsAreOrdered(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let porridge = Recipe(title: "Porridge", servings: 1)
        let soup = Recipe(title: "Suppe", servings: 2)
        try await recipes.save(porridge)
        try await recipes.save(soup)

        // Planned dinner first, breakfast second.
        await plan.add(soup, to: Date(), slot: .dinner)
        await plan.add(porridge, to: Date(), slot: .breakfast)

        #expect(plan.plan(for: Date()).map(\.recipe?.title) == ["Porridge", "Suppe"])
    }

    @Test("Meals with nothing planned are left out", arguments: StoreBackend.allCases)
    func emptyMealsAreSkipped(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let soup = Recipe(title: "Suppe", servings: 2)
        try await recipes.save(soup)

        await plan.add(soup, to: Date(), slot: .lunch)

        let meals = plan.meals(for: Date())
        #expect(meals.map(\.slot) == [.lunch])
        #expect(meals[0].items.map(\.recipe?.title) == ["Suppe"])
    }

    @Test("Dinner is what a recipe is planned for unless said otherwise", arguments: StoreBackend.allCases)
    func dinnerByDefault(_ backend: StoreBackend) async throws {
        let (plan, recipes) = try makeLibrary(backend)
        let soup = Recipe(title: "Suppe", servings: 2)
        try await recipes.save(soup)

        await plan.add(soup, to: Date())
        #expect(plan.plan(for: Date())[0].entry.slot == .dinner)
    }
}

@MainActor
@Suite("The undated pool")
struct MealPlanPoolTests {
    private func makeLibrary(_ backend: StoreBackend) throws -> (MealPlanLibrary, any RecipeStore) {
        let stores = try backend.makeStores()
        let library = MealPlanLibrary(store: stores.mealPlan, recipeStore: stores.recipes)
        return (library, stores.recipes)
    }

    private func saved(_ title: String, in store: any RecipeStore) async throws -> Recipe {
        try await store.save(Recipe(title: title, servings: 2, ingredientsText: "200 g Linsen"))
    }

    @Test("A recipe planned without a day lands in the pool, not on the calendar", arguments: StoreBackend.allCases)
    func addToPool(_ backend: StoreBackend) async throws {
        let (library, recipes) = try makeLibrary(backend)
        let recipe = try await saved("Linsensuppe", in: recipes)

        await library.add(recipe, to: nil)

        #expect(library.pool.count == 1)
        #expect(library.pool.first?.isInPool == true)
        #expect(library.entries.isEmpty)
        #expect(library.pooledMeals.first?.recipe?.title == "Linsensuppe")
    }

    @Test("A pool entry moves onto a day and keeps what was planned with it", arguments: StoreBackend.allCases)
    func moveOntoDay(_ backend: StoreBackend) async throws {
        let (library, recipes) = try makeLibrary(backend)
        let recipe = try await saved("Linsensuppe", in: recipes)
        await library.add(recipe, to: nil, servings: 6)
        let entry = try #require(library.pool.first)

        let today = try #require(library.days.first)
        await library.move(entry, to: today, slot: .lunch)

        #expect(library.pool.isEmpty)
        let planned = try #require(library.plan(for: today).first)
        // The same entry, not a fresh one: six people are still coming.
        #expect(planned.entry.id == entry.id)
        #expect(planned.entry.servings == 6)
        #expect(planned.entry.slot == .lunch)
    }

    @Test("A meal can be taken off its day and left loose", arguments: StoreBackend.allCases)
    func moveIntoPool(_ backend: StoreBackend) async throws {
        let (library, recipes) = try makeLibrary(backend)
        let recipe = try await saved("Linsensuppe", in: recipes)
        let today = try #require(library.days.first)
        await library.add(recipe, to: today)
        let entry = try #require(library.entries.first)

        await library.move(entry, to: nil)

        #expect(library.entries.isEmpty)
        #expect(library.pool.map(\.id) == [entry.id])
    }

    @Test("The shopping list can take the pool as it is", arguments: StoreBackend.allCases)
    func shoppingFromPool(_ backend: StoreBackend) async throws {
        let (library, recipes) = try makeLibrary(backend)
        await library.add(try await saved("Linsensuppe", in: recipes), to: nil, servings: 4)
        await library.add(try await saved("Rührei", in: recipes), to: nil)

        let planned = library.pooledRecipes
        #expect(planned.count == 2)
        #expect(planned.first { $0.recipe.title == "Linsensuppe" }?.servings == 4)
        // A day range never reaches the pool, however wide it is.
        #expect(library.plannedRecipes(from: .distantPast, through: .distantFuture).isEmpty)
    }
}
