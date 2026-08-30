import Foundation
import Testing
@testable import SousKit

/// Holding the editor's text and the recipe's text in step.
///
/// The editor shows "2 Portionen Naan" and the recipe keeps
/// "2 Portionen [Naan](sous://recipe/…)". Everything that reads the cursor —
/// the ingredient autocomplete, "Rezept verlinken" — works on the stored one,
/// and everything the cook does happens in the shown one. A mapping that is
/// off by one puts an inserted link inside a word, or offers completions for
/// the line above.
@Suite("Recipe links as chips")
struct RecipeLinkChippingTests {
    private let id = UUID(uuidString: "9E2F0A1C-4B3D-4E5F-8A9B-0C1D2E3F4A5B")!

    private func stored(_ prefix: String, _ suffix: String = "") -> String {
        "\(prefix)\(RecipeLink.markdown(title: "Naan", id: id))\(suffix)"
    }

    @Test("The shown text is the title, and nothing of the syntax")
    func displayIsJustTheTitle() throws {
        let (text, chips) = RecipeLinkChipping.display(of: stored("2 Portionen ", " dazu"))
        #expect(text == "2 Portionen Naan dazu")
        let chip = try #require(chips.first)
        #expect(chip.title == "Naan")
        #expect(chip.url == "sous://recipe/\(id.uuidString)")
        // Where the title actually landed, so the run can be painted.
        #expect((text as NSString).substring(with: chip.displayRange) == "Naan")
    }

    @Test("A link the app did not write is left as typed")
    func foreignLinksAreNotHidden() {
        // Hiding half of an ordinary markdown link would hide something the
        // cook meant to see — and there would be no way to get it back.
        let (text, chips) = RecipeLinkChipping.display(of: "Siehe [die Quelle](https://example.com)")
        #expect(text == "Siehe [die Quelle](https://example.com)")
        #expect(chips.isEmpty)
    }

    @Test("Every position in the shown text has a home in the stored one")
    func offsetsRoundTrip() {
        let text = stored("2 Portionen ", " dazu")
        let shown = RecipeLinkChipping.display(of: text).text
        for offset in 0...shown.count {
            let back = RecipeLinkChipping.storedOffset(forDisplay: offset, in: text)
            #expect(back >= 0 && back <= text.count, "display \(offset) → stored \(back)")
            // Outside the chip the trip is exact; inside it every position
            // collapses onto the link's start, which is the whole point.
            let forward = RecipeLinkChipping.displayOffset(forStored: back, in: text)
            let insideChip = (12...15).contains(offset)
            #expect(forward == (insideChip ? 12 : offset), "display \(offset) → \(back) → \(forward)")
        }
    }

    @Test("The far side of a chip is the far side in both texts")
    func theEndOfAChipLinesUp() {
        let text = stored("2 Portionen ", " dazu")
        // "2 Portionen " is 12, the chip shows 4, so 16 is just past it.
        #expect(RecipeLinkChipping.storedOffset(forDisplay: 16, in: text) == 12 + RecipeLink.markdown(title: "Naan", id: id).count)
        #expect(RecipeLinkChipping.displayOffset(forStored: text.count, in: text) == 21)
    }

    @Test("A cursor pointed into the syntax lands beside the chip, not inside it")
    func offsetsInsideTheSyntaxAreTiedOff() {
        let text = stored("2 Portionen ")
        // Somewhere in the middle of the UUID — a position the editor can
        // never show, and so must never report back as a place to type.
        #expect(RecipeLinkChipping.displayOffset(forStored: 25, in: text) == 12)
    }

    @Test("Two links in one line each keep their own place")
    func twoChipsInOneLine() {
        let other = UUID(uuidString: "1A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D")!
        let text = "\(RecipeLink.markdown(title: "Naan", id: id)) und \(RecipeLink.markdown(title: "Raita", id: other))"
        let (shown, chips) = RecipeLinkChipping.display(of: text)
        #expect(shown == "Naan und Raita")
        #expect(chips.map(\.title) == ["Naan", "Raita"])
        #expect(RecipeLinkChipping.storedOffset(forDisplay: 9, in: text) == text.count - RecipeLink.markdown(title: "Raita", id: other).count)
    }

    @Test("A line with no link is its own display text")
    func plainTextIsUntouched() {
        let text = "500 g Sojahack\n80 g rote Linsen"
        let (shown, chips) = RecipeLinkChipping.display(of: text)
        #expect(shown == text)
        #expect(chips.isEmpty)
        for offset in 0...text.count {
            #expect(RecipeLinkChipping.storedOffset(forDisplay: offset, in: text) == offset)
            #expect(RecipeLinkChipping.displayOffset(forStored: offset, in: text) == offset)
        }
    }
}
