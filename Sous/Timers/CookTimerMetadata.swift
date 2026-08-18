#if os(iOS)
import AlarmKit
import Foundation

/// What a timer says about itself on the lock screen.
///
/// Shared between the app and the widget, and carried by the alarm rather
/// than looked up: the Live Activity draws when the app is not running, so
/// there is no recipe on screen to read the name off.
nonisolated struct CookTimerMetadata: AlarmMetadata {
    /// The dish this belongs to — the cook may have two on the go.
    var recipeTitle: String
    /// The step's number as the cook sees it.
    var stepNumber: Int

    init(recipeTitle: String, stepNumber: Int) {
        self.recipeTitle = recipeTitle
        self.stepNumber = stepNumber
    }
}
#endif
