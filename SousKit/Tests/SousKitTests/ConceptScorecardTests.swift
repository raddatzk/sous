import Foundation
import SwiftData
import Testing
@testable import SousKit

/// The eleven test cases of `INGREDIENTS-CONCEPT.md` §9, played through the
/// real libraries against the shipped data — the permanent scorecard
/// `INGREDIENTS-MIGRATION.md` §6 asks for.
///
/// Every one of these cases is already covered somewhere: the basis in
/// `BasisStatusTests`, the states in `PreparationStateTests`, the grouped
/// line in `ShoppingLibraryTests`, and so on. What did not exist was a place
/// where the eleven are named *as the eleven*, so that "11 pass" is something
/// the suite says rather than something a person reconstructs by grepping —
/// and so that a case quietly falling out of a later refactor falls out
/// loudly.
///
/// That is also why these run against `IngredientCatalog.bundled` and
/// `BLSCatalog.bundled` rather than fixtures: a case that only passes against
/// a table written for it has not been played through. Where a case depends
/// on a specific curated row, it says so, so that a data change breaks it
/// with an explanation rather than with a number.
///
/// Since phase 6b the cases are played through the way the app answers them
/// now (INGREDIENTS-DATA §3 A–C): the catalog answers, nothing is proposed
/// or confirmed, and what the household adds is a local answer.
@MainActor
@Suite("The concept's eleven test cases")
struct ConceptScorecardTests {
    /// The whole app's data side, on one in-memory store: what the household
    /// answered, what the numbers rest on, and what has to be bought.
    private struct Stack {
        var catalog: IngredientCatalogLibrary
        var nutrition: NutritionLibrary
        var shopping: ShoppingLibrary
        var recipes: SwiftDataRecipeStore
    }

    private func stack() throws -> Stack {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let recipes = SwiftDataRecipeStore(modelContainer: container)
        let nutritionStore = SwiftDataRecipeNutritionStore(modelContainer: container)
        let catalog = IngredientCatalogLibrary()
        return Stack(
            catalog: catalog,
            nutrition: NutritionLibrary(
                store: nutritionStore, recipeStore: recipes, catalogLibrary: catalog
            ),
            shopping: ShoppingLibrary(
                store: SwiftDataShoppingListStore(modelContainer: container),
                recipeStore: recipes,
                catalogLibrary: catalog
            ),
            recipes: recipes
        )
    }

    private func recipe(_ title: String, _ lines: String, servings: Int = 2) -> Recipe {
        Recipe(title: title, servings: servings, ingredientsText: lines)
    }

    /// Values off a packet, as the local-answer form writes them.
    private func ownValues(_ name: String, kcal: Double) -> LocalAnswer {
        LocalAnswer(name: name, values: info(kcal: kcal), valuesSource: "Packung")
    }

    // MARK: - 1 · "200 g Schmelzkäse"

    /// *The line stands verbatim; the name carries the proposed marker with
    /// the best candidate from the synonym table; a tap shows all nine
    /// variants. List: "Schmelzkäse — 200 g"; catalog language never reaches
    /// the list. Nutrition: computed provisionally, visibly marked.*
    ///
    /// **Changed in phase 6b:** the catalog answers (INGREDIENTS-DATA §3 A).
    /// The synonym table's row is the basis, named in the drill-down; there
    /// is no proposed marker and no picker. Which row is right is the
    /// curator's question.
    @Test("200 g Schmelzkäse — counted, the basis named, catalog language off the list")
    func schmelzkäse() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        let recipe = self.recipe("Käsesuppe", "200 g Schmelzkäse")

        let computed = try #require(await stack.nutrition.nutrition(for: recipe))
        let line = try #require(computed.coverage.contributions.first)
        #expect(computed.perPortion.kcal > 0)
        #expect(computed.coverage.isComplete)
        // "beruht auf: Schmelzkäse, mind. 45 % Fett i. Tr."
        let basisName = try #require(line.basisName)
        #expect(basisName.localizedCaseInsensitiveContains("schmelzkäse"))

        // The list speaks the kitchen's language, never the catalog's.
        await stack.shopping.add(recipe)
        let item = try #require(stack.shopping.items.first)
        #expect(item.name == "Schmelzkäse")
        #expect(!item.name.contains("Fett i. Tr."))
        #expect(item.quantities == [Quantity(200, .gram)])
    }

    // MARK: - 2 · "500 g veganes Hackfleisch"

    /// *The ingredient enters the vocabulary like any other; the list carries
    /// it immediately (principle III). BLS search yields nothing usable — the
    /// mapping stays open, the sum reports the gap. The cook types the label
    /// values in, or confirms "deliberately without"; either ends the notice
    /// for good.*
    ///
    /// **Changed in phase 6b:** the label values are a local answer (§3 B).
    /// "Bewusst ohne" is the catalog's answer, not the cook's — see
    /// ``vanilleOhneWerte()``.
    @Test("500 g veganes Hackfleisch — on the list at once, a named gap until the packet answers")
    func veganesHackfleisch() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        let recipe = self.recipe("Bolognese", "500 g veganes Hackfleisch")

        // Principle III: the list never waits for the catalog to agree.
        await stack.shopping.add(recipe)
        #expect(stack.shopping.items.count == 1)
        #expect(stack.shopping.items[0].quantities == [Quantity(500, .gram)])

        let open = try #require(await stack.nutrition.nutrition(for: recipe))
        #expect(open.coverage.defects.count == 1)

        // The packet's numbers, as a local answer: they count from now on.
        #expect(await stack.catalog.saveLocalAnswer(ownValues("veganes Hackfleisch", kcal: 180)))
        let answered = try #require(await stack.nutrition.nutrition(for: recipe))
        #expect(answered.coverage.defects.isEmpty)
        #expect(answered.perPortion.kcal > 0)
    }

    /// The other half of the same case: "ohne Werte" is an answer, and an
    /// answer must not count as a defect. Vanille ships that way — no
    /// licensed source has the pod, and the catalog says so (CATALOG D).
    /// (Zimt was the example until Ciqual gave it a row.)
    @Test("1 Vanilleschote — the catalog's 'ohne Werte' is an answer, not a defect")
    func vanilleOhneWerte() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        let recipe = self.recipe("Milchreis", "1 Vanilleschote")

        let settled = try #require(await stack.nutrition.nutrition(for: recipe))
        #expect(settled.coverage.defects.isEmpty)
        #expect(settled.coverage.gaps.first?.reason == .deliberatelyWithout)
    }

    // MARK: - 3 · Twelve ingredients, three without values

    /// *Shown is the sum of the nine, never naked: "≈ 640 kcal per portion —
    /// 9 of 12 ingredients included", behind it the three missing ones with
    /// reason and jump-off to the fix.*
    @Test("Twelve ingredients, three without values — nine of twelve, and the three named")
    func nineOfTwelve() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        // Nine ordinary words, and three that no release will ever carry —
        // the case needs a gap that stays a gap, not one a data update might
        // close under the test.
        //
        // "Gouda" rather than "Käse" on purpose: the shipped table has no row
        // for the generic word, only for the specific cheeses, so "Käse" is a
        // recognized ingredient with no values — a tenth gap, and precisely
        // the kind phase 1 made visible. Right behaviour, wrong fixture.
        let recipe = self.recipe("Eintopf", """
        200 g Tomaten
        100 g Zwiebeln
        150 g Kartoffeln
        100 g Karotten
        200 g Reis
        100 g Linsen
        50 g Butter
        200 ml Milch
        100 g Gouda
        10 g Sternenstaub
        10 g Mondmilch
        10 g Drachenblut
        """)

        let computed = try #require(await stack.nutrition.nutrition(for: recipe))
        let coverage = computed.coverage

        #expect(coverage.accountableCount == 12)
        #expect(coverage.includedCount == 9)
        #expect(coverage.defects.count == 3)
        // "with reason": every gap names why — here, that the catalog does
        // not know the name.
        #expect(coverage.defects.allSatisfy { $0.reason == .noCatalogMatch })
        #expect(coverage.defects.map(\.ingredientName).sorted()
            == ["Drachenblut", "Mondmilch", "Sternenstaub"])
        // Never naked: the figure exists *and* says what it leaves out.
        #expect(computed.perPortion.kcal > 0)
    }

    // MARK: - 4 · Ajvar, cooked regularly

    /// *Confirm "Ajvar Konserve" as basis once — on the ingredient, not the
    /// line. From then on it holds in every recipe that writes "Ajvar". The
    /// display name stays "Ajvar"; the catalog name appears only as the fine
    /// print of the foundation.*
    ///
    /// **Changed in phase 6b:** nothing is confirmed; the catalog's basis
    /// holds for the ingredient in every recipe from the start.
    @Test("Ajvar — the catalog's basis, the same in every recipe, the kitchen's name shown")
    func ajvarSettledOnTheIngredient() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()

        let first = try #require(await stack.nutrition.nutrition(for: recipe("Dip", "50 g Ajvar")))
        let other = recipe("Ofengemüse", "100 g Ajvar\n200 g Zucchini")
        let computed = try #require(await stack.nutrition.nutrition(for: other))
        let line = try #require(
            computed.coverage.contributions.first { $0.ingredientName.localizedCaseInsensitiveContains("ajvar") }
        )
        #expect(line.basisCode != nil)
        #expect(line.basisCode == first.coverage.contributions.first?.basisCode)

        // The display name stays the kitchen's; the catalog's is fine print.
        #expect(line.ingredientName.localizedCaseInsensitiveContains("ajvar"))
        #expect(line.provenance() != nil)

        await stack.shopping.add(other)
        let item = try #require(stack.shopping.items.first { $0.key.contains("ajvar") })
        #expect(item.name.localizedCaseInsensitiveContains("ajvar"))
    }

    // MARK: - 5 · "Tomaten" + "Cocktailtomaten"

    /// *The app proposes the variant relation (name kinship), the cook
    /// confirms once. On the list: one grouped entry "Tomaten — 700 g" with
    /// sub-lines that keep the 200 g Cocktailtomaten distinguishable.*
    ///
    /// **The second half of that case was withdrawn.** The grouped entry is
    /// gone — see the catalog target, decision E — so there is no heading and
    /// no 700 g total. What the case was *for* survives whole and is what is
    /// checked here: the two tomatoes stay two things, and the 200 g of
    /// cocktail tomatoes never melt into an anonymous share of a larger
    /// number. The aisle sort puts them next to each other without a heading
    /// claiming they are one purchase.
    ///
    /// For *this* pair the cook is never asked, which is better than the case
    /// wanted: the relation is curated in the kitchen list, so it holds on a
    /// fresh install with nothing decided. The proposal mechanism the case
    /// describes is for a name the app does not ship, and that is exactly
    /// what case 10 plays through — see ``ochsenherztomaten()``.
    @Test("Tomaten + Cocktailtomaten — two errands, and the 200 g stay 200 g")
    func tomatenUndCocktailtomaten() async throws {
        let stack = try stack()
        await stack.catalog.reload()

        // Not an alias of Tomate — a word of its own that knows its parent.
        // Pinning it inside Tomate's spellings is what used to melt 200 g of
        // cocktail tomatoes into an anonymous 700 g, and the relation still
        // carries nutrition, the aisle and the shelf note.
        #expect(stack.catalog.catalog.canonicalName(for: "Cocktailtomaten") == "Cocktailtomate")
        #expect(stack.catalog.catalog.ingredient(for: "Cocktailtomate")?.parentName == "Tomate")

        await stack.shopping.add(recipe("Salat", "500 g Tomaten\n200 g Cocktailtomaten"))

        // Two rows, each its own errand and each tickable on its own.
        #expect(stack.shopping.items.count == 2)
        let variety = try #require(stack.shopping.items.first { $0.key.contains("cocktail") })
        #expect(variety.quantities == [Quantity(200, .gram)])
        let plain = try #require(stack.shopping.items.first { $0.key == "tomate" })
        #expect(plain.quantities == [Quantity(500, .gram)])

        // And they are found in the same place without being summed: the
        // aisle is what puts them together, not a heading.
        #expect(variety.category == plain.category)

        // The relation's other job. Cocktailtomate has no row of its own and
        // computes with Tomate's, naming where it came from (§3 A: an
        // inherited basis is simply the basis).
        await stack.nutrition.ensureLoaded()
        let inherited = try #require(stack.nutrition.nutrition(forName: "Cocktailtomaten")?.basis(for: .raw))
        #expect(inherited.status == .computed)
        #expect(inherited.inheritedFrom == "Tomate")
    }

    // MARK: - 6 · 500 g raw / 300 g cooked potatoes

    /// *Nutrition: two states, two bases — exactly what the BLS keeps
    /// separate rows for. List: one entry "Kartoffeln — 500 g + 300 g
    /// (weighed cooked)". No conversion, because the source knows no cooking
    /// yield.*
    @Test("500 g roh / 300 g gegart — two bases in the sum, one line on the list")
    func kartoffelnRohUndGegart() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        let recipe = self.recipe("Auflauf", "500 g Kartoffeln, roh\n300 g Kartoffeln, gegart")

        let computed = try #require(await stack.nutrition.nutrition(for: recipe))
        let lines = computed.coverage.contributions
        #expect(lines.count == 2)
        #expect(Set(lines.map(\.state)) == [.raw, .cooked])
        // Two states, two rows: the BLS keeps them apart because they *are*
        // apart, and a single blended entry was what phase 3 abolished.
        #expect(Set(lines.compactMap(\.basisCode)).count == 2)
        #expect(lines.allSatisfy { $0.matchesState })

        // One entry on the list, with the state said out loud and nothing
        // converted — nobody buys 300 g of cooked potatoes, and the source
        // knows no yield to invent one from.
        await stack.shopping.add(recipe)
        #expect(stack.shopping.items.count == 1)
        let item = try #require(stack.shopping.items.first)
        #expect(item.quantities == [Quantity(800, .gram)])
        let stated = try #require(item.statedQuantities.first { $0.state == .cooked })
        #expect(stated.quantities == [Quantity(300, .gram)])
        #expect(IngredientState.cooked.shoppingAnnotation == "gegart gewogen")
    }

    // MARK: - 7 · "1 Zehe Knoblauch"

    /// *Nutrition: measure table, 1 Zehe ≈ 3 g, labeled an assumption. List:
    /// "Knoblauch — 1 Zehe". Translation into purchase units is deliberately
    /// out of scope.*
    @Test("1 Zehe Knoblauch — three grams, and the app says it is an assumption")
    func eineZeheKnoblauch() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        let recipe = self.recipe("Aioli", "1 Zehe Knoblauch")

        let computed = try #require(await stack.nutrition.nutrition(for: recipe))
        let line = try #require(computed.coverage.contributions.first)
        // The curated `byIngredient` row, not the generic 5 g Zehe: garlic's
        // clove is smaller than the table's default one.
        #expect(line.grams == 3)
        #expect(line.isAssumedGrams)

        // The list keeps the measure the cook wrote. Turning cloves into
        // bulbs is out of scope by decision — the human at the shelf knows.
        await stack.shopping.add(recipe)
        let item = try #require(stack.shopping.items.first)
        #expect(item.quantities == [Quantity(1, .clove)])
    }

    // MARK: - 7b · "2 Knoblauchzehen"

    /// *A spelling may imply a unit (DATA §3 G): "Knoblauchzehe" is Knoblauch
    /// counted in Zehen. It replaces the piece and nothing else, so a written
    /// tablespoon stays a tablespoon. The list carries the cloves under
    /// Knoblauch, beside the ones written as Zehen.* A counted Knoblauch
    /// without the spelling is a bulb, which has no weight on record.
    @Test("2 Knoblauchzehen are two cloves, on the scale and on the list")
    func knoblauchzehenAreCloves() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        let recipe = self.recipe("Aioli", "2 Knoblauchzehen\n3 Zehen Knoblauch\n1 EL Knoblauchzehen")

        let computed = try #require(await stack.nutrition.nutrition(for: recipe))
        let lines = computed.coverage.contributions
        try #require(lines.count == 3)
        #expect(lines[0].quantity == Quantity(2, .clove))
        #expect(lines[0].grams == 6)
        #expect(lines[1].grams == 9)
        #expect(lines[2].quantity == Quantity(1, .tablespoon))

        await stack.shopping.add(recipe)
        let item = try #require(stack.shopping.items.first { $0.name == "Knoblauch" })
        #expect(item.quantities.contains(Quantity(5, .clove)))

        let bulbs = try #require(await stack.nutrition.nutrition(for: self.recipe("Knolle", "2 Knoblauch")))
        #expect(bulbs.coverage.gaps.map(\.reason) == [.noGramEquivalent])
    }

    // MARK: - 8 · "2 EL Olivenöl"

    /// *No density model, a table entry: "EL" for oils ≈ 10 g, so ≈ 20 g in
    /// the math, with ≈ and tappable.*
    ///
    /// **Deviation, decided in phase 5:** the app does model density, because
    /// a per-unit gram table cannot answer `ml` and `l` at all. Oil is
    /// 0.92 g/ml, so 2 EL = 30 ml ≈ 27.6 g rather than the concept's sketched
    /// 20 g. What the case is actually about survives intact and is what is
    /// asserted: the number is not water's, it is marked an assumption, and
    /// it is correctable. The concept's own words — "that oil is lighter than
    /// water lives in the entry, not in a formula" — are honoured by the
    /// density being curated data in `measures.json`.
    @Test("2 EL Olivenöl — lighter than water, and marked as an assumption")
    func zweiEsslöffelOlivenöl() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        let recipe = self.recipe("Dressing", "2 EL Olivenöl")

        let computed = try #require(await stack.nutrition.nutrition(for: recipe))
        let line = try #require(computed.coverage.contributions.first)
        let grams = try #require(line.grams)

        // The bug this case was written to catch: 2 EL counted as 30 g,
        // because the resolver fell back to the density of water.
        #expect(grams < 30)
        #expect(grams > 20)
        #expect(line.isAssumedGrams)

        // "tappable" — correctable per ingredient, which is what makes the
        // assumption an offer rather than a verdict.
        await stack.nutrition.setUnitWeight(11, unit: .tablespoon, forName: "Olivenöl")
        let corrected = try #require(await stack.nutrition.nutrition(for: recipe))
        #expect(corrected.coverage.contributions.first?.grams == 22)
    }

    // MARK: - 9 · "1 Prise Salz" · "Salz nach Geschmack"

    /// *Fully recognized, amount kind "unquantified": no coverage defect,
    /// shown in the detail as "not included", does not scale. On the list,
    /// salt — as a pantry ingredient — lands in the collapsed pantry
    /// check-through, not among the errands.*
    @Test("Prise Salz · Salz nach Geschmack — recognized, not counted, not a defect")
    func salzNachGeschmack() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()
        // In the fixed form "nach Geschmack" is the annotation after the comma.
        let recipe = self.recipe("Nudeln", "500 g Nudeln\nSalz, nach Geschmack")

        let computed = try #require(await stack.nutrition.nutrition(for: recipe))
        let gap = try #require(computed.coverage.gaps.first)
        #expect(gap.reason == .unquantified)
        // The whole point: a line that is fully understood and simply carries
        // no accountable amount is not a hole in the sum. There is nothing to
        // fix, so it must not ask.
        #expect(!gap.reason.countsAsDefect)
        #expect(computed.coverage.defects.isEmpty)
        #expect(computed.coverage.accountableCount == 1)

        // Does not scale: there is no number to multiply.
        await stack.shopping.add(recipe, servings: 8)
        let salt = try #require(stack.shopping.items.first { $0.key == "salz" })
        #expect(salt.quantities.isEmpty)

        // The pantry check-through, not the errands.
        await stack.shopping.setPantry(true, name: "Salz")
        #expect(stack.shopping.isPantry(salt))
        let sections = stack.shopping.bySection.map(\.section)
        #expect(sections.contains(.pantry))
        let pantry = try #require(stack.shopping.bySection.first { $0.section == .pantry })
        #expect(pantry.items.map(\.key) == ["salz"])
    }

    // MARK: - 10 · Ochsenherztomaten, fixed after checking off

    /// *Before the fix the line sat as a raw-text entry under "Unassigned" —
    /// it was never missing (principle II). The cook creates
    /// "Ochsenherztomaten" as a variant of "Tomaten"; the demand appears
    /// under the Tomaten entry. The check mark on the already-bought tomatoes
    /// stays untouched — the group shows: done, but something arrived later.*
    ///
    /// The grouped entry that last sentence names is withdrawn (decision E).
    /// **Changed in phase 6b:** the cook no longer creates a variety; a
    /// variety is the curator's. What the household does is a local answer —
    /// "zählt wie Tomate" — which gives the aisle and the numbers but never
    /// the identity (R2). The load-bearing half — a late fix never un-checks
    /// what was bought — is untouched and still asserted.
    @Test("Ochsenherztomaten — never missing, and answering for it does not un-check the tomatoes")
    func ochsenherztomaten() async throws {
        let stack = try stack()
        await stack.catalog.reload()
        await stack.shopping.add(recipe("Salat", "500 g Tomaten\n300 g Ochsenherztomaten"))

        // Principle II: the line the catalog did not recognize is on the list
        // from the first moment, under its own written name.
        let unknown = try #require(stack.shopping.items.first { $0.key.contains("ochsenherz") })
        #expect(unknown.quantities == [Quantity(300, .gram)])
        #expect(stack.shopping.items.count == 2)

        // The cook buys the tomatoes, and only then answers for the other
        // line.
        let tomatoes = try #require(stack.shopping.items.first { $0.key == "tomate" })
        await stack.shopping.toggle(tomatoes)

        let tomato = try #require(stack.catalog.catalog.ingredient(for: "Tomate"))
        #expect(await stack.catalog.count("Ochsenherztomaten", as: tomato))
        await stack.shopping.reload()

        // The answer carries the aisle and the numbers across, not the
        // identity: still two rows, the late one its own.
        #expect(stack.catalog.catalog.ingredient(for: "Ochsenherztomaten")?.parentName == nil)
        #expect(stack.shopping.items.count == 2)
        let computed = try #require(await stack.nutrition.nutrition(for: recipe("Salat", "300 g Ochsenherztomaten")))
        #expect(computed.coverage.defects.isEmpty)

        // "Done, but something arrived later": the check mark that was earned
        // stays earned, and the late line is open beside it.
        let bought = try #require(stack.shopping.items.first { $0.key == "tomate" })
        #expect(bought.isChecked)
        let late = try #require(stack.shopping.items.first { $0.key.contains("ochsenherz") })
        #expect(!late.isChecked)
    }

    // MARK: - 11 · Values added later, twenty recipes

    /// *A non-event. Sums are views (principle V); the twenty recipes show
    /// the new state on next open, and the coverage display improves
    /// everywhere by itself. There is no stored old value that could go
    /// stale.*
    @Test("Values added later — every recipe already written improves by itself")
    func valuesAddedLater() async throws {
        let stack = try stack()
        await stack.nutrition.ensureLoaded()

        // Twenty recipes is the point of the case: the fix is one write, not
        // twenty. Five is enough to prove the mechanism and keeps the suite
        // quick — the number that matters is "all of them", not "twenty".
        let recipes = (1...5).map {
            recipe("Gericht \($0)", "100 g Sternenstaub\n\($0 * 50) g Tomaten")
        }
        for recipe in recipes { try await stack.recipes.save(recipe) }

        for recipe in recipes {
            let before = try #require(await stack.nutrition.nutrition(for: recipe))
            #expect(before.coverage.defects.count == 1)
        }

        // One local answer, made once, on the name.
        await stack.catalog.saveLocalAnswer(ownValues("Sternenstaub", kcal: 120))

        for recipe in recipes {
            let after = try #require(await stack.nutrition.nutrition(for: recipe))
            // Not a stale cached figure: none of these texts changed, and the
            // cache's key carries the answers, so the old sum is missed.
            #expect(after.coverage.defects.isEmpty)
            #expect(after.coverage.includedCount == 2)
        }
    }
}
