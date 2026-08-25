import Foundation

/// Storage for whether a recipe's unrecognized ingredients have been
/// reviewed — kept separate from the recipe itself for the same reason the
/// amount-review cache is: a fact about a moment in the recipe's history,
/// not part of the aggregate a person typed.
public protocol RecipeIngredientReviewStore: Sendable {
    /// The content hash `recipeID` was last reviewed against, or `nil` if
    /// it never has been.
    func reviewedHash(for recipeID: UUID) async throws -> String?
    /// Marks `recipe` reviewed against its current text.
    func markReviewed(_ recipe: Recipe) async throws
    func delete(recipeID: UUID) async throws
}
