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
    /// A recipe name on a chip: the switcher at the foot of cook mode.
    static let recipeChip = Font.system(.subheadline, design: .serif, weight: .semibold)

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

    /// The box a field of chips sits in — the search field, the category
    /// field. Written once because the two are the same control doing two
    /// different jobs, and a difference in padding between them would read
    /// as a mistake rather than a distinction.
    func sousFieldBox() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.sousField, in: .rect(cornerRadius: 12))
    }

    /// A value sitting inside such a field: a filter, a category.
    func sousChip() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.tint.opacity(SousStyle.chipTint), in: .capsule)
            .foregroundStyle(.tint)
    }

    /// A value being offered rather than held — the suggestions under a
    /// field. Neutral, because taking the offer is what tints it.
    func sousSuggestionChip() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.sousField, in: .capsule)
    }
}

/// How much room a sheet needs, said once so that ten sheets do not each
/// invent their own numbers.
///
/// Every sheet used to name a minimum size for the Mac and a detent for the
/// phone by hand, which is how the recipe editor ended up opening at half
/// height on the iPad and nobody noticed: the decision was made ten times,
/// so it could be wrong in one place while looking right in the other nine.
enum SousSheetSize {
    /// One question with one or two controls: a duration, a serving count.
    case question
    /// A form to fill in, or a short list to pick from.
    case form
    /// Something worked on at length: the editor, a whole catalogue.
    case page
}

extension View {
    /// Sizes a sheet for whichever device it opens on.
    ///
    /// Three mechanisms, because the platforms disagree about what a sheet
    /// is: the Mac wants a minimum window size, the phone a detent it can be
    /// dragged between, and the iPad a presentation size — a form sheet there
    /// otherwise stops well short of the window no matter what the detents
    /// say. The detent and the presentation size can both be stated, since
    /// each is ignored where the other applies.
    @ViewBuilder
    func sousSheetSizing(_ size: SousSheetSize) -> some View {
        #if os(macOS)
        switch size {
        case .question: frame(minWidth: 340, minHeight: 320)
        case .form: frame(minWidth: 380, minHeight: 480)
        case .page: frame(minWidth: 520, minHeight: 620)
        }
        #else
        switch size {
        case .question:
            presentationDetents([.height(300)])
                .presentationSizing(.form)
        case .form:
            presentationDetents([.medium])
                .presentationSizing(.form)
        case .page:
            // Deliberately only `.large`: a set of detents is unordered, so
            // adding `.medium` does not offer a bigger sheet, it gambles on
            // which one opens.
            presentationDetents([.large])
                .presentationSizing(.page)
        }
        #endif
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

    /// The warm red the app is built around.
    ///
    /// The same two values as the `AccentColor` asset, written out because a
    /// colour handed to a Live Activity is resolved in the widget's process —
    /// and an asset reference there finds no asset, falling back to system
    /// blue in the middle of an orange app.
    static var sousAccent: Color {
        adaptive(
            light: Color(red: 0.706, green: 0.271, blue: 0.118),
            dark: Color(red: 0.929, green: 0.451, blue: 0.278)
        )
    }

    /// A block set apart from the page: the servings control, a banner.
    static var sousSurface: Color {
        adaptive(light: .black.opacity(0.05), dark: .white.opacity(0.09))
    }

    /// A field or a neutral chip the reader can tap.
    static var sousField: Color {
        adaptive(light: .black.opacity(0.07), dark: .white.opacity(0.13))
    }

    /// A bar docked against the keyboard. Opaque rather than a material:
    /// sitting right on the keyboard, a material picks up its grey and
    /// leaves `sousField` chips barely readable on top.
    static var sousBar: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
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

    /// A category's own colour, stable across launches and devices.
    ///
    /// Categories are free text — "Fleisch", "Suppen", whatever a recipe
    /// happens to be filed under — so there is no fixed list to hand-pick
    /// colours for. A hash of the name picks a hue instead: the same name
    /// always lands on the same colour, without anything to store. `String`
    /// itself cannot be used for this — `Hashable`'s seed is randomised
    /// per launch, so the same category would change colour every time the
    /// app opened.
    static func sousCategory(_ name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360
        return adaptive(
            light: Color(hue: hue, saturation: 0.55, brightness: 0.5),
            dark: Color(hue: hue, saturation: 0.5, brightness: 0.85)
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
