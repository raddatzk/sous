import CloudKit
import CoreData
import Foundation

/// One household — the row every other row hangs off, and the object a share
/// is placed on.
@objc(CDHousehold)
final class CDHousehold: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
}

/// A row that belongs to a household.
///
/// The attachment happens in `awakeFromInsert` rather than in each store,
/// which is the whole point of doing it here: there are six stores and rather
/// more insert paths than that, and one that forgot would not fail — it would
/// write a row outside the shared zone, where it syncs to nobody and looks
/// perfectly normal on the device that wrote it.
///
/// The lookup is a fetch with a limit of one against an indexed column, and
/// after the first insert the household is already in the context's row cache,
/// so a bulk import pays for it once rather than per row.
class CDHouseholdMember: NSManagedObject {
    @NSManaged var household: CDHousehold?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        guard let managedObjectContext else { return }
        household = try? CoreDataHouseholds.current(in: managedObjectContext)
    }
}

/// The household a store writes into.
///
/// Every store asks this before inserting, and the answer is the same object
/// for all of them, which is what keeps one library in one zone. It is
/// find-or-create rather than a setup step: the share extension runs no
/// migrations and may well be the first thing to open the store after an
/// update, so "there is no household yet" has to be an ordinary case rather
/// than a broken one.
///
/// One per container, because the identity that matters is the row in the
/// store, not this object.
public final class CoreDataHouseholds: @unchecked Sendable {
    /// What the cook's own household is called until anybody renames it.
    public static let defaultName = "Mein Haushalt"

    private let container: NSPersistentContainer

    public init(container: NSPersistentContainer) {
        self.container = container
    }

    /// The household this device writes into, created on first ask.
    ///
    /// Called inside the caller's own `perform`, so it takes the context it
    /// is already on rather than opening another.
    static func current(in context: NSManagedObjectContext) throws -> CDHousehold {
        let request = NSFetchRequest<CDHousehold>(entityName: SousManagedObjectModel.householdEntityName)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        request.fetchLimit = 1
        // Only this person's own store. Households they joined live in the
        // shared one, and the oldest row across both could easily be
        // somebody else's — which would make tonight's recipe a contribution
        // to their library rather than to this one.
        request.affectedStores = ownStores(for: context)
        if let existing = try context.fetch(request).first {
            return existing
        }

        let made = CDHousehold(context: context)
        made.id = UUID()
        made.name = defaultName
        made.createdAt = .nowInSyncPrecision
        made.updatedAt = .nowInSyncPrecision
        if let store = ownStores(for: context)?.first {
            // Said explicitly rather than left to the default, which is
            // simply the first store the coordinator lists.
            context.assign(made, to: store)
        }
        return made
    }

    /// The persistent store this device writes its own rows into, as the one
    /// element of a list, which is the shape a fetch request wants.
    private static func ownStores(for context: NSManagedObjectContext) -> [NSPersistentStore]? {
        guard let coordinator = context.persistentStoreCoordinator else { return nil }
        return SousPersistentContainer.privateStore(in: coordinator).map { [$0] }
    }

    /// Puts the household into a shared CloudKit zone, if it is not in one
    /// already.
    ///
    /// This is the "shared from the first day" rule made real. Sharing is not
    /// a flag that can be set later: `shareManagedObjects` moves the objects
    /// into the share's record zone, so promoting a grown library would
    /// relocate every recipe and every picture through iCloud, with new
    /// record identities, at the moment somebody is waiting to send an
    /// invitation. A share whose only participant is its owner costs nothing
    /// to hold, so the library is created inside one and inviting is reduced
    /// to opening the sharing sheet.
    ///
    /// The traversal does the rest: the header promises that related objects
    /// are shared along with the ones handed over, and everything in this
    /// store is related to the household. Rows written afterwards join by
    /// being attached to it.
    ///
    /// Returns `false` when the device cannot share right now — no iCloud
    /// account, no entitlement, mirroring never initialized. That is not an
    /// error to show anybody: the library works, it simply has no zone yet,
    /// and the next launch that can will make one.
    @discardableResult
    public func ensureShared() async throws -> Bool {
        guard let cloudContainer = container as? NSPersistentCloudKitContainer else { return false }

        let context = container.newBackgroundContext()
        let household: CDHousehold = try await context.perform {
            let household = try CoreDataHouseholds.current(in: context)
            // A share needs a permanent object id, which an unsaved insert
            // does not have.
            if context.hasChanges { try context.save() }
            return household
        }

        let alreadyShared = try? cloudContainer.fetchShares(matching: [household.objectID])
        guard alreadyShared?.isEmpty ?? true else { return true }

        do {
            _ = try await cloudContainer.share([household], to: nil)
            return true
        } catch {
            return false
        }
    }

    /// The share to hand to the system's sharing sheet, made if there is
    /// none yet.
    ///
    /// Inviting somebody is meant to be nothing more than opening that sheet,
    /// which is only true when the zone already exists — and it does, because
    /// `ensureShared` ran at launch. This is the same call once more for the
    /// case where it could not: a first launch offline, or an account signed
    /// in afterwards.
    ///
    /// Throws where sharing is impossible rather than returning nothing: at
    /// this point a person has asked to invite somebody, and silence would
    /// leave them tapping a button that does nothing.
    public func shareForInviting() async throws -> (share: CKShare, container: CKContainer) {
        guard let cloudContainer = container as? NSPersistentCloudKitContainer else {
            throw HouseholdSharingError.notAvailable
        }

        let context = container.newBackgroundContext()
        let (householdID, householdName) = try await context.perform {
            let household = try CoreDataHouseholds.current(in: context)
            if context.hasChanges { try context.save() }
            return (household.objectID, household.name)
        }

        let ckContainer = CKContainer(
            identifier: SousPersistentContainer.cloudKitContainerIdentifier
        )
        if let existing = try? cloudContainer.fetchShares(matching: [householdID])[householdID] {
            existing[CKShare.SystemFieldKey.title] = householdName
            return (existing, ckContainer)
        }

        let household = try context.existingObject(with: householdID)
        let (_, share, sharedContainer) = try await cloudContainer.share([household], to: nil)
        // What the invitation calls the thing being shared. Left unset, the
        // sheet offers to share something unnamed, which is a poor way to ask
        // somebody to join a kitchen. The sharing controller saves the share
        // when participants are added, and carries this along.
        share[CKShare.SystemFieldKey.title] = householdName
        return (share, sharedContainer)
    }

    /// Attaches everything that has no household yet to the one this device
    /// writes into.
    ///
    /// The repair for rows written before the household existed — a library
    /// migrated out of SwiftData, or anything the share extension saved while
    /// running an older build. Rows without a household are not broken, they
    /// simply never reach a shared zone, which is the failure worth healing
    /// quietly rather than reporting.
    @discardableResult
    public func adoptOrphanedRows() async throws -> Int {
        let context = container.newBackgroundContext()
        return try await context.perform {
            let household = try CoreDataHouseholds.current(in: context)
            var adopted = 0
            for entity in SousManagedObjectModel.memberEntityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: "household == nil")
                // Same reason: a row in a household somebody else owns is not
                // orphaned, it belongs to them.
                request.affectedStores = CoreDataHouseholds.ownStores(for: context)
                for row in try context.fetch(request) {
                    row.setValue(household, forKey: "household")
                    adopted += 1
                }
            }
            if context.hasChanges { try context.save() }
            return adopted
        }
    }
}

/// Why a household could not be shared.
public enum HouseholdSharingError: LocalizedError {
    /// The stores are not mirrored — no entitlement, no iCloud container, or
    /// a load that fell back to local-only.
    case notAvailable

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            "Sous kann gerade nicht auf iCloud zugreifen. Melde dich in den Systemeinstellungen bei iCloud an."
        }
    }
}
