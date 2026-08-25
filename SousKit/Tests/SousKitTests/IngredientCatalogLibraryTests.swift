import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Own ingredients")
struct IngredientCatalogLibraryTests {
    private func makeLibrary() throws -> IngredientCatalogLibrary {
        let container = try ModelContainer.sousContainer(inMemory: true)
        return IngredientCatalogLibrary(
            store: SwiftDataIngredientCatalogStore(modelContainer: container),
            aliasStore: SwiftDataIngredientAliasOverrideStore(modelContainer: container)
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

    @Test("A spelling taught to a bundled entry resolves to it")
    func aliasOverrideOnABundledEntry() async throws {
        let library = try makeLibrary()
        await library.reload()
        let tomato = try #require(library.catalog.ingredient(for: "Tomate"))
        #expect(library.catalog.ingredient(for: "Ochsenherz") == nil)

        await library.addAlias("Ochsenherz", to: tomato)

        #expect(library.catalog.canonicalName(for: "Ochsenherz") == "Tomate")
        // The bundled entry itself is untouched — only the merged view of it
        // carries the extra spelling.
        #expect(IngredientCatalog.bundled.ingredient(for: "Ochsenherz") == nil)
        #expect(library.ownAliases(of: tomato) == ["Ochsenherz"])
    }

    @Test("A spelling taught to an own entry resolves to it too")
    func aliasOverrideOnAnOwnEntry() async throws {
        let library = try makeLibrary()
        await library.save(CatalogIngredient(name: "Gochujang", category: .canned))
        let own = try #require(library.catalog.ingredient(for: "Gochujang"))

        await library.addAlias("Gochu-Paste", to: own)

        #expect(library.catalog.canonicalName(for: "Gochu-Paste") == "Gochujang")
    }

    @Test("A taught spelling can be taken back")
    func aliasOverrideIsRemovable() async throws {
        let library = try makeLibrary()
        await library.reload()
        let tomato = try #require(library.catalog.ingredient(for: "Tomate"))

        await library.addAlias("Ochsenherz", to: tomato)
        await library.removeAlias("Ochsenherz", from: tomato)

        #expect(library.catalog.ingredient(for: "Ochsenherz") == nil)
    }

    @Test("An own entry shadowing an override's target keeps both intact")
    func ownEntryShadowsAnOverriddenBundledOne() async throws {
        let library = try makeLibrary()
        await library.reload()
        let bundled = try #require(library.catalog.ingredient(for: "Olive"))
        await library.addAlias("Kalamata", to: bundled)

        // Now the cook defines "Olive" themselves. The override was written
        // against the key, so it lands on whichever entry now answers to it.
        await library.save(CatalogIngredient(name: "Olive", category: .canned))

        #expect(library.catalog.canonicalName(for: "Kalamata") == "Olive")
        #expect(library.catalog.category(for: "Kalamata") == .canned)
        #expect(library.catalog.ingredients.filter { $0.key == "olive" }.count == 1)
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
