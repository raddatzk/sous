import Foundation

/// The physical dimension a unit belongs to. Conversion is only defined
/// within a dimension; `imprecise` units convert to nothing at all.
public enum UnitDimension: String, Codable, Hashable, Sendable {
    case mass
    case volume
    case count
    case imprecise
}

/// A unit of measure as it appears in a recipe.
///
/// Serialized as its symbol, so unknown symbols survive a round trip as
/// `.custom` rather than failing to decode.
public enum IngredientUnit: Hashable, Sendable {
    case gram
    case kilogram
    case milliliter
    case liter
    case teaspoon
    case tablespoon
    case piece
    case pinch
    case bunch
    case clove
    case package
    case custom(String)

    public static let allKnown: [IngredientUnit] = [
        .gram, .kilogram, .milliliter, .liter, .teaspoon, .tablespoon,
        .piece, .pinch, .bunch, .clove, .package,
    ]

    public var symbol: String {
        switch self {
        case .gram: "g"
        case .kilogram: "kg"
        case .milliliter: "ml"
        case .liter: "l"
        case .teaspoon: "TL"
        case .tablespoon: "EL"
        case .piece: "Stk."
        case .pinch: "Prise"
        case .bunch: "Bund"
        case .clove: "Zehe"
        case .package: "Pck."
        case .custom(let symbol): symbol
        }
    }

    /// The symbol as it should appear next to an amount. Counted items read
    /// better without one — "2 Eier", not "2 Stk. Eier".
    public var displaySymbol: String {
        self == .piece ? "" : symbol
    }

    public init(symbol: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        if let known = Self.allKnown.first(where: {
            $0.symbol.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            self = known
        } else {
            self = .custom(trimmed)
        }
    }

    public var dimension: UnitDimension {
        switch self {
        case .gram, .kilogram: .mass
        case .milliliter, .liter, .teaspoon, .tablespoon: .volume
        case .piece: .count
        case .pinch, .bunch, .clove, .package, .custom: .imprecise
        }
    }

    /// How many base units (gram for mass, milliliter for volume) one of this
    /// unit is worth. `nil` for units that cannot be converted.
    ///
    /// Teaspoon and tablespoon use the metric kitchen convention (5 ml / 15 ml).
    public var baseUnitFactor: Double? {
        switch self {
        case .gram: 1
        case .kilogram: 1000
        case .milliliter: 1
        case .liter: 1000
        case .teaspoon: 5
        case .tablespoon: 15
        case .piece: 1
        case .pinch, .bunch, .clove, .package, .custom: nil
        }
    }

    public var isConvertible: Bool { baseUnitFactor != nil }
}

extension IngredientUnit: Codable {
    public init(from decoder: any Decoder) throws {
        let symbol = try decoder.singleValueContainer().decode(String.self)
        self.init(symbol: symbol)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(symbol)
    }
}
