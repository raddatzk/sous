import Foundation
import Testing
@testable import SousKit

@Suite("Completing categories")
struct CategoryCompletionTests {
    private let existing = ["Salate", "Schnell", "Suppen", "Backen"]

    @Test("What is being typed is the part after the last comma")
    func partialEntry() {
        #expect(CategoryCompletion.partial(in: "Schnell, Sal") == "Sal")
        #expect(CategoryCompletion.partial(in: "Sal") == "Sal")
        #expect(CategoryCompletion.partial(in: "Schnell, ") == nil)
    }

    @Test("Suggestions come from what the library already uses")
    func suggestions() {
        #expect(CategoryCompletion.suggestions(for: "S", categories: existing)
            == ["Salate", "Suppen", "Schnell"])
    }

    @Test("Categories already in the list are not offered again")
    func alreadyListed() {
        let matches = CategoryCompletion.suggestions(for: "Salate, S", categories: existing)
        #expect(!matches.contains("Salate"))
        #expect(matches.contains("Suppen"))
    }

    @Test("An exact match needs no suggesting")
    func exactMatch() {
        #expect(!CategoryCompletion.suggestions(for: "Suppen", categories: existing).contains("Suppen"))
    }

    @Test("Taking a suggestion completes the entry and starts the next")
    func completing() {
        #expect(CategoryCompletion.completed(text: "Sal", with: "Salate") == "Salate, ")
        #expect(
            CategoryCompletion.completed(text: "Schnell, Sup", with: "Suppen")
                == "Schnell, Suppen, "
        )
    }
}
