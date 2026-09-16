import CoreData
import Foundation
import Testing
@testable import SousKit

/// A store written by a build that still had `CDAmountReview` opens under
/// the current model, which no longer has it, and keeps everything else.
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

    @Test("A store holding amount-review rows opens without the entity and keeps its recipes")
    func amountReviewEntityIsDroppedByLightweightMigration() async throws {
        let url = try temporaryStoreURL()
        let recipe = Recipe(title: "Brot", servings: 4, ingredientsText: "500 g Mehl", instructionsText: "Mehl kneten.")

        // The store as an earlier build left it: a recipe, and a review mark
        // in the entity that no longer exists.
        let before = try open(url, with: SousManagedObjectModel.makeModel(includingRetiredEntities: true))
        let saved = try await CoreDataRecipeStore(container: before).save(recipe)
        let context = before.newBackgroundContext()
        try await context.perform {
            let mark = try #require(NSEntityDescription.insertNewObject(
                forEntityName: SousManagedObjectModel.amountReviewEntityName, into: context
            ) as? CDReviewMark)
            mark.recipeID = saved.id
            mark.reviewedContentHash = RecipeContentHash.hash(for: saved)
            mark.updatedAt = Date()
            try context.save()
        }
        try close(before)

        // The current model: the entity is gone from it, and the store still
        // opens — Core Data infers the migration and drops the table.
        let current = SousManagedObjectModel.shared
        #expect(current.entitiesByName[SousManagedObjectModel.amountReviewEntityName] == nil)
        let after = try open(url, with: current)
        let reopened = try await CoreDataRecipeStore(container: after).recipe(id: saved.id)
        #expect(reopened?.title == "Brot")
        #expect(reopened?.ingredientsText == "500 g Mehl")
        try close(after)
    }
}
