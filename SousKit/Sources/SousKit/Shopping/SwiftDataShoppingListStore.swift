import Foundation
import SwiftData

/// A ``ShoppingListStore`` backed by SwiftData.
///
/// Every mutation obeys the document's one hard rule: checking off is the
/// cook's work and is never reset. New demand appends instead of un-checking,
/// scaling down annotates instead of deleting, and sweeping the list flags
/// rows rather than removing them.
@ModelActor
public actor SwiftDataShoppingListStore: ShoppingListStore {
    /// Below this, two portion-scaled amounts count as the same.
    private static let tolerance = 1e-6

    public func snapshot() async throws -> ShoppingListSnapshot {
        try migrateLegacyRowsIfNeeded()

        let plans = try planEntries()
        let planByID = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0.domainValue) })
        let demandsByItem = Dictionary(grouping: try allDemands(), by: \.itemID)

        let items = try allEntries().map { entry in
            entry.domainValue(demands: (demandsByItem[entry.itemID] ?? []).map { demand in
                demand.domainValue(planEntry: demand.planEntryID.flatMap { planByID[$0] })
            })
        }
        return ShoppingListSnapshot(
            items: items,
            planEntries: plans.map(\.domainValue)
        )
    }

    public func add(_ capture: ShoppingCapture) async throws {
        try migrateLegacyRowsIfNeeded()

        // A recipe the list already knows arrives as a re-add: its demands
        // are marked late, so the list tells what changed since check-off.
        let knownRecipeIDs = Set(try planEntries().compactMap(\.recipeID))
        var lateEntryIDs = Set<UUID>()
        var planPosition = try nextPlanSortOrder()
        for planEntry in capture.planEntries {
            let stored = StoredShoppingPlanEntry(planEntry)
            stored.sortOrder = planPosition
            planPosition += 1
            if let recipeID = planEntry.recipeID, knownRecipeIDs.contains(recipeID) {
                lateEntryIDs.insert(planEntry.id)
            }
            modelContext.insert(stored)
        }

        var itemPosition = try nextSortOrder()
        var demandPosition = try nextDemandSortOrder()
        for captured in capture.demands {
            guard !captured.key.isEmpty else { continue }
            var demand = captured.demand
            if let planEntryID = demand.planEntryID, lateEntryIDs.contains(planEntryID) {
                demand.isLate = true
            }
            let target = try targetEntry(
                key: captured.key,
                name: captured.displayName,
                category: captured.category,
                position: &itemPosition
            )
            modelContext.insert(StoredShoppingDemand(
                demand, itemID: target.itemID, sortOrder: demandPosition
            ))
            demandPosition += 1
            target.updatedAt = .nowInSyncPrecision
        }
        try modelContext.save()
    }

    public func addManual(
        key: String,
        name: String,
        category: IngredientCategory?,
        quantities: [Quantity]
    ) async throws {
        try migrateLegacyRowsIfNeeded()
        guard !key.isEmpty else { return }

        var position = try nextSortOrder()
        let target = try targetEntry(key: key, name: name, category: category, position: &position)
        target.manualQuantities = target.manualQuantities.adding(quantities)
        try modelContext.save()
    }

    public func setChecked(_ checked: Bool, itemID: UUID) async throws {
        guard let entry = try entry(itemID: itemID) else { return }
        entry.isChecked = checked
        entry.updatedAt = .nowInSyncPrecision

        let plans = try planEntriesByID()
        for demand in try demands(itemID: itemID) {
            if checked {
                // Freeze at today's dial: what is in the basket does not
                // change size when the stepper turns later.
                if let planEntryID = demand.planEntryID, let plan = plans[planEntryID] {
                    demand.checkedAtServings = plan.servingsCurrent
                    demand.updatedAt = .nowInSyncPrecision
                }
            } else {
                // Un-checking hands the demand back to the stepper; the
                // difference rows that covered for it would now double.
                demand.checkedAtServings = nil
                demand.lapsedQuantity = nil
                if !demand.isScaleDiff, let planEntryID = demand.planEntryID {
                    try removeOpenScaleDiffs(planEntryID: planEntryID, lineID: demand.lineID)
                }
            }
        }
        try modelContext.save()
    }

    public func remove(itemID: UUID) async throws {
        guard let entry = try entry(itemID: itemID) else { return }
        for demand in try demands(itemID: itemID) {
            modelContext.delete(demand)
        }
        modelContext.delete(entry)
        try modelContext.save()
    }

    public func setServings(_ servings: Int, planEntryID: UUID) async throws {
        try migrateLegacyRowsIfNeeded()
        guard let plan = try planEntry(id: planEntryID) else { return }
        let servings = max(1, servings)
        guard plan.servingsCurrent != servings else { return }
        plan.servingsCurrent = servings
        plan.updatedAt = .nowInSyncPrecision

        try reconcileScaleDiffs(for: plan)
        try modelContext.save()
    }

    public func removePlanEntry(_ planEntryID: UUID) async throws {
        guard let plan = try planEntry(id: planEntryID) else { return }
        let plans = try planEntriesByID()

        for demand in try demands(planEntryID: planEntryID) {
            guard let item = try entry(itemID: demand.itemID), item.isChecked || item.clearedAt != nil else {
                // Open demand disappears with its recipe; an item that held
                // nothing else goes with it.
                let itemID = demand.itemID
                modelContext.delete(demand)
                try removeEntryIfEmpty(itemID: itemID)
                continue
            }
            // On a checked item the demand is annotated as lapsed instead of
            // deleted — frozen at what the check-off froze it at, since its
            // plan entry will not be there to derive against.
            demand.quantity = demand.effectiveQuantity(planEntry: plans[planEntryID]?.domainValue)
            demand.planEntryID = nil
            demand.scales = false
            demand.checkedAtServings = nil
            demand.lapsedQuantity = nil
            demand.isLapsed = true
            demand.updatedAt = .nowInSyncPrecision
        }
        modelContext.delete(plan)
        try modelContext.save()
    }

    public func clearChecked() async throws {
        let now = Date.nowInSyncPrecision
        for entry in try allEntries() where entry.isChecked && entry.clearedAt == nil {
            entry.clearedAt = now
            entry.updatedAt = now
        }
        try modelContext.save()
    }

    // MARK: - Re-scaling

    /// Brings the difference rows in line with the dial: demand on open
    /// items derives on its own, demand frozen by a check-off gets the
    /// difference appended as an open late row — or, scaling down, the
    /// lapse annotated on the checked row.
    private func reconcileScaleDiffs(for plan: StoredShoppingPlanEntry) throws {
        let captured = Double(plan.servingsCaptured)
        guard captured > 0 else { return }
        let demands = try demands(planEntryID: plan.id)
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

            let frozenAt = demand.checkedAtServings ?? plan.servingsCaptured
            var covered = quantity.amount * Double(frozenAt) / captured
            var openCompanion: StoredShoppingDemand?
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
                        category: item.categoryRaw.flatMap(IngredientCategory.init(rawValue:)),
                        position: &position
                    )
                    modelContext.insert(StoredShoppingDemand(
                        ShoppingDemand(
                            planEntryID: plan.id,
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
                    ))
                }
            } else {
                if let openCompanion {
                    let itemID = openCompanion.itemID
                    modelContext.delete(openCompanion)
                    try removeEntryIfEmpty(itemID: itemID)
                }
                demand.lapsedQuantity = delta < -Self.tolerance ? Quantity(-delta, quantity.unit) : nil
            }
        }
    }

    private func removeOpenScaleDiffs(planEntryID: UUID, lineID: UUID?) throws {
        for diff in try demands(planEntryID: planEntryID) where diff.isScaleDiff && diff.lineID == lineID {
            guard let item = try entry(itemID: diff.itemID), !item.isChecked, item.clearedAt == nil else { continue }
            let itemID = diff.itemID
            modelContext.delete(diff)
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
    ) throws -> StoredShoppingEntry {
        let candidates = try entries(key: key).filter { $0.clearedAt == nil }
        if let open = candidates.first(where: { !$0.isChecked }) {
            return open
        }
        let entry = StoredShoppingEntry(key: key, name: name, category: category)
        // Landing under an ingredient already ticked off is what makes an
        // addition "late" — the list says so instead of un-checking.
        entry.isLateAddition = candidates.contains(where: \.isChecked)
        entry.sortOrder = position
        position += 1
        modelContext.insert(entry)
        return entry
    }

    private func removeEntryIfEmpty(itemID: UUID?) throws {
        guard let itemID, let entry = try entry(itemID: itemID) else { return }
        guard try demands(itemID: itemID).isEmpty, entry.manualQuantities.isEmpty else { return }
        modelContext.delete(entry)
    }

    // MARK: - Migration

    /// Turns pre-document rows into the document's shape, once: the
    /// title-keyed sources become frozen demands without a plan entry —
    /// visible, checkable, not re-scalable. Checked stays checked.
    private func migrateLegacyRowsIfNeeded() throws {
        var migrated = false
        // The whole migration runs inside one millisecond, so the order the
        // old rows named their recipes in only survives if it is written down.
        var position = try nextDemandSortOrder()
        for entry in try allEntries() {
            if entry.itemID == nil {
                entry.itemID = UUID()
                migrated = true
            }
            let sources = entry.legacySources
            guard !sources.isEmpty else { continue }
            for source in sources {
                let quantities: [Quantity?] = source.quantities.isEmpty ? [nil] : source.quantities
                for quantity in quantities {
                    modelContext.insert(StoredShoppingDemand(
                        ShoppingDemand(
                            originTitle: source.recipeTitle,
                            quantity: quantity,
                            scales: false
                        ),
                        itemID: entry.itemID,
                        sortOrder: position
                    ))
                    position += 1
                }
            }
            entry.sourceData = Data()
            migrated = true
        }
        if migrated {
            try modelContext.save()
        }
    }

    // MARK: - Fetching

    private func allEntries() throws -> [StoredShoppingEntry] {
        var descriptor = FetchDescriptor<StoredShoppingEntry>()
        descriptor.sortBy = [SortDescriptor(\.sortOrder)]
        return try modelContext.fetch(descriptor)
    }

    private func entries(key: String) throws -> [StoredShoppingEntry] {
        var descriptor = FetchDescriptor<StoredShoppingEntry>(predicate: #Predicate { $0.key == key })
        descriptor.sortBy = [SortDescriptor(\.sortOrder)]
        return try modelContext.fetch(descriptor)
    }

    private func entry(itemID: UUID?) throws -> StoredShoppingEntry? {
        guard let itemID else { return nil }
        var descriptor = FetchDescriptor<StoredShoppingEntry>(predicate: #Predicate { $0.itemID == itemID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func allDemands() throws -> [StoredShoppingDemand] {
        var descriptor = FetchDescriptor<StoredShoppingDemand>()
        // Both keys, in this order: `addedAt` keeps later captures after
        // earlier ones, `sortOrder` settles everything captured together —
        // which `addedAt` cannot, being tied across a whole pass.
        descriptor.sortBy = [SortDescriptor(\.addedAt), SortDescriptor(\.sortOrder)]
        return try modelContext.fetch(descriptor)
    }

    private func demands(itemID: UUID?) throws -> [StoredShoppingDemand] {
        guard let itemID else { return [] }
        let descriptor = FetchDescriptor<StoredShoppingDemand>(predicate: #Predicate { $0.itemID == itemID })
        return try modelContext.fetch(descriptor)
    }

    private func demands(planEntryID: UUID) throws -> [StoredShoppingDemand] {
        let descriptor = FetchDescriptor<StoredShoppingDemand>(
            predicate: #Predicate { $0.planEntryID == planEntryID }
        )
        return try modelContext.fetch(descriptor)
    }

    private func planEntries() throws -> [StoredShoppingPlanEntry] {
        var descriptor = FetchDescriptor<StoredShoppingPlanEntry>()
        descriptor.sortBy = [SortDescriptor(\.sortOrder)]
        return try modelContext.fetch(descriptor)
    }

    private func planEntriesByID() throws -> [UUID: StoredShoppingPlanEntry] {
        Dictionary(uniqueKeysWithValues: try planEntries().map { ($0.id, $0) })
    }

    private func planEntry(id: UUID) throws -> StoredShoppingPlanEntry? {
        var descriptor = FetchDescriptor<StoredShoppingPlanEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func nextSortOrder() throws -> Int {
        var descriptor = FetchDescriptor<StoredShoppingEntry>()
        descriptor.sortBy = [SortDescriptor(\.sortOrder, order: .reverse)]
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.sortOrder ?? -1) + 1
    }

    private func nextDemandSortOrder() throws -> Int {
        var descriptor = FetchDescriptor<StoredShoppingDemand>()
        descriptor.sortBy = [SortDescriptor(\.sortOrder, order: .reverse)]
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.sortOrder ?? -1) + 1
    }

    private func nextPlanSortOrder() throws -> Int {
        var descriptor = FetchDescriptor<StoredShoppingPlanEntry>()
        descriptor.sortBy = [SortDescriptor(\.sortOrder, order: .reverse)]
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.sortOrder ?? -1) + 1
    }
}
