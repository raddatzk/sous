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
    /// A serving of another recipe: "1 Portion [Naan](…)".
    case portion
    /// A leaf, counted rather than weighed: "10 Blätter Basilikum".
    case leaf
    /// The German recipe cup, which is a rough measure and not the US cup's
    /// 240 ml — what it holds depends on what is in it, so it converts through
    /// the measure table like a pinch does, not through a volume factor.
    case cup
    case custom(String)

    public static let allKnown: [IngredientUnit] = [
        .gram, .kilogram, .milliliter, .liter, .teaspoon, .tablespoon,
        .piece, .pinch, .bunch, .clove, .package, .portion, .leaf, .cup,
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
        case .portion: "Portion"
        case .leaf: "Blatt"
        case .cup: "Tasse"
        case .custom(let symbol): symbol
        }
    }

    /// The symbol as it should appear next to an amount. Counted items read
    /// better without one — "2 Eier", not "2 Stk. Eier".
    public var displaySymbol: String {
        self == .piece ? "" : symbol
    }

    /// How a unit is written in practice, beyond its canonical symbol —
    /// plurals and the spellings people actually type. Recipes are written by
    /// hand and imported from sites; "2 Stück", "2 Stk." and "2 St" are all
    /// the same thing.
    var spellings: [String] {
        switch self {
        case .gram: ["g", "gr", "gramm"]
        case .kilogram: ["kg", "kilo", "kilogramm"]
        case .milliliter: ["ml", "milliliter"]
        case .liter: ["l", "liter"]
        case .teaspoon: ["tl", "teelöffel"]
        case .tablespoon: ["el", "esslöffel"]
        case .piece: ["stk", "stück", "st", "x"]
        case .pinch: ["prise", "prisen"]
        case .bunch: ["bund", "bünde"]
        case .clove: ["zehe", "zehen"]
        case .package: ["pck", "packung", "packungen", "päckchen"]
        case .portion: ["portion", "portionen"]
        case .leaf: ["blatt", "blätter"]
        case .cup: ["tasse", "tassen"]
        case .custom: []
        }
    }

    public init(symbol: String) {
        let normalized = Self.normalize(symbol)
        if let known = Self.allKnown.first(where: { $0.spellings.contains(normalized) }) {
            self = known
        } else {
            self = .custom(symbol.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Lowercased and stripped of the trailing period an abbreviation carries.
    private static func normalize(_ symbol: String) -> String {
        symbol
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    public var dimension: UnitDimension {
        switch self {
        case .gram, .kilogram: .mass
        case .milliliter, .liter, .teaspoon, .tablespoon: .volume
        case .piece: .count
        case .pinch, .bunch, .clove, .package, .portion, .leaf, .cup, .custom: .imprecise
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
        case .pinch, .bunch, .clove, .package, .portion, .leaf, .cup, .custom: nil
        }
    }

    public var isConvertible: Bool { baseUnitFactor != nil }

    /// Units that describe the same thing on a shopping list and can be
    /// added together. Spoons are deliberately absent: they measure while
    /// cooking, not while buying.
    public var shoppingGroup: String? {
        switch self {
        case .gram, .kilogram: "mass"
        case .milliliter, .liter: "volume"
        default: nil
        }
    }
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
