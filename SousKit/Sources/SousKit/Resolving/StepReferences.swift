import CryptoKit
import Foundation

/// Which ingredient lines a recipe's steps take, and where a step writes the
/// amount, in which words — as a chat model read them, handed over by the
/// person who pasted the model's answer back into Sous, and kept beside the
/// recipe.
///
/// Sous never talks to the model itself. ``StepReferencesPrompt/prompt(for:)``
/// writes a prompt to copy into whatever chat app the cook already pays
/// for; ``StepReferencesPrompt/read(_:for:)`` reads the answer that comes
/// back.
///
/// A reference says a step takes something of a line: either an amount
/// written in the sentence, anchored to its exact words ("200 g"), or a line
/// taken without a number of its own — by name, share, collective word or
/// implication — which becomes a chip and needs no words. Because every
/// written amount belongs to a line, it can be scaled by *that line's*
/// factor — which is what lets a single ingredient group be scaled on its
/// own one day, not just the whole recipe.
///
/// The references are only true of the text they were read from.
/// ``fingerprint`` hashes exactly that text; once the recipe reads
/// differently they are stale, and the steps show as written: nothing
/// scaled, nothing accented, no chips.
public struct StepReferences: Codable, Hashable, Sendable {
    public struct Reference: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable {
            /// An amount written in the sentence — scaled in place.
            case amount
            /// A line the step takes something of without writing a number
            /// for it — shown as a chip under the step.
            case mention
        }

        public var kind: Kind
        /// For an amount, its words in the step exactly as written; empty for
        /// a mention, which is a chip and stands nowhere in the text.
        public var text: String
        /// Which occurrence of `text` in the step is meant, from 1.
        public var occurrence: Int
        /// 1-based, as the lines are numbered in the prompt; `nil` for an
        /// amount of something the list does not have ("300 ml Wasser").
        public var line: Int?
        /// What the step takes of the line, at the recipe's own serving
        /// count, as the model wrote it ("50 g"); `nil` where the line has
        /// no amount.
        public var amount: String?

        public init(kind: Kind, text: String, occurrence: Int = 1, line: Int?, amount: String?) {
            self.kind = kind
            self.text = text
            self.occurrence = occurrence
            self.line = line
            self.amount = amount
        }
    }

    public var fingerprint: String
    /// One entry per step, in step order.
    public var steps: [[Reference]]
    public var createdAt: Date

    public init(fingerprint: String, steps: [[Reference]], createdAt: Date = .nowInSyncPrecision) {
        self.fingerprint = fingerprint
        self.steps = steps
        self.createdAt = createdAt
    }

    /// Whether these references were read from `recipe` as it reads now.
    public func isCurrent(for recipe: Recipe) -> Bool {
        fingerprint == StepReferencesPrompt.fingerprint(for: recipe)
    }

    /// The column's JSON, or `nil` for no references.
    static func encode(_ references: StepReferences?) -> String? {
        guard let references, let data = try? SousCoding.encoder.encode(references) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads what ``encode(_:)`` wrote. Anything unreadable — the first
    /// prototype's chips-only shape included — reads as no references.
    static func decode(_ json: String?) -> StepReferences? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? SousCoding.decoder.decode(StepReferences.self, from: data)
    }

    /// Where `reference` stands in `text`: its `occurrence`-th appearance,
    /// matched exactly and, failing that, ignoring case — a model that
    /// capitalizes "Die Hälfte" at the start of its quote still means the
    /// words in the sentence.
    static func range(of reference: Reference, in text: String) -> Range<String.Index>? {
        guard !reference.text.isEmpty else { return nil }
        for options: String.CompareOptions in [[], [.caseInsensitive]] {
            var searchStart = text.startIndex
            var found: Range<String.Index>?
            for _ in 0..<max(reference.occurrence, 1) {
                guard let match = text.range(of: reference.text, options: options, range: searchStart..<text.endIndex) else {
                    found = nil
                    break
                }
                found = match
                searchStart = match.upperBound
            }
            if let found { return found }
        }
        return nil
    }
}

extension StepReferences {
    /// No references yet, current for `recipe` — where the cook assigns by
    /// hand instead of asking a chat model.
    public static func empty(for recipe: Recipe) -> StepReferences {
        StepReferences(
            fingerprint: StepReferencesPrompt.fingerprint(for: recipe),
            steps: Array(repeating: [], count: recipe.steps.count)
        )
    }

    /// Makes the step at `stepIndex` take `amount` of `line` as a chip —
    /// updating the chip it already has for that line, or adding one.
    public mutating func setChip(line: Int, amount: String?, inStepAt stepIndex: Int) {
        ensureStep(stepIndex)
        // Kept as typed — an editor writes every keystroke through here, and
        // trimming would swallow the space before the unit. Reading an
        // amount ignores the whitespace around it anyway.
        let value = amount?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? amount : nil
        if let index = steps[stepIndex].firstIndex(where: { $0.kind == .mention && $0.line == line }) {
            steps[stepIndex][index].amount = value
        } else {
            steps[stepIndex].append(Reference(kind: .mention, text: "", line: line, amount: value))
        }
    }

    /// Takes the chip for `line` off the step at `stepIndex`.
    public mutating func removeChip(line: Int, fromStepAt stepIndex: Int) {
        guard steps.indices.contains(stepIndex) else { return }
        steps[stepIndex].removeAll { $0.kind == .mention && $0.line == line }
    }

    /// Ties the written amount at `index` in the step to another line, or to
    /// none (it then scales with the serving count alone).
    public mutating func setLine(_ line: Int?, forReferenceAt index: Int, inStepAt stepIndex: Int) {
        guard steps.indices.contains(stepIndex), steps[stepIndex].indices.contains(index) else { return }
        steps[stepIndex][index].line = line
    }

    /// Drops the reference at `index` — for a written amount, the text is
    /// then shown as written and never scaled.
    public mutating func removeReference(at index: Int, inStepAt stepIndex: Int) {
        guard steps.indices.contains(stepIndex), steps[stepIndex].indices.contains(index) else { return }
        steps[stepIndex].remove(at: index)
    }

    private mutating func ensureStep(_ stepIndex: Int) {
        while steps.count <= stepIndex { steps.append([]) }
    }
}

extension StepReferences {
    /// The steps as a view shows them at one serving count: text with the
    /// referenced amounts scaled, the chips under each step, and the spans
    /// an editor marks. Worked out once per recipe and serving count.
    public struct Rendition: Sendable {
        fileprivate var segmentsByStep: [UUID: [StepAmountSegment]] = [:]
        fileprivate var chipsByStep: [UUID: [RecipeIngredient]] = [:]
        fileprivate var marksByStep: [UUID: [StepTextMark]] = [:]

        /// `step`'s text split into plain text and amounts — the whole text
        /// as written where nothing is known about it.
        public func segments(for step: RecipeStep) -> [StepAmountSegment] {
            segmentsByStep[step.id] ?? [.text(step.text)]
        }

        /// The lines `step` takes something of without writing the amount.
        public func ingredients(for step: RecipeStep) -> [RecipeIngredient] {
            chipsByStep[step.id] ?? []
        }

        /// The referenced spans of `step`'s text, for an editor to mark.
        public func marks(for step: RecipeStep) -> [StepTextMark] {
            marksByStep[step.id] ?? []
        }
    }
}

extension Recipe {
    /// How this recipe's steps read at `targetServings`, by its pasted
    /// references — or as plain text, without chips, where it has none or
    /// they no longer fit the text.
    public func stepRendition(
        toServings targetServings: Int? = nil,
        formatter: QuantityFormatter = QuantityFormatter()
    ) -> StepReferences.Rendition {
        var rendition = StepReferences.Rendition()
        guard let references = stepReferences, references.isCurrent(for: self) else { return rendition }

        let lines = ingredients
        let recipeFactor: Double = if let targetServings, servings > 0, targetServings > 0 {
            Double(targetServings) / Double(servings)
        } else {
            1
        }
        // Per line, so that one group can be scaled apart from the rest
        // later; today every scalable line moves with the serving count.
        func factor(forLine line: Int?) -> Double {
            guard let line, lines.indices.contains(line - 1) else { return recipeFactor }
            return lines[line - 1].scalesWithServings ? recipeFactor : 1
        }

        for (stepIndex, step) in steps.enumerated() where references.steps.indices.contains(stepIndex) {
            let referencesInStep = references.steps[stepIndex]

            // Amounts written in the sentence, in reading order, overlaps
            // dropped — two quotes of the same words cannot both be scaled.
            // Mentions carry no words: they are chips, nothing in the text.
            var placed: [(range: Range<String.Index>, reference: StepReferences.Reference)] = []
            for reference in referencesInStep where reference.kind == .amount {
                guard let range = StepReferences.range(of: reference, in: step.text),
                      !placed.contains(where: { $0.range.overlaps(range) })
                else { continue }
                placed.append((range, reference))
            }
            placed.sort { $0.range.lowerBound < $1.range.lowerBound }

            var segments: [StepAmountSegment] = []
            var marks: [StepTextMark] = []
            var cursor = step.text.startIndex
            for (range, reference) in placed {
                let written = String(step.text[range])
                guard let quantity = StepReferencesPrompt.quantity(in: written) else { continue }
                if cursor < range.lowerBound { segments.append(.text(String(step.text[cursor..<range.lowerBound]))) }
                // "je ¼ TL", "à 40 g", "3 cm": the same per piece however
                // many pieces there are — the prompt asks for these not to
                // come back as amounts, and this catches the ones that do.
                let scale = StepAmountScaling.scalesWithServings(quantity.quantity.unit, writtenRange: range, in: step.text)
                    ? factor(forLine: reference.line)
                    : 1
                segments.append(.amount(Self.scaled(written, quantity: quantity, by: scale, formatter: formatter)))
                cursor = range.upperBound
                marks.append(StepTextMark(
                    kind: reference.line == nil ? .loose : .bound,
                    range: range,
                    ingredientName: reference.line.flatMap { lines.indices.contains($0 - 1) ? lines[$0 - 1].name : nil }
                ))
            }
            if cursor < step.text.endIndex { segments.append(.text(String(step.text[cursor...]))) }
            rendition.segmentsByStep[step.id] = segments.isEmpty ? [.text(step.text)] : segments
            rendition.marksByStep[step.id] = marks.compactMap { $0.trimmed(in: step.text) }

            // Chips: every line the step takes by name, share or implication —
            // once, and not where the sentence already prints its amount.
            let printed = Set(referencesInStep.filter { $0.kind == .amount }.compactMap(\.line))
            var chips: [RecipeIngredient] = []
            for reference in referencesInStep where reference.kind == .mention {
                guard let line = reference.line, lines.indices.contains(line - 1), !printed.contains(line) else { continue }
                var chip = lines[line - 1]
                if let index = chips.firstIndex(where: { $0.id == chip.id }) {
                    // A second quote for the same line: keep the one that
                    // says how much.
                    guard chips[index].quantity == nil, reference.amount != nil else { continue }
                    chips.remove(at: index)
                }
                chip.resolvedGrams = nil
                if let written = reference.amount.flatMap(StepReferencesPrompt.quantity(in:)) {
                    var quantity = written.quantity
                    // "3" for a line of "3 Zehen Knoblauch": a bare count
                    // means the line's own unit, not three pieces of garlic.
                    if quantity.unit == .piece, let lineUnit = lines[line - 1].quantity?.unit, lineUnit != .piece {
                        quantity = Quantity(quantity.amount, lineUnit)
                    }
                    chip.quantity = quantity.scaled(by: factor(forLine: line))
                    chip.size = written.size
                } else {
                    // Named without an amount: the model could not say how
                    // much, so the chip says nothing either.
                    chip.quantity = nil
                    chip.size = nil
                }
                chips.append(chip)
            }
            rendition.chipsByStep[step.id] = chips
        }
        return rendition
    }
}

extension Recipe {
    /// `written` at `factor` — both ends of a span like "3-4 EL", which
    /// read as a single amount would lose its upper bound.
    fileprivate static func scaled(
        _ written: String,
        quantity: (quantity: Quantity, size: IngredientSize?),
        by factor: Double,
        formatter: QuantityFormatter
    ) -> String {
        guard factor != 1 else { return written }
        if let span = written.wholeMatch(of: /(\d+(?:[.,]\d+)?)\s*[-–]\s*(\d+(?:[.,]\d+)?)\s*(.*)/),
           let low = StepReferencesPrompt.quantity(in: "\(span.1) \(span.3)"),
           let high = StepReferencesPrompt.quantity(in: "\(span.2) \(span.3)") {
            let lowText = formatter.string(for: low.quantity.scaled(by: factor), size: low.size)
            let highText = formatter.string(for: high.quantity.scaled(by: factor), size: high.size)
            // One unit for the pair where both ends landed in the same one.
            let unit = highText.drop(while: { !$0.isWhitespace })
            if !unit.isEmpty, lowText.hasSuffix(unit) {
                return "\(lowText.dropLast(unit.count))–\(highText)"
            }
            return "\(lowText) – \(highText)"
        }
        return formatter.string(for: quantity.quantity.scaled(by: factor), size: quantity.size)
    }
}

/// Builds the prompt the cook copies into a chat app, and reads back what
/// they paste. See ``StepReferences``.
public enum StepReferencesPrompt {
    /// Part of the fingerprint: a changed prompt asks a different question,
    /// so answers to the old one should not pass for answers to the new.
    static let version = "v2"

    static let rules = """
    Du liest ein deutsches Rezept. Für jeden Zubereitungsschritt sagst du, \
    welche Zeilen der Zutatenliste der Schritt verwendet und wie viel davon.

    Jeder Eintrag hat:
    - "art": "menge", wenn im Satz eine Mengenangabe dieser Zutat steht \
    ("200 g", "2 EL", "3"). Dann gehört dazu "stelle": genau diese \
    Mengenangabe, so wie sie im Schritt steht (gleiche Schreibweise, gleiche \
    Brüche, ohne Zutatennamen), und "vorkommen": das wievielte Vorkommen \
    dieses Wortlauts im Schritt gemeint ist, sonst 1. Steht die Zutat nicht in \
    der Liste ("300 ml Wasser"), ist "zeile" null.
    - "art": "bezug", wenn der Schritt eine Zutat ohne eigene Zahl verwendet: \
    beim Namen ("Zwiebeln"), als Anteil ("die Hälfte der Butter"), als \
    Sammelbegriff ("die trockenen Zutaten" — ein Eintrag je gemeinter Zeile) \
    oder nur gemeint ("abschmecken" für Salz). Ohne "stelle".
    - "zeile": die Nummer der Zutatenzeile (Z-Nummer ohne Z).
    - "menge": was dieser Schritt von der Zeile nimmt, mit der Einheit der \
    Zeile und ohne Zutatennamen: "150 g", "½ TL", "2 Zehen", "1" — nicht \
    "1 Schalotte". \
    "Die Hälfte", "den Rest", "je ¼ TL" bei mehreren Stücken rechnest du um. \
    Hat die Zeile keine Menge (Salz, "etwas Öl"), bleibt "menge" leer. \
    Runde so, wie ein Rezept es schreiben würde: "85 g" statt "83,3 g", \
    "⅓ TL" statt "0,33 TL".

    Regeln:
    - Pro Schritt höchstens ein Eintrag je Zeile. Nimmt ein Schritt eine Zeile \
    in mehreren Teilen ("⅓ Mozzarella", dann "die übrigen Zutaten ebenso"), \
    ist das ein Eintrag mit der Summe. Ausnahme: mehrere geschriebene \
    Mengenangaben derselben Zutat im Satz — jede ist ein eigener "menge"-Eintrag.
    - Wird eine Zutat erst ganz vorbereitet und später aufgeteilt ("Kürbis \
    würfeln", dann "die Hälfte vom Kürbis", dann "die restlichen Kürbiswürfel"), \
    bekommt der Vorbereitungsschritt die ganze Menge und jeder spätere Schritt \
    seinen Anteil davon.
    - Nennt ein Schritt eine Zutat, die ein früherer Schritt schon vollständig \
    verarbeitet hat ("die Zwiebeln glasig dünsten" nach "Zwiebeln würfeln"), \
    gibt es dafür keinen Eintrag.
    - Zahlen, die keine Zutatenmenge sind — Temperaturen, Zeiten, Größen wie \
    "3 cm", Stückzahlen des Ergebnisses wie "24 Kugeln" —, bekommen keinen \
    Eintrag.
    - Mengen pro Stück ("je ¼ TL Salz", "à 40 g") bleiben gleich, wenn das \
    Rezept verdoppelt wird, und sind deshalb keine "menge": Nimm die Zutat \
    als "bezug" mit der Gesamtmenge ("menge": "1 TL" bei vier Stücken).
    - Salz für Koch- oder Nudelwasser ("in Salzwasser garen") ist ein "bezug" \
    auf die Salz-Zeile ohne Menge.
    - Nur Zeilen aus der Liste, keine erfundenen Zutaten. Schritte ohne Zutaten \
    bekommen eine leere Liste.
    - "hinweise" ist für die Person, die das Rezept pflegt, und nur für genau \
    diese drei Fälle, je ein kurzer Satz: (1) Die Schritte nennen mehr oder \
    eine andere Menge einer Zutat als die Liste. (2) Ein Schritt verwendet eine \
    Zutat, die in der Liste fehlt. (3) Eine Zeile der Liste kommt in keinem \
    Schritt vor. Nicht dazu zählen: Wasser (auch Koch-, Nudel- und Salzwasser), \
    Serviervorschläge ("dazu passt Reis") und Zutaten, die als Alternative oder \
    Variante gekennzeichnet sind. Erkläre keine eigenen Annahmen oder \
    Zuordnungen. Trifft keiner der drei Fälle zu, bleibt "hinweise" leer.

    Antworte ausschließlich mit einem JSON-Codeblock in genau dieser Form, \
    ein Eintrag pro Schritt, in Schrittreihenfolge:

    ```json
    {"schritte": [{"schritt": 1, "bezuege": [{"art": "menge", "stelle": "200 g", "vorkommen": 1, "zeile": 1, "menge": "200 g"}, {"art": "bezug", "zeile": 4, "menge": "50 g"}]}], "hinweise": []}
    ```
    """

    /// The whole text to copy: rules, answer format, and the recipe with its
    /// lines and steps numbered.
    public static func prompt(for recipe: Recipe) -> String {
        "\(rules)\n\nRezept: \(recipe.title)\n\(body(for: recipe))"
    }

    /// Hash of what the model is shown about the recipe, title aside —
    /// renaming a dish does not change what its steps refer to.
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
        /// A quoted amount the step does not contain — dropped, as there is
        /// nothing to scale.
        case notInStep(step: Int, text: String)
        /// A quoted amount that does not read as one; it is left unscaled.
        case unreadableAmount(step: Int, text: String)
        /// The amounts the steps write add up to more than the line holds —
        /// the recipe's text and its list disagree.
        case overbooked(line: Int, percent: Int)
    }

    public struct Reading: Sendable {
        public let references: StepReferences
        public let warnings: [Warning]
        /// What the model noticed does not add up between the steps and the
        /// ingredient list — for the cook to fix in the recipe, not stored.
        public let notes: [String]
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
                let bezuege: [Item]
            }
            struct Item: Decodable {
                let art: String?
                let stelle: String?
                let vorkommen: Int?
                let zeile: Int?
                let menge: String?
            }
            let schritte: [Step]
            let hinweise: [String]?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(pasted[open...close].utf8)) else {
            return .failure(.unreadable)
        }

        let lines = recipe.ingredients
        let steps = recipe.steps
        var referencesByStep = Array(repeating: [StepReferences.Reference](), count: steps.count)
        var warnings: [Warning] = []
        var taken: [Int: Quantity] = [:]
        for step in answer.schritte {
            guard steps.indices.contains(step.schritt - 1) else {
                return .failure(.unknownStep(step.schritt))
            }
            let stepText = steps[step.schritt - 1].text
            for item in step.bezuege {
                if let line = item.zeile, !lines.indices.contains(line - 1) {
                    return .failure(.unknownLine(step: step.schritt, line: line))
                }
                let kind: StepReferences.Reference.Kind = item.art?.lowercased() == "menge" ? .amount : .mention
                // Only an amount written in the sentence is anchored in it —
                // a mention's words, where a model quotes them anyway, have
                // nothing to do and are dropped.
                let text = kind == .amount ? (item.stelle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let amount = item.menge.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
                let reference = StepReferences.Reference(
                    kind: kind, text: text, occurrence: kind == .amount ? max(item.vorkommen ?? 1, 1) : 1, line: item.zeile, amount: amount
                )

                switch kind {
                case .amount:
                    // Nothing to scale without the words in the sentence.
                    guard !text.isEmpty else { continue }
                    guard StepReferences.range(of: reference, in: stepText) != nil else {
                        warnings.append(.notInStep(step: step.schritt, text: text))
                        continue
                    }
                    if quantity(in: text) == nil {
                        warnings.append(.unreadableAmount(step: step.schritt, text: text))
                    }
                case .mention:
                    guard reference.line != nil else { continue }
                }

                // Only what the text itself writes is held against the line:
                // a chain that prepares all of it and hands out shares later
                // adds up past the line by design.
                if kind == .amount, let line = reference.line, let counted = quantity(in: text)?.quantity {
                    taken[line] = taken[line].map { $0.adding(counted) ?? $0 } ?? counted
                }
                appendMerging(reference, to: &referencesByStep[step.schritt - 1])
            }
        }
        for (line, sum) in taken.sorted(by: { $0.key < $1.key }) {
            guard let total = lines[line - 1].quantity else { continue }
            // Only like with like: 400 g of a line written "2 große
            // Kartoffeln" is not two hundred times the line.
            let share: Double? = if sum.unit.dimension == total.unit.dimension, sum.unit.dimension != .imprecise,
                                    let a = sum.inBaseUnit, let b = total.inBaseUnit, b > 0 {
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
        let notes = (answer.hinweise ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return .success(Reading(
            references: StepReferences(fingerprint: fingerprint(for: recipe), steps: referencesByStep),
            warnings: warnings,
            notes: notes
        ))
    }

    /// Adds `reference` to a step's list — or, for a second mention of a
    /// line the step already takes, folds it into that one: "⅓ Mozzarella"
    /// and "die übrigen ebenso" are one chip of the whole, not two.
    private static func appendMerging(_ reference: StepReferences.Reference, to list: inout [StepReferences.Reference]) {
        guard reference.kind == .mention, let line = reference.line,
              let index = list.firstIndex(where: { $0.kind == .mention && $0.line == line })
        else {
            list.append(reference)
            return
        }
        let existing = list[index]
        switch (existing.amount.flatMap(quantity(in:)), reference.amount.flatMap(quantity(in:))) {
        case let (.some(first), .some(second)):
            guard let sum = first.quantity.adding(second.quantity) else { return }
            let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))
            list[index].amount = formatter.string(for: sum, size: first.size)
        case (.none, .some):
            list[index].amount = reference.amount
        default:
            break
        }
    }

    /// Whether `text` reads as an amount — for an editor to flag what it
    /// would have to show without one.
    public static func readsAsAmount(_ text: String) -> Bool {
        quantity(in: text) != nil
    }

    /// An amount as written, read the way an ingredient line would be —
    /// "150 g", "½ TL", "1 kleine".
    static func quantity(in amount: String) -> (quantity: Quantity, size: IngredientSize?)? {
        let parsed = IngredientParser.parseLine("\(amount) x")
        if let quantity = parsed.quantity { return (quantity, parsed.size) }
        // What a sentence writes where a list would write a digit: "etwa
        // 25 g", "einer Prise", "Zwei".
        var words = amount.split(separator: " ").map(String.init)
        if let first = words.first, approximationWords.contains(first.lowercased()) { words.removeFirst() }
        if let first = words.first, let number = numberWords[first.lowercased()] { words[0] = number }
        let rewritten = words.joined(separator: " ")
        guard rewritten != amount else { return nil }
        let retried = IngredientParser.parseLine("\(rewritten) x")
        return retried.quantity.map { ($0, retried.size) }
    }

    private static let approximationWords: Set<String> = ["etwa", "ca.", "ca", "circa", "ungefähr", "rund", "knapp"]
    private static let numberWords: [String: String] = [
        "ein": "1", "eine": "1", "einer": "1", "einen": "1", "einem": "1",
        "zwei": "2", "drei": "3", "vier": "4", "fünf": "5", "sechs": "6", "acht": "8", "zehn": "10",
    ]
}
