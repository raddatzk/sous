import Foundation

/// What kind of thing an ingredient is — which doubles as the aisle it is
/// found in, so a shopping list can be walked through a shop in order.
public enum IngredientCategory: String, Codable, CaseIterable, Sendable {
    case vegetables
    case fruit
    case herbs
    case spices
    case meat
    case fish
    case dairy
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
        case .meat: 5
        case .fish: 6
        case .frozen: 7
        case .grains: 8
        case .legumes: 9
        case .canned: 10
        case .oils: 11
        case .spices: 12
        case .nuts: 13
        case .baking: 14
        case .drinks: 15
        case .other: 16
        }
    }
}
