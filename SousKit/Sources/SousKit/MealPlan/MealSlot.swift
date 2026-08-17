import Foundation

/// Which meal of the day a recipe is planned for.
public enum MealSlot: String, Codable, CaseIterable, Sendable {
    case breakfast
    case lunch
    case dinner

    public var title: String {
        switch self {
        case .breakfast: "Frühstück"
        case .lunch: "Mittag"
        case .dinner: "Abend"
        }
    }

    public var symbolName: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon"
        }
    }

    /// The order the meals happen in.
    public var order: Int {
        switch self {
        case .breakfast: 0
        case .lunch: 1
        case .dinner: 2
        }
    }
}
