import CoreData
import Foundation
import Testing
@testable import SousKit

/// A household's overrides of the catalog (phase 7d): aisle, parent,
/// spellings and display name — regional names, Brötchen / Semmel /
/// Weckerl. Local wins; a catalog that moves later is asked about quietly,
/// one that comes to agree folds the override away. Checked against a small
/// hand-made catalog, so every reading can be worked out by hand.
@Suite("Catalog overrides")
struct CatalogOverrideTests {
    private static func word(
        _ name: String, id: String, aliases: [String] = [], category: IngredientCategory? = nil, parent: String? = nil
    ) -> CatalogIngredient {
        var ingredient = CatalogIngredient(name: name, aliases: aliases, category: category, parentName: parent)
        ingredient.catalogID = id
        return ingredient
    }

    /// The data set as the household first saw it; `extra` entries win their
    /// names, which is how a later release is played.
    private static func catalog(extra: [CatalogIngredient] = []) -> IngredientCatalog {
        IngredientCatalog(ingredients: extra + [
            word("Brötchen", id: "broetchen", aliases: ["Semmel", "Semmeln"], category: .bakery),
            word("Weizenbrötchen", id: "weizenbroetchen", parent: "Brötchen"),
            word("Brot", id: "brot", category: .bakery),
            word("Eierkuchen", id: "eierkuchen", aliases: ["Pfannkuchen"], category: .baking),
            word("Berliner", id: "berliner", category: .bakery),
            word("Kokosmilch", id: "kokosmilch", category: .canned),
            word("Tempeh", id: "tempeh", category: .legumes),
        ])
    }

    private static func info(kcal: Double) -> NutritionInfo {
        var info = NutritionInfo.zero
        info.kcal = kcal
        return info
    }

    private static let nutrition = NutritionCatalog(entries: [
        CatalogNutrition(name: "Brötchen", perHundredGrams: ["unspecified": info(kcal: 270)]),
        CatalogNutrition(name: "Weizenbrötchen", bases: [:], parentName: "Brötchen"),
        CatalogNutrition(name: "Brot", perHundredGrams: ["unspecified": info(kcal: 230)]),
        CatalogNutrition(name: "Eierkuchen", perHundredGrams: ["unspecified": info(kcal: 220)]),
        CatalogNutrition(name: "Berliner", perHundredGrams: ["unspecified": info(kcal: 350)]),
        CatalogNutrition(name: "Kokosmilch", perHundredGrams: ["unspecified": info(kcal: 180)]),
        CatalogNutrition(name: "Tempeh", perHundredGrams: ["unspecified": info(kcal: 190)]),
    ])

    private static func kcal(_ text: String, _ applied: LocalAnswerSet.Applied) -> Double {
        let recipe = Recipe(title: "Test", servings: 1, ingredientsText: text)
        return NutritionAggregator.aggregate(
            recipe: recipe, servings: 1, catalog: applied.catalog,
            nutritionCatalog: applied.nutrition(over: nutrition), resolve: { _ in nil }
        ).total.kcal
    }

    private static func shoppingKeys(_ text: String, _ applied: LocalAnswerSet.Applied) -> [String] {
        let recipe = Recipe(title: "Test", servings: 1, ingredientsText: text)
        return ShoppingListBuilder.build(
            from: recipe, servings: 1, selecting: nil, catalog: applied.catalog, resolve: { _ in nil }
        ).demands.map(\.key)
    }

    // MARK: - Regional names

    @Test("A spelling the catalog lacks is identity: same word, same shopping row")
    func localSpellingIsIdentity() {
        let answer = LocalAnswer(catalogID: "broetchen", name: "Brötchen", spellings: ["Weckerl"])
        let applied = LocalAnswerSet([answer]).applied(to: Self.catalog())

        #expect(applied.catalog.ingredient(for: "Weckerl")?.name == "Brötchen")
        #expect(applied.catalog.ingredient(for: "Weckerln")?.name == "Brötchen")
        #expect(Set(Self.shoppingKeys("2 Weckerln\n2 Brötchen", applied)) == ["brötchen"])
        #expect(Self.kcal("100 g Weckerl", applied) == 270)
        #expect(applied.conflicts.isEmpty)
        #expect(applied.trace(for: "Weckerl")?.label == "lokal: eigene Schreibweisen")
    }

    @Test("A display name is what the word is shown as, never what it is")
    func displayNameChangesNoIdentity() {
        let answer = LocalAnswer(catalogID: "broetchen", name: "Brötchen", displayName: "Semmel")
        let applied = LocalAnswerSet([answer]).applied(to: Self.catalog())

        let word = applied.catalog.ingredient(for: "Brötchen")
        #expect(word?.shownName == "Semmel")
        #expect(word?.name == "Brötchen")
        #expect(word?.key == "brötchen")
        #expect(Self.shoppingKeys("2 Semmeln", applied) == ["brötchen"])
        // The suggestions show it, and complete a line with it.
        let suggestion = applied.catalog.suggestions(for: "Brö").first
        #expect(suggestion?.shownName == "Semmel")
        #expect(IngredientCompletion.completed(line: "2 Brö", with: try! #require(suggestion)) == "2 Semmel")

        // Only a spelling of the word may be its display name.
        let stray = LocalAnswer(catalogID: "broetchen", name: "Brötchen", displayName: "Weckle")
        #expect(LocalAnswerSet([stray]).applied(to: Self.catalog()).catalog.ingredient(for: "Brötchen")?.shownName == "Brötchen")
    }

    @Test("A claimed spelling reads as the household's word, and the other word lets go of it")
    func homonymIsClaimed() {
        // Confirmed once, when it was added: the catalog gave "Pfannkuchen"
        // to Eierkuchen then.
        let answer = LocalAnswer(
            catalogID: "berliner", name: "Berliner", spellings: ["Pfannkuchen"],
            baseline: CatalogBaseline(spellingOwners: ["pfannkuchen": "eierkuchen"])
        )
        let applied = LocalAnswerSet([answer]).applied(to: Self.catalog())

        #expect(applied.catalog.ingredient(for: "Pfannkuchen")?.name == "Berliner")
        #expect(applied.catalog.ingredient(for: "Eierkuchen")?.aliases.isEmpty == true)
        #expect(Self.kcal("100 g Pfannkuchen", applied) == 350)
        #expect(applied.conflicts.isEmpty)
    }

    // MARK: - Aisle and variety

    @Test("A local aisle wins, and a variety without one of its own follows it")
    func categoryOverride() {
        let answer = LocalAnswer(
            catalogID: "broetchen", name: "Brötchen", category: .frozen,
            baseline: CatalogBaseline(category: .bakery)
        )
        let applied = LocalAnswerSet([answer]).applied(to: Self.catalog())
        #expect(applied.catalog.category(for: "Brötchen") == .frozen)
        #expect(applied.catalog.category(for: "Weizenbrötchen") == .frozen)
        #expect(applied.conflicts.isEmpty)
    }

    @Test("A local variety is its own errand under its parent, and inherits like a shipped one")
    func localVariety() {
        let answers = [
            // A household word counted as Kokosmilch, filed as its variety.
            LocalAnswer(name: "dünne Kokosmilch", kind: .countsAs, targetID: "kokosmilch", parentID: "kokosmilch"),
            // A word of its own, without values: it inherits its parent's.
            LocalAnswer(name: "Kokosdrink", kind: .word, parentID: "kokosmilch"),
        ]
        let applied = LocalAnswerSet(answers).applied(to: Self.catalog())

        #expect(applied.catalog.ancestors(of: "dünne Kokosmilch").map(\.name) == ["Kokosmilch"])
        #expect(applied.catalog.variants(of: "Kokosmilch").map(\.name) == ["Kokosdrink", "dünne Kokosmilch"])
        // Its own row, like Cocktailtomate beside Tomate (decision E).
        #expect(Set(Self.shoppingKeys("200 ml dünne Kokosmilch\n200 ml Kokosmilch", applied))
            == ["dünne kokosmilch", "kokosmilch"])
        #expect(applied.catalog.category(for: "Kokosdrink") == .canned)
        #expect(Self.kcal("100 g Kokosdrink", applied) == 180)
    }

    @Test("A catalog variety moved under another parent inherits from the new one")
    func parentOverrideOnACatalogWord() {
        let answer = LocalAnswer(
            catalogID: "weizenbroetchen", name: "Weizenbrötchen", parentID: "brot",
            baseline: CatalogBaseline(parentID: "broetchen")
        )
        let applied = LocalAnswerSet([answer]).applied(to: Self.catalog())
        #expect(applied.catalog.ancestors(of: "Weizenbrötchen").map(\.name) == ["Brot"])
        #expect(Self.kcal("100 g Weizenbrötchen", applied) == 230)
        #expect(applied.conflicts.isEmpty)
    }

    // MARK: - When the catalog moves

    @Test("A catalog that moves an overridden place is asked about; local still wins")
    func laterChangeIsAConflict() {
        let answers = [
            LocalAnswer(
                catalogID: "broetchen", name: "Brötchen", category: .frozen, spellings: ["Weckerl"],
                displayName: "Semmel", baseline: CatalogBaseline(category: .bakery)
            ),
            LocalAnswer(
                catalogID: "weizenbroetchen", name: "Weizenbrötchen", parentID: "brot",
                baseline: CatalogBaseline(parentID: "broetchen")
            ),
        ]
        // The next release: Brötchen under Getreide, Weizenbrötchen under
        // Berliner, and "Weckerl" a spelling of Weizenbrötchen.
        let release = Self.catalog(extra: [
            Self.word("Brötchen", id: "broetchen", aliases: ["Semmel", "Semmeln"], category: .grains),
            Self.word("Weizenbrötchen", id: "weizenbroetchen", aliases: ["Weckerl"], parent: "Berliner"),
        ])
        let applied = LocalAnswerSet(answers).applied(to: release)

        #expect(Set(applied.conflicts.map(\.place)) == [.category, .parent, .spelling("Weckerl")])
        let category = try! #require(applied.conflicts.first { $0.place == .category })
        #expect(category.word == "Semmel")
        #expect(category.message
            == "Der Katalog sagt jetzt: Nudeln, Reis & Getreide · deine Angabe: Tiefkühl")
        #expect(category.catalogValue == "grains")
        let parent = try! #require(applied.conflicts.first { $0.place == .parent })
        #expect(parent.message == "Der Katalog sagt jetzt: Sorte von Berliner · deine Angabe: Sorte von Brot")
        let spelling = try! #require(applied.conflicts.first { $0.place == .spelling("Weckerl") })
        #expect(spelling.catalogSays == "„Weckerl“ ist Weizenbrötchen")
        #expect(spelling.catalogValue == "weizenbroetchen")

        // Local wins meanwhile, at every place.
        #expect(applied.catalog.category(for: "Brötchen") == .frozen)
        #expect(applied.catalog.ancestors(of: "Weizenbrötchen").map(\.name) == ["Brot"])
        #expect(applied.catalog.ingredient(for: "Weckerl")?.name == "Brötchen")
        #expect(applied.folded.isEmpty)
    }

    @Test("The catalog's value remembered by „Meine behalten“ is no conflict until it moves again")
    func keptOverrideStaysQuiet() {
        let release = Self.catalog(extra: [
            Self.word("Brötchen", id: "broetchen", aliases: ["Semmel"], category: .grains),
        ])
        let kept = LocalAnswer(
            catalogID: "broetchen", name: "Brötchen", category: .frozen, baseline: CatalogBaseline(category: .grains)
        )
        #expect(LocalAnswerSet([kept]).applied(to: release).conflicts.isEmpty)

        let again = Self.catalog(extra: [Self.word("Brötchen", id: "broetchen", category: .other)])
        #expect(LocalAnswerSet([kept]).applied(to: again).conflicts.map(\.place) == [.category])
    }

    @Test("A claimed spelling is never a later conflict — unless the catalog gives it to yet another word")
    func claimIsAskedOnce() {
        let answer = LocalAnswer(
            catalogID: "berliner", name: "Berliner", spellings: ["Pfannkuchen"],
            baseline: CatalogBaseline(spellingOwners: ["pfannkuchen": "eierkuchen"])
        )
        // A release that touches Eierkuchen but leaves it the spelling.
        let release = Self.catalog(extra: [
            Self.word("Eierkuchen", id: "eierkuchen", aliases: ["Pfannkuchen", "Crêpe"], category: .baking),
        ])
        #expect(LocalAnswerSet([answer]).applied(to: release).conflicts.isEmpty)
    }

    @Test("Where the catalog comes to agree, the override folds away without a question")
    func agreementFolds() {
        let answer = LocalAnswer(
            catalogID: "broetchen", name: "Brötchen", category: .frozen, spellings: ["Weckerl"],
            baseline: CatalogBaseline(category: .bakery)
        )
        let release = Self.catalog(extra: [
            Self.word("Brötchen", id: "broetchen", aliases: ["Semmel", "Weckerl"], category: .frozen),
        ])
        let applied = LocalAnswerSet([answer]).applied(to: release)
        #expect(applied.conflicts.isEmpty)
        #expect(Set(applied.folded.map(\.place)) == [.category, .spelling("Weckerl")])
    }

    @Test("Overrides outlive a 'zählt wie' the catalog silenced, and ask where it disagrees")
    func overridesOutliveASilencedFallback() {
        let answer = LocalAnswer(name: "Tempeh-Speck", kind: .countsAs, targetID: "tempeh", category: .meat)
        let before = LocalAnswerSet([answer]).applied(to: Self.catalog())
        #expect(before.catalog.category(for: "Tempeh-Speck") == .meat)
        #expect(before.conflicts.isEmpty)

        let release = Self.catalog(extra: [Self.word("Tempeh-Speck", id: "tempeh-speck", category: .legumes)])
        let after = LocalAnswerSet([answer]).applied(to: release)
        #expect(after.trace(for: "Tempeh-Speck")?.status == .silenced(by: "Tempeh-Speck"))
        #expect(after.catalog.category(for: "Tempeh-Speck") == .meat)
        #expect(after.conflicts.map(\.place) == [.category])
    }

    @Test("Spellings and parents reach the fingerprint; an answer without overrides keeps its digest")
    func fingerprint() {
        let plain = LocalAnswer(name: "Rauchtofu", kind: .countsAs, targetID: "tempeh")
        var spelled = plain
        spelled.spellings = ["Räuchertofu"]
        var varied = plain
        varied.parentID = "tempeh"
        var shown = plain
        shown.displayName = "Rauchtofu"
        let prints = [plain, spelled, varied].map { LocalAnswerSet([$0]).fingerprint }
        #expect(Set(prints).count == 3)
        // A display name changes no number.
        #expect(LocalAnswerSet([shown]).fingerprint == LocalAnswerSet([plain]).fingerprint)
    }

    // MARK: - Sharing

    @Test("Overrides go to the curator as proposals; claims and display names stay home")
    func sharingPayload() throws {
        let answers = [
            LocalAnswer(
                catalogID: "broetchen", name: "Brötchen", category: .frozen, parentID: "brot",
                spellings: ["Weckerl", "Pfannkuchen"], displayName: "Semmel",
                baseline: CatalogBaseline(category: .bakery, spellingOwners: ["pfannkuchen": "eierkuchen"])
            ),
            LocalAnswer(name: "dünne Kokosmilch", kind: .countsAs, targetID: "kokosmilch", parentID: "kokosmilch"),
        ]
        let offers = CatalogSharing.offers(LocalAnswerSet(answers), catalog: Self.catalog(), nutrition: Self.nutrition)
        let items = offers.map(\.item)

        #expect(items.map(\.name) == ["dünne Kokosmilch", "Weckerl", "Brötchen"])
        #expect(Set(offers.map(\.id)).count == 3)

        let household = items[0]
        #expect(household.kind == .countsAs)
        #expect(household.parent == CatalogSubmission.Item.Target(id: "kokosmilch", name: "Kokosmilch"))
        #expect(household.summary == "„dünne Kokosmilch“ zählt wie Kokosmilch · Sorte von Kokosmilch")

        let spelling = items[1]
        #expect(spelling.kind == .countsAs)
        #expect(spelling.spelling == true)
        #expect(spelling.target == CatalogSubmission.Item.Target(id: "broetchen", name: "Brötchen"))
        #expect(spelling.summary == "„Weckerl“ Schreibweise von Brötchen")

        let placement = items[2]
        #expect(placement.kind == .catalogOverride)
        #expect(placement.catalogID == "broetchen")
        #expect(placement.category == .frozen)
        #expect(placement.parent?.id == "brot")
        #expect(placement.detail == "eigene Einordnung · Kategorie Tiefkühl · Sorte von Brot")
        #expect(CatalogSharing.Group(placement.kind) == .placement)

        // The wire format inbox.py reads.
        let json = CatalogSubmission(items: items, app: "1.0 (1)", dataVersion: 2026100400).itemsJSON
        #expect(json.contains("\"kind\":\"override\""))
        #expect(json.contains("\"spelling\":true"))
        #expect(json.contains("\"category\":\"frozen\""))
        #expect(!json.contains("Semmel"))
        #expect(!json.contains("Pfannkuchen"))
    }

    @Test("An override the catalog already holds is not offered")
    func agreedOverrideIsNotOffered() {
        let answer = LocalAnswer(
            catalogID: "weizenbroetchen", name: "Weizenbrötchen", category: .bakery, parentID: "broetchen",
            spellings: ["Semmel"]
        )
        #expect(CatalogSharing.offers(LocalAnswerSet([answer]), catalog: Self.catalog(), nutrition: Self.nutrition)
            .isEmpty)
    }
}

/// The overrides as the household writes them: the library's edit mode,
/// the conflict actions, folding, and the stores.
@MainActor
@Suite("Catalog overrides in the household")
struct CatalogOverrideLibraryTests {
    @Test("Display name and spelling reach the catalog, the shopping list and the search index",
          arguments: StoreBackend.allCases)
    func editModeWritesOverrides(_ backend: StoreBackend) async throws {
        let stores = try backend.makeStores()
        let catalog = IngredientCatalogLibrary(localAnswers: stores.localAnswers, household: stores.household)
        let shopping = ShoppingLibrary(store: stores.shopping, recipeStore: stores.recipes, catalogLibrary: catalog)
        await catalog.reload()
        var reindexed = 0
        catalog.wordsDidChange = { reindexed += 1 }

        let broetchen = try #require(catalog.catalog.ingredient(for: "Brötchen"))
        #expect(catalog.checkSpelling("Semmel", for: broetchen) == .alreadyKnown)
        #expect(catalog.checkSpelling("Weckerl", for: broetchen) == .new)

        #expect(await catalog.saveOverrides(
            of: broetchen, category: .frozen, parentID: nil, spellings: ["Weckerl"], displayName: "Semmel"
        ))
        #expect(reindexed == 1)
        let answer = try #require(catalog.overrideAnswer(of: broetchen))
        #expect(answer.key == "id:broetchen")
        // What the catalog said when the household decided.
        #expect(answer.baseline == CatalogBaseline(category: .bakery))
        #expect(catalog.catalog.ingredient(for: "Weckerl")?.shownName == "Semmel")
        #expect(catalog.catalog.category(for: "Weckerl") == .frozen)
        #expect(catalog.catalogConflicts.isEmpty)

        await shopping.add(Recipe(title: "Frühstück", servings: 2, ingredientsText: "4 Weckerln\n2 Brötchen"))
        let item = try #require(shopping.items.first)
        #expect(shopping.items.count == 1)
        #expect(item.name == "Brötchen")
        #expect(shopping.shownName(of: item) == "Semmel")
        #expect(shopping.bySection.map(\.section) == [.aisle(.frozen)])

        // The catalog's own value is no override, and a field taken back
        // leaves nothing behind.
        #expect(await catalog.saveOverrides(
            of: broetchen, category: .bakery, parentID: nil, spellings: [], displayName: nil
        ))
        #expect(catalog.overrideAnswer(of: broetchen) == nil)
        #expect(try await stores.localAnswers.answers().isEmpty)
        // The row already on the list follows the aisle back.
        #expect(shopping.bySection.map(\.section) == [.aisle(.bakery)])
    }

    @Test("A spelling of another word is claimed with that word named; a name is taken",
          arguments: StoreBackend.allCases)
    func claimingIsNamed(_ backend: StoreBackend) async throws {
        let catalog = try backend.makeCatalogLibrary()
        await catalog.reload()
        let tofu = try #require(catalog.catalog.ingredient(for: "Tofu"))
        #expect(catalog.checkSpelling("Semmel", for: tofu) == .claims("Brötchen"))
        #expect(catalog.checkSpelling("Brötchen", for: tofu) == .taken("Brötchen"))

        await catalog.saveOverrides(of: tofu, category: nil, parentID: nil, spellings: ["Semmel"], displayName: nil)
        let answer = try #require(catalog.overrideAnswer(of: tofu))
        #expect(answer.baseline?.spellingOwners == ["semmel": "broetchen"])
        #expect(catalog.catalog.ingredient(for: "Semmel")?.name == "Tofu")
        #expect(catalog.catalogConflicts.isEmpty)
    }

    @Test("„Meine behalten“ remembers the catalog's value; „Katalog übernehmen“ drops the override",
          arguments: StoreBackend.allCases)
    func conflictActions(_ backend: StoreBackend) async throws {
        let stores = try backend.makeStores()
        // Written against a catalog that filed Brötchen under Getreide; the
        // data set now says Backwaren.
        try await stores.localAnswers.save(LocalAnswer(
            catalogID: "broetchen", name: "Brötchen", category: .frozen, spellings: ["Weckerl"],
            baseline: CatalogBaseline(category: .grains)
        ))
        let catalog = IngredientCatalogLibrary(localAnswers: stores.localAnswers, household: stores.household)
        await catalog.reload()
        let broetchen = try #require(catalog.catalog.ingredient(for: "Brötchen"))
        let conflict = try #require(catalog.conflicts(of: broetchen).first)
        #expect(conflict.place == .category)
        #expect(conflict.message == "Der Katalog sagt jetzt: Brot & Backwaren · deine Angabe: Tiefkühl")

        #expect(await catalog.keepLocal(conflict))
        #expect(catalog.catalogConflicts.isEmpty)
        #expect(catalog.overrideAnswer(of: broetchen)?.baseline?.category == .bakery)
        #expect(catalog.catalog.category(for: "Brötchen") == .frozen)

        // Played again from the conflict, the other way.
        try await stores.localAnswers.save(LocalAnswer(
            catalogID: "broetchen", name: "Brötchen", category: .frozen, spellings: ["Weckerl"],
            baseline: CatalogBaseline(category: .grains)
        ))
        await catalog.reload()
        let again = try #require(catalog.catalogConflicts.first)
        #expect(await catalog.adoptCatalog(again))
        #expect(catalog.catalogConflicts.isEmpty)
        #expect(catalog.catalog.category(for: "Brötchen") == .bakery)
        // The spelling was not part of the conflict and stays.
        #expect(catalog.overrideAnswer(of: broetchen)?.spellings == ["Weckerl"])
    }

    @Test("An override the catalog has come to agree with is folded away on load",
          arguments: StoreBackend.allCases)
    func agreementFoldsOnLoad(_ backend: StoreBackend) async throws {
        let stores = try backend.makeStores()
        try await stores.localAnswers.save(LocalAnswer(
            catalogID: "broetchen", name: "Brötchen", category: .bakery, spellings: ["Semmel"],
            baseline: CatalogBaseline(category: .grains)
        ))
        try await stores.localAnswers.save(LocalAnswer(
            catalogID: "tofu", name: "Tofu", weights: ["Pck.": LocalAnswer.Weight(grams: 175)], category: .bakery,
            baseline: CatalogBaseline(category: .plantBased)
        ))
        let catalog = IngredientCatalogLibrary(localAnswers: stores.localAnswers, household: stores.household)
        await catalog.reload()

        #expect(catalog.catalogConflicts.isEmpty)
        let left = try await stores.localAnswers.answers()
        // Brötchen's answer said only what the catalog says now: gone.
        // Tofu's override stands, beside its weight.
        #expect(left.map(\.key) == ["id:tofu"])
        #expect(left.first?.category == .bakery)
    }

    @Test("A local variety shares its parent's pantry flag and store, as its own row",
          arguments: StoreBackend.allCases)
    func localVarietyOnTheShoppingList(_ backend: StoreBackend) async throws {
        let stores = try backend.makeStores()
        let catalog = IngredientCatalogLibrary(localAnswers: stores.localAnswers, household: stores.household)
        let shopping = ShoppingLibrary(store: stores.shopping, recipeStore: stores.recipes, catalogLibrary: catalog)
        await catalog.reload()
        let kokosmilch = try #require(catalog.catalog.ingredient(for: "Kokosmilch"))
        #expect(await catalog.count("halbfette Kokosmilch", as: kokosmilch))
        let thin = try #require(catalog.catalog.ingredient(for: "halbfette Kokosmilch"))
        #expect(await catalog.saveOverrides(
            of: thin, category: nil, parentID: kokosmilch.catalogID, spellings: [], displayName: nil
        ))
        let answer = try #require(catalog.overrideAnswer(of: thin))
        #expect(answer.kind == .countsAs)
        #expect(answer.parentID == "kokosmilch")
        #expect(answer.baseline == nil)

        await shopping.add(Recipe(title: "Curry", servings: 2, ingredientsText: "200 ml halbfette Kokosmilch\n200 ml Kokosmilch"))
        #expect(Set(shopping.items.map(\.name)) == ["halbfette Kokosmilch", "Kokosmilch"])
        await catalog.setShoppingPreferences(store: "Asia-Markt", note: nil, name: "Kokosmilch")
        let item = try #require(shopping.items.first { $0.name == "halbfette Kokosmilch" })
        #expect(shopping.preferredStore(of: item) == "Asia-Markt")
    }
}

/// The override attributes in Core Data, and the step that added them.
@Suite("Catalog override store")
struct CatalogOverrideStoreTests {
    @Test("Every override field survives the round trip")
    func roundTrip() async throws {
        let store = CoreDataLocalAnswerStore(container: try SousPersistentContainer.make(inMemory: true))
        let answer = LocalAnswer(
            catalogID: "broetchen", name: "Brötchen", category: .frozen, parentID: "brot",
            spellings: ["Weckerl", "Pfannkuchen"], displayName: "Semmel",
            baseline: CatalogBaseline(category: .bakery, parentID: "", spellingOwners: ["pfannkuchen": "eierkuchen"])
        )
        try await store.save(answer)
        let read = try #require(try await store.answers().first)
        #expect(read.category == .frozen)
        #expect(read.parentID == "brot")
        #expect(read.spellings == ["Weckerl", "Pfannkuchen"])
        #expect(read.displayName == "Semmel")
        #expect(read.baseline == answer.baseline)
        #expect(!read.isEmpty)
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sous-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Sous.sqlite")
    }

    private func open(_ url: URL, with model: NSManagedObjectModel) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Sous", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in
            if loadError == nil { loadError = error }
        }
        if let loadError { throw loadError }
        return container
    }

    private func close(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    @Test("A store from before phase 7d opens, keeps its answers, and takes overrides")
    func storeBeforeOverridesMigrates() async throws {
        let url = try temporaryStoreURL()
        let old = SousManagedObjectModel.makeModel(includingRetiredEntities: false, includingCatalogOverrides: false)
        #expect(old.entitiesByName[SousManagedObjectModel.localAnswerEntityName]?
            .attributesByName["spellingsData"] == nil)

        let before = try open(url, with: old)
        let context = before.newBackgroundContext()
        try await context.perform {
            let row = NSEntityDescription.insertNewObject(
                forEntityName: SousManagedObjectModel.localAnswerEntityName, into: context
            )
            row.setValue(UUID(), forKey: "id")
            row.setValue("name:rauchtofu", forKey: "key")
            row.setValue("Rauchtofu", forKey: "name")
            row.setValue("countsAs", forKey: "kindRaw")
            row.setValue("tofu", forKey: "targetID")
            row.setValue(Date(), forKey: "createdAt")
            row.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
        try close(before)

        for _ in 0..<2 {
            let after = try open(url, with: SousManagedObjectModel.shared)
            let read = try await CoreDataLocalAnswerStore(container: after).answers()
            #expect(read.map(\.name) == ["Rauchtofu"])
            #expect(read.first?.spellings == [])
            #expect(read.first?.hasOverrides == false)
            try close(after)
        }

        let after = try open(url, with: SousManagedObjectModel.shared)
        let store = CoreDataLocalAnswerStore(container: after)
        var answer = try #require(try await store.answers().first)
        answer.parentID = "tofu"
        answer.spellings = ["Rauch-Tofu"]
        try await store.save(answer)
        #expect(try await store.answers().first?.spellings == ["Rauch-Tofu"])
        try close(after)
    }
}

@Suite("The plant-based aisle")
struct PlantBasedAisleTests {
    @Test("Tofu and Sojahack stand in their own aisle, between the dairy and the meat")
    func shelved() {
        let catalog = IngredientCatalog.bundled
        #expect(catalog.ingredient(for: "Tofu")?.category == .plantBased)
        #expect(catalog.ingredient(for: "Räuchertofu")?.category == .plantBased)
        #expect(catalog.ingredient(for: "Sojahack")?.category == .plantBased)
        #expect(IngredientCategory.plantBased.title == "Vegan & Fleischersatz")
        #expect(IngredientCategory.dairy.aisleOrder < IngredientCategory.plantBased.aisleOrder)
        #expect(IngredientCategory.plantBased.aisleOrder < IngredientCategory.meat.aisleOrder)
    }

    @Test("An aisle a newer data set brings reads as Sonstiges, not as a broken set")
    func unknownAisle() throws {
        let read = try JSONDecoder().decode([IngredientCategory].self, from: Data(#"["plantBased", "somethingNew"]"#.utf8))
        #expect(read == [.plantBased, .other])
    }
}
