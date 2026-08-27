import CoreData
import Foundation
import SwiftData
@testable import SousKit

/// Which implementation a store test runs against.
///
/// Every contract in these suites is checked twice, because there are now two
/// stores obliged to keep it: the SwiftData one the app has always used, and
/// the Core Data one the shared CloudKit database requires. A divergence
/// between them would not announce itself as a crash — it would be a library
/// that answers the same search differently after the migration, which is the
/// kind of failure nobody reports because nobody sees it happen.
enum StoreBackend: CaseIterable, CustomStringConvertible {
    case swiftData
    case coreData

    var description: String {
        switch self {
        case .swiftData: "SwiftData"
        case .coreData: "Core Data"
        }
    }

    /// Several stores over one container.
    ///
    /// Which matters as soon as a test needs two of them to see each other —
    /// a plan entry pointing at a recipe, a shopping list built from one.
    /// Handing out stores over separate containers would give each test its
    /// own private, mutually invisible library.
    struct StoreSet {
        let recipes: any RecipeStore
        let images: any RecipeImageStore
        let mealPlan: any MealPlanStore
        let amountReviews: any RecipeAmountReviewStore
        let ingredientReviews: any RecipeIngredientReviewStore
        let vocabulary: any VocabularyStore
        let shopping: any ShoppingListStore
    }

    func makeStores() throws -> StoreSet {
        switch self {
        case .swiftData:
            let container = try ModelContainer.sousContainer(inMemory: true)
            return StoreSet(
                recipes: SwiftDataRecipeStore(modelContainer: container),
                images: SwiftDataRecipeImageStore(modelContainer: container),
                mealPlan: SwiftDataMealPlanStore(modelContainer: container),
                amountReviews: SwiftDataRecipeAmountReviewStore(modelContainer: container),
                ingredientReviews: SwiftDataRecipeIngredientReviewStore(modelContainer: container),
                vocabulary: SwiftDataVocabularyStore(modelContainer: container),
                shopping: SwiftDataShoppingListStore(modelContainer: container)
            )
        case .coreData:
            let container = try SousPersistentContainer.make(inMemory: true)
            return StoreSet(
                recipes: CoreDataRecipeStore(container: container),
                images: CoreDataRecipeImageStore(container: container),
                mealPlan: CoreDataMealPlanStore(container: container),
                amountReviews: CoreDataRecipeAmountReviewStore(container: container),
                ingredientReviews: CoreDataRecipeIngredientReviewStore(container: container),
                vocabulary: CoreDataVocabularyStore(container: container),
                shopping: CoreDataShoppingListStore(container: container)
            )
        }
    }

    func makeStore() throws -> any RecipeStore { try makeStores().recipes }
    func makeImageStore() throws -> any RecipeImageStore { try makeStores().images }
    func makeMealPlanStore() throws -> any MealPlanStore { try makeStores().mealPlan }
    func makeAmountReviewStore() throws -> any RecipeAmountReviewStore { try makeStores().amountReviews }
    func makeIngredientReviewStore() throws -> any RecipeIngredientReviewStore { try makeStores().ingredientReviews }
    func makeVocabularyStore() throws -> any VocabularyStore { try makeStores().vocabulary }
}
