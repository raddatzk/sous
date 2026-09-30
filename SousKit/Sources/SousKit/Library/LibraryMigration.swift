import Foundation

/// "Bibliothek umstellen": the one-time move of a library written before the
/// fixed form (``IngredientLineReader``) into it.
///
/// The tolerant ``IngredientParser`` reads every line once more, and every
/// line it understands is written back in the fixed form, deterministically:
///
///     ½ Limette, Saft davon (optional)   →  ½ Limette, Saft davon, optional
///     2 Zwiebeln, rot                    →  2 rote Zwiebeln
///     250 g rote Linsen - (getrocknet)   →  250 g rote Linsen, getrocknet
///
/// Nothing is invented and nothing moves into a step — that takes the
/// optimization. The annotation only parks the words until then.
///
/// A rewrite is taken only when both readers agree with what the line meant
/// before: the strict reader reads the new line as the same ingredient,
/// amount and state, and so does the old parser, which is what an older app
/// in the household still runs. Everything else stays as written and is
/// counted as outside the form, for the optimization.
///
/// Lines are never added or removed, so the step references keep their line
/// numbers; a reading that was current before is stamped for the new text.
/// Running it twice changes nothing the second time.
public enum LibraryMigration {
    /// What became of one ingredient line.
    public enum LineOutcome: Hashable, Sendable {
        /// Already in the fixed form, read as before.
        case inForm
        /// Written back in the fixed form.
        case rewritten(to: String)
        /// Outside the form, left as written for the optimization.
        case outsideForm
    }

    /// One recipe after the migration, with what happened to its lines.
    public struct RecipeOutcome: Sendable {
        /// The recipe as it is to be saved: new text, original kept, step
        /// references stamped. Equal to the input when nothing changed.
        public var recipe: Recipe
        public var lines: [(written: String, outcome: LineOutcome)]

        public var changed: Bool { lines.contains { if case .rewritten = $0.outcome { true } else { false } } }
        public var rewrittenCount: Int { lines.count { if case .rewritten = $0.outcome { true } else { false } } }
        public var outsideForm: [String] { lines.filter { $0.outcome == .outsideForm }.map(\.written) }
    }

    /// The counts the preview shows, over a whole library.
    public struct Summary: Hashable, Sendable {
        public var recipes = 0
        public var recipesChanged = 0
        public var lines = 0
        public var rewritten = 0
        /// Lines in the form, after the migration, that carry an annotation —
        /// words the optimization still moves into a step or the notes.
        public var annotated = 0
        public var outsideForm: [OutsideFormLine] = []

        public struct OutsideFormLine: Hashable, Sendable {
            public var recipeTitle: String
            public var line: String
        }

        public init() {}
    }

    // MARK: - A library

    /// Every recipe migrated, and the summary over them.
    public static func migrate(
        _ recipes: [Recipe], catalog: IngredientCatalog? = nil, keptAt: Date = .nowInSyncPrecision
    ) -> (outcomes: [RecipeOutcome], summary: Summary) {
        let catalog = catalog ?? IngredientLineReader.catalog
        var summary = Summary()
        var outcomes: [RecipeOutcome] = []
        for recipe in recipes {
            let outcome = migrate(recipe, catalog: catalog, keptAt: keptAt)
            summary.recipes += 1
            if outcome.changed { summary.recipesChanged += 1 }
            summary.lines += outcome.lines.count
            summary.rewritten += outcome.rewrittenCount
            summary.outsideForm += outcome.outsideForm.map { .init(recipeTitle: recipe.title, line: $0) }
            summary.annotated += IngredientLineReader.read(outcome.recipe.ingredientsText, catalog: catalog)
                .count { !$0.isOutsideForm && $0.preparation != nil }
            outcomes.append(outcome)
        }
        return (outcomes, summary)
    }

    // MARK: - A recipe

    public static func migrate(
        _ recipe: Recipe, catalog: IngredientCatalog? = nil, keptAt: Date = .nowInSyncPrecision
    ) -> RecipeOutcome {
        let catalog = catalog ?? IngredientLineReader.catalog
        var textLines = recipe.ingredientsText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var lines: [(written: String, outcome: LineOutcome)] = []
        for written in IngredientLineReader.writtenLines(in: recipe.ingredientsText) {
            let outcome = migrate(line: written.text, catalog: catalog)
            if case .rewritten(let new) = outcome { textLines[written.textLine] = new }
            lines.append((written.text, outcome))
        }

        let text = textLines.joined(separator: "\n")
        guard text != recipe.ingredientsText else { return RecipeOutcome(recipe: recipe, lines: lines) }

        var migrated = recipe.keepingOriginal(keptAt: keptAt)
        migrated.ingredientsText = text
        // Same lines in the same places, same steps: a reading that was
        // current is still right, and only its stamp has to follow the text.
        if var references = recipe.stepReferences, references.isCurrent(for: recipe) {
            references.fingerprint = StepReferencesPrompt.fingerprint(for: migrated)
            migrated.stepReferences = references
        }
        return RecipeOutcome(recipe: migrated, lines: lines)
    }

    // MARK: - A line

    /// What becomes of one written line.
    public static func migrate(line: String, catalog: IngredientCatalog) -> LineOutcome {
        let before = Meaning(IngredientParser.parseLine(line, catalog: catalog), catalog: catalog)
        let strict = IngredientLineReader.readLine(line, catalog: catalog)

        // Already in the form, and read as it always was.
        if !strict.isOutsideForm, Meaning(strict, catalog: catalog) == before { return .inForm }

        if let candidate = fixedLine(for: line, catalog: catalog), candidate != line,
           !IngredientLineReader.isGroupHeading(candidate) {
            let read = IngredientLineReader.readLine(candidate, catalog: catalog)
            let old = IngredientParser.parseLine(candidate, catalog: catalog)
            if !read.isOutsideForm,
               Meaning(read, catalog: catalog) == before,
               Meaning(old, catalog: catalog) == before {
                return .rewritten(to: candidate)
            }
        }
        // In the form, only read better than before: "1 1/2 TL", which the
        // old parser took for one teaspoon of something called "1/2 TL".
        return strict.isOutsideForm ? .outsideForm : .inForm
    }

    /// The line in the fixed form, built from what the old parser read:
    /// the measure as written, the name the catalog knows, and everything
    /// else — the preparation after a comma or in parentheses, "nach
    /// Geschmack", a trailing state word — as the annotation. `nil` when
    /// the old parser found no known name either.
    static func fixedLine(for line: String, catalog: IngredientCatalog) -> String? {
        let parsed = IngredientParser.parseLine(line, catalog: catalog)
        guard var name = name(for: parsed.name, catalog: catalog) else { return nil }
        name = withoutDash(name)

        var measure = ""
        if parsed.quantity != nil,
           let length = IngredientParser.leadingAmountAndUnitLength(in: line, catalog: catalog) {
            measure = String(line.trimmingCharacters(in: .whitespaces).prefix(length))
                .trimmingCharacters(in: .whitespaces)
        }
        let annotation = [parsed.unquantifiedPhrase?.phrase, parsed.preparation]
            .compactMap { $0 }
            .map(withoutDash)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        var fixed = [measure, name].filter { !$0.isEmpty }.joined(separator: " ")
        if !annotation.isEmpty { fixed += ", \(annotation)" }
        return fixed
    }

    /// The name to write for what the old parser called `parsed`: itself
    /// when the catalog knows that writing, a recipe link as it is, and a
    /// variety written the list way round ("Zwiebeln, rot") the way the
    /// catalog files it ("rote Zwiebeln").
    private static func name(for parsed: String, catalog: IngredientCatalog) -> String? {
        let written = withoutDash(parsed)
        if written.contains("](") { return written }
        if catalog.ingredient(writtenAs: written) != nil { return written }
        guard let comma = written.lastIndex(of: ","), catalog.ingredient(for: written) != nil else { return nil }
        let head = written[..<comma].trimmingCharacters(in: .whitespaces)
        let word = written[written.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return ["\(word) \(head)", "\(word)e \(head)", "\(head) \(word)"]
            .first { catalog.ingredient(writtenAs: $0) != nil }
    }

    /// Without the trailing " -" some sites set before a parenthesis.
    private static func withoutDash(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        while result.hasSuffix("-") || result.hasSuffix("–") {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// What a reading of a line amounts to, for comparing two readings:
    /// which ingredient, which nutrition row, how much and in what state.
    private struct Meaning: Equatable {
        var ingredient: String?
        var nutritionName: String?
        var link: String?
        var quantity: Quantity?
        var size: IngredientSize.Degree?
        var state: IngredientState

        init(_ reading: RecipeIngredient, catalog: IngredientCatalog) {
            let known = reading.isOutsideForm ? nil : catalog.ingredient(for: reading.name)
            ingredient = known?.name
            nutritionName = known.map { _ in catalog.nutritionName(for: reading) }
            link = reading.name.contains("](") ? reading.name : nil
            quantity = reading.quantity
            size = reading.size?.degree
            state = reading.state
        }
    }
}
