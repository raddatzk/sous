import Foundation
import Testing
@testable import SousKit

/// What a variety takes from its ancestry, and how it says so.
///
/// Decision B of the catalog target: inheritance is a proposal, never a
/// confirmation. The case that decided it - Räucherlachs at raw salmon's
/// 32 mg of sodium instead of its own row's 1170, confirmed because Lachs
/// was confirmed - is in `BundledDataTests`; these are the mechanics.
@Suite("Inheritance down the variety chain")
struct InheritanceTests {
    private func info(kcal: Double) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: 0, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0,
            fiberG: 0, sodiumMg: 0, vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0,
            vitaminEMg: 0, calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
        )
    }

    private func catalog() -> NutritionCatalog {
        NutritionCatalog(entries: [
            CatalogNutrition(
                name: "Pilz",
                bases: ["raw": NutritionBasis(
                    values: info(kcal: 22), code: "K700100", catalogName: "Pilz roh", status: .confirmed
                )],
                unitWeightsGrams: ["Stk.": 20]
            ),
            CatalogNutrition(name: "Champignon", bases: [:], parentName: "Pilz"),
            CatalogNutrition(
                name: "Brauner Champignon", bases: [:],
                unitWeightsGrams: ["Stk.": 25], parentName: "Champignon"
            ),
            CatalogNutrition(
                name: "Minze",
                bases: ["unspecified": NutritionBasis(values: .zero, status: .deliberatelyWithout)]
            ),
            CatalogNutrition(name: "Pfefferminze", bases: [:], parentName: "Minze"),
        ])
    }

    @Test("A variety computes with its parent's row, as a proposal that names the parent")
    func inheritedBasisIsProposedAndAttributed() throws {
        let champignon = try #require(catalog().nutrition(forCanonicalName: "Champignon"))
        let basis = try #require(champignon.basis(for: .raw))
        #expect(basis.code == "K700100")
        #expect(basis.status == .proposed)
        #expect(basis.inheritedFrom == "Pilz")
        #expect(champignon.inheritedFrom == "Pilz")
    }

    @Test("The chain is walked to the nearest ancestor with a basis")
    func inheritanceReachesPastAnEmptyParent() throws {
        // Champignon has no basis of its own; Brauner Champignon has to look
        // one step further. One hop - which is what the lookup used to take -
        // would have found nothing and left the line a gap.
        let brown = try #require(catalog().nutrition(forCanonicalName: "Brauner Champignon"))
        #expect(brown.basis(for: .raw)?.code == "K700100")
        #expect(brown.basis(for: .raw)?.status == .proposed)
        #expect(brown.inheritedFrom == "Pilz")
        // Its own piece weight wins over the ancestor's; the density and the
        // rest come down the chain as before.
        #expect(brown.unitWeightsGrams["Stk."] == 25)
    }

    @Test("A settled non-answer is inherited as what it is")
    func deliberatelyWithoutPassesThroughUnchanged() throws {
        // Minze has no BLS row and says so. Pfefferminze inherits the
        // *answer*, not a proposal to compute with zero.
        let mint = try #require(catalog().nutrition(forCanonicalName: "Pfefferminze"))
        #expect(mint.basis(for: .unspecified)?.status == .deliberatelyWithout)
        #expect(mint.inheritedFrom == "Minze")
    }

    @Test("An entry with its own basis is not touched by its ancestry")
    func ownBasisIsNotOverwritten() throws {
        let own = NutritionCatalog(entries: [
            CatalogNutrition(name: "Lachs", bases: ["raw": NutritionBasis(
                values: info(kcal: 180), code: "T410100", catalogName: "Lachs roh", status: .confirmed
            )]),
            CatalogNutrition(name: "Räucherlachs", bases: ["unspecified": NutritionBasis(
                values: info(kcal: 170), code: "T410600", catalogName: "Lachs geräuchert", status: .confirmed
            )], parentName: "Lachs"),
        ])
        let smoked = try #require(own.nutrition(forCanonicalName: "Räucherlachs"))
        #expect(smoked.basis(for: .unspecified)?.code == "T410600")
        #expect(smoked.basis(for: .unspecified)?.status == .confirmed)
        #expect(smoked.inheritedFrom == nil)
    }

    @Test("The entry as written is still reachable beside the resolved one")
    func ownEntryStaysAvailable() throws {
        let resolved = try #require(catalog().nutrition(forCanonicalName: "Champignon"))
        let written = try #require(catalog().ownEntry(forCanonicalName: "Champignon"))
        #expect(resolved.hasBases)
        #expect(!written.hasBases)
        #expect(written.inheritedFrom == nil)
    }

    @Test("A loop in the data ends the walk instead of the app")
    func cyclicDataDoesNotHang() {
        let loop = NutritionCatalog(entries: [
            CatalogNutrition(name: "A", bases: [:], parentName: "B"),
            CatalogNutrition(name: "B", bases: [:], parentName: "A"),
        ])
        #expect(loop.nutrition(forCanonicalName: "A")?.hasBases == false)
    }
}
