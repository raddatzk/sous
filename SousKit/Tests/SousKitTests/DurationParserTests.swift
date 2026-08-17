import Foundation
import Testing
@testable import SousKit

@Suite("Duration parsing")
struct DurationParserTests {
    @Test("Minutes, hours and seconds are all recognized")
    func units() {
        #expect(DurationParser.seconds(in: "30 Minuten backen") == 1800)
        #expect(DurationParser.seconds(in: "10 Min. ruhen lassen") == 600)
        #expect(DurationParser.seconds(in: "1 Stunde ziehen lassen") == 3600)
        #expect(DurationParser.seconds(in: "90 Sekunden blanchieren") == 90)
        #expect(DurationParser.seconds(in: "2 Std. garen") == 7200)
    }

    @Test("A step without a time offers no timer")
    func noDuration() {
        #expect(DurationParser.seconds(in: "Zwiebeln schneiden") == nil)
        #expect(DurationParser.seconds(in: "Bei 180 Grad backen") == nil)
    }

    @Test("The first duration wins, since instructions run in order")
    func firstWins() {
        #expect(DurationParser.seconds(in: "5 Minuten anbraten, dann 20 Minuten schmoren") == 300)
    }

    @Test("Steps carry the timer they mention")
    func stepsGetTimers() {
        let steps = StepParser.parse("""
        Zwiebeln schneiden
        20 Minuten schmoren lassen
        """)

        #expect(steps[0].durationSeconds == nil)
        #expect(steps[1].durationSeconds == 1200)
    }
}
