import Foundation

/// The NRF9.3 score read as one of five bands, the way a raw number never
/// is at a glance. Deliberately not called "Nutri-Score" and not shaped like
/// one in the UI — it is a different formula (nutrient density per calorie,
/// not a product-label algorithm) and would mislead if it looked identical.
///
/// Bands are a first-pass calibration against whole dishes, not single
/// foods: NRF9.3 rewards low calorie-density heavily, so a light vegetable
/// soup scores far above a meat-and-cream version of the same dish even
/// with similar ingredients. Adjust the thresholds here if real recipes end
/// up clustering too heavily in one band.
public enum NRFLevel: String, CaseIterable, Sendable {
    case a, b, c, d, e

    public init(score: Double) {
        switch score {
        case 40...: self = .a
        case 20..<40: self = .b
        case 0..<20: self = .c
        case -20..<0: self = .d
        default: self = .e
        }
    }

    public var letter: String { rawValue.uppercased() }

    /// A short description for accessibility and anywhere a word reads
    /// better than a letter.
    public var label: String {
        switch self {
        case .a: "Sehr nährstoffreich"
        case .b: "Nährstoffreich"
        case .c: "Mittel"
        case .d: "Nährstoffarm"
        case .e: "Sehr nährstoffarm"
        }
    }
}

extension RecipeNutrition {
    public var nrfLevel: NRFLevel { NRFLevel(score: nrf93Score) }
}
