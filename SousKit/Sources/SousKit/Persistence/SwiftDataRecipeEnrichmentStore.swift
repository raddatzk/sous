import Foundation
import SwiftData

/// A ``RecipeEnrichmentStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataRecipeEnrichmentStore: RecipeEnrichmentStore {
    public func claims(for recipe: Recipe) async throws -> [StoredAmountClaim]? {
        guard let stored = try stored(recipeID: recipe.id),
              stored.contentHash == RecipeContentHash.hash(for: recipe)
        else { return nil }
        return stored.claims
    }

    public func save(_ claims: [StoredAmountClaim], for recipe: Recipe) async throws {
        let hash = RecipeContentHash.hash(for: recipe)
        if let existing = try stored(recipeID: recipe.id) {
            existing.apply(contentHash: hash, claims: claims)
        } else {
            modelContext.insert(StoredRecipeEnrichment(recipeID: recipe.id, contentHash: hash, claims: claims))
        }
        try modelContext.save()
    }

    public func delete(recipeID: UUID) async throws {
        guard let existing = try stored(recipeID: recipeID) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func stored(recipeID: UUID) throws -> StoredRecipeEnrichment? {
        var descriptor = FetchDescriptor<StoredRecipeEnrichment>(predicate: #Predicate { $0.recipeID == recipeID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
