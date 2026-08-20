import Foundation
import SwiftData

/// A ``RecipeAmountReviewStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataRecipeAmountReviewStore: RecipeAmountReviewStore {
    public func reviewedHash(for recipeID: UUID) async throws -> String? {
        try stored(recipeID: recipeID)?.reviewedContentHash
    }

    public func markReviewed(_ recipe: Recipe) async throws {
        let hash = RecipeContentHash.hash(for: recipe)
        if let existing = try stored(recipeID: recipe.id) {
            existing.apply(reviewedContentHash: hash)
        } else {
            modelContext.insert(StoredAmountReview(recipeID: recipe.id, reviewedContentHash: hash))
        }
        try modelContext.save()
    }

    public func delete(recipeID: UUID) async throws {
        guard let existing = try stored(recipeID: recipeID) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func stored(recipeID: UUID) throws -> StoredAmountReview? {
        var descriptor = FetchDescriptor<StoredAmountReview>(predicate: #Predicate { $0.recipeID == recipeID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
