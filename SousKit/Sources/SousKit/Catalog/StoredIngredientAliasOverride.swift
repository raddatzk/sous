import Foundation
import SwiftData

/// One extra spelling the cook taught an ingredient that already exists.
///
/// Stored as a thin delta rather than as a copy of the whole entry: the
/// bundled catalog ships with the app and is replaced on every update, so an
/// added alias has to name its target by key and be merged back in at read
/// time. The target may just as well be one of the cook's own entries — an
/// override augments whichever entry currently answers to that name.
@Model
public final class StoredIngredientAliasOverride {
    #Index<StoredIngredientAliasOverride>([\.canonicalKey])

    /// The normalized name of the ingredient this alias points at, matching
    /// ``CatalogIngredient/key``.
    public var canonicalKey: String = ""
    /// The spelling as the cook wrote it — shown as-is, matched normalized.
    public var alias: String = ""
    public var createdAt: Date = Date.nowInSyncPrecision

    public init(canonicalKey: String, alias: String) {
        self.canonicalKey = canonicalKey
        self.alias = alias
    }
}
