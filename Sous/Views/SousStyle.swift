import SwiftUI

/// The app's own voice: a serif for names, the system sans for everything
/// read while cooking, and one warm accent.
///
/// Recipe titles are set in a serif because a recipe is a piece of writing
/// with a name, not a row in a list — it gives the app a face without costing
/// legibility, since instructions and amounts stay in the system sans, which
/// is what SF is good at.
enum SousStyle {
    /// The name of a recipe, at the top of its page.
    static let recipeTitle = Font.system(.largeTitle, design: .serif, weight: .bold)
    /// A recipe name in a list.
    static let recipeName = Font.system(.headline, design: .serif)
    /// Section headings inside a recipe: "Zutaten", "Zubereitung".
    static let sectionHeading = Font.system(.title2, design: .serif, weight: .semibold)
    /// The heading of a group within ingredients or steps.
    static let groupHeading = Font.system(.headline, design: .serif)
    /// The big step number in cook mode.
    static let stepNumber = Font.system(size: 40, weight: .bold, design: .serif)
}

extension View {
    /// A row of facts under the title: servings, times, categories.
    func metaLabel() -> some View {
        font(.footnote)
            .foregroundStyle(.secondary)
    }
}
