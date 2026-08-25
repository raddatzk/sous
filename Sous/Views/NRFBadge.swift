import SousKit
import SwiftUI

/// A recipe's nutrient-density rating, read as a letter and a colour rather
/// than the raw NRF9.3 score — nobody has that scale memorized.
///
/// Shaped as a filled circle rather than Nutri-Score's familiar horizontal
/// bar on purpose: the two are easy to mix up otherwise, and this is a
/// different formula (nutrient density per calorie) wearing similar traffic
/// -light colours, not an actual Nutri-Score rating.
struct NRFBadge: View {
    let level: NRFLevel

    private var tint: Color {
        switch level {
        case .a: Color(red: 0.16, green: 0.5, blue: 0.16)
        case .b: Color(red: 0.42, green: 0.66, blue: 0.2)
        case .c: Color(red: 0.85, green: 0.72, blue: 0.13)
        case .d: Color(red: 0.87, green: 0.51, blue: 0.15)
        case .e: Color(red: 0.78, green: 0.24, blue: 0.2)
        }
    }

    var body: some View {
        Text(level.letter)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint, in: .circle)
            .accessibilityLabel(level.label)
    }
}
