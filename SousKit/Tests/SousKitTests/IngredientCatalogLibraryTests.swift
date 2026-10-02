import Foundation
import SwiftData
import Testing
@testable import SousKit

/// The household's catalog since phase 6b: the data set's words, the local
/// answers over them, and pantry, store and note beside them. Nothing the
/// household says changes what an ingredient *is* (INGREDIENTS-DATA §3 A–C).
@MainActor
@Suite("Household catalog")
struct IngredientCatalogLibraryTests {
    private func makeLibrary(_ backend: StoreBackend) throws -> IngredientCatalogLibrary {
        try backend.makeCatalogLibrary()
    }

    @Test("A recipe's unknown ingredients are found, links and knowns skipped", arguments: StoreBackend.allCases)
    func unknownIngredients(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.reload()

        let unknown = library.unknownIngredients(in: """
        300 g Tomaten
        2 EL Gochujang
        1 Portion \(RecipeLink.markdown(title: "Naan", id: UUID()))
        1 TL Sumach
        2 EL Gochujang
        """)

        // Tomaten is known, the link is a recipe, and the repeat is folded.
        #expect(unknown == ["Gochujang", "Sumach"])
    }

    @Test("Household fields leave the shipped word whole, alias units included",
          arguments: StoreBackend.allCases)
    func householdFieldsLeaveTheWordWhole(_ backend: StoreBackend) async throws {
        // Until 6b a pantry flag made a vocabulary row that was laid over the
        // shipped word, and the patch once dropped its alias units: "2
        // Knoblauchzehen" read as two bulbs in exactly the households that
        // cared about garlic. Household fields are beside the word now.
        let library = try makeLibrary(backend)
        await library.reload()
        await library.setPantry(true, name: "Knoblauch")
        await library.setShoppingPreferences(store: "Markt", note: "die violette", name: "Knoblauch")

        #expect(library.catalog.reading(Quantity(2, .piece), for: "Knoblauchzehen").unit == .clove)
        #expect(library.catalog.ingredient(for: "Knoblauch") == IngredientCatalog.current.ingredient(for: "Knoblauch"))
        let entry = try #require(library.householdIngredient(for: "Knoblauchzehen"))
        #expect(entry.isPantry)
        #expect(entry.preferredStore == "Markt")
        #expect(entry.shoppingNote == "die violette")
    }

    @Test("A row with nothing left to say is deleted, and survives a reload otherwise",
          arguments: StoreBackend.allCases)
    func emptyRowsGo(_ backend: StoreBackend) async throws {
        let stores = try backend.makeStores()
        let library = IngredientCatalogLibrary(localAnswers: stores.localAnswers, household: stores.household)
        await library.reload()
        await library.setPantry(true, name: "Mehl")
        await library.setShoppingPreferences(store: "  ", note: nil, name: "Mehl")

        let reread = IngredientCatalogLibrary(localAnswers: stores.localAnswers, household: stores.household)
        await reread.reload()
        #expect(reread.householdIngredient(for: "Mehl")?.isPantry == true)
        #expect(reread.householdIngredient(for: "Mehl")?.preferredStore == nil)

        await reread.setPantry(false, name: "Mehl")
        #expect(reread.householdIngredient(for: "Mehl") == nil)
        #expect(try await stores.household.entries().isEmpty)
    }

    @Test("A name counted as Tofu keeps its own household row (R2)", arguments: StoreBackend.allCases)
    func countedNameHasItsOwnRow(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.reload()
        let tofu = try #require(library.catalog.ingredient(for: "Tofu"))
        #expect(await library.count("Rauchtofu", as: tofu))
        await library.setPantry(true, name: "Tofu")
        await library.setShoppingPreferences(store: "Bioladen", note: nil, name: "Tofu")

        #expect(library.householdIngredient(for: "Rauchtofu") == nil)
        await library.setPantry(true, name: "Rauchtofu")
        #expect(library.householdIngredient(for: "Rauchtofu")?.key == "name:rauchtofu")
        #expect(library.householdIngredient(for: "Rauchtofu")?.preferredStore == nil)
    }

    @Test("Only an answer that adds or takes back a word asks for a reindex", arguments: StoreBackend.allCases)
    func wordsDidChangeOnlyForWords(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        var calls = 0
        library.wordsDidChange = { calls += 1 }
        await library.reload()
        #expect(calls == 0)

        // A weight for a word the catalog knows adds no word.
        await library.setLocalWeight(180, unit: .piece, of: "Zwiebel")
        #expect(calls == 0)

        let tofu = try #require(library.catalog.ingredient(for: "Tofu"))
        await library.count("Rauchtofu", as: tofu)
        #expect(calls == 1)

        // A pantry flag is no word either.
        await library.setPantry(true, name: "Rauchtofu")
        #expect(calls == 1)

        let answer = try #require(library.localAnswer(for: "Rauchtofu"))
        await library.deleteLocalAnswer(answer)
        #expect(calls == 2)
    }

    @Test("Emptying a household takes its answers and rows, and leaves the catalog", arguments: StoreBackend.allCases)
    func removeHouseholdAnswers(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.reload()
        let tofu = try #require(library.catalog.ingredient(for: "Tofu"))
        await library.count("Rauchtofu", as: tofu)
        await library.setPantry(true, name: "Mehl")
        #expect(library.householdRowCount == 2)

        await library.removeHouseholdAnswers()

        #expect(library.householdRowCount == 0)
        #expect(library.catalog.ingredient(for: "Rauchtofu") == nil)
        #expect(library.catalog.ingredient(for: "Tofu") != nil)
    }

    @Test("A local weight is an own weight of the name's answer, and goes when taken back",
          arguments: StoreBackend.allCases)
    func localWeight(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.reload()

        await library.setLocalWeight(180, unit: .piece, of: "Zwiebeln")
        let answer = try #require(library.localAnswer(for: "Zwiebel"))
        #expect(answer.catalogID == library.catalog.ingredient(for: "Zwiebel")?.catalogID)
        #expect(answer.weights["Stk."]?.grams == 180)

        await library.setLocalWeight(nil, unit: .piece, of: "Zwiebel")
        #expect(library.localAnswer(for: "Zwiebel") == nil)
    }
}
