import Foundation

/// Who answers the optimization prompt: prompt in, answer text out.
///
/// The first one is the cook's own chat, by copy and paste. Apple
/// Intelligence with Private Cloud Compute, a model embedded on the Mac or an
/// API endpoint can follow as further conformances. None of them changes
/// what Sous does with the answer: ``RecipeOptimizationPrompt/read(_:for:catalog:nutritionCatalog:)``
/// checks every one of them the same way, and only what passes is offered.
public protocol RecipeOptimizationBackend: Sendable {
    /// The model's answer to `prompt`, as the text it wrote.
    func answer(to prompt: String) async throws -> String
}

public enum RecipeOptimizer {
    /// Asks `backend` about `recipe` and checks what comes back.
    public static func optimize(
        _ recipe: Recipe,
        catalog: IngredientCatalog = .bundled,
        nutritionCatalog: NutritionCatalog = .bundled,
        backend: some RecipeOptimizationBackend
    ) async throws -> Result<RecipeOptimization, RecipeOptimizationPrompt.Failure> {
        let prompt = RecipeOptimizationPrompt.prompt(for: recipe, catalog: catalog)
        let answer = try await backend.answer(to: prompt)
        return RecipeOptimizationPrompt.read(answer, for: recipe, catalog: catalog, nutritionCatalog: nutritionCatalog)
    }
}

/// A recipe prepared for Sous by a chat model, checked, and waiting for the
/// cook to take it — or parts of it.
///
/// The model rewrites every ingredient line into the line principle's form
/// (amount, unit, the raw ingredient as bought): preparation becomes a step,
/// alternatives move into the notes, noise is dropped. It classifies the
/// names the catalog does not know, and it reads the steps' references
/// against the new lines in the same answer.
///
/// The model proposes; the fixed reader decides. Every line change passes
/// the checks of INGREDIENTS-DATA §3 L or is refused, and a refused change
/// leaves the line as written. The model never supplies a number, a
/// category or a parent: amounts must stand in the line already, and where a
/// measured line loses its preparation, Sous weighs it from the catalog.
public struct RecipeOptimization: Sendable {
    /// One line of the list as written, and what the model makes of it.
    public struct Line: Identifiable, Hashable, Sendable {
        public enum Change: String, Hashable, Sendable {
            /// Words dropped that change nothing about the purchase.
            case noise
            /// Preparation words moved out of the line, into a step.
            case preparation
            /// An alternative moved into the notes.
            case alternative
            /// A misspelled name corrected.
            case typo
            /// Two ingredients in one line, now two lines.
            case split
            /// The line goes, with the group that offered alternatives.
            case group
        }

        public enum Issue: Hashable, Sendable {
            /// An amount other than the line's own — refused.
            case amountChanged(from: String, to: String)
            /// An amount where the line has none — refused.
            case amountInvented(String)
            /// The line's amount is gone — refused.
            case amountDropped(String)
            /// A word the line does not contain — refused: lines are never
            /// exchanged for other words.
            case newWord(String)
            /// A correction more than one edit away — refused.
            case typoTooFar(wrong: String, right: String)
            /// A correction of a word the line does not contain — refused.
            case typoNotInLine(String)
            /// A correction after which the line still means nothing known —
            /// refused.
            case typoDoesNotResolve(String)
            /// The line would go without its content going anywhere — refused.
            case removedWithoutPlace
            /// The model says the line means `claimed`; Sous reads `read`.
            case readsAs(line: String, claimed: String, read: String?)
            /// The model names an ingredient the catalog does not have.
            case unknownClaim(String)
            /// One amount now stands in several lines.
            case amountRepeated
            /// The measure was of the prepared ingredient, and the catalog has
            /// no weight to turn it into: "1 TL Zitrone" measures nothing.
            case unweighed(String)

            /// Whether the change is refused outright, rather than offered
            /// unticked.
            public var refuses: Bool {
                switch self {
                case .amountChanged, .amountInvented, .amountDropped, .newWord,
                     .typoTooFar, .typoNotInLine, .typoDoesNotResolve, .removedWithoutPlace:
                    true
                case .readsAs, .unknownClaim, .amountRepeated, .unweighed:
                    false
                }
            }
        }

        /// A corrected word, as it stood and as it is proposed.
        public struct Typo: Hashable, Sendable {
            public let wrong: String
            public let right: String
            /// Whether the model said so, rather than Sous noticing it.
            public let declared: Bool
        }

        /// A measured amount Sous weighed, because the measure was of the
        /// prepared ingredient: "1 TL" grated ginger is not 1 TL of a root.
        public struct Weighing: Hashable, Sendable {
            public let from: Quantity
            public let grams: Double
        }

        public var id: Int { number }
        /// 1-based, as numbered in the prompt.
        public let number: Int
        public let written: String
        public let group: String?
        /// What takes the line's place: usually one line, two for a split,
        /// none where the line goes. Weighed already, where Sous weighed.
        public let rewritten: [String]
        public let changes: Set<Change>
        /// The words that became a step.
        public let preparation: String?
        /// What goes into the recipe's notes with this change.
        public let note: String?
        public let typos: [Typo]
        public let weighing: Weighing?
        public let issues: [Issue]
        /// Whether every rewritten line reads as an ingredient the catalog
        /// knows.
        public let resolves: Bool

        public var isRefused: Bool { issues.contains(where: \.refuses) }
        public var isChanged: Bool { rewritten != [written] || note != nil }
        /// Offered ticked: a change that passed every check and asks for no
        /// look. A typo never is (R4), nor anything with a caution.
        public var isPreTicked: Bool {
            isChanged && !isRefused && issues.isEmpty && typos.isEmpty && !changes.contains(.group)
        }
    }

    /// A preparation step the model proposes, where no step says it yet.
    public struct NewStep: Identifiable, Hashable, Sendable {
        /// Its place in the answer's list of steps.
        public let id: Int
        /// The step it goes before, 1-based; `nil` for after the last.
        public let before: Int?
        public let text: String
    }

    /// What the model says about a name the catalog does not know.
    public struct Classification: Identifiable, Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable, CaseIterable {
            case alias
            case variety = "sorte"
            case new = "neu"
            case wording = "formulierung"
            case typo = "tippfehler"
            case household = "haushalt"
            case product = "produkt"

            public var title: String {
                switch self {
                case .alias: "anderes Wort für"
                case .variety: "Sorte von"
                case .new: "neu"
                case .wording: "Formulierung für"
                case .typo: "Tippfehler für"
                case .household: "Haushaltswort für"
                case .product: "Produkt, zählt wie"
                }
            }
        }

        public var id: Int { line }
        public let line: Int
        public let name: String
        public let kind: Kind
        /// The catalog's name for what it is, where one fits fairly.
        public let target: String?
        /// Where the line still reads as unknown after the rewrite: the
        /// "zählt wie" this would give. Stored from phase 6 on; until then
        /// only reported.
        public let countsAs: String?
    }

    /// An ingredient group headed as alternatives ("# Alternative").
    public struct GroupProposal: Identifiable, Hashable, Sendable {
        public enum Action: String, Hashable, Sendable {
            case remove = "entfernen"
            case variant = "variante"
            case keep = "behalten"
        }

        public var id: String { name }
        public let name: String
        public let action: Action
        public let reason: String?
        /// The group's lines, 1-based.
        public let lines: [Int]
        public let variant: VariantProposal?
    }

    /// A different dish the alternatives describe, as a recipe of its own.
    public struct VariantProposal: Hashable, Sendable {
        public let title: String
        public let ingredientsText: String
        public let instructionsText: String
        /// Lines carrying an amount the recipe does not write anywhere.
        public let foreignAmounts: [String]
    }

    /// What the cook takes.
    public struct Selection: Hashable, Sendable {
        public var lines: Set<Int>
        public var steps: Set<Int>
        public var groups: Set<String>

        public init(lines: Set<Int> = [], steps: Set<Int> = [], groups: Set<String> = []) {
            self.lines = lines
            self.steps = steps
            self.groups = groups
        }
    }

    /// The recipe as it reads with a selection taken.
    public struct Applied: Sendable {
        public let recipe: Recipe
        /// The step references read against the new text, or `nil` where they
        /// could not be (nothing is lost: the steps then show as written).
        public let reading: StepReferencesPrompt.Reading?
    }

    /// The recipe the answer was made for.
    public let recipe: Recipe
    public let lines: [Line]
    public let newSteps: [NewStep]
    public let classifications: [Classification]
    public let groups: [GroupProposal]
    /// What the model noticed does not add up.
    public let notes: [String]

    /// The answer's steps, in its order: an old step by number or a new one
    /// by id, each with its references numbered by the answer's new lines.
    fileprivate let answerSteps: [(step: AnswerStep, items: [StepReferencesPrompt.AnswerItem])]
    /// Answer line number → (old line, index among its rewritten lines).
    fileprivate let answerLines: [Int: (line: Int, index: Int)]

    fileprivate enum AnswerStep: Sendable {
        case old(Int)
        case new(Int)
    }

    /// What is ticked when the preview opens.
    public var defaultSelection: Selection {
        Selection(
            lines: Set(lines.filter(\.isPreTicked).map(\.number)),
            steps: Set(newSteps.map(\.id)),
            groups: Set(groups.filter { $0.action != .keep }.map(\.name))
        )
    }

    /// Whether the answer changes anything at all.
    public var changesAnything: Bool {
        lines.contains(where: \.isChanged) || !newSteps.isEmpty || groups.contains { $0.action != .keep }
    }

    /// The "zählt wie" proposals: names that stay unknown after the rewrite
    /// and have a fair stand-in in the catalog.
    public var countsAsProposals: [Classification] {
        classifications.filter { $0.countsAs != nil }
    }
}

// MARK: - Applying

extension RecipeOptimization {
    /// `recipe` with `selection` taken: the chosen lines rewritten, the
    /// chosen steps inserted, the chosen groups gone, their notes appended —
    /// and everything else exactly as written. The step references are
    /// mapped onto the result and stamped with its fingerprint.
    public func applied(_ selection: Selection) -> Applied {
        let removedGroups = Set(groups.filter { $0.action != .keep && selection.groups.contains($0.name) }.map(\.name))
        func isTaken(_ line: Line) -> Bool {
            if let group = line.group, removedGroups.contains(group) { return true }
            if line.changes.contains(.group) { return false }
            return !line.isRefused && selection.lines.contains(line.number)
        }
        func finalTexts(of line: Line) -> [String] {
            if let group = line.group, removedGroups.contains(group) { return [] }
            return isTaken(line) ? line.rewritten : [line.written]
        }

        // Ingredients, in place: headings, blank lines and untouched lines
        // stay as typed.
        let written = IngredientParser.writtenLines(in: recipe.ingredientsText)
        var replacement: [Int: [String]] = [:]
        for (index, entry) in written.enumerated() where lines.indices.contains(index) {
            replacement[entry.textLine] = finalTexts(of: lines[index])
        }
        let ingredientsText = Self.rebuilt(recipe.ingredientsText, replacing: replacement)

        // Steps: the new ones before the step they precede.
        let takenSteps = newSteps.filter { selection.steps.contains($0.id) }
        let stepLines = StepParser.writtenLines(in: recipe.instructionsText)
        var insertions: [Int: [String]] = [:]
        var trailing: [String] = []
        for step in takenSteps {
            if let before = step.before, stepLines.indices.contains(before - 1) {
                insertions[stepLines[before - 1].textLine, default: []].append(step.text)
            } else {
                trailing.append(step.text)
            }
        }
        let instructionsText = Self.inserting(insertions, trailing: trailing, into: recipe.instructionsText)

        // Notes: appended, each once.
        var notes = recipe.notes ?? ""
        for line in lines where isTaken(line) {
            guard let note = line.note, !notes.contains(note) else { continue }
            notes += (notes.isEmpty || notes.hasSuffix("\n") ? "" : "\n") + note
        }

        var result = recipe
        result.ingredientsText = ingredientsText
        result.instructionsText = instructionsText
        result.notes = notes.isEmpty ? nil : notes

        // References: the answer numbered the lines as if every change were
        // taken; map each onto where it stands now.
        var finalLine: [Int: Int] = [:] // old line number → first final line
        var finalCount = 0
        for line in lines {
            finalLine[line.number] = finalCount + 1
            finalCount += finalTexts(of: line).count
        }
        func mappedLine(_ answerLine: Int?) -> (line: Int?, weighing: Line.Weighing?)? {
            guard let answerLine else { return (nil, nil) }
            guard let position = answerLines[answerLine],
                  let line = lines.first(where: { $0.number == position.line }),
                  let first = finalLine[position.line]
            else { return nil }
            let texts = finalTexts(of: line)
            if texts.isEmpty { return nil }
            if isTaken(line) {
                return position.index < texts.count ? (first + position.index, line.weighing) : nil
            }
            return (first, nil)
        }

        var steps: [(schritt: Int, bezuege: [StepReferencesPrompt.AnswerItem])] = []
        var stepNumber = 0
        for (step, items) in answerSteps {
            switch step {
            case .old: break
            case .new(let id): guard selection.steps.contains(id) else { continue }
            }
            stepNumber += 1
            var mapped: [StepReferencesPrompt.AnswerItem] = []
            for var item in items {
                guard let target = mappedLine(item.zeile) else {
                    // A line that is gone: a written amount still scales
                    // with the servings, a mention has nothing to show.
                    if item.art?.lowercased() == "menge" {
                        item.zeile = nil
                        mapped.append(item)
                    }
                    continue
                }
                item.zeile = target.line
                if let weighing = target.weighing, let amount = item.menge {
                    item.menge = Self.weighed(amount, by: weighing) ?? amount
                }
                mapped.append(item)
            }
            steps.append((stepNumber, mapped))
        }
        let reading = try? StepReferencesPrompt.reading(steps: steps, notes: self.notes, for: result).get()
        result.stepReferences = reading?.references
        return Applied(recipe: result, reading: reading)
    }

    /// A chip's amount in the unit Sous weighed the line from, in grams.
    fileprivate static func weighed(_ amount: String, by weighing: Line.Weighing) -> String? {
        guard let quantity = StepReferencesPrompt.quantity(in: amount)?.quantity,
              quantity.unit == weighing.from.unit, weighing.from.amount > 0
        else { return nil }
        let grams = weighing.grams * quantity.amount / weighing.from.amount
        return QuantityFormatter(locale: Locale(identifier: "de_DE")).string(for: Quantity(roundedGrams(grams), .gram), size: nil)
    }

    /// `text` with the lines at the given indices replaced — by nothing, one
    /// line or several — and a heading dropped whose lines are all gone.
    static func rebuilt(_ text: String, replacing replacement: [Int: [String]]) -> String {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Which text lines belong under which heading, to drop a heading
        // left without lines.
        var headingOf: [Int: Int] = [:]
        var currentHeading: Int?
        for (index, raw) in rawLines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if IngredientParser.isGroupHeading(trimmed) {
                currentHeading = index
            } else if replacement[index] != nil, let currentHeading {
                headingOf[index] = currentHeading
            }
        }
        var emptied = Set<Int>()
        for heading in Set(headingOf.values) {
            let members = headingOf.filter { $0.value == heading }.map(\.key)
            if members.allSatisfy({ replacement[$0]?.isEmpty == true }) { emptied.insert(heading) }
        }

        var output: [String] = []
        for (index, raw) in rawLines.enumerated() {
            if emptied.contains(index) { continue }
            if let lines = replacement[index] {
                output.append(contentsOf: lines)
            } else {
                output.append(raw)
            }
        }
        // No run of blank lines where a whole block went.
        var collapsed: [String] = []
        for line in output {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, collapsed.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true { continue }
            collapsed.append(line)
        }
        while let last = collapsed.last, last.trimmingCharacters(in: .whitespaces).isEmpty { collapsed.removeLast() }
        return collapsed.joined(separator: "\n")
    }

    /// `text` with new lines before the given text lines, and at the end.
    static func inserting(_ insertions: [Int: [String]], trailing: [String], into text: String) -> String {
        var output: [String] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            output.append(contentsOf: insertions[index] ?? [])
            output.append(String(raw))
        }
        while let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty { output.removeLast() }
        output.append(contentsOf: trailing)
        return output.joined(separator: "\n")
    }

    /// Grams as a recipe writes them: halves below ten, whole grams below a
    /// hundred, fives above.
    static func roundedGrams(_ grams: Double) -> Double {
        switch grams {
        case ..<10: max((grams * 2).rounded() / 2, 0.5)
        case ..<100: grams.rounded()
        default: (grams / 5).rounded() * 5
        }
    }
}

// MARK: - Reporting

extension RecipeOptimization {
    /// The classifications as text to send to the curator — the way to
    /// share them until local answers exist (phase 6).
    public func report(_ chosen: [Classification]) -> String {
        var text = "Sous – Vorschläge für den Zutatenkatalog\nRezept: \(recipe.title)\n"
        for item in chosen {
            let target = item.target.map { " \($0)" } ?? ""
            text += "- „\(item.name)“: \(item.kind.title)\(target)\n"
        }
        return text
    }
}

// MARK: - The prompt

/// Builds the optimization prompt (v3) and reads the answer. See
/// ``RecipeOptimization``.
///
/// The step references it asks for are the same references as v2's, read by
/// the same reader and stamped with the same fingerprint scheme — only over
/// the new text. That is why this prompt's version is its own: answers to
/// v2 stay current, and nothing becomes stale by this prompt existing.
public enum RecipeOptimizationPrompt {
    static let version = "v3"

    static let rules = """
    Du bereitest ein deutsches Rezept für die Koch-App Sous vor. Eine Antwort, \
    zwei Teile: Teil A schreibt die Zutatenzeilen in eine feste Form um. Teil B \
    sagt für jeden Zubereitungsschritt, welche der neuen Zeilen er verwendet.

    TEIL A — DIE ZEILEN

    Eine Zeile nennt die Rohzutat so, wie man sie kauft: Menge, Einheit, Zutat. \
    Sonst nichts.
    - Zubereitung wird ein Schritt. "1 TL Ingwer, frisch gerieben" wird \
    "1 TL Ingwer" mit "zubereitung": "frisch gerieben". Sagt noch kein Schritt, \
    dass der Ingwer gerieben wird, bekommt Teil B einen neuen Schritt ("Ingwer \
    schälen und fein reiben.") direkt vor dem ersten Schritt, der ihn verwendet. \
    Sagt es ein Schritt schon ("den geriebenen Ingwer dazugeben"), kommt kein \
    Schritt dazu.
    - Alternativen kommen in die Notizen. "1,5 TL Kreuzkümmel, gemahlen - \
    (ersatzweise Zimtpulver)" wird "1,5 TL Kreuzkümmel, gemahlen" mit "notiz": \
    "Statt Kreuzkümmel geht auch Zimtpulver." Ebenso Beispiele ("Nudeln, z. B. \
    Penne oder Tagliatelle") und Formen ("Paprikapulver, mild oder scharf"). \
    Sagen die Notizen des Rezepts es schon, entfällt die "notiz".
    - Störtext fällt weg: Bindestriche, Selbstverständliches und Hinweise ohne \
    Einfluss auf den Einkauf. "250 g rote Linsen - (getrocknet)" wird "250 g \
    rote Linsen", denn rote Linsen kauft man getrocknet. Ebenso "gerne Bio", \
    "selbstgemacht oder Fertigprodukt", "zum Servieren".
    - Eine Kaufform bleibt nur, wenn sie ein anderes Produkt bedeutet: \
    "getrocknete Tomaten", "Kreuzkümmel, gemahlen", "stückige Tomaten", \
    "entsteinte Datteln", "geriebener Käse", "fettarmer Joghurt" bleiben. Was \
    man so kaufen kann, ist keine Zubereitung.
    - Größenangaben gehören zur Menge und bleiben: "1 große Zwiebel".
    - Zwei Zutaten in einer Zeile werden zwei neue Zeilen ("Salz und Pfeffer").
    - Mengen und Einheiten übernimmst du genau so, wie sie dastehen. Du rechnest \
    nichts um und schreibst keine Zahl, die nicht in der Zeile steht. Nur ein \
    Gewicht, das für die ganze Zeile gilt, darf die Menge werden: "1 Dose \
    stückige Tomaten (400 g)" wird "400 g stückige Tomaten". Ein Abtropfgewicht \
    bleibt in Klammern stehen: "1 Dose Kidneybohnen (Abtropfgewicht 500 g)".
    - Du behältst die Wörter des Rezepts. Du tauschst nie eine Zutat gegen einen \
    Katalognamen ("Möhren" bleiben "Möhren") und fügst keine Wörter hinzu. Du \
    darfst Wörter streichen, umstellen und beugen ("Tomaten, getrocknet" wird \
    "getrocknete Tomaten") und ein Einheitenwort abtrennen ("3 Knoblauchzehen" \
    wird "3 Zehen Knoblauch").
    - Einen Tippfehler korrigierst du nur, wenn das richtige Wort genau eine \
    Änderung entfernt ist (ein Buchstabe mehr, weniger, anders, oder zwei \
    vertauscht): "Chiabatta" wird "Ciabatta", mit "tippfehler": {"falsch": \
    "Chiabatta", "richtig": "Ciabatta"}. Ein anderes Wort, das nur ähnlich \
    aussieht, ist kein Tippfehler: "Margarine" bleibt "Margarine".
    - Eine Zeile, die schon so dasteht, bleibt unverändert.

    Jede Zeile Z1, Z2, … bekommt genau einen Eintrag in "zeilen", in der \
    Reihenfolge der Liste. "neu" sind die Zeilen, die an ihre Stelle treten: \
    meist eine, zwei bei zwei Zutaten, keine, wenn die Zeile wegfällt. Jede neue \
    Zeile hat "nr" (fortlaufend über alle neuen Zeilen, ab 1), "text" und \
    "zutat": den Namen aus der Katalogliste, den die Zeile meint, genau wie dort \
    geschrieben, oder null, wenn der Katalog ihn weder als Namen noch als Alias \
    hat. Eine Zeile fällt nur weg, wenn ihr Inhalt in die Notizen wandert oder \
    ihre Gruppe entfernt wird.

    Unbekannte Namen: Steht der Name einer Zeile nicht im Katalog (weder als Name \
    noch als Alias; Einzahl und Mehrzahl zählen gleich), ordnest du ihn ein: \
    "einordnung": {"name": der Name wie in der Zeile, "art": …, "ziel": ein \
    Katalogname oder null}.
    - "alias": derselbe Einkauf, ein anderes Wort ("Rotkraut" → Rotkohl). \
    Derselbe Einkauf heißt: Mit dem Katalognamen auf dem Einkaufszettel nähme man \
    dasselbe aus dem Regal.
    - "sorte": ein anderer Einkauf derselben Zutat ("Babyspinat" → Spinat). Im \
    Zweifel "sorte".
    - "neu": eine Zutat, die der Katalog nicht hat ("Curryblätter").
    - "formulierung": ein Zubereitungs- oder Einheitenwort macht den Namen \
    unbekannt.
    - "tippfehler": der Name ist falsch geschrieben.
    - "haushalt": eine Formulierung nur dieses Rezepts ("die gelbe Paste aus dem \
    Becher").
    - "produkt": eine Marke oder ein Produkt ("Müsli (Seitenbacher)").
    "ziel" nur, wenn der Katalogname ein fairer Ersatz ist: dieselbe Zutat oder \
    eine Sorte davon, ein Öl für ein Öl, ein Sirup für einen Sirup, ein Kohl für \
    einen Kohl. Sojamilch ist keine Milch. Sonst ist "ziel" null. Namen, die der \
    Katalog kennt, bekommen keine Einordnung.

    Gruppen mit Alternativen: Kündigt eine Zutatengruppe Alternativen an \
    ("[Alternative]"), bekommt sie einen Eintrag in "gruppen" mit "vorschlag":
    - "entfernen", wenn die Alternativen einzelne Tauschmöglichkeiten sind. Ihre \
    Zeilen bekommen "neu": [] und "entfernt": "gruppe"; was die Notizen noch \
    nicht sagen, kommt als "notiz" dazu.
    - "variante" nur, wenn die Alternativen zusammen ein anderes Gericht ergeben, \
    das man eigens plant und einkauft (etwa eine vegane Fassung). Dazu gehört \
    "variante": {"titel": …, "zutaten": [Zeilen], "schritte": [Schritte]}, das \
    ganze andere Rezept, mit Mengen nur aus diesem Rezept. Auch dann bekommen die \
    Zeilen "entfernt": "gruppe".
    - "behalten" in jedem anderen Fall.
    "grund" sagt in einem kurzen Satz, warum.

    TEIL B — DIE SCHRITTE

    Die Schritte bleiben, wie sie sind. "schritte" listet alle Schritte in der \
    neuen Reihenfolge: jeden alten als {"alt": n} (S1 ist 1), in der alten \
    Reihenfolge, und jeden neuen Zubereitungsschritt aus Teil A als {"neu": \
    "Text"} an seiner Stelle. Jeder Eintrag hat "bezuege": welche neuen Zeilen \
    der Schritt verwendet und wie viel davon. Jeder Bezug hat:
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
    - "zeile": die "nr" der neuen Zeile.
    - "menge": was dieser Schritt von der Zeile nimmt, mit der Einheit der \
    neuen Zeile und ohne Zutatennamen: "150 g", "½ TL", "2 Zehen", "1" — nicht \
    "1 Schalotte". "Die Hälfte", "den Rest", "je ¼ TL" bei mehreren Stücken \
    rechnest du um. Hat die Zeile keine Menge (Salz, "etwas Öl"), bleibt \
    "menge" leer. Runde so, wie ein Rezept es schreiben würde: "85 g" statt \
    "83,3 g", "⅓ TL" statt "0,33 TL".

    Regeln für die Bezüge:
    - Pro Schritt höchstens ein Eintrag je Zeile. Nimmt ein Schritt eine Zeile \
    in mehreren Teilen, ist das ein Eintrag mit der Summe. Ausnahme: mehrere \
    geschriebene Mengenangaben derselben Zutat im Satz — jede ist ein eigener \
    "menge"-Eintrag.
    - Wird eine Zutat erst ganz vorbereitet und später aufgeteilt, bekommt der \
    Vorbereitungsschritt die ganze Menge und jeder spätere Schritt seinen Anteil.
    - Nennt ein Schritt eine Zutat, die ein früherer Schritt schon vollständig \
    verarbeitet hat, gibt es dafür keinen Eintrag.
    - Zahlen, die keine Zutatenmenge sind — Temperaturen, Zeiten, Größen wie \
    "3 cm", Stückzahlen des Ergebnisses —, bekommen keinen Eintrag.
    - Mengen pro Stück ("je ¼ TL Salz", "à 40 g") sind keine "menge": Nimm die \
    Zutat als "bezug" mit der Gesamtmenge.
    - Salz für Koch- oder Nudelwasser ist ein "bezug" auf die Salz-Zeile ohne \
    Menge.
    - Nur neue Zeilen, keine erfundenen Zutaten. Schritte ohne Zutaten bekommen \
    eine leere Liste.

    "hinweise" ist für die Person, die das Rezept pflegt, und nur für genau \
    diese drei Fälle, je ein kurzer Satz: (1) Die Schritte nennen mehr oder \
    eine andere Menge einer Zutat als die Liste. (2) Ein Schritt verwendet eine \
    Zutat, die in der Liste fehlt. (3) Eine Zeile der Liste kommt in keinem \
    Schritt vor. Nicht dazu zählen: Wasser (auch Koch-, Nudel- und Salzwasser), \
    Serviervorschläge und Zutaten, die als Alternative oder Variante \
    gekennzeichnet sind. Erkläre keine eigenen Annahmen oder Änderungen. Trifft \
    keiner der drei Fälle zu, bleibt "hinweise" leer.

    Antworte ausschließlich mit einem JSON-Codeblock in genau dieser Form:

    ```json
    {"zeilen": [{"zeile": 1, "neu": [{"nr": 1, "text": "250 g rote Linsen", "zutat": "Rote Linsen"}]}, {"zeile": 2, "neu": [{"nr": 2, "text": "1 TL Ingwer", "zutat": "Ingwer"}], "zubereitung": "frisch gerieben"}, {"zeile": 3, "neu": [{"nr": 3, "text": "1,5 TL Kreuzkümmel, gemahlen", "zutat": "Kreuzkümmel"}], "notiz": "Statt Kreuzkümmel geht auch Zimtpulver."}, {"zeile": 4, "neu": [{"nr": 4, "text": "100 g Babyspinat", "zutat": null}], "einordnung": {"name": "Babyspinat", "art": "sorte", "ziel": "Spinat"}}, {"zeile": 5, "neu": [], "entfernt": "gruppe"}], "gruppen": [{"gruppe": "Alternative", "vorschlag": "entfernen", "grund": "Die Notizen nennen die Alternativen schon."}], "schritte": [{"neu": "Ingwer schälen und fein reiben.", "bezuege": [{"art": "bezug", "zeile": 2, "menge": "1 TL"}]}, {"alt": 1, "bezuege": [{"art": "menge", "stelle": "250 g", "vorkommen": 1, "zeile": 1, "menge": "250 g"}]}], "hinweise": []}
    ```
    """

    /// The whole text to copy: rules, answer format, the catalog, and the
    /// recipe with its lines as written and its steps numbered.
    public static func prompt(for recipe: Recipe, catalog: IngredientCatalog = .bundled) -> String {
        "\(rules)\n\n\(catalogList(catalog))\n\nRezept: \(recipe.title)\n\(body(for: recipe))"
    }

    /// The catalog as the model sees it: "Name | Alias, Alias", no values,
    /// no weights. Keyed by name, not by catalog id, on purpose: the answer
    /// is recipe text, which names things, and a name is unique in the
    /// catalog, so Sous derives the id itself wherever it stores one.
    static func catalogList(_ catalog: IngredientCatalog) -> String {
        let rows = catalog.ingredients.map { ingredient in
            ingredient.aliases.isEmpty ? ingredient.name : "\(ingredient.name) | \(ingredient.aliases.joined(separator: ", "))"
        }
        return "Katalog (Name | Aliasse):\n" + rows.joined(separator: "\n")
    }

    /// Serving count, the lines exactly as written, the steps, the notes.
    static func body(for recipe: Recipe) -> String {
        var text = "Portionen: \(recipe.servings)\n\nZutaten:\n"
        var lastGroup: String?
        for (index, line) in IngredientParser.writtenLines(in: recipe.ingredientsText).enumerated() {
            if let group = line.group, group != lastGroup { text += "[\(group)]\n" }
            lastGroup = line.group
            text += "Z\(index + 1): \(line.text)\n"
        }
        text += "\nZubereitung:\n"
        lastGroup = nil
        for (index, step) in recipe.steps.enumerated() {
            if let group = step.group, group != lastGroup { text += "[\(group)]\n" }
            lastGroup = step.group
            text += "S\(index + 1): \(step.text)\n"
        }
        if let notes = recipe.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            text += "\nNotizen:\n\(notes)\n"
        }
        return text
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noAnswer
        case unreadable
        /// An old line without an entry — the answer skipped it.
        case lineNotCovered(Int)
        /// An old line with two entries.
        case lineCoveredTwice(Int)
        /// A line number the recipe does not have.
        case unknownLine(Int)
        /// Two new lines under one number.
        case duplicateNumber(Int)
        /// The old steps are not all there, once each, in their order.
        case stepsChanged
        /// A reference to a new line that does not exist.
        case unknownNewLine(step: Int, line: Int)

        public var errorDescription: String? {
            switch self {
            case .noAnswer: "In der Zwischenablage steht keine Antwort im erwarteten Format."
            case .unreadable: "Die Antwort hat nicht das erwartete Format. Stammt sie vom Prompt „Für Sous optimieren“?"
            case .lineNotCovered(let line): "Die Antwort lässt Zeile \(line) aus."
            case .lineCoveredTwice(let line): "Die Antwort nennt Zeile \(line) zweimal."
            case .unknownLine(let line): "Die Antwort nennt Zeile \(line), die es in diesem Rezept nicht gibt."
            case .duplicateNumber(let number): "Die Antwort vergibt die neue Zeile \(number) zweimal."
            case .stepsChanged: "Die Antwort lässt Schritte aus oder stellt sie um."
            case .unknownNewLine(let step, let line): "Schritt \(step) nennt eine neue Zeile \(line), die es nicht gibt."
            }
        }
    }

    // MARK: Reading

    private struct Answer: Decodable {
        struct Entry: Decodable {
            struct New: Decodable {
                var nr: Int?
                var text: String
                var zutat: String?

                init(from decoder: Decoder) throws {
                    // A model that writes plain strings instead of objects
                    // still means the lines.
                    if let text = try? decoder.singleValueContainer().decode(String.self) {
                        self.text = text
                        return
                    }
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    nr = try container.decodeIfPresent(Int.self, forKey: .nr)
                    text = try container.decode(String.self, forKey: .text)
                    zutat = try container.decodeIfPresent(String.self, forKey: .zutat)
                }

                enum CodingKeys: String, CodingKey { case nr, text, zutat }
            }
            struct Classification: Decodable {
                var name: String?
                var art: String
                var ziel: String?
            }
            struct Typo: Decodable {
                var falsch: String
                var richtig: String
            }
            var zeile: Int
            var neu: [New]
            var zubereitung: String?
            var notiz: String?
            var tippfehler: Typo?
            var einordnung: Classification?
            var entfernt: String?
        }
        struct Group: Decodable {
            struct Variant: Decodable {
                var titel: String
                var zutaten: [String]
                var schritte: [String]
            }
            var gruppe: String
            var vorschlag: String
            var grund: String?
            var variante: Variant?
        }
        struct Step: Decodable {
            var alt: Int?
            var neu: String?
            var bezuege: [StepReferencesPrompt.AnswerItem]?
        }
        var zeilen: [Entry]
        var gruppen: [Group]?
        var schritte: [Step]
        var hinweise: [String]?
    }

    /// Reads a pasted answer for `recipe` and checks it. The answer is
    /// refused whole where its structure does not fit the recipe (a line
    /// skipped or doubled, a step lost or moved, a reference to no line);
    /// a single line change that fails a check is refused alone, and its
    /// line stays as written.
    public static func read(
        _ pasted: String,
        for recipe: Recipe,
        catalog: IngredientCatalog = .bundled,
        nutritionCatalog: NutritionCatalog = .bundled
    ) -> Result<RecipeOptimization, Failure> {
        guard let open = pasted.firstIndex(of: "{"), let close = pasted.lastIndex(of: "}"), open < close else {
            return .failure(.noAnswer)
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(pasted[open...close].utf8)) else {
            return .failure(.unreadable)
        }

        let written = IngredientParser.writtenLines(in: recipe.ingredientsText)
        let parsed = IngredientParser.parse(recipe.ingredientsText, catalog: catalog)

        // Every old line exactly once.
        var entries: [Int: Answer.Entry] = [:]
        for entry in answer.zeilen {
            guard written.indices.contains(entry.zeile - 1) else { return .failure(.unknownLine(entry.zeile)) }
            guard entries[entry.zeile] == nil else { return .failure(.lineCoveredTwice(entry.zeile)) }
            entries[entry.zeile] = entry
        }
        for number in written.indices.map({ $0 + 1 }) where entries[number] == nil {
            return .failure(.lineNotCovered(number))
        }

        // The new lines' numbers, as the references use them.
        var answerLines: [Int: (line: Int, index: Int)] = [:]
        var nextNumber = 1
        for number in written.indices.map({ $0 + 1 }) {
            let texts = entries[number]!.neu
            for (index, new) in texts.enumerated() {
                let key = new.nr ?? nextNumber
                guard answerLines[key] == nil else { return .failure(.duplicateNumber(key)) }
                answerLines[key] = (number, index)
                nextNumber = key + 1
            }
        }

        // The old steps, all of them, once each, in order.
        let oldSteps = answer.schritte.compactMap(\.alt)
        guard oldSteps == Array(1..<(recipe.steps.count + 1)) else {
            return .failure(.stepsChanged)
        }
        var newSteps: [RecipeOptimization.NewStep] = []
        var answerSteps: [(step: RecipeOptimization.AnswerStep, items: [StepReferencesPrompt.AnswerItem])] = []
        for (position, step) in answer.schritte.enumerated() {
            for item in step.bezuege ?? [] {
                if let line = item.zeile, answerLines[line] == nil {
                    return .failure(.unknownNewLine(step: position + 1, line: line))
                }
            }
            if let old = step.alt {
                answerSteps.append((.old(old), step.bezuege ?? []))
            } else if let text = step.neu.map(singleLine), !text.isEmpty {
                let before = answer.schritte[(position + 1)...].first(where: { $0.alt != nil })?.alt
                newSteps.append(RecipeOptimization.NewStep(id: position, before: before, text: text))
                answerSteps.append((.new(position), step.bezuege ?? []))
            }
        }

        // Groups offering alternatives.
        let groupNames = Set(written.compactMap(\.group))
        var groups: [RecipeOptimization.GroupProposal] = []
        for group in answer.gruppen ?? [] {
            guard let name = groupNames.first(where: { $0.caseInsensitiveCompare(group.gruppe.trimmingCharacters(in: .whitespaces)) == .orderedSame }),
                  !groups.contains(where: { $0.name == name }),
                  let action = RecipeOptimization.GroupProposal.Action(rawValue: group.vorschlag.lowercased())
            else { continue }
            let members = written.indices.filter { written[$0].group == name }.map { $0 + 1 }
            let variant = action == .variant ? group.variante.flatMap { variantProposal($0, recipe: recipe, parsed: parsed) } : nil
            groups.append(.init(
                name: name,
                action: action == .variant && variant == nil ? .remove : action,
                reason: group.grund.flatMap(nonEmpty),
                lines: members,
                variant: variant
            ))
        }
        // Lines marked as leaving with their group, where the answer forgot
        // to propose removing the group.
        for number in written.indices.map({ $0 + 1 }) {
            guard entries[number]!.entfernt?.lowercased() == "gruppe", let name = written[number - 1].group,
                  !groups.contains(where: { $0.name == name })
            else { continue }
            let members = written.indices.filter { written[$0].group == name }.map { $0 + 1 }
            groups.append(.init(name: name, action: .remove, reason: nil, lines: members, variant: nil))
        }

        var lines: [RecipeOptimization.Line] = []
        var classifications: [RecipeOptimization.Classification] = []
        for (index, line) in written.enumerated() {
            let entry = entries[index + 1]!
            let checked = check(
                entry, number: index + 1, written: line.text, group: line.group, parsed: parsed[index],
                inRemovedGroup: line.group.map { name in groups.contains { $0.name == name && $0.action != .keep } } ?? false,
                catalog: catalog, nutritionCatalog: nutritionCatalog
            )
            lines.append(checked)
            if let classification = classify(entry, line: checked, parsed: parsed[index], catalog: catalog) {
                classifications.append(classification)
            }
        }

        let notes = (answer.hinweise ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return .success(RecipeOptimization(
            recipe: recipe,
            lines: lines,
            newSteps: newSteps,
            classifications: classifications,
            groups: groups,
            notes: notes,
            answerSteps: answerSteps,
            answerLines: answerLines
        ))
    }

    // MARK: Checks (§3 L)

    private static func check(
        _ entry: Answer.Entry,
        number: Int,
        written: String,
        group: String?,
        parsed: RecipeIngredient,
        inRemovedGroup: Bool,
        catalog: IngredientCatalog,
        nutritionCatalog: NutritionCatalog
    ) -> RecipeOptimization.Line {
        typealias Line = RecipeOptimization.Line
        var rewritten = entry.neu.map { singleLine($0.text) }.filter { !$0.isEmpty }
        let preparation = entry.zubereitung.flatMap(nonEmpty)
        let note = entry.notiz.flatMap(nonEmpty)
        var changes = Set<Line.Change>()
        var issues: [Line.Issue] = []
        var typos: [Line.Typo] = []

        if entry.entfernt?.lowercased() == "gruppe", group != nil { changes.insert(.group) }
        if rewritten.isEmpty, !changes.contains(.group), note == nil { issues.append(.removedWithoutPlace) }
        if rewritten.count > 1 { changes.insert(.split) }
        if preparation != nil { changes.insert(.preparation) }
        if note != nil { changes.insert(.alternative) }

        // A declared typo: one edit, in the line, and the line then reads.
        var allowedWords: [String] = []
        if let typo = entry.tippfehler {
            let wrong = typo.falsch.trimmingCharacters(in: .whitespaces)
            let right = typo.richtig.trimmingCharacters(in: .whitespaces)
            if written.range(of: wrong, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                issues.append(.typoNotInLine(wrong))
            } else if TypoDistance.edits(fold(wrong), fold(right)) > 1 {
                issues.append(.typoTooFar(wrong: wrong, right: right))
            } else if fold(wrong) != fold(right) {
                typos.append(.init(wrong: wrong, right: right, declared: true))
                allowedWords += words(in: right).map(fold)
            }
        }

        // Amounts: the line's own, or a weight the line writes.
        let oldQuantity = parsed.quantity
        let writtenAmounts = amountsWritten(in: written)
        var carriers = 0
        for text in rewritten {
            let new = IngredientParser.parseLine(text, catalog: catalog)
            guard let quantity = new.quantity else { continue }
            carriers += 1
            // The size belongs to the amount: "1 großer Blumenkohl" is not
            // "1 Blumenkohl".
            let known = oldQuantity.map { sameAmount(quantity, $0, writtenIn: written) && new.size == parsed.size } ?? false
                || writtenAmounts.contains { sameAmount(quantity, $0, writtenIn: written) }
            guard !known else { continue }
            if oldQuantity != nil {
                issues.append(.amountChanged(from: measure(of: written), to: measure(of: text)))
            } else {
                issues.append(.amountInvented(measure(of: text)))
            }
        }
        if oldQuantity != nil, !rewritten.isEmpty, carriers == 0 {
            issues.append(.amountDropped(measure(of: written)))
        }
        if carriers > 1, oldQuantity != nil { issues.append(.amountRepeated) }

        // Words: only the line's own, dropped, reordered or declined; a unit
        // split off a compound; a declared typo. One edit that nobody
        // declared is a typo too, and shown as one.
        let oldWords = words(in: written).map(fold)
        for text in rewritten {
            let newWords = words(in: text)
            var remainders = Dictionary(oldWords.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
            var takenFrom: [String: String] = [:]
            for word in newWords {
                let folded = fold(word)
                if oldWords.contains(folded) || allowedWords.contains(folded) { continue }
                if oldWords.contains(where: { isInflection(folded, of: $0) }) { continue }
                // Before the unit words: "Zehen" is a unit, and also the
                // half of "Knoblauchzehen" that must be accounted for.
                if let compound = oldWords.first(where: { consumes(folded, from: remainders[$0] ?? $0) }) {
                    remainders[compound] = consumed(folded, from: remainders[compound] ?? compound)
                    takenFrom[compound] = word
                    continue
                }
                if isUnitWord(word.lowercased()) { continue }
                if folded.count >= 4, let near = oldWords.first(where: { TypoDistance.edits(folded, $0) == 1 }) {
                    let wrong = words(in: written).first { fold($0) == near } ?? near
                    typos.append(.init(wrong: wrong, right: word, declared: false))
                    continue
                }
                issues.append(.newWord(word))
            }
            // A compound taken apart must be taken apart whole:
            // "Knoblauchzehen" is "Zehen Knoblauch", but "Kürbiskernöl" is
            // not "Kürbiskern".
            for (compound, rest) in remainders where rest != compound && !rest.isEmpty && !inflectionEndings.contains(rest) {
                issues.append(.newWord(takenFrom[compound] ?? compound))
            }
        }
        // A correction only counts if the corrected line reads.
        let reads = rewritten.map { catalog.ingredient(for: IngredientParser.parseLine($0, catalog: catalog).name) }
        if !typos.isEmpty, reads.contains(where: { $0 == nil }) {
            issues.append(.typoDoesNotResolve(typos.map(\.right).joined(separator: ", ")))
        }
        if !typos.isEmpty { changes.insert(.typo) }

        // The claimed ingredient must be what the reader reads.
        for (index, new) in entry.neu.enumerated() where index < rewritten.count {
            guard let claim = new.zutat.flatMap(nonEmpty) else { continue }
            guard let claimed = catalog.ingredient(for: claim) else {
                issues.append(.unknownClaim(claim))
                continue
            }
            if reads[index]?.name != claimed.name {
                issues.append(.readsAs(line: rewritten[index], claimed: claimed.name, read: reads[index]?.name))
            }
        }

        // Preparation out of a measured line: Sous weighs it, from the
        // catalog's measure; without one, the unit stays.
        var weighing: Line.Weighing?
        if changes.contains(.preparation), rewritten.count == 1, !issues.contains(where: \.refuses) {
            let new = IngredientParser.parseLine(rewritten[0], catalog: catalog)
            if let quantity = new.quantity,
               let grams = weighedGrams(new, catalog: catalog, nutritionCatalog: nutritionCatalog),
               let length = IngredientParser.leadingAmountAndUnitLength(in: rewritten[0], catalog: catalog) {
                let rounded = RecipeOptimization.roundedGrams(grams)
                let amount = QuantityFormatter(locale: Locale(identifier: "de_DE")).string(for: Quantity(rounded, .gram), size: nil)
                let rest = rewritten[0].dropFirst(length).trimmingCharacters(in: .whitespaces)
                rewritten[0] = "\(amount) \(rest)"
                weighing = .init(from: quantity, grams: rounded)
            } else if let quantity = new.quantity,
                      quantity.unit.dimension == .volume || quantity.unit == .cup || quantity.unit == .handful {
                issues.append(.unweighed(measure(of: rewritten[0])))
            }
        }

        let isChanged = rewritten != [written] || note != nil
        if isChanged, changes.isEmpty { changes.insert(.noise) }
        // A line that stays as written has nothing to refuse or doubt —
        // only a claim Sous reads differently is worth keeping, as a hint.
        if !isChanged { issues.removeAll { $0.refuses } }

        return Line(
            number: number, written: written, group: group, rewritten: rewritten, changes: changes,
            preparation: preparation, note: note, typos: typos, weighing: weighing, issues: issues,
            resolves: !reads.isEmpty && reads.allSatisfy { $0 != nil }
        )
    }

    private static func classify(
        _ entry: Answer.Entry,
        line: RecipeOptimization.Line,
        parsed: RecipeIngredient,
        catalog: IngredientCatalog
    ) -> RecipeOptimization.Classification? {
        guard let raw = entry.einordnung,
              let kind = RecipeOptimization.Classification.Kind(rawValue: raw.art.lowercased())
                ?? (raw.art.lowercased() == "marke" ? .product : nil)
        else { return nil }
        // Names Sous already knows are Sous's business, whatever the model
        // says about them.
        guard catalog.ingredient(for: parsed.name) == nil else { return nil }
        let name = raw.name.flatMap(nonEmpty) ?? parsed.name
        guard line.written.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
        // An unknown target drops the target, not the classification.
        let target = kind == .new ? nil : raw.ziel.flatMap(nonEmpty).flatMap { catalog.ingredient(for: $0)?.name }
        let stillUnknown = line.isRefused || !line.resolves
        let countsAs = [.new, .typo].contains(kind) || !stillUnknown ? nil : target
        return .init(line: line.number, name: name, kind: kind, target: target, countsAs: countsAs)
    }

    private static func variantProposal(
        _ variant: Answer.Group.Variant,
        recipe: Recipe,
        parsed: [RecipeIngredient]
    ) -> RecipeOptimization.VariantProposal? {
        let title = variant.titel.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = variant.zutaten.map(singleLine).filter { !$0.isEmpty }
        guard !title.isEmpty, !lines.isEmpty else { return nil }
        let known = parsed.compactMap(\.quantity)
            + IngredientParser.writtenLines(in: recipe.ingredientsText).flatMap { amountsWritten(in: $0.text) }
        let foreign = lines.filter { line in
            guard let quantity = IngredientParser.parseLine(line).quantity else { return false }
            return !known.contains { sameAmount(quantity, $0, writtenIn: "") }
        }
        return .init(
            title: title,
            ingredientsText: lines.joined(separator: "\n"),
            instructionsText: variant.schritte.map(singleLine).filter { !$0.isEmpty }.joined(separator: "\n"),
            foreignAmounts: foreign
        )
    }

    // MARK: Helpers

    /// Grams from the catalog's own measure — a weight for the unit, or a
    /// density for a volume — for a unit that measures the prepared thing.
    /// Never the water fallback or a generic weight: that would be Sous
    /// guessing where the rule says the unit then stays.
    static func weighedGrams(
        _ ingredient: RecipeIngredient,
        catalog: IngredientCatalog,
        nutritionCatalog: NutritionCatalog
    ) -> Double? {
        guard let quantity = ingredient.quantity,
              quantity.unit.dimension == .volume || quantity.unit == .cup || quantity.unit == .handful
        else { return nil }
        let entry = nutritionCatalog.nutrition(forCanonicalName: catalog.nutritionName(for: ingredient))
        if let weight = entry?.unitWeightsGrams[quantity.unit.symbol] {
            return quantity.amount * weight
        }
        if quantity.unit.dimension == .volume, let milliliters = quantity.inBaseUnit, let density = entry?.densityGramsPerMl {
            return milliliters * density
        }
        return nil
    }

    /// Whether `new` is the amount `old` is, as far as a line can say it:
    /// the same number in the same unit, the same weight or volume in
    /// another unit ("0,5 kg" is "500 g"), or the same count in a unit the
    /// line wrote into its name ("3 Knoblauchzehen" is "3 Zehen").
    static func sameAmount(_ new: Quantity, _ old: Quantity, writtenIn line: String) -> Bool {
        if new.unit == old.unit { return abs(new.amount - old.amount) < 0.0001 }
        if new.unit.dimension == old.unit.dimension, [.mass, .volume].contains(new.unit.dimension),
           let a = new.inBaseUnit, let b = old.inBaseUnit, b > 0 {
            return abs(a - b) / b < 0.005
        }
        if old.unit == .piece, abs(new.amount - old.amount) < 0.0001 {
            let folded = fold(line)
            let lineWords = words(in: line).map(fold)
            return new.unit.spellings.contains { spelling in
                spelling.count >= 3 && folded.contains(fold(spelling))
                    // A misspelled unit, "3 Priesen": the correction is
                    // shown as a typo and never pre-ticked.
                    || spelling.count >= 4 && lineWords.contains { TypoDistance.edits($0, fold(spelling)) == 1 }
            }
        }
        return false
    }

    /// The amounts written anywhere in a line — "(400 g)", "Abtropfgewicht
    /// 500 g" — so that a weight for the whole line may become its amount.
    static func amountsWritten(in line: String) -> [Quantity] {
        line.matches(of: /(\d+(?:[.,]\d+)?)\s*([[:alpha:]]+\.?)/).compactMap { match in
            guard let quantity = StepReferencesPrompt.quantity(in: String(match.output.0))?.quantity,
                  quantity.unit != .piece
            else { return nil }
            return quantity
        }
    }

    /// A line's amount and unit as written — "1,5 TL", "1 Dose" — for the
    /// cook to recognize in a message.
    static func measure(of line: String) -> String {
        guard let length = IngredientParser.leadingAmountAndUnitLength(in: line) else { return line }
        return String(line.trimmingCharacters(in: .whitespaces).prefix(length)).trimmingCharacters(in: .whitespaces)
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    static let inflectionEndings: Set<String> = ["e", "n", "en", "s", "es", "er", "em", "r", "ns"]

    /// "getrocknete" of "getrocknet", "Paprikaschote" of "Paprikaschoten".
    static func isInflection(_ word: String, of other: String) -> Bool {
        let (short, long) = word.count <= other.count ? (word, other) : (other, word)
        guard short.count >= 3, long.hasPrefix(short) else { return false }
        return inflectionEndings.contains(String(long.dropFirst(short.count)))
    }

    /// Whether `word` — or `word` without an inflection ending — is a part
    /// of what is left of a compound.
    static func consumes(_ word: String, from rest: String) -> Bool {
        forms(of: word).contains { $0.count >= 3 && rest.contains($0) }
    }

    static func consumed(_ word: String, from rest: String) -> String {
        guard let form = forms(of: word).first(where: { $0.count >= 3 && rest.contains($0) }),
              let range = rest.range(of: form)
        else { return rest }
        return rest.replacingCharacters(in: range, with: "")
    }

    private static func forms(of word: String) -> [String] {
        [word] + inflectionEndings.sorted { $0.count > $1.count }.compactMap { ending in
            word.hasSuffix(ending) ? String(word.dropLast(ending.count)) : nil
        }
    }

    static func isUnitWord(_ word: String) -> Bool {
        if case .custom = IngredientUnit(symbol: word) { return false }
        return true
    }

    private static func singleLine(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // A heading marker would turn the line into a group.
        while line.hasPrefix("#") { line.removeFirst() }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// How many edits apart two words are: a letter added, dropped, changed, or
/// two neighbours swapped (optimal string alignment). A typo correction may
/// be one edit at most — "Chiabatta" → "Ciabatta" is, "Margarine" →
/// "Mandarine" is two.
enum TypoDistance {
    static func edits(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}
