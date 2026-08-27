import CoreData
import Foundation

/// Makes the Core Data container the household's library lives in.
///
/// Plain `NSPersistentContainer` for now. The CloudKit door is deliberately
/// left shut rather than left ajar: `NSPersistentCloudKitContainer` fails to
/// load its stores when the entitlement is missing, which would turn every
/// test host and every unsigned build into a broken app, and the zones the
/// sharing design needs are a step of their own. Opening it is a change to
/// this one function.
public enum SousPersistentContainer {
    public static let appGroup = "group.me.raddatz.sous"

    /// - Parameter inMemory: for tests, and for the migration's dry run.
    public static func make(inMemory: Bool = false) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "Sous",
            managedObjectModel: SousManagedObjectModel.shared
        )

        // `/dev/null` rather than `NSInMemoryStoreType`: it is still the
        // SQLite store, so it behaves like the real one and supports the
        // history tracking below, which the in-memory type does not.
        let description = NSPersistentStoreDescription(
            url: inMemory ? URL(fileURLWithPath: "/dev/null") : storeURL()
        )
        // Both are what CloudKit mirroring will need, and neither costs
        // anything before then: the history it reads to work out what changed,
        // and the notifications that tell other processes — the share
        // extension, the widgets — that something did.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }

    /// Beside the SwiftData store in the app group, under its own name. The
    /// app and its share extension both read from there, and a recipe saved
    /// from Safari has to land where the app looks.
    private static func storeURL() -> URL {
        let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? URL.applicationSupportDirectory
        return directory.appending(path: "Sous.sqlite")
    }
}
