import CryptoKit
import Foundation

/// What each step takes off the ingredient list, as a chat model read it
/// out of the recipe — handed over by the person who pasted the model's
/// answer back into Sous, and kept beside the recipe.
///
/// Sous never talks to the model itself. ``StepChipsPrompt/prompt(for:)``
/// writes a prompt to copy into whatever chat app the cook already pays
/// for; ``StepChipsPrompt/read(_:for:)`` reads the answer that comes back.
/// Amounts are stored as the model wrote them, at the recipe's own serving
/// count, and scaled on the way out like any ingredient line.
///
/// The answer is only true of the text it was given. ``fingerprint`` hashes
/// exactly that text; once the recipe reads differently the chips are stale
/// and ``StepChips/isCurrent(for:)`` says so.
public struct StepChips: Codable, Hashable, Sendable {
    public struct Use: Codable, Hashable, Sendable {
        /// 1-based, as the lines are numbered in the prompt.
        public var line: Int
        /// As the model wrote it ("150 g", "½"), or `nil` where the line
        /// carries no amount.
        public var amount: String?

        public init(line: Int, amount: String?) {
            self.line = line
            self.amount = amount
        }
    }

    public var fingerprint: String
    /// One entry per step, in step order.
    public var usesByStep: [[Use]]
    public var createdAt: Date

    public init(fingerprint: String, usesByStep: [[Use]], createdAt: Date = .nowInSyncPrecision) {
        self.fingerprint = fingerprint
        self.usesByStep = usesByStep
        self.createdAt = createdAt
    }

    /// The column's JSON, or `nil` for no chips.
    static func encode(_ chips: StepChips?) -> String? {
        guard let chips, let data = try? SousCoding.encoder.encode(chips) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads what ``encode(_:)`` wrote. Anything unreadable reads as no
    /// chips — the resolver's take on the steps is still there.
    static func decode(_ json: String?) -> StepChips? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? SousCoding.decoder.decode(StepChips.self, from: data)
    }

    /// Whether these chips were made from `recipe` as it reads now.
    public func isCurrent(for recipe: Recipe) -> Bool {
        fingerprint == StepChipsPrompt.fingerprint(for: recipe)
    }

    /// The chips under every step, in step order: each named line with the
    /// amount the step takes, scaled to `targetServings`. `nil` once the
    /// chips are no longer current for `recipe`.
    ///
    /// All steps at once, because a view walks all of them and the check
    /// that the chips still fit hashes the whole recipe.
    public func ingredientsByStep(of recipe: Recipe, scaledToServings targetServings: Int? = nil) -> [[RecipeIngredient]]? {
        guard isCurrent(for: recipe) else { return nil }
        let lines = recipe.ingredients
        let factor: Double = if let targetServings, recipe.servings > 0, targetServings > 0 {
            Double(targetServings) / Double(recipe.servings)
        } else {
            1
        }
        return recipe.steps.indices.map { stepIndex in
            guard usesByStep.indices.contains(stepIndex) else { return [] }
            var result: [RecipeIngredient] = []
            for use in usesByStep[stepIndex] {
                guard lines.indices.contains(use.line - 1) else { continue }
                var chip = lines[use.line - 1]
                guard !result.contains(where: { $0.id == chip.id }) else { continue }
                chip.resolvedGrams = nil
                if let written = use.amount.flatMap(StepChipsPrompt.quantity(in:)) {
                    chip.quantity = chip.scalesWithServings ? written.quantity.scaled(by: factor) : written.quantity
                    chip.size = written.size
                } else if chip.quantity != nil {
                    // A quantified line named without an amount: the model
                    // could not say how much, so the chip says nothing either.
                    chip.quantity = nil
                    chip.size = nil
                }
                result.append(chip)
            }
            return result
        }
    }
}

/// Builds the prompt the cook copies into a chat app, and reads back what
/// they paste. See ``StepChips``.
public enum StepChipsPrompt {
    /// Part of the fingerprint: a changed prompt asks a different question,
    /// so answers to the old one should not pass for answers to the new.
    static let version = "v1"

    static let rules = """
    Du liest ein deutsches Rezept und ordnest jedem Zubereitungsschritt die \
    Zutaten zu, die in diesem Schritt von der Zutatenliste genommen werden, \
    mit der Menge, die der Schritt davon braucht.

    Regeln:
    - Jede Zutatenzeile wird über alle Schritte hinweg höchstens so oft \
    verteilt, wie sie Menge hat. Wird eine Zutat auf mehrere Schritte \
    aufgeteilt, müssen die Teilmengen zusammen die Zeilenmenge ergeben.
    - Nennt der Schritt eine Zutat, die ein früherer Schritt schon vollständig \
    verarbeitet hat ("die Zwiebeln glasig dünsten" nach "Zwiebeln würfeln"), \
    wird sie nicht erneut genommen.
    - Sammelbegriffe ("die trockenen Zutaten", "die Kräuter") löst du in die \
    gemeinten Zeilen auf.
    - Steht eine Menge im Schritt, gilt sie. "Die Hälfte", "den Rest", \
    "restliche", "je ¼ TL" bei mehreren Stücken rechnest du in eine Menge um.
    - "menge" ist eine Zahl mit der Einheit der Zeile, ohne den Zutatennamen: \
    "150 g", "½ TL", "1" — nicht "1 Schalotte". Hat die Zeile keine Menge \
    (Salz, "etwas Öl"), bleibt "menge" leer.
    - Zeilen ohne Menge nimmst du auf, wenn der Schritt sie verwendet — auch \
    wenn sie nur gemeint sind ("abschmecken").
    - Nur Zeilen aus der Liste, keine erfundenen Zutaten. Schritte ohne Zutaten \
    bekommen eine leere Liste.

    Antworte ausschließlich mit einem JSON-Codeblock in genau dieser Form, \
    ein Eintrag pro Schritt, in Schrittreihenfolge:

    ```json
    {"schritte": [{"schritt": 1, "zutaten": [{"zeile": 3, "menge": "150 g"}]}]}
    ```
    """

    /// The whole text to copy: rules, answer format, and the recipe with its
    /// lines and steps numbered.
    public static func prompt(for recipe: Recipe) -> String {
        "\(rules)\n\nRezept: \(recipe.title)\n\(body(for: recipe))"
    }

    /// Hash of what the model is shown about the recipe, title aside —
    /// renaming a dish does not change what its steps take.
    public static func fingerprint(for recipe: Recipe) -> String {
        let input = "\(version)\n\(body(for: recipe))"
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Serving count, numbered lines and numbered steps. A fixed locale, so
    /// the same recipe reads — and fingerprints — the same on every device.
    static func body(for recipe: Recipe) -> String {
        let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))
        var text = "Portionen: \(recipe.servings)\n\nZutaten:\n"
        var lastGroup: String?
        for (index, line) in recipe.ingredients.enumerated() {
            if let group = line.group, group != lastGroup { text += "[\(group)]\n" }
            lastGroup = line.group
            text += "Z\(index + 1): \(formatter.string(for: line))\n"
        }
        text += "\nZubereitung:\n"
        lastGroup = nil
        for (index, step) in recipe.steps.enumerated() {
            if let group = step.group, group != lastGroup { text += "[\(group)]\n" }
            lastGroup = step.group
            text += "S\(index + 1): \(step.text)\n"
        }
        return text
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// Nothing in the pasted text looks like the answer format.
        case noAnswer
        /// The JSON is there but not in the asked-for shape.
        case unreadable
        /// A line number the recipe does not have — the answer belongs to
        /// another recipe, or the model invented a line.
        case unknownLine(step: Int, line: Int)
        case unknownStep(Int)

        public var errorDescription: String? {
            switch self {
            case .noAnswer: "In der Zwischenablage steht keine Antwort im erwarteten Format."
            case .unreadable: "Die Antwort hat nicht das erwartete Format."
            case .unknownLine(let step, let line): "Schritt \(step) nennt Zeile \(line), die es in diesem Rezept nicht gibt."
            case .unknownStep(let step): "Die Antwort nennt Schritt \(step), den es in diesem Rezept nicht gibt."
            }
        }
    }

    /// Something in an otherwise usable answer the cook should know about
    /// before taking it.
    public enum Warning: Hashable, Sendable {
        /// An amount that does not read as one — the chip goes without.
        case unreadableAmount(step: Int, line: Int, amount: String)
        /// The steps between them take more of a line than it holds.
        case overbooked(line: Int, percent: Int)
    }

    public struct Reading: Sendable {
        public let chips: StepChips
        public let warnings: [Warning]
    }

    /// Reads a pasted answer for `recipe`: the first `{` to the last `}`, so
    /// a code fence or a sentence around it does not matter. An answer that
    /// names a line or step the recipe lacks is refused whole — it was made
    /// for some other text.
    public static func read(_ pasted: String, for recipe: Recipe) -> Result<Reading, Failure> {
        guard let open = pasted.firstIndex(of: "{"), let close = pasted.lastIndex(of: "}"), open < close else {
            return .failure(.noAnswer)
        }
        struct Answer: Decodable {
            struct Step: Decodable {
                let schritt: Int
                let zutaten: [Item]
            }
            struct Item: Decodable {
                let zeile: Int
                let menge: String?
            }
            let schritte: [Step]
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(pasted[open...close].utf8)) else {
            return .failure(.unreadable)
        }

        let lines = recipe.ingredients
        let stepCount = recipe.steps.count
        var usesByStep = Array(repeating: [StepChips.Use](), count: stepCount)
        var warnings: [Warning] = []
        var taken: [Int: Quantity] = [:]
        for step in answer.schritte {
            guard (1...max(stepCount, 1)).contains(step.schritt), stepCount > 0 else {
                return .failure(.unknownStep(step.schritt))
            }
            for item in step.zutaten {
                guard lines.indices.contains(item.zeile - 1) else {
                    return .failure(.unknownLine(step: step.schritt, line: item.zeile))
                }
                let written = item.menge?.trimmingCharacters(in: .whitespacesAndNewlines)
                let amount = written?.isEmpty == false ? written : nil
                if let amount {
                    if let quantity = quantity(in: amount)?.quantity {
                        taken[item.zeile] = taken[item.zeile].map { $0.adding(quantity) ?? $0 } ?? quantity
                    } else {
                        warnings.append(.unreadableAmount(step: step.schritt, line: item.zeile, amount: amount))
                    }
                }
                usesByStep[step.schritt - 1].append(StepChips.Use(line: item.zeile, amount: amount))
            }
        }
        for (line, sum) in taken.sorted(by: { $0.key < $1.key }) {
            guard let total = lines[line - 1].quantity else { continue }
            let share: Double? = if let a = sum.inBaseUnit, let b = total.inBaseUnit, b > 0 {
                a / b
            } else if sum.unit == total.unit, total.amount > 0 {
                sum.amount / total.amount
            } else {
                nil
            }
            if let share, share > 1.01 {
                warnings.append(.overbooked(line: line, percent: Int((share * 100).rounded())))
            }
        }
        return .success(Reading(
            chips: StepChips(fingerprint: fingerprint(for: recipe), usesByStep: usesByStep),
            warnings: warnings
        ))
    }

    /// An amount as the model wrote it, read the way an ingredient line
    /// would be — "150 g", "½ TL", "1 kleine".
    static func quantity(in amount: String) -> (quantity: Quantity, size: IngredientSize?)? {
        let parsed = IngredientParser.parseLine("\(amount) x")
        return parsed.quantity.map { ($0, parsed.size) }
    }
}
