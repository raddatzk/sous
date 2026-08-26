import Foundation
import SwiftData

/// **Legacy.** The vocabulary entity absorbed this, as this comment already
/// announced it would. Kept in the schema so the migration can read it.
///
/// The cook's mark that an ingredient is a pantry staple — salt, oil, flour:
/// things checked against the shelf, not hunted through the store.
///
/// Stored as a thin, name-keyed row after the pattern of
/// ``StoredIngredientAliasOverride``: the bundled catalog is replaced on
/// every app update, so the flag names its ingredient by key and is merged
/// back in at read time. The vocabulary entity of a later phase absorbs it.
@Model
public final class StoredPantryFlag {
    #Index<StoredPantryFlag>([\.key])

    /// The normalized ingredient name, matching ``ShoppingItem/key``.
    public var key: String = ""
    public var createdAt: Date = Date.nowInSyncPrecision

    public init(key: String) {
        self.key = key
    }
}
