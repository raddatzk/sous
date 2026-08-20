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
    /// Marks `recipe` reviewed against its current text.
    func markReviewed(_ recipe: Recipe) async throws
    func delete(recipeID: UUID) async throws
}
