import Foundation

/// Renders nutrient figures so that a small one still says something.
///
/// The gram is a convention, not a requirement. A potato carries 7.5 mg of
/// salt per 100 g; printed in grams that rounds to "0 g", which reads as a
/// measured absence rather than as a trace too small for the unit. So the
/// unit follows the number down — grams, then milligrams, then micrograms —
/// and below that the decimal places grow instead.
///
/// Only ever downwards, unlike ``QuantityFormatter``, which promotes grams to
/// kilograms. Nutrition labels have conventional units: salt is quoted in
/// grams and vitamin A in micrograms whatever the amount, and a figure that
/// changed unit as it grew would stop being comparable between ingredients.
public struct NutrientFormatter: Sendable {
    /// Below this, the figure moves to the next unit down.
    private static let downgradeThreshold = 0.1
    /// Enough decimals to keep a trace visible, and no more.
    private static let maximumFractionDigits = 3

    /// The units a mass can be shown in, largest first.
    public enum MassUnit: Sendable, CaseIterable {
        case grams
        case milligrams
        case micrograms

        var symbol: String {
            switch self {
            case .grams: "g"
            case .milligrams: "mg"
            case .micrograms: "µg"
            }
        }

        /// How many of this unit make one gram.
        var perGram: Double {
            switch self {
            case .grams: 1
            case .milligrams: 1_000
            case .micrograms: 1_000_000
            }
        }
    }

    public var locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Energy, which nobody wants to a decimal place.
    public func string(kilocalories: Double) -> String {
        "\(Int(kilocalories.rounded())) kcal"
    }

    /// `value`, given in `unit`, printed in `unit` or in whatever smaller one
    /// keeps a digit on screen.
    ///
    /// `unit` is the nutrient's conventional unit, not a starting guess: pass
    /// grams for salt and fat, milligrams for sodium and most minerals,
    /// micrograms for vitamins A and D.
    public func string(_ value: Double, in unit: MassUnit) -> String {
        // Zero stays in the unit it was asked about. It is the one figure
        // that means the same thing at every scale.
        guard value > 0 else { return "\(decimalString(0)) \(unit.symbol)" }

        let grams = value / unit.perGram
        let smaller = MassUnit.allCases.drop { $0 != unit }
        let chosen = smaller.first { grams * $0.perGram >= Self.downgradeThreshold }
            ?? smaller.last
            ?? unit
        return "\(decimalString(grams * chosen.perGram)) \(chosen.symbol)"
    }

    private func decimalString(_ value: Double) -> String {
        value.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...fractionDigits(for: value)))
                .locale(locale)
        )
    }

    /// One decimal place normally; more only where one would round the figure
    /// away — which happens when even the smallest unit cannot lift it.
    private func fractionDigits(for value: Double) -> Int {
        guard value > 0, value < Self.downgradeThreshold else { return 1 }
        return min(Self.maximumFractionDigits, Int(-log10(value)) + 1)
    }
}
