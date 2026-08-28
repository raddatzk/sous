import CloudKit
import CoreData
import Foundation

/// Makes the Core Data container the household's library lives in, and
/// mirrors it into iCloud.
public enum SousPersistentContainer {
    public static let appGroup = SousAppGroup.identifier

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

    /// - Parameters:
    ///   - inMemory: for tests, and for the migration's dry run. Never
    ///     mirrored: a test that reached iCloud would be a test that depends
    ///     on an account.
    ///   - mirroring: whether this process talks to CloudKit at all. The app
    ///     passes the default; the share extension passes `false`, because
    ///     two processes each mirroring the same store files means two sync
    ///     engines racing over one set of books — and an extension lives
    ///     under a memory ceiling that a CloudKit import is happy to blow
    ///     through. What the extension writes reaches iCloud anyway: it lands
    ///     in the store's history, and the app exports it on its next run.
    public static func make(
        inMemory: Bool = false,
        mirroring: Bool = true
    ) throws -> NSPersistentContainer {
        if inMemory || !mirroring {
            isConfiguredForCloudKit = false
            return try makeLocal(inMemory: inMemory)
        }

        do {
            let container = try makeMirrored()
            isConfiguredForCloudKit = true
            return container
        } catch {
            // The entitlement is missing, the container identifier is not in
            // the account, or the device cannot reach iCloud at all. None of
            // those is a reason to leave the cook without their recipes, so
            // the same stores open without mirroring — the files are
            // identical either way, and a later launch that can mirror picks
            // them up.
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

        container.viewContext.transactionAuthor = appTransactionAuthor
        configure(container.viewContext)
        return container
    }

    private static func makeLocal(inMemory: Bool) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "Sous",
            managedObjectModel: SousManagedObjectModel.shared
        )
        // Both files, not just the private one. Households this person was
        // invited into live in the shared store, and a fallback that leaves
        // that file closed makes every one of them vanish from the app for
        // exactly as long as iCloud is unreachable — which is when nothing
        // could explain where they went.
        container.persistentStoreDescriptions = if inMemory {
            [description(at: URL(fileURLWithPath: "/dev/null"))]
        } else {
            [description(at: storeURL()), description(at: sharedStoreURL())]
        }

        var loadError: Error?
        container.loadPersistentStores { _, error in
            if loadError == nil { loadError = error }
        }
        if let loadError { throw loadError }

        container.viewContext.transactionAuthor = appTransactionAuthor
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

    /// What this app writes under, as opposed to what CloudKit's mirroring
    /// writes under when it imports.
    ///
    /// The distinction matters because a row attaches itself to the household
    /// on insert, and an insert is not always the app's doing: importing a
    /// record creates managed objects too. A row arriving from somebody
    /// else's household must keep the household it came with — not be given
    /// this device's, which would rewrite their library on the next export.
    public static let appTransactionAuthor = "me.raddatz.sous.app"

    /// A background context for a store to work on, marked as this app's.
    ///
    /// Every store used to make its own and configure it identically; this is
    /// that, said once, plus the author that tells our writes from CloudKit's.
    public static func backgroundContext(
        for container: NSPersistentContainer
    ) -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.transactionAuthor = appTransactionAuthor
        configure(context)
        return context
    }

    private static func configure(_ context: NSManagedObjectContext) {
        // Last writer wins per property. Two devices editing different fields
        // of one recipe is ordinary once this syncs, and refusing the merge
        // would surface as a save failing for reasons nobody can act on.
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        context.automaticallyMergesChangesFromParent = true
    }

    /// The store holding what this person owns, as opposed to households
    /// they were invited into.
    ///
    /// Needed by name, because "which household do I write into" must never
    /// be answered by a fetch across both stores: a fetch like that can
    /// return somebody else's household, and then a recipe written tonight
    /// lands in their library instead of this one.
    public static func privateStore(
        in coordinator: NSPersistentStoreCoordinator
    ) -> NSPersistentStore? {
        let url = storeURL()
        let stores = coordinator.persistentStores
        // By URL rather than by position: the order the coordinator lists
        // them in is not promised, and picking the wrong one here is exactly
        // the mistake this function exists to prevent.
        return stores.first { $0.url == url } ?? stores.first
    }

    /// The store mirroring the shared CloudKit database — where an accepted
    /// invitation has to be filed, because that is the database the household
    /// arrives in.
    public static func sharedStore(
        in coordinator: NSPersistentStoreCoordinator
    ) -> NSPersistentStore? {
        let url = sharedStoreURL()
        return coordinator.persistentStores.first { $0.url == url }
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

    /// The app group where there is one, and the app's own Application
    /// Support where there is not — the Mac, and any test host.
    ///
    /// Created if missing, because a sandboxed app's Application Support
    /// directory does not exist until somebody makes it, and Core Data given
    /// a URL under a directory that is not there reports a store that failed
    /// to open rather than making the path itself.
    private static func containerDirectory() -> URL {
        if let group = SousAppGroup.url { return group }
        let support = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }
}
