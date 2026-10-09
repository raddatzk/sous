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
    /// Which ingredient lines each step uses, as the answer says — read
    /// against the recipe only once it is taken, since the references are
    /// stamped with the text and serving count they were read for.
    var stepReferenceItems: [StepItems] = []

    struct StepItems: Equatable, Sendable, Decodable {
        var step: Int
        var references: [StepReferencesPrompt.AnswerItem]
    }

    /// Whether the answer said which lines the steps use.
    public var hasStepReferences: Bool { !stepReferenceItems.isEmpty }

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

    /// What this replacement changes against `recipe`, for a card that shows
    /// the difference instead of the whole recipe.
    public struct Changes: Equatable, Sendable {
        /// Lines the replacement has and the recipe did not.
        public var added: [String]
        /// Lines the recipe had and the replacement does not.
        public var removed: [String]
        /// Steps (by position) that read differently, and steps the count differs by.
        public var changedSteps: Int
        public var titleChanged: Bool
        public var servingsChanged: Bool

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changedSteps == 0 && !titleChanged && !servingsChanged }
    }

    public func changes(from recipe: Recipe) -> Changes {
        func lines(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        // Spacing is not a change: "200ml" and "200 ml" are the same line.
        func key(_ line: String) -> String { line.lowercased().filter { !$0.isWhitespace } }

        let old = lines(recipe.ingredientsText), new = lines(ingredientsText)
        let oldKeys = Set(old.map(key)), newKeys = Set(new.map(key))
        let oldSteps = lines(recipe.instructionsText), newSteps = lines(instructionsText)
        let paired = zip(oldSteps, newSteps).filter { key($0) != key($1) }.count
        return Changes(
            added: new.filter { !oldKeys.contains(key($0)) },
            removed: old.filter { !newKeys.contains(key($0)) },
            changedSteps: paired + abs(oldSteps.count - newSteps.count),
            titleChanged: title != recipe.title,
            servingsChanged: servings.map { $0 != recipe.servings } ?? false
        )
    }

    /// What `fields` says of this replacement, applied to `recipe`'s content.
    public func applied(to recipe: Recipe, fields: Fields) -> Recipe {
        var result = recipe
        if fields.contains(.title) { result.title = title }
        if fields.contains(.summary) { result.summary = summary }
        if fields.contains(.servings), let servings { result.servings = servings }
        if fields.contains(.categories), let categories { result.categories = categories }
        result.ingredientsText = ingredientsText
        result.instructionsText = instructionsText
        result.notes = notes
        // Read against the recipe as it will be, title, servings and all:
        // that is what the references are stamped for. An answer whose
        // references name a line or a step it does not have brings none.
        if !stepReferenceItems.isEmpty,
           case .success(let reading) = StepReferencesPrompt.reading(
               steps: stepReferenceItems.map { ($0.step, $0.references) }, for: result
           ) {
            result.stepReferences = reading.references
        } else {
            result.stepReferences = nil
        }
        return result
    }
}

public enum RecipeReplacementPrompt {
    /// The answer's shape, one example the model copies.
    static let format = """
    ```json
    {"title": "Vegane Linsensuppe", "summary": "Cremig und würzig.", "servings": 4, "categories": ["Suppe", "Vegan"], "ingredients": ["# Für die Suppe", "250 g rote Linsen", "1 Zwiebel"], "steps": ["# Suppe", "Zwiebel würfeln und anschwitzen.", "200 g Linsen zugeben und 15 Minuten kochen, dann den Rest."], "notes": "Hält sich 3 Tage im Kühlschrank.", "stepReferences": [{"step": 1, "references": [{"kind": "mention", "line": 2, "amount": "1"}]}, {"step": 2, "references": [{"kind": "amount", "text": "200 g", "occurrence": 1, "line": 1, "amount": "200 g"}, {"kind": "mention", "line": 1, "amount": "50 g"}]}]}
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

    Regeln für das JSON: "ingredients" und "steps" sind Listen mit einer \
    Zeile pro Eintrag. Eine Zutat steht als "Menge Einheit Zutat" \
    ("250 g rote Linsen", "1 Zwiebel"), ohne Zubereitung in der Zeile — die \
    gehört in die Schritte. Eine Zeile "# Name" eröffnet eine Gruppe. \
    "summary", "categories" und "notes" dürfen fehlen. Schreibe \
    "servings" als ganze Zahl.

    Wähle "categories" aus den vorhandenen Kategorien unten, wo sie passen; \
    eine neue nur, wenn keine passt. Die Schreibweise der vorhandenen \
    Kategorien bleibt unverändert.

    Für Sous gehört zum JSON auch "stepReferences": für jeden Schritt, welche \
    Zutatenzeilen er verwendet und wie viel davon — damit Sous beim Kochen die \
    Mengen im Text mitrechnen kann. Zeilen und Schritte zählen ab 1 in der \
    Reihenfolge von "ingredients" und "steps"; Überschriften ("# …") zählen \
    nicht mit. Jeder Bezug hat:
    - "kind": "amount", wenn im Schritt eine Mengenangabe dieser Zutat steht \
    ("200 g", "2 EL", "3"). Dann gehört dazu "text": genau diese \
    Mengenangabe, so wie sie im Schritt steht (ohne Zutatennamen), und \
    "occurrence": das wievielte Vorkommen dieses Wortlauts im Schritt gemeint \
    ist, sonst 1.
    - "kind": "mention", wenn der Schritt eine Zutat ohne eigene Zahl verwendet: \
    beim Namen, als Anteil ("die Hälfte der Butter"), als Sammelbegriff ("die \
    trockenen Zutaten" — ein Eintrag je gemeinter Zeile) oder nur gemeint \
    ("abschmecken" für Salz). Ohne "text".
    - "line": die Nummer der Zutatenzeile.
    - "amount": was der Schritt von der Zeile nimmt, in der Einheit der Zeile \
    und ohne Zutatennamen ("150 g", "½ TL", "1"); "die Hälfte" oder "den Rest" \
    rechnest du um. Hat die Zeile keine Menge (Salz), bleibt "amount" leer.
    Pro Schritt höchstens ein Eintrag je Zeile, außer mehrere geschriebene \
    Mengen derselben Zutat im Satz. Temperaturen, Zeiten und Größen bekommen \
    keinen Eintrag. Schritte ohne Zutaten lässt du weg.

    Orientiere dich bei den Zutatennamen am Katalog unten: Nimm den dort \
    stehenden Namen, wo er passt (also "Hafermilch" statt "pflanzliche \
    Milch"). Fehlt eine Zutat im Katalog, schreibe sie trotzdem.
    """

    /// The rules for a chat Sous itself runs: the model does not write the
    /// recipe out again, because Sous shows it as a card beside the answer. The
    /// JSON block stays, and with it everything the reader needs.
    static let rulesForSousChat: String = {
        let shown = """
            1. Zeige mir das umgearbeitete Rezept gut lesbar (Titel, Portionen, Zutaten, Zubereitung) und erkläre kurz, was du geändert hast und warum. Wir können danach darüber sprechen und es weiter anpassen.
            2. Hänge in JEDER Antwort, in der du ein Rezept zeigst, am Ende den aktuellen Stand als JSON-Codeblock an, genau in dieser Form, damit ich ihn kopieren und in Sous einfügen kann:
            """.replacingOccurrences(of: "\n            ", with: "\n").replacingOccurrences(of: "            1.", with: "1.")
        let brief = """
            1. Erkläre kurz, was du geändert hast und warum. Schreibe das Rezept selbst nicht noch einmal aus: Sous zeigt es neben deiner Antwort an. Wir können danach darüber sprechen und es weiter anpassen.
            2. Hänge in JEDER Antwort, in der du das Rezept geändert hast, am Ende den aktuellen Stand als JSON-Codeblock an, genau in dieser Form:
            """.replacingOccurrences(of: "\n            ", with: "\n").replacingOccurrences(of: "            1.", with: "1.")
        return rules.replacingOccurrences(of: shown, with: brief)
    }()

    /// The whole text to copy: the rules, the catalog, the task, the recipe.
    ///
    /// `task` is what the cook asked for — a saved template's text or a line
    /// they typed. A `{{recipe}}` in it marks where the recipe stands;
    /// without one, the recipe follows the task.
    public static func prompt(
        task: String,
        for recipe: Recipe,
        catalog: IngredientCatalog = .current,
        categories: [String] = [],
        showsRecipe: Bool = true
    ) -> String {
        let parts = parts(task: task, for: recipe, catalog: catalog, categories: categories, showsRecipe: showsRecipe)
        return parts.prefix + parts.rest
    }

    /// The prompt in two: the rules, the categories and the catalog, which stay
    /// the same from one request to the next, and the task with the recipe.
    public static func parts(
        task: String,
        for recipe: Recipe,
        catalog: IngredientCatalog = .current,
        categories: [String] = [],
        showsRecipe: Bool = true
    ) -> (prefix: String, rest: String) {
        let recipeText = text(of: recipe)
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = trimmed.contains(placeholder)
            ? trimmed.replacingOccurrences(of: placeholder, with: recipeText)
            : "\(trimmed)\n\n\(recipeText)"
        let categoryList = categories.isEmpty
            ? ""
            : "Vorhandene Kategorien:\n\(categories.joined(separator: ", "))\n\n"
        return (
            "\(showsRecipe ? rules : rulesForSousChat)\n\n\(categoryList)\(RecipeOptimizationPrompt.catalogList(catalog))\n\n",
            "Aufgabe:\n\(request)"
        )
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
        var title: String?
        var summary: String?
        var servings: Int?
        var categories: [String]?
        var ingredients: [String]?
        var steps: [String]?
        var notes: String?
        var stepReferences: [RecipeReplacement.StepItems]?
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
        guard let title = clean(answer.title) else { return .failure(.missing("der Titel")) }
        let ingredients = lines(answer.ingredients)
        guard !ingredients.isEmpty else { return .failure(.missing("die Zutatenliste")) }
        let steps = lines(answer.steps)
        guard !steps.isEmpty else { return .failure(.missing("die Zubereitung")) }

        return .success(RecipeReplacement(
            title: title,
            summary: clean(answer.summary),
            servings: answer.servings.flatMap { (1...100).contains($0) ? $0 : nil },
            categories: answer.categories.map { $0.compactMap(clean) },
            ingredientsText: ingredients.joined(separator: "\n"),
            instructionsText: steps.joined(separator: "\n"),
            notes: clean(answer.notes),
            stepReferenceItems: answer.stepReferences ?? []
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
