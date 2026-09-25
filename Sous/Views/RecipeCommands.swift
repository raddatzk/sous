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
        CommandGroup(replacing: .printItem) {
            Button("Drucken …") { page?.print?() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(page?.print == nil)
        }
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
