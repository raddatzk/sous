import Foundation
import Testing
@testable import SousKit

@Suite("Links a deletion would break")
struct RecipeLinkAuditTests {
    private func recipe(_ title: String, links: [Recipe] = []) -> Recipe {
        Recipe(
            title: title,
            ingredientsText: links
                .map { "2 Portionen \(RecipeLink.markdown(title: $0.title, id: $0.id))" }
                .joined(separator: "\n")
        )
    }

    @Test("A recipe naming a doomed one is reported, with what it names")
    func reportsBreaks() {
        let naan = recipe("Naan")
        let curry = recipe("Curry", links: [naan])
        let salad = recipe("Salat")

        let breaks = RecipeLinkAudit.breaks(deleting: [naan], in: [curry, salad, naan])

        #expect(breaks.count == 1)
        #expect(breaks.first?.source.title == "Curry")
        #expect(breaks.first?.targets.map(\.title) == ["Naan"])
    }

    @Test("A link between two recipes that both go is nobody's loss")
    func bothDeleted() {
        let naan = recipe("Naan")
        let curry = recipe("Curry", links: [naan])

        #expect(RecipeLinkAudit.breaks(deleting: [naan, curry], in: [curry, naan]).isEmpty)
    }

    @Test("A recipe already in the trash is not a source worth warning about")
    func trashedSource() {
        let naan = recipe("Naan")
        var curry = recipe("Curry", links: [naan])
        curry.deletedAt = .now

        #expect(RecipeLinkAudit.breaks(deleting: [naan], in: [curry, naan]).isEmpty)
    }

    @Test("Several links from one recipe are one entry with several targets")
    func severalTargets() {
        let naan = recipe("Naan")
        let chutney = recipe("Chutney")
        let curry = recipe("Curry", links: [naan, chutney])

        let breaks = RecipeLinkAudit.breaks(deleting: [naan, chutney], in: [curry, naan, chutney])

        #expect(breaks.count == 1)
        #expect(breaks.first?.targets.map(\.title) == ["Naan", "Chutney"])
    }

    @Test("Nothing to delete is nothing to warn about")
    func nothingDeleted() {
        let naan = recipe("Naan")
        #expect(RecipeLinkAudit.breaks(deleting: [], in: [naan]).isEmpty)
    }
}
