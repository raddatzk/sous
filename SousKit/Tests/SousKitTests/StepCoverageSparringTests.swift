import Foundation
import Testing
@testable import SousKit

/// Not a regression test — a measuring bench, the coverage sibling of
/// `AmountExtractionSparringTests`. It resolves every step of a recipe and
/// prints the pots no step ever reaches: not bound to a written amount, not
/// offered as a suggestion, not matched as a bare-name chip. Those unreached
/// pots are exactly the near-misses the matcher cannot see today —
/// "festkochende Kartoffeln" in the list against plain "Kartoffeln" in the
/// step, "Bockshornkleesamen" against "Bockshornklee".
///
/// Each miss is classified by what would have bridged it, so the output
/// answers which fix pays for itself before any fix is built:
///
/// - `GRUPPE` — the catalog already bundles both names under one parent;
///   matching at `groupIngredient` level would close it.
/// - `TEILWORT` — a single word of the line's multi-word name (or a naive
///   plural stem of it) appears in a step; word-level matching would close it.
/// - `STAMM` — a step word and the line name share a compound stem, one a
///   prefix of the other; a stem heuristic would close it.
/// - `ohne Spur` — no step names anything like it. Implicit uses ("würzen",
///   garnish) land here; these are not matcher bugs.
///
/// The reverse list prints capitalized mid-sentence words that relate to no
/// ingredient line at all — candidates for "the step uses something the list
/// never had". Expect noise; the stoplist grows with the findings.
///
/// Opt in explicitly, like the other bench:
///
///     SOUS_SPARRING=1 swift test --filter StepCoverage
///
/// Point `SOUS_SPARRING_LIBRARY` at a `.melarecipes` export to run the same
/// report over a real library instead of the built-in challenge recipe.
@Suite(
    "Step coverage sparring",
    .enabled(if: ProcessInfo.processInfo.environment["SOUS_SPARRING"] == "1")
)
struct StepCoverageSparringTests {
    @Test("Kartoffelcurry — the two known near-misses")
    func kartoffelcurry() {
        // A reconstruction of the shape of "Ala Hodi (Kartoffelcurry)", not
        // its text: the list writes "festkochende Kartoffeln" and
        // "Bockshornkleesamen", the steps say "Kartoffeln" and
        // "Bockshornklee". Both must show up below as near-misses.
        let recipe = Recipe(
            title: "Ala Hodi (Kartoffelcurry, Nachbau)",
            servings: 4,
            ingredientsText: """
            800 g festkochende Kartoffeln
            2 Zwiebeln
            3 Knoblauchzehen
            1 TL Bockshornkleesamen
            1 TL Kurkuma
            2 TL Currypulver
            1 Dose Kokosmilch
            2 EL Öl
            1 TL Salz
            """,
            instructionsText: """
            Die Kartoffeln schälen und in mundgerechte Stücke schneiden.
            Die Zwiebeln würfeln und den Knoblauch fein hacken.
            Das Öl erhitzen und den Bockshornklee darin anrösten, bis er duftet.
            Zwiebeln und Knoblauch zugeben und glasig dünsten.
            Kurkuma und Currypulver einrühren, die Kartoffeln zugeben und mit der Kokosmilch ablöschen.
            Zugedeckt 20 Minuten köcheln lassen und mit Salz abschmecken.
            """
        )
        var tally = Tally()
        report(on: recipe, into: &tally)
        tally.printSummary(recipeCount: 1)
    }

    @Test("Whole Mela library, when one is pointed at")
    func library() throws {
        guard let path = ProcessInfo.processInfo.environment["SOUS_SPARRING_LIBRARY"],
              !path.isEmpty
        else {
            print("🧾 SOUS_SPARRING_LIBRARY ist nicht gesetzt — kein Export, über den der Report laufen könnte.")
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let batch = try MelaImport.read(Data(contentsOf: url), named: url.lastPathComponent)
        for problem in batch.problems {
            print("🧾 Übersprungen: \(problem.name) — \(problem.reason)")
        }
        var tally = Tally()
        for imported in batch.recipes {
            report(on: imported.recipe, into: &tally)
        }
        tally.printSummary(recipeCount: batch.recipes.count)
    }

    // MARK: - The bench

    private struct Tally {
        var pots = 0
        var unreachedByKind: [String: Int] = [:]
        var suspects = 0

        mutating func count(_ kind: String) {
            unreachedByKind[kind, default: 0] += 1
        }

        func printSummary(recipeCount: Int) {
            let unreached = unreachedByKind.values.reduce(0, +)
            let byKind = unreachedByKind
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: " · ")
            print("🧾 ================================================================")
            print("🧾 Gesamt: \(recipeCount) Rezepte · \(pots) Pots · \(unreached) nie erreicht"
                + (byKind.isEmpty ? "" : " (\(byKind))")
                + " · \(suspects) Verdachtsworte")
            print("🧾 ================================================================")
        }
    }

    /// One ingredient supply the way the resolver pools it: lines sharing a
    /// group and a canonical name. Rebuilt here because the resolver keeps
    /// its `Pot` and `potIndexByLineID` file-private — the bench only needs
    /// the key, not the claiming machinery.
    private struct PotSurvey {
        let key: String
        let displayName: String
        let lineCount: Int
        let amount: String?
    }

    private func report(on recipe: Recipe, into tally: inout Tally) {
        let catalog = IngredientCatalog.bundled
        let steps = recipe.steps
        let lines = recipe.ingredients.filter { $0.linkedRecipeID == nil && !$0.name.isEmpty }
        guard !steps.isEmpty, !lines.isEmpty else { return }

        let resolution = StepAmountResolver.resolve(recipe, toServings: recipe.servings, catalog: catalog)

        var pots: [PotSurvey] = []
        var potIndexByKey: [String: Int] = [:]
        for line in lines {
            let key = potKey(group: line.group, name: line.name, catalog: catalog)
            if let index = potIndexByKey[key] {
                pots[index] = PotSurvey(
                    key: key,
                    displayName: pots[index].displayName,
                    lineCount: pots[index].lineCount + 1,
                    amount: pots[index].amount
                )
            } else {
                potIndexByKey[key] = pots.count
                pots.append(PotSurvey(
                    key: key,
                    displayName: line.name,
                    lineCount: 1,
                    amount: line.quantity.map { QuantityFormatter().string(for: $0) }
                ))
            }
        }
        tally.pots += pots.count

        // Every way a step can reach a pot today, collected by pot key.
        var reached = Set<String>()
        for step in steps {
            for line in lines where resolution.mentionsAmount(of: line, in: step) {
                reached.insert(potKey(group: line.group, name: line.name, catalog: catalog))
            }
            for suggestion in resolution.suggestions(for: step) {
                reached.insert(potKey(group: nil, name: suggestion.ingredientName, catalog: catalog))
            }
            for chip in recipe.ingredients(mentionedIn: step, resolution: resolution) {
                reached.insert(potKey(group: chip.group, name: chip.name, catalog: catalog))
            }
        }
        // A suggestion carries no group, so its key was built without one.
        // Let it stand for any pot of the same canonical name rather than
        // reporting a grouped line as unreached that a suggestion did find.
        let reachedNames = Set(reached.map { $0.components(separatedBy: "|").last! })

        let unreached = pots.filter { pot in
            !reached.contains(pot.key) && !reachedNames.contains(pot.key.components(separatedBy: "|").last!)
        }
        let suspects = suspectWords(in: steps, against: lines, catalog: catalog)
        guard !unreached.isEmpty || !suspects.isEmpty else { return }

        print("🧾 ================================================================")
        print("🧾 \(recipe.title) — \(lines.count) Zutaten in \(pots.count) Pots, \(steps.count) Schritte")
        for pot in unreached {
            let amount = pot.amount.map { " (\($0))" } ?? ""
            let count = pot.lineCount > 1 ? " [\(pot.lineCount) Zeilen]" : ""
            print("🧾 Nie erreicht: \(pot.displayName)\(amount)\(count)")
            if let miss = nearMiss(for: pot.displayName, in: steps, catalog: catalog) {
                print("🧾   ↳ \(miss.kind): Schritt \(miss.stepNumber) sagt „\(miss.word)\" — \(miss.reason)")
                tally.count(miss.kind)
            } else {
                print("🧾   ↳ ohne Spur — kein Schritt nennt etwas Ähnliches")
                tally.count("ohne Spur")
            }
        }
        for suspect in suspects {
            print("🧾 Verdacht: „\(suspect.word)\" (Schritt \(suspect.stepNumber)) passt zu keiner Zutatenzeile")
        }
        tally.suspects += suspects.count
    }

    private func potKey(group: String?, name: String, catalog: IngredientCatalog) -> String {
        let canonical = IngredientCatalog.normalize(catalog.canonicalName(for: name))
        guard let group, !group.isEmpty else { return canonical }
        return IngredientCatalog.normalize(group) + "|" + canonical
    }

    // MARK: - Near-miss classification

    private struct NearMiss {
        let kind: String
        let stepNumber: Int
        let word: String
        let reason: String
    }

    /// The best bridge from an unreached line name to any word any step
    /// wrote, strongest class first: catalog knowledge beats word geometry.
    private func nearMiss(for name: String, in steps: [RecipeStep], catalog: IngredientCatalog) -> NearMiss? {
        let nameWords = name.split(separator: " ").map(String.init)
        let lineGroup = catalog.groupIngredient(for: name)
        var teilwort: NearMiss?
        var stamm: NearMiss?

        for (index, step) in steps.enumerated() {
            for word in Self.words(in: step.text) where word.text.count >= 4 {
                let stepWord = word.text
                if let lineGroup,
                   let stepGroup = catalog.groupIngredient(for: stepWord),
                   stepGroup.key == lineGroup.key {
                    return NearMiss(
                        kind: "GRUPPE", stepNumber: index + 1, word: stepWord,
                        reason: "der Katalog bündelt beide unter „\(lineGroup.name)\""
                    )
                }
                if teilwort == nil,
                   nameWords.contains(where: { Self.stemEqual($0, stepWord) }),
                   !Self.stemEqual(name, stepWord) {
                    teilwort = NearMiss(
                        kind: "TEILWORT", stepNumber: index + 1, word: stepWord,
                        reason: "trifft ein Wort von „\(name)\""
                    )
                }
                if stamm == nil,
                   nameWords.contains(where: { Self.sharesCompoundStem($0, stepWord) }) {
                    stamm = NearMiss(
                        kind: "STAMM", stepNumber: index + 1, word: stepWord,
                        reason: "gemeinsamer Wortstamm mit „\(name)\""
                    )
                }
            }
        }
        return teilwort ?? stamm
    }

    /// Case-insensitive equality up to a naive German plural ending — the
    /// same endings `IngredientCatalog.ingredient(for:)` strips, applied
    /// symmetrically to words the catalog has never heard of.
    private static func stemEqual(_ first: String, _ second: String) -> Bool {
        let a = stem(of: first), b = stem(of: second)
        return !a.isEmpty && a == b
    }

    private static func stem(of word: String) -> String {
        let lowered = word.lowercased()
        for suffix in ["en", "n", "e", "s"] where lowered.hasSuffix(suffix) {
            let stem = String(lowered.dropLast(suffix.count))
            if stem.count >= 4 { return stem }
        }
        return lowered
    }

    /// Whether one word is a compound built on the other — "Bockshornklee"
    /// against "Bockshornkleesamen". The shorter side must be substantial
    /// and the leftover must be a real morpheme, not a plural ending.
    private static func sharesCompoundStem(_ first: String, _ second: String) -> Bool {
        let a = first.lowercased(), b = second.lowercased()
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 6 && long.count - short.count >= 3 && long.hasPrefix(short)
    }

    // MARK: - Suspect words

    private struct Suspect {
        let word: String
        let stepNumber: Int
    }

    /// Kitchen nouns a step names without meaning an ingredient. Grown from
    /// findings, never meant to be complete — a suspect too many is noise in
    /// a bench, a rule too eager would be noise in the app.
    private static let kitchenNouns: Set<String> = [
        "minute", "minuten", "stunde", "stunden", "sekunde", "sekunden",
        "grad", "umluft", "hitze", "stufe", "herd", "ofen", "backofen",
        "pfanne", "topf", "schüssel", "deckel", "blech", "backblech", "form",
        "auflaufform", "brett", "messer", "sieb", "mixer", "stabmixer",
        "wasser", "kochendes", "seite", "seiten", "ende", "mitte", "boden",
        "rand", "größe", "stücke", "stück", "würfel", "scheiben", "streifen",
        "ringe", "hälfte", "drittel", "viertel", "rest", "teig", "masse",
        "mischung", "sauce", "soße", "sud", "flüssigkeit", "konsistenz",
        "geschmack", "zimmertemperatur", "temperatur", "portionen", "personen",
    ]

    /// Capitalized mid-sentence words — German's cheap noun detector — that
    /// relate to no ingredient line at all: not canonically, not as a word
    /// of one, not by stem, not as a substring either way.
    private func suspectWords(
        in steps: [RecipeStep], against lines: [RecipeIngredient], catalog: IngredientCatalog
    ) -> [Suspect] {
        let lineNames = lines.map { $0.name.lowercased() }
        let lineWords = lines.flatMap { $0.name.split(separator: " ").map(String.init) }
        let lineKeys = Set(lines.map { IngredientCatalog.normalize(catalog.canonicalName(for: $0.name)) })

        var seen = Set<String>()
        var suspects: [Suspect] = []
        for (index, step) in steps.enumerated() {
            for word in Self.words(in: step.text) {
                let text = word.text
                guard text.count >= 5,
                      text.first!.isUppercase,
                      !word.startsSentence,
                      !Self.kitchenNouns.contains(text.lowercased()),
                      seen.insert(text.lowercased()).inserted
                else { continue }

                let canonical = IngredientCatalog.normalize(catalog.canonicalName(for: text))
                let related = lineKeys.contains(canonical)
                    || lineWords.contains { Self.stemEqual($0, text) || Self.sharesCompoundStem($0, text) }
                    || lineNames.contains { $0.contains(text.lowercased()) || text.lowercased().contains($0) }
                if !related {
                    suspects.append(Suspect(word: text, stepNumber: index + 1))
                }
            }
        }
        return suspects
    }

    // MARK: - Tokenizing

    private struct Word {
        let text: String
        let startsSentence: Bool
    }

    private static func words(in text: String) -> [Word] {
        text.matches(of: /[\p{L}][\p{L}\-]*/).map { match in
            var cursor = match.range.lowerBound
            var startsSentence = true
            while cursor > text.startIndex {
                cursor = text.index(before: cursor)
                let character = text[cursor]
                if character == " " { continue }
                startsSentence = ".:;!?\n„»(".contains(character)
                break
            }
            return Word(text: String(text[match.range]), startsSentence: startsSentence)
        }
    }
}
