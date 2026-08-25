import Foundation
import Testing
@testable import SousKit

@Suite("NRF9.3 quality score")
struct NRF93ScoreTests {
    private func nutrition(
        kcal: Double, proteinG: Double = 0, fatG: Double = 0, saturatedFatG: Double = 0,
        carbsG: Double = 0, sugarG: Double = 0, fiberG: Double = 0, sodiumMg: Double = 0,
        vitaminAMcg: Double = 0, vitaminCMg: Double = 0, vitaminDMcg: Double = 0, vitaminEMg: Double = 0,
        calciumMg: Double = 0, ironMg: Double = 0, magnesiumMg: Double = 0, potassiumMg: Double = 0
    ) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: proteinG, fatG: fatG, saturatedFatG: saturatedFatG,
            carbsG: carbsG, sugarG: sugarG, fiberG: fiberG, sodiumMg: sodiumMg,
            vitaminAMcg: vitaminAMcg, vitaminCMg: vitaminCMg, vitaminDMcg: vitaminDMcg, vitaminEMg: vitaminEMg,
            calciumMg: calciumMg, ironMg: ironMg, magnesiumMg: magnesiumMg, potassiumMg: potassiumMg
        )
    }

    @Test("A nutrient-dense, low-calorie profile scores clearly positive")
    func nutrientDenseProfileIsPositive() {
        let spinachLike = nutrition(
            kcal: 23, proteinG: 2.9, saturatedFatG: 0, sugarG: 0.4, fiberG: 2.2, sodiumMg: 79,
            vitaminAMcg: 469, vitaminCMg: 28.1, vitaminEMg: 2,
            calciumMg: 99, ironMg: 2.7, magnesiumMg: 79, potassiumMg: 558
        )
        #expect(NRF93Score.score(for: spinachLike) > 50)
    }

    @Test("A sugar- and sodium-heavy, nutrient-poor profile scores clearly negative")
    func poorProfileIsNegative() {
        let candyLike = nutrition(
            kcal: 500, proteinG: 2, saturatedFatG: 15, sugarG: 60, fiberG: 1, sodiumMg: 800,
            calciumMg: 10, ironMg: 0.5, magnesiumMg: 5, potassiumMg: 50
        )
        #expect(NRF93Score.score(for: candyLike) < -10)
    }

    @Test("Zero calories does not divide by zero, and reads as neutral")
    func zeroCaloriesIsGuarded() {
        #expect(NRF93Score.score(for: nutrition(kcal: 0, proteinG: 10)) == 0)
    }

    @Test("Each beneficial nutrient's contribution caps at 100% DV per 100 kcal")
    func beneficialContributionIsCapped() {
        // Potassium alone, wildly out of proportion to the calories — without
        // a cap this would dominate the score by itself.
        let extreme = nutrition(kcal: 10, potassiumMg: 100_000)
        #expect(NRF93Score.score(for: extreme) == 100)
    }
}
