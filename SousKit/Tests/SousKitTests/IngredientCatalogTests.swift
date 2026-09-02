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
        // A variety is not a spelling: "Cocktailtomaten" resolves to the
        // variety, which knows what it is a variety of.
        #expect(catalog.canonicalName(for: "Cocktailtomaten") == "Cocktailtomate")
        #expect(catalog.groupIngredient(for: "Cocktailtomaten")?.name == "Tomate")
        #expect(catalog.canonicalName(for: "Möhren") == "Karotte")
        #expect(catalog.canonicalName(for: "Eier") == "Ei")
    }

    @Test("A name defined twice appears once, and the first one wins")
    func duplicateNamesAreFolded() {
        let catalog = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Olive", aliases: ["Oliven"], category: .canned),
            CatalogIngredient(name: "olive", aliases: ["Olivchen"], category: .vegetables),
        ])

        // One entry, not two rows reading "Olive" in the catalog browser.
        #expect(catalog.ingredients.count == 1)
        #expect(catalog.category(for: "Olive") == .canned)
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

    // MARK: - Inherited categories

    @Test("A variety without a category takes the nearest ancestor's")
    func categoryComesDownTheChain() throws {
        let catalog = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Pilz", category: .vegetables),
            CatalogIngredient(name: "Champignon", parentName: "Pilz"),
            CatalogIngredient(name: "Brauner Champignon", parentName: "Champignon"),
        ])
        #expect(catalog.category(for: "Champignon") == .vegetables)
        #expect(catalog.category(for: "Brauner Champignon") == .vegetables)
        #expect(catalog.ingredient(for: "Brauner Champignon")?.ownCategory == nil)
        // The index resolves too, not only the list.
        #expect(catalog.ingredient(for: "champignon")?.category == .vegetables)
    }

    @Test("A written category wins over the inherited one, and clearing it falls back")
    func overrideWinsAndClearedFallsBack() {
        let overridden = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Lachs", category: .fish),
            CatalogIngredient(name: "Räucherlachs", category: .meat, parentName: "Lachs"),
        ])
        #expect(overridden.category(for: "Räucherlachs") == .meat)

        let cleared = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Lachs", category: .fish),
            CatalogIngredient(name: "Räucherlachs", parentName: "Lachs"),
        ])
        #expect(cleared.category(for: "Räucherlachs") == .fish)
    }

    @Test("A chain that never writes a category ends in .other, not in a loop")
    func unresolvedChainFallsToOther() {
        let loose = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "A", parentName: "B"),
            CatalogIngredient(name: "B", parentName: "A"),
        ])
        #expect(loose.category(for: "A") == .other)
    }
}
