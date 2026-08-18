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
}
