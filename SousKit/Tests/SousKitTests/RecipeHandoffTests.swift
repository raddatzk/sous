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

    @Test("An activity without a readable id names no recipe")
    func unreadable() {
        #expect(RecipeHandoff.recipeID(from: nil) == nil)
        #expect(RecipeHandoff.recipeID(from: [:]) == nil)
        #expect(RecipeHandoff.recipeID(from: ["recipeID": "nonsense"]) == nil)
        #expect(RecipeHandoff.recipeID(from: ["recipeID": 42]) == nil)
    }
}
