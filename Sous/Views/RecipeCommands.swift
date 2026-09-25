import SousKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What the menu bar can do to the recipe page in front of the cook.
///
/// The page owns everything these act on — the serving count on screen, the
/// sheet the editor opens in, what "Kochen" starts with — so the page hands
/// its actions up rather than the menu reaching for `RecipeSelection`. A
/// scene value, because on the Mac the keyboard is almost never inside the
/// detail column: it sits in the sidebar's list while the page is read.
///
/// `nil` members are the menu's disabled items: a recipe in the trash can be
/// edited and printed, not favourited, trashed again or cooked.
struct RecipePageActions {
    typealias Action = @MainActor () -> Void

    var cook: Action?
    var edit: Action
    var print: Action?
    var servings: Int
    var setServings: @MainActor (Int) -> Void
    var isFavorite: Bool
    var toggleFavorite: Action?
    var trash: Action?
}

extension FocusedValues {
    /// Published by the recipe page on screen; see ``RecipePageActions``.
    @Entry var recipePage: RecipePageActions?
}

/// The recipe menu and the two standard File items that act on a recipe.
///
/// The shortcuts are the Mac's own where it has one — ⌘S, ⌘P, ⌘⌫ as in the
/// Finder, ⌘D as Safari's bookmark — and the iPad's menu bar gets the same.
struct RecipeCommands: Commands {
    @FocusedValue(\.recipePage) private var shownPage
    @FocusedValue(\.recipeEditor) private var editor

    /// The page, unless an editor is in front of it. ⌘D or ⌘⌫ there belong
    /// to the draft, and saving it would put back whatever the menu had just
    /// changed underneath. Decided here rather than by the page going quiet:
    /// with the editor's sheet in front, the menu goes on seeing what the
    /// page last published.
    private var page: RecipePageActions? { editor == nil ? shownPage : nil }
    private var save: (@MainActor () -> Void)? { editor?.save }

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Sichern") { save?() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(save == nil)
        }
        #if os(macOS)
        CommandGroup(replacing: .printItem) {
            Button("Drucken …") { page?.print?() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(page?.print == nil)
        }
        #endif
        CommandMenu("Rezept") {
            // The app's primary action, reachable without the mouse. ⌘⏎
            // rather than a letter, the way "do the thing" reads elsewhere.
            Button("Kochen") { page?.cook?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(page?.cook == nil)
            Button("Bearbeiten") { page?.edit() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(page == nil)
            Divider()
            // "+" and "-" as the German keyboard types them, unshifted.
            Button("Mehr Portionen") { step(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!canStep(by: 1))
            Button("Weniger Portionen") { step(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!canStep(by: -1))
            Divider()
            Button(page?.isFavorite == true ? "Aus Favoriten entfernen" : "Zu Favoriten") {
                page?.toggleFavorite?()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(page?.toggleFavorite == nil)
            Divider()
            Button("In den Papierkorb") { trash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(page?.trash == nil)
        }
    }

    private func canStep(by delta: Int) -> Bool {
        guard let page else { return false }
        return Recipe.servingsRange.contains(page.servings + delta)
    }

    private func step(by delta: Int) {
        guard let page, canStep(by: delta) else { return }
        page.setServings(page.servings + delta)
    }

    /// ⌘⌫ is also how a text field deletes back to the start of the line,
    /// and the menu sees the key before the field does. Typing in the search
    /// field and losing the recipe beside it would be a nasty surprise, so
    /// while text is being edited the key goes back to the text.
    private func trash() {
        #if os(macOS)
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
            return
        }
        #endif
        page?.trash?()
    }
}

#if os(macOS)
/// A recipe on paper, at the serving count on screen.
///
/// Laid out as text rather than as a rendering of the page: a text view
/// breaks pages between lines, where a picture of the page would be cut
/// through the middle of a step. Black on white whatever the window's
/// appearance — paper has no dark mode.
@MainActor
enum RecipePrinting {
    static func print(
        _ recipe: Recipe,
        servings: Int,
        times: [(label: String, value: String)]
    ) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        for side in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] {
            info[keyPath: side] = 56
        }
        let width = info.paperSize.width - info.leftMargin - info.rightMargin

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.isEditable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(document(recipe, servings: servings, times: times))
        // Through TextKit 2: reading `layoutManager` would switch the view to
        // TextKit 1 for good, which draws no `NSTextList` numbers.
        if let layout = view.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            view.frame.size.height = ceil(layout.usageBoundsForTextContainer.height)
        }

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = recipe.title
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private static func document(
        _ recipe: Recipe,
        servings: Int,
        times: [(label: String, value: String)]
    ) -> NSAttributedString {
        let formatter = QuantityFormatter(locale: .sous)
        let text = NSMutableAttributedString()

        text.append(paragraph(recipe.title, font: serif(22, .bold), after: 4))
        if let summary = recipe.summary, !summary.isEmpty {
            text.append(paragraph(summary, font: sans(11), color: .darkGray, after: 4))
        }
        let facts = ["\(servings) \(servings == 1 ? "Portion" : "Portionen")"]
            + times.map { "\($0.label) \($0.value)" }
        text.append(paragraph(facts.joined(separator: " · "), font: sans(10), color: .darkGray, after: 14))

        if !recipe.ingredients.isEmpty {
            text.append(heading("Zutaten"))
            for group in recipe.ingredientGroups(scaledToServings: servings) {
                if let name = group.group { text.append(subheading(name)) }
                for ingredient in group.ingredients {
                    let parts = IngredientLineView(ingredient: ingredient, formatter: formatter).plainParts
                    let line = NSMutableAttributedString()
                    if !parts.amount.isEmpty {
                        line.append(run(parts.amount + " ", font: sans(11, .semibold)))
                    }
                    line.append(run(parts.rest, font: sans(11)))
                    line.append(run("\n", font: sans(11)))
                    line.addAttribute(.paragraphStyle, value: style(after: 2), range: NSRange(location: 0, length: line.length))
                    text.append(line)
                }
            }
            text.append(spacer())
        }

        if !recipe.steps.isEmpty {
            text.append(heading("Zubereitung"))
            let rendition = recipe.stepRendition(toServings: servings, formatter: formatter)
            for group in recipe.stepGroups {
                if let name = group.group { text.append(subheading(name)) }
                // Numbering restarts per group, as it does on the page.
                for (index, step) in group.steps.enumerated() {
                    let line = NSMutableAttributedString(attributedString: run("\(index + 1).\t", font: serif(11, .bold)))
                    for segment in rendition.segments(for: step) {
                        switch segment {
                        case .text(let string): line.append(run(plain(string), font: sans(11)))
                        case .amount(let string): line.append(run(string, font: sans(11, .semibold)))
                        }
                    }
                    line.append(run("\n", font: sans(11)))
                    // A hanging indent, so a step's second line starts under
                    // its first word rather than under the number.
                    let hanging = style(after: 6)
                    hanging.headIndent = 20
                    hanging.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
                    line.addAttribute(.paragraphStyle, value: hanging, range: NSRange(location: 0, length: line.length))
                    text.append(line)
                }
            }
            text.append(spacer())
        }

        if let notes = recipe.notes, !notes.isEmpty {
            text.append(heading("Notizen"))
            text.append(paragraph(plain(notes), font: sans(11), after: 14))
        }

        if let source = recipe.source.url?.absoluteString ?? recipe.source.name {
            text.append(paragraph(source, font: sans(9), color: .gray, after: 0))
        }
        return text
    }

    private static func heading(_ string: String) -> NSAttributedString {
        paragraph(string, font: serif(15, .semibold), after: 6)
    }

    private static func subheading(_ string: String) -> NSAttributedString {
        paragraph(string, font: serif(12, .semibold), after: 3, before: 4)
    }

    private static func spacer() -> NSAttributedString {
        paragraph("", font: sans(6), after: 8)
    }

    private static func paragraph(
        _ string: String,
        font: NSFont,
        color: NSColor = .black,
        after: CGFloat,
        before: CGFloat = 0
    ) -> NSAttributedString {
        let paragraphStyle = style(after: after)
        paragraphStyle.paragraphSpacingBefore = before
        return NSAttributedString(string: string + "\n", attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ])
    }

    private static func run(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func style(after: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = after
        style.lineHeightMultiple = 1.1
        return style
    }

    private static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    private static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Markdown as the reader sees it: the emphasis marks and the link
    /// targets gone, the words kept.
    private static func plain(_ markdown: String) -> String {
        let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return parsed.map { String($0.characters) } ?? markdown
    }
}
#endif
