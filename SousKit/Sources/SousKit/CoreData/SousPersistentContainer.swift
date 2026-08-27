import CloudKit
import CoreData
import Foundation

/// Makes the Core Data container the household's library lives in, and
/// mirrors it into iCloud.
public enum SousPersistentContainer {
    public static let appGroup = "group.me.raddatz.sous"

    /// The iCloud container the household's rows are mirrored into. It has to
    /// exist in the developer account; a build signed without it cannot use
    /// it, which is what `make` falls back from.
    public static let cloudKitContainerIdentifier = "iCloud.me.raddatz.sous"

    /// Whether the last `make` opened its stores *configured* for CloudKit.
    ///
    /// Deliberately not called "is syncing": the stores open perfectly well
    /// with no iCloud account at all, and the mirroring then fails afterwards
    /// and asynchronously — the simulator says `CKAccountStatusNoAccount` a
    /// few milliseconds after a load that reported success. So this answers
    /// "was the attempt made", which is the only thing that is known at that
    /// point. Whether anything actually reaches another device is a question
    /// for `NSPersistentCloudKitContainer`'s own event notifications.
    public private(set) nonisolated(unsafe) static var isConfiguredForCloudKit = false

    /// - Parameter inMemory: for tests, and for the migration's dry run. Never
    ///   mirrored: a test that reached iCloud would be a test that depends on
    ///   an account.
    public static func make(inMemory: Bool = false) throws -> NSPersistentContainer {
        if inMemory {
            isConfiguredForCloudKit = false
            return try makeLocal(inMemory: true)
        }

        do {
            let container = try makeMirrored()
            isConfiguredForCloudKit = true
            return container
        } catch {
            // The entitlement is missing, the container identifier is not in
            // the account, or the device cannot reach iCloud at all. None of
            // those is a reason to leave the cook without their recipes, so
            // the same store opens without mirroring — the file is identical
            // either way, and a later launch that can mirror picks it up.
            isConfiguredForCloudKit = false
            return try makeLocal(inMemory: false)
        }
    }

    /// Both CloudKit databases, each mirrored into a store of its own.
    ///
    /// The private one holds what this person owns. The shared one is where a
    /// household somebody else owns arrives once its invitation is accepted —
    /// which is the whole reason for Core Data being here at all, since
    /// SwiftData can address neither the shared scope nor a `CKShare`.
    ///
    /// The private store is listed first, and that is not cosmetic: a newly
    /// inserted object with no store assigned goes to the first one, and a
    /// recipe written into someone else's household by default would be a
    /// gift nobody meant to give.
    private static func makeMirrored() throws -> NSPersistentContainer {
        let container = NSPersistentCloudKitContainer(
            name: "Sous",
            managedObjectModel: SousManagedObjectModel.shared
        )

        let privateStore = description(at: storeURL())
        privateStore.cloudKitContainerOptions = cloudKitOptions(scope: .private)

        let sharedStore = description(at: sharedStoreURL())
        sharedStore.cloudKitContainerOptions = cloudKitOptions(scope: .shared)

        container.persistentStoreDescriptions = [privateStore, sharedStore]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            // Only the first failure is kept: the second store failing for the
            // same reason says nothing new.
            if loadError == nil { loadError = error }
        }
        if let loadError { throw loadError }

        configure(container.viewContext)
        return container
    }

    private static func makeLocal(inMemory: Bool) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "Sous",
            managedObjectModel: SousManagedObjectModel.shared
        )
        container.persistentStoreDescriptions = [
            description(at: inMemory ? URL(fileURLWithPath: "/dev/null") : storeURL()),
        ]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        configure(container.viewContext)
        return container
    }

    private static func cloudKitOptions(
        scope: CKDatabase.Scope
    ) -> NSPersistentCloudKitContainerOptions {
        let options = NSPersistentCloudKitContainerOptions(
            containerIdentifier: cloudKitContainerIdentifier
        )
        options.databaseScope = scope
        return options
    }

    /// `/dev/null` rather than `NSInMemoryStoreType` for the in-memory case:
    /// it is still the SQLite store, so it behaves like the real one and
    /// supports the history tracking below, which the in-memory type does not.
    private static func description(at url: URL) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        // History tracking is what CloudKit reads to work out what changed,
        // and the notification is how the other processes — the share
        // extension, the widgets — hear that something did.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        return description
    }

    private static func configure(_ context: NSManagedObjectContext) {
        // Last writer wins per property. Two devices editing different fields
        // of one recipe is ordinary once this syncs, and refusing the merge
        // would surface as a save failing for reasons nobody can act on.
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        context.automaticallyMergesChangesFromParent = true
    }

    /// Beside the SwiftData store in the app group, under its own name. The
    /// app and its share extension both read from there, and a recipe saved
    /// from Safari has to land where the app looks.
    private static func storeURL() -> URL {
        containerDirectory().appending(path: "Sous.sqlite")
    }

    /// Households this person was invited into. A file of its own because the
    /// scopes cannot share one: each store mirrors exactly one database.
    private static func sharedStoreURL() -> URL {
        containerDirectory().appending(path: "Sous-shared.sqlite")
    }

    private static func containerDirectory() -> URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? URL.applicationSupportDirectory
    }
}
