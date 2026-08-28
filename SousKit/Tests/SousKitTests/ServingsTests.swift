import Foundation
import Testing
@testable import SousKit

@Suite("Portion counts in words")
struct ServingsTests {
    @Test("One portion is singular — the only number that is")
    func oneIsSingular() {
        #expect(Servings.text(1) == "1 Portion")
        #expect(Servings.text(2) == "2 Portionen")
    }

    @Test("Every number the steppers can reach reads as German")
    func acrossTheRange() {
        // The dials are bounded by `Recipe.servingsRange`, so both ends are
        // numbers a cook can actually land on.
        #expect(Servings.text(Recipe.servingsRange.lowerBound) == "1 Portion")
        #expect(Servings.text(Recipe.servingsRange.upperBound) == "200 Portionen")
        for count in Recipe.servingsRange where count > 1 {
            #expect(Servings.text(count) == "\(count) Portionen")
        }
    }

    @Test("Zero is plural, as German has it — even where no dial goes there")
    func zeroIsPlural() {
        // Not reachable through the steppers, but the calendar note takes its
        // count from a stored plan entry rather than from a dial.
        #expect(Servings.text(0) == "0 Portionen")
    }
}
