import Foundation

/// An amount paired with a unit, e.g. `250 g` or `2 Stk.`.
public struct Quantity: Codable, Hashable, Sendable {
    public var amount: Double
    public var unit: IngredientUnit

    public init(_ amount: Double, _ unit: IngredientUnit) {
        self.amount = amount
        self.unit = unit
    }

    public func scaled(by factor: Double) -> Quantity {
        Quantity(amount * factor, unit)
    }

    /// Converts to `target` if both units share a dimension and are convertible.
    public func converted(to target: IngredientUnit) -> Quantity? {
        guard unit.dimension == target.dimension,
              let from = unit.baseUnitFactor,
              let to = target.baseUnitFactor,
              to != 0
        else { return nil }
        return Quantity(amount * from / to, target)
    }

    /// This quantity with `other` added on, kept in this quantity's unit —
    /// `nil` when the two cannot be added at all: different dimensions, or
    /// units nothing can convert (unless they are the very same unit, which
    /// adds plainly).
    public func adding(_ other: Quantity) -> Quantity? {
        if other.unit == unit { return Quantity(amount + other.amount, unit) }
        guard let converted = other.converted(to: unit) else { return nil }
        return Quantity(amount + converted.amount, unit)
    }

    /// The amount expressed in the dimension's base unit (gram or milliliter),
    /// `nil` for units that cannot be converted.
    public var inBaseUnit: Double? {
        guard let factor = unit.baseUnitFactor else { return nil }
        return amount * factor
    }
}
