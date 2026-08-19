import Foundation
import FoundationModels
import Testing
@testable import SousKit

/// Not a regression test — a measuring bench. It runs the regex scanner and
/// the Foundation Models extractor over the same recipes and prints them
/// side by side, per step: what each found, where they agree, what only one
/// of them reached, and which model claims the literal-text guard threw out.
///
/// Exists to answer, with data instead of a feeling, how well the on-device
/// model performs on its own — including against a recipe long enough to
/// press against the model's 4096-token context. Opt in explicitly, since a
/// live model call has no place in a routine test run:
///
///     SOUS_SPARRING=1 swift test --filter Sparring
@Suite(
    "Regex vs Foundation Models sparring",
    .enabled(if: ProcessInfo.processInfo.environment["SOUS_SPARRING"] == "1")
)
struct AmountExtractionSparringTests {
    @Test("Apple pie — the recipe the pooling bug was found with")
    func applePie() async throws {
        let recipe = Recipe(
            title: "Apfelkuchen",
            servings: 4,
            ingredientsText: """
            300 g Mehl
            150 g Butter
            150 g Butter
            1 Ei
            100 g Zucker
            1 kg Äpfel
            1 TL Zimt
            """,
            instructionsText: """
            300 g Mehl mit 150 g Butter und dem Ei zu einem glatten Teig verkneten und 30 Minuten kühl stellen.
            Die Äpfel schälen, vierteln und mit der Hälfte des Zuckers mischen.
            Die restliche Butter in einer Pfanne erhitzen und die Äpfel darin 5 Minuten andünsten.
            Den restlichen Zucker mit dem Zimt vermengen und über die Äpfel streuen.
            Den Teig ausrollen, belegen und bei 180 Grad 45 Minuten backen.
            """
        )
        try await spar(recipe)
    }

    @Test("Rouladen dinner — long, and full of wording regex cannot read")
    func longRecipe() async throws {
        let recipe = Recipe(
            title: "Rinderrouladen mit Rotkohl und Klößen",
            servings: 4,
            ingredientsText: """
            4 Rinderrouladen
            4 TL Senf
            8 Scheiben Speck
            4 Gewürzgurken
            3 Zwiebeln
            2 Karotten
            100 g Sellerie
            2 EL Tomatenmark
            400 ml Rotwein
            600 ml Rinderfond
            1 kg Rotkohl
            2 Äpfel
            3 EL Butterschmalz
            750 g Kartoffeln
            2 Eier
            100 g Mehl
            1 TL Salz
            """,
            instructionsText: """
            Die Rouladen ausbreiten, mit je 1 TL Senf bestreichen und mit 2 Scheiben Speck belegen.
            Ein Drittel der Zwiebeln in feine Ringe schneiden und mit den Gewürzgurken auf den Rouladen verteilen.
            Die Rouladen aufrollen, feststecken und in 2 EL Butterschmalz rundherum kräftig anbraten.
            Die restlichen Zwiebeln und Karotten grob würfeln und mit dem Sellerie zum Fleisch geben.
            2 EL Tomatenmark einrühren und kurz mitrösten.
            Mit der Hälfte des Rotweins ablöschen und vollständig einkochen lassen.
            Den übrigen Rotwein und 600 ml Rinderfond angießen und alles 90 Minuten schmoren lassen.
            Den Rotkohl fein hobeln und die Äpfel reiben.
            Das restliche Butterschmalz erhitzen und den Rotkohl darin andünsten.
            Ein Viertel der Kartoffeln fein reiben und beiseitestellen.
            Die übrigen Kartoffeln kochen, stampfen und abkühlen lassen.
            Die geriebenen und die gestampften Kartoffeln mit den Eiern, 100 g Mehl und dem Salz zu einem Teig verkneten.
            Aus dem Teig 8 Klöße formen und in siedendem Wasser 20 Minuten ziehen lassen.
            Die Rouladen herausnehmen und die Sauce auf ein Drittel einkochen lassen.
            Alles zusammen anrichten und servieren.
            """
        )
        try await spar(recipe)
    }

    // MARK: - The bench

    private func spar(_ recipe: Recipe) async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            Issue.record("Foundation Models is not available on this machine — nothing to spar against.")
            return
        }

        let steps = recipe.steps
        let started = Date()
        let rawClaims: [ExtractedQuantity]
        do {
            rawClaims = try await AmountAIExtractor.extractClaims(from: recipe)
        } catch {
            // A context overflow on the long recipe is itself a finding,
            // not a test failure.
            print("⚔️ [\(recipe.title)] model call FAILED: \(error)")
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        let surviving = AmountAIExtractor.mentions(from: rawClaims, steps: steps)

        var regexTotal = 0, aiTotal = 0, agreed = 0, aiOnly = 0

        print("⚔️ ================================================================")
        print("⚔️ \(recipe.title) — \(steps.count) Schritte, Modellantwort in \(String(format: "%.1f", elapsed)) s")
        for (index, step) in steps.enumerated() {
            let regexMentions = AmountMentionScanner.mentions(in: step.text)
            let aiMentions = surviving[step.id] ?? []
            guard !regexMentions.isEmpty || !aiMentions.isEmpty else { continue }

            print("⚔️ Schritt \(index + 1): \(step.text)")
            for mention in regexMentions {
                print("⚔️   Regex:   \(describe(mention, in: step.text))")
            }
            for mention in aiMentions {
                let alsoRegex = regexMentions.contains { $0.writtenRange.overlaps(mention.writtenRange) }
                print("⚔️   KI:      \(describe(mention, in: step.text))\(alsoRegex ? "  (= Regex)" : "  (nur KI)")")
                if alsoRegex { agreed += 1 } else { aiOnly += 1 }
            }
            regexTotal += regexMentions.count
            aiTotal += aiMentions.count
        }

        let rejected = rawClaims.count - surviving.values.map(\.count).reduce(0, +)
        if rejected > 0 {
            print("⚔️ Vom Wörtlich-Guard verworfen (\(rejected) von \(rawClaims.count) Claims):")
            for claim in rawClaims where !steps.contains(where: {
                $0.text.localizedCaseInsensitiveContains(claim.quantityText)
                    && $0.text.localizedCaseInsensitiveContains(claim.modifiedNoun)
            }) {
                print("⚔️   ✗ \(claim.kind.rawValue) \"\(claim.quantityText)\" → \"\(claim.modifiedNoun)\" (Schritt \(claim.stepNumber) laut Modell)")
            }
        }

        print("⚔️ Bilanz: Regex \(regexTotal) · KI \(aiTotal) davon einig \(agreed), nur KI \(aiOnly) · verworfen \(rejected)")
        print("⚔️ ================================================================")
    }

    private func describe(_ mention: AmountMention, in text: String) -> String {
        let kind = switch mention.kind {
        case .absolute(let quantity): "absolute \(QuantityFormatter().string(for: quantity))"
        case .bareCount(let value): "bareCount \(value)"
        case .fraction(let value): "fraction \(value)"
        case .remaining: "remaining"
        }
        return "[\(kind)] \"\(text[mention.writtenRange])\" → \"\(mention.namePhrase)\""
    }
}
