import Foundation

/// How much of a demand is actually wanted right now.
///
/// Free of any persistence framework, because both stored forms of a demand
/// derive it. Captured × current/captured of the plan entry — frozen at the
/// check-off, and left alone entirely for non-scaling demands.
///
/// It is derived rather than stored for the reason the whole list works that
/// way: the captured amount and the plan entry's two portion counts are the
/// truth, and a third number written beside them could disagree with both.
public enum ShoppingDemandScaling {
    public static func effectiveQuantity(
        captured: Quantity?,
        scales: Bool,
        isScaleDiff: Bool,
        checkedAtServings: Int?,
        planEntry: ShoppingPlanEntry?
    ) -> Quantity? {
        guard let captured else { return nil }
        guard scales, !isScaleDiff, let planEntry, planEntry.servingsCaptured > 0 else { return captured }
        let target = checkedAtServings ?? planEntry.servingsCurrent
        return captured.scaled(by: Double(target) / Double(planEntry.servingsCaptured))
    }
}
