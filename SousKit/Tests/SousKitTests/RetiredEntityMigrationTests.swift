import CoreData
import Foundation
import Testing
@testable import SousKit

/// A store written by a build that still had the retired entities opens
/// under the current model, which no longer has them, and keeps everything
/// else: `CDAmountReview` (2026-09-16), `CDIngredientReview` and
/// `CDVocabularyEntry` (phase 6b), with `CDHouseholdIngredient` arriving in
/// the same step.
///
/// Not in memory: an in-memory store has no schema to migrate. A real SQLite
/// file in a temporary directory, with the same history tracking the app
/// switches on, is the one way to see the lightweight migration Core Data
/// infers for a dropped entity actually run.
@Suite("Retired entities migrate away")
struct RetiredEntityMigrationTests {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sous-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Sous.sqlite")
    }

    private func description(at url: URL) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        return description
    }

    private func open(_ url: URL, with model: NSManagedObjectModel) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Sous", managedObjectModel: model)
        container.persistentStoreDescriptions = [description(at: url)]
        var loadError: Error?
        container.loadPersistentStores { _, error in
            if loadError == nil { loadError = error }
        }
        if let loadError { throw loadError }
        return container
    }

    private func close(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    @Test("A store holding rows of every retired entity opens without them and keeps its recipes")
    func retiredEntitiesAreDroppedByLightweightMigration() async throws {
        let url = try temporaryStoreURL()
        let recipe = Recipe(title: "Brot", servings: 4, ingredientsText: "500 g Mehl", instructionsText: "Mehl kneten.")

        // The store as a 6a build left it: a recipe, review marks, and a
        // vocabulary row — and no household-ingredient entity yet.
        let before = try open(url, with: SousManagedObjectModel.makeModel(
            includingRetiredEntities: true, includingHouseholdIngredients: false
        ))
        let saved = try await CoreDataRecipeStore(container: before).save(recipe)
        let context = before.newBackgroundContext()
        try await context.perform {
            for entity in [SousManagedObjectModel.amountReviewEntityName, SousManagedObjectModel.ingredientReviewEntityName] {
                let mark = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
                mark.setValue(saved.id, forKey: "recipeID")
                mark.setValue(RecipeContentHash.hash(for: saved), forKey: "reviewedContentHash")
                mark.setValue(Date(), forKey: "updatedAt")
            }
            let word = NSEntityDescription.insertNewObject(
                forEntityName: SousManagedObjectModel.vocabularyEntryEntityName, into: context
            )
            word.setValue(UUID(), forKey: "id")
            word.setValue("mehl", forKey: "key")
            word.setValue("Mehl", forKey: "name")
            word.setValue(true, forKey: "isPantry")
            word.setValue(Date(), forKey: "createdAt")
            word.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
        try close(before)

        // The current model: the entities are gone from it, the new one is
        // there, and the store still opens — Core Data infers the migration.
        let current = SousManagedObjectModel.shared
        for retired in [
            SousManagedObjectModel.amountReviewEntityName,
            SousManagedObjectModel.ingredientReviewEntityName,
            SousManagedObjectModel.vocabularyEntryEntityName,
        ] {
            #expect(current.entitiesByName[retired] == nil)
            #expect(!SousManagedObjectModel.memberEntityNames.contains(retired))
        }
        #expect(current.entitiesByName[SousManagedObjectModel.householdIngredientEntityName] != nil)
        let after = try open(url, with: current)
        let reopened = try await CoreDataRecipeStore(container: after).recipe(id: saved.id)
        #expect(reopened?.title == "Brot")
        #expect(reopened?.ingredientsText == "500 g Mehl")

        // Nothing is taken over from the vocabulary (the data is reset); the
        // household's fields start empty and can be written.
        let household = CoreDataHouseholdIngredientStore(container: after)
        #expect(try await household.entries().isEmpty)
        try await household.save(HouseholdIngredient(catalogID: "mehl", name: "Mehl", isPantry: true))
        #expect(try await household.entries().map(\.key) == ["id:mehl"])
        try close(after)
    }
}
