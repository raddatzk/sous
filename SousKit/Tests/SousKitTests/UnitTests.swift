import Foundation
import Testing
@testable import SousKit

@Suite("Units and quantities")
struct UnitTests {
    @Test("Unknown symbols round-trip as custom units")
    func unknownSymbolBecomesCustom() throws {
        let unit = IngredientUnit(symbol: "Handvoll")
        #expect(unit == .custom("Handvoll"))
        #expect(unit.dimension == .imprecise)
        #expect(!unit.isConvertible)

        let data = try JSONEncoder().encode(unit)
        #expect(try JSONDecoder().decode(IngredientUnit.self, from: data) == unit)
    }

    @Test("Known symbols are matched case-insensitively")
    func knownSymbolMatching() {
        #expect(IngredientUnit(symbol: "kg") == .kilogram)
        #expect(IngredientUnit(symbol: "el") == .tablespoon)
        #expect(IngredientUnit(symbol: " g ") == .gram)
    }

    @Test("Conversion works within a dimension")
    func conversionWithinDimension() throws {
        let flour = Quantity(1500, .gram)
        let converted = try #require(flour.converted(to: .kilogram))
        #expect(converted.amount == 1.5)
        #expect(converted.unit == .kilogram)

        let oil = Quantity(2, .tablespoon)
        #expect(oil.inBaseUnit == 30)
        #expect(try #require(oil.converted(to: .milliliter)).amount == 30)
    }

    @Test("Conversion across dimensions and imprecise units is refused")
    func conversionRefused() {
        #expect(Quantity(200, .gram).converted(to: .milliliter) == nil)
        #expect(Quantity(1, .pinch).converted(to: .gram) == nil)
        #expect(Quantity(1, .custom("Bund")).converted(to: .gram) == nil)
    }
}
