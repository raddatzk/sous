import Foundation

/// A size word standing between the amount and the name: "1 kleine
/// Zimtstange", "3 große EL Mandelmus".
///
/// It belongs to the measure, not to the name. Left where it was written it
/// glues itself onto the name the way "Blätter" and "Dose" did before they
/// became units — "kleine Zimtstange" is nothing the catalog knows, so the
/// line gets no nutrition and buys itself a shopping row of its own next to
/// the same ingredient written plainly. It is not a preparation either:
/// "gehackt" says what was done to the thing, "klein" says how much of it
/// there is.
///
/// The word is kept exactly as written so the line renders back as typed;
/// the ``Degree`` beside it is what a gram bridge can read, once there is
/// one that reads it.
public struct IngredientSize: Codable, Hashable, Sendable {
    public enum Degree: String, Codable, Hashable, Sendable {
        case small
        case medium
        case large
    }

    /// The word as written: "kleine", "kleiner", "mittelgroße".
    public var word: String
    public var degree: Degree

    public init(word: String, degree: Degree) {
        self.word = word
        self.degree = degree
    }

    /// Stems rather than every inflected form spelled out: German adjective
    /// declension is closed grammar, and "kleine", "kleiner", "kleines" and
    /// "kleinen" are one word four times over.
    ///
    /// Comparatives fall out on their own — "größer" does not start with
    /// "groß" — which is the right answer: "2 größere Zwiebeln" says larger
    /// than what, and nothing here knows.
    private static let stems: [(stem: String, degree: Degree)] = [
        ("mittelgroß", .medium),
        ("mittelgross", .medium),
        ("mittler", .medium),
        ("klein", .small),
        ("groß", .large),
        ("gross", .large),
    ]

    /// The endings an attributive adjective takes. The bare stem is absent
    /// on purpose: "1 klein Zwiebel" is not something anyone writes, and
    /// leaving it out keeps a stem from swallowing a name that merely
    /// starts like one.
    private static let endings: Set<String> = ["e", "er", "es", "en"]

    /// The size a single word names, `nil` for anything outside the
    /// vocabulary.
    public init?(word: String) {
        let written = word.trimmingCharacters(in: .whitespaces)
        let normalized = written.lowercased()
        for (stem, degree) in Self.stems where normalized.hasPrefix(stem) {
            guard Self.endings.contains(String(normalized.dropFirst(stem.count))) else { continue }
            self.init(word: written, degree: degree)
            return
        }
        return nil
    }
}
