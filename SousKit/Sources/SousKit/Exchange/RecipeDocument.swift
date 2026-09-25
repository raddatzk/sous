import Foundation

/// A recipe settled for leaving the app: scaled to one serving count, every
/// amount formatted, every markdown mark and in-app link read out into plain
/// words.
///
/// What the Markdown file, the printout and the PDF are all written from, so
/// the three cannot disagree about an amount. Nothing here knows about a
/// page or a file format — ``RecipeMarkdown`` and ``RecipeHTML`` decide how
/// it looks.
public struct RecipeDocument: Hashable, Sendable {
    public struct Fact: Hashable, Sendable {
        public var label: String
        public var value: String
    }

    /// One ingredient line split the way the page splits it: the amount the
    /// cook is looking for, then the rest.
    public struct IngredientLine: Hashable, Sendable {
        /// "300 g", "1 kleine", "etwas" — empty where the line has none.
        public var amount: String
        /// The name and whatever was written after it, preparation included.
        public var text: String
    }

    public struct IngredientGroup: Hashable, Sendable {
        public var name: String?
        public var lines: [IngredientLine]
    }

    public struct Step: Hashable, Sendable {
        /// Counted within its group, as on the page.
        public var number: Int
        public var segments: [StepAmountSegment]

        /// The step as one run of words.
        public var text: String {
            segments.map {
                switch $0 {
                case .text(let string), .amount(let string): string
                }
            }.joined()
        }
    }

    public struct StepGroup: Hashable, Sendable {
        public var name: String?
        public var steps: [Step]
    }

    /// The per-portion figures, laid out as the EU label lays them out.
    public struct Nutrition: Hashable, Sendable {
        public struct Row: Hashable, Sendable {
            public var label: String
            public var value: String
            /// A "davon" line under the one before it.
            public var isIndented: Bool
        }

        public var rows: [Row]
        /// What the figure rests on, in words — never left off: a sum
        /// without it would look more settled than it is.
        public var caption: String
        public var isProvisional: Bool
    }

    public struct Source: Hashable, Sendable {
        /// The site, channel or author — or the address itself where
        /// nobody named one.
        public var name: String
        public var url: URL?
        public var isGenerated: Bool
    }

    public var title: String
    public var summary: String?
    public var categories: [String]
    public var servings: Int
    public var times: [Fact]
    public var ingredientGroups: [IngredientGroup]
    public var stepGroups: [StepGroup]
    public var notes: String?
    public var nutrition: Nutrition?
    public var source: Source?
    /// The recipe's own `sous://` link, for whoever holds the paper and has
    /// the app — `nil` where there is nothing in the app to go back to.
    public var appLink: URL?

    /// `recipe` at `servings`, with `nutrition` where it has been worked
    /// out. The figure is per portion, so it is the same at every count —
    /// but it has to be the recipe's current one, which only the caller
    /// knows. So does `appLink`: which household the link names is the
    /// app's state, not the recipe's.
    public init(
        _ recipe: Recipe,
        servings: Int? = nil,
        nutrition: RecipeNutrition? = nil,
        appLink: URL? = nil,
        locale: Locale = Locale(identifier: "de_DE")
    ) {
        let servings = servings ?? recipe.servings
        let formatter = QuantityFormatter(locale: locale)

        title = recipe.title
        summary = Self.paragraph(recipe.summary)
        categories = recipe.categories
        self.servings = servings
        times = RecipeTimes.items(for: recipe).map { Fact(label: $0.label, value: $0.value) }

        ingredientGroups = recipe.ingredientGroups(scaledToServings: servings).map { group in
            IngredientGroup(
                name: group.group,
                lines: group.ingredients.map { Self.line(for: $0, formatter: formatter) }
            )
        }

        let rendition = recipe.stepRendition(toServings: servings, formatter: formatter)
        stepGroups = recipe.stepGroups.map { group in
            StepGroup(
                name: group.group,
                steps: group.steps.enumerated().map { index, step in
                    Step(
                        number: index + 1,
                        segments: rendition.segments(for: step).map {
                            switch $0 {
                            case .text(let string): .text(Self.plain(string))
                            case .amount: $0
                            }
                        }
                    )
                }
            )
        }

        notes = Self.paragraph(recipe.notes)
        self.nutrition = nutrition.flatMap { Self.nutrition($0, locale: locale) }
        self.appLink = appLink

        let sourceName = recipe.source.name ?? recipe.source.url.map { $0.host() ?? $0.absoluteString }
        if let sourceName {
            source = Source(name: sourceName, url: recipe.source.url, isGenerated: recipe.source.kind == .generated)
        } else if recipe.source.kind == .generated {
            source = Source(name: "Von der KI erzeugt", url: nil, isGenerated: true)
        }
    }

    /// "4 Portionen · Vorbereitung 15 Min · Gesamt 55 Min".
    public var factsLine: String {
        ([Servings.text(servings)] + times.map { "\($0.label) \($0.value)" }).joined(separator: " · ")
    }

    /// A name for the file, safe for every file system it may land on.
    public var fileName: String {
        let stripped = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "Rezept" : String(stripped.prefix(80))
    }

    // MARK: - Building

    private static func line(for ingredient: RecipeIngredient, formatter: QuantityFormatter) -> IngredientLine {
        var amount = ""
        if let quantity = ingredient.quantity {
            amount = formatter.string(for: quantity, size: ingredient.size)
        } else if let phrase = ingredient.unquantifiedPhrase, phrase.placement == .beforeName {
            amount = phrase.phrase
        }
        var text = plain(ingredient.name)
        if let phrase = ingredient.unquantifiedPhrase, phrase.placement == .afterName {
            text += " \(phrase.phrase)"
        }
        if let preparation = ingredient.preparation, !preparation.isEmpty {
            text += " (\(preparation))"
        }
        return IngredientLine(amount: amount, text: text)
    }

    private static func nutrition(_ nutrition: RecipeNutrition, locale: Locale) -> Nutrition? {
        let coverage = nutrition.coverage
        // Nothing counted, nothing to print: a column of zeros would read
        // as a light dish.
        guard coverage.includedCount > 0 else { return nil }
        let formatter = NutrientFormatter(locale: locale)
        let info = nutrition.perPortion
        func mass(_ grams: Double) -> String { formatter.string(grams, in: .grams) }

        var caption = "Pro Portion, geschätzt"
        if coverage.includedCount < coverage.accountableCount {
            caption += " aus \(coverage.includedCount) von \(coverage.accountableCount) Zutaten"
        }
        return Nutrition(
            rows: [
                .init(label: "Energie", value: formatter.string(kilocalories: info.kcal), isIndented: false),
                .init(label: "Fett", value: mass(info.fatG), isIndented: false),
                .init(label: "davon gesättigte Fettsäuren", value: mass(info.saturatedFatG), isIndented: true),
                .init(label: "Kohlenhydrate", value: mass(info.carbsG), isIndented: false),
                .init(label: "davon Zucker", value: mass(info.sugarG), isIndented: true),
                .init(label: "Ballaststoffe", value: mass(info.fiberG), isIndented: false),
                .init(label: "Eiweiß", value: mass(info.proteinG), isIndented: false),
                // BLS reports sodium; the label shows salt.
                .init(label: "Salz", value: mass(info.sodiumMg * 2.5 / 1000), isIndented: false),
            ],
            caption: caption,
            isProvisional: coverage.isProvisional
        )
    }

    /// Markdown as the reader sees it: the emphasis marks and the link
    /// targets gone, the words kept. A `sous://` link means nothing on paper
    /// or in another app, but the name it is written on does.
    ///
    /// Whitespace is kept as it is: a step arrives in pieces around its
    /// amounts, and the spaces between them are part of the sentence.
    static func plain(_ markdown: String) -> String {
        let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return parsed.map { String($0.characters) } ?? markdown
    }

    /// A free-text field, or `nil` where nothing was written.
    private static func paragraph(_ markdown: String?) -> String? {
        let trimmed = markdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : plain(trimmed)
    }
}
