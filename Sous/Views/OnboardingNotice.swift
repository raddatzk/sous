import Observation
import SousKit
import SwiftUI

/// Whether this launch is somebody's first, and the welcome is owed.
///
/// The same shape `DataUpdateNotice` uses, and for the same reason: the
/// question is answered where the launch work happens — in the app, once the
/// migrations have run and the library has been read — and shown by the root,
/// which is the only view that outlives every section. A screen asking it for
/// itself would ask too early, find an empty library on a device that has one,
/// and welcome a cook who has been using the app for months.
///
/// The flag is device state rather than a setting: it says what this install
/// has already been told, not what anybody chose. So it goes into the app
/// group's defaults under a key of its own — the way `HouseholdSwitcher`
/// keeps the active household — and not into `SousSetting`, which is for
/// things the cook can change.
@MainActor
@Observable
final class OnboardingNotice {
    /// What the welcome was left holding when it closed.
    ///
    /// The buttons on the second page open a file dialog and the recipe
    /// editor — both of them sheets, and both presented by the very screen
    /// this one is covering. Presenting one out of a sheet that is still
    /// dismissing gets swallowed on iOS, so the intent is parked here and the
    /// root acts on it in `onDismiss`, once the welcome is actually gone.
    enum FollowUp {
        case importing
        case newRecipe
    }

    /// Whether the welcome is on screen. Settable, because the sheet's
    /// binding writes to it when the cook swipes it away.
    var isShowing = false
    /// What to do the moment it is off screen, if anything.
    var followUp: FollowUp?

    private static let defaultsKey = "didFinishOnboarding"

    /// Whether to welcome anybody, asked once per launch.
    ///
    /// An install that already carries recipes is not a first launch, whatever
    /// the flag says: the flag simply predates the feature, and greeting a
    /// full library with "Willkommen bei Sous" would be worse than never
    /// greeting anyone. Such a device is marked as welcomed and never asked
    /// again.
    ///
    /// A fresh install whose iCloud library has not arrived yet does see the
    /// welcome, and that is the right way round — the import lands behind it
    /// within seconds, and every page can be skipped.
    func decide(hasRecipes: Bool) {
        guard !UserDefaults.sous.bool(forKey: Self.defaultsKey) else { return }
        guard !hasRecipes else { return finish() }
        isShowing = true
    }

    /// The welcome is done with — however it was closed. Swiping it away
    /// counts: every page offers a way past it, so a cook who dismisses it
    /// has decided, and asking again next launch would be nagging.
    func finish() {
        isShowing = false
        UserDefaults.sous.set(true, forKey: Self.defaultsKey)
    }
}
