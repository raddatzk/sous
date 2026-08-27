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

    func makeStore() throws -> any RecipeStore {
        switch self {
        case .swiftData:
            SwiftDataRecipeStore(modelContainer: try .sousContainer(inMemory: true))
        case .coreData:
            CoreDataRecipeStore(container: try SousPersistentContainer.make(inMemory: true))
        }
    }

    func makeImageStore() throws -> any RecipeImageStore {
        switch self {
        case .swiftData:
            SwiftDataRecipeImageStore(modelContainer: try .sousContainer(inMemory: true))
        case .coreData:
            CoreDataRecipeImageStore(container: try SousPersistentContainer.make(inMemory: true))
        }
    }
}
