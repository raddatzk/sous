import Foundation

/// A recipe's computed nutrition, at the servings it was figured for.
public struct RecipeNutrition: Codable, Hashable, Sendable {
    public var perPortion: NutritionInfo
    public var servings: Int
    public var nrf93Score: Double

    public init(perPortion: NutritionInfo, servings: Int, nrf93Score: Double) {
        self.perPortion = perPortion
        self.servings = servings
        self.nrf93Score = nrf93Score
    }
}
