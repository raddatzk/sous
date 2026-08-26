import Foundation
import SwiftData
import Testing
@testable import SousKit

/// The re-key from curated names onto SBLS codes, and — more importantly —
/// what happens to the rows it cannot re-key. Losing a cook's own values to a
/// data swap is the one thing the migration rules forbid outright.
@Suite("Bundled data migration")
struct BundledDataMigrationTests {
    private func store() throws -> ModelContainer {
        try .sousContainer(inMemory: true)
    }

    @Test("A name the synonym table knows gains its code")
    func mappableNameIsRekeyed() async throws {
        let container = try store()
        let legacy = LegacyRows(modelContainer: container)
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Kartoffel",
            perHundredGrams: [IngredientState.unspecified.rawValue: .zero],
            source: CatalogNutrition.ownSource
        ))

        let report = try await SwiftDataBundledDataMigration(modelContainer: container).run()

        #expect(report.nutritionRekeyed == 1)
        #expect(report.nutritionFlagged == 0)
    }

    @Test("A name that maps to nothing keeps working and is flagged instead")
    func unmappableNameKeepsWorking() async throws {
        let container = try store()
        let legacy = LegacyRows(modelContainer: container)
        let own = CatalogNutrition(
            name: "Omas Streuselmischung",
            perHundredGrams: [IngredientState.unspecified.rawValue: NutritionInfo(
                kcal: 420, proteinG: 5, fatG: 20, saturatedFatG: 0, carbsG: 55, sugarG: 0,
                fiberG: 0, sodiumMg: 0, vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0,
                vitaminEMg: 0, calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
            )],
            source: CatalogNutrition.ownSource
        )
        try await legacy.addOwnNutrition(own)

        let report = try await SwiftDataBundledDataMigration(modelContainer: container).run()

        #expect(report.nutritionFlagged == 1)
        #expect(report.nutritionRekeyed == 0)
        // The compatibility path: the row still reads back, by name, with the
        // cook's numbers intact. Nothing about the re-key may cost them that.
        #expect(try await legacy.ownNutritionNames() == ["Omas Streuselmischung"])
        #expect(try await legacy.flaggedNutritionNames() == ["Omas Streuselmischung"])
    }

    @Test("An alias override is re-keyed by the entry it points at")
    func aliasOverrideIsRekeyed() async throws {
        let container = try store()
        let legacy = LegacyRows(modelContainer: container)
        try await legacy.addAlias("Erdapfel", toKey: IngredientCatalog.normalize("Kartoffel"))
        try await legacy.addAlias("Wunderknolle", toKey: "gibtesnicht")

        let report = try await SwiftDataBundledDataMigration(modelContainer: container).run()

        #expect(report.aliasesRekeyed == 1)
        #expect(report.aliasesFlagged == 1)
        // Both still resolve their spelling — the flagged one by name, as it
        // always did.
        let byKey = try await legacy.aliasesByKey()
        #expect(byKey[IngredientCatalog.normalize("Kartoffel")] == ["Erdapfel"])
        #expect(byKey["gibtesnicht"] == ["Wunderknolle"])
        #expect(try await legacy.flaggedAliases() == ["Wunderknolle"])
    }

    @Test("Running it twice changes nothing the second time")
    func migrationIsIdempotent() async throws {
        let container = try store()
        let legacy = LegacyRows(modelContainer: container)
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Kartoffel", perHundredGrams: [:], source: CatalogNutrition.ownSource
        ))
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Omas Streuselmischung", perHundredGrams: [:], source: CatalogNutrition.ownSource
        ))
        let migration = SwiftDataBundledDataMigration(modelContainer: container)

        let first = try await migration.run()
        let second = try await migration.run()

        #expect(first.didChangeAnything)
        // It runs on every launch; a second pass must not re-flag or re-stamp.
        #expect(!second.didChangeAnything)
    }

    @Test("A word with identity but no values is not given a code")
    func identityOnlyWordIsFlagged() async throws {
        let container = try store()
        let legacy = LegacyRows(modelContainer: container)
        // "Kurkuma" is a known ingredient with no BLS row behind it. There is
        // no code to write down, and inventing one would be worse than the
        // name-keyed join it already has.
        try await legacy.addOwnNutrition(CatalogNutrition(
            name: "Kurkuma", perHundredGrams: [:], source: CatalogNutrition.ownSource
        ))

        let report = try await SwiftDataBundledDataMigration(modelContainer: container).run()

        #expect(report.nutritionFlagged == 1)
        #expect(report.nutritionRekeyed == 0)
    }
}
