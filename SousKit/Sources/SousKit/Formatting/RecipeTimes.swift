import Foundation

/// A recipe's times as the cook reads them, in the order they happen.
///
/// One list for every place that shows them — the recipe page, the import
/// preview, the printout — so a total that is left out in one place is left
/// out in all of them.
public enum RecipeTimes {
    /// The times worth showing.
    ///
    /// "Gesamt" appears unless exactly one other time is shown: beside a
    /// single number it would mostly repeat it. Where it is all a recipe
    /// records, or beside two or more times, it is the figure the cook reads
    /// first.
    public static func items(for recipe: Recipe) -> [(label: String, value: String)] {
        var items: [(label: String, value: String)] = []
        if let prep = recipe.prepTimeSeconds, prep > 0 {
            items.append(("Vorbereitung", text(prep)))
        }
        if let cook = recipe.cookTimeSeconds, cook > 0 {
            items.append(("Zubereitung", text(cook)))
        }
        if let resting = recipe.restingTimeSeconds {
            items.append(("Ruhezeit", text(resting)))
        }
        if let elapsed = recipe.elapsedTimeSeconds, items.count != 1 {
            items.append(("Gesamt", text(elapsed)))
        }
        return items
    }

    /// Minutes up to an hour, then hours and minutes: "1:30 Std" is read at
    /// a glance where "90 Min" has to be divided first.
    public static func text(_ seconds: Int) -> String {
        let total = seconds / 60
        guard total >= 60 else { return "\(total) Min" }
        let rest = total % 60
        return rest == 0 ? "\(total / 60) Std" : String(format: "%d:%02d Std", total / 60, rest)
    }
}
