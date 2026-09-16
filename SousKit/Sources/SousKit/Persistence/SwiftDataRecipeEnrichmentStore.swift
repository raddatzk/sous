import Foundation
import SwiftData

/// A ``RecipeEnrichmentStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataRecipeEnrichmentStore: RecipeEnrichmentStore {
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
            let row = StoredRecipeEnrichment(recipeID: recipeID)
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
            let row = StoredRecipeEnrichment(recipeID: recipeID)
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
