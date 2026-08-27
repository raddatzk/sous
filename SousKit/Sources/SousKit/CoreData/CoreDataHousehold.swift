import CloudKit
import CoreData
import Foundation
import os

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
        guard let context = managedObjectContext else { return }
        // Only when this app is the one inserting. Importing a record from
        // CloudKit creates managed objects too, and a row arriving from
        // somebody else's household has to keep the household it came with —
        // giving it this device's would rewrite their library on the next
        // export.
        guard context.transactionAuthor == SousPersistentContainer.appTransactionAuthor
        else { return }

        // Writing into a joined household. The row has to live in the shared
        // store as well, because a relationship cannot reach across store
        // files — a recipe in the private file cannot point at a household
        // in the shared one.
        if let activeID = ActiveHousehold.id,
           let joined = try? CoreDataHouseholds.joined(id: activeID, in: context) {
            if let coordinator = context.persistentStoreCoordinator,
               let shared = SousPersistentContainer.sharedStore(in: coordinator) {
                context.assign(self, to: shared)
            }
            household = joined
            return
        }

        // Assigned to its store immediately, not left for the save to
        // decide: scoped fetches restrict by store, and a pending insert
        // with no store affiliation is invisible to them — which made a
        // shopping capture create its item and then fail to find it two
        // lines later, filing the next amount under a duplicate.
        if let coordinator = context.persistentStoreCoordinator,
           let own = SousPersistentContainer.privateStore(in: coordinator) {
            context.assign(self, to: own)
        }
        // The own household comes into being with the first thing that
        // belongs to it — not at launch, where an invitation-only member
        // would get an empty one beside the household they joined. The
        // duplicate a reinstall race can still make is folded away by
        // `mergeDuplicates`; what that race can no longer do is create a
        // zone, which was the part that hurt.
        household = try? CoreDataHouseholds.findOrCreate(in: context)
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
    private static let log = Logger(subsystem: "me.raddatz.sous", category: "household")

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
    /// This device's household, or `nil` if it does not have one yet.
    ///
    /// The oldest wins, and that rule is what keeps two devices agreeing:
    /// both see the same rows and both pick the same one, without asking
    /// each other.
    static func existing(in context: NSManagedObjectContext) throws -> CDHousehold? {
        try households(in: context).first
    }

    /// Every household this person owns, oldest first.
    ///
    /// Only their own store. Households they joined live in the shared one,
    /// and the oldest row across both could easily be somebody else's —
    /// which would make tonight's recipe a contribution to their library
    /// rather than to this one.
    private static func households(in context: NSManagedObjectContext) throws -> [CDHousehold] {
        let request = NSFetchRequest<CDHousehold>(entityName: SousManagedObjectModel.householdEntityName)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        request.affectedStores = ownStores(for: context)
        return try context.fetch(request)
    }

    /// This device's household, made if there is none.
    ///
    /// Deliberately **not** what an insert calls. A fresh install has an
    /// empty store and an import on the way, and creating a household in that
    /// second means creating a second one — the copy already in iCloud
    /// arrives moments later, and from then on the library is split between
    /// two households that can never be shared together. So a row joins the
    /// household that exists, and making one is a decision taken once, at
    /// launch, after the import has had its chance.
    static func findOrCreate(in context: NSManagedObjectContext) throws -> CDHousehold {
        if let existing = try existing(in: context) { return existing }

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

    /// A household this person was invited into, by id.
    ///
    /// Looked up in the shared store only: that is where joined households
    /// live, and an id that matches nothing there is not one to write into.
    static func joined(id: UUID, in context: NSManagedObjectContext) throws -> CDHousehold? {
        guard let coordinator = context.persistentStoreCoordinator,
              let shared = SousPersistentContainer.sharedStore(in: coordinator)
        else { return nil }
        let request = NSFetchRequest<CDHousehold>(
            entityName: SousManagedObjectModel.householdEntityName
        )
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.affectedStores = [shared]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// Everything a person could switch to: their own household, if it
    /// exists yet, and every household they joined.
    public func choices() async throws -> [HouseholdChoice] {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            var result: [HouseholdChoice] = []
            if let own = try CoreDataHouseholds.existing(in: context), let id = own.id {
                result.append(HouseholdChoice(id: id, name: own.name, isOwn: true))
            }
            if let coordinator = context.persistentStoreCoordinator,
               let shared = SousPersistentContainer.sharedStore(in: coordinator) {
                let request = NSFetchRequest<CDHousehold>(
                    entityName: SousManagedObjectModel.householdEntityName
                )
                request.affectedStores = [shared]
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                for household in try context.fetch(request) {
                    guard let id = household.id else { continue }
                    result.append(HouseholdChoice(id: id, name: household.name, isOwn: false))
                }
            }
            return result
        }
    }

    /// Takes an invitation somebody tapped and files the household it opens
    /// into the shared store.
    ///
    /// This is the other half of the sharing sheet: the system delivers the
    /// tapped invitation to the app as metadata, and nothing happens unless
    /// the app hands it to the container. Once accepted, CloudKit imports the
    /// zone behind it, the household lands in the shared store, and the
    /// remote-change reload puts its recipes on screen — there is no further
    /// step and no screen to build for it.
    ///
    /// Through the completion API for the same reason `makeShare` is: the
    /// generated async variant assumes a completion without an error carries
    /// values, and this one may carry neither while the delegate starts up.
    public func acceptInvitation(from metadata: CKShare.Metadata) async throws {
        guard let cloudContainer = container as? NSPersistentCloudKitContainer else {
            throw HouseholdSharingError.notAvailable
        }
        guard let sharedStore = SousPersistentContainer.sharedStore(
            in: container.persistentStoreCoordinator
        ) else {
            throw HouseholdSharingError.notAvailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cloudContainer.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        Self.log.info("Accepted an invitation into the shared store.")
    }

    /// Creates the share, through the completion API rather than the `async`
    /// one Swift generates for it.
    ///
    /// The generated version returns a non-optional tuple, because Swift
    /// assumes an Objective-C completion that reports no error reports
    /// values. This one does not: all four of its parameters are nullable,
    /// and while the mirroring delegate is still starting up it calls back
    /// with no error *and* no share. The generated wrapper then force-
    /// unwraps that nil, and the app dies inside a framework bridge with a
    /// message that names nothing.
    private static func makeShare(
        for object: NSManagedObject,
        in container: NSPersistentCloudKitContainer
    ) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            container.share([object], to: nil) { _, share, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let share {
                    continuation.resume(returning: share)
                } else {
                    // No error and no share: not ready, and not saying so.
                    continuation.resume(throwing: HouseholdSharingError.notAvailable)
                }
            }
        }
    }

    /// Waits for the mirroring delegate to report that it has set itself up.
    ///
    /// Returns `false` on timeout, which is the ordinary case offline: there
    /// is nothing to wait for and nothing to report.
    private static func waitForCloudKitSetup(timeout: Duration) async -> Bool {
        let events = NotificationCenter.default.notifications(
            named: NSPersistentCloudKitContainer.eventChangedNotification
        )

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await note in events {
                    guard let event = note.userInfo?[
                        NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                    ] as? NSPersistentCloudKitContainer.Event else { continue }
                    // `endDate` distinguishes "setup finished" from "setup
                    // started" — both arrive as the same event type.
                    guard event.type == .setup, event.endDate != nil else { continue }
                    return event.succeeded
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The share to hand to the system's sharing sheet, made if there is
    /// none yet.
    ///
    /// This is where the zone comes into being — deliberately not at launch,
    /// where making one raced the initial import and reset the sync. The
    /// first invitation therefore pays for the move into the shared zone,
    /// and every later one just reopens the sheet.
    ///
    /// If the first attempt fails, it waits for the mirroring delegate to
    /// finish setting up and tries once more: the sheet is opened by a person
    /// standing there, often seconds after launch, and "try again in half a
    /// minute" is not an answer a button should give when waiting quietly
    /// does the same job.
    ///
    /// Throws where sharing is impossible rather than returning nothing: at
    /// this point a person has asked to invite somebody, and silence would
    /// leave them tapping a button that does nothing.
    public func shareForInviting() async throws -> (share: CKShare, container: CKContainer) {
        guard let cloudContainer = container as? NSPersistentCloudKitContainer else {
            throw HouseholdSharingError.notAvailable
        }

        let context = SousPersistentContainer.backgroundContext(for: container)
        let (householdID, householdName) = try await context.perform {
            let household = try CoreDataHouseholds.findOrCreate(in: context)
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

        let household = try await context.perform { try context.existingObject(with: householdID) }
        let share: CKShare
        do {
            share = try await Self.makeShare(for: household, in: cloudContainer)
        } catch {
            // Usually "not ready yet": the mirroring delegate is still
            // setting up, which it very much is in the first seconds after
            // launch. Wait for it to say so, then ask once more.
            guard await Self.waitForCloudKitSetup(timeout: .seconds(30)) else { throw error }
            share = try await Self.makeShare(for: household, in: cloudContainer)
        }
        // What the invitation calls the thing being shared. Left unset, the
        // sheet offers to share something unnamed, which is a poor way to ask
        // somebody to join a kitchen. The sharing controller saves the share
        // when participants are added, and carries this along.
        share[CKShare.SystemFieldKey.title] = householdName
        return (share, ckContainer)
    }

    /// Folds several of this person's households into one.
    ///
    /// They can appear despite `awakeFromInsert` never making one: an older
    /// build made them per install, two devices can decide at the same
    /// moment that there is none, and an import can deliver one just after
    /// this device concluded there was not. Left alone, the library ends up
    /// split between households that can never be shared as a whole — and
    /// nothing about that looks wrong on screen, because every recipe is
    /// still there.
    ///
    /// The oldest wins, which is the same rule `existing` applies, so two
    /// devices doing this independently reach the same answer without
    /// talking to each other.
    ///
    /// Returns how many were folded away.
    @discardableResult
    public func mergeDuplicates() async throws -> Int {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            let all = try CoreDataHouseholds.households(in: context)
            guard let survivor = all.first, all.count > 1 else { return 0 }

            for doomed in all.dropFirst() {
                for entity in SousManagedObjectModel.memberEntityNames {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                    request.predicate = NSPredicate(format: "household == %@", doomed)
                    for row in try context.fetch(request) {
                        row.setValue(survivor, forKey: "household")
                    }
                }
                context.delete(doomed)
            }

            if context.hasChanges { try context.save() }
            let folded = all.count - 1
            Self.log.info("Folded \(folded, privacy: .public) duplicate household(s) into one.")
            return folded
        }
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
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            // The orphans are found before a household is conjured up to hold
            // them: creating one eagerly is how an invitation-only member
            // ended up with an empty own household standing beside the one
            // they joined. No orphans, no household.
            var orphans: [NSManagedObject] = []
            for entity in SousManagedObjectModel.memberEntityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: "household == nil")
                // A row in a household somebody else owns is not orphaned,
                // it belongs to them.
                request.affectedStores = CoreDataHouseholds.ownStores(for: context)
                orphans.append(contentsOf: try context.fetch(request))
            }
            guard !orphans.isEmpty else { return 0 }

            let household = try CoreDataHouseholds.findOrCreate(in: context)
            for row in orphans {
                row.setValue(household, forKey: "household")
            }
            if context.hasChanges { try context.save() }
            return orphans.count
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

/// One entry in the household switch.
public struct HouseholdChoice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let isOwn: Bool
}
