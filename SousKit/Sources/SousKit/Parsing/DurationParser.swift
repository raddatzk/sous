import Foundation

/// Finds a duration written into an instruction, so the cook mode can offer
/// a timer for "30 Minuten backen" without the user entering it twice.
public enum DurationParser {
    /// The first duration mentioned, in seconds.
    ///
    /// The first rather than the longest: instructions are written in the
    /// order things happen, so the first is the one about to be needed.
    public static func seconds(in text: String) -> Int? {
        let pattern = /(\d+)\s*(Sekunden|Sekunde|Sek\.?|Minuten|Minute|Min\.?|Stunden|Stunde|Std\.?|h\b)/
            .ignoresCase()

        guard let match = text.firstMatch(of: pattern),
              let value = Int(match.1)
        else { return nil }

        let unit = String(match.2).lowercased()
        let multiplier: Int = if unit.hasPrefix("sek") {
            1
        } else if unit.hasPrefix("std") || unit.hasPrefix("stunde") || unit == "h" {
            3600
        } else {
            60
        }
        return value * multiplier
    }
}
