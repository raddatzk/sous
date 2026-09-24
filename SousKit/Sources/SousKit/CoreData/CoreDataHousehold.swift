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
    @NSManaged var isDeliberate: Bool
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

        // Into the active household, in the store that holds it — own or
        // joined. Assigned to that store immediately, not left for the save
        // to decide: a relationship cannot reach across store files, and
        // scoped fetches restrict by store, so a pending insert with no store
        // affiliation is invisible to them — which made a shopping capture
        // create its item and then fail to find it two lines later.
        if let activeID = ActiveHousehold.id,
           let active = try? CoreDataHouseholds.household(id: activeID, in: context) {
            if let store = CoreDataHouseholds.store(of: active, in: context) {
                context.assign(self, to: store)
            }
            household = active
            return
        }

        // No household known yet. The row waits without one, in the private
        // store, until `CoreDataHouseholds.settle` knows which households
        // exist. Founding one here is what a reinstall used to do while
        // iCloud was still delivering the real ones, leaving a stray
        // household on every device.
        if let coordinator = context.persistentStoreCoordinator,
           let own = SousPersistentContainer.privateStore(in: coordinator) {
            context.assign(self, to: own)
        }
    }
}

/// The households on this device: the ones this person owns, in the private
/// store, and the ones they joined, in the shared one.
///
/// One per container, because the identity that matters is the row in the
/// store, not this object.
public final class CoreDataHouseholds: @unchecked Sendable {
    private static let log = Logger(subsystem: "me.raddatz.sous", category: "household")

    /// What a household the app makes for a person is called until anybody
    /// renames it.
    public static let defaultName = "Mein Haushalt"

    private let container: NSPersistentContainer

    public init(container: NSPersistentContainer) {
        self.container = container
    }

    // MARK: Finding households

    /// Oldest first, and the id after that: timestamps carry milliseconds,
    /// two devices can land on the same one, and "the oldest" has to be the
    /// same household on both.
    static var oldestFirst: [NSSortDescriptor] {
        [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true),
        ]
    }

    /// Every household this person owns, oldest first.
    ///
    /// Only their own store. Households they joined live in the shared one,
    /// and the oldest row across both could easily be somebody else's.
    private static func households(in context: NSManagedObjectContext) throws -> [CDHousehold] {
        let request = NSFetchRequest<CDHousehold>(entityName: SousManagedObjectModel.householdEntityName)
        request.sortDescriptors = oldestFirst
        request.affectedStores = ownStores(for: context)
        return try context.fetch(request)
    }

    /// A household by id, own or joined.
    ///
    /// Both stores at once: an id lives in exactly one of them — the owner's
    /// private store, or a member's shared one — so the answer cannot be
    /// ambiguous.
    static func household(id: UUID, in context: NSManagedObjectContext) throws -> CDHousehold? {
        let request = NSFetchRequest<CDHousehold>(entityName: SousManagedObjectModel.householdEntityName)
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// The store a household's rows belong in.
    ///
    /// One made in this context and not saved yet has no store on its object
    /// id; it was made here, so it is this person's own.
    static func store(of household: CDHousehold, in context: NSManagedObjectContext) -> NSPersistentStore? {
        if let store = household.objectID.persistentStore { return store }
        guard let coordinator = context.persistentStoreCoordinator else { return nil }
        return SousPersistentContainer.privateStore(in: coordinator)
    }

    /// The store holding the household with this id, or `nil` if none does.
    static func store(ofHousehold id: UUID, in context: NSManagedObjectContext) throws -> NSPersistentStore? {
        try household(id: id, in: context).flatMap { store(of: $0, in: context) }
    }

    /// The own household something without a household of its own acts on:
    /// the active one if it is this person's, otherwise the oldest they own.
    private static func ownTarget(in context: NSManagedObjectContext) throws -> CDHousehold? {
        let own = try households(in: context)
        if let activeID = ActiveHousehold.id, let active = own.first(where: { $0.id == activeID }) {
            return active
        }
        return own.first
    }

    /// The persistent store this device writes its own rows into, as the one
    /// element of a list, which is the shape a fetch request wants.
    private static func ownStores(for context: NSManagedObjectContext) -> [NSPersistentStore]? {
        guard let coordinator = context.persistentStoreCoordinator else { return nil }
        return SousPersistentContainer.privateStore(in: coordinator).map { [$0] }
    }

    private static func makeHousehold(
        named name: String,
        deliberately: Bool,
        in context: NSManagedObjectContext
    ) -> CDHousehold {
        let made = CDHousehold(context: context)
        made.id = UUID()
        made.name = name
        made.isDeliberate = deliberately
        made.createdAt = .nowInSyncPrecision
        made.updatedAt = .nowInSyncPrecision
        if let store = ownStores(for: context)?.first {
            // Said explicitly rather than left to the default, which is
            // simply the first store the coordinator lists.
            context.assign(made, to: store)
        }
        return made
    }

    /// The oldest household this person owns — where a device that has not
    /// chosen one starts, and where content from before households existed
    /// belongs.
    ///
    /// Synchronous, because the switch needs it before the first fetch of a
    /// session: an update from a build that knew only one household arrives
    /// with nothing chosen, and a library read with nothing chosen shows only
    /// what has no household — an empty screen for as long as the launch
    /// takes to decide.
    public func oldestOwnID() -> UUID? {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return context.performAndWait {
            (try? CoreDataHouseholds.households(in: context))?.first?.id
        }
    }

    /// Everything a person could switch to: every household they own, oldest
    /// first, then every household they joined.
    public func choices() async throws -> [HouseholdChoice] {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            var result: [HouseholdChoice] = []
            for own in try CoreDataHouseholds.households(in: context) {
                guard let id = own.id else { continue }
                result.append(HouseholdChoice(id: id, name: own.name, isOwn: true))
            }
            if let coordinator = context.persistentStoreCoordinator,
               let shared = SousPersistentContainer.sharedStore(in: coordinator) {
                let request = NSFetchRequest<CDHousehold>(
                    entityName: SousManagedObjectModel.householdEntityName
                )
                request.affectedStores = [shared]
                request.sortDescriptors = CoreDataHouseholds.oldestFirst
                for household in try context.fetch(request) {
                    guard let id = household.id else { continue }
                    result.append(HouseholdChoice(id: id, name: household.name, isOwn: false))
                }
            }
            return result
        }
    }

    // MARK: Making and naming

    /// A new household, made by a person and named by them. It is never
    /// folded into another.
    ///
    /// Empty until something is written into it, which the caller arranges
    /// by making it the active one.
    @discardableResult
    public func create(named name: String) async throws -> UUID {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let made = CoreDataHouseholds.makeHousehold(
                named: trimmed.isEmpty ? CoreDataHouseholds.defaultName : trimmed,
                deliberately: true,
                in: context
            )
            try context.save()
            // Always set by `makeHousehold`; the attribute is optional only
            // because CloudKit asks every attribute to be.
            return made.id ?? UUID()
        }
    }

    /// What the household sharing acts on is called — the active household
    /// if it is this person's, otherwise the oldest they own — or `nil`
    /// while they own none.
    public func ownName() async throws -> String? {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            try CoreDataHouseholds.ownTarget(in: context)?.name
        }
    }

    /// Gives the household sharing acts on a new name — the one everybody
    /// invited into it sees in their switcher.
    ///
    /// Only a household that exists: a name typed during a reinstall, before
    /// the households have arrived from iCloud, must not found another one.
    /// Nothing is lost by waiting — inviting names the household it shares.
    public func rename(to name: String) async throws {
        let context = SousPersistentContainer.backgroundContext(for: container)
        try await context.perform {
            guard let household = try CoreDataHouseholds.ownTarget(in: context) else { return }
            Self.rename(household, to: name)
            if context.hasChanges { try context.save() }
        }
    }

    /// Trimmed, and ignored when empty or unchanged — an unchanged name
    /// would still bump `updatedAt` and send the row through iCloud again.
    private static func rename(_ household: CDHousehold, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != household.name else { return }
        household.name = trimmed
        household.updatedAt = .nowInSyncPrecision
    }

    // MARK: Keeping it tidy

    /// Puts the households in order once this device knows which ones
    /// exist — after its first import has arrived, or at once where nothing
    /// is mirrored.
    ///
    /// Not earlier, and that is the point: before the import, "no household"
    /// only means "none delivered yet", and a household founded on that
    /// belief is a stray on every device a minute later.
    ///
    /// Two things, in this order:
    /// * An account without a household of its own gets one — the only way
    ///   the app ever makes one unasked.
    /// * Rows saved without a household join the own one, if there is
    ///   exactly one. With several the app cannot know which was meant, and
    ///   they stay unassigned — still visible in every own household — for
    ///   the person to decide.
    @discardableResult
    public func settle() async throws -> HouseholdSettlement {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            var own = try CoreDataHouseholds.households(in: context)
            var founded = false
            if own.isEmpty {
                own = [CoreDataHouseholds.makeHousehold(
                    named: CoreDataHouseholds.defaultName,
                    deliberately: false,
                    in: context
                )]
                founded = true
            }

            let orphans = try CoreDataHouseholds.waitingRows(in: context)

            var assigned = 0
            if own.count == 1, let only = own.first {
                for row in orphans {
                    row.setValue(only, forKey: "household")
                }
                assigned = orphans.count
            }
            if context.hasChanges { try context.save() }

            let settlement = HouseholdSettlement(
                founded: founded,
                assigned: assigned,
                unassigned: orphans.count - assigned
            )
            if settlement != HouseholdSettlement(founded: false, assigned: 0, unassigned: 0) {
                Self.log.info("Settled households: founded \(founded, privacy: .public), assigned \(assigned, privacy: .public), unassigned \(settlement.unassigned, privacy: .public)")
            }
            return settlement
        }
    }

    /// How many rows wait for a household — saved before this device knew
    /// one, and left unassigned by `settle` because there are several own
    /// households to choose from.
    public func waitingRowCount() async throws -> Int {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            try CoreDataHouseholds.waitingRows(in: context).count
        }
    }

    /// Gives every row that waits for a household to the own household the
    /// person chose. Returns how many there were.
    ///
    /// Only an own household: the waiting rows sit in the private store, and
    /// a relationship cannot reach a household in the shared one.
    @discardableResult
    public func assignWaitingRows(to id: UUID) async throws -> Int {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            guard let target = try CoreDataHouseholds.households(in: context).first(where: { $0.id == id })
            else { return 0 }
            let rows = try CoreDataHouseholds.waitingRows(in: context)
            for row in rows {
                row.setValue(target, forKey: "household")
            }
            if context.hasChanges { try context.save() }
            return rows.count
        }
    }

    /// Every row in the private store that has no household.
    private static func waitingRows(in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        var rows: [NSManagedObject] = []
        for entity in SousManagedObjectModel.memberEntityNames {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "household == nil")
            // A row in a household somebody else owns is not waiting, it
            // belongs to them.
            request.affectedStores = ownStores(for: context)
            rows.append(contentsOf: try context.fetch(request))
        }
        return rows
    }

    /// Folds the households the app made on its own into one.
    ///
    /// Two devices set up at the same moment on a brand-new account both
    /// find no household after their first import and both make one; older
    /// builds made one per install as well. Left alone, the library ends up
    /// split between two "Mein Haushalt" — and nothing about that looks
    /// wrong on screen, because every recipe is still there.
    ///
    /// Only households the app made. One a person made with a name is never
    /// touched: two of those side by side is what they asked for.
    ///
    /// The oldest wins, so two devices doing this independently reach the
    /// same answer without talking to each other.
    ///
    /// Returns how many were folded away.
    @discardableResult
    public func mergeDuplicates() async throws -> Int {
        let context = SousPersistentContainer.backgroundContext(for: container)
        return try await context.perform {
            let implicit = try CoreDataHouseholds.households(in: context).filter { !$0.isDeliberate }
            guard let survivor = implicit.first, implicit.count > 1 else { return 0 }

            for doomed in implicit.dropFirst() {
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
            let folded = implicit.count - 1
            Self.log.info("Folded \(folded, privacy: .public) duplicate household(s) into one.")
            return folded
        }
    }

    // MARK: Sharing

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
    ///
    /// `name` is what the household is called from now on — given here, at
    /// the moment of inviting, because that is when a name starts to matter:
    /// until somebody else is in it, every household is simply "mine", and
    /// once somebody is, theirs is too.
    public func shareForInviting(
        named name: String
    ) async throws -> (share: CKShare, container: CKContainer) {
        guard let cloudContainer = container as? NSPersistentCloudKitContainer else {
            throw HouseholdSharingError.notAvailable
        }

        let context = SousPersistentContainer.backgroundContext(for: container)
        let (householdID, householdName) = try await context.perform {
            // Inviting is a deliberate act with a name, so a person who owns
            // no household yet gets one here that can never be folded away.
            let household = try CoreDataHouseholds.ownTarget(in: context)
                ?? CoreDataHouseholds.makeHousehold(named: name, deliberately: true, in: context)
            Self.rename(household, to: name)
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

}

/// What `CoreDataHouseholds.settle` did.
public struct HouseholdSettlement: Equatable, Sendable {
    /// Whether the account had no household of its own and got one.
    public var founded: Bool
    /// Rows that had no household and joined the only own one.
    public var assigned: Int
    /// Rows still without a household, because there are several own ones
    /// to choose from.
    public var unassigned: Int
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
