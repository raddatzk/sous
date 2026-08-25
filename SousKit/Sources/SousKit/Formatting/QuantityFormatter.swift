import Foundation

/// Renders amounts the way a recipe would write them: 1,5 kg instead of
/// 1500 g, ½ TL instead of 0,5 TL.
public struct QuantityFormatter: Sendable {
    /// Amounts below this many grams or milliliters stay in the small unit.
    private static let promotionThreshold: Double = 1000

    private static let fractions: [(value: Double, glyph: String)] = [
        (1.0 / 4.0, "¼"),
        (1.0 / 3.0, "⅓"),
        (1.0 / 2.0, "½"),
        (2.0 / 3.0, "⅔"),
        (3.0 / 4.0, "¾"),
    ]

    public var locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// The full line as it appears in the ingredient list.
    public func string(for quantity: Quantity) -> String {
        let normalized = normalize(quantity)
        let amount = amountString(normalized.amount, unit: normalized.unit)
        let symbol = normalized.unit.displaySymbol
        return symbol.isEmpty ? amount : "\(amount) \(symbol)"
    }

    /// Promotes to the larger unit once the amount warrants it, and demotes
    /// fractional large units back down.
    public func normalize(_ quantity: Quantity) -> Quantity {
        switch quantity.unit {
        case .gram where quantity.amount >= Self.promotionThreshold:
            return quantity.converted(to: .kilogram) ?? quantity
        case .milliliter where quantity.amount >= Self.promotionThreshold:
            return quantity.converted(to: .liter) ?? quantity
        case .kilogram where quantity.amount < 1:
            return quantity.converted(to: .gram) ?? quantity
        case .liter where quantity.amount < 1:
            return quantity.converted(to: .milliliter) ?? quantity
        default:
            return quantity
        }
    }

    private func amountString(_ amount: Double, unit: IngredientUnit) -> String {
        if usesFractions(unit), let fraction = fractionString(for: amount) {
            return fraction
        }
        return decimalString(amount, fractionDigits: fractionDigits(for: unit, amount: amount))
    }

    /// Spoons and counted items read better as fractions; weights do not —
    /// nobody writes "½ g".
    private func usesFractions(_ unit: IngredientUnit) -> Bool {
        switch unit {
        case .teaspoon, .tablespoon, .piece, .pinch, .bunch, .clove, .package, .portion, .leaf, .custom:
            true
        case .gram, .kilogram, .milliliter, .liter:
            false
        }
    }

    private func fractionString(for amount: Double) -> String? {
        guard amount > 0, amount < 100 else { return nil }
        let whole = floor(amount)
        let remainder = amount - whole
        guard remainder > 0.001 else { return nil }
        guard let match = Self.fractions.first(where: { abs(remainder - $0.value) < 0.02 }) else {
            return nil
        }
        return whole == 0 ? match.glyph : "\(decimalString(whole, fractionDigits: 0)) \(match.glyph)"
    }

    private func fractionDigits(for unit: IngredientUnit, amount: Double) -> Int {
        switch unit.dimension {
        case .mass, .volume:
            // Grams and millilitres are whole numbers once they are big
            // enough for the difference to be meaningless.
            amount >= 10 ? 0 : 1
        case .count, .imprecise:
            amount == amount.rounded() ? 0 : 1
        }
    }

    private func decimalString(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...fractionDigits))
                .locale(locale)
        )
    }
}

extension QuantityFormatter {
    /// A whole ingredient line: "300 g Zucchini, fein gehackt".
    ///
    /// Lives here rather than in the UI because the same line is needed for
    /// shopping lists, export, and the prompts handed to the model.
    public func string(for ingredient: RecipeIngredient) -> String {
        var line = ""
        if let quantity = ingredient.quantity {
            line = string(for: quantity)
        } else if let phrase = ingredient.unquantifiedPhrase, phrase.placement == .beforeName {
            // "etwas Salz" — the words sit where a number would.
            line = phrase.phrase
        }
        line = line.isEmpty ? ingredient.name : "\(line) \(ingredient.name)"
        if let phrase = ingredient.unquantifiedPhrase, phrase.placement == .afterName {
            line += " \(phrase.phrase)"
        }
        if let preparation = ingredient.preparation, !preparation.isEmpty {
            line += " (\(preparation))"
        }
        return line
    }
}
