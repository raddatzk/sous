import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Meal plan")
struct MealPlanTests {
    private func makeStore() throws -> SwiftDataMealPlanStore {
        SwiftDataMealPlanStore(modelContainer: try .sousContainer(inMemory: true))
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


    @Test("Entries come back for the days they were planned on")
    func storeAndFetch() async throws {
        let store = try makeStore()
        let recipeID = UUID()
        let days = monday.weekDays

        try await store.save(MealPlanEntry(day: days[0], recipeID: recipeID))
        try await store.save(MealPlanEntry(day: days[3], recipeID: recipeID, sortOrder: 0))
        try await store.save(MealPlanEntry(day: days[3], recipeID: UUID(), sortOrder: 1))

        let entries = try await store.entries(for: days)
        #expect(entries.count == 3)
        #expect(entries.map(\.day) == [days[0], days[3], days[3]])
    }

    @Test("Other weeks are left out")
    func weekIsolation() async throws {
        let store = try makeStore()
        let thisWeek = monday.weekDays
        let nextWeek = monday.addingWeeks(1).weekDays

        try await store.save(MealPlanEntry(day: thisWeek[2], recipeID: UUID()))
        try await store.save(MealPlanEntry(day: nextWeek[2], recipeID: UUID()))

        #expect(try await store.entries(for: thisWeek).count == 1)
        #expect(try await store.entries(for: nextWeek).count == 1)
    }

    @Test("Saving twice updates the entry rather than adding one")
    func saveIsIdempotent() async throws {
        let store = try makeStore()
        let days = monday.weekDays
        var entry = MealPlanEntry(day: days[1], recipeID: UUID())

        try await store.save(entry)
        entry.servings = 6
        try await store.save(entry)

        let entries = try await store.entries(for: days)
        #expect(entries.count == 1)
        #expect(entries[0].servings == 6)
    }

    @Test("A removed entry disappears from the plan")
    func deletion() async throws {
        let store = try makeStore()
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
    private func makeLibrary() throws -> (MealPlanLibrary, SwiftDataRecipeStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let recipes = SwiftDataRecipeStore(modelContainer: container)
        let plan = MealPlanLibrary(
            store: SwiftDataMealPlanStore(modelContainer: container),
            recipeStore: recipes
        )
        return (plan, recipes)
    }

@Test("The plan runs from today onwards, and grows when scrolled")
    func continuousRun() async throws {
        let (plan, _) = try makeLibrary()

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

    @Test("A recipe planned for today shows up on today")
    func planningForToday() async throws {
        let (plan, recipes) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2)
        try await recipes.save(recipe)

        await plan.add(recipe, to: Date())

        let today = plan.plan(for: Date())
        #expect(today.map(\.recipe?.title) == ["Salat"])
        // Cooked as written, so no separate serving count is stored.
        #expect(today[0].entry.servings == nil)
    }

    @Test("Planning for a different number of people is remembered")
    func planningWithServings() async throws {
        let (plan, recipes) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2)
        try await recipes.save(recipe)

        await plan.add(recipe, to: Date(), servings: 6)

        #expect(plan.plan(for: Date())[0].entry.servings == 6)
        #expect(plan.plannedRecipes.first?.servings == 6)
    }

    @Test("Planning beyond the end of the run extends it")
    func planningPastTheEnd() async throws {
        let (plan, recipes) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2)
        try await recipes.save(recipe)

        let farOff = try #require(Calendar.current.date(byAdding: .day, value: 40, to: Date()))
        await plan.add(recipe, to: farOff)

        // Otherwise the recipe would sit past the end, invisible.
        #expect(plan.days.contains(farOff.startOfDay))
        #expect(plan.plan(for: farOff).count == 1)
    }

    @Test("A stretch of days can be read on its own, for shopping")
    func plannedRecipesInRange() async throws {
        let (plan, recipes) = try makeLibrary()
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
}
