import Foundation
import Testing
@testable import SousKit

@Suite("Nutrient formatting")
struct NutrientFormatterTests {
    private let formatter = NutrientFormatter(locale: Locale(identifier: "de_DE"))

    @Test("Ordinary figures stay in their own unit, to one decimal place")
    func ordinaryFigures() {
        #expect(formatter.string(0.6, in: .grams) == "0,6 g")
        #expect(formatter.string(3, in: .grams) == "3 g")
        #expect(formatter.string(17.94, in: .grams) == "17,9 g")
        #expect(formatter.string(57, in: .micrograms) == "57 µg")
    }

    @Test("A figure too small for its unit moves down instead of rounding to nothing")
    func smallFiguresChangeUnit() {
        // A potato: 3 mg of sodium per 100 g, which is 7,5 mg of salt — and
        // "0 g" if the gram is treated as compulsory.
        #expect(formatter.string(3 * 2.5 / 1000, in: .grams) == "7,5 mg")
        #expect(formatter.string(0.0036, in: .grams) == "3,6 mg")
        #expect(formatter.string(0.000_001, in: .grams) == "1 µg")
        #expect(formatter.string(0.001, in: .milligrams) == "1 µg")
    }

    @Test("Below the smallest unit the decimals grow rather than the figure vanishing")
    func tracesBelowMicrograms() {
        // Vitamin A is quoted in micrograms; there is nowhere below to go.
        #expect(formatter.string(0.001, in: .micrograms) == "0,001 µg")
        #expect(formatter.string(0.04, in: .micrograms) == "0,04 µg")
    }

    @Test("Zero keeps the unit it was asked about")
    func zeroStaysPut() {
        #expect(formatter.string(0, in: .grams) == "0 g")
        #expect(formatter.string(0, in: .micrograms) == "0 µg")
    }

    @Test("A large figure is never promoted — the unit is the label's, not the number's")
    func noPromotion() {
        // Salt itself, at 38 g per 100 g, and vitamin C at a gram.
        #expect(formatter.string(38, in: .grams) == "38 g")
        #expect(formatter.string(1000, in: .milligrams) == "1000 mg")
    }

    @Test("Energy is whole")
    func energy() {
        #expect(formatter.string(kilocalories: 82.6) == "83 kcal")
    }
}
