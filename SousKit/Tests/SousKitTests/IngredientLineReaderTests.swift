import Foundation
import Testing
@testable import SousKit

@Suite("Ingredient line reader")
struct IngredientLineReaderTests {
    private let catalog = IngredientCatalog.bundled

    private func read(_ line: String) -> RecipeIngredient {
        IngredientLineReader.readLine(line, catalog: catalog)
    }

    // MARK: - The measure

    @Test("An amount is a number, a fraction, a mixed number or a range", arguments: [
        ("300 g Zucker", 300.0),
        ("1,5 EL Olivenöl", 1.5),
        ("0.5 TL Salz", 0.5),
        ("1/2 TL Salz", 0.5),
        ("½ TL Salz", 0.5),
        ("1 ½ TL Backpulver", 1.5),
        ("1½ TL Backpulver", 1.5),
        ("1 1/2 TL Backpulver", 1.5),
        ("10-15 Blätter Basilikum", 10.0),
        ("200ml Wasser", 200.0),
    ])
    func amounts(line: String, amount: Double) {
        let ingredient = read(line)
        #expect(!ingredient.isOutsideForm)
        #expect(ingredient.quantity?.amount == amount)
    }

    @Test("A unit is any spelling from the list, the new ones included")
    func units() {
        #expect(read("2 Esslöffel Olivenöl").quantity == Quantity(2, .tablespoon))
        #expect(read("2 Zweig/e Rosmarin").quantity == Quantity(2, .sprig))
        #expect(read("1 Spritzer Zitronensaft").quantity == Quantity(1, .splash))
        #expect(read("1 Spritzer Zitronensaft").name == "Zitronensaft")
        #expect(read("0.5 Köpfe Weißkohl").quantity == Quantity(0.5, .head))
        #expect(read("1 Kopf Weißkohl").name == "Weißkohl")
        // No unit is a count.
        #expect(read("2 Zwiebeln").quantity == Quantity(2, .piece))
    }

    @Test("A size word belongs to the amount")
    func sizeWord() {
        let ingredient = read("2 große Zwiebeln, gehackt")
        #expect(ingredient.size?.degree == .large)
        #expect(ingredient.name == "Zwiebeln")
        #expect(ingredient.preparation == "gehackt")
    }

    @Test("The measure's length colours the editor, and needs no known name")
    func measureLength() {
        // Up to the name, the space before it included — as the editor
        // always coloured it.
        #expect(IngredientLineReader.measure(in: "300 g Toma", catalog: catalog)?.length == 6)
        #expect(IngredientLineReader.measure(in: "2 kleine EL Zucker", catalog: catalog)?.length == 12)
        #expect(IngredientLineReader.measure(in: "Salz", catalog: catalog) == nil)
    }

    // MARK: - Name and annotation

    @Test("Everything after the comma that follows a known name is the annotation")
    func annotation() {
        let lime = read("½ Limette, Saft davon, optional")
        #expect(!lime.isOutsideForm)
        #expect(lime.name == "Limette")
        #expect(lime.preparation == "Saft davon, optional")
    }

    @Test("A state word at the start of the annotation still picks the basis")
    func stateInAnnotation() {
        let beans = read("200 g schwarze Bohnen, gekocht")
        #expect(beans.state == .cooked)
        #expect(read("200 g schwarze Bohnen").state == .unspecified)
    }

    /// The BLS way of writing names: a qualifier after the name, commas in
    /// the name itself.
    private let blsCatalog = IngredientCatalog(ingredients: [
        CatalogIngredient(name: "Tomate", aliases: ["Tomaten"], category: .vegetables),
        CatalogIngredient(name: "Tomate Konserve", aliases: ["Tomaten Konserve"], category: .canned),
        CatalogIngredient(name: "Sauerrahm/Schmand, mind. 20 % Fett", category: .dairy),
    ])

    @Test("A qualifier in the annotation still names its own row")
    func qualifierInAnnotation() {
        let tomatoes = IngredientLineReader.readLine("400 g Tomaten, Konserve", catalog: blsCatalog)
        #expect(tomatoes.name == "Tomaten")
        #expect(blsCatalog.nutritionName(for: tomatoes) == "Tomate Konserve")
    }

    @Test("The annotation is never part of the name: no variety is turned round")
    func noQualifierTurn() {
        let onion = read("1 Zwiebel, rot")
        #expect(onion.name == "Zwiebel")
        #expect(onion.preparation == "rot")
        // Written as the variety, it is the variety.
        #expect(catalog.ingredient(for: read("1 rote Zwiebel").name)?.name == "Rote Zwiebel")
    }

    @Test("A name that carries its own comma stays whole, and can still take an annotation")
    func longestKnownWritingWins() {
        let name = "Sauerrahm/Schmand, mind. 20 % Fett"
        let read = { IngredientLineReader.readLine($0, catalog: blsCatalog) }
        #expect(read("200 g \(name)").name == name)
        let chilled = read("200 g \(name), kalt")
        #expect(chilled.name == name)
        #expect(chilled.preparation == "kalt")
    }

    @Test("A plural glued on in parentheses is closed grammar")
    func gluedPlural() {
        let aubergines = read("2 große Aubergine(n)")
        #expect(!aubergines.isOutsideForm)
        #expect(aubergines.name == "Auberginen")
        #expect(read("1 Bund Frühlingszwiebel(n), in Ringen").preparation == "in Ringen")
    }

    @Test("A recipe link is a name, and may take an annotation")
    func link() {
        let link = "[Naan](sous://recipe/2F1B6C1E-0000-0000-0000-000000000000)"
        #expect(!read("1 Portion \(link)").isOutsideForm)
        #expect(read("1 Portion \(link), warm").preparation == "warm")
        #expect(read("1 Portion \(link) warm").isOutsideForm)
    }

    @Test("Sales forms the export wrote are known words now")
    func salesForms() {
        for line in ["15 g frische Minze", "125 g entsteinte Datteln", "3 frische Lorbeerblätter",
                     "1,5 cm frische Kurkuma", "100 g frischer Spinat", "1 Bund frischer Koriander",
                     "15 g frische glatte Petersilie", "1 EL frischer Ingwer"] {
            #expect(!read(line).isOutsideForm, "\(line)")
        }
    }

    // MARK: - Outside the form

    @Test("A line outside the form keeps its words and its amount, and says so", arguments: [
        ("1 TL frisch geriebener Ingwer", "frisch geriebener Ingwer"),
        ("1 Chili (rot)", "Chili (rot)"),
        ("300 g Zwiebeln gegart", "Zwiebeln gegart"),
        ("Salz nach Geschmack", "Salz nach Geschmack"),
        ("150 g Einhornstaub", "Einhornstaub"),
    ])
    func outsideForm(line: String, words: String) {
        let ingredient = read(line)
        #expect(ingredient.isOutsideForm)
        #expect(ingredient.name == words)
        #expect(ingredient.preparation == nil)
        #expect(ingredient.state == .unspecified)
    }

    @Test("Outside the form, the amount still scales")
    func outsideFormScales() {
        let recipe = Recipe(title: "Dal", servings: 2, ingredientsText: "300 ml dünne Kokosmilch (oder mehr)")
        let scaled = recipe.scaledIngredients(toServings: 4, catalog: catalog)
        #expect(scaled.first?.isOutsideForm == true)
        #expect(scaled.first?.quantity == Quantity(600, .milliliter))
    }

    @Test("The household's own words are known when its catalog is the one asked")
    func householdCatalog() {
        let own = CatalogIngredient(name: "Seitan-Mix", category: .other)
        let household = IngredientCatalog(ingredients: [own] + IngredientCatalog.bundled.ingredients)
        #expect(IngredientLineReader.readLine("200 g Seitan-Mix", catalog: .bundled).isOutsideForm)
        #expect(!IngredientLineReader.readLine("200 g Seitan-Mix", catalog: household).isOutsideForm)
        let recipe = Recipe(title: "Gyros", ingredientsText: "200 g Seitan-Mix")
        #expect(recipe.ingredients(readWith: household).first?.isOutsideForm == false)
    }

    // MARK: - Lists

    @Test("Headings group lines as before, and the old parser numbers alike")
    func headings() {
        let text = "# Für den Teig\n200 g Mehl\n\nFür die Soße:\n1 Zwiebel\n300 g Tomaten:"
        let lines = IngredientLineReader.read(text, catalog: catalog)
        #expect(lines.map(\.group) == ["Für den Teig", "Für die Soße", "Für die Soße"])
        #expect(IngredientParser.writtenLines(in: text).map(\.text)
            == IngredientLineReader.writtenLines(in: text).map(\.text))
    }

    @Test("Every line in the fixed form reads the same in the old parser")
    func oldAppsReadTheFixedForm() {
        for line in ["½ Limette, Saft davon, optional", "2 rote Zwiebeln", "250 g rote Linsen, getrocknet",
                     "1 Dose Kidneybohnen, Abtropfgewicht 500 g", "200 g schwarze Bohnen, gekocht",
                     "Salz, nach Geschmack", "400 g Tomaten, TK"] {
            let strict = read(line)
            let old = IngredientParser.parseLine(line, catalog: catalog)
            #expect(catalog.ingredient(for: strict.name)?.name == catalog.ingredient(for: old.name)?.name, "\(line)")
            #expect(strict.quantity == old.quantity, "\(line)")
            #expect(strict.state == old.state, "\(line)")
            #expect(catalog.nutritionName(for: strict) == catalog.nutritionName(for: old), "\(line)")
        }
    }
}
