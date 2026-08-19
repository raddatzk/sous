import Foundation

/// Scales amounts written into free text, so an instruction reading
/// "300 g Tomaten würfeln" follows the serving count the cook picked.
///
/// This is the fallback ``StepAmountResolver`` reaches for when it cannot
/// tie a written amount to a specific ingredient line — every recognized
/// unit still moves with the serving count, just without knowing which line
/// it came from. Only amounts carrying a known measurement unit are
/// touched, which rules out the two things that must never scale:
/// temperatures ("bei 180 Grad") and times ("20 Minuten"). A bare number is
/// left alone too — "in 2 Hälften schneiden" stays two halves however many
/// people are eating.
public enum AmountScaler {
    public static func scaled(
        _ text: String,
        by factor: Double,
        formatter: QuantityFormatter = QuantityFormatter()
    ) -> String {
        StepAmountResolver.blindlyScaled(text, by: factor, formatter: formatter)
    }
}
