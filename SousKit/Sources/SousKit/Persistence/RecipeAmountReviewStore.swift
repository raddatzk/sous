import Foundation

/// Storage for whether a recipe's amount suggestions have been reviewed —
/// kept separate from the recipe itself for the same reason the AI
/// enrichment cache is: it is a fact about a moment in the recipe's
/// history, not part of the aggregate a person typed. The staleness check
/// lives here rather than in the caller, so nothing outside this store
/// needs to know how it is decided.
public protocol RecipeAmountReviewStore: Sendable {
    /// The content hash `recipeID` was last reviewed against, or `nil` if
    /// it never has been.
    func reviewedHash(for recipeID: UUID) async throws -> String?
    /// Marks `recipe` reviewed against its current text, remembering
    /// `declining` as the questions answered "no, not in the text".
    ///
    /// The keys replace whatever was there rather than adding to it: the
    /// caller knows which of the old ones the recipe still asks, and a set
    /// that only ever grew would carry every sentence the recipe ever had.
    func markReviewed(_ recipe: Recipe, declining: Set<String>) async throws
    /// The ``AmountSuggestion/declineKey``s the cook has turned down for
    /// good — empty for a recipe nobody has answered.
    func declinedKeys(for recipeID: UUID) async throws -> Set<String>
    func delete(recipeID: UUID) async throws
}

public extension RecipeAmountReviewStore {
    /// Settling the recipe without turning any single question down — the
    /// "Nicht jetzt" of the review sheet, and every caller that predates
    /// there being anything to remember.
    func markReviewed(_ recipe: Recipe) async throws {
        try await markReviewed(recipe, declining: [])
    }
}
