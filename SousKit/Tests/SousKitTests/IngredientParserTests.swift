import Foundation
import Testing
@testable import SousKit

@Suite("Ingredient parsing")
struct IngredientParserTests {
    @Test("A written line becomes amount, unit, name and preparation")
    func fullLine() {
        let ingredient = IngredientParser.parseLine("300 g Zucchini, fein gehackt")

        #expect(ingredient.quantity == Quantity(300, .gram))
        #expect(ingredient.name == "Zucchini")
        #expect(ingredient.preparation == "fein gehackt")
    }

    @Test("A catalog name that carries its own comma is not split at it")
    func commaInsideACatalogName() {
        // The BLS writes a product's qualifier into the name itself, so the
        // comma here is not the "name, preparation" comma above. 974 of the
        // 2661 bundled names look like this.
        let ingredient = IngredientParser.parseLine("Sauerrahm/Schmand, mind. 20 % Fett")

        #expect(ingredient.name == "Sauerrahm/Schmand, mind. 20 % Fett")
        #expect(ingredient.preparation == nil)
    }

    @Test("An amount still comes off a catalog name that carries a comma")
    func commaInsideACatalogNameWithAmount() {
        let ingredient = IngredientParser.parseLine("150 g Sauerrahm/Schmand, mind. 20 % Fett")

        #expect(ingredient.quantity == Quantity(150, .gram))
        #expect(ingredient.name == "Sauerrahm/Schmand, mind. 20 % Fett")
        #expect(ingredient.preparation == nil)
    }

    @Test("A comma the catalog does not know still separates a preparation")
    func commaOutsideACatalogNameStillSplits() {
        // "Zwiebel, rot" is not a catalog name, so the old reading stands
        // and the bare "Zwiebel" is what gets looked up.
        let ingredient = IngredientParser.parseLine("1 Zwiebel, rot")

        #expect(ingredient.name == "Zwiebel")
        #expect(ingredient.preparation == "rot")
    }

    @Test("A count without a unit is a piece")
    func bareCount() {
        let ingredient = IngredientParser.parseLine("2 Zwiebeln")

        #expect(ingredient.quantity == Quantity(2, .piece))
        #expect(ingredient.name == "Zwiebeln")
    }

    @Test("An unknown word after the amount stays part of the name")
    func unknownUnitIsName() {
        let ingredient = IngredientParser.parseLine("2 Handvoll Spinat")

        #expect(ingredient.quantity == Quantity(2, .piece))
        #expect(ingredient.name == "Handvoll Spinat")
    }

    @Test("A line without an amount keeps its whole text")
    func noAmount() {
        let ingredient = IngredientParser.parseLine("Salz")

        #expect(ingredient.quantity == nil)
        #expect(ingredient.name == "Salz")
    }

    @Test("Decimals, fractions and mixed numbers are all understood")
    func numberForms() {
        #expect(IngredientParser.parseLine("1,5 kg Kartoffeln").quantity == Quantity(1.5, .kilogram))
        #expect(IngredientParser.parseLine("1/2 TL Kreuzkümmel").quantity == Quantity(0.5, .teaspoon))
        #expect(IngredientParser.parseLine("½ TL Zimt").quantity == Quantity(0.5, .teaspoon))
        #expect(IngredientParser.parseLine("200ml Sahne").quantity == Quantity(200, .milliliter))

        let mixed = IngredientParser.parseLine("1 ½ EL Zucker")
        #expect(mixed.quantity == Quantity(1.5, .tablespoon))
        #expect(mixed.name == "Zucker")
    }

    @Test("A range takes its lower bound")
    func range() {
        let ingredient = IngredientParser.parseLine("3-4 Tomaten")

        #expect(ingredient.quantity == Quantity(3, .piece))
        #expect(ingredient.name == "Tomaten")
    }

    @Test("A range with a unit between the numbers and the name still splits correctly")
    func rangeWithUnit() {
        // "Blätter" must be a recognized unit, or the whole "Blätter
        // Basilikum" ends up as the name — leaving nothing in the recipe
        // that can ever match a bare "Basilikum" mentioned in a step.
        let ingredient = IngredientParser.parseLine("10-15 Blätter Basilikum")

        #expect(ingredient.quantity == Quantity(10, .leaf))
        #expect(ingredient.name == "Basilikum")
    }

    @Test("Headings open a group for the lines that follow")
    func groups() {
        let ingredients = IngredientParser.parse("""
        Für den Teig:
        300 g Mehl
        1 Ei

        # Für die Sauce
        200 ml Sahne

        Salz
        """)

        #expect(ingredients.map(\.name) == ["Mehl", "Ei", "Sahne", "Salz"])
        #expect(ingredients.map(\.group) == ["Für den Teig", "Für den Teig", "Für die Sauce", "Für die Sauce"])
    }

    @Test("A line with an amount is not mistaken for a heading")
    func quantifiedLineIsNotAHeading() {
        let ingredients = IngredientParser.parse("300 g Tomaten:")

        #expect(ingredients.count == 1)
        #expect(ingredients[0].quantity == Quantity(300, .gram))
    }

    @Test("Parsed lines render back to the text they came from")
    func roundTrip() {
        let source = """
        # Für den Teig
        300 g Mehl
        1 ½ EL Zucker
        2 Eier (verquirlt)

        # Für die Sauce
        200 ml Sahne
        Salz
        """

        let ingredients = IngredientParser.parse(source)
        let rendered = IngredientParser.text(
            for: ingredients,
            formatter: QuantityFormatter(locale: Locale(identifier: "de_DE"))
        )
        #expect(rendered == source)
    }
}

extension IngredientParserTests {
    @Test("Parsing the same text twice yields equal values")
    func parsingIsDeterministic() {
        let text = "300 g Zucchini\n100 g Feta"

        #expect(IngredientParser.parse(text) == IngredientParser.parse(text))
        #expect(StepParser.parse("Schneiden\nAnbraten") == StepParser.parse("Schneiden\nAnbraten"))
    }

    @Test("Identity follows the line, not the recipe it sits in")
    func identityFollowsContent() {
        let first = IngredientParser.parse("300 g Zucchini")
        let changed = IngredientParser.parse("400 g Zucchini")

        #expect(first[0].id != changed[0].id)
    }
}

extension IngredientParserTests {
    @Test("A comment in parentheses is the preparation, the way Mela writes it")
    func parenthesizedComment() {
        let ingredient = IngredientParser.parseLine("300 g Zucchini (fein gehackt)")

        #expect(ingredient.name == "Zucchini")
        #expect(ingredient.preparation == "fein gehackt")
    }

    @Test("Both group syntaxes are accepted")
    func groupSyntaxes() {
        let hash = IngredientParser.parse("# Teig\n300 g Mehl")
        let colon = IngredientParser.parse("Teig:\n300 g Mehl")

        #expect(hash[0].group == "Teig")
        #expect(colon[0].group == "Teig")
    }
}

extension IngredientParserTests {
    @Test("A markdown link is not mistaken for a comment in parentheses")
    func linkIsNotAComment() {
        let id = UUID()
        let line = "1 Portion \(RecipeLink.markdown(title: "Naan", id: id))"
        let ingredient = IngredientParser.parseLine(line)

        #expect(ingredient.quantity == Quantity(1, .portion))
        #expect(ingredient.preparation == nil)
        // The whole link stays in the name so it still renders as a link.
        #expect(ingredient.name == RecipeLink.markdown(title: "Naan", id: id))
    }

    @Test("A comment still works on a line that also carries a link")
    func linkWithComment() {
        let id = UUID()
        let line = "\(RecipeLink.markdown(title: "Naan", id: id)), lauwarm"
        let ingredient = IngredientParser.parseLine(line)

        #expect(ingredient.preparation == "lauwarm")
        #expect(ingredient.name == RecipeLink.markdown(title: "Naan", id: id))
    }
}

extension IngredientParserTests {
    @Test("The amount-and-unit span is measured for highlighting while typing")
    func highlightSpan() {
        func prefix(_ line: String) -> String? {
            guard let length = IngredientParser.leadingAmountAndUnitLength(in: line) else { return nil }
            return String(line.trimmingCharacters(in: .whitespaces).prefix(length))
        }
        #expect(prefix("300 g Zucchini") == "300 g ")
        #expect(prefix("2 Zwiebeln") == "2 ")
        #expect(prefix("  1 Zehe Knoblauch") == "1 Zehe ")
        #expect(IngredientParser.leadingAmountAndUnitLength(in: "Salz") == nil)
    }
}
