import Foundation

/// What one recipe line wants of one ingredient, as captured at add time.
///
/// Demands stay single rows — they are never summed into each other when
/// stored. The bundling the list shows happens at display time, so every
/// contribution keeps its origin and can be re-derived when the plan entry's
/// portion count changes.
public struct ShoppingDemand: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The plan entry this demand scales with. `nil` means frozen: the
    /// amount stands as written and no portion stepper reaches it — manual
    /// migration leftovers and lapsed remains live here.
    public var planEntryID: UUID?
    /// The recipe line it was captured from, for telling two lines of the
    /// same ingredient apart. Meaningless outside the capture — recipe edits
    /// never reach the list.
    public var lineID: UUID?
    /// Where the demand reads as coming from — the subrecipe's title when a
    /// linked recipe was resolved, even though it scales with the parent's
    /// plan entry.
    public var originTitle: String
    /// The ingredient exactly as the recipe wrote it.
    ///
    /// Capture replaces the written name with the catalog's for the item's
    /// heading, which is right for the heading and destroys the very thing a
    /// variety sub-line has to say: "200 g Cocktailtomaten", not "200 g
    /// Tomaten". Kept here so the distinction survives the moment of adding,
    /// which is the only moment it could be lost in.
    public var writtenName: String
    /// The amount as captured, at the plan entry's captured portion count.
    /// `nil` is an unquantified demand ("Salz nach Geschmack").
    public var quantity: Quantity?
    /// What the demand is worth right now: captured × current/captured of
    /// its plan entry, frozen at the check-off for checked items. Filled
    /// when the list is read; equals `quantity` for everything frozen.
    public var effectiveQuantity: Quantity?
    /// Whether the line's amount refers to the ingredient raw or cooked —
    /// carried for annotation, ignored in bundling.
    public var state: IngredientState
    /// Seasoning does not scale with servings, and neither do unquantified
    /// or raw-text demands.
    public var scales: Bool
    /// Appended after the list already knew this recipe — a re-add, not the
    /// first capture.
    public var isLate: Bool
    /// Created by the portion stepper to cover the difference an already
    /// checked item cannot absorb. Holds its amount literally and is
    /// recomputed, not scaled.
    public var isScaleDiff: Bool
    /// The plan entry's portion count at the moment the item was checked
    /// off. While set, the effective amount stops following the stepper —
    /// what is in the basket does not change size anymore.
    public var checkedAtServings: Int?
    /// The part of a checked demand that is no longer wanted after scaling
    /// down — annotated, because un-checking is not ours to do.
    public var lapsedQuantity: Quantity?
    /// No longer wanted at all — its plan entry was removed while the item
    /// was already checked. Rendered struck through rather than deleted.
    public var isLapsed: Bool

    public init(
        id: UUID = UUID(),
        planEntryID: UUID? = nil,
        lineID: UUID? = nil,
        originTitle: String = "",
        writtenName: String = "",
        quantity: Quantity? = nil,
        effectiveQuantity: Quantity? = nil,
        state: IngredientState = .unspecified,
        scales: Bool = true,
        isLate: Bool = false,
        isScaleDiff: Bool = false,
        checkedAtServings: Int? = nil,
        lapsedQuantity: Quantity? = nil,
        isLapsed: Bool = false
    ) {
        self.id = id
        self.planEntryID = planEntryID
        self.lineID = lineID
        self.originTitle = originTitle
        self.writtenName = writtenName
        self.quantity = quantity
        self.effectiveQuantity = effectiveQuantity ?? quantity
        self.state = state
        self.scales = scales
        self.isLate = isLate
        self.isScaleDiff = isScaleDiff
        self.checkedAtServings = checkedAtServings
        self.lapsedQuantity = lapsedQuantity
        self.isLapsed = isLapsed
    }
}
