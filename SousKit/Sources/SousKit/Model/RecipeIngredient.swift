import Foundation

/// Whether the amount refers to the ingredient raw or cooked. This matters for
/// nutrition lookup — 100 g of raw and cooked pasta are very different things.
public enum IngredientState: String, Codable, Hashable, Sendable {
    case unspecified
    case raw
    case cooked

    /// How a nutrition table's variants read when there is more than one of
    /// them and a person has to pick. "Unspecified" is only ever shown on its
    /// own, where naming the state at all would be noise — hence the plain
    /// "je 100 g" rather than something like "unbestimmt".
    public var title: String {
        switch self {
        case .unspecified: "Allgemein"
        case .raw: "Roh"
        case .cooked: "Gegart"
        }
    }

    /// Raw before cooked before unspecified — the order BLS's own merge step
    /// writes them in, so a picker lists them the way the data reads.
    public static let displayOrder: [IngredientState] = [.raw, .cooked, .unspecified]
}

/// Words that stand in for a number — "Salz nach Geschmack", "etwas Mehl".
///
/// The phrase is kept as written, and where it stood, so the line renders
/// back exactly as typed; the *name* stays clean ("Salz"), which is what
/// lets the catalog recognize the ingredient at all.
public struct UnquantifiedPhrase: Codable, Hashable, Sendable {
    public enum Placement: String, Codable, Hashable, Sendable {
        /// "etwas Salz" — the phrase sits where a number would.
        case beforeName
        /// "Salz nach Geschmack" — the phrase trails the name.
        case afterName
    }

    public var phrase: String
    public var placement: Placement

    public init(phrase: String, placement: Placement) {
        self.phrase = phrase
        self.placement = placement
    }
}

/// One line of a recipe's ingredient list.
///
/// The fields are kept separate on purpose: quantity, unit, name, and
/// preparation each need to be addressed on their own for scaling, nutrition
/// matching, and shopping lists. Merging them into one string is the thing
/// that cannot be undone later.
public struct RecipeIngredient: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// The ingredient itself, without amount or preparation: "Zwiebel".
    public var name: String
    /// `nil` means an unquantified amount ("Salz nach Geschmack").
    public var quantity: Quantity?
    /// The words that stood in for a number, when the line wrote its amount
    /// that way — see ``UnquantifiedPhrase``.
    public var unquantifiedPhrase: UnquantifiedPhrase?
    /// How it is prepared: "fein gehackt".
    public var preparation: String?
    /// Optional heading this line belongs to: "Für den Teig".
    public var group: String?
    public var state: IngredientState
    /// Grams resolved against a nutrition database. Populated in phase 2,
    /// never entered by hand.
    public var resolvedGrams: Double?
    /// Set when this ingredient is itself another recipe in the library.
    public var linkedRecipeID: UUID?
    /// Seasoning and frying oil do not scale linearly with servings.
    public var scalesWithServings: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: Quantity? = nil,
        unquantifiedPhrase: UnquantifiedPhrase? = nil,
        preparation: String? = nil,
        group: String? = nil,
        state: IngredientState = .unspecified,
        resolvedGrams: Double? = nil,
        linkedRecipeID: UUID? = nil,
        scalesWithServings: Bool = true
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unquantifiedPhrase = unquantifiedPhrase
        self.preparation = preparation
        self.group = group
        self.state = state
        self.resolvedGrams = resolvedGrams
        self.linkedRecipeID = linkedRecipeID
        self.scalesWithServings = scalesWithServings
    }
}
