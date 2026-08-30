import Foundation
import Testing
@testable import SousKit

/// Finding the row a cook means when the cook and the table call it
/// different things.
///
/// Containment alone only ever reaches down, to a name longer than what was
/// typed — and German runs the other way. The table stocks the general word,
/// the bottle carries the specific one: BLS names Q160000 "Leinöl", and
/// nobody writes anything but "Leinsamenöl" on a shopping list. Since
/// `"leinöl".contains("leinsamenöl")` is false, the one right row was
/// invisible to the one name anybody types, and the picker offered nothing
/// at all.
///
/// These check both halves of the bargain: the compound is found, and the
/// list does not fill up with everything that happens to end in the same
/// three letters.
@Suite("Finding a row by the name a cook writes")
struct BLSSearchTests {
    private let bls = BLSCatalog.bundled

    @Test("A compound written more specifically than the table finds its row")
    func compoundReachesItsRow() throws {
        let hits = bls.search("Leinsamenöl")
        let first = try #require(hits.first)
        #expect(first.name == "Leinöl")
        #expect(first.code == "Q160000")
    }

    @Test("The head noun outranks the modifier")
    func theOilComesBeforeTheSeed() throws {
        // Both are real matches: the oil shares the ending, the seed shares
        // the beginning. A German compound says what the thing *is* last, so
        // the oil has to lead — offering 470 kcal of seed for a spoonful of
        // 900 kcal oil is the mistake this ordering exists to prevent.
        let names = bls.search("Leinsamenöl").map(\.name)
        let oil = try #require(names.firstIndex(of: "Leinöl"))
        let seed = try #require(names.firstIndex(of: "Leinsamen"))
        #expect(oil < seed)
    }

    @Test("A modifier written in front still finds the plain row")
    func aPrefixedCompoundFindsThePlainRow() throws {
        // The commoner shape: what a cook writes is the table's own name
        // with something said in front of it. The table has no opinion about
        // organic, and should not need one to be found.
        #expect(try #require(bls.search("Bio-Sesamöl").first).name == "Sesamöl")
    }

    @Test("Reaching up does not let everything in")
    func theListStaysShort() {
        // The guard that makes the relaxation safe. Nearly every row shares
        // a short ending with something, and a search for one oil that
        // returned every oil in the table would be no more use than one that
        // returned nothing.
        #expect(bls.search("Leinsamenöl").count <= 4)
        #expect(bls.search("Omas Schmalztopf").isEmpty)
        // Invented, and made of real German parts — the case a suffix rule
        // gets wrong if it is allowed to match on one or two letters.
        #expect(bls.search("Quittenglibber").isEmpty)
    }

    @Test("An exact name still wins its own search")
    func theExactRowLeads() throws {
        // The relaxation is additive: everything that resolved before has to
        // resolve the same way, at the same rank.
        #expect(try #require(bls.search("Leinöl").first).code == "Q160000")
        #expect(try #require(bls.search("Sonnenblumenöl").first).name == "Sonnenblumenöl")
    }
}
