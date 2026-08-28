import Foundation
import Testing
@testable import SousKit

@Suite("The meal plan as calendar events")
struct MealPlanCalendarPlannerTests {
    private let monday = Date(timeIntervalSince1970: 1_755_734_400).startOfDay

    @Test("A dinner becomes an hour at seven, named after the recipe")
    func mapsSlotToMealtime() throws {
        let entry = MealPlanEntry(day: monday, slot: .dinner, recipeID: UUID(), servings: 4)
        let event = try #require(MealPlanCalendarPlanner.event(for: entry, recipeTitle: "Linsensuppe"))

        #expect(event.title == "Linsensuppe")
        let calendar = Calendar.current
        #expect(calendar.component(.hour, from: event.start) == 19)
        #expect(event.end.timeIntervalSince(event.start) == 3600)
        #expect(event.notes == "4 Portionen · Geplant mit Sous")
    }

    @Test("The event names its entry, and the id survives the round trip")
    func urlCarriesTheEntryID() throws {
        let entry = MealPlanEntry(day: monday, slot: .lunch, recipeID: UUID())
        let event = try #require(MealPlanCalendarPlanner.event(for: entry, recipeTitle: "Bowl"))

        // The URL is the only tie between event and entry: titles get
        // renamed and times get moved, ids do neither.
        #expect(MealPlanCalendarPlanner.entryID(of: event.url) == entry.id)
        #expect(MealPlanCalendarPlanner.entryID(of: URL(string: "https://example.com")) == nil)
    }

    @Test("Pool entries and unknown recipes make no event")
    func skipsWhatCannotBeShown() {
        let pool = MealPlanEntry(day: nil, slot: .dinner, recipeID: UUID())
        #expect(MealPlanCalendarPlanner.event(for: pool, recipeTitle: "Brot") == nil)

        // A plan pointing at a recipe the import has not delivered yet is a
        // gap for the next pass — not an event called nothing.
        let dated = MealPlanEntry(day: monday, slot: .dinner, recipeID: UUID())
        #expect(MealPlanCalendarPlanner.event(for: dated, recipeTitle: nil) == nil)
    }
}
