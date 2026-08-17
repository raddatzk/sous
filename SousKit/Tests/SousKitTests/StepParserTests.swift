import Foundation
import Testing
@testable import SousKit

@Suite("Step parsing")
struct StepParserTests {
    @Test("Each line becomes a step")
    func linesBecomeSteps() {
        let steps = StepParser.parse("""
        Zwiebeln schneiden

        In der Pfanne anbraten
        """)

        #expect(steps.map(\.text) == ["Zwiebeln schneiden", "In der Pfanne anbraten"])
    }

    @Test("Existing numbering is stripped so steps are not numbered twice")
    func listMarkers() {
        let steps = StepParser.parse("""
        1. Zwiebeln schneiden
        2) Anbraten
        - Servieren
        """)

        #expect(steps.map(\.text) == ["Zwiebeln schneiden", "Anbraten", "Servieren"])
    }

    @Test("A colon inside an instruction is not a heading")
    func colonIsNotAHeading() {
        let steps = StepParser.parse("Wichtig: Die Pfanne muss heiß sein")

        #expect(steps.count == 1)
        #expect(steps[0].group == nil)
    }

    @Test("Markdown headings open a section")
    func headings() {
        let steps = StepParser.parse("""
        # Teig
        Mehl und Ei verrühren

        # Sauce
        Sahne erhitzen
        """)

        #expect(steps.map(\.group) == ["Teig", "Sauce"])
    }

    @Test("Steps render back to the text they came from")
    func roundTrip() {
        let source = """
        # Teig
        Mehl und Ei verrühren
        30 Minuten ruhen lassen

        # Sauce
        Sahne erhitzen
        """

        #expect(StepParser.text(for: StepParser.parse(source)) == source)
    }
}
