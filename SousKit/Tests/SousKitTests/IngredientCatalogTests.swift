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
        // And the source is nameable: what the form says "wie Pilz" from, and
        // the same walk the resolution above took - one authority, not two.
        #expect(catalog.categorySource(for: "Brauner Champignon")?.name == "Pilz")
        #expect(catalog.categorySource(for: "Pilz")?.name == "Pilz")
        #expect(catalog.categorySource(for: "Nichts") == nil)
        // The group is the top of the chain, whatever its depth.
        #expect(catalog.groupIngredient(for: "Brauner Champignon")?.name == "Pilz")
    }

    @Test("A parent named by one of its spellings still hands its category down")
    func parentNamedByAliasResolves() {
        // The resolution used to look parents up by exact name while every
        // other walk went through the spellings, so a hand-edited file naming
        // "Tomaten" as the parent got Sonstiges here and Gemüse everywhere
        // else. One index, one answer.
        let catalog = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Tomate", aliases: ["Tomaten"], category: .vegetables),
            CatalogIngredient(name: "Kirschtomate", parentName: "Tomaten"),
        ])
        #expect(catalog.category(for: "Kirschtomate") == .vegetables)
        #expect(catalog.categorySource(for: "Kirschtomate")?.name == "Tomate")
        #expect(catalog.ancestors(of: "Kirschtomate").map(\.name) == ["Tomate"])
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

    @Test("A Codable round-trip keeps an inheriting variety inheriting")
    func codableKeepsTheWrittenCategory() throws {
        // The resolved category must never be encoded as though it were
        // written: Cocktailtomate would come back frozen to Gemüse, and a later
        // change to Tomate's aisle would no longer reach it.
        let catalog = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Tomate", category: .vegetables),
            CatalogIngredient(name: "Cocktailtomate", parentName: "Tomate"),
        ])
        let resolved = try #require(catalog.ingredient(for: "Cocktailtomate"))
        #expect(resolved.category == .vegetables)

        let data = try JSONEncoder().encode(resolved)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"category\""), "resolved category leaked into the encoding: \(json)")
        let back = try JSONDecoder().decode(CatalogIngredient.self, from: data)
        #expect(back.ownCategory == nil)
        #expect(back.parentName == "Tomate")

        // A written one survives, and an older file that carries only
        // `category` is read as the written one it was.
        let override = try JSONDecoder().decode(
            CatalogIngredient.self,
            from: Data(#"{"name":"Räucherlachs","category":"meat","parentName":"Lachs"}"#.utf8)
        )
        #expect(override.ownCategory == .meat)
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
