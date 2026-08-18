import Foundation

/// The bits of parsing that every recipe format needs.
///
/// A yield and a duration arrive written by people — "4 Portionen", "1h
/// 30min" — or by machines, as ISO-8601 periods. Both Mela's files and
/// schema.org markup contain the same mixture, so the reading of them lives
/// in one place rather than once per format.
public enum RecipeFieldParsing {
    /// "4 Portionen", "4", "Für 4 Personen" — the first number in it.
    public static func servings(from text: String?) -> Int {
        guard let text, let match = text.firstMatch(of: /\d+/), let value = Int(match.0) else {
            return 2
        }
        return value.clamped(to: Recipe.servingsRange)
    }

    /// A duration as Mela may have stored it.
    ///
    /// Real exports carry "40min", "1h 30min", "20 Min", "5 Minuten", "95"
    /// and ISO-8601 periods from its web import, sometimes several of them
    /// in one field. Every number with its unit is therefore added up: a
    /// parser that stopped at the first one would read "1h 30min" as an
    /// hour and quietly lose half of every long recipe.
    public static func seconds(in text: String?) -> Int? {
        guard let text = nonEmpty(text) else { return nil }
        if let period = isoPeriodSeconds(text) { return period }

        var total = 0
        var found = false
        for match in text.matches(of: /(\d+)\s*([\p{L}.]*)/) {
            guard let value = Int(match.1) else { continue }
            let unit = String(match.2).lowercased().trimmingCharacters(in: .init(charactersIn: "."))
            let multiplier: Int
            // "std" before "s": both start the same way and mean very
            // different things.
            if unit.hasPrefix("h") || unit.hasPrefix("std") || unit.hasPrefix("stunde") {
                multiplier = 3600
            } else if unit.hasPrefix("sek") || unit.hasPrefix("sec") || unit == "s" {
                multiplier = 1
            } else if unit.isEmpty || unit.hasPrefix("m") {
                // A bare number in a time field means minutes.
                multiplier = 60
            } else {
                continue
            }
            total += value * multiplier
            found = true
        }
        return found && total > 0 ? total : nil
    }

    private static func isoPeriodSeconds(_ text: String) -> Int? {
        guard let match = text.firstMatch(
            of: /^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/.ignoresCase()
        ) else { return nil }
        let days = match.1.flatMap { Int($0) } ?? 0
        let hours = match.2.flatMap { Int($0) } ?? 0
        let minutes = match.3.flatMap { Int($0) } ?? 0
        let seconds = match.4.flatMap { Int($0) } ?? 0
        let total = days * 86400 + hours * 3600 + minutes * 60 + seconds
        return total > 0 ? total : nil
    }


    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
