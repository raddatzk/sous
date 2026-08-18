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
    /// Set to the bundle that has been prepared for saving.
    var export: RecipeExport?
}
