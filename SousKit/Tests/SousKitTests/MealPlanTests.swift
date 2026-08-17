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
