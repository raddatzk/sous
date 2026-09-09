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

    public func suitabilityGuess(for recipeID: UUID, inputHash: String) async throws -> Set<MealSlot>? {
        guard let stored = try stored(recipeID: recipeID),
              stored.suitabilityInputHash == inputHash
        else { return nil }
        return stored.suitabilityGuess
    }

    public func saveSuitabilityGuess(_ guess: Set<MealSlot>, for recipeID: UUID, inputHash: String) async throws {
        if let existing = try stored(recipeID: recipeID) {
            existing.applySuitability(inputHash: inputHash, guess: guess)
        } else {
            // A row born for the guess alone: its claim hash stays empty,
            // which can never match a real recipe, so the claims side keeps
            // reading as "nothing cached".
            let row = StoredRecipeEnrichment(recipeID: recipeID, contentHash: "", claims: [])
            row.applySuitability(inputHash: inputHash, guess: guess)
            modelContext.insert(row)
        }
        try modelContext.save()
    }

    public func declinedNutritionTags(for recipeID: UUID) async throws -> Set<NutritionTag.Kind> {
        try stored(recipeID: recipeID)?.declinedNutritionTags ?? []
    }

    public func declineNutritionTag(_ kind: NutritionTag.Kind, for recipeID: UUID) async throws {
        if let existing = try stored(recipeID: recipeID) {
            existing.decline(kind)
        } else {
            // Same as the guess above: an empty claim hash never matches a
            // real recipe, so a row born for a decline says nothing about
            // claims.
            let row = StoredRecipeEnrichment(recipeID: recipeID, contentHash: "", claims: [])
            row.decline(kind)
            modelContext.insert(row)
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
