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
    /// The questions turned down for good, as `AmountSuggestion.declineKey`s
    /// in a JSON array.
    ///
    /// The hash alone could never carry this. It settles the whole recipe
    /// until any of its text changes, which is right for "I have looked at
    /// these" and wrong for "this one, never": one comma elsewhere and every
    /// declined amount was being asked about again. These keys hang on the
    /// sentence the question is about, so the rest of the recipe can be
    /// rewritten around them.
    ///
    /// Defaulted rather than optional, which is what SwiftData's lightweight
    /// migration needs of anything added to a model already in use.
    public var declinedKeysJSON: String = "[]"
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(recipeID: UUID, reviewedContentHash: String, declinedKeys: Set<String> = []) {
        self.recipeID = recipeID
        self.reviewedContentHash = reviewedContentHash
        self.declinedKeysJSON = Self.encode(declinedKeys)
    }

    public func apply(reviewedContentHash: String, declinedKeys: Set<String>) {
        self.reviewedContentHash = reviewedContentHash
        self.declinedKeysJSON = Self.encode(declinedKeys)
        self.updatedAt = .nowInSyncPrecision
    }

    public var declinedKeys: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: Data(declinedKeysJSON.utf8))) ?? []
    }

    /// Sorted before encoding: the set has no order of its own, and two
    /// devices writing the same answers should write the same bytes.
    static func encode(_ keys: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(keys.sorted()) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
