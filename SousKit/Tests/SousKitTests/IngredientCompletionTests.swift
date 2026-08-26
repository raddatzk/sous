import Foundation
import Testing
@testable import SousKit

@Suite("Completing ingredient lines")
struct IngredientCompletionTests {
    private let catalog = IngredientCatalog.bundled

    private func line(_ text: String, cursorAtEnd: Bool = true) -> String {
        let range = IngredientCompletion.lineRange(
            in: text,
            at: cursorAtEnd ? text.endIndex : text.startIndex
        )
        return String(text[range])
    }

    @Test("The cursor's line is found among the others")
    func lineAtCursor() {
        let text = "300 g Tomaten\n2 EL Oliven\n1 Prise Salz"
        let cursor = text.index(text.startIndex, offsetBy: 20)

        let range = IngredientCompletion.lineRange(in: text, at: cursor)
        #expect(String(text[range]) == "2 EL Oliven")
    }

    @Test("The amount and unit are not part of what is being completed")
    func partialName() {
        #expect(IngredientCompletion.partialName(in: "300 g Toma") == "Toma")
        #expect(IngredientCompletion.partialName(in: "Toma") == "Toma")
        #expect(IngredientCompletion.partialName(in: "2 EL Ol") == "Ol")
    }

    @Test("Headings, links and near-empty lines are left alone")
    func nothingToSuggest() {
        #expect(IngredientCompletion.partialName(in: "# Für den Teig") == nil)
        #expect(IngredientCompletion.partialName(in: "Für den Teig:") == nil)
        #expect(IngredientCompletion.partialName(in: "300 g T") == nil)
        #expect(IngredientCompletion.partialName(in: "") == nil)
        #expect(IngredientCompletion.partialName(
            in: "1 Portion \(RecipeLink.markdown(title: "Naan", id: UUID()))"
        ) == nil)
    }

    @Test("Suggestions match what is being typed")
    func suggestions() throws {
        let matches = IngredientCompletion.suggestions(forLine: "300 g Toma", catalog: catalog)
        #expect(matches.contains { $0.name == "Tomate" })
        #expect(matches.count <= 6)
    }

    @Test("A name already written out is not offered again")
    func noSuggestionsWhenComplete() {
        #expect(IngredientCompletion.suggestions(forLine: "300 g Tomaten", catalog: catalog).isEmpty)
        #expect(IngredientCompletion.suggestions(forLine: "300 g Tomate", catalog: catalog).isEmpty)
    }

    @Test("An ingredient already written out elsewhere is not suggested again")
    func noSuggestionForNameUsedOnAnotherLine() {
        let text = "1 Tomate\n2 Toma"
        let matches = IngredientCompletion.suggestions(forLine: "2 Toma", in: text, catalog: catalog)

        #expect(!matches.contains { $0.name == "Tomate" })
        #expect(!matches.isEmpty)
    }

    @Test("A suggestion whose name carries a comma survives being read back")
    func acceptedCommaNameStaysKnown() throws {
        // "Schmand" is a spelling of this row rather than its name since the
        // slashed BLS names were split — the word is "Sauerrahm, mind. 20 %
        // Fett" and "Sauerrahm/Schmand, mind. 20 % Fett" still reaches it.
        // What this test is about is the comma in the middle of it.
        let schmand = try #require(catalog.ingredient(for: "Schmand, mind. 20 % Fett"))
        #expect(schmand.name.contains(","))
        let completed = IngredientCompletion.completed(line: "schmand", with: schmand)

        // What the editor writes into the text …
        #expect(completed == "Sauerrahm, mind. 20 % Fett")
        // … has to read back as that same ingredient, not as a truncated
        // name plus a "preparation", or it re-reports as unknown and drops
        // out of the recipe's nutrition.
        let parsed = IngredientParser.parseLine(completed, catalog: catalog)
        #expect(parsed.name == "Sauerrahm, mind. 20 % Fett")
        #expect(parsed.preparation == nil)
        #expect(catalog.unknownIngredients(in: completed).isEmpty)
    }

    @Test("Taking a suggestion keeps the amount and what follows the name")
    func completingALine() {
        let tomato = CatalogIngredient(name: "Tomate", category: .vegetables)

        #expect(IngredientCompletion.completed(line: "300 g Toma", with: tomato) == "300 g Tomate")
        #expect(IngredientCompletion.completed(line: "Toma", with: tomato) == "Tomate")
        #expect(
            IngredientCompletion.completed(line: "300 g Toma (gewürfelt)", with: tomato)
                == "300 g Tomate (gewürfelt)"
        )
    }

    @Test("Completing a line leaves the rest of the text untouched")
    func completingWithinAText() {
        let text = "300 g Mehl\n2 Zwie\n1 Prise Salz"
        let cursor = text.index(text.startIndex, offsetBy: 17)
        let range = IngredientCompletion.lineRange(in: text, at: cursor)

        let completed = IngredientCompletion.completed(
            line: String(text[range]),
            with: CatalogIngredient(name: "Zwiebel", category: .vegetables)
        )
        let result = text.replacingCharacters(in: range, with: completed)

        #expect(result == "300 g Mehl\n2 Zwiebel\n1 Prise Salz")
    }
}
