import Foundation
import Testing
@testable import SousKit

@Suite("Variant grouping")
struct VariantGroupingTests {
    private let group = VariantGroup(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
        title: "Chili con Carne"
    )

    private func member(_ title: String, createdAt: TimeInterval) -> Recipe {
        Recipe(
            title: title,
            variantGroupID: group.id,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }

    @Test("A group takes the place its first member had")
    func groupKeepsTheSlot() {
        let bread = Recipe(title: "Brot")
        let chili = member("Chili con Carne", createdAt: 100)
        let vegetarian = member("Chili vegetarisch", createdAt: 200)
        let soup = Recipe(title: "Suppe")

        let entries = VariantGrouping.entries(
            for: [bread, chili, vegetarian, soup],
            groups: [group.id: group]
        )

        #expect(entries.count == 3)
        #expect(entries[0] == .recipe(bread))
        #expect(entries[1] == .group(group, members: [chili, vegetarian]))
        #expect(entries[2] == .recipe(soup))
    }

    @Test("Members read in creation order, whatever order the query gave them")
    func membersInCreationOrder() {
        let older = member("Chili con Carne", createdAt: 100)
        let newer = member("Chili vegetarisch", createdAt: 200)

        // What sorting by title hands over: the variant first.
        let entries = VariantGrouping.entries(for: [newer, older], groups: [group.id: group])

        #expect(entries == [.group(group, members: [older, newer])])
    }

    @Test("A filtered list draws the group around the one member that matched")
    func filteredGroupKeepsItsRow() {
        // Searching for "Linsen" hit one variant of five. The group's row is
        // context around that hit, not a reason to draw the other four —
        // which is why nothing here goes looking for the missing members.
        let hit = member("Chili vegetarisch", createdAt: 200)

        let entries = VariantGrouping.entries(for: [hit], groups: [group.id: group])

        #expect(entries == [.group(group, members: [hit])])
    }

    @Test("A recipe whose group is not a group stands on its own")
    func unknownGroupStandsAlone() {
        // Both cases at once: a group down to a single member, which the
        // library leaves out of its map, and a member outliving a group row
        // that is gone. Neither is damage — they read as ungrouped.
        let orphan = member("Chili con Carne", createdAt: 100)

        let entries = VariantGrouping.entries(for: [orphan], groups: [:])

        #expect(entries == [.recipe(orphan)])
    }
}

@Suite("Variant comparison")
struct VariantComparisonTests {
    private let groupID = UUID()

    private func variant(_ title: String, ingredients: String, servings: Int = 4) -> Recipe {
        Recipe(
            title: title,
            servings: servings,
            ingredientsText: ingredients,
            variantGroupID: groupID
        )
    }

    @Test("Only what the versions disagree about gets a row")
    func differencesOnly() {
        let meat = variant("Chili con Carne", ingredients: """
        400 g Hackfleisch
        1 Dose Kidneybohnen
        2 Zwiebeln
        """)
        let vegetarian = variant("Chili vegetarisch", ingredients: """
        400 g Linsen
        1 Dose Kidneybohnen
        2 Zwiebeln
        """)

        let comparison = VariantComparison.make(of: [meat, vegetarian])

        #expect(comparison.rows.map(\.title) == ["Hackfleisch", "Linsen"])
        // The beans and the onions are written the same way twice, so they
        // are counted and not listed.
        #expect(comparison.sharedCount == 2)
    }

    @Test("A missing line says which version is missing it")
    func missingLines() {
        let meat = variant("Chili con Carne", ingredients: "400 g Hackfleisch")
        let vegetarian = variant("Chili vegetarisch", ingredients: "400 g Linsen")

        let comparison = VariantComparison.make(of: [meat, vegetarian])
        let mince = try! #require(comparison.rows.first { $0.title == "Hackfleisch" })

        #expect(!mince.isMissing(from: meat))
        #expect(mince.isMissing(from: vegetarian))
        #expect(mince.ingredients[meat.id]?.quantity?.amount == 400)
    }

    @Test("The same ingredient in another amount is a difference too")
    func amountsDiffer() {
        let full = variant("Chili scharf", ingredients: "2 TL Chilipulver")
        let mild = variant("Chili mild", ingredients: "1 TL Chilipulver")

        let comparison = VariantComparison.make(of: [full, mild])

        #expect(comparison.rows.map(\.title) == ["Chilipulver"])
        #expect(comparison.sharedCount == 0)
        // Both write it; neither is missing it. What differs is the amount,
        // handed over as written rather than judged.
        let row = comparison.rows[0]
        #expect(!row.isMissing(from: full))
        #expect(row.ingredients[full.id]?.quantity?.amount == 2)
        #expect(row.ingredients[mild.id]?.quantity?.amount == 1)
    }

    @Test("Two spellings of one ingredient are not a difference")
    func spellingIsNotADifference() {
        // What the catalog is for: the shopping list already puts these on
        // one line, and the comparison uses the same judgment.
        let first = variant("Chili con Carne", ingredients: "2 Zwiebeln")
        let second = variant("Chili vegetarisch", ingredients: "2 Zwiebel")

        let comparison = VariantComparison.make(of: [first, second])

        #expect(comparison.rows.isEmpty)
        #expect(comparison.sharedCount == 1)
    }
}

@Suite("Variant copies")
struct VariantCopyTests {
    @Test("A variant is a full recipe, and starts without the original's pictures")
    func copyCarries() {
        let groupID = UUID()
        let original = Recipe(
            title: "Chili con Carne",
            summary: "Der Klassiker",
            servings: 4,
            ingredientsText: "400 g Hackfleisch",
            instructionsText: "Anbraten",
            categories: ["Hauptgericht"],
            isFavorite: true,
            wantToCook: true,
            notes: "Beim zweiten Mal weniger Salz",
            source: RecipeSource(kind: .web, url: URL(string: "https://example.com"), name: "Beispiel"),
            prepTimeSeconds: 600,
            totalTimeSeconds: 3600,
            imageIDs: [UUID()]
        )

        let variant = original.variantCopy(title: "Chili vegetarisch", in: groupID)

        #expect(variant.id != original.id)
        #expect(variant.title == "Chili vegetarisch")
        #expect(variant.variantGroupID == groupID)
        #expect(variant.ingredientsText == original.ingredientsText)
        #expect(variant.instructionsText == original.instructionsText)
        #expect(variant.categories == ["Hauptgericht"])
        #expect(variant.notes == original.notes)
        #expect(variant.source == original.source)
        #expect(variant.servings == 4)
        #expect(variant.prepTimeSeconds == 600)
        #expect(variant.totalTimeSeconds == 3600)
        // Pictures belong to the recipe they were taken for: copied ids would
        // name rows this recipe does not own, and render nothing.
        #expect(variant.imageIDs.isEmpty)
        // Neither mark is a fact about the dish. Nobody has cooked this one.
        #expect(!variant.isFavorite)
        #expect(!variant.wantToCook)
    }
}
