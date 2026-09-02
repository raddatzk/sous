import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Nutrition library")
struct NutritionLibraryTests {
    private func makeLibrary() throws -> (NutritionLibrary, SwiftDataRecipeStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let recipes = SwiftDataRecipeStore(modelContainer: container)
        let nutrition = NutritionLibrary(
            store: SwiftDataRecipeNutritionStore(modelContainer: container),
            recipeStore: recipes,
            catalogLibrary: IngredientCatalogLibrary(
                store: SwiftDataVocabularyStore(modelContainer: container)
            )
        )
        return (nutrition, recipes)
    }

    /// One hand-entered entry, in the shape the ingredient form produces:
    /// one unspecified variant, everything not asked for left at zero.
    private func ownEntry(_ name: String, kcal: Double, gramsPerPiece: Double? = nil) -> CatalogNutrition {
        CatalogNutrition(
            name: name,
            perHundredGrams: [IngredientState.unspecified.rawValue: NutritionInfo(
                kcal: kcal, proteinG: 0, fatG: 0, saturatedFatG: 0,
                carbsG: 0, sugarG: 0, fiberG: 0, sodiumMg: 0,
                vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0, vitaminEMg: 0,
                calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
            )],
            unitWeightsGrams: gramsPerPiece.map { [IngredientUnit.piece.symbol: $0] } ?? [:],
            source: CatalogNutrition.ownSource
        )
    }

    @Test("A basis filed under one state is re-pointed without touching the others")
    func rePointingOneStateLeavesTheOthersAlone() async throws {
        let (nutrition, _) = try makeLibrary()
        await nutrition.ensureLoaded()

        // Kartoffel ships raw and cooked as separate rows. Confirm the cooked
        // one first, so there is a settled answer to change - the case the
        // form could not reach at all before the Grundlage row, because it
        // hid the picker for anything that already had values and wrote only
        // to unspecified when it did show.
        await nutrition.confirmBasis(code: "K110132", state: .cooked, forName: "Kartoffeln")
        #expect(nutrition.nutrition(forName: "Kartoffeln")?.basis(for: .cooked)?.code == "K110132")
        #expect(nutrition.nutrition(forName: "Kartoffeln")?.basis(for: .cooked)?.status == .confirmed)

        // Point cooked at a different row. Raw must not move.
        let rawBefore = nutrition.nutrition(forName: "Kartoffeln")?.basis(for: .raw)
        await nutrition.confirmBasis(code: "K110182", state: .cooked, forName: "Kartoffeln")

        let entry = try #require(nutrition.nutrition(forName: "Kartoffeln"))
        #expect(entry.basis(for: .cooked)?.code == "K110182")
        #expect(entry.basis(for: .raw)?.code == rawBefore?.code)
        #expect(entry.basis(for: .raw)?.status == rawBefore?.status)
    }

    @Test("Deliberately without for one state leaves another state's row standing")
    func optingOutIsPerState() async throws {
        let (nutrition, _) = try makeLibrary()
        await nutrition.ensureLoaded()

        await nutrition.confirmBasis(code: "K110100", state: .raw, forName: "Kartoffeln")
        await nutrition.setDeliberatelyWithoutBasis(forName: "Kartoffeln", state: .cooked)

        let entry = try #require(nutrition.nutrition(forName: "Kartoffeln"))
        #expect(entry.basis(for: .cooked)?.status == .deliberatelyWithout)
        #expect(entry.basis(for: .raw)?.code == "K110100")
        #expect(entry.basis(for: .raw)?.status == .confirmed)
    }

    @Test("A recipe with no ingredient the catalog recognizes comes back as zero, not a crash")
    func unknownIngredientsAreZeroNotFatal() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Fantasiegericht", servings: 2, ingredientsText: "1 Prise Sternenstaub")

        let result = await nutrition.nutrition(for: recipe)
        #expect(result?.perPortion.kcal == 0)
        #expect(result?.nrf93Score == 0)
    }

    @Test("Asking twice returns the same, cached value")
    func idempotent() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")

        let first = await nutrition.nutrition(for: recipe)
        let second = await nutrition.nutrition(for: recipe)
        #expect(first == second)
    }

    @Test("Editing the recipe's text is reflected the next time it is asked for")
    func editingInvalidatesTheCache() async throws {
        let (nutrition, recipes) = try makeLibrary()
        var recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")
        try await recipes.save(recipe)

        let before = await nutrition.nutrition(for: recipe)

        recipe.ingredientsText = "400 g Zucker"
        try await recipes.save(recipe)
        let after = await nutrition.nutrition(for: recipe)

        #expect(before?.perPortion.kcal != after?.perPortion.kcal)
    }

    @Test("Own nutrition fills a gap the bundled table has")
    func ownNutritionFillsAGap() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Bratlinge", servings: 2, ingredientsText: "200 g veganes Hackfleisch")
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 0)

        await nutrition.saveIngredientNutrition(ownEntry("veganes Hackfleisch", kcal: 150))

        // 200 g at 150 kcal/100 g, over two portions.
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 150)
    }

    @Test("Own nutrition overrides the bundled entry of the same name")
    func ownNutritionWins() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")
        let bundled = try #require(await nutrition.nutrition(for: recipe)?.perPortion.kcal)
        #expect(bundled > 0)

        await nutrition.saveIngredientNutrition(ownEntry("Zucker", kcal: 1))

        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 1)
        #expect(nutrition.ownNutrition(forCanonicalName: "zucker")?.source == CatalogNutrition.ownSource)
    }

    @Test("Taking own nutrition back restores the bundled figure")
    func deletingOwnNutritionRestoresBundled() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")
        let bundled = try #require(await nutrition.nutrition(for: recipe)?.perPortion.kcal)

        await nutrition.saveIngredientNutrition(ownEntry("Zucker", kcal: 1))
        await nutrition.deleteIngredientNutrition(name: "Zucker")

        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == bundled)
    }

    @Test("A hand-entered piece weight makes a counted line count")
    func ownPieceWeightResolves() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Bratlinge", servings: 1, ingredientsText: "2 Sojaküchlein")
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 0)

        await nutrition.saveIngredientNutrition(ownEntry("Sojaküchlein", kcal: 200, gramsPerPiece: 50))

        // Two pieces of 50 g, at 200 kcal/100 g.
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 200)
    }

    @Test("A correction to a spoon beats the shipped density, for that unit alone")
    func ownUnitWeightBeatsTheGenericValue() async throws {
        // The concept's "the cook can override any value on their
        // ingredient", past the single `Stk.` weight that used to be the only
        // one anybody could write. The storage was always a dictionary keyed
        // by unit — only the callers and the form were piece-only.
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Dressing", servings: 1, ingredientsText: "2 EL Olivenöl")

        let byDensity = try #require(await nutrition.nutrition(for: recipe))
        // 30 ml × 0.92 g/ml, against olive oil's ~900 kcal/100 g.
        #expect(byDensity.perPortion.kcal > 200)

        await nutrition.setUnitWeight(5, unit: .tablespoon, forName: "Olivenöl")
        let corrected = try #require(await nutrition.nutrition(for: recipe))

        // 10 g instead of 27.6 g — and the figure moved, which means the
        // cache noticed a write that never touched a recipe's text.
        #expect(corrected.perPortion.kcal < byDensity.perPortion.kcal / 2)
        #expect(nutrition.unitWeight(.tablespoon, forName: "Olivenöl") == 5)
        #expect(nutrition.hasOwnUnitWeight(.tablespoon, forName: "Olivenöl"))

        // …and only for the spoon: a millilitre still pours as oil pours.
        let byVolume = Recipe(title: "Marinade", servings: 1, ingredientsText: "100 ml Olivenöl")
        let volume = try #require(await nutrition.nutrition(for: byVolume))
        #expect(volume.perPortion.kcal > 700)
    }

    @Test("Taking a measure correction back leaves the shipped one standing")
    func clearingAUnitWeightRestoresTheShippedOne() async throws {
        let (nutrition, _) = try makeLibrary()
        await nutrition.ensureLoaded()
        let shipped = nutrition.unitWeight(.piece, forName: "Zwiebel")
        #expect(shipped == 110)

        await nutrition.setUnitWeight(200, unit: .piece, forName: "Zwiebel")
        #expect(nutrition.unitWeight(.piece, forName: "Zwiebel") == 200)

        await nutrition.setUnitWeight(nil, unit: .piece, forName: "Zwiebel")
        #expect(nutrition.unitWeight(.piece, forName: "Zwiebel") == 110)
        #expect(!nutrition.hasOwnUnitWeight(.piece, forName: "Zwiebel"))
    }

    @Test("Withdrawing own values leaves the measure the cook corrected")
    func deletingNutritionKeepsMeasures() async throws {
        // These used to go together, which made no sense in either
        // direction: what an onion weighs is not a claim about its calories.
        let (nutrition, _) = try makeLibrary()
        await nutrition.saveIngredientNutrition(ownEntry("Sojaküchlein", kcal: 200))
        await nutrition.setUnitWeight(50, unit: .piece, forName: "Sojaküchlein")

        await nutrition.deleteIngredientNutrition(name: "Sojaküchlein")

        #expect(nutrition.unitWeight(.piece, forName: "Sojaküchlein") == 50)
    }

    @Test("A shipped mapping counts, provisionally, until the cook confirms it")
    func confirmingSettlesTheFigure() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")

        let proposed = try #require(await nutrition.nutrition(for: recipe))
        // Decision A: the figure is there from the first look, and says of
        // itself that it rests on a guess.
        #expect(proposed.perPortion.kcal > 0)
        #expect(proposed.coverage.unconfirmedCount == 1)
        #expect(!proposed.coverage.isComplete)
        // Named as the recipe wrote it — the question belongs to the line
        // the cook is looking at, even though the answer holds for the word.
        #expect(proposed.coverage.openIngredientNames == ["Tomaten"])

        await nutrition.confirmProposedBasis(forName: "Tomate")

        let confirmed = try #require(await nutrition.nutrition(for: recipe))
        // Same number, and now a solid one — the badge's gate opens.
        #expect(confirmed.perPortion.kcal == proposed.perPortion.kcal)
        #expect(confirmed.coverage.unconfirmedCount == 0)
        #expect(confirmed.coverage.isComplete)
        #expect(confirmed.coverage.openIngredientNames.isEmpty)
    }

    @Test("Picking another row changes what the figure is based on")
    func pickingAnotherRow() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Toast", servings: 1, ingredientsText: "100 g Schmelzkäse")
        let before = try #require(await nutrition.nutrition(for: recipe))
        let candidates = nutrition.candidates(forName: "Schmelzkäse")
        // The eleven Schmelzkäse rows the source ships, not the one averaged
        // row the old pipeline made of them. The synonym table knows five of
        // them; the other six come from searching the catalog's own names,
        // which is what makes the picker usable for a word curation never
        // reached.
        #expect(candidates.count == 11)
        let other = try #require(candidates.first {
            $0.code != before.coverage.contributions.first?.basisCode
        })

        await nutrition.confirmBasis(code: other.code, forName: "Schmelzkäse")

        let after = try #require(await nutrition.nutrition(for: recipe))
        #expect(after.coverage.contributions.first?.basisCode == other.code)
        #expect(after.coverage.contributions.first?.isProvisional == false)
        #expect(after.coverage.isComplete)
    }

    @Test("Naming the row a cook's own numbers stand in for keeps the numbers")
    func linkingARowAfterTypingValuesKeepsThem() async throws {
        // The two directions used to disagree. Typing values *after* picking
        // a row carried the code across; picking a row *after* typing values
        // built a fresh assignment with no values and replaced the whole
        // slot, so the numbers went silently. Whichever way round the cook
        // does it, they end up with both.
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Toast", servings: 1, ingredientsText: "100 g Schmelzkäse")
        await nutrition.saveIngredientNutrition(ownEntry("Schmelzkäse", kcal: 111))
        let row = try #require(nutrition.candidates(forName: "Schmelzkäse").first)

        await nutrition.confirmBasis(code: row.code, forName: "Schmelzkäse")

        let after = try #require(await nutrition.nutrition(for: recipe))
        // The cook's number, not the row's — the row is the note beside it.
        #expect(after.perPortion.kcal == 111)
        #expect(after.coverage.contributions.first?.basisCode == row.code)
        #expect(nutrition.ownNutrition(forCanonicalName: "Schmelzkäse") != nil)
    }

    @Test("Deliberately without stops the asking for good")
    func deliberatelyWithoutIsRemembered() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Bratlinge", servings: 2, ingredientsText: "200 g veganes Hackfleisch")
        let asking = try #require(await nutrition.nutrition(for: recipe))
        #expect(asking.coverage.defects.count == 1)

        await nutrition.setDeliberatelyWithoutBasis(forName: "veganes Hackfleisch")

        let settled = try #require(await nutrition.nutrition(for: recipe))
        #expect(settled.coverage.gaps.first?.reason == .deliberatelyWithout)
        #expect(settled.coverage.defects.isEmpty)
        #expect(settled.coverage.openIngredientNames.isEmpty)
        // Not a badge, though: nothing contributed, so there is no sum to
        // pass a verdict on.
        #expect(!settled.coverage.isComplete)
    }

    @Test("Confirming an ingredient confirms its varieties with it")
    func varietiesInheritTheConfirmation() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Pastasalat", servings: 2, ingredientsText: "200 g Cocktailtomaten")

        let proposed = try #require(await nutrition.nutrition(for: recipe))
        #expect(proposed.coverage.unconfirmedCount == 1)

        // The mapping is attached per ingredient so the work amortizes — and
        // a variety with nothing of its own is that ingredient.
        await nutrition.confirmProposedBasis(forName: "Tomate")

        let confirmed = try #require(await nutrition.nutrition(for: recipe))
        #expect(confirmed.coverage.unconfirmedCount == 0)
        #expect(confirmed.coverage.isComplete)
    }

    @Test("An invalid serving count is refused rather than dividing by zero")
    func invalidServingsIsNil() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "200 g Zucker")

        let result = await nutrition.nutrition(for: recipe, servings: 0)
        #expect(result == nil)
    }
}
