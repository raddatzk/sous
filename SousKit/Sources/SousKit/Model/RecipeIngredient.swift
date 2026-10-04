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
    /// "Allgemein" rather than something like "unbestimmt".
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

    /// How the shopping list annotates an amount that named a state —
    /// "500 g + 300 g (gegart gewogen)".
    ///
    /// It says *gewogen*, not just *gegart*, because that is the whole point
    /// of the annotation: nobody buys 300 g of cooked potatoes. How much raw
    /// yields 300 g cooked the source does not know and the list does not
    /// pretend to, so it hands the cook the fact and stops there. `nil` where
    /// the line said nothing, which is almost every line.
    public var shoppingAnnotation: String? {
        switch self {
        case .unspecified: nil
        case .raw: "roh gewogen"
        case .cooked: "gegart gewogen"
        }
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
    /// The size word the measure carried, when the line wrote one — see
    /// ``IngredientSize``.
    public var size: IngredientSize?
    /// How it is prepared: "fein gehackt".
    public var preparation: String?
    /// Optional heading this line belongs to: "Für den Teig".
    public var group: String?
    public var state: IngredientState
    /// The line is not in the fixed form (see ``IngredientLineReader``): its
    /// words are kept as written in `name`, its amount is still read, and it
    /// gets no nutrition until it is optimized.
    public var isOutsideForm: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: Quantity? = nil,
        size: IngredientSize? = nil,
        preparation: String? = nil,
        group: String? = nil,
        state: IngredientState = .unspecified,
        isOutsideForm: Bool = false
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.size = size
        self.preparation = preparation
        self.group = group
        self.state = state
        self.isOutsideForm = isOutsideForm
    }
}
