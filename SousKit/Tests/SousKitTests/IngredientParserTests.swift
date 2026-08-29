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

    /// A catalog with names of the shape the rules below are about.
    ///
    /// Built here rather than taken from the bundled one. It used to be the
    /// bundled one, because the shipped vocabulary held 974 names with a
    /// comma in them — every BLS row name was in it. The kitchen's own list
    /// has none, by rule, and the names that look like this now are the ones
    /// a cook writes down themselves. So the rule is worth keeping and the
    /// example has to be made rather than found.
    private let catalog = IngredientCatalog(ingredients: [
        CatalogIngredient(name: "Sauerrahm/Schmand, mind. 20 % Fett", category: .dairy),
        CatalogIngredient(name: "Erbse grün, tiefgefroren", category: .frozen),
        CatalogIngredient(name: "Apfel getrocknet", category: .fruit),
        CatalogIngredient(name: "Kartoffel geschält, gekocht, Konserve, abgetropft", category: .canned),
        CatalogIngredient(name: "Kartoffel geschält", category: .vegetables),
        CatalogIngredient(name: "Tomate Konserve", aliases: ["Tomaten Konserve"], category: .canned),
        CatalogIngredient(name: "Tomate", aliases: ["Tomaten"], category: .vegetables),
        CatalogIngredient(name: "Zwiebel", category: .vegetables),
    ])

    @Test("A catalog name that carries its own comma is not split at it")
    func commaInsideACatalogName() {
        // The comma here belongs to the name, not to a "name, preparation"
        // reading, and the parser can only tell the two apart by asking.
        let ingredient = IngredientParser.parseLine(
            "Sauerrahm/Schmand, mind. 20 % Fett", catalog: catalog
        )

        #expect(ingredient.name == "Sauerrahm/Schmand, mind. 20 % Fett")
        #expect(ingredient.preparation == nil)
    }

    @Test("An amount still comes off a catalog name that carries a comma")
    func commaInsideACatalogNameWithAmount() {
        let ingredient = IngredientParser.parseLine(
            "150 g Sauerrahm/Schmand, mind. 20 % Fett", catalog: catalog
        )

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

    @Test("A state after the comma is read, and left where it was written")
    func stateAfterComma() {
        let ingredient = IngredientParser.parseLine("500 g Kartoffeln, gegart")

        #expect(ingredient.name == "Kartoffeln")
        #expect(ingredient.state == .cooked)
        // The word stays in the preparation: the line has to render back as
        // it was typed, and the state is read from it, not taken out of it.
        #expect(ingredient.preparation == "gegart")
    }

    @Test("A state written bare after the name is read the same way")
    func stateAfterNameWithoutComma() {
        let ingredient = IngredientParser.parseLine("500 g Kartoffeln gegart")

        // Moved into the preparation so both writings arrive in one shape —
        // and so the name is a name again and can be found in the catalog.
        #expect(ingredient.name == "Kartoffeln")
        #expect(ingredient.state == .cooked)
        #expect(ingredient.preparation == "gegart")
    }

    @Test("A state in parentheses is read too")
    func stateInParentheses() {
        let ingredient = IngredientParser.parseLine("300 g Linsen (gekocht)")

        #expect(ingredient.name == "Linsen")
        #expect(ingredient.state == .cooked)
    }

    @Test("\"roh\" is its own state, not the same as saying nothing")
    func rawIsItsOwnState() {
        #expect(IngredientParser.parseLine("200 g Spinat, roh").state == .raw)
        #expect(IngredientParser.parseLine("200 g Spinat").state == .unspecified)
    }

    @Test("A preparation that only mentions a state word in passing is not one")
    func stateOnlyCountsAsTheFirstWord() {
        // "in Streifen gebraten" is a way of cutting something, not the claim
        // that the amount was weighed after frying — reading it as one would
        // silently move the numbers of every line written that way.
        let ingredient = IngredientParser.parseLine("300 g Hähnchenbrust, in Streifen gebraten")

        #expect(ingredient.state == .unspecified)
        #expect(ingredient.name == "Hähnchenbrust")
    }

    @Test("A catalog name that ends in a state word is not taken apart")
    func catalogNameEndingInAStateWord() {
        // 649 of the shipped names end in one of these words. Splitting them
        // is the very thing the comma rule exists to prevent, so the trailing
        // rule asks the catalog first, exactly as the comma rule does.
        for name in [
            "Erbse grün, tiefgefroren", "Apfel getrocknet",
            "Kartoffel geschält, gekocht, Konserve, abgetropft",
        ] {
            let ingredient = IngredientParser.parseLine("100 g \(name)", catalog: catalog)
            #expect(ingredient.name == name, "\(name) was split")
            #expect(ingredient.preparation == nil)
        }
    }

    @Test("A catalog name plus a state word splits into exactly that")
    func catalogNamePlusAState() {
        // "Kartoffel geschält" is a word; "Kartoffel geschält, gekocht" is
        // not — the shipped word carries both its states as bases. So the
        // comma rule splits here, which is right: the name resolves and the
        // state picks the cooked one of the two rows behind it.
        let ingredient = IngredientParser.parseLine(
            "500 g Kartoffel geschält, gekocht", catalog: catalog
        )

        #expect(ingredient.name == "Kartoffel geschält")
        #expect(ingredient.state == .cooked)
    }

    @Test("A qualifier is not a state — it picks a different food")
    func qualifiersAreNotStates() {
        // Decision E1: `IngredientState` is the raw/cooked axis, because that
        // is the axis the shipped bases are filed along. Canned tomatoes are
        // their own word in the catalog, so the qualifier resolves a *name*.
        let ingredient = IngredientParser.parseLine("400 g Tomaten, Konserve", catalog: catalog)

        #expect(ingredient.name == "Tomaten")
        #expect(ingredient.state == .unspecified)
        #expect(catalog.nutritionName(for: ingredient) == "Tomate Konserve")
    }

    @Test("A qualifier the catalog has no word for falls back to the plain food")
    func unknownQualifiedNameFallsBack() {
        // "Erbse tiefgefroren" is not a word — the catalog writes "Erbse
        // grün, tiefgefroren". Counting the line as peas is closer than
        // counting it as nothing.
        let ingredient = IngredientParser.parseLine("300 g Erbsen, TK")

        #expect(IngredientCatalog.bundled.nutritionName(for: ingredient) == "Erbse")
    }

    @Test("A line that is only a state word keeps it as its name")
    func aBareStateWordIsNotASplit() {
        // "roh" alone is a line that says nothing; splitting it would leave
        // an ingredient with no name at all.
        let ingredient = IngredientParser.parseLine("roh")

        #expect(ingredient.name == "roh")
        #expect(ingredient.preparation == nil)
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

    @Test("Container words are units, not the front half of a name")
    func containerWordsAreUnits() {
        let can = IngredientParser.parseLine("1 Dose Kokosmilch")
        #expect(can.quantity == Quantity(1, .can))
        #expect(can.name == "Kokosmilch")

        let stalks = IngredientParser.parseLine("2 Stangen Lauch")
        #expect(stalks.quantity == Quantity(2, .stalk))
        #expect(stalks.name == "Lauch")

        let jar = IngredientParser.parseLine("1 Glas getrocknete Tomaten")
        #expect(jar.quantity == Quantity(1, .jar))
        #expect(jar.name == "getrocknete Tomaten")

        let package = IngredientParser.parseLine("1 Pkg Blätterteig")
        #expect(package.quantity == Quantity(1, .package))
        #expect(package.name == "Blätterteig")

        let length = IngredientParser.parseLine("2 cm Ingwer")
        #expect(length.quantity == Quantity(2, .centimeter))
        #expect(length.name == "Ingwer")

        let sprigs = IngredientParser.parseLine("2 Zweig/e Rosmarin")
        #expect(sprigs.quantity == Quantity(2, .sprig))
        #expect(sprigs.name == "Rosmarin")

        // The Chefkoch export writes its plural markers with a slash.
        let cloves = IngredientParser.parseLine("4 Zehe/n Knoblauch")
        #expect(cloves.quantity == Quantity(4, .clove))
        #expect(cloves.name == "Knoblauch")
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

extension IngredientParserTests {
    @Test("A trailing phrase in place of a number leaves the name clean")
    func trailingUnquantifiedPhrase() {
        let ingredient = IngredientParser.parseLine("Salz nach Geschmack")

        #expect(ingredient.name == "Salz")
        #expect(ingredient.quantity == nil)
        #expect(ingredient.unquantifiedPhrase == UnquantifiedPhrase(phrase: "nach Geschmack", placement: .afterName))
    }

    @Test("\"nach Belieben\" reads the same way, case-insensitively")
    func nachBeliebenIsUnquantified() {
        let ingredient = IngredientParser.parseLine("Frische Kräuter NACH BELIEBEN")

        #expect(ingredient.name == "Frische Kräuter")
        #expect(ingredient.unquantifiedPhrase == UnquantifiedPhrase(phrase: "NACH BELIEBEN", placement: .afterName))
    }

    @Test("A leading \"etwas\" or \"einige\" is an amount in words, not part of the name")
    func leadingUnquantifiedWords() {
        let etwas = IngredientParser.parseLine("Etwas Mehl")
        #expect(etwas.name == "Mehl")
        #expect(etwas.quantity == nil)
        #expect(etwas.unquantifiedPhrase == UnquantifiedPhrase(phrase: "Etwas", placement: .beforeName))

        let einige = IngredientParser.parseLine("einige Basilikumblätter")
        #expect(einige.name == "Basilikumblätter")
        #expect(einige.unquantifiedPhrase == UnquantifiedPhrase(phrase: "einige", placement: .beforeName))
    }

    @Test("A trailing phrase also comes off a line that carries a number")
    func trailingPhraseAfterAQuantity() {
        let ingredient = IngredientParser.parseLine("1 TL Salz nach Geschmack")

        #expect(ingredient.quantity == Quantity(1, .teaspoon))
        #expect(ingredient.name == "Salz")
        #expect(ingredient.unquantifiedPhrase == UnquantifiedPhrase(phrase: "nach Geschmack", placement: .afterName))
    }

    @Test("A phrase with nothing before it stays a name")
    func phraseAloneStaysAName() {
        let ingredient = IngredientParser.parseLine("nach Geschmack")

        #expect(ingredient.name == "nach Geschmack")
        #expect(ingredient.unquantifiedPhrase == nil)
    }

    @Test("Unquantified lines render back to the text they came from")
    func unquantifiedRoundTrip() {
        let source = """
        Salz nach Geschmack
        etwas Mehl
        Pfeffer nach Belieben
        einige Basilikumblätter
        1 TL Zucker nach Geschmack
        """

        let rendered = IngredientParser.text(
            for: IngredientParser.parse(source),
            formatter: QuantityFormatter(locale: Locale(identifier: "de_DE"))
        )
        #expect(rendered == source)
    }

    @Test("A recognized phrase no longer makes the ingredient unknown")
    func unquantifiedIsNotAnUnknownIngredient() {
        let catalog = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Salz", category: .spices),
            CatalogIngredient(name: "Mehl", category: .baking),
        ])

        #expect(catalog.unknownIngredients(in: "Salz nach Geschmack\netwas Mehl").isEmpty)
    }
}
