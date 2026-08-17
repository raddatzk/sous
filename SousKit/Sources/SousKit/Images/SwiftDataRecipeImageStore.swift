import Foundation
import SwiftData

/// A ``RecipeImageStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataRecipeImageStore: RecipeImageStore {
    public func thumbnails(for recipeID: UUID) async throws -> [(id: UUID, data: Data)] {
        try fetchImages(of: recipeID).map { ($0.id, $0.thumbnail) }
    }

    public func thumbnail(id: UUID) async throws -> Data? {
        try stored(id: id)?.thumbnail
    }

    public func image(id: UUID) async throws -> Data? {
        try stored(id: id)?.data
    }

    private func stored(id: UUID) throws -> StoredRecipeImage? {
        var descriptor = FetchDescriptor<StoredRecipeImage>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    public func add(_ data: Data, to recipeID: UUID) async throws -> UUID {
        guard let prepared = RecipeImageProcessing.prepare(data) else {
            throw RecipeImageError.unreadableImage
        }

        let image = StoredRecipeImage(
            recipeID: recipeID,
            sortOrder: try fetchImages(of: recipeID).count,
            data: prepared.data,
            thumbnail: prepared.thumbnail
        )
        modelContext.insert(image)
        try modelContext.save()
        return image.id
    }

    public func delete(id: UUID) async throws {
        let descriptor = FetchDescriptor<StoredRecipeImage>(predicate: #Predicate { $0.id == id })
        for image in try modelContext.fetch(descriptor) {
            modelContext.delete(image)
        }
        try modelContext.save()
    }

    public func deleteImages(ofRecipe recipeID: UUID, notIn keep: [UUID]) async throws {
        let kept = Set(keep)
        for image in try fetchImages(of: recipeID) where !kept.contains(image.id) {
            modelContext.delete(image)
        }
        try modelContext.save()
    }

    private func fetchImages(of recipeID: UUID) throws -> [StoredRecipeImage] {
        var descriptor = FetchDescriptor<StoredRecipeImage>(
            predicate: #Predicate { $0.recipeID == recipeID }
        )
        descriptor.sortBy = [SortDescriptor(\.sortOrder)]
        return try modelContext.fetch(descriptor)
    }
}

public enum RecipeImageError: Error, LocalizedError {
    case unreadableImage

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: "Das Bild konnte nicht gelesen werden."
        }
    }
}
