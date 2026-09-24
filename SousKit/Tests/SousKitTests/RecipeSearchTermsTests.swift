import Testing
@testable import SousKit

@Suite("Recipe search terms")
struct RecipeSearchTermsTests {
    @Test("Words are split, lowercased and stripped of accents")
    func words() {
        #expect(RecipeSearchTerms("  Kürbis   Suppe ").words == ["kurbis", "suppe"])
        #expect(RecipeSearchTerms("   ").isEmpty)
    }

    @Test("The recipe called what was typed comes before the ones mentioning it")
    func ranking() {
        let recipes = [
            "Gefüllte Paprika", "Linsen-Dal", "Pani Pol", "Spaghetti Carbonara",
        ].map { Recipe(title: $0) }

        // Store order is alphabetical; the ranking keeps it within a rung.
        let ranked = RecipeSearchTerms("pa").ranked(recipes).map(\.title)
        #expect(ranked == ["Pani Pol", "Gefüllte Paprika", "Spaghetti Carbonara", "Linsen-Dal"])
    }

    @Test("A title word starting with each typed word ranks as close")
    func wordPrefixes() {
        let terms = RecipeSearchTerms("hahn papr")
        #expect(terms.rank(ofTitle: "Paprika-Hähnchen") == 1)
        #expect(RecipeSearchTerms("paprika hä").rank(ofTitle: "Paprika-Hähnchen") == 1)
        #expect(RecipeSearchTerms("paprika-hä").rank(ofTitle: "Paprika-Hähnchen") == 0)
        #expect(terms.rank(ofTitle: "Linsen-Dal") == 3)
    }

    @Test("No words leaves the order alone")
    func emptyKeepsOrder() {
        let recipes = ["B", "A"].map { Recipe(title: $0) }
        #expect(RecipeSearchTerms("").ranked(recipes).map(\.title) == ["B", "A"])
    }
}
