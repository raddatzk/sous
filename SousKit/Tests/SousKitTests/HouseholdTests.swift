import CoreData
import Foundation
import Testing
@testable import SousKit

@Suite("The household every row belongs to")
struct HouseholdTests {
    private func makeContainer() throws -> NSPersistentContainer {
        try SousPersistentContainer.make(inMemory: true)
    }

    private func households(in container: NSPersistentContainer) throws -> [CDHousehold] {
        let context = container.newBackgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<CDHousehold>(
                entityName: SousManagedObjectModel.householdEntityName
            )
            return try context.fetch(request)
        }
    }

    @Test("A saved recipe joins the household without anybody saying so")
    func insertsJoinTheHousehold() async throws {
        let container = try makeContainer()
        let store = CoreDataRecipeStore(container: container)

        try await store.save(Recipe(title: "Brot"))

        let context = container.newBackgroundContext()
        try await context.perform {
            let request = CDRecipe.fetchRequest()
            let row = try #require(try context.fetch(request).first)
            // Nothing in CoreDataRecipeStore mentions a household. If this
            // holds, no future insert path can forget it either.
            #expect(row.household != nil)
            #expect(row.household?.name == CoreDataHouseholds.defaultName)
        }
    }

    @Test("Every kind of row lands in the same household")
    func oneHouseholdForTheWholeLibrary() async throws {
        let container = try makeContainer()

        let recipe = try await CoreDataRecipeStore(container: container).save(Recipe(title: "Brot"))
        try await CoreDataMealPlanStore(container: container)
            .save(MealPlanEntry(day: nil, slot: .dinner, recipeID: recipe.id))
        try await CoreDataShoppingListStore(container: container)
            .addManual(key: "mehl", name: "Mehl", category: .grains, quantities: [])
        _ = try await CoreDataVocabularyStore(container: container)
            .save(IngredientVocabularyEntry(name: "Ajvar", isOwnIngredient: true))

        // One library, one zone: several households would mean rows that can
        // never be shared together.
        #expect(try households(in: container).count == 1)
    }

    @Test("Rows written before the household existed are taken in")
    func adoptsOrphanedRows() async throws {
        let container = try makeContainer()
        let store = CoreDataRecipeStore(container: container)
        try await store.save(Recipe(title: "Brot"))

        // What a row migrated out of SwiftData by an older build looks like:
        // present, correct, and hanging off nothing.
        let context = container.newBackgroundContext()
        try await context.perform {
            for row in try context.fetch(CDRecipe.fetchRequest()) {
                row.household = nil
            }
            try context.save()
        }

        let adopted = try await CoreDataHouseholds(container: container).adoptOrphanedRows()

        #expect(adopted == 1)
        try await context.perform {
            let row = try #require(try context.fetch(CDRecipe.fetchRequest()).first)
            #expect(row.household != nil)
        }
    }

    @Test("Without an iCloud account there is no zone, and that is not an error")
    func sharingIsQuietWhenItCannotHappen() async throws {
        // The in-memory container is a plain NSPersistentContainer, which is
        // the same answer a device without an account gives: no share, no
        // complaint, and a library that still works.
        let shared = try await CoreDataHouseholds(container: try makeContainer()).ensureShared()
        #expect(!shared)
    }
}
