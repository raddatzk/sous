import Foundation
import SwiftData

/// A tick, an item added by hand, or both.
@Model
public final class StoredShoppingEntry {
    #Index<StoredShoppingEntry>([\.key])

    /// The normalized ingredient name, matching ``ShoppingItem/key``.
    public var key: String = ""
    public var name: String = ""
    public var amount: Double?
    public var unitSymbol: String?
    public var isChecked: Bool = false
    public var isManual: Bool = false
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(
        key: String,
        name: String,
        amount: Double? = nil,
        unitSymbol: String? = nil,
        isChecked: Bool = false,
        isManual: Bool = false
    ) {
        self.key = key
        self.name = name
        self.amount = amount
        self.unitSymbol = unitSymbol
        self.isChecked = isChecked
        self.isManual = isManual
    }

    public var domainValue: ShoppingItem {
        var quantities: [Quantity] = []
        if let amount, let unitSymbol {
            quantities.append(Quantity(amount, IngredientUnit(symbol: unitSymbol)))
        }
        return ShoppingItem(
            key: key,
            name: name,
            quantities: quantities,
            isChecked: isChecked,
            isManual: isManual
        )
    }
}
