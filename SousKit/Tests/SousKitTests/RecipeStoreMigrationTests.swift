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
    private func makeSource() throws -> (any RecipeStore, any RecipeImageStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        return (
            SwiftDataRecipeStore(modelContainer: container),
            SwiftDataRecipeImageStore(modelContainer: container)
        )
    }

    private func makeDestination() throws -> (CoreDataRecipeStore, CoreDataRecipeImageStore) {
        let container = try SousPersistentContainer.make(inMemory: true)
        return (
            CoreDataRecipeStore(container: container),
            CoreDataRecipeImageStore(container: container)
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
        let (source, sourceImages) = try makeSource()
        let (destination, destinationImages) = try makeDestination()

        let group = try await source.saveVariantGroup(VariantGroup(title: "Chili"))
        let withGroup = try await source.save(Recipe(
            title: "Chili con Carne",
            ingredientsText: "400 g Hackfleisch",
            variantGroupID: group.id
        ))
        let plain = try await source.save(Recipe(title: "Brot", ingredientsText: "500 g Mehl"))
        let binned = try await source.save(Recipe(title: "Alter Auflauf"))
        try await source.delete(id: binned.id)
        let imageID = try await sourceImages.add(try makeImage(), to: plain.id)

        let report = try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )

        #expect(report.recipesCopied == 3)
        #expect(report.groupsCopied == 1)
        #expect(report.imagesCopied == 1)

        #expect(try await destination.recipe(id: withGroup.id)?.variantGroupID == group.id)
        #expect(try await destination.variantGroup(id: group.id)?.title == "Chili")
        #expect(try await destination.recipe(id: plain.id)?.ingredientsText == "500 g Mehl")
        // The trash comes along: a deletion nobody has synced yet is still
        // news, and one that can be undone is still the cook's.
        #expect(try await destination.recipe(id: binned.id)?.deletedAt != nil)
        #expect(try await destinationImages.image(id: imageID) != nil)
    }

    @Test("The timestamps are carried over, not restamped")
    func preservesTimestamps() async throws {
        let (source, sourceImages) = try makeSource()
        let (destination, destinationImages) = try makeDestination()

        let saved = try await source.save(Recipe(title: "Brot"))
        try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )

        let migrated = try #require(try await destination.recipe(id: saved.id))
        // The whole point: `save` would stamp this to now, and a library that
        // arrives marked as changed just now uploads itself wholesale on the
        // first sync — from whichever device happened to migrate first.
        #expect(migrated.updatedAt == saved.updatedAt)
        #expect(migrated.createdAt == saved.createdAt)
    }

    @Test("Running it twice changes nothing the second time")
    func isIdempotent() async throws {
        let (source, sourceImages) = try makeSource()
        let (destination, destinationImages) = try makeDestination()

        let saved = try await source.save(Recipe(title: "Brot"))
        _ = try await sourceImages.add(try makeImage(), to: saved.id)

        try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )
        let second = try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )

        #expect(second.isEmpty)
        #expect(second.recipesAlreadyCurrent == 1)
        #expect(second.imagesAlreadyThere == 1)
        #expect(try await destination.recipes(matching: .all).count == 1)
    }

    @Test("A run that stopped halfway finishes on the next attempt")
    func resumesAfterAnInterruption() async throws {
        let (source, sourceImages) = try makeSource()
        let (destination, destinationImages) = try makeDestination()

        let first = try await source.save(Recipe(title: "Brot"))
        let second = try await source.save(Recipe(title: "Suppe"))
        // What a crash between two rows leaves behind: one there, one not.
        try await destination.adopt(first)

        let report = try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )

        #expect(report.recipesCopied == 1)
        #expect(report.recipesAlreadyCurrent == 1)
        #expect(try await destination.recipe(id: second.id)?.title == "Suppe")
    }

    @Test("Work done in the old store after a migration still comes across")
    func newerSourceWins() async throws {
        let (source, sourceImages) = try makeSource()
        let (destination, destinationImages) = try makeDestination()

        var recipe = try await source.save(Recipe(title: "Brot"))
        try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )

        recipe.title = "Brot mit Nüssen"
        _ = try await source.save(recipe)
        let report = try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )

        #expect(report.recipesCopied == 1)
        #expect(try await destination.recipe(id: recipe.id)?.title == "Brot mit Nüssen")
    }

    @Test("A migrated member is findable by the name of its group")
    func groupTitleReachesTheIndex() async throws {
        let (source, sourceImages) = try makeSource()
        let (destination, destinationImages) = try makeDestination()

        let group = try await source.saveVariantGroup(VariantGroup(title: "Ajvar-Suppe"))
        try await source.save(Recipe(title: "Vegane Variante", variantGroupID: group.id))

        try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )

        // Which only works because groups are adopted before their members.
        let found = try await destination.recipes(matching: RecipeQuery(searchText: "Ajvar"))
        #expect(found.map(\.title) == ["Vegane Variante"])
    }

    @Test("The old store is left exactly as it was")
    func sourceIsUntouched() async throws {
        let (source, sourceImages) = try makeSource()
        let (destination, destinationImages) = try makeDestination()

        let saved = try await source.save(Recipe(title: "Brot"))
        let imageID = try await sourceImages.add(try makeImage(), to: saved.id)

        try await RecipeStoreMigration.run(
            from: source, images: sourceImages,
            to: destination, images: destinationImages
        )

        #expect(try await source.recipes(matching: .all).count == 1)
        #expect(try await source.recipe(id: saved.id)?.updatedAt == saved.updatedAt)
        #expect(try await sourceImages.image(id: imageID) != nil)
    }
}
