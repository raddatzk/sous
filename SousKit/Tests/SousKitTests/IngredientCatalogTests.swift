import Foundation
import Testing
@testable import SousKit

@Suite("Ingredient catalog")
struct IngredientCatalogTests {
    private let catalog = IngredientCatalog.bundled

    @Test("The bundled catalog loads")
    func bundledCatalogLoads() {
        #expect(catalog.ingredients.count > 100)
    }

    @Test("Spellings of the same thing resolve to one entry")
    func spellingsResolve() {
        #expect(catalog.canonicalName(for: "Tomaten") == "Tomate")
        #expect(catalog.canonicalName(for: "tomate") == "Tomate")
        #expect(catalog.canonicalName(for: "Cocktailtomaten") == "Tomate")
        #expect(catalog.canonicalName(for: "Möhren") == "Karotte")
        #expect(catalog.canonicalName(for: "Eier") == "Ei")
    }

    @Test("A regular plural is understood even when not listed")
    func pluralFallback() {
        // "Pastinaken" is listed; "Artischocken" resolves through the stem.
        #expect(catalog.canonicalName(for: "Artischocken") == "Artischocke")
        #expect(catalog.canonicalName(for: "Feigen") == "Feige")
    }

    @Test("Unknown ingredients are left as written")
    func unknownStaysAsWritten() {
        #expect(catalog.canonicalName(for: "Rhabarberkompott") == "Rhabarberkompott")
        #expect(catalog.category(for: "Rhabarberkompott") == nil)
    }

    @Test("Ingredients carry the aisle they are found in")
    func categories() {
        #expect(catalog.category(for: "Tomaten") == .vegetables)
        #expect(catalog.category(for: "Zitrone") == .fruit)
        #expect(catalog.category(for: "Basilikum") == .herbs)
        #expect(catalog.category(for: "Kreuzkümmel") == .spices)
        #expect(catalog.category(for: "Walnüsse") == .nuts)
        #expect(catalog.category(for: "Feta") == .dairy)
    }

    @Test("Typing suggests matching ingredients, prefixes first")
    func suggestions() throws {
        let matches = catalog.suggestions(for: "toma")
        #expect(matches.contains { $0.name == "Tomate" })

        let mark = catalog.suggestions(for: "tomatenm")
        #expect(try #require(mark.first).name == "Tomatenmark")

        // Too short to be worth suggesting.
        #expect(catalog.suggestions(for: "t").isEmpty)
    }
}

extension IngredientCatalogTests {
    @Test("The closest match is offered first")
    func suggestionOrder() throws {
        let matches = catalog.suggestions(for: "toma")

        // Tomate before Tomatenmark, and both before things that only match
        // through an alias like "Dosentomaten".
        #expect(try #require(matches.first).name == "Tomate")
        #expect(matches.prefix(2).map(\.name) == ["Tomate", "Tomatenmark"])
    }
}
