import Foundation

/// A recipe's computed nutrition, at the servings it was figured for —
/// always together with what the figure is based on: a sum without its
/// coverage would be a number pretending to be more complete than it is.
public struct RecipeNutrition: Codable, Hashable, Sendable {
    public var perPortion: NutritionInfo
    public var servings: Int
    public var nrf93Score: Double
    public var coverage: NutritionCoverage

    public init(perPortion: NutritionInfo, servings: Int, nrf93Score: Double, coverage: NutritionCoverage) {
        self.perPortion = perPortion
        self.servings = servings
        self.nrf93Score = nrf93Score
        self.coverage = coverage
    }
}
