import Foundation

/// Turns written instructions into steps, and back.
///
/// One step per line, because that is how instructions are typed and how
/// they are numbered when read back. Only markdown headings open a section —
/// a colon is far too common inside an instruction to mean anything.
public enum StepParser {
    public static func parse(_ text: String) -> [RecipeStep] {
        var result: [RecipeStep] = []
        var currentGroup: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                currentGroup = heading.isEmpty ? nil : heading
                continue
            }

            result.append(RecipeStep(
                id: StableID.make(namespace: "step", index: result.count, content: line),
                text: stripListMarker(from: line),
                group: currentGroup
            ))
        }
        return result
    }

    public static func text(for steps: [RecipeStep]) -> String {
        var lines: [String] = []
        var lastGroup: String??

        for step in steps {
            if lastGroup == nil || lastGroup! != step.group {
                if let group = step.group {
                    if !lines.isEmpty { lines.append("") }
                    lines.append("# \(group)")
                }
                lastGroup = step.group
            }
            lines.append(step.text)
        }
        return lines.joined(separator: "\n")
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
