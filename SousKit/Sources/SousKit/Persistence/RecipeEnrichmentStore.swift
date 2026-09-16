import Foundation

/// Storage for what the model worked out about a recipe, kept separate
/// from the recipe itself for the same reason images are: derived,
/// replaceable facts, not part of the aggregate a person typed. Staleness
/// is decided in here — a guess is stamped with a hash of what it was
/// derived from — so nothing outside this store needs to know how.
public protocol RecipeEnrichmentStore: Sendable {
    func delete(recipeID: UUID) async throws

    /// The meal-suitability guess cached for this recipe, or `nil` if none
    /// is, or the one there is was made against a different `inputHash`
    /// than the recipe currently produces. An empty set is a real answer:
    /// the dish suits no meal on its own.
    func suitabilityGuess(for recipeID: UUID, inputHash: String) async throws -> Set<MealSlot>?
    /// Caches a guess, stamped with the hash of what it was derived from.
    func saveSuitabilityGuess(_ guess: Set<MealSlot>, for recipeID: UUID, inputHash: String) async throws

    /// The nutrition categories this cook has turned down for this recipe.
    /// Unstamped, and so never stale: see `StoredRecipeEnrichment`.
    func declinedNutritionTags(for recipeID: UUID) async throws -> Set<NutritionTag.Kind>
    /// Records that a suggested nutrition category was turned down, so it is
    /// not offered again.
    func declineNutritionTag(_ kind: NutritionTag.Kind, for recipeID: UUID) async throws
}
