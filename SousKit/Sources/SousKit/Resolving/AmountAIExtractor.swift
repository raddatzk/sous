import FoundationModels
import Foundation

/// What kind of quantity a phrase is — a judgment call the model makes once,
/// so nothing downstream has to recognize open-ended wording by matching
/// against a hand-written list of words. "Ein Drittel", "zwei Fünftel", "die
/// Hälfte" are all just `fraction` with a different `fractionValue`; no case
/// had to be added for any of them.
@Generable
enum ExtractedAmountKind: String, Sendable {
    /// An explicit amount with a number: "300 g", "2 Stück".
    case absolute
    /// A fixed share of the ingredient's total, independent of how the line
    /// itself scales: "die Hälfte", "ein Drittel", "das Doppelte".
    case fraction
    /// Whatever the other mentions of the same ingredient have not already
    /// claimed: "die restlichen", "die übrigen", "der Rest".
    case remaining
    /// Not a quantity of an ingredient at all — a duration, a temperature,
    /// or anything else that only looks like one.
    case notAQuantity
}

/// A quantity the model found in a step, and the noun it believes that
/// quantity modifies — nothing more. Which ingredient line, if any, that
/// noun refers to is for `StepAmountResolver` to work out, exactly as it
/// already does for the regex scanner's mentions.
@Generable
struct ExtractedQuantity: Equatable, Sendable {
    @Guide(description: "The quantity phrase exactly as written in the step, e.g. '100 g', 'restlichen', 'ein Drittel'")
    var quantityText: String
    @Guide(description: "The noun this quantity grammatically modifies, exactly as written. Empty if kind is notAQuantity.")
    var modifiedNoun: String
    var kind: ExtractedAmountKind
    @Guide(description: "Only set when kind is 'fraction': the fraction as a decimal, e.g. 0.5 for 'die Hälfte', 0.333 for 'ein Drittel', 0.25 for 'ein Viertel', 2.0 for 'das Doppelte'")
    var fractionValue: Double?
    var stepNumber: Int
}

@Generable
struct AmountExtraction: Equatable, Sendable {
    var mentions: [ExtractedQuantity]
}

public enum AmountAIExtractionError: Error, LocalizedError {
    case modelUnavailable

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable: "Auf diesem Gerät nicht verfügbar."
        }
    }
}

/// A second, optional source of ``AmountMention``s, alongside
/// `AmountMentionScanner`'s regex — for the shapes regex cannot read at
/// all: a relative amount that names more than one ingredient at once
/// ("restlichen Zwiebeln und Karotten"), or a fraction word regex was
/// never taught to recognize, since teaching it every such word by hand is
/// the same brittleness this exists to avoid.
///
/// The model is asked for sentence structure and the arithmetic meaning of
/// a fraction word — never for which ingredient line a mention belongs to.
/// That match still happens entirely inside `StepAmountResolver`, under the
/// same dimension, group and capacity constraints every mention answers
/// to. And nothing the model claims is trusted outright: a mention only
/// survives if its exact text occurs somewhere in the recipe's own steps,
/// found by literal search rather than by the step number the model
/// happened to name.
public enum AmountAIExtractor {
    /// Calls the on-device model once for the whole recipe's steps.
    public static func extract(from recipe: Recipe) async throws -> [UUID: [AmountMention]] {
        guard case .available = SystemLanguageModel.default.availability else {
            throw AmountAIExtractionError.modelUnavailable
        }
        let steps = recipe.steps
        guard !steps.isEmpty else { return [:] }
        let raw = try await requestExtraction(steps: steps)
        return mentions(from: raw.mentions, steps: steps)
    }

    private static func requestExtraction(steps: [RecipeStep]) async throws -> AmountExtraction {
        let numberedSteps = steps.enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n")

        let instructions = """
        Du analysierst die Satzstruktur von Kochrezept-Schritten: welches \
        Nomen eine Mengenangabe grammatisch modifiziert, und welche Art von \
        Menge es ist. Bei einer relativen Menge (Bruchteil) gibst du den \
        Bruch als Dezimalzahl an, unabhängig davon, mit welchem Wort er im \
        Text ausgedrückt ist. Du rätst nicht — wenn eine Menge zu keinem \
        sinnvollen Nomen gehört (z.B. eine Zeitangabe), ist sie \
        notAQuantity, statt ein beliebiges Nomen aus dem Text zu nehmen. Du \
        gibst ausschließlich Mengenangaben zurück, die wörtlich im vom \
        Nutzer übergebenen Rezepttext stehen — niemals aus dem folgenden \
        Beispiel, das nur das Antwortformat zeigt und mit keinem echten \
        Rezept etwas zu tun hat:

        \(fewShotExample)
        """

        let prompt = """
        Zubereitung:
        \(numberedSteps)

        Finde JEDE Mengenangabe in diesen Schritten. Eine Mengenangabe ist \
        nicht nur eine Zahl mit Einheit ("400 g", "2 EL") — auch WÖRTER, die \
        eine Menge ausdrücken, zählen: Bruchteile ("die Hälfte", "ein \
        Drittel", "ein Viertel") und Restmengen ("restliche", "übrige", \
        "der Rest"). Suche aktiv nach diesen Wörtern, nicht nur nach \
        Ziffern. Eine Mengenangabe kann sich auch auf mehrere Zutaten \
        gleichzeitig beziehen ("restlichen Zwiebeln und Karotten") — gib \
        dann für jede betroffene Zutat einen eigenen Eintrag zurück.

        Gib für jede Mengenangabe an, zu welchem Nomen sie grammatisch \
        gehört — also welches Ding direkt gezählt oder gemessen wird. Achte \
        genau auf Satzstellung: eine Menge gehört zu dem Wort, das direkt \
        danach oder in der gleichen Aufzählung steht, nicht zu einer \
        anderen Zutat, die im selben Satz nur zufällig auch vorkommt.

        Zeit- und Temperaturangaben (Minuten, Sekunden, Stunden, Grad) sind \
        notAQuantity und gehören zu KEINEM Nomen.

        Jede Mengenangabe muss wörtlich in einem der oben nummerierten \
        Schritte stehen. Erfinde keine Mengenangaben.
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: AmountExtraction.self,
            options: GenerationOptions(temperature: 0)
        )
        return response.content
    }

    /// Bewusst mit Zutaten, die in keinem echten Rezept vorkommen dürften —
    /// sonst besteht die Gefahr, dass das Beispiel selbst als Teil der
    /// Eingabe missverstanden und in die Ausgabe übernommen wird.
    private static let fewShotExample = """
    Beispiel (rein zur Veranschaulichung des Formats, hat nichts mit dem Rezept unten zu tun):
    1. 2 EL Butter in einer Pfanne erhitzen und die Paprika darin 5 Minuten andünsten.
    2. Ein Drittel der Paprika roh in Scheiben schneiden.
    3. Die Hälfte des Selleries fein hacken, den Rest des Selleries aufheben.
    ->
    - "2 EL" modifiziert "Butter", kind: absolute (Schritt 1)
    - "5 Minuten" modifiziert nichts, kind: notAQuantity (Schritt 1)
    - "Ein Drittel" modifiziert "Paprika", kind: fraction, fractionValue: 0.333 (Schritt 2)
    - "Die Hälfte" modifiziert "Sellerie", kind: fraction, fractionValue: 0.5 (Schritt 3)
    - "den Rest" modifiziert "Sellerie", kind: remaining (Schritt 3)
    """

    // MARK: - The guard

    /// Turns the model's raw claims into the same `AmountMention` shape the
    /// regex scanner produces — a pure function, and the part that is
    /// actually unit tested, since it needs no live model call.
    static func mentions(from raw: [ExtractedQuantity], steps: [RecipeStep]) -> [UUID: [AmountMention]] {
        var result: [UUID: [AmountMention]] = [:]
        for extracted in raw {
            guard let (stepID, mention) = mention(for: extracted, steps: steps) else { continue }
            result[stepID, default: []].append(mention)
        }
        return result
    }

    private static func mention(for extracted: ExtractedQuantity, steps: [RecipeStep]) -> (UUID, AmountMention)? {
        guard let kind = amountMentionKind(for: extracted) else { return nil }

        // Never trust the claimed step number on its own — only a literal
        // match counts, and a mention naming text that occurs nowhere is a
        // hallucination, not an amount. The noun has to occur too, not just
        // the quantity: a second, independent guard against the model
        // pairing a real quantity with an invented noun. Prefer the claimed
        // step when it happens to be one of the places both occur.
        let candidates = steps.enumerated().filter {
            $0.element.text.localizedCaseInsensitiveContains(extracted.quantityText)
                && $0.element.text.localizedCaseInsensitiveContains(extracted.modifiedNoun)
        }
        guard !candidates.isEmpty else { return nil }
        let step = (candidates.first { $0.offset + 1 == extracted.stepNumber } ?? candidates[0]).element
        guard let range = step.text.range(of: extracted.quantityText, options: [.caseInsensitive]),
              // `namePhrase` has to be a slice of `step.text` itself, not a
              // standalone string — `StepAmountResolver` later reads
              // `String.Index` positions out of it that only mean anything
              // relative to that same text's storage.
              let nounRange = step.text.range(of: extracted.modifiedNoun, options: [.caseInsensitive])
        else { return nil }

        let mention = AmountMention(
            kind: kind,
            writtenRange: range,
            replacesWrittenRange: isFixedAmount(kind),
            namePhrase: step.text[nounRange]
        )
        return (step.id, mention)
    }

    /// Reads the model's own judgment of what kind of quantity this is —
    /// only the `absolute` case still needs this module to parse the
    /// number and unit out of `quantityText` itself, since that is a
    /// closed, mechanical grammar and not a matter of language
    /// understanding the way a fraction word is.
    private static func amountMentionKind(for extracted: ExtractedQuantity) -> AmountMention.Kind? {
        guard !extracted.modifiedNoun.isEmpty else { return nil }
        switch extracted.kind {
        case .notAQuantity:
            return nil
        case .remaining:
            return .remaining
        case .fraction:
            guard let value = extracted.fractionValue, value > 0 else { return nil }
            return .fraction(value)
        case .absolute:
            return absoluteKind(from: extracted.quantityText)
        }
    }

    private static func absoluteKind(from quantityText: String) -> AmountMention.Kind? {
        let pattern = /(\d+(?:[.,]\d+)?|[½⅓⅔¼¾])\s*([\p{L}]+\.?)?/
        guard let match = quantityText.firstMatch(of: pattern),
              let value = AmountMentionScanner.amountValue(from: String(match.1))
        else { return nil }

        guard let unitWord = match.2 else { return .bareCount(value) }
        let symbol = String(unitWord).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard case .custom = IngredientUnit(symbol: symbol) else {
            return .absolute(Quantity(value, IngredientUnit(symbol: symbol)))
        }
        return .bareCount(value)
    }

    private static func isFixedAmount(_ kind: AmountMention.Kind) -> Bool {
        switch kind {
        case .absolute, .bareCount: true
        case .fraction, .remaining: false
        }
    }
}
