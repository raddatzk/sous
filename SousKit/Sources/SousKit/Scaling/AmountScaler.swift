import Foundation

/// Scales amounts written into free text, so an instruction reading
/// "300 g Tomaten würfeln" follows the serving count the cook picked.
///
/// Only amounts carrying a known measurement unit are touched. That rules out
/// the two things that must never scale: temperatures ("bei 180 Grad") and
/// times ("20 Minuten"). A bare number is left alone too — "in 2 Hälften
/// schneiden" stays two halves however many people are eating.
public enum AmountScaler {
    public static func scaled(
        _ text: String,
        by factor: Double,
        formatter: QuantityFormatter = QuantityFormatter()
    ) -> String {
        guard factor > 0, factor != 1 else { return text }

        let pattern = /(\d+(?:[.,]\d+)?|[½⅓⅔¼¾])\s*([\p{L}]+\.?)/
        var result = text

        // Replaced back to front so earlier ranges stay valid.
        for match in text.matches(of: pattern).reversed() {
            guard let amount = amount(from: String(match.1)) else { continue }
            let symbol = String(match.2).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let unit = IngredientUnit(symbol: symbol)

            // An unrecognized word is not a unit — it is the thing being counted.
            guard case .custom = unit else {
                let scaled = Quantity(amount * factor, unit)
                result.replaceSubrange(match.range, with: formatter.string(for: scaled))
                continue
            }
        }
        return result
    }

    private static func amount(from token: String) -> Double? {
        switch token {
        case "½": 0.5
        case "⅓": 1.0 / 3.0
        case "⅔": 2.0 / 3.0
        case "¼": 0.25
        case "¾": 0.75
        default: Double(token.replacingOccurrences(of: ",", with: "."))
        }
    }
}

extension Recipe {
    /// A step's text with its amounts scaled to `targetServings`.
    public func scaledStepText(_ step: RecipeStep, toServings targetServings: Int) -> String {
        guard servings > 0, targetServings > 0, targetServings != servings else { return step.text }
        return AmountScaler.scaled(step.text, by: Double(targetServings) / Double(servings))
    }

    /// The ingredients a step appears to use.
    ///
    /// Matched by name appearing in the step's text, which is a guess rather
    /// than a fact — the recipe never says which ingredient belongs to which
    /// step. It is right often enough to be useful and wrong in a way that is
    /// obvious to the cook, who can see the full list one swipe away.
    public func ingredients(mentionedIn step: RecipeStep, scaledToServings targetServings: Int? = nil) -> [RecipeIngredient] {
        let all = scaledIngredients(toServings: targetServings ?? servings)
        return all.filter { ingredient in
            let name = ingredient.name.trimmingCharacters(in: .whitespaces)
            guard name.count >= 3 else { return false }
            return step.text.localizedCaseInsensitiveContains(name)
        }
    }
}
