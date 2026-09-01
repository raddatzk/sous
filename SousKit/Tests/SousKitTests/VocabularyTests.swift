import Foundation
import SwiftData
import Testing
@testable import SousKit

/// The store's own rules: identity, the one-level variant relation, and the
/// silent sweep of an entry that no longer says anything.
@Suite("The vocabulary store")
struct VocabularyStoreTests {
    private func store() throws -> SwiftDataVocabularyStore {
        SwiftDataVocabularyStore(modelContainer: try .sousContainer(inMemory: true))
    }

    @Test("A variety names its parent, which comes into being with the relation")
    func parentIsCreatedOnDemand() async throws {
        let store = try store()

        _ = try await store.save(IngredientVocabularyEntry(
            name: "Ochsenherztomate", parentName: "Tomate", isOwnIngredient: true
        ))

        let entries = try await store.entries()
        let child = try #require(entries.first { $0.key == "ochsenherztomate" })
        #expect(child.parentName == "Tomate")
        // Saying "this is a variety of Tomate" is itself something the cook
        // has said about Tomate, so Tomate is part of the vocabulary now.
        #expect(entries.contains { $0.key == "tomate" })
    }

    @Test("The relation stays one level deep")
    func noVarietyOfAVariety() async throws {
        let store = try store()
        _ = try await store.save(IngredientVocabularyEntry(
            name: "Kirschtomate", parentName: "Tomate", isOwnIngredient: true
        ))

        _ = try await store.save(IngredientVocabularyEntry(
            name: "Gelbe Kirschtomate", parentName: "Kirschtomate", isOwnIngredient: true
        ))

        let entries = try await store.entries()
        let grandchild = try #require(entries.first { $0.key == "gelbe kirschtomate" })
        #expect(grandchild.parentName == nil)
    }

    @Test("An entry that no longer says anything is swept")
    func emptyEntriesAreRemoved() async throws {
        let store = try store()
        _ = try await store.save(IngredientVocabularyEntry(name: "Tomate", isPantry: true))
        #expect(try await store.entries().count == 1)

        _ = try await store.save(IngredientVocabularyEntry(name: "Tomate", isPantry: false))

        // The concept asks for silent cleanup of unused, never-confirmed
        // entries; the write that emptied one is the cheapest moment for it.
        #expect(try await store.entries().isEmpty)
    }

    @Test("A store preference is state, not residue — it keeps the entry alive and round-trips")
    func storePreferenceSurvives() async throws {
        let store = try store()
        _ = try await store.save(IngredientVocabularyEntry(
            name: "Dürüm", preferredStore: "Lidl", shoppingNote: "die große Packung"
        ))

        let entry = try #require(try await store.entries().first { $0.key == "dürüm" })
        #expect(entry.preferredStore == "Lidl")
        #expect(entry.shoppingNote == "die große Packung")

        // Taking the preference back empties the entry, and the sweep takes it.
        _ = try await store.save(IngredientVocabularyEntry(name: "Dürüm"))
        #expect(try await store.entries().isEmpty)
    }

    @Test("Deleting an entry does not leave its varieties pointing at nothing")
    func deletingDetachesChildren() async throws {
        let store = try store()
        _ = try await store.save(IngredientVocabularyEntry(
            name: "Cocktailtomate", parentName: "Tomate", isOwnIngredient: true
        ))

        try await store.delete(key: "tomate")

        let child = try #require(try await store.entries().first { $0.key == "cocktailtomate" })
        #expect(child.parentName == nil)
    }
}

/// Decision B: proposed, at creation time, by word ending — and never applied
/// on its own.
@Suite("The variety proposal")
struct VariantHeuristicTests {
    private let catalog = IngredientCatalog.bundled

    @Test("A compound ending in a known word is offered as a variety of it")
    func compoundsAreCaught() {
        #expect(VariantHeuristic.parent(for: "Ochsenherztomate", in: catalog)?.name == "Tomate")
        #expect(VariantHeuristic.parent(for: "Rinderhackfleisch", in: catalog)?.name == "Hackfleisch")
    }

    @Test("A name the catalog already knows is not coming into being")
    func knownNamesAreNotProposed() {
        // The question is asked once, in the moment a new ingredient appears.
        #expect(VariantHeuristic.parent(for: "Tomate", in: catalog) == nil)
        #expect(VariantHeuristic.parent(for: "Cocktailtomaten", in: catalog) == nil)
    }

    @Test("A plural is not a variety")
    func pluralsAreNotVarieties() {
        // Too little word in front of the head noun to be a compound.
        #expect(VariantHeuristic.parent(for: "Tomatchen", in: catalog) == nil)
    }

    @Test("The longest head noun wins")
    func longestMatchWins() {
        let catalog = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Mark", category: .canned),
            CatalogIngredient(name: "Tomatenmark", category: .canned),
        ])
        #expect(VariantHeuristic.parent(for: "Bio-Tomatenmark", in: catalog)?.name == "Tomatenmark")
    }
}
