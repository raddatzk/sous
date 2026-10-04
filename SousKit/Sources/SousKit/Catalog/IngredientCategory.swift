import Foundation

/// What kind of thing an ingredient is — which doubles as the aisle it is
/// found in, so a shopping list can be walked through a shop in order.
///
/// Read tolerantly: an aisle a newer data set brings ("plantBased" was the
/// first) reads as `other` in an app that does not know it yet,
/// rather than failing the whole set.
public enum IngredientCategory: String, Codable, CaseIterable, Sendable {
    case vegetables
    case fruit
    case herbs
    case spices
    case meat
    case fish
    case dairy
    /// Tofu, Sojahack and their like: the shelf most shops keep beside the
    /// dairy and the meat, not among the beans.
    case plantBased
    case bakery
    case grains
    case legumes
    case nuts
    case oils
    case baking
    case canned
    case drinks
    case frozen
    case other

    public var title: String {
        switch self {
        case .vegetables: "Gemüse"
        case .fruit: "Obst"
        case .herbs: "Kräuter"
        case .spices: "Gewürze"
        case .meat: "Fleisch & Wurst"
        case .fish: "Fisch"
        case .dairy: "Milchprodukte & Eier"
        case .plantBased: "Vegan & Fleischersatz"
        case .bakery: "Brot & Backwaren"
        case .grains: "Nudeln, Reis & Getreide"
        case .legumes: "Hülsenfrüchte"
        case .nuts: "Nüsse & Samen"
        case .oils: "Öle & Essig"
        case .baking: "Backen & Süßes"
        case .canned: "Konserven & Gläser"
        case .drinks: "Getränke"
        case .frozen: "Tiefkühl"
        case .other: "Sonstiges"
        }
    }

    /// The order a shop is usually walked in, so the list reads as a route.
    public var aisleOrder: Int {
        switch self {
        case .vegetables: 0
        case .fruit: 1
        case .herbs: 2
        case .bakery: 3
        case .dairy: 4
        case .plantBased: 5
        case .meat: 6
        case .fish: 7
        case .frozen: 8
        case .grains: 9
        case .legumes: 10
        case .canned: 11
        case .oils: 12
        case .spices: 13
        case .nuts: 14
        case .baking: 15
        case .drinks: 16
        case .other: 17
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IngredientCategory(rawValue: raw) ?? .other
    }
}
