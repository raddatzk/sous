import CoreData
import Foundation

/// Which household this device is currently looking at and writing into.
///
/// A UUID names a household, own or joined — whichever store holds it.
/// `nil` means this device knows no household yet: a fresh install before
/// its first import has arrived, where content is kept without a household
/// and assigned once it is clear which ones exist (see
/// `CoreDataHouseholds.settle`). The value is process-wide state the way the
/// transaction author is: every store consults it on every fetch and every
/// insert, and threading it through six stores and thirty call sites would
/// buy ceremony, not safety.
///
/// The app sets it at launch from the defaults and whenever the switch is
/// used; the share extension reads the same defaults, so what it saves lands
/// in the household that was showing last.
public enum ActiveHousehold {
    public nonisolated(unsafe) static var id: UUID?

    /// Where the app keeps the choice, in the app group's defaults — so the
    /// share extension saves into the household that was showing last.
    public static let defaultsKey = "activeHouseholdID"

    /// The household chosen last, as the app left it.
    public static var remembered: UUID? {
        UserDefaults.sous.string(forKey: defaultsKey).flatMap(UUID.init(uuidString:))
    }
}

extension NSManagedObjectContext {
    /// Fetches within the active household — the reading half of the switch.
    ///
    /// A household is found in whichever store holds it and read there by
    /// its id. An own household also shows the rows that have no household
    /// yet: they are this person's, saved before the device knew where they
    /// belong, and hiding them until they are assigned would make a recipe
    /// imported during a reinstall vanish the moment the library arrived.
    /// With no household active — or one no store holds any more — only
    /// those unassigned rows are visible.
    func fetchInActiveHousehold<T>(_ request: NSFetchRequest<T>) throws -> [T] where T: NSFetchRequestResult {
        scopeToActiveHousehold(request)
        return try fetch(request)
    }

    private func scopeToActiveHousehold<T>(_ request: NSFetchRequest<T>) {
        guard let coordinator = persistentStoreCoordinator else { return }
        let own = SousPersistentContainer.privateStore(in: coordinator)
        let unassigned = NSPredicate(format: "household == nil")

        let scope: NSPredicate
        if let activeID = ActiveHousehold.id,
           let store = try? CoreDataHouseholds.store(ofHousehold: activeID, in: self) {
            request.affectedStores = [store]
            let household = NSPredicate(format: "household.id == %@", activeID as NSUUID)
            scope = store == own
                ? NSCompoundPredicate(orPredicateWithSubpredicates: [household, unassigned])
                : household
        } else if let own {
            request.affectedStores = [own]
            scope = unassigned
        } else {
            return
        }
        request.predicate = request.predicate.map {
            NSCompoundPredicate(andPredicateWithSubpredicates: [$0, scope])
        } ?? scope
    }
}
