import Foundation
import SwiftData
import Testing
@testable import SousKit

/// The precedence of a household's local answers (INGREDIENTS-DATA §3 B,
/// R2, R3), checked against a small hand-made catalog so every number can be
/// worked out by hand.
@Suite("Local answers")
struct LocalAnswerTests {
    private static func word(_ name: String, id: String, category: IngredientCategory? = nil, parent: String? = nil) -> CatalogIngredient {
        var ingredient = CatalogIngredient(name: name, category: category, parentName: parent)
        ingredient.catalogID = id
        return ingredient
    }

    /// The data set before a later release learned "Tempeh-Speck" and
    /// "Vegane Butter".
    private static func catalog(renames: CatalogRenames = .none, extra: [CatalogIngredient] = []) -> IngredientCatalog {
        IngredientCatalog(ingredients: extra + [
            word("Tofu", id: "tofu", category: .legumes),
            word("Tempeh", id: "tempeh", category: .legumes),
            word("Butter", id: "butter", category: .dairy),
            word("Mehl", id: "mehl", category: .baking),
        ], renames: renames)
    }

    private static func info(kcal: Double) -> NutritionInfo {
        var info = NutritionInfo.zero
        info.kcal = kcal
        return info
    }

    private static func nutrition(extra: [CatalogNutrition] = []) -> NutritionCatalog {
        NutritionCatalog(entries: extra + [
            CatalogNutrition(
                name: "Tofu", perHundredGrams: ["unspecified": info(kcal: 120)],
                unitWeightsGrams: ["Pck.": 200]
            ),
            CatalogNutrition(name: "Tempeh", perHundredGrams: ["unspecified": info(kcal: 190)]),
            CatalogNutrition(name: "Butter", perHundredGrams: ["unspecified": info(kcal: 740)]),
            CatalogNutrition(name: "Mehl", perHundredGrams: ["unspecified": info(kcal: 350)]),
        ])
    }

    private static func kcal(
        _ text: String, catalog: IngredientCatalog, nutrition: NutritionCatalog
    ) -> Double {
        let recipe = Recipe(title: "Test", servings: 1, ingredientsText: text)
        return NutritionAggregator.aggregate(
            recipe: recipe, servings: 1, catalog: catalog, nutritionCatalog: nutrition, resolve: { _ in nil }
        ).total.kcal
    }

    private static let smokedTofu = LocalAnswer(name: "Rauchtofu", kind: .countsAs, targetID: "tofu")

    // MARK: - "Zählt wie"

    @Test("A name counted as Tofu is read, weighed and computed as Tofu")
    func countsAsLendsRecognitionAndNumbers() {
        let applied = LocalAnswerSet([Self.smokedTofu]).applied(to: Self.catalog())
        let nutrition = applied.nutrition(over: Self.nutrition())

        #expect(applied.catalog.ingredient(writtenAs: "Rauchtofu") != nil)
        #expect(Self.kcal("200 g Rauchtofu", catalog: applied.catalog, nutrition: nutrition) == 240)
        // Tofu's piece weight came along: 1 Pck. = 200 g.
        #expect(Self.kcal("1 Pck. Rauchtofu", catalog: applied.catalog, nutrition: nutrition) == 240)
        #expect(applied.trace(for: "Rauchtofu")?.status == .applied)
        #expect(applied.trace(for: "Rauchtofu")?.label == "lokal: zählt wie Tofu")
    }

    @Test("A name counted as Tofu stays itself on the shopping list, under Tofu's aisle (R2)")
    func countsAsGivesNoShoppingIdentity() {
        let applied = LocalAnswerSet([Self.smokedTofu]).applied(to: Self.catalog())
        let recipe = Recipe(title: "Test", servings: 1, ingredientsText: "200 g Rauchtofu\n200 g Tofu")

        let capture = ShoppingListBuilder.build(
            from: [(recipe: recipe, servings: 1)], catalog: applied.catalog, resolve: { _ in nil }
        )

        let keys = Set(capture.demands.map(\.key))
        #expect(keys == ["rauchtofu", "tofu"])
        let smoked = capture.demands.first { $0.key == "rauchtofu" }
        #expect(smoked?.displayName == "Rauchtofu")
        #expect(smoked?.category == .legumes)
        // Not a variety of Tofu: Tofu's pantry flag and store do not reach it.
        #expect(applied.catalog.ancestors(of: "Rauchtofu").isEmpty)
        #expect(applied.catalog.groupIngredient(for: "Rauchtofu")?.name == "Rauchtofu")
    }

    @Test("A 'zählt wie' falls silent once the catalog knows the name, and says so (R3)")
    func countsAsFallsSilentWithATrace() {
        let answer = LocalAnswer(name: "Tempeh-Speck", kind: .countsAs, targetID: "tempeh")
        let before = LocalAnswerSet([answer]).applied(to: Self.catalog())
        let beforeNutrition = before.nutrition(over: Self.nutrition())
        #expect(Self.kcal("100 g Tempeh-Speck", catalog: before.catalog, nutrition: beforeNutrition) == 190)

        // A later release learns the word, with its own numbers.
        let release = Self.catalog(extra: [Self.word("Tempeh-Speck", id: "tempeh-speck", category: .legumes)])
        let releaseNutrition = Self.nutrition(extra: [
            CatalogNutrition(name: "Tempeh-Speck", perHundredGrams: ["unspecified": Self.info(kcal: 260)]),
        ])
        let after = LocalAnswerSet([answer]).applied(to: release)
        let afterNutrition = after.nutrition(over: releaseNutrition)

        #expect(Self.kcal("100 g Tempeh-Speck", catalog: after.catalog, nutrition: afterNutrition) == 260)
        #expect(after.trace(for: "Tempeh-Speck")?.status == .silenced(by: "Tempeh-Speck"))
        #expect(after.trace(for: "Tempeh-Speck")?.label
            == "lokal: zählt wie Tempeh · jetzt vom Katalog beantwortet")
    }

    // MARK: - Products

    @Test("A brand choice survives the catalog learning the generic word")
    func productChoiceOverridesALaterCatalogWord() {
        // The household's brand of vegane Butter, as a local product.
        let brand = LocalAnswer(
            name: "vegane Butter", kind: .product,
            values: Self.info(kcal: 540), valuesSource: "Packung", brand: "Marke A"
        )
        let before = LocalAnswerSet([brand]).applied(to: Self.catalog())
        #expect(Self.kcal("100 g vegane Butter", catalog: before.catalog,
                          nutrition: before.nutrition(over: Self.nutrition())) == 540)

        // The release adds a generic "Vegane Butter" on a representative label.
        let release = Self.catalog(extra: [Self.word("Vegane Butter", id: "vegane-butter", category: .dairy)])
        let releaseNutrition = Self.nutrition(extra: [
            CatalogNutrition(name: "Vegane Butter", perHundredGrams: ["unspecified": Self.info(kcal: 700)]),
        ])
        let after = LocalAnswerSet([brand]).applied(to: release)

        #expect(Self.kcal("100 g vegane Butter", catalog: after.catalog,
                          nutrition: after.nutrition(over: releaseNutrition)) == 540)
        #expect(after.trace(for: "vegane Butter")?.status == .applied)
        // Still the catalog's word on the list.
        #expect(after.catalog.ingredient(for: "vegane Butter")?.catalogID == "vegane-butter")
    }

    // MARK: - Field by field

    @Test("Own values replace the basis; an own weight replaces only its unit")
    func ownValuesAndWeightsWinFieldByField() {
        let answer = LocalAnswer(
            catalogID: "tofu", name: "Tofu",
            values: Self.info(kcal: 150), valuesSource: "Packung, Marke X",
            weights: ["Stk.": LocalAnswer.Weight(grams: 180)]
        )
        let applied = LocalAnswerSet([answer]).applied(to: Self.catalog())
        let nutrition = applied.nutrition(over: Self.nutrition())
        let entry = nutrition.nutrition(forCanonicalName: "Tofu")

        #expect(entry?.basis(for: .unspecified)?.values.kcal == 150)
        #expect(entry?.basis(for: .unspecified)?.source == "Packung, Marke X")
        #expect(entry?.unitWeightsGrams["Stk."] == 180)
        // The catalog's own package weight stays.
        #expect(entry?.unitWeightsGrams["Pck."] == 200)
        // Values about Tofu are not identity: no new word, no alias.
        #expect(applied.catalog.ingredients.count == Self.catalog().ingredients.count)
    }

    @Test("A weight with a state counts the line in that state")
    func ownWeightCarriesItsState() {
        let answer = LocalAnswer(
            catalogID: "tofu", name: "Tofu", weights: ["Dose": LocalAnswer.Weight(grams: 240, state: .cooked)]
        )
        let nutrition = LocalAnswerSet([answer]).applied(to: Self.catalog()).nutrition(over: Self.nutrition())

        #expect(nutrition.nutrition(forCanonicalName: "Tofu")?.unitStates["Dose"] == .cooked)
    }

    // MARK: - Ids

    @Test("A renamed target is followed on read")
    func renamedTargetResolvesOnRead() {
        let renames = CatalogRenames(renamed: ["sojaquark": "tofu"])
        let answer = LocalAnswer(name: "Rauchtofu", kind: .countsAs, targetID: "sojaquark")
        let applied = LocalAnswerSet([answer]).applied(to: Self.catalog(renames: renames))

        #expect(applied.trace(for: "Rauchtofu")?.targetName == "Tofu")
        #expect(Self.kcal("100 g Rauchtofu", catalog: applied.catalog,
                          nutrition: applied.nutrition(over: Self.nutrition())) == 120)
    }

    @Test("A target retired without a successor leaves the visible gap")
    func retiredTargetIsAGap() {
        let renames = CatalogRenames(retired: ["seitan"])
        let answer = LocalAnswer(name: "Seitanstreifen", kind: .countsAs, targetID: "seitan")
        let applied = LocalAnswerSet([answer]).applied(to: Self.catalog(renames: renames))

        #expect(applied.catalog.ingredient(writtenAs: "Seitanstreifen") == nil)
        #expect(applied.trace(for: "Seitanstreifen")?.status == .unresolvedTarget)
    }

    // MARK: - Twins and the fingerprint

    @Test("Two rows for one key: the newer one answers")
    func newerTwinWins() {
        let older = LocalAnswer(name: "Rauchtofu", kind: .countsAs, targetID: "tofu", updatedAt: Date(timeIntervalSince1970: 1))
        let newer = LocalAnswer(name: "rauchtofu", kind: .countsAs, targetID: "tempeh", updatedAt: Date(timeIntervalSince1970: 2))

        let set = LocalAnswerSet([newer, older])

        #expect(set.answers.count == 1)
        #expect(set.answers.first?.targetID == "tempeh")
    }

    @Test("The fingerprint follows what the answers say, not ids or times")
    func fingerprintFollowsContent() {
        let one = LocalAnswerSet([Self.smokedTofu])
        var twin = Self.smokedTofu
        twin.id = UUID()
        twin.updatedAt = Date(timeIntervalSince1970: 5)
        var other = Self.smokedTofu
        other.targetID = "tempeh"

        #expect(one.fingerprint == LocalAnswerSet([twin]).fingerprint)
        #expect(one.fingerprint != LocalAnswerSet([other]).fingerprint)
        #expect(LocalAnswerSet.empty.fingerprint != one.fingerprint)
    }
}

/// The answers inside the app's libraries: the store, the household
/// catalog, and the nutrition cache keyed by household and answers.
@MainActor
@Suite("Local answers in the libraries")
struct LocalAnswerLibraryTests {
    private func makeLibraries(
        answers: any LocalAnswerStore = InMemoryLocalAnswerStore(),
        household: @escaping @MainActor () -> UUID? = { nil }
    ) throws -> (NutritionLibrary, IngredientCatalogLibrary, SwiftDataRecipeNutritionStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let cache = SwiftDataRecipeNutritionStore(modelContainer: container)
        let catalog = IngredientCatalogLibrary(localAnswers: answers)
        let nutrition = NutritionLibrary(
            store: cache, recipeStore: SwiftDataRecipeStore(modelContainer: container),
            catalogLibrary: catalog, household: household
        )
        return (nutrition, catalog, cache)
    }

    private static let recipe = Recipe(title: "Brot", servings: 1, ingredientsText: "100 g Hafer-Drink-Pulver")

    private static func info(kcal: Double) -> NutritionInfo {
        var info = NutritionInfo.zero
        info.kcal = kcal
        return info
    }

    private static func brand(_ name: String, kcal: Double) -> LocalAnswer {
        LocalAnswer(name: "Hafer-Drink-Pulver", kind: .product, values: info(kcal: kcal), brand: name)
    }

    @Test("Two households, two brands: one recipe, two figures")
    func twoHouseholdsTwoBrands() async throws {
        let (first, _, _) = try makeLibraries(answers: InMemoryLocalAnswerStore([Self.brand("A", kcal: 400)]))
        let (second, _, _) = try makeLibraries(answers: InMemoryLocalAnswerStore([Self.brand("B", kcal: 380)]))

        let one = await first.nutrition(for: Self.recipe)
        let two = await second.nutrition(for: Self.recipe)

        #expect(one?.perPortion.kcal == 400)
        #expect(two?.perPortion.kcal == 380)
        #expect(first.cacheContext != second.cacheContext)
    }

    @Test("A household switch misses the cache and clears it")
    func householdSwitchEmptiesTheCache() async throws {
        let active = ActiveBox(id: UUID())
        let (nutrition, _, cache) = try makeLibraries(
            answers: InMemoryLocalAnswerStore([Self.brand("A", kcal: 400)]),
            household: { active.id }
        )
        _ = await nutrition.nutrition(for: Self.recipe)
        let firstContext = nutrition.cacheContext
        #expect(try await cache.nutrition(for: Self.recipe, servings: 1, context: firstContext) { _ in nil } != nil)

        active.id = UUID()
        #expect(nutrition.cacheContext != firstContext)
        #expect(try await cache.nutrition(for: Self.recipe, servings: 1, context: nutrition.cacheContext) { _ in nil } == nil)

        await nutrition.householdDidChange()
        #expect(try await cache.nutrition(for: Self.recipe, servings: 1, context: firstContext) { _ in nil } == nil)
    }

    @Test("An answer arriving later — written here or synced in — changes the key")
    func newAnswerChangesTheKey() async throws {
        let store = InMemoryLocalAnswerStore()
        let (nutrition, catalog, _) = try makeLibraries(answers: store)
        let before = await nutrition.nutrition(for: Self.recipe)
        #expect(before?.perPortion.kcal == 0)
        let beforeContext = nutrition.cacheContext

        // As a sync would: the row lands in the store, and the remote-change
        // pass reloads the catalog.
        await store.save(Self.brand("A", kcal: 400))
        await catalog.reload()

        let after = await nutrition.nutrition(for: Self.recipe)
        #expect(after?.perPortion.kcal == 400)
        #expect(nutrition.cacheContext != beforeContext)
    }

    @Test("Saving a 'zählt wie' writes the current id, keyed by the written name")
    func savingWritesCurrentIDs() async throws {
        let store = InMemoryLocalAnswerStore()
        let (_, catalog, _) = try makeLibraries(answers: store)
        await catalog.reload()
        let tofu = try #require(catalog.catalog.ingredient(for: "Tofu"))

        #expect(!catalog.catalogKnows("Rauchtofu"))
        #expect(await catalog.count("Rauchtofu", as: tofu))

        let saved = try #require(await store.answers().first)
        #expect(saved.key == "name:rauchtofu")
        #expect(saved.targetID == tofu.catalogID)
        #expect(catalog.catalog.ingredient(writtenAs: "Rauchtofu")?.name == "Rauchtofu")
        #expect(catalog.localTrace(for: "Rauchtofu")?.status == .applied)
        // The written name is known now only through the answer.
        #expect(!catalog.catalogKnows("Rauchtofu"))
    }

    @Test("Own values on a catalog word are keyed by its id")
    func ownValuesOnAKnownWordAreKeyedByID() async throws {
        let store = InMemoryLocalAnswerStore()
        let (_, catalog, _) = try makeLibraries(answers: store)
        await catalog.reload()

        #expect(await catalog.saveLocalAnswer(LocalAnswer(name: "Tofu", values: Self.info(kcal: 150))))

        #expect(try await store.answers().first?.key == "id:tofu")
    }
}

/// The household a test switches, as the switcher would.
@MainActor
private final class ActiveBox {
    var id: UUID?
    init(id: UUID?) { self.id = id }
}
