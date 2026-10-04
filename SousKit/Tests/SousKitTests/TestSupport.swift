import CoreData
import Foundation
import Testing
@testable import SousKit

/// The bytes of a file under `Fixtures/`, failing the test where it is missing.
func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
    )
    return try Data(contentsOf: url)
}

/// Nutrient values that are zero but for the energy, and the protein where a
/// test needs a second number — enough to tell two rows apart in a sum.
func info(kcal: Double, protein: Double = 0) -> NutritionInfo {
    var info = NutritionInfo.zero
    info.kcal = kcal
    info.proteinG = protein
    return info
}

/// A Core Data store as a real SQLite file, for the migration suites.
///
/// Not in memory: an in-memory store has no schema to migrate. A file in a
/// directory of its own, with the same history tracking the app switches on,
/// is the one way to see the lightweight migration Core Data infers actually
/// run.
enum ScratchStore {
    /// A fresh `Sous.sqlite` in a temporary directory of its own.
    static func makeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sous-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Sous.sqlite")
    }

    /// Removes the directory ``makeURL()`` made for `url`.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func open(_ url: URL, with model: NSManagedObjectModel) throws -> NSPersistentContainer {
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

    static func close(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}
