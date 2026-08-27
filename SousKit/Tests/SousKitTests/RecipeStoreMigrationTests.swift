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
    /// The SwiftData side, the way a device that has been in use holds it.
    private func makeSource() throws -> RecipeStoreMigration.Source {
        let container = try ModelContainer.sousContainer(inMemory: true)
        return RecipeStoreMigration.Source(
            recipes: SwiftDataRecipeStore(modelContainer: container),
            images: SwiftDataRecipeImageStore(modelContainer: container),
            mealPlan: SwiftDataMealPlanStore(modelContainer: container),
            vocabulary: SwiftDataVocabularyStore(modelContainer: container),
            shopping: SwiftDataShoppingListStore(modelContainer: container),
            amountReviews: SwiftDataRecipeAmountReviewStore(modelContainer: container),
            ingredientReviews: SwiftDataRecipeIngredientReviewStore(modelContainer: container)
        )
    }

    private func makeDestination() throws -> RecipeStoreMigration.Destination {
        let container = try SousPersistentContainer.make(inMemory: true)
        return RecipeStoreMigration.Destination(
            recipes: CoreDataRecipeStore(container: container),
            images: CoreDataRecipeImageStore(container: container),
            mealPlan: CoreDataMealPlanStore(container: container),
            vocabulary: CoreDataVocabularyStore(container: container),
            shopping: CoreDataShoppingListStore(container: container),
            amountReviews: CoreDataRecipeAmountReviewStore(container: container),
            ingredientReviews: CoreDataRecipeIngredientReviewStore(container: container)
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

    @Test("The plan, the vocabulary and the shopping list come across too")
    func copiesTheRestOfTheLibrary() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        let recipe = try await source.recipes.save(Recipe(title: "Linsensuppe", servings: 2))
        let plan = try #require(source.mealPlan)
        try await plan.save(MealPlanEntry(day: Date().startOfDay, slot: .dinner, recipeID: recipe.id))
        try await plan.save(MealPlanEntry(day: nil, slot: .dinner, recipeID: recipe.id))
        _ = try await source.vocabulary?.save(IngredientVocabularyEntry(
            name: "Ajvar", aliases: ["Aivar"], isOwnIngredient: true, isPantry: true
        ))
        try await source.shopping?.addManual(
            key: "linsen", name: "Linsen", category: .legumes, quantities: [Quantity(500, .gram)]
        )

        let report = try await RecipeStoreMigration.run(from: source, to: destination)

        #expect(report.planEntriesCopied == 2)
        #expect(report.vocabularyCopied == 1)
        #expect(report.shoppingItemsCopied == 1)

        let migratedPool = try await destination.mealPlan?.poolEntries() ?? []
        #expect(migratedPool.count == 1)
        let ajvar = try #require(try await destination.vocabulary?.entries().first { $0.key == "ajvar" })
        #expect(ajvar.isPantry)
        #expect(ajvar.aliases == ["Aivar"])
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

    @Test("A settled review stays settled; one whose recipe changed does not")
    func reviewMarksFollowTheirText() async throws {
        let source = try makeSource()
        let destination = try makeDestination()

        var settled = try await source.recipes.save(Recipe(title: "Brot", ingredientsText: "500 g Mehl"))
        try await source.amountReviews?.markReviewed(settled)

        // Reviewed, then edited: the question reopened before the migration
        // ever ran, and must not arrive answered.
        var reopened = try await source.recipes.save(Recipe(title: "Suppe", ingredientsText: "1 Zwiebel"))
        try await source.ingredientReviews?.markReviewed(reopened)
        reopened.ingredientsText = "2 Zwiebeln"
        reopened = try await source.recipes.save(reopened)

        try await RecipeStoreMigration.run(from: source, to: destination)

        settled = try #require(try await destination.recipes.recipe(id: settled.id))
        #expect(try await destination.amountReviews?.reviewedHash(for: settled.id)
            == RecipeContentHash.hash(for: settled))
        let migratedReopened = try #require(try await destination.recipes.recipe(id: reopened.id))
        #expect(try await destination.ingredientReviews?.reviewedHash(for: migratedReopened.id)
            != RecipeContentHash.hash(for: migratedReopened))
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
