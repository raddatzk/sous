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

    /// How much accent a tinted chip carries behind its label. One value
    /// so a filter chip and a recipe's category chip look like siblings.
    static let chipTint = 0.15
}

extension View {
    /// A row of facts under the title: servings, times, categories.
    func metaLabel() -> some View {
        font(.footnote)
            .foregroundStyle(.secondary)
    }
}

extension Locale {
    /// The language the app is written in. A stand-in until it is localized:
    /// hard-coded German strings and system-locale dates do not mix.
    static let sous = Locale(identifier: "de_DE")
}

/// The surfaces the app draws on top of the system background.
///
/// These exist because `.quaternary` at a hand-picked opacity reads very
/// differently in the two schemes — dimming a fill that is already faint
/// leaves nothing visible in the dark. Each token names a job instead, and
/// carries its own value per scheme.
extension Color {
    /// The page colour behind a recipe, used to fade a hero image into it.
    static var sousBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// A block set apart from the page: the servings control, a banner.
    static var sousSurface: Color {
        adaptive(light: .black.opacity(0.05), dark: .white.opacity(0.09))
    }

    /// A field or a neutral chip the reader can tap.
    static var sousField: Color {
        adaptive(light: .black.opacity(0.07), dark: .white.opacity(0.13))
    }

    /// Dimming behind a progress card, strong enough to separate in the dark.
    static var sousScrim: Color {
        adaptive(light: .black.opacity(0.18), dark: .black.opacity(0.5))
    }

    /// The screen cook mode fills, edge to edge. Not pure black and not pure
    /// white: a hob-side screen at full contrast is tiring to read from.
    static var sousCookBackground: Color {
        adaptive(
            light: Color(red: 0.98, green: 0.97, blue: 0.96),
            dark: Color(red: 0.05, green: 0.05, blue: 0.06)
        )
    }

    /// One colour per scheme, resolved by the view it is drawn in — so a
    /// window pinned to light stays light inside a dark system.
    private static func adaptive(light: Color, dark: Color) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}
