import Foundation
import Testing
@testable import SousKit

@Suite("Quantity formatting")
struct QuantityFormatterTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    @Test("Large weights and volumes are promoted to the bigger unit")
    func promotion() {
        #expect(formatter.string(for: Quantity(1500, .gram)) == "1,5 kg")
        #expect(formatter.string(for: Quantity(1000, .milliliter)) == "1 l")
        #expect(formatter.string(for: Quantity(999, .gram)) == "999 g")
    }

    @Test("Fractional large units are demoted")
    func demotion() {
        #expect(formatter.string(for: Quantity(0.5, .kilogram)) == "500 g")
        #expect(formatter.string(for: Quantity(0.25, .liter)) == "250 ml")
    }

    @Test("Spoons and counts use fraction glyphs")
    func fractions() {
        #expect(formatter.string(for: Quantity(0.5, .teaspoon)) == "½ TL")
        #expect(formatter.string(for: Quantity(1.5, .tablespoon)) == "1 ½ EL")
        #expect(formatter.string(for: Quantity(0.25, .piece)) == "¼")
    }

    @Test("Counted items carry no unit symbol")
    func countedItems() {
        #expect(formatter.string(for: Quantity(2, .piece)) == "2")
        #expect(formatter.string(for: Quantity(1, .pinch)) == "1 Prise")
    }

    @Test("Weights stay decimal rather than fractional")
    func weightsStayDecimal() {
        #expect(formatter.string(for: Quantity(0.5, .gram)) == "0,5 g")
        #expect(formatter.string(for: Quantity(333.333, .gram)) == "333 g")
    }
}
