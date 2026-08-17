import Foundation
import SwiftData

/// One line on the shopping list.
@Model
public final class StoredShoppingEntry {
    #Index<StoredShoppingEntry>([\.key])

    /// The normalized ingredient name, matching ``ShoppingItem/key``.
    public var key: String = ""
    public var name: String = ""
    /// Serialized amounts: a line can carry several that do not combine,
    /// like "100 g + 3 EL".
    public var quantityData: Data = Data()
    /// Serialized contributions: which recipe wants how much.
    public var sourceData: Data = Data()
    public var isChecked: Bool = false
    /// Position on the list. A timestamp is not enough: a whole recipe is
    /// added within the same millisecond, and its ingredients should keep the
    /// order they are written in.
    public var sortOrder: Int = 0
    public var addedAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(_ item: ShoppingItem) {
        key = item.key
        apply(item)
    }

    public func apply(_ item: ShoppingItem) {
        name = item.name
        quantityData = (try? SousCoding.encoder.encode(item.quantities)) ?? Data()
        sourceData = (try? SousCoding.encoder.encode(item.sources)) ?? Data()
        isChecked = item.isChecked
        updatedAt = .nowInSyncPrecision
    }

    public var quantities: [Quantity] {
        (try? SousCoding.decoder.decode([Quantity].self, from: quantityData)) ?? []
    }

    public var sources: [ShoppingSource] {
        (try? SousCoding.decoder.decode([ShoppingSource].self, from: sourceData)) ?? []
    }

    public var domainValue: ShoppingItem {
        ShoppingItem(
            key: key,
            name: name,
            quantities: quantities,
            sources: sources,
            isChecked: isChecked
        )
    }
}
