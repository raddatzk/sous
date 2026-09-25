import Foundation
import Testing
@testable import SousKit

@Suite("Recipe handoff")
struct RecipeHandoffTests {
    @Test("A recipe id round-trips through the activity's user info")
    func roundTrip() {
        let id = UUID()

        #expect(RecipeHandoff.recipeID(from: RecipeHandoff.userInfo(for: id)) == id)
    }

    @Test("The household travels along, and an older activity names none")
    func household() {
        let id = UUID()
        let household = UUID()

        #expect(RecipeHandoff.householdID(from: RecipeHandoff.userInfo(for: id, household: household)) == household)
        #expect(RecipeHandoff.recipeID(from: RecipeHandoff.userInfo(for: id, household: household)) == id)
        #expect(RecipeHandoff.householdID(from: RecipeHandoff.userInfo(for: id)) == nil)
    }

    @Test("An activity without a readable id names no recipe")
    func unreadable() {
        #expect(RecipeHandoff.recipeID(from: nil) == nil)
        #expect(RecipeHandoff.recipeID(from: [:]) == nil)
        #expect(RecipeHandoff.recipeID(from: ["recipeID": "nonsense"]) == nil)
        #expect(RecipeHandoff.recipeID(from: ["recipeID": 42]) == nil)
    }
}
