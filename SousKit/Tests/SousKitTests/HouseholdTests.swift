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
        _ = try await CoreDataHouseholds(container: container).adoptOrphanedRows()
        #expect(try households(in: container).count == 1)

        let context = container.newBackgroundContext()
        try await context.perform {
            for entity in SousManagedObjectModel.memberEntityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                for row in try context.fetch(request) {
                    #expect(row.value(forKey: "household") != nil)
                }
            }
        }
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

    @Test("A second household is folded into the first, and takes its rows along")
    func mergesDuplicates() async throws {
        let container = try makeContainer()
        let store = CoreDataRecipeStore(container: container)
        _ = try await CoreDataHouseholds(container: container).adoptOrphanedRows()
        try await store.save(Recipe(title: "Brot"))

        // What a reinstall used to leave behind, and what an import can still
        // deliver: a second household, with a recipe of its own hanging off it.
        let context = container.newBackgroundContext()
        try await context.perform {
            let second = CDHousehold(context: context)
            second.id = UUID()
            second.name = "Zweiter"
            second.createdAt = .nowInSyncPrecision
            second.updatedAt = .nowInSyncPrecision
            let stray = CDRecipe(context: context)
            stray.id = UUID()
            stray.title = "Suppe"
            stray.createdAt = .nowInSyncPrecision
            stray.updatedAt = .nowInSyncPrecision
            stray.household = second
            try context.save()
        }

        let folded = try await CoreDataHouseholds(container: container).mergeDuplicates()

        #expect(folded == 1)
        #expect(try households(in: container).count == 1)
        // Both recipes survive, under the household that was there first.
        let titles = try await store.recipes(matching: .all).map(\.title).sorted()
        #expect(titles == ["Brot", "Suppe"])
        try await context.perform {
            for row in try context.fetch(CDRecipe.fetchRequest()) {
                #expect(row.household != nil)
            }
        }
    }

    @Test("The own household is founded by the first content, not by launch")
    func firstContentFoundsTheHousehold() async throws {
        let container = try makeContainer()

        // Launch with nothing to show: no household is conjured up. An
        // invitation-only member stays household-less and lives entirely in
        // the one they joined.
        let adopted = try await CoreDataHouseholds(container: container).adoptOrphanedRows()
        #expect(adopted == 0)
        #expect(try households(in: container).isEmpty)

        // The first own recipe is the founding act.
        try await CoreDataRecipeStore(container: container).save(Recipe(title: "Brot"))
        #expect(try households(in: container).count == 1)
    }

    @Test("Asking to invite without CloudKit fails with a sentence, not silence")
    func invitingWithoutCloudKitSaysWhy() async throws {
        // The in-memory container is a plain NSPersistentContainer — the same
        // shape a device without the entitlement gets. A person who taps
        // "Haushalt teilen" there has asked for something, and the answer has
        // to be an error they can read, not a button that does nothing.
        await #expect(throws: HouseholdSharingError.self) {
            _ = try await CoreDataHouseholds(container: try makeContainer()).shareForInviting()
        }
    }
}

/// Serialized, because the active household is process-wide state — the same
/// way it is in the app.
@Suite("Switching households", .serialized)
struct HouseholdSwitchingTests {
    @Test("An active household nothing holds falls back to the person's own")
    func fallsBackToOwn() async throws {
        let before = ActiveHousehold.id
        defer { ActiveHousehold.id = before }
        // Names a household no store on this device has — the state after
        // being removed from one, or after the account changed.
        ActiveHousehold.id = UUID()

        let container = try SousPersistentContainer.make(inMemory: true)
        let store = CoreDataRecipeStore(container: container)
        try await store.save(Recipe(title: "Brot"))

        // Both the write and the read land in the own household rather than
        // vanishing into a scope that does not exist.
        #expect(try await store.recipes(matching: .all).map(\.title) == ["Brot"])
    }
}
