import CoreData
import Foundation

/// A ``ShoppingListStore`` backed by Core Data.
///
/// Every mutation obeys the list's one hard rule: checking off is the cook's
/// work and is never reset. New demand appends instead of un-checking, scaling
/// down annotates instead of deleting, and sweeping the list flags rows rather
/// than removing them.
///
/// What the SwiftData store has and this one does not is
/// `migrateLegacyRowsIfNeeded`. Pre-document rows — title-keyed sources, items
/// without an `itemID` — cannot reach this store: it is filled through the
/// protocol, and `snapshot()` on the other side has already turned them into
/// demands. Carrying the pass across would be code that can never run.
public final class CoreDataShoppingListStore: ShoppingListStore, @unchecked Sendable {
    /// Below this, two portion-scaled amounts count as the same.
    private static let tolerance = 1e-6

    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = SousPersistentContainer.backgroundContext(for: container)
    }

    public func snapshot() async throws -> ShoppingListSnapshot {
        try await context.perform {
            let plans = try self.planEntries()
            let planByID = Dictionary(
                plans.map { ($0.domainValue.id, $0.domainValue) },
                uniquingKeysWith: { first, _ in first }
            )
            let demandsByItem = Dictionary(grouping: try self.allDemands(), by: \.itemID)

            let items = try self.allEntries().map { entry in
                entry.domainValue(demands: (demandsByItem[entry.itemID] ?? []).map { demand in
                    demand.domainValue(planEntry: demand.planEntryID.flatMap { planByID[$0] })
                })
            }
            return ShoppingListSnapshot(items: items, planEntries: plans.map(\.domainValue))
        }
    }

    public func add(_ capture: ShoppingCapture) async throws {
        try await context.perform {
            // A recipe the list already knows arrives as a re-add: its demands
            // are marked late, so the list tells what changed since check-off.
            // A demand joining an entry already on the list is late for the
            // same reason - see the SwiftData store for the whole note.
            let existing = try self.planEntries()
            let knownRecipeIDs = Set(existing.compactMap(\.recipeID))
            var lateEntryIDs = Set(existing.map(\.id))
            var planPosition = try self.nextPlanSortOrder()
            for planEntry in capture.planEntries {
                let stored = CDShoppingPlanEntry(context: self.context)
                stored.apply(planEntry)
                stored.sortOrder = Int64(planPosition)
                planPosition += 1
                if let recipeID = planEntry.recipeID, knownRecipeIDs.contains(recipeID) {
                    lateEntryIDs.insert(planEntry.id)
                }
            }

            var itemPosition = try self.nextSortOrder()
            var demandPosition = try self.nextDemandSortOrder()
            for captured in capture.demands {
                guard !captured.key.isEmpty else { continue }
                var demand = captured.demand
                if let planEntryID = demand.planEntryID, lateEntryIDs.contains(planEntryID) {
                    demand.isLate = true
                }
                let target = try self.targetEntry(
                    key: captured.key,
                    name: captured.displayName,
                    category: captured.category,
                    position: &itemPosition
                )
                CDShoppingDemand(context: self.context)
                    .apply(demand, itemID: target.itemID, sortOrder: demandPosition)
                demandPosition += 1
                target.updatedAt = .nowInSyncPrecision
            }
            try self.context.save()
        }
    }

    public func addManual(
        key: String,
        name: String,
        category: IngredientCategory?,
        quantities: [Quantity]
    ) async throws {
        guard !key.isEmpty else { return }

        try await context.perform {
            var position = try self.nextSortOrder()
            let target = try self.targetEntry(
                key: key, name: name, category: category, position: &position
            )
            target.manualQuantities = target.manualQuantities.adding(quantities)
            try self.context.save()
        }
    }

    public func setChecked(_ checked: Bool, itemID: UUID) async throws {
        try await context.perform {
            guard let entry = try self.entry(itemID: itemID) else { return }
            entry.isChecked = checked
            entry.updatedAt = .nowInSyncPrecision

            let plans = try self.planEntriesByID()
            for demand in try self.demands(itemID: itemID) {
                if checked {
                    // Freeze at today's dial: what is in the basket does not
                    // change size when the stepper turns later.
                    if let planEntryID = demand.planEntryID, let plan = plans[planEntryID] {
                        demand.checkedAtServings = Int(plan.servingsCurrent)
                        demand.updatedAt = .nowInSyncPrecision
                    }
                } else {
                    // Un-checking hands the demand back to the stepper; the
                    // difference rows that covered for it would now double.
                    demand.checkedAtServings = nil
                    demand.lapsedQuantity = nil
                    if !demand.isScaleDiff, let planEntryID = demand.planEntryID {
                        try self.removeOpenScaleDiffs(planEntryID: planEntryID, lineID: demand.lineID)
                    }
                }
            }
            try self.context.save()
        }
    }

    public func remove(itemID: UUID) async throws {
        try await context.perform {
            guard let entry = try self.entry(itemID: itemID) else { return }
            for demand in try self.demands(itemID: itemID) {
                self.context.delete(demand)
            }
            self.context.delete(entry)
            try self.context.save()
        }
    }

    public func setServings(_ servings: Int, planEntryID: UUID) async throws {
        try await context.perform {
            guard let plan = try self.planEntry(id: planEntryID) else { return }
            let servings = Int64(max(1, servings))
            guard plan.servingsCurrent != servings else { return }
            plan.servingsCurrent = servings
            plan.updatedAt = .nowInSyncPrecision

            try self.reconcileScaleDiffs(for: plan)
            try self.context.save()
        }
    }

    public func removePlanEntry(_ planEntryID: UUID) async throws {
        try await context.perform {
            guard let plan = try self.planEntry(id: planEntryID) else { return }
            let planValue = plan.domainValue

            for demand in try self.demands(planEntryID: planEntryID) {
                guard let item = try self.entry(itemID: demand.itemID),
                      item.isChecked || item.clearedAt != nil
                else {
                    // Open demand disappears with its recipe; an item that held
                    // nothing else goes with it.
                    let itemID = demand.itemID
                    self.context.delete(demand)
                    try self.removeEntryIfEmpty(itemID: itemID)
                    continue
                }
                // On a checked item the demand is annotated as lapsed instead
                // of deleted — frozen at what the check-off froze it at, since
                // its plan entry will not be there to derive against.
                demand.quantity = demand.effectiveQuantity(planEntry: planValue)
                demand.planEntryID = nil
                demand.scales = false
                demand.checkedAtServings = nil
                demand.lapsedQuantity = nil
                demand.isLapsed = true
                demand.updatedAt = .nowInSyncPrecision
            }
            self.context.delete(plan)
            try self.context.save()
        }
    }

    public func clearChecked() async throws {
        try await context.perform {
            let now = Date.nowInSyncPrecision
            for entry in try self.allEntries() where entry.isChecked && entry.clearedAt == nil {
                entry.clearedAt = now
                entry.updatedAt = now
            }
            try self.context.save()
        }
    }

    // MARK: - Migration

    /// Writes a whole list as it stands — items, their demands, and the
    /// recipes they were captured from.
    ///
    /// `add(_:)` cannot do this: it is the door for *new* demand and would
    /// re-derive positions, re-decide what counts as a late addition, and
    /// know nothing of what is already ticked off or swept away. A list
    /// arriving through it would come back open, reordered, and with the
    /// shopping done twice.
    ///
    /// Positions come from the order of the snapshot itself, which is how
    /// both stores hand it over — the sort order is not part of the domain
    /// value, and does not need to be.
    public func adopt(_ snapshot: ShoppingListSnapshot) async throws {
        try await context.perform {
            for (position, plan) in snapshot.planEntries.enumerated() {
                guard try self.planEntry(id: plan.id) == nil else { continue }
                let row = CDShoppingPlanEntry(context: self.context)
                row.apply(plan)
                row.sortOrder = Int64(position)
            }

            var demandPosition = 0
            for (position, item) in snapshot.items.enumerated() {
                guard try self.entry(itemID: item.itemID) == nil else {
                    demandPosition += item.demands.count
                    continue
                }
                let row = CDShoppingEntry(context: self.context)
                row.itemID = item.itemID
                row.key = item.key
                row.name = item.name
                row.categoryRaw = item.category?.rawValue
                row.manualQuantities = item.manualQuantities
                row.isChecked = item.isChecked
                row.isLateAddition = item.isLateAddition
                // The sweep is remembered as a date, but the domain value
                // only carries that it happened — which is all anything reads.
                row.clearedAt = item.isCleared ? .nowInSyncPrecision : nil
                row.sortOrder = Int64(position)
                row.addedAt = .nowInSyncPrecision
                row.updatedAt = .nowInSyncPrecision

                for demand in item.demands {
                    CDShoppingDemand(context: self.context)
                        .apply(demand, itemID: item.itemID, sortOrder: demandPosition)
                    demandPosition += 1
                }
            }
            try self.context.save()
        }
    }

    // MARK: - Re-scaling

    /// Brings the difference rows in line with the dial: demand on open
    /// items derives on its own, demand frozen by a check-off gets the
    /// difference appended as an open late row — or, scaling down, the
    /// lapse annotated on the checked row.
    private func reconcileScaleDiffs(for plan: CDShoppingPlanEntry) throws {
        let captured = Double(plan.servingsCaptured)
        guard captured > 0, let planID = plan.id else { return }
        let demands = try demands(planEntryID: planID)
        let diffs = demands.filter(\.isScaleDiff)

        for demand in demands where !demand.isScaleDiff {
            guard demand.scales, let quantity = demand.quantity else { continue }
            guard let item = try entry(itemID: demand.itemID) else { continue }
            let companions = diffs.filter { $0.lineID == demand.lineID }

            guard item.isChecked || item.clearedAt != nil else {
                // The item is open; the demand follows the dial by
                // derivation and needs no difference row.
                continue
            }

            let frozenAt = demand.checkedAtServings ?? Int(plan.servingsCaptured)
            var covered = quantity.amount * Double(frozenAt) / captured
            var openCompanion: CDShoppingDemand?
            for companion in companions {
                let companionItem = try entry(itemID: companion.itemID)
                let isOpen = companionItem.map { !$0.isChecked && $0.clearedAt == nil } ?? false
                if isOpen {
                    openCompanion = companion
                } else if let bought = companion.quantity {
                    // A difference already in the basket stays covered.
                    covered += bought.amount
                }
            }

            let desired = quantity.amount * Double(plan.servingsCurrent) / captured
            let delta = desired - covered

            if delta > Self.tolerance {
                demand.lapsedQuantity = nil
                let difference = Quantity(delta, quantity.unit)
                if let openCompanion {
                    openCompanion.quantity = difference
                } else {
                    var position = try nextSortOrder()
                    let target = try targetEntry(
                        key: item.key,
                        name: item.name,
                        category: item.category,
                        position: &position
                    )
                    CDShoppingDemand(context: context).apply(
                        ShoppingDemand(
                            planEntryID: planID,
                            lineID: demand.lineID,
                            originTitle: demand.originTitle,
                            quantity: difference,
                            state: IngredientState(rawValue: demand.stateRaw) ?? .unspecified,
                            scales: false,
                            isLate: true,
                            isScaleDiff: true
                        ),
                        itemID: target.itemID,
                        sortOrder: try nextDemandSortOrder()
                    )
                }
            } else {
                if let openCompanion {
                    let itemID = openCompanion.itemID
                    context.delete(openCompanion)
                    try removeEntryIfEmpty(itemID: itemID)
                }
                demand.lapsedQuantity = delta < -Self.tolerance ? Quantity(-delta, quantity.unit) : nil
            }
        }
    }

    private func removeOpenScaleDiffs(planEntryID: UUID, lineID: UUID?) throws {
        for diff in try demands(planEntryID: planEntryID)
        where diff.isScaleDiff && diff.lineID == lineID {
            guard let item = try entry(itemID: diff.itemID),
                  !item.isChecked, item.clearedAt == nil
            else { continue }
            let itemID = diff.itemID
            context.delete(diff)
            try removeEntryIfEmpty(itemID: itemID)
        }
    }

    // MARK: - Items

    /// The item a new contribution lands on: the open one under that key —
    /// or a fresh one, because whatever is already checked stays checked.
    private func targetEntry(
        key: String,
        name: String,
        category: IngredientCategory?,
        position: inout Int
    ) throws -> CDShoppingEntry {
        let candidates = try entries(key: key).filter { $0.clearedAt == nil }
        if let open = candidates.first(where: { !$0.isChecked }) {
            return open
        }
        let entry = CDShoppingEntry(context: context)
        entry.itemID = UUID()
        entry.key = key
        entry.name = name
        entry.categoryRaw = category?.rawValue
        entry.addedAt = .nowInSyncPrecision
        entry.updatedAt = .nowInSyncPrecision
        // Landing under an ingredient already ticked off is what makes an
        // addition "late" — the list says so instead of un-checking.
        entry.isLateAddition = candidates.contains(where: \.isChecked)
        entry.sortOrder = Int64(position)
        position += 1
        return entry
    }

    private func removeEntryIfEmpty(itemID: UUID?) throws {
        guard let itemID, let entry = try entry(itemID: itemID) else { return }
        guard try demands(itemID: itemID).isEmpty, entry.manualQuantities.isEmpty else { return }
        context.delete(entry)
    }

    // MARK: - Fetching

    private func allEntries() throws -> [CDShoppingEntry] {
        let request = CDShoppingEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetchInActiveHousehold(request)
    }

    private func entries(key: String) throws -> [CDShoppingEntry] {
        let request = CDShoppingEntry.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", key)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetchInActiveHousehold(request)
    }

    private func entry(itemID: UUID?) throws -> CDShoppingEntry? {
        guard let itemID else { return nil }
        let request = CDShoppingEntry.fetchRequest()
        request.predicate = NSPredicate(format: "itemID == %@", itemID as NSUUID)
        request.fetchLimit = 1
        return try context.fetchInActiveHousehold(request).first
    }

    private func allDemands() throws -> [CDShoppingDemand] {
        let request = CDShoppingDemand.fetchRequest()
        // Both keys, in this order: `addedAt` keeps later captures after
        // earlier ones, `sortOrder` settles everything captured together —
        // which `addedAt` cannot, being tied across a whole pass.
        request.sortDescriptors = [
            NSSortDescriptor(key: "addedAt", ascending: true),
            NSSortDescriptor(key: "sortOrder", ascending: true),
        ]
        return try context.fetchInActiveHousehold(request)
    }

    private func demands(itemID: UUID?) throws -> [CDShoppingDemand] {
        guard let itemID else { return [] }
        let request = CDShoppingDemand.fetchRequest()
        request.predicate = NSPredicate(format: "itemID == %@", itemID as NSUUID)
        return try context.fetchInActiveHousehold(request)
    }

    private func demands(planEntryID: UUID) throws -> [CDShoppingDemand] {
        let request = CDShoppingDemand.fetchRequest()
        request.predicate = NSPredicate(format: "planEntryID == %@", planEntryID as NSUUID)
        return try context.fetchInActiveHousehold(request)
    }

    private func planEntries() throws -> [CDShoppingPlanEntry] {
        let request = CDShoppingPlanEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetchInActiveHousehold(request)
    }

    private func planEntriesByID() throws -> [UUID: CDShoppingPlanEntry] {
        Dictionary(
            try planEntries().compactMap { row in row.id.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func planEntry(id: UUID) throws -> CDShoppingPlanEntry? {
        let request = CDShoppingPlanEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try context.fetchInActiveHousehold(request).first
    }

    private func nextSortOrder() throws -> Int {
        try nextSortOrder(CDShoppingEntry.fetchRequest())
    }

    private func nextDemandSortOrder() throws -> Int {
        try nextSortOrder(CDShoppingDemand.fetchRequest())
    }

    private func nextPlanSortOrder() throws -> Int {
        try nextSortOrder(CDShoppingPlanEntry.fetchRequest())
    }

    /// One past the highest position in use — the same question for all three
    /// row types, so it is asked once.
    private func nextSortOrder<T: NSManagedObject>(_ request: NSFetchRequest<T>) throws -> Int {
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: false)]
        request.fetchLimit = 1
        let highest = try context.fetchInActiveHousehold(request).first?.value(forKey: "sortOrder") as? Int64
        return Int(highest ?? -1) + 1
    }
}
