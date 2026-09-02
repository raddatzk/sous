import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Own ingredients")
struct IngredientCatalogLibraryTests {
    private func makeLibrary(_ backend: StoreBackend) throws -> IngredientCatalogLibrary {
        IngredientCatalogLibrary(store: try backend.makeVocabularyStore())
    }

    @Test("An added ingredient becomes part of the catalog", arguments: StoreBackend.allCases)
    func addingAnIngredient(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
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

    @Test("An own entry overrides the bundled one of the same name", arguments: StoreBackend.allCases)
    func ownEntryWins(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        // Bundled: Olive is a vegetable. Someone may disagree.
        await library.save(CatalogIngredient(name: "Olive", aliases: ["Oliven"], category: .canned))

        #expect(library.catalog.category(for: "Oliven") == .canned)
    }

    @Test("Only own entries can be edited or removed", arguments: StoreBackend.allCases)
    func ownershipIsVisible(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.save(CatalogIngredient(name: "Gochujang", category: .canned))

        let own = try #require(library.catalog.ingredient(for: "Gochujang"))
        let bundled = try #require(library.catalog.ingredient(for: "Tomate"))
        #expect(library.isOwn(own))
        #expect(!library.isOwn(bundled))

        await library.delete(own)
        #expect(library.catalog.ingredient(for: "Gochujang") == nil)
    }

    @Test("A spelling taught to a bundled entry resolves to it", arguments: StoreBackend.allCases)
    func aliasOverrideOnABundledEntry(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
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

    @Test("A spelling taught to an own entry resolves to it too", arguments: StoreBackend.allCases)
    func aliasOverrideOnAnOwnEntry(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.save(CatalogIngredient(name: "Gochujang", category: .canned))
        let own = try #require(library.catalog.ingredient(for: "Gochujang"))

        await library.addAlias("Gochu-Paste", to: own)

        #expect(library.catalog.canonicalName(for: "Gochu-Paste") == "Gochujang")
    }

    @Test("A taught spelling can be taken back", arguments: StoreBackend.allCases)
    func aliasOverrideIsRemovable(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.reload()
        let tomato = try #require(library.catalog.ingredient(for: "Tomate"))

        await library.addAlias("Ochsenherz", to: tomato)
        await library.removeAlias("Ochsenherz", from: tomato)

        #expect(library.catalog.ingredient(for: "Ochsenherz") == nil)
    }

    @Test("Taking over a bundled entry keeps the spelling taught to it", arguments: StoreBackend.allCases)
    func ownEntryShadowsAnOverriddenBundledOne(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.reload()
        let bundled = try #require(library.catalog.ingredient(for: "Olive"))
        await library.addAlias("Kalamata", to: bundled)

        // Now the cook defines "Olive" themselves — from the entry as it
        // stands, which is what the form hands back. Spelling and entry live
        // in one vocabulary row now, so taking the entry over must not
        // quietly drop what was taught to it.
        let taught = try #require(library.catalog.ingredient(for: "Olive"))
        #expect(taught.aliases.contains("Kalamata"))
        var own = taught
        // The *written* category is what a save stores; the resolved one is
        // read-only and follows from it.
        own.ownCategory = .canned
        await library.save(own)

        #expect(library.catalog.canonicalName(for: "Kalamata") == "Olive")
        #expect(library.catalog.category(for: "Kalamata") == .canned)
        #expect(library.catalog.ingredients.filter { $0.key == "olive" }.count == 1)
    }

    @Test("Filing a parent under its own variety is refused and reported", arguments: StoreBackend.allCases)
    func cyclicParentIsRefused(_ backend: StoreBackend) async throws {
        let library = try makeLibrary(backend)
        await library.reload()
        await library.save(CatalogIngredient(name: "Kirschtomate", category: .vegetables, parentName: "Tomate"))
        #expect(library.catalog.ingredient(for: "Kirschtomate")?.parentName == "Tomate")

        await library.setParent("Kirschtomate", of: "Tomate")

        // Refused loudly - the library surfaces what the store threw - and
        // refused whole: Tomate is not a variety of anything afterwards.
        #expect(library.errorMessage?.isEmpty == false)
        #expect(library.catalog.ingredient(for: "Tomate")?.parentName == nil)
        #expect(library.catalog.ancestors(of: "Kirschtomate").map(\.name) == ["Tomate"])
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
}
