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

    /// How wide a list of single-line rows may grow before the width stops
    /// helping and starts separating a row's two ends from each other.
    ///
    /// The recipe page's number for a readable single column, reused rather
    /// than guessed again: it is the same question asked of the same eyes.
    static let readableList: CGFloat = 700

    /// How much accent a tinted chip carries behind its label. One value
    /// so a filter chip and a recipe's category chip look like siblings.
    static let chipTint = 0.15

    /// A timer's remaining time, in cook mode. Rounded digits, because they
    /// are read from across the kitchen, and monospaced so the seconds do not
    /// make the minutes jump.
    static let timerReadout = Font.system(.title2, design: .rounded).monospacedDigit()

    /// The corners of a field, a surface, or a thumbnail large enough to
    /// read as one: the servings control, an image in the editor.
    static let fieldRadius: CGFloat = 12
    /// The corners of a small thumbnail beside a row — 44 points, where
    /// the field radius would round it into a coin.
    static let thumbnailRadius: CGFloat = 8
    /// The corners of a card that stands on the page: a recipe on the shelf,
    /// the import and export panels.
    static let cardRadius: CGFloat = 16
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
            .background(Color.sousField, in: .rect(cornerRadius: SousStyle.fieldRadius))
    }

    /// The heading of a group in a list — an aisle, a day, a category of
    /// ingredients. The serif the rest of the app names things in, and the
    /// system's capitals switched off, so a heading does not shout what the
    /// row below it says quietly.
    func sousGroupHeader() -> some View {
        font(SousStyle.groupHeading)
            .foregroundStyle(.primary)
            .textCase(nil)
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

    /// A chip that is both at once: tinted while it holds, neutral while it
    /// merely offers. The two states of anything that can be switched on and
    /// off by tapping it — a meal in the editor, a filter in the search.
    @ViewBuilder
    func sousToggleChip(isOn: Bool) -> some View {
        if isOn {
            sousChip()
        } else {
            sousSuggestionChip().foregroundStyle(.secondary)
        }
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

    /// Something that has run out or is about to be taken away: a timer past
    /// zero, the dial position that removes a row. The system red, named so
    /// that the five places that mean this say the same thing.
    static var sousDanger: Color { .red }

    /// Something to look at twice but not to fear: a figure computed from a
    /// proposal, a meal moved out of its day into the pool.
    static var sousCaution: Color { .orange }

    /// A favourite's star, and the swipe that sets it.
    static var sousStar: Color { .yellow }

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

/// Keeps a list readable when the window is far wider than a row needs.
///
/// A row that grows without limit puts the thing on its right — a recipe's
/// badges, the button that adds a meal to a day — an entire iPad away from
/// the name it belongs to, and the eye has to cross the gap to pair them up.
/// So the rows stop growing at the width the recipe page already settled on
/// for a single readable column, and what is left over becomes margin.
///
/// The margin goes on the scroll content rather than on the rows, so the
/// separators and the grouped background come in with them; insetting the
/// rows alone would leave a card the full width of the window with its
/// contents huddled in the middle of it.
///
/// All of it on the trailing side, so the list stays where it starts. Split
/// evenly it would centre the rows under a large navigation title that no
/// content inset reaches — the title stayed against the leading edge while
/// everything below it moved in, which reads as a mistake. Left where it is,
/// the list lines up with the title and with the filter chips above it, which
/// have been capped and pinned left for the same reason all along.
///
/// A no-op wherever the window is narrower than the cap, which is every
/// phone, the Mac's list column, and an iPad sharing its screen — the
/// measurement is of the list, not of the device.
private struct ReadableListWidth: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(
                .trailing,
                max(0, width - SousStyle.readableList),
                for: .scrollContent
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension View {
    /// See ``ReadableListWidth``.
    func sousReadableList() -> some View { modifier(ReadableListWidth()) }
}
