import Foundation
import Testing
@testable import SousKit

@Suite("Completing categories")
struct CategoryCompletionTests {
    private let existing = ["Salate", "Schnell", "Suppen", "Backen"]

    @Test("Suggestions come from what the library already uses")
    func suggestions() {
        #expect(CategoryCompletion.suggestions(for: "S", categories: existing)
            == ["Salate", "Suppen", "Schnell"])
    }

    @Test("An empty entry is not a question")
    func nothingTyped() {
        #expect(CategoryCompletion.suggestions(for: "", categories: existing).isEmpty)
        #expect(CategoryCompletion.suggestions(for: "  ", categories: existing).isEmpty)
    }

    @Test("Categories the recipe already carries are not offered again")
    func alreadyCarried() {
        let matches = CategoryCompletion.suggestions(
            for: "S",
            categories: existing,
            excluding: ["salate"]
        )
        #expect(!matches.contains("Salate"))
        #expect(matches.contains("Suppen"))
    }

    @Test("An exact match needs no suggesting")
    func exactMatch() {
        #expect(!CategoryCompletion.suggestions(for: "Suppen", categories: existing).contains("Suppen"))
    }

    @Test("What was typed is taken as one category, trimmed")
    func addsOne() {
        #expect(CategoryCompletion.adding("  Nachtisch ", to: ["Schnell"]) == ["Schnell", "Nachtisch"])
    }

    @Test("Nothing typed adds nothing")
    func addsNothing() {
        #expect(CategoryCompletion.adding("   ", to: ["Schnell"]) == ["Schnell"])
        #expect(CategoryCompletion.adding(",,", to: []) == [])
    }

    @Test("A pasted list becomes one category each")
    func addsSeveral() {
        #expect(CategoryCompletion.adding("Salate, Schnell\nSuppen", to: [])
            == ["Salate", "Schnell", "Suppen"])
    }

    @Test("A category the recipe already carries is not added again")
    func noDuplicates() {
        #expect(CategoryCompletion.adding("salate", to: ["Salate"]) == ["Salate"])
    }

    @Test("The library's spelling wins over the one just typed")
    func adoptsKnownSpelling() {
        #expect(CategoryCompletion.adding("salate", to: [], known: existing) == ["Salate"])
        #expect(CategoryCompletion.adding("Gebäck", to: [], known: existing) == ["Gebäck"])
    }
}
