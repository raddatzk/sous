import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import SousKit

@Suite("Recipe images")
struct RecipeImageTests {
    /// A JPEG of the given size, so tests do not depend on a fixture file.
    private func makeImage(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return (
            try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }

    @Test("A large photo is downsized on the way in, keeping its proportions")
    func downsizing() throws {
        let original = try makeImage(width: 4000, height: 3000)
        let prepared = try #require(RecipeImageProcessing.prepare(original))

        let full = try pixelSize(of: prepared.data)
        #expect(full.width == Int(RecipeImageProcessing.maxPixelSize))
        #expect(full.height == 1536)

        let thumbnail = try pixelSize(of: prepared.thumbnail)
        #expect(thumbnail.width == Int(RecipeImageProcessing.thumbnailPixelSize))
        #expect(prepared.data.count < original.count)
        #expect(prepared.thumbnail.count < prepared.data.count)
    }

    @Test("Data that is not an image is refused rather than stored", arguments: StoreBackend.allCases)
    func refusesNonImages(_ backend: StoreBackend) async throws {
        let store = try backend.makeImageStore()

        await #expect(throws: RecipeImageError.self) {
            try await store.add(Data("not an image".utf8), to: UUID())
        }
    }

    @Test("Images are stored per recipe, in order, and read back", arguments: StoreBackend.allCases)
    func storeAndRead(_ backend: StoreBackend) async throws {
        let store = try backend.makeImageStore()
        let recipeID = UUID()

        let first = try await store.add(try makeImage(width: 800, height: 600), to: recipeID)
        let second = try await store.add(try makeImage(width: 640, height: 480), to: recipeID)

        let thumbnails = try await store.thumbnails(for: recipeID)
        #expect(thumbnails.map(\.id) == [first, second])
        #expect(thumbnails.allSatisfy { !$0.data.isEmpty })

        #expect(try await store.image(id: first) != nil)
        #expect(try await store.image(id: UUID()) == nil)
    }

    @Test("Images of other recipes are untouched", arguments: StoreBackend.allCases)
    func isolationBetweenRecipes(_ backend: StoreBackend) async throws {
        let store = try backend.makeImageStore()
        let mine = UUID()
        let theirs = UUID()

        _ = try await store.add(try makeImage(width: 200, height: 200), to: mine)
        _ = try await store.add(try makeImage(width: 200, height: 200), to: theirs)

        #expect(try await store.thumbnails(for: mine).count == 1)
        #expect(try await store.thumbnails(for: theirs).count == 1)
    }

    @Test("Removing a picture from a recipe deletes its blob", arguments: StoreBackend.allCases)
    func pruningUnreferenced(_ backend: StoreBackend) async throws {
        let store = try backend.makeImageStore()
        let recipeID = UUID()

        let kept = try await store.add(try makeImage(width: 300, height: 300), to: recipeID)
        let dropped = try await store.add(try makeImage(width: 300, height: 300), to: recipeID)

        try await store.deleteImages(ofRecipe: recipeID, notIn: [kept])

        #expect(try await store.thumbnails(for: recipeID).map(\.id) == [kept])
        #expect(try await store.image(id: dropped) == nil)
    }

    @Test("A recipe carries its image references through a round trip", arguments: StoreBackend.allCases)
    func recipeKeepsReferences(_ backend: StoreBackend) async throws {
        let store = try backend.makeStore()
        let imageID = UUID()
        let recipe = Recipe(title: "Brot", imageIDs: [imageID])

        try await store.save(recipe)
        #expect(try await store.recipe(id: recipe.id)?.imageIDs == [imageID])
    }
}
