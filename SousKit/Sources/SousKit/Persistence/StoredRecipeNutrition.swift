import Foundation
import SwiftData

/// What `NutritionAggregator` computed the last time it ran for a recipe at
/// one serving count, kept only as long as neither the recipe's own text nor
/// any recipe it links to has changed since — see
/// `RecipeContentHash.hash(for:resolve:)`.
///
/// One row per (recipe, servings), not per recipe: per-portion figures are
/// not invariant under scaling (seasoning does not scale), and a single row
/// had the list view at base servings and the detail view at the displayed
/// count overwriting each other on every visit.
@Model
public final class StoredRecipeNutrition {
    #Index<StoredRecipeNutrition>([\.recipeID])

    public var recipeID: UUID = UUID()
    public var servings: Int = 0
    public var contentHash: String = ""
    private var nutritionData: Data = Data()
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(recipeID: UUID, contentHash: String, nutrition: RecipeNutrition) {
        self.recipeID = recipeID
        self.servings = nutrition.servings
        self.contentHash = contentHash
        self.nutritionData = (try? JSONEncoder().encode(nutrition)) ?? Data()
    }

    public var nutrition: RecipeNutrition? {
        try? JSONDecoder().decode(RecipeNutrition.self, from: nutritionData)
    }

    public func apply(contentHash: String, nutrition: RecipeNutrition) {
        self.servings = nutrition.servings
        self.contentHash = contentHash
        self.nutritionData = (try? JSONEncoder().encode(nutrition)) ?? Data()
        self.updatedAt = .nowInSyncPrecision
    }
}
