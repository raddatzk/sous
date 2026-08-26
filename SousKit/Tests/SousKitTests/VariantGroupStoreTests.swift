import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Variant groups in the store")
struct VariantGroupStoreTests {
    private func makeStore() throws -> SwiftDataRecipeStore {
        SwiftDataRecipeStore(modelContainer: try .sousContainer(inMemory: true))
    }

    /// A group with two members in it, the way `addVariant` leaves one.
    private func makePair(
        in store: SwiftDataRecipeStore
    ) async throws -> (group: VariantGroup, first: Recipe, second: Recipe) {
        let group = try await store.saveVariantGroup(VariantGroup(title: "Chili con Carne"))
        let first = Recipe(
            title: "Chili con Carne",
            ingredientsText: "400 g Hackfleisch",
            variantGroupID: group.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let second = Recipe(
            title: "Chili vegetarisch",
            ingredientsText: "400 g Linsen",
            variantGroupID: group.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        try await store.save(first)
        try await store.save(second)
        return (group, first, second)
    }

    @Test("A member remembers which group it is a version of")
    func membershipRoundTrips() async throws {
        let store = try makeStore()
        let (group, first, second) = try await makePair(in: store)

        let loaded = try #require(try await store.recipe(id: first.id))
        #expect(loaded.variantGroupID == group.id)

        let members = try await store.variantGroupMembers(id: group.id)
        // Creation order, which is the only order a symmetric group has.
        #expect(members.map(\.id) == [first.id, second.id])
    }

    @Test("The group's title is searchable through its members")
    func groupTitleIsSearchable() async throws {
        let store = try makeStore()
        let (_, _, second) = try await makePair(in: store)

        // "Chili vegetarisch" does not contain "con Carne" anywhere in its
        // own text — it is findable because the group's name was folded into
        // its search index.
        let found = try await store.recipes(matching: RecipeQuery(searchText: "con Carne"))
        #expect(found.map(\.id).contains(second.id))
    }

    @Test("Renaming a group rewrites what its members are found by")
    func renamingReindexes() async throws {
        let store = try makeStore()
        let (group, first, second) = try await makePair(in: store)

        var renamed = group
        renamed.title = "Eintopf"
        try await store.saveVariantGroup(renamed)

        // The vegetarian one was only ever findable under the old group name
        // because the index carried it; the original keeps matching because
        // that is its own title.
        let old = try await store.recipes(matching: RecipeQuery(searchText: "con Carne"))
        #expect(old.map(\.id) == [first.id])

        let new = try await store.recipes(matching: RecipeQuery(searchText: "eintopf"))
        #expect(Set(new.map(\.id)) == [first.id, second.id])
    }

    @Test("A group in the trash keeps its row, so restoring puts the pair back")
    func deletingDoesNotDissolve() async throws {
        let store = try makeStore()
        let (group, first, second) = try await makePair(in: store)

        try await store.delete(id: second.id)

        // One live member left: not a group any more as far as the list is
        // concerned — but nothing was written, so the survivor still knows
        // where it belongs.
        let counted = try #require(try await store.variantGroups().first { $0.group.id == group.id })
        #expect(counted.liveMembers == 1)
        #expect(try await store.recipe(id: first.id)?.variantGroupID == group.id)

        try await store.restore(id: second.id)
        let restored = try #require(try await store.variantGroups().first { $0.group.id == group.id })
        #expect(restored.liveMembers == 2)
    }

    @Test("Erasing the second-to-last member takes the group with it")
    func erasingCollects() async throws {
        let store = try makeStore()
        let (group, first, second) = try await makePair(in: store)

        try await store.delete(id: second.id)
        try await store.erase(id: second.id)

        // Now there is nothing left to stand beside, and nothing that could
        // come back from the trash either.
        #expect(try await store.variantGroup(id: group.id) == nil)
        #expect(try await store.recipe(id: first.id)?.variantGroupID == nil)
    }

    @Test("Dissolving leaves the members behind as ordinary recipes")
    func dissolving() async throws {
        let store = try makeStore()
        let (group, first, second) = try await makePair(in: store)

        try await store.dissolveVariantGroup(id: group.id)

        #expect(try await store.variantGroup(id: group.id) == nil)
        #expect(try await store.recipe(id: first.id)?.variantGroupID == nil)
        #expect(try await store.recipe(id: second.id)?.variantGroupID == nil)
        // The recipes themselves are untouched — a variant was never a
        // derivation, so there is nothing to fold back into anything.
        #expect(try await store.recipe(id: second.id)?.ingredientsText == "400 g Linsen")
        #expect(try await store.recipes(matching: RecipeQuery(searchText: "con Carne")).count == 1)
    }
}

@MainActor
@Suite("Variant groups in the library")
struct VariantGroupLibraryTests {
    private func makeLibrary() throws -> (RecipeLibrary, SwiftDataRecipeStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let store = SwiftDataRecipeStore(modelContainer: container)
        let images = SwiftDataRecipeImageStore(modelContainer: container)
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: container)
        let amountReview = SwiftDataRecipeAmountReviewStore(modelContainer: container)
        return (
            RecipeLibrary(
                store: store,
                imageStore: images,
                enrichmentStore: enrichment,
                amountReviewStore: amountReview
            ),
            store
        )
    }

    @Test("Adding a variant puts the original in the group too")
    func addingCreatesASymmetricGroup() async throws {
        let (library, _) = try makeLibrary()
        let original = Recipe(title: "Chili con Carne", ingredientsText: "400 g Hackfleisch")
        await library.save(original)

        let variant = try #require(
            await library.addVariant(
                of: original,
                title: "Chili vegetarisch",
                groupTitle: "Chili con Carne"
            )
        )

        let groupID = try #require(variant.variantGroupID)
        // Symmetric: the original joined the group rather than being the
        // base the variant hangs off.
        #expect(await library.recipe(id: original.id)?.variantGroupID == groupID)
        #expect(library.variantGroups[groupID]?.title == "Chili con Carne")
        #expect(library.entries == [
            .group(
                try #require(library.variantGroups[groupID]),
                members: [
                    try #require(await library.recipe(id: original.id)),
                    try #require(await library.recipe(id: variant.id)),
                ]
            ),
        ])
    }

    @Test("A second variant joins the group that already has a name")
    func secondVariantJoins() async throws {
        let (library, _) = try makeLibrary()
        let original = Recipe(title: "Chili con Carne")
        await library.save(original)

        let first = try #require(
            await library.addVariant(of: original, title: "Chili vegetarisch", groupTitle: "Chili")
        )
        // The sheet does not ask a second time, so nothing sensible is
        // passed here — and nothing sensible is what it has to survive.
        let second = try #require(
            await library.addVariant(of: first, title: "Chili schnell", groupTitle: "Ignoriert")
        )

        #expect(second.variantGroupID == first.variantGroupID)
        #expect(library.variantGroups.count == 1)
        #expect(library.variantGroups[first.variantGroupID!]?.title == "Chili")
    }

    @Test("A group down to one member draws as an ordinary recipe")
    func oneMemberIsNoGroup() async throws {
        let (library, _) = try makeLibrary()
        let original = Recipe(title: "Chili con Carne")
        await library.save(original)
        let variant = try #require(
            await library.addVariant(of: original, title: "Chili vegetarisch", groupTitle: "Chili")
        )

        await library.delete(variant)

        #expect(library.variantGroups.isEmpty)
        #expect(library.entries.count == 1)
        #expect(library.entries.first?.recipes.map(\.title) == ["Chili con Carne"])

        // Out of the trash, and the pair is a pair again — which is why
        // nothing cleared the survivor's field when its sibling went.
        await library.restore(variant)
        #expect(library.variantGroups.count == 1)
        #expect(library.entries.count == 1)
        #expect(library.entries.first?.recipes.count == 2)
    }

    @Test("Dissolving a group leaves two ordinary recipes")
    func dissolving() async throws {
        let (library, _) = try makeLibrary()
        let original = Recipe(title: "Chili con Carne")
        await library.save(original)
        let variant = try #require(
            await library.addVariant(of: original, title: "Chili vegetarisch", groupTitle: "Chili")
        )

        await library.dissolveVariantGroup(try #require(variant.variantGroupID))

        #expect(library.variantGroups.isEmpty)
        #expect(library.entries.count == 2)
        #expect(await library.recipe(id: variant.id)?.variantGroupID == nil)
    }

    @Test("An exported group comes back as a group")
    func exportRoundTrip() async throws {
        let (library, _) = try makeLibrary()
        let original = Recipe(title: "Chili con Carne")
        await library.save(original)
        let variant = try #require(
            await library.addVariant(of: original, title: "Chili vegetarisch", groupTitle: "Chili")
        )
        let archive = try #require(await library.exportedLibrary())

        let (fresh, _) = try makeLibrary()
        let summary = await fresh.importRecipes(from: archive, named: "Rezepte.sousrecipes")

        #expect(summary.imported == 2)
        #expect(fresh.variantGroups.count == 1)
        #expect(await fresh.recipe(id: variant.id)?.variantGroupID == variant.variantGroupID)
        #expect(fresh.variantGroups[variant.variantGroupID!]?.title == "Chili")
    }
}
