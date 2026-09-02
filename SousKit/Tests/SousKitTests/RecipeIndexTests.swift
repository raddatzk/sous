import Foundation
import Testing
@testable import SousKit

/// What a recipe can be found by, when what it names is a variety of a
/// variety.
@Suite("The search index and the variety chain")
struct RecipeIndexTests {
    private let catalog = IngredientCatalog(ingredients: [
        CatalogIngredient(name: "Pilz", aliases: ["Pilze"], category: .vegetables),
        CatalogIngredient(name: "Champignon", aliases: ["Champignons"], category: .vegetables, parentName: "Pilz"),
        CatalogIngredient(
            name: "Brauner Champignon", aliases: ["Braune Champignons"], category: .vegetables,
            parentName: "Champignon"
        ),
        CatalogIngredient(name: "Zwiebel", aliases: ["Zwiebeln"], category: .vegetables),
    ])

    @Test("A recipe with braune Champignons answers to Pilz")
    func everyAncestorIsIndexed() {
        // The chain the shipped data already held, and the one hop the index
        // used to take: "Champignon" was found, "Pilz" was not, and a cook
        // filtering for mushrooms missed a mushroom recipe.
        let recipe = Recipe(title: "Pfanne", servings: 2, ingredientsText: "200 g Braune Champignons\n1 Zwiebel")
        let keys = RecipeIndex.ingredientKeys(for: recipe, catalog: catalog)

        #expect(keys.contains("brauner champignon"))
        #expect(keys.contains("champignon"))
        #expect(keys.contains("pilz"))
        #expect(keys.contains("zwiebel"))
        // Once each, in the order they were met: a key is not made stronger
        // by being listed twice.
        #expect(Set(keys).count == keys.count)
    }

    @Test("The chain stops where the catalog does")
    func aDanglingParentEndsTheWalk() {
        let loose = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Steinpilz", category: .vegetables, parentName: "Waldpilz"),
        ])
        // "Waldpilz" is named and not present. The variety keeps its own key
        // and the walk ends without inventing one for the missing word.
        let keys = RecipeIndex.ingredientKeys(
            for: Recipe(title: "Risotto", servings: 2, ingredientsText: "100 g Steinpilz"),
            catalog: loose
        )
        #expect(keys == ["steinpilz"])
        #expect(loose.ancestors(of: "Steinpilz").isEmpty)
    }
}
