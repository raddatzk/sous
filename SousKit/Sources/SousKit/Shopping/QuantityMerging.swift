import Foundation

extension Array where Element == Quantity {
    /// Adds an amount to the ones already gathered.
    ///
    /// Only amounts bought in the same measure are combined: 300 g and 0,2 kg
    /// make 500 g. Everything else is kept side by side — "100 g + 3 EL" is
    /// honest, while a converted "135 ml" would be a number nobody asked for.
    /// Spoons in particular are a cooking measure, not a shopping one.
    public func adding(_ quantity: Quantity) -> [Quantity] {
        var result = self

        if let group = quantity.unit.shoppingGroup,
           let index = result.firstIndex(where: { $0.unit.shoppingGroup == group }) {
            let existing = result[index]
            guard let converted = quantity.converted(to: existing.unit) else { return result }
            result[index] = Quantity(existing.amount + converted.amount, existing.unit)
            return result
        }

        // Outside those groups only identical units add up.
        if let index = result.firstIndex(where: { $0.unit == quantity.unit }) {
            result[index] = Quantity(result[index].amount + quantity.amount, quantity.unit)
            return result
        }

        result.append(quantity)
        return result
    }

    public func adding(_ quantities: [Quantity]) -> [Quantity] {
        quantities.reduce(self) { $0.adding($1) }
    }
}
