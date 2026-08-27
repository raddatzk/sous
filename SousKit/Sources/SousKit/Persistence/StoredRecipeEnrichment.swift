import Foundation
import SwiftData

/// What `AmountAIExtractor` found the last time it ran for a recipe, kept
/// only as long as the text it ran against hasn't changed.
///
/// One row per recipe rather than one row per claim: the claims are only
/// ever read or replaced as a whole set, never queried individually, so a
/// JSON blob avoids the ceremony of a second `@Model` and a relationship
/// for data nothing needs to join against.
@Model
public final class StoredRecipeEnrichment {
    #Index<StoredRecipeEnrichment>([\.recipeID])

    public var recipeID: UUID = UUID()
    /// `RecipeContentHash.hash(for:)` at the time `claimsData` was written —
    /// a mismatch against the recipe's current text means these claims
    /// describe a version of the recipe that no longer exists.
    public var contentHash: String = ""
    private var claimsData: Data = Data()
    public var updatedAt: Date = Date.nowInSyncPrecision

    /// The meal-suitability guess ``MealSuitabilityClassifier`` made, beside
    /// the amount claims: a second derived fact about the same recipe, with
    /// its own staleness stamp because it reads different parts of the
    /// recipe than the claims do. An empty array is a real guess — "suits
    /// no meal on its own", a dessert — where `nil` means nobody has asked.
    public var suitabilityInputHash: String?
    public var suitabilityGuessRaw: [String]?

    public init(recipeID: UUID, contentHash: String, claims: [StoredAmountClaim]) {
        self.recipeID = recipeID
        self.contentHash = contentHash
        self.claimsData = (try? JSONEncoder().encode(claims)) ?? Data()
    }

    public var claims: [StoredAmountClaim] {
        (try? JSONDecoder().decode([StoredAmountClaim].self, from: claimsData)) ?? []
    }

    public var suitabilityGuess: Set<MealSlot>? {
        suitabilityGuessRaw.map { Set($0.compactMap(MealSlot.init(rawValue:))) }
    }

    public func apply(contentHash: String, claims: [StoredAmountClaim]) {
        self.contentHash = contentHash
        self.claimsData = (try? JSONEncoder().encode(claims)) ?? Data()
        self.updatedAt = .nowInSyncPrecision
    }

    public func applySuitability(inputHash: String, guess: Set<MealSlot>) {
        suitabilityInputHash = inputHash
        suitabilityGuessRaw = guess.map(\.rawValue).sorted()
        updatedAt = .nowInSyncPrecision
    }
}
