import CoreData
import Foundation

/// The Core Data form of a shopping item — the counterpart to
/// ``StoredShoppingEntry``.
@objc(CDShoppingEntry)
final class CDShoppingEntry: CDHouseholdMember {
    @NSManaged var itemID: UUID?
    @NSManaged var key: String
    @NSManaged var name: String
    @NSManaged var categoryRaw: String?
    @NSManaged var manualQuantityData: Data?
    @NSManaged var isChecked: Bool
    @NSManaged var isLateAddition: Bool
    @NSManaged var clearedAt: Date?
    @NSManaged var sortOrder: Int64
    @NSManaged var addedAt: Date?
    @NSManaged var updatedAt: Date?

    var category: IngredientCategory? { categoryRaw.flatMap(IngredientCategory.init(rawValue:)) }

    var manualQuantities: [Quantity] {
        get {
            guard let manualQuantityData else { return [] }
            return (try? SousCoding.decoder.decode([Quantity].self, from: manualQuantityData)) ?? []
        }
        set {
            manualQuantityData = try? SousCoding.encoder.encode(newValue)
            updatedAt = .nowInSyncPrecision
        }
    }

    /// The domain reading; demands are attached by the store, which knows
    /// the plan entries they derive against.
    func domainValue(demands: [ShoppingDemand]) -> ShoppingItem {
        ShoppingItem(
            itemID: itemID ?? UUID(),
            key: key,
            name: name,
            category: category,
            demands: demands,
            manualQuantities: manualQuantities,
            isChecked: isChecked,
            isLateAddition: isLateAddition,
            isCleared: clearedAt != nil
        )
    }
}

/// The Core Data form of a captured recipe on the list.
@objc(CDShoppingPlanEntry)
final class CDShoppingPlanEntry: CDHouseholdMember {
    @NSManaged var id: UUID?
    @NSManaged var recipeID: UUID?
    @NSManaged var title: String
    @NSManaged var servingsCaptured: Int64
    @NSManaged var servingsCurrent: Int64
    @NSManaged var sortOrder: Int64
    @NSManaged var addedAt: Date?
    @NSManaged var updatedAt: Date?

    func apply(_ entry: ShoppingPlanEntry) {
        id = entry.id
        recipeID = entry.recipeID
        title = entry.title
        servingsCaptured = Int64(entry.servingsCaptured)
        servingsCurrent = Int64(entry.servingsCurrent)
        addedAt = entry.addedAt
        updatedAt = .nowInSyncPrecision
    }

    var domainValue: ShoppingPlanEntry {
        ShoppingPlanEntry(
            id: id ?? UUID(),
            recipeID: recipeID,
            title: title,
            servingsCaptured: Int(servingsCaptured),
            servingsCurrent: Int(servingsCurrent),
            addedAt: addedAt ?? .distantPast
        )
    }
}

/// The Core Data form of one contribution to an item.
@objc(CDShoppingDemand)
final class CDShoppingDemand: CDHouseholdMember {
    @NSManaged var id: UUID?
    @NSManaged var itemID: UUID?
    @NSManaged var planEntryID: UUID?
    @NSManaged var lineID: UUID?
    @NSManaged var originTitle: String
    @NSManaged var writtenName: String
    @NSManaged var quantityData: Data?
    @NSManaged var stateRaw: String
    @NSManaged var scales: Bool
    @NSManaged var isLate: Bool
    @NSManaged var isScaleDiff: Bool
    @NSManaged var checkedAtServingsValue: NSNumber?
    @NSManaged var lapsedQuantityData: Data?
    @NSManaged var isLapsed: Bool
    @NSManaged var sortOrder: Int64
    @NSManaged var addedAt: Date?
    @NSManaged var updatedAt: Date?

    /// The plan entry's portion count when the item was checked off; while
    /// set, the effective amount stops following the stepper.
    var checkedAtServings: Int? {
        get { checkedAtServingsValue?.intValue }
        set { checkedAtServingsValue = newValue.map(NSNumber.init) }
    }

    var quantity: Quantity? {
        get { Self.decode(quantityData) }
        set {
            quantityData = newValue.flatMap { try? SousCoding.encoder.encode($0) }
            updatedAt = .nowInSyncPrecision
        }
    }

    /// The part no longer wanted after scaling a checked item down.
    var lapsedQuantity: Quantity? {
        get { Self.decode(lapsedQuantityData) }
        set {
            lapsedQuantityData = newValue.flatMap { try? SousCoding.encoder.encode($0) }
            updatedAt = .nowInSyncPrecision
        }
    }

    private static func decode(_ data: Data?) -> Quantity? {
        guard let data, !data.isEmpty else { return nil }
        return try? SousCoding.decoder.decode(Quantity.self, from: data)
    }

    func apply(_ demand: ShoppingDemand, itemID: UUID?, sortOrder: Int) {
        id = demand.id
        self.sortOrder = Int64(sortOrder)
        self.itemID = itemID
        planEntryID = demand.planEntryID
        lineID = demand.lineID
        originTitle = demand.originTitle
        writtenName = demand.writtenName
        quantity = demand.quantity
        stateRaw = demand.state.rawValue
        scales = demand.scales
        isLate = demand.isLate
        isScaleDiff = demand.isScaleDiff
        checkedAtServings = demand.checkedAtServings
        lapsedQuantity = demand.lapsedQuantity
        isLapsed = demand.isLapsed
        addedAt = .nowInSyncPrecision
        updatedAt = .nowInSyncPrecision
    }

    /// See ``ShoppingDemandScaling``, which both stored forms share.
    func effectiveQuantity(planEntry: ShoppingPlanEntry?) -> Quantity? {
        ShoppingDemandScaling.effectiveQuantity(
            captured: quantity,
            scales: scales,
            isScaleDiff: isScaleDiff,
            checkedAtServings: checkedAtServings,
            planEntry: planEntry
        )
    }

    func domainValue(planEntry: ShoppingPlanEntry?) -> ShoppingDemand {
        ShoppingDemand(
            id: id ?? UUID(),
            planEntryID: planEntryID,
            lineID: lineID,
            originTitle: originTitle,
            writtenName: writtenName,
            quantity: quantity,
            effectiveQuantity: effectiveQuantity(planEntry: planEntry),
            state: IngredientState(rawValue: stateRaw) ?? .unspecified,
            scales: scales,
            isLate: isLate,
            isScaleDiff: isScaleDiff,
            checkedAtServings: checkedAtServings,
            lapsedQuantity: lapsedQuantity,
            isLapsed: isLapsed
        )
    }
}

extension CDShoppingEntry {
    static func fetchRequest() -> NSFetchRequest<CDShoppingEntry> {
        NSFetchRequest<CDShoppingEntry>(entityName: SousManagedObjectModel.shoppingEntryEntityName)
    }
}

extension CDShoppingPlanEntry {
    static func fetchRequest() -> NSFetchRequest<CDShoppingPlanEntry> {
        NSFetchRequest<CDShoppingPlanEntry>(entityName: SousManagedObjectModel.shoppingPlanEntryEntityName)
    }
}

extension CDShoppingDemand {
    static func fetchRequest() -> NSFetchRequest<CDShoppingDemand> {
        NSFetchRequest<CDShoppingDemand>(entityName: SousManagedObjectModel.shoppingDemandEntityName)
    }
}
