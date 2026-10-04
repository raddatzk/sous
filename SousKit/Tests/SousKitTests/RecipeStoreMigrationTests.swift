import CoreData
import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import SousKit

@Suite("Migrating a library between stores")
struct RecipeStoreMigrationTests {
    /// The SwiftData side, the way a device that has been in use holds it.
    private func makeSource() throws -> RecipeStoreMigration.Source {
        let container = try ModelContainer.sousContainer(inMemory: true)
        return RecipeStoreMigration.Source(
            recipes: SwiftDataRecipeStore(modelContainer: container),
            images: SwiftDataRecipeImageStore(modelContainer: container),
            mealPlan: SwiftDataMealPlanStore(modelContainer: container),
            shopping: SwiftDataShoppingListStore(modelContainer: container)
        )
    }

    private func makeDestination() throws -> RecipeStoreMigration.Destination {
        let container = try SousPersistentContainer.make(inMemory: true)
        return RecipeStoreMigration.Destination(
            recipes: CoreDataRecipeStore(container: container),
            images: CoreDataRecipeImageStore(container: container),
            mealPlan: CoreDataMealPlanStore(container: container),
            shopping: CoreDataShoppingListStore(container: container)
        )
    }

    /// A small JPEG, so the test does not depend on a fixture file.
    private func makeImage() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 30,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("A library arrives whole — recipes, groups, pictures and the trash")
    func copiesEverything() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        let group = try await source.recipes.saveVariantGroup(VariantGroup(title: "Chili"))
        let withGroup = try await source.recipes.save(Recipe(
            title: "Chili con Carne",
            ingredientsText: "400 g Hackfleisch",
            variantGroupID: group.id
        ))
        let plain = try await source.recipes.save(Recipe(title: "Brot", ingredientsText: "500 g Mehl"))
        let binned = try await source.recipes.save(Recipe(title: "Alter Auflauf"))
        try await source.recipes.delete(id: binned.id)
        let imageID = try await source.images.add(try makeImage(), to: plain.id)

        let report = try await RecipeStoreMigration.run(from: source, to: destination)

        #expect(report.recipesCopied == 3)
        #expect(report.groupsCopied == 1)
        #expect(report.imagesCopied == 1)

        #expect(try await destination.recipes.recipe(id: withGroup.id)?.variantGroupID == group.id)
        #expect(try await destination.recipes.variantGroup(id: group.id)?.title == "Chili")
        #expect(try await destination.recipes.recipe(id: plain.id)?.ingredientsText == "500 g Mehl")
        // The trash comes along: a deletion nobody has synced yet is still
        // news, and one that can be undone is still the cook's.
        #expect(try await destination.recipes.recipe(id: binned.id)?.deletedAt != nil)
        #expect(try await destination.images.image(id: imageID) != nil)
    }

    @Test("The timestamps are carried over, not restamped")
    func preservesTimestamps() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        let saved = try await source.recipes.save(Recipe(title: "Brot"))
        try await RecipeStoreMigration.run(from: source, to: destination)

        let migrated = try #require(try await destination.recipes.recipe(id: saved.id))
        // The whole point: `save` would stamp this to now, and a library that
        // arrives marked as changed just now uploads itself wholesale on the
        // first sync — from whichever device happened to migrate first.
        #expect(migrated.updatedAt == saved.updatedAt)
        #expect(migrated.createdAt == saved.createdAt)
    }

    @Test("Running it twice changes nothing the second time")
    func isIdempotent() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        let saved = try await source.recipes.save(Recipe(title: "Brot"))
        _ = try await source.images.add(try makeImage(), to: saved.id)

        try await RecipeStoreMigration.run(from: source, to: destination)
        let second = try await RecipeStoreMigration.run(from: source, to: destination)

        #expect(second.isEmpty)
        #expect(second.recipesAlreadyCurrent == 1)
        #expect(second.imagesAlreadyThere == 1)
        #expect(try await destination.recipes.recipes(matching: .all).count == 1)
    }

    @Test("A run that stopped halfway finishes on the next attempt")
    func resumesAfterAnInterruption() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        let first = try await source.recipes.save(Recipe(title: "Brot"))
        let second = try await source.recipes.save(Recipe(title: "Suppe"))
        // What a crash between two rows leaves behind: one there, one not.
        try await destination.recipes.adopt(first)

        let report = try await RecipeStoreMigration.run(from: source, to: destination)

        #expect(report.recipesCopied == 1)
        #expect(report.recipesAlreadyCurrent == 1)
        #expect(try await destination.recipes.recipe(id: second.id)?.title == "Suppe")
    }

    @Test("Work done in the old store after a migration still comes across")
    func newerSourceWins() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        var recipe = try await source.recipes.save(Recipe(title: "Brot"))
        try await RecipeStoreMigration.run(from: source, to: destination)

        recipe.title = "Brot mit Nüssen"
        _ = try await source.recipes.save(recipe)
        let report = try await RecipeStoreMigration.run(from: source, to: destination)

        #expect(report.recipesCopied == 1)
        #expect(try await destination.recipes.recipe(id: recipe.id)?.title == "Brot mit Nüssen")
    }

    @Test("A migrated member is findable by the name of its group")
    func groupTitleReachesTheIndex() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        let group = try await source.recipes.saveVariantGroup(VariantGroup(title: "Ajvar-Suppe"))
        try await source.recipes.save(Recipe(title: "Vegane Variante", variantGroupID: group.id))

        try await RecipeStoreMigration.run(from: source, to: destination)

        // Which only works because groups are adopted before their members.
        let found = try await destination.recipes.recipes(matching: RecipeQuery(searchText: "Ajvar"))
        #expect(found.map(\.title) == ["Vegane Variante"])
    }

    @Test("The old store is left exactly as it was")
    func sourceIsUntouched() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        let saved = try await source.recipes.save(Recipe(title: "Brot"))
        let imageID = try await source.images.add(try makeImage(), to: saved.id)

        try await RecipeStoreMigration.run(from: source, to: destination)

        #expect(try await source.recipes.recipes(matching: .all).count == 1)
        #expect(try await source.recipes.recipe(id: saved.id)?.updatedAt == saved.updatedAt)
        #expect(try await source.images.image(id: imageID) != nil)
    }

    @Test("The plan and the shopping list come across too")
    func copiesTheRestOfTheLibrary() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        let recipe = try await source.recipes.save(Recipe(title: "Linsensuppe", servings: 2))
        let plan = try #require(source.mealPlan)
        try await plan.save(MealPlanEntry(day: Date().startOfDay, slot: .dinner, recipeID: recipe.id))
        try await plan.save(MealPlanEntry(day: nil, slot: .dinner, recipeID: recipe.id))
        try await source.shopping?.addManual(
            key: "linsen", name: "Linsen", category: .legumes, quantities: [Quantity(500, .gram)]
        )

        let report = try await RecipeStoreMigration.run(from: source, to: destination)

        #expect(report.planEntriesCopied == 2)
        #expect(report.shoppingItemsCopied == 1)

        let migratedPool = try await destination.mealPlan?.poolEntries() ?? []
        #expect(migratedPool.count == 1)
        let list = try #require(try await destination.shopping?.snapshot())
        #expect(list.items.map(\.name) == ["Linsen"])
    }

    @Test("A checked-off item arrives still checked")
    func shoppingKeepsItsCheckMarks() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        try await source.shopping?.addManual(
            key: "mehl", name: "Mehl", category: .grains, quantities: [Quantity(1, .kilogram)]
        )
        let before = try #require(try await source.shopping?.snapshot())
        let item = try #require(before.items.first)
        try await source.shopping?.setChecked(true, itemID: item.itemID)

        try await RecipeStoreMigration.run(from: source, to: destination)

        // Through `add` this would have come back open — which is the whole
        // reason the list has a door of its own.
        let migrated = try #require(try await destination.shopping?.snapshot().items.first)
        #expect(migrated.isChecked)
        #expect(migrated.itemID == item.itemID)
    }

    // MARK: - Once, not on every launch
    //
    // Plan entries and the shopping list are adopted without comparing
    // against what Core Data already holds, and an erased recipe leaves
    // nothing to compare against: a second run would undo work done in the
    // destination since. The app runs the migration through `runOnce`, so
    // each launch below after the first one is a no-op.

    /// A defaults suite of the test's own, empty, so no run is recorded yet.
    private func makeDefaults() throws -> UserDefaults {
        let name = "sous-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A completed run is recorded, and the next launch skips the migration")
    func runsOnce() async throws {
        let source = try makeSource()
        let destination = try makeDestination()
        let defaults = try makeDefaults()
        _ = try await source.recipes.save(Recipe(title: "Brot", ingredientsText: "500 g Mehl"))

        let first = try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)
        #expect(first?.recipesCopied == 1)
        #expect(defaults.bool(forKey: RecipeStoreMigration.finishedKey))

        _ = try await source.recipes.save(Recipe(title: "Kuchen", ingredientsText: "200 g Zucker"))
        let second = try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)
        #expect(second == nil)
        #expect(try await destination.recipes.recipes(matching: .all).map(\.title) == ["Brot"])
    }

    @Test("A plan entry moved after the migration stays where it was moved")
    func movedPlanEntryStaysMoved() async throws {
        let source = try makeSource()
        let destination = try makeDestination()
        let defaults = try makeDefaults()
        let plan = try #require(destination.mealPlan)
        let pooled = try await #require(source.mealPlan).save(MealPlanEntry(day: nil, recipeID: UUID()))
        try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)

        var moved = try #require(try await plan.entry(id: pooled.id))
        moved.day = Date()
        moved.updatedAt = .nowInSyncPrecision
        try await plan.save(moved)

        try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)

        #expect(try await plan.poolEntries().isEmpty)
    }

    @Test("A plan entry removed after the migration stays removed")
    func removedPlanEntryStaysRemoved() async throws {
        let source = try makeSource()
        let destination = try makeDestination()
        let defaults = try makeDefaults()
        let plan = try #require(destination.mealPlan)
        let pooled = try await #require(source.mealPlan).save(MealPlanEntry(day: nil, recipeID: UUID()))
        try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)

        try await plan.delete(id: pooled.id)
        #expect(try await plan.poolEntries().isEmpty)

        try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)

        #expect(try await plan.poolEntries().isEmpty)
    }

    @Test("A shopping item removed after the migration stays removed")
    func removedShoppingItemStaysRemoved() async throws {
        let source = try makeSource()
        let destination = try makeDestination()
        let defaults = try makeDefaults()
        let shopping = try #require(destination.shopping)
        try await source.shopping?.addManual(
            key: "mehl", name: "Mehl", category: .grains, quantities: [Quantity(1, .kilogram)]
        )
        try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)

        let item = try #require(try await shopping.snapshot().items.first)
        try await shopping.remove(itemID: item.itemID)
        #expect(try await shopping.snapshot().items.isEmpty)

        try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)

        #expect(try await shopping.snapshot().items.isEmpty)
    }

    @Test("A recipe erased after the migration stays erased")
    func erasedRecipeStaysErased() async throws {
        let source = try makeSource()
        let destination = try makeDestination()
        let defaults = try makeDefaults()
        let recipe = try await source.recipes.save(Recipe(title: "Brot", ingredientsText: "500 g Mehl"))
        try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)

        try await destination.recipes.erase(id: recipe.id)
        #expect(try await destination.recipes.recipe(id: recipe.id) == nil)

        try await RecipeStoreMigration.runOnce(from: source, to: destination, defaults: defaults)

        #expect(try await destination.recipes.recipe(id: recipe.id) == nil)
    }
}

/// The one thing the in-memory tests cannot reach.
///
/// Every other store test runs against `/dev/null`, where Core Data has no
/// directory to put external blobs in — so `allowsExternalBinaryDataStorage`,
/// the attribute that makes a photo a file beside the database rather than a
/// column in it, is never actually exercised there. That is also the setting
/// that becomes a CKAsset under CloudKit, which makes it the last place worth
/// leaving untested.
@Suite("Pictures in a store on disk")
struct RecipeImageOnDiskTests {
    private func makeContainer(at url: URL) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "Sous",
            managedObjectModel: SousManagedObjectModel.shared
        )
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container
    }

    /// Large enough that Core Data has reason to put it outside the row.
    private func makeLargeImage() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 3000, height: 2000,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // Noise rather than a flat fill: a single colour compresses to almost
        // nothing and would never leave the row.
        for x in stride(from: 0, to: 3000, by: 7) {
            for y in stride(from: 0, to: 2000, by: 7) {
                context.setFillColor(CGColor(
                    red: Double((x * y) % 255) / 255,
                    green: Double(x % 255) / 255,
                    blue: Double(y % 255) / 255,
                    alpha: 1
                ))
                context.fill(CGRect(x: x, y: y, width: 7, height: 7))
            }
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("A picture survives the store being closed and opened again")
    func survivesReopening() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sous-image-test-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: url.path + suffix)
                )
            }
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent().appending(path: ".Sous_SUPPORT")
            )
        }

        let recipeID = UUID()
        let original = try makeLargeImage()

        let imageID: UUID
        do {
            let store = CoreDataRecipeImageStore(container: try makeContainer(at: url))
            imageID = try await store.add(original, to: recipeID)
            #expect(try await store.image(id: imageID) != nil)
        }

        // A second container over the same file, the way the next launch
        // opens it. An external blob whose file the store cannot find again
        // reads as a recipe that lost its photo — silently.
        let reopened = CoreDataRecipeImageStore(container: try makeContainer(at: url))
        let readBack = try #require(try await reopened.image(id: imageID))
        #expect(readBack.count > 0)
        #expect(try await reopened.thumbnails(for: recipeID).map(\.id) == [imageID])
    }
}
