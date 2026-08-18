import Observation
import SwiftUI

/// Importing and exporting the whole library, as an intent rather than a
/// button.
///
/// On the Mac these belong in the Ablage menu, and a menu command lives in
/// the scene while the file dialogs live in the recipe list — the two cannot
/// reach each other's state. So the intent sits here, in the app: the command
/// sets it and the list, which owns the importer and exporter, acts on it.
///
/// The same shape `RecipeLibrary.editing` already uses for "a recipe is being
/// edited", and deliberately not in SousKit: `RecipeExport` is a file dialog's
/// concern, and the package has no business knowing about one.
@MainActor
@Observable
final class LibraryExchange {
    /// Set while the importer's file dialog should be open.
    var isImporting = false
    /// Set to the bundle that has been prepared for saving.
    var export: RecipeExport?
}
