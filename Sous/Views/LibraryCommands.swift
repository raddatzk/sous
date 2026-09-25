import Observation
import SwiftUI

/// What the menu bar can ask of the recipe library.
///
/// A menu command lives in the scene and the screens it opens live in the
/// recipe list — the two cannot reach each other's state. So the intent sits
/// here, in the app: the command sets it and the list, which owns the sheets
/// and the file dialogs, acts on it. The toolbar's own menu sets exactly the
/// same values, so both paths lead to one place.
///
/// The same shape `RecipeLibrary.editing` already uses for "a recipe is being
/// edited", and deliberately not in SousKit: which panel is open is a window's
/// business, and `RecipeExport` is a file dialog's.
@MainActor
@Observable
final class LibraryCommands {
    /// The screens that manage the library rather than a recipe. One value
    /// rather than three flags, because only one sheet can be up at a time
    /// and three booleans would let the code claim otherwise.
    enum Panel: String, Identifiable {
        case catalog
        case categories
        case trash

        var id: String { rawValue }
    }

    var panel: Panel?
    /// Set while the importer's file dialog should be open.
    var isImporting = false
    /// Set by ⌘F until the recipe list's search field has taken the focus.
    /// The list may not be on screen yet when it is asked — the section is
    /// switched in the same breath — so it is a request the field picks up,
    /// not a focus binding the menu could set directly.
    var isSearchRequested = false
    /// The recipes ticked for a bulk action, or `nil` while the list is
    /// simply a list. Here rather than in the list itself, because the Mac
    /// starts it from the menu bar, which cannot see a view's state.
    var picked: Set<UUID>?
    /// Set to the bundle that has been prepared for saving.
    var export: RecipeExport?
    /// Files handed to the app from outside — "Öffnen mit Sous" in the Files
    /// app or the Finder, AirDrop — waiting for the importer to read them.
    var openedFiles: [URL] = []
    /// Whether the launch has got far enough to act on what arrived from
    /// outside.
    ///
    /// A file or a link can start the app, and its URL arrives while the
    /// stores are still being moved and the household is still being worked
    /// out — for that stretch the active household is forced to the cook's
    /// own, so an import would put the recipes in the wrong kitchen and a
    /// plan entry would be looked for in the wrong plan. Opened files and
    /// plan links wait until this is set.
    var isLaunchSettled = false
}
