import Foundation
import SwiftData

/// Derived facts about a recipe the model worked out — the meal-suitability
/// guess and the nutrition categories the cook turned down. One row per
/// recipe.
@Model
public final class StoredRecipeEnrichment {
    #Index<StoredRecipeEnrichment>([\.recipeID])

    public var recipeID: UUID = UUID()
    /// Retired 2026-09-15 with the amount-claim cache. Both columns stay
    /// in the schema so an existing store opens without a migration; they
    /// are never read or written any more.
    public var contentHash: String = ""
    private var claimsData: Data = Data()
    public var updatedAt: Date = Date.nowInSyncPrecision

    /// The meal-suitability guess ``MealSuitabilityClassifier`` made, with
    /// its own staleness stamp. An empty array is a real guess — "suits no
    /// meal on its own", a dessert — where `nil` means nobody has asked.
    public var suitabilityInputHash: String?
    public var suitabilityGuessRaw: [String]?

    /// Nutrition categories this cook has turned down for this recipe.
    ///
    /// The one derived fact here that carries no staleness stamp, and that is
    /// the point: the guesses above describe a version of the recipe and
    /// expire with it, while a decline is a judgement about the dish. Asking
    /// again because an instruction was reworded would be exactly the nagging
    /// the suggestion model exists to avoid.
    public var declinedNutritionTagsRaw: [String]?

    public init(recipeID: UUID) {
        self.recipeID = recipeID
    }

    public var suitabilityGuess: Set<MealSlot>? {
        suitabilityGuessRaw.map { Set($0.compactMap(MealSlot.init(rawValue:))) }
    }

    public var declinedNutritionTags: Set<NutritionTag.Kind> {
        Set((declinedNutritionTagsRaw ?? []).compactMap(NutritionTag.Kind.init(rawValue:)))
    }

    public func applySuitability(inputHash: String, guess: Set<MealSlot>) {
        suitabilityInputHash = inputHash
        suitabilityGuessRaw = guess.map(\.rawValue).sorted()
        updatedAt = .nowInSyncPrecision
    }

    public func decline(_ kind: NutritionTag.Kind) {
        var declined = declinedNutritionTags
        declined.insert(kind)
        declinedNutritionTagsRaw = declined.map(\.rawValue).sorted()
        updatedAt = .nowInSyncPrecision
    }
}
