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
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(_ demand: ShoppingDemand, itemID: UUID?) {
        id = demand.id
        self.itemID = itemID
        planEntryID = demand.planEntryID
        lineID = demand.lineID
        originTitle = demand.originTitle
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

    /// Captured × current/captured of the plan entry — frozen at the
    /// check-off, and left alone entirely for non-scaling demands.
    public func effectiveQuantity(planEntry: ShoppingPlanEntry?) -> Quantity? {
        guard let captured = quantity else { return nil }
        guard scales, !isScaleDiff, let planEntry, planEntry.servingsCaptured > 0 else { return captured }
        let target = checkedAtServings ?? planEntry.servingsCurrent
        return captured.scaled(by: Double(target) / Double(planEntry.servingsCaptured))
    }
}
