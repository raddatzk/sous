import Foundation

/// A recipe rewritten by a chat model at the cook's request — "make it
/// vegan", "for four" — read back whole.
///
/// The counterpart to ``RecipeOptimization``: that one may only tidy lines
/// and Sous checks every word, this one is *meant* to change ingredients,
/// amounts and steps, so all Sous checks is that a complete recipe came back.
/// What the cook takes of it, and whether it replaces the recipe or becomes a
/// second one, is theirs to decide afterwards.
public struct RecipeReplacement: Sendable, Equatable {
    public var title: String
    public var summary: String?
    public var servings: Int?
    public var categories: [String]?
    public var ingredientsText: String
    public var instructionsText: String
    public var notes: String?

    /// What a replacement carries over besides ingredients, steps and notes,
    /// which it always does.
    public struct Fields: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let title = Fields(rawValue: 1)
        public static let summary = Fields(rawValue: 2)
        public static let servings = Fields(rawValue: 4)
        public static let categories = Fields(rawValue: 8)

        /// The title is what a recipe is recognised by, so it stays unless
        /// the cook asks for the new one; the rest describes the content.
        public static let standard: Fields = [.summary, .servings, .categories]
        public static let all: Fields = [.title, .summary, .servings, .categories]
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noAnswer
        /// The cook pasted the prompt Sous copied, not the chat's answer —
        /// whose example JSON would otherwise be read as one.
        case pastedThePrompt
        case unreadable
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case .noAnswer:
                "In der Antwort steht kein JSON-Block. Bitte die KI um das Rezept als JSON bitten und die Antwort erneut einfügen."
            case .pastedThePrompt:
                "Eingefügt wurde der Prompt selbst, nicht die Antwort des Chats. Bitte die Antwort des Chats kopieren — am besten den JSON-Block."
            case .unreadable:
                "Das JSON ist nicht lesbar. Bitte die KI bitten, das Rezept im vorgegebenen Format erneut auszugeben."
            case .missing(let what):
                "Im Rezept fehlt \(what). Bitte die KI um eine vollständige Antwort bitten."
            }
        }
    }

    /// What `fields` says of this replacement, applied to `recipe`'s content.
    func applied(to recipe: Recipe, fields: Fields) -> Recipe {
        var result = recipe
        if fields.contains(.title) { result.title = title }
        if fields.contains(.summary) { result.summary = summary }
        if fields.contains(.servings), let servings { result.servings = servings }
        if fields.contains(.categories), let categories { result.categories = categories }
        result.ingredientsText = ingredientsText
        result.instructionsText = instructionsText
        result.notes = notes
        result.stepReferences = nil
        return result
    }
}

public enum RecipeReplacementPrompt {
    /// The answer's shape, one example the model copies.
    static let format = """
    ```json
    {"titel": "Vegane Linsensuppe", "beschreibung": "Cremig und würzig.", "portionen": 4, "kategorien": ["Suppe", "Vegan"], "zutaten": ["# Für die Suppe", "250 g rote Linsen", "1 Zwiebel"], "zubereitung": ["# Suppe", "Zwiebel würfeln und anschwitzen.", "Linsen zugeben und 15 Minuten kochen."], "notizen": "Hält sich 3 Tage im Kühlschrank."}
    ```
    """

    /// The rules' first sentence, which marks a pasted prompt.
    static let promptMarker = "Du arbeitest ein Rezept für die App Sous um."

    static let rules = """
    \(promptMarker) Antworte so:

    1. Zeige mir das umgearbeitete Rezept gut lesbar (Titel, Portionen, \
    Zutaten, Zubereitung) und erkläre kurz, was du geändert hast und warum. \
    Wir können danach darüber sprechen und es weiter anpassen.
    2. Hänge in JEDER Antwort, in der du ein Rezept zeigst, am Ende den \
    aktuellen Stand als JSON-Codeblock an, genau in dieser Form, damit ich ihn \
    kopieren und in Sous einfügen kann:

    \(format)

    Regeln für das JSON: "zutaten" und "zubereitung" sind Listen mit einer \
    Zeile pro Eintrag. Eine Zutat steht als "Menge Einheit Zutat" \
    ("250 g rote Linsen", "1 Zwiebel"), ohne Zubereitung in der Zeile — die \
    gehört in die Schritte. Eine Zeile "# Name" eröffnet eine Gruppe. \
    "beschreibung", "kategorien" und "notizen" dürfen fehlen. Schreibe \
    "portionen" als ganze Zahl.

    Orientiere dich bei den Zutatennamen am Katalog unten: Nimm den dort \
    stehenden Namen, wo er passt (also "Hafermilch" statt "pflanzliche \
    Milch"). Fehlt eine Zutat im Katalog, schreibe sie trotzdem.
    """

    /// The whole text to copy: the rules, the catalog, the task, the recipe.
    ///
    /// `task` is what the cook asked for — a saved template's text or a line
    /// they typed. A `{{recipe}}` in it marks where the recipe stands;
    /// without one, the recipe follows the task.
    public static func prompt(
        task: String,
        for recipe: Recipe,
        catalog: IngredientCatalog = .current
    ) -> String {
        let recipeText = text(of: recipe)
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = trimmed.contains(placeholder)
            ? trimmed.replacingOccurrences(of: placeholder, with: recipeText)
            : "\(trimmed)\n\n\(recipeText)"
        return "\(rules)\n\n\(RecipeOptimizationPrompt.catalogList(catalog))\n\nAufgabe:\n\(request)"
    }

    /// Where a template says the recipe goes.
    public static let placeholder = "{{recipe}}"

    /// The recipe as the model reads it: the same shape the answer has.
    static func text(of recipe: Recipe) -> String {
        var text = "Titel: \(recipe.title)\nPortionen: \(recipe.servings)\n"
        if let summary = recipe.summary, !summary.isEmpty { text += "Beschreibung: \(summary)\n" }
        if !recipe.categories.isEmpty { text += "Kategorien: \(recipe.categories.joined(separator: ", "))\n" }
        text += "\nZutaten:\n\(recipe.ingredientsText.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        text += "\nZubereitung:\n\(recipe.instructionsText.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if let notes = recipe.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            text += "\nNotizen:\n\(notes)\n"
        }
        return text
    }

    private struct Answer: Decodable {
        var titel: String?
        var beschreibung: String?
        var portionen: Int?
        var kategorien: [String]?
        var zutaten: [String]?
        var zubereitung: [String]?
        var notizen: String?
    }

    /// Reads the JSON block out of a chat answer.
    ///
    /// From the first `{` to the last `}`, as the optimizer does, so a
    /// ```json fence and the prose around it do not matter. What makes it
    /// through has a title, ingredients and steps; the rest is optional.
    public static func read(_ pasted: String) -> Result<RecipeReplacement, RecipeReplacement.Failure> {
        if pasted.contains(promptMarker) { return .failure(.pastedThePrompt) }
        guard let open = pasted.firstIndex(of: "{"), let close = pasted.lastIndex(of: "}"), open < close else {
            return .failure(.noAnswer)
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(pasted[open...close].utf8)) else {
            return .failure(.unreadable)
        }
        guard let title = clean(answer.titel) else { return .failure(.missing("der Titel")) }
        let ingredients = lines(answer.zutaten)
        guard !ingredients.isEmpty else { return .failure(.missing("die Zutatenliste")) }
        let steps = lines(answer.zubereitung)
        guard !steps.isEmpty else { return .failure(.missing("die Zubereitung")) }

        return .success(RecipeReplacement(
            title: title,
            summary: clean(answer.beschreibung),
            servings: answer.portionen.flatMap { (1...100).contains($0) ? $0 : nil },
            categories: answer.kategorien.map { $0.compactMap(clean) },
            ingredientsText: ingredients.joined(separator: "\n"),
            instructionsText: steps.joined(separator: "\n"),
            notes: clean(answer.notizen)
        ))
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The non-empty lines, each on a single line.
    private static func lines(_ list: [String]?) -> [String] {
        (list ?? []).flatMap { $0.split(whereSeparator: \.isNewline) }
            .compactMap { clean(String($0)) }
    }
}
