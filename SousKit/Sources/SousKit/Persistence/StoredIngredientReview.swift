import Foundation
import SwiftData

/// That a person has looked at a recipe's unrecognized ingredients and
/// decided what to do with them — add some to the catalog, leave some for
/// later, either way the question is settled until the recipe's own text
/// changes again.
///
/// One row per recipe, holding only the content hash it was reviewed
/// against — which ingredients were unknown at review time is recomputed
/// from the current text and the current catalog on demand, never stored.
@Model
public final class StoredIngredientReview {
    #Index<StoredIngredientReview>([\.recipeID])

    public var recipeID: UUID = UUID()
    /// `RecipeContentHash.hash(for:)` at the time this recipe was last
    /// reviewed — a mismatch against the recipe's current text means the
    /// ingredients changed since, and the question is open again.
    public var reviewedContentHash: String = ""
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(recipeID: UUID, reviewedContentHash: String) {
        self.recipeID = recipeID
        self.reviewedContentHash = reviewedContentHash
    }

    public func apply(reviewedContentHash: String) {
        self.reviewedContentHash = reviewedContentHash
        self.updatedAt = .nowInSyncPrecision
    }
}
