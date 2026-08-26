import Foundation
import SwiftData
import Testing
@testable import SousKit

/// The fold of the three legacy tables into one vocabulary entry. Rule 1 of
/// the migration plan says user data is never lost, and this is the phase
/// with the most of it to carry: own ingredients, taught spellings, typed
/// numbers, pantry flags — all keyed by four different ideas of one name.
@Suite("Folding the user tables into the vocabulary")
struct VocabularyMigrationTests {
    private func info(kcal: Double, protein: Double = 0) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: protein, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0,
            fiberG: 0, sodiumMg: 0, vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0,
            vitaminEMg: 0, calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
        )
    }

    private func store() throws -> ModelContainer { try .sousContainer(inMemory: true) }

    @Test("Everything the four tables held arrives in one entry")
    func foldIsLossless() async throws {
        let container = try store()
        let legacy = LegacyRows(modelContainer: container)
        try await legacy.addOwnIngredient(CatalogIngredient(
            name: "Ajvar", aliases: ["Aivar"], category: .canned
        ))
        try await legacy.addAlias("Ajvar mild", toKey: "ajvar")
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Ajvar",
            perHundredGrams: [IngredientState.unspecified.rawValue: info(kcal: 90, protein: 2)],
            unitWeightsGrams: [IngredientUnit.piece.symbol: 30],
            source: CatalogNutrition.ownSource
        ))
        try await legacy.addPantryFlag(key: "ajvar")

        let report = try await SwiftDataVocabularyMigration(modelContainer: container).run()

        #expect(report.ingredientsFolded == 1)
        #expect(report.aliasesFolded == 1)
        #expect(report.nutritionFolded == 1)
        #expect(report.pantryFlagsFolded == 1)

        let entries = try await SwiftDataVocabularyStore(modelContainer: container).entries()
        let ajvar = try #require(entries.first { $0.key == "ajvar" })
        #expect(ajvar.name == "Ajvar")
        #expect(ajvar.isOwnIngredient)
        #expect(ajvar.category == .canned)
        #expect(ajvar.aliases == ["Aivar", "Ajvar mild"])
        #expect(ajvar.isPantry)
        #expect(ajvar.unitWeightsGrams[IngredientUnit.piece.symbol] == 30)

        let basis = try #require(ajvar.bases[IngredientState.unspecified.rawValue])
        #expect(basis.status == .confirmed)
        #expect(basis.values?.kcal == 90)
        #expect(basis.values?.proteinG == 2)
        #expect(basis.source == CatalogNutrition.ownSource)

        // Folded means folded: a row left behind would be folded again.
        #expect(try await legacy.remainingCount() == 0)
    }

    @Test("The phase-3 stamps are carried across, not dropped")
    func stampsSurvive() async throws {
        let container = try store()
        let legacy = LegacyRows(modelContainer: container)
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Kartoffel",
            perHundredGrams: [IngredientState.unspecified.rawValue: info(kcal: 70)],
            source: CatalogNutrition.ownSource
        ))
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Omas Streuselmischung",
            perHundredGrams: [IngredientState.unspecified.rawValue: info(kcal: 420)],
            source: CatalogNutrition.ownSource
        ))
        // Phase 3 first: it is what writes the stamps the fold carries.
        _ = try await SwiftDataBundledDataMigration(modelContainer: container).run()

        _ = try await SwiftDataVocabularyMigration(modelContainer: container).run()

        let entries = try await SwiftDataVocabularyStore(modelContainer: container).entries()
        let potato = try #require(entries.first { $0.key == "kartoffel" })
        // The code the re-key found: the join into the shipped world that
        // survives a data swap, and the one thing an own-values basis could
        // not say before there was somewhere to write it down.
        #expect(potato.bases[IngredientState.unspecified.rawValue]?.code != nil)
        #expect(!potato.needsBasisReview)

        let grandma = try #require(entries.first { $0.key == "omas streuselmischung" })
        #expect(grandma.bases[IngredientState.unspecified.rawValue]?.code == nil)
        // The stamp nobody read until now: a name that maps to nothing is a
        // question, and this is what puts it on the list of them.
        #expect(grandma.needsBasisReview)
        #expect(grandma.bases[IngredientState.unspecified.rawValue]?.values?.kcal == 420)
    }

    @Test("Running it twice changes nothing the second time")
    func foldIsIdempotent() async throws {
        let container = try store()
        let legacy = LegacyRows(modelContainer: container)
        try await legacy.addOwnIngredient(CatalogIngredient(name: "Ajvar", category: .canned))
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Ajvar",
            perHundredGrams: [IngredientState.unspecified.rawValue: info(kcal: 90)],
            source: CatalogNutrition.ownSource
        ))
        let migration = SwiftDataVocabularyMigration(modelContainer: container)

        let first = try await migration.run()
        let second = try await migration.run()

        #expect(first.didChangeAnything)
        #expect(!second.didChangeAnything)
        let entries = try await SwiftDataVocabularyStore(modelContainer: container).entries()
        #expect(entries.filter { $0.key == "ajvar" }.count == 1)
    }

    @Test("A row the share extension wrote first is merged into, not doubled")
    func foldMergesWithRowsItNeverSaw() async throws {
        let container = try store()
        // The extension builds its own stack and never runs a migration. It
        // may perfectly well be the first thing to open the store after an
        // update, and what it writes is a vocabulary row.
        let vocabulary = SwiftDataVocabularyStore(modelContainer: container)
        _ = try await vocabulary.save(IngredientVocabularyEntry(
            name: "Ajvar", aliases: ["Aivar"], isOwnIngredient: true
        ))
        let legacy = LegacyRows(modelContainer: container)
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Ajvar",
            perHundredGrams: [IngredientState.unspecified.rawValue: info(kcal: 90)],
            source: CatalogNutrition.ownSource
        ))
        try await legacy.addAlias("Ajvar scharf", toKey: "ajvar")

        _ = try await SwiftDataVocabularyMigration(modelContainer: container).run()

        let entries = try await vocabulary.entries()
        #expect(entries.count == 1)
        let ajvar = try #require(entries.first)
        #expect(ajvar.aliases == ["Aivar", "Ajvar scharf"])
        #expect(ajvar.bases[IngredientState.unspecified.rawValue]?.values?.kcal == 90)
    }
}

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
