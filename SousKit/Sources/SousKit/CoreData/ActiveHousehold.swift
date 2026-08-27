import CoreData
import Foundation

/// Which household this device is currently looking at and writing into.
///
/// `nil` means the person's own. A UUID names a household they joined, which
/// lives in the shared store. The value is process-wide state the way the
/// transaction author is: every store consults it on every fetch and every
/// insert, and threading it through six stores and thirty call sites would
/// buy ceremony, not safety.
///
/// The app sets it at launch from the defaults and whenever the switch is
/// used. The share extension never sets it, so everything shared in from
/// Safari lands in the person's own household — which is where a recipe
/// clipped in passing belongs until somebody decides otherwise.
public enum ActiveHousehold {
    public nonisolated(unsafe) static var id: UUID?
}

extension NSManagedObjectContext {
    /// Fetches within the active household — the reading half of the switch.
    ///
    /// Own means the private store file, whole: everything in it belongs to
    /// this person, orphans included, and nothing in it belongs to anyone
    /// else. A joined household means the shared store file *and* a
    /// predicate, because several joined households share that one file.
    ///
    /// A named household whose store cannot be found falls back to own —
    /// the same answer `awakeFromInsert` gives, so reading and writing never
    /// disagree about where "here" is.
    func fetchInActiveHousehold<T>(_ request: NSFetchRequest<T>) throws -> [T] where T: NSFetchRequestResult {
        scopeToActiveHousehold(request)
        return try fetch(request)
    }

    private func scopeToActiveHousehold<T>(_ request: NSFetchRequest<T>) {
        guard let coordinator = persistentStoreCoordinator else { return }

        if let activeID = ActiveHousehold.id,
           let shared = SousPersistentContainer.sharedStore(in: coordinator) {
            request.affectedStores = [shared]
            let household = NSPredicate(format: "household.id == %@", activeID as NSUUID)
            request.predicate = request.predicate.map {
                NSCompoundPredicate(andPredicateWithSubpredicates: [$0, household])
            } ?? household
        } else if let own = SousPersistentContainer.privateStore(in: coordinator) {
            request.affectedStores = [own]
        }
    }
}
