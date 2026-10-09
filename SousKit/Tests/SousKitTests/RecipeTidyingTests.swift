import Foundation
import Testing
@testable import SousKit

@Suite("Tidying an edited recipe")
struct RecipeTidyingTests {
    private struct Backend: RecipeOptimizationBackend {
        let reply: String?
        func answer(to prompt: String) async throws -> String {
            guard let reply else {
                Issue.record("The backend was asked, but the recipe was in form already.")
                return ""
            }
            return reply
        }
    }

    @Test("A recipe whose lines are in form and without steps is left alone, and nobody is asked")
    func alreadyInForm() async throws {
        let recipe = Recipe(title: "Linsen", servings: 2, ingredientsText: "250 g rote Linsen\n1 Zwiebel")
        #expect(recipe.isOptimizedForSous)
        let result = try await RecipeTidier.tidy(recipe, backend: Backend(reply: nil))
        #expect(result == nil)
    }

    @Test("A recipe outside the form is sent to the optimizer, and an unreadable answer comes back as a failure")
    func outsideForm() async throws {
        let recipe = Recipe(
            title: "Suppe", servings: 2,
            ingredientsText: "ein bisschen Mehl, nach Gefühl\netwas Öl",
            instructionsText: "Alles verrühren.")
        #expect(!recipe.isOptimizedForSous)
        let result = try #require(try await RecipeTidier.tidy(recipe, backend: Backend(reply: "Gerne, hier ist das Rezept.")))
        guard case .failure = result else {
            Issue.record("A reply without an answer must not tidy anything.")
            return
        }
    }
}
