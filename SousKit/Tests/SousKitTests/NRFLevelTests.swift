import Foundation
import Testing
@testable import SousKit

@Suite("NRF level bands")
struct NRFLevelTests {
    @Test("Each band's boundary lands on the correct side")
    func boundaries() {
        #expect(NRFLevel(score: 40) == .a)
        #expect(NRFLevel(score: 39.9) == .b)
        #expect(NRFLevel(score: 20) == .b)
        #expect(NRFLevel(score: 19.9) == .c)
        #expect(NRFLevel(score: 0) == .c)
        #expect(NRFLevel(score: -0.1) == .d)
        #expect(NRFLevel(score: -20) == .d)
        #expect(NRFLevel(score: -20.1) == .e)
    }

    @Test("Extreme scores stay within the outer bands")
    func extremes() {
        #expect(NRFLevel(score: 1000) == .a)
        #expect(NRFLevel(score: -1000) == .e)
    }

    @Test("A recipe's level follows its score")
    func recipeLevel() {
        let nutrition = RecipeNutrition(perPortion: .zero, servings: 2, nrf93Score: 51.1)
        #expect(nutrition.nrfLevel == .a)
    }
}
