import Foundation

/// Reading and writing the numbers a cook types into a field.
///
/// Two lines that were written twice already and were about to be written a
/// third time, for the measure fields. A German keyboard offers a comma and
/// `Double` only reads a point; a whole number reads better without a decimal
/// place after it.
enum DecimalText {
    /// What was typed, or `nil` when the field is empty or unreadable.
    static func number(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return normalized.isEmpty ? nil : Double(normalized)
    }

    /// A value as it should appear in a field to be edited — not formatted
    /// for reading, which is `NutrientFormatter`'s job.
    static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Blank for anything at or below zero: in a form, "did not say" and
    /// "said zero" have to stay apart.
    static func optionalText(_ value: Double) -> String {
        value > 0 ? text(value) : ""
    }
}
