import Foundation

/// What `RecipeEnrichmentStore` actually persists — the model's raw claim
/// about one quantity, deliberately not `ExtractedQuantity` itself.
///
/// `ExtractedQuantity` is shaped by `@Generable` for guided generation; this
/// is shaped by what a row on disk should look like. Keeping them separate
/// means the generation schema can change — a renamed field, a stricter
/// `@Guide` — without silently breaking recipes already cached under the
/// old shape.
public struct StoredAmountClaim: Codable, Sendable, Equatable {
    public var quantityText: String
    public var modifiedNoun: String
    public var kind: ExtractedAmountKind
    public var fractionValue: Double?
    public var stepNumber: Int

    public init(quantityText: String, modifiedNoun: String, kind: ExtractedAmountKind, fractionValue: Double?, stepNumber: Int) {
        self.quantityText = quantityText
        self.modifiedNoun = modifiedNoun
        self.kind = kind
        self.fractionValue = fractionValue
        self.stepNumber = stepNumber
    }

    public init(_ extracted: ExtractedQuantity) {
        self.init(
            quantityText: extracted.quantityText,
            modifiedNoun: extracted.modifiedNoun,
            kind: extracted.kind,
            fractionValue: extracted.fractionValue,
            stepNumber: extracted.stepNumber
        )
    }

    /// Back into the shape `AmountAIExtractor.mentions(from:steps:)` reads —
    /// the guard runs again on every read, cheap and pure, rather than
    /// trusting a stale conversion made at save time.
    public var asExtractedQuantity: ExtractedQuantity {
        ExtractedQuantity(
            quantityText: quantityText,
            modifiedNoun: modifiedNoun,
            kind: kind,
            fractionValue: fractionValue,
            stepNumber: stepNumber
        )
    }
}
