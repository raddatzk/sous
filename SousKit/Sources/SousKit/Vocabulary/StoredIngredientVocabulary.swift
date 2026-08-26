import Foundation
import SwiftData

/// One vocabulary entry, persisted.
///
/// CloudKit-shaped like everything else in this store: no SwiftData
/// relationships, joins by UUID and string, every property defaulted. The
/// variant relation is a `parentID` rather than a reference for exactly that
/// reason — and because a name is a thing that changes, while an identity is
/// not.
///
/// The two blobs are the compromise the shape forces: a dictionary of bases
/// per state and a dictionary of unit weights are not columns, and modelling
/// them as further entities would buy queryability nothing here ever asks
/// for. They are read and written whole, with the entry.
@Model
public final class StoredIngredientVocabulary {
    #Index<StoredIngredientVocabulary>([\.key], [\.parentID])

    public var id: UUID = UUID()
    /// The normalized name — the join from recipe text, and what makes an
    /// entry findable before its id is known.
    public var key: String = ""
    public var name: String = ""
    public var aliases: [String] = []
    /// `nil` where the cook has not overridden the aisle.
    public var categoryRaw: String?
    /// The entry this is a variety of. One level: nothing sets a parent on
    /// an entry that is itself a variant.
    public var parentID: UUID?
    /// Whether the cook created this ingredient, as opposed to leaving a note
    /// on a shipped one. What used to be the whole of `StoredCatalogIngredient`.
    public var isOwnIngredient: Bool = false
    /// What used to be `StoredPantryFlag`, whose doc comment already said a
    /// later phase's vocabulary entity would absorb it.
    public var isPantry: Bool = false
    /// The phase-3 stamp, carried over and finally read: a name whose link
    /// into the shipped world could never be established is a question for
    /// the cook, and this is what puts it on the list of them.
    public var needsBasisReview: Bool = false
    /// Serialized `[String: BasisAssignment]`, keyed by `IngredientState.rawValue`.
    public var basisData: Data = Data()
    /// Serialized `[String: Double]`, keyed by `IngredientUnit.symbol`.
    public var unitWeightData: Data = Data()
    public var createdAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    public var bases: [String: BasisAssignment] {
        get { (try? SousCoding.decoder.decode([String: BasisAssignment].self, from: basisData)) ?? [:] }
        set {
            basisData = (try? SousCoding.encoder.encode(newValue)) ?? Data()
            updatedAt = .nowInSyncPrecision
        }
    }

    public var unitWeightsGrams: [String: Double] {
        get { (try? SousCoding.decoder.decode([String: Double].self, from: unitWeightData)) ?? [:] }
        set {
            unitWeightData = (try? SousCoding.encoder.encode(newValue)) ?? Data()
            updatedAt = .nowInSyncPrecision
        }
    }

    /// The domain reading. The parent's *name* is resolved by the store,
    /// which is the only place that can see the other row.
    public func domainValue(parentName: String?) -> IngredientVocabularyEntry {
        IngredientVocabularyEntry(
            id: id,
            name: name,
            aliases: aliases,
            category: categoryRaw.flatMap(IngredientCategory.init(rawValue:)),
            parentName: parentName,
            isOwnIngredient: isOwnIngredient,
            isPantry: isPantry,
            unitWeightsGrams: unitWeightsGrams,
            bases: bases,
            needsBasisReview: needsBasisReview,
            updatedAt: updatedAt
        )
    }

    /// Writes everything but the identity and the parent join, which the
    /// store owns.
    public func apply(_ entry: IngredientVocabularyEntry) {
        key = entry.key
        name = entry.name
        aliases = entry.aliases
        categoryRaw = entry.category?.rawValue
        isOwnIngredient = entry.isOwnIngredient
        isPantry = entry.isPantry
        needsBasisReview = entry.needsBasisReview
        bases = entry.bases
        unitWeightsGrams = entry.unitWeightsGrams
        updatedAt = .nowInSyncPrecision
    }
}
