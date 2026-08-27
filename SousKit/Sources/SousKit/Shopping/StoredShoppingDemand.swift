import Foundation
import SwiftData

/// One captured contribution to a shopping item. Demands are stored one row
/// per recipe line and never summed into each other — the bundling happens
/// when the list is read.
@Model
public final class StoredShoppingDemand {
    #Index<StoredShoppingDemand>([\.itemID], [\.planEntryID])

    public var id: UUID = UUID()
    /// The item this demand sits under, matching ``StoredShoppingEntry/itemID``.
    public var itemID: UUID?
    /// The plan entry it scales with; `nil` means frozen (migrated rows,
    /// lapsed remains).
    public var planEntryID: UUID?
    /// The recipe line it was captured from, within its capture.
    public var lineID: UUID?
    /// The recipe or subrecipe title it reads as coming from.
    public var originTitle: String = ""
    /// The ingredient as the recipe wrote it — see ``ShoppingDemand/writtenName``.
    public var writtenName: String = ""
    /// Serialized ``Quantity`` as captured; empty means unquantified.
    public var quantityData: Data = Data()
    public var stateRaw: String = IngredientState.unspecified.rawValue
    public var scales: Bool = true
    public var isLate: Bool = false
    public var isScaleDiff: Bool = false
    /// The plan entry's portion count when the item was checked off; while
    /// set, the effective amount stops following the stepper.
    public var checkedAtServings: Int?
    /// Serialized ``Quantity``: the part no longer wanted after scaling a
    /// checked item down.
    public var lapsedQuantityData: Data = Data()
    public var isLapsed: Bool = false
    public var addedAt: Date = Date.nowInSyncPrecision
    /// Where this demand sits among the others, the way ``StoredShoppingEntry``
    /// and ``StoredShoppingPlanEntry`` carry their position.
    ///
    /// `addedAt` alone could not order them: it is stored at millisecond
    /// precision, and everything captured in one pass — every line of one
    /// recipe, every source of one migrated row — lands in the same
    /// millisecond. Tied rows then came back in whatever order the fetch
    /// happened to produce, so a list read twice could name its recipes in
    /// two different orders.
    public var sortOrder: Int = 0
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(_ demand: ShoppingDemand, itemID: UUID?, sortOrder: Int = 0) {
        id = demand.id
        self.sortOrder = sortOrder
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
    }

    public var quantity: Quantity? {
        get { quantityData.isEmpty ? nil : try? SousCoding.decoder.decode(Quantity.self, from: quantityData) }
        set {
            quantityData = newValue.flatMap { try? SousCoding.encoder.encode($0) } ?? Data()
            updatedAt = .nowInSyncPrecision
        }
    }

    public var lapsedQuantity: Quantity? {
        get { lapsedQuantityData.isEmpty ? nil : try? SousCoding.decoder.decode(Quantity.self, from: lapsedQuantityData) }
        set {
            lapsedQuantityData = newValue.flatMap { try? SousCoding.encoder.encode($0) } ?? Data()
            updatedAt = .nowInSyncPrecision
        }
    }

    /// The domain reading, with the effective amount already derived against
    /// the plan entry it scales with.
    public func domainValue(planEntry: ShoppingPlanEntry?) -> ShoppingDemand {
        let captured = quantity
        return ShoppingDemand(
            id: id,
            planEntryID: planEntryID,
            lineID: lineID,
            originTitle: originTitle,
            writtenName: writtenName,
            quantity: captured,
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

    /// See ``ShoppingDemandScaling``, which both stored forms share.
    public func effectiveQuantity(planEntry: ShoppingPlanEntry?) -> Quantity? {
        ShoppingDemandScaling.effectiveQuantity(
            captured: quantity,
            scales: scales,
            isScaleDiff: isScaleDiff,
            checkedAtServings: checkedAtServings,
            planEntry: planEntry
        )
    }
}
