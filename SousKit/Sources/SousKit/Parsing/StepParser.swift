import Foundation

/// Turns written instructions into steps, and back.
///
/// One step per line, because that is how instructions are typed and how
/// they are numbered when read back. Only markdown headings open a section —
/// a colon is far too common inside an instruction to mean anything.
public enum StepParser {
    public static func parse(_ text: String) -> [RecipeStep] {
        var result: [RecipeStep] = []
        for written in writtenLines(in: text) {
            let text = stripListMarker(from: written.text)
            result.append(RecipeStep(
                id: StableID.make(namespace: "step", index: result.count, content: written.text),
                text: text,
                group: written.group,
                // A time written into the step is a timer the cook mode can
                // offer, without asking for the same number twice.
                durationSeconds: DurationParser.seconds(in: text)
            ))
        }
        return result
    }

    /// The step lines as written, trimmed, each with its section and where
    /// it stands in the text — the n-th of these is the n-th step.
    public static func writtenLines(in text: String) -> [(text: String, group: String?, textLine: Int)] {
        var result: [(text: String, group: String?, textLine: Int)] = []
        var currentGroup: String?

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                currentGroup = heading.isEmpty ? nil : heading
                continue
            }
            result.append((line, currentGroup, index))
        }
        return result
    }

    /// Removes "1. ", "2) " or "- " — the view numbers the steps itself, and
    /// a pasted list should not end up numbered twice.
    private static func stripListMarker(from line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return line }
        let rest = line[digits.endIndex...]
        guard let separator = rest.first, separator == "." || separator == ")" else { return line }
        return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}
