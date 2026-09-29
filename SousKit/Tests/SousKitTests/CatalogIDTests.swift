import Foundation
import Testing
@testable import SousKit

/// Catalog ids and what the app does with one that is no longer an entry's
/// (INGREDIENTS-DATA §3 F): a renamed id is read through the map and written
/// anew on the next save; a retired one says so; an unknown one is left
/// alone, because it comes from a newer data version.
@Suite("Catalog ids")
struct CatalogIDTests {
    /// Zwetschge merged into Pflaume, as `compile.py` writes it. The compiler
    /// test `test_the_swift_fixture_is_what_the_merge_compiles_to` keeps the
    /// two equal.
    private static func mergedCatalog() throws -> IngredientCatalog {
        func fixture(_ name: String) throws -> Data {
            let url = try #require(Bundle.module.url(forResource: "Fixtures/Renames/\(name)", withExtension: "json"))
            return try Data(contentsOf: url)
        }
        let words = try JSONDecoder().decode([KitchenWords.Word].self, from: fixture("kitchen_words"))
        let renames = try JSONDecoder().decode(CatalogRenames.self, from: fixture("ids"))
        let table = SynonymTable(kitchen: KitchenWords(words: words), curation: IngredientCuration(words: [:]))
        return IngredientCatalog(ingredients: table.catalogIngredients, renames: renames)
    }

    @Test("A compiled merge reaches a row written with the absorbed id")
    func compiledMergeReachesOldRow() throws {
        let catalog = try Self.mergedCatalog()
        // A household row saved before the merge, holding "zwetschge".
        let storedID = "zwetschge"

        #expect(catalog.ingredient(forID: storedID)?.name == "Pflaume")
        #expect(catalog.resolve(id: storedID) == .renamed(to: try #require(catalog.ingredient(for: "Pflaume"))))
        // Rewritten when the row is saved anyway, not before.
        #expect(catalog.currentID(for: storedID) == "pflaume")
        // The written name still finds the word too, through its new alias.
        #expect(catalog.ingredient(for: "Zwetschgen")?.catalogID == "pflaume")
    }

    @Test("A current id is its own entry and stays as written")
    func currentID() throws {
        let catalog = try Self.mergedCatalog()
        #expect(catalog.resolve(id: "zwiebel") == .current(try #require(catalog.ingredient(for: "Zwiebel"))))
        #expect(catalog.currentID(for: "zwiebel") == "zwiebel")
    }

    @Test("An id from a newer data version waits, untouched")
    func unknownIDWaits() throws {
        let catalog = try Self.mergedCatalog()
        #expect(catalog.resolve(id: "raeuchertofu") == .unknown)
        #expect(catalog.ingredient(forID: "raeuchertofu") == nil)
        #expect(catalog.currentID(for: "raeuchertofu") == "raeuchertofu")
    }

    @Test("A retired id resolves to nothing, and says so")
    func retiredID() {
        let catalog = IngredientCatalog(
            ingredients: [Self.word("Tofu", id: "tofu")],
            renames: CatalogRenames(retired: ["seitan-fertig"])
        )
        #expect(catalog.resolve(id: "seitan-fertig") == .retired)
        #expect(catalog.currentID(for: "seitan-fertig") == "seitan-fertig")
    }

    @Test("A row written two merges ago still arrives")
    func renamesChain() {
        let catalog = IngredientCatalog(
            ingredients: [Self.word("Pflaume", id: "pflaume")],
            renames: CatalogRenames(renamed: ["hauszwetschge": "zwetschge", "zwetschge": "pflaume"])
        )
        #expect(catalog.ingredient(forID: "hauszwetschge")?.name == "Pflaume")
        #expect(catalog.currentID(for: "hauszwetschge") == "pflaume")
    }

    @Test("A rename loop in bad data ends instead of spinning")
    func renameLoop() {
        let catalog = IngredientCatalog(
            ingredients: [Self.word("Pflaume", id: "pflaume")],
            renames: CatalogRenames(renamed: ["a": "b", "b": "a"])
        )
        #expect(catalog.resolve(id: "a") == .unknown)
    }

    @Test("The cook's own word of the same name answers for the shipped id")
    func ownWordTakesTheID() {
        let own = CatalogIngredient(name: "Räuchertofu", category: .other)
        let catalog = IngredientCatalog(ingredients: [own, Self.word("Räuchertofu", id: "raeuchertofu")])
        #expect(catalog.ingredients.count == 1)
        #expect(catalog.ingredient(forID: "raeuchertofu")?.ownCategory == .other)
        #expect(catalog.ingredient(for: "Räuchertofu")?.catalogID == "raeuchertofu")
    }

    private static func word(_ name: String, id: String) -> CatalogIngredient {
        var ingredient = CatalogIngredient(name: name, category: .vegetables)
        ingredient.catalogID = id
        return ingredient
    }
}

@MainActor
@Suite("Catalog ids in the household's catalog")
struct CatalogIDLibraryTests {
    @Test("A shipped word the household patched keeps its id", arguments: StoreBackend.allCases)
    func patchedWordKeepsItsID(_ backend: StoreBackend) async throws {
        let library = IngredientCatalogLibrary(store: try backend.makeVocabularyStore())
        await library.reload()
        await library.setPantry(true, name: "Knoblauch")

        let catalog = library.catalog
        #expect(catalog.ingredient(forID: "knoblauch")?.name == "Knoblauch")
        #expect(catalog.ingredient(for: "Knoblauchzehen")?.catalogID == "knoblauch")
        #expect(catalog.renames == IngredientCatalog.bundled.renames)
    }
}
