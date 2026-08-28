import Foundation

/// How a portion count is written out.
///
/// One is not an edge case anywhere here: `Recipe.servingsRange` starts at
/// one, a recipe written for one person is ordinary, and the shopping list's
/// dial now rests on one rather than passing through it. So the German
/// singular has to be right — and the places that print the number say it
/// through here rather than each spelling out a plural that only one of them
/// got round to.
///
/// Deliberately not a `Formatter`: there is nothing locale-dependent to
/// resolve while the whole app is German (see `RootView`'s `.locale`), and a
/// formatter would promise otherwise. When the app is localized this is one
/// of the strings that has to become a stringsdict entry, and standing in one
/// place is what makes that cheap.
public enum Servings {
    /// "1 Portion", "4 Portionen".
    public static func text(_ count: Int) -> String {
        count == 1 ? "1 Portion" : "\(count) Portionen"
    }
}
