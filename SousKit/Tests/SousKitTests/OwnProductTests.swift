import Foundation
import Testing
@testable import SousKit

/// Phase 7b: a household's own products are entries of its catalog, and a
/// name links to one ("Sojahack" → "Greenforce Sojahack"); a name nothing
/// stands in for becomes a word of its own, without values.
@Suite("Own products and own words")
struct OwnProductTests {
    static let sojahack = LocalAnswer(
        name: "Greenforce Sojahack", kind: .product, targetID: "margarine", brand: "Greenforce"
    )
    /// "Sojahack" is a catalog word: the household chooses its product for it.
    static let link = LocalAnswer(catalogID: "sojahack", name: "Sojahack", kind: .product, targetID: sojahack.key)

    @Test("A name linked to an own product computes the product's estimate and shows its brand")
    @MainActor
    func linkedName() async throws {
        let margarine = try #require(
            ProductTests.products.nutrition.nutrition(forCanonicalName: "Margarine")?.basis(for: .unspecified)
        )
        let (nutrition, catalog) = try ProductTests.libraries([Self.link, Self.sojahack])
        await catalog.reload()

        // Both are words of the household's catalog; the product carries its brand.
        #expect(IngredientLineReader.isInForm("100 g Sojahack", catalog: catalog.catalog))
        #expect(catalog.catalog.ingredient(for: "Greenforce Sojahack")?.product?.brand == "Greenforce")
        #expect(catalog.brand(for: "Sojahack") == "Greenforce")
        #expect(catalog.targetName(for: Self.link.targetID!) == "Greenforce Sojahack")
        #expect(catalog.ownProducts.map(\.name) == ["Greenforce Sojahack"])

        let result = try #require(await nutrition.nutrition(
            for: Recipe(title: "Bolognese", servings: 1, ingredientsText: "100 g Sojahack")
        ))
        #expect(abs(result.perPortion.kcal - margarine.values.kcal) < 1e-9)
        #expect(result.coverage.contributions.first?.estimatedLike == "Margarine")
        #expect(catalog.localTrace(for: "Greenforce Sojahack")?.label
            == "lokal: eigenes Produkt von Greenforce, Schätzung wie Margarine")
    }

    @Test("An own product's label values replace the estimate for every name linked to it")
    @MainActor
    func labelValues() async throws {
        var product = Self.sojahack
        product.values = NutritionInfo.label(
            kcal: 250, proteinG: 20, fatG: 15, saturatedFatG: 2, carbsG: 5, sugarG: 1, fiberG: nil, saltG: 1
        )
        let (nutrition, _) = try ProductTests.libraries([Self.link, product])
        let result = try #require(await nutrition.nutrition(
            for: Recipe(title: "Bolognese", servings: 1, ingredientsText: "100 g Sojahack")
        ))
        #expect(result.perPortion.kcal == 250)
        #expect(result.coverage.contributions.first?.estimatedLike == nil)
    }

    @Test("Renaming an own product takes the names linked to it along; deleting it leaves the catalog's word")
    @MainActor
    func renameAndDelete() async throws {
        let (_, catalog) = try ProductTests.libraries([Self.link, Self.sojahack])
        await catalog.reload()

        var renamed = try #require(catalog.ownProducts.first)
        renamed.name = "Greenforce Veganes Hack"
        #expect(await catalog.saveLocalAnswer(renamed))
        #expect(catalog.localAnswer(for: "Sojahack")?.targetID == "name:greenforce veganes hack")
        #expect(catalog.brand(for: "Sojahack") == "Greenforce")
        #expect(catalog.ownProducts.map(\.name) == ["Greenforce Veganes Hack"])

        await catalog.deleteLocalAnswer(try #require(catalog.ownProducts.first))
        #expect(catalog.localTrace(for: "Sojahack")?.status == .unresolvedTarget)
        #expect(catalog.brand(for: "Sojahack") == nil)
    }

    @Test("A word of its own is read and shopped as written, and not computed")
    @MainActor
    func ownWord() async throws {
        let (nutrition, catalog) = try ProductTests.libraries([])
        await catalog.reload()
        #expect(await catalog.addWord("Einhornstaub"))

        #expect(IngredientLineReader.isInForm("2 Einhornstaub", catalog: catalog.catalog))
        #expect(catalog.localTrace(for: "Einhornstaub")?.label == "lokal: eigenes Wort, ohne Werte")
        #expect(catalog.brand(for: "Einhornstaub") == nil)
        let result = try #require(await nutrition.nutrition(
            for: Recipe(title: "Curry", servings: 1, ingredientsText: "2 Einhornstaub")
        ))
        #expect(result.coverage.gaps.map(\.reason) == [.noNutritionValues])
    }

    @Test("A word of its own falls silent once the catalog knows the name")
    func ownWordIsAFallback() {
        let applied = LocalAnswerSet([LocalAnswer(name: "Margarine", kind: .word)])
            .applied(to: ProductTests.products.catalog)
        #expect(applied.trace(for: "Margarine")?.status == .silenced(by: "Margarine"))
        #expect(applied.addedNames.isEmpty)
    }
}
