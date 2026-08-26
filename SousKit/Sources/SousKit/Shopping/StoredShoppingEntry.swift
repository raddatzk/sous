import Foundation
import SwiftData

/// One checkable line on the shopping list.
///
/// The demands that fill it are ``StoredShoppingDemand`` rows joined by
/// `itemID`. `sourceData` is the shape the list had before it became a
/// document — read once by the migration, then left empty.
@Model
public final class StoredShoppingEntry {
    #Index<StoredShoppingEntry>([\.key])

    /// The normalized ingredient name, matching ``ShoppingItem/key``.
    public var key: String = ""
    public var name: String = ""
    public var categoryRaw: String?
    /// The join demands use. Optional because rows written before the
    /// document schema have none until the migration assigns one.
    public var itemID: UUID?
    /// Serialized amounts added straight to the list, belonging to no recipe.
    public var manualQuantityData: Data = Data()
    /// Pre-document contributions, serialized `[ShoppingSource]`. Emptied by
    /// the migration that turns them into frozen demands.
    public var sourceData: Data = Data()
    public var isChecked: Bool = false
    /// Appeared after the same ingredient was already checked off.
    public var isLateAddition: Bool = false
    /// Set when "Erledigte entfernen" swept it off the list; the row stays
    /// as the document's memory instead of being deleted.
    public var clearedAt: Date?
    /// Position on the list. A timestamp is not enough: a whole recipe is
    /// added within the same millisecond, and its ingredients should keep the
    /// order they are written in.
    public var sortOrder: Int = 0
    public var addedAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(key: String, name: String, category: IngredientCategory?) {
        self.key = key
        self.name = name
        categoryRaw = category?.rawValue
        itemID = UUID()
    }

    public var manualQuantities: [Quantity] {
        get { (try? SousCoding.decoder.decode([Quantity].self, from: manualQuantityData)) ?? [] }
        set {
            manualQuantityData = (try? SousCoding.encoder.encode(newValue)) ?? Data()
            updatedAt = .nowInSyncPrecision
        }
    }

    /// The pre-document contributions still waiting for migration.
    public var legacySources: [ShoppingSource] {
        (try? SousCoding.decoder.decode([ShoppingSource].self, from: sourceData)) ?? []
    }

    /// The domain reading; demands are attached by the store, which knows
    /// the plan entries they derive against.
    public func domainValue(demands: [ShoppingDemand]) -> ShoppingItem {
        ShoppingItem(
            itemID: itemID ?? UUID(),
            key: key,
            name: name,
            category: categoryRaw.flatMap(IngredientCategory.init(rawValue:)),
            demands: demands,
            manualQuantities: manualQuantities,
            isChecked: isChecked,
            isLateAddition: isLateAddition,
            isCleared: clearedAt != nil
        )
    }
}
