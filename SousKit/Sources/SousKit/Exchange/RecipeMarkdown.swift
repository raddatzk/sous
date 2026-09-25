import Foundation

/// A recipe as a Markdown file — for a notes app, a wiki or a message, where
/// it should read as a recipe with nothing but a text editor.
///
/// Plain on purpose: amounts are not bolded and nothing links back into the
/// app, so the file reads the same raw as rendered. A group heading in the
/// recipe's own text sits one level below the section it belongs to.
public enum RecipeMarkdown {
    public static func string(for document: RecipeDocument) -> String {
        var blocks: [String] = ["# \(inline(document.title))"]

        if let summary = document.summary {
            blocks.append(summary)
        }
        if !document.categories.isEmpty {
            blocks.append("*\(document.categories.map(inline).joined(separator: " · "))*")
        }
        blocks.append(document.factsLine)

        if !document.ingredientGroups.isEmpty {
            blocks.append("## Zutaten")
            for group in document.ingredientGroups {
                if let name = group.name { blocks.append("### \(inline(name))") }
                blocks.append(group.lines.map { line in
                    let words = [line.amount, line.text].filter { !$0.isEmpty }.joined(separator: " ")
                    return "- \(inline(words))"
                }.joined(separator: "\n"))
            }
        }

        if !document.stepGroups.isEmpty {
            blocks.append("## Zubereitung")
            for group in document.stepGroups {
                if let name = group.name { blocks.append("### \(inline(name))") }
                blocks.append(group.steps.map { step in
                    // Continuation lines indented under the text, so a step
                    // written over several lines stays one list item.
                    let text = inline(step.text)
                        .components(separatedBy: .newlines)
                        .joined(separator: "\n   ")
                    return "\(step.number). \(text)"
                }.joined(separator: "\n"))
            }
        }

        if let notes = document.notes {
            blocks.append("## Notizen")
            blocks.append(notes)
        }

        if let nutrition = document.nutrition {
            blocks.append("## Nährwerte")
            var caption = nutrition.caption
            if nutrition.isProvisional { caption += ", vorläufig" }
            blocks.append("*\(caption).*")
            blocks.append(nutrition.rows.map { row in
                "\(row.isIndented ? "  " : "")- \(row.label): \(row.value)"
            }.joined(separator: "\n"))
        }

        if let source = document.source {
            if let url = source.url {
                blocks.append("Quelle: [\(inline(source.name))](\(url.absoluteString))")
            } else {
                blocks.append(source.isGenerated ? source.name : "Quelle: \(inline(source.name))")
            }
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Text that has to stay text: a line that happens to start like a
    /// heading or a list, or brackets that would read as a link, are
    /// escaped. The rest is left alone — a file full of backslashes is no
    /// easier to read than one with a stray asterisk.
    static func inline(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "[]*_`<>".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        if let first = escaped.first, "#+-".contains(first) {
            escaped.insert("\\", at: escaped.startIndex)
        }
        return escaped
    }
}
