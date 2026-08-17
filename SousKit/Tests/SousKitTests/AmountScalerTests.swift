import Foundation
import Testing
@testable import SousKit

@Suite("Scaling amounts in free text")
struct AmountScalerTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    @Test("Amounts with a unit follow the serving count")
    func amountsScale() {
        #expect(AmountScaler.scaled("300 g Tomaten würfeln", by: 2, formatter: formatter)
            == "600 g Tomaten würfeln")
        #expect(AmountScaler.scaled("1 EL Öl erhitzen", by: 3, formatter: formatter)
            == "3 EL Öl erhitzen")
        #expect(AmountScaler.scaled("½ TL Salz zugeben", by: 2, formatter: formatter)
            == "1 TL Salz zugeben")
    }

    @Test("Temperatures and times are never scaled")
    func timesAndTemperaturesAreLeftAlone() {
        #expect(AmountScaler.scaled("Bei 180 Grad backen", by: 2, formatter: formatter)
            == "Bei 180 Grad backen")
        #expect(AmountScaler.scaled("20 Minuten schmoren", by: 2, formatter: formatter)
            == "20 Minuten schmoren")
        #expect(AmountScaler.scaled("30 Sekunden blanchieren", by: 4, formatter: formatter)
            == "30 Sekunden blanchieren")
    }

    @Test("A bare number is not an amount")
    func bareNumbers() {
        #expect(AmountScaler.scaled("In 2 Hälften schneiden", by: 2, formatter: formatter)
            == "In 2 Hälften schneiden")
    }

    @Test("A factor of one changes nothing")
    func identity() {
        let text = "300 g Tomaten würfeln"
        #expect(AmountScaler.scaled(text, by: 1, formatter: formatter) == text)
    }

    @Test("Step text scales with the recipe's servings")
    func stepTextScales() {
        let recipe = Recipe(
            title: "Pfanne",
            servings: 2,
            instructionsText: "300 g Tomaten würfeln und 20 Minuten schmoren"
        )
        let step = recipe.steps[0]

        #expect(recipe.scaledStepText(step, toServings: 4).contains("600 g"))
        #expect(recipe.scaledStepText(step, toServings: 4).contains("20 Minuten"))
        #expect(recipe.scaledStepText(step, toServings: 2) == step.text)
    }

    @Test("A step lists the ingredients it names")
    func ingredientsPerStep() {
        let recipe = Recipe(
            title: "Pfanne",
            servings: 2,
            ingredientsText: """
            300 g Tomaten
            200 g Feta
            Salz
            """,
            instructionsText: """
            Tomaten würfeln
            Feta zerbröseln und alles mischen
            """
        )

        #expect(recipe.ingredients(mentionedIn: recipe.steps[0]).map(\.name) == ["Tomaten"])
        #expect(recipe.ingredients(mentionedIn: recipe.steps[1]).map(\.name) == ["Feta"])
    }

    @Test("Ingredients named in a step are scaled too")
    func ingredientsPerStepScale() throws {
        let recipe = Recipe(
            title: "Pfanne",
            servings: 2,
            ingredientsText: "300 g Tomaten",
            instructionsText: "Tomaten würfeln"
        )

        let scaled = recipe.ingredients(mentionedIn: recipe.steps[0], scaledToServings: 6)
        #expect(try #require(scaled.first).quantity == Quantity(900, .gram))
    }
}
