import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Own ingredients")
struct IngredientCatalogLibraryTests {
    private func makeLibrary() throws -> IngredientCatalogLibrary {
        IngredientCatalogLibrary(
            store: SwiftDataIngredientCatalogStore(modelContainer: try .sousContainer(inMemory: true))
        )
    }

    @Test("An added ingredient becomes part of the catalog")
    func addingAnIngredient() async throws {
        let library = try makeLibrary()
        await library.reload()
        #expect(library.catalog.ingredient(for: "Gochujang") == nil)

        await library.save(CatalogIngredient(
            name: "Gochujang",
            aliases: ["Gochu"],
            category: .canned
        ))

        #expect(library.catalog.canonicalName(for: "gochu") == "Gochujang")
        #expect(library.catalog.category(for: "Gochujang") == .canned)
        #expect(library.ownIngredients.map(\.name) == ["Gochujang"])
    }

    @Test("An own entry overrides the bundled one of the same name")
    func ownEntryWins() async throws {
        let library = try makeLibrary()
        // Bundled: Olive is a vegetable. Someone may disagree.
        await library.save(CatalogIngredient(name: "Olive", aliases: ["Oliven"], category: .canned))

        #expect(library.catalog.category(for: "Oliven") == .canned)
    }

    @Test("Only own entries can be edited or removed")
    func ownershipIsVisible() async throws {
        let library = try makeLibrary()
        await library.save(CatalogIngredient(name: "Gochujang", category: .canned))

        let own = try #require(library.catalog.ingredient(for: "Gochujang"))
        let bundled = try #require(library.catalog.ingredient(for: "Tomate"))
        #expect(library.isOwn(own))
        #expect(!library.isOwn(bundled))

        await library.delete(own)
        #expect(library.catalog.ingredient(for: "Gochujang") == nil)
    }

    @Test("A recipe's unknown ingredients are found, links and knowns skipped")
    func unknownIngredients() async throws {
        let library = try makeLibrary()
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
}
