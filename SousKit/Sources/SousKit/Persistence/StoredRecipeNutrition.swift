import Foundation
import SwiftData

/// What `NutritionAggregator` computed the last time it ran for a recipe,
/// kept only as long as neither the recipe's own text nor any recipe it
/// links to has changed since — see `RecipeContentHash.hash(for:resolve:)`.
@Model
public final class StoredRecipeNutrition {
    #Index<StoredRecipeNutrition>([\.recipeID])

    public var recipeID: UUID = UUID()
    public var contentHash: String = ""
    private var nutritionData: Data = Data()
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(recipeID: UUID, contentHash: String, nutrition: RecipeNutrition) {
        self.recipeID = recipeID
        self.contentHash = contentHash
        self.nutritionData = (try? JSONEncoder().encode(nutrition)) ?? Data()
    }

    public var nutrition: RecipeNutrition? {
        try? JSONDecoder().decode(RecipeNutrition.self, from: nutritionData)
    }

    public func apply(contentHash: String, nutrition: RecipeNutrition) {
        self.contentHash = contentHash
        self.nutritionData = (try? JSONEncoder().encode(nutrition)) ?? Data()
        self.updatedAt = .nowInSyncPrecision
    }
}
