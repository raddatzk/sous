import Foundation
import SwiftData

/// That a person has looked at the amount suggestions for a recipe and
/// decided what to do with them — accept some, accept none, either way the
/// question is settled until the recipe's own text changes again.
///
/// One row per recipe, holding only the content hash it was reviewed
/// against — there is nothing else worth keeping: which suggestions existed
/// at review time is recomputed from the current text on demand, the same
/// way the suggestions themselves are, never stored.
@Model
public final class StoredAmountReview {
    #Index<StoredAmountReview>([\.recipeID])

    public var recipeID: UUID = UUID()
    /// `RecipeContentHash.hash(for:)` at the time this recipe was last
    /// reviewed — a mismatch against the recipe's current text means the
    /// ingredients or instructions changed since, and the question is open
    /// again.
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
