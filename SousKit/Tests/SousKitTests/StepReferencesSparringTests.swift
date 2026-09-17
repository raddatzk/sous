import Foundation
import Testing
@testable import SousKit

/// Not a regression test — a measuring bench for the paste prompt. It walks
/// a library dump (JSON of title, servings, ingredientsText,
/// instructionsText and the store's row key `pk`), writes the prompt Sous
/// copies for every recipe, and reads back whatever answers were saved
/// beside them — so a prompt change can be tried on real recipes with any
/// chat model, and the answers compared run against run.
///
///     SOUS_SPARRING=1 SOUS_LLM_LIBRARY=/path/library.json SOUS_LLM_PASTE_OUT=/path/out \
///         swift test --filter StepReferencesSparring
///
/// `SOUS_LLM_PICK=3,17,42` limits it to those indices of the dump.
@Suite(
    "Step references sparring",
    .enabled(if: ProcessInfo.processInfo.environment["SOUS_SPARRING"] == "1")
)
struct StepReferencesSparringTests {
    struct LibraryRecipe: Decodable {
        /// The store's row key, where the dump carries one.
        let pk: Int?
        let title: String
        let servings: Int?
        let ingredientsText: String?
        let instructionsText: String?
    }

    /// Writes the app's paste prompt per recipe to `SOUS_LLM_PASTE_OUT`, and
    /// where `<n>.answer.txt` sits beside it, what the app reads out of it:
    /// the references per step, the warnings and the model's notes, the
    /// stored JSON, and a line of counts per recipe.
    @Test("Paste prompts and pasted answers")
    func paste() throws {
        let env = ProcessInfo.processInfo.environment
        guard let libraryPath = env["SOUS_LLM_LIBRARY"], let outPath = env["SOUS_LLM_PASTE_OUT"] else { return }
        let picks = env["SOUS_LLM_PICK"]?.split(separator: ",").compactMap { Int($0) }
        let library = try JSONDecoder().decode([LibraryRecipe].self, from: Data(contentsOf: URL(fileURLWithPath: libraryPath)))
        try FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
        let formatter = QuantityFormatter()
        let out = URL(fileURLWithPath: outPath)

        var report = ""
        var summary = "index\tpk\tstatus\tfailure\tamounts\tamountsWithoutLine\tmentions\tnotInStep\tunreadable\toverbooked\ttitle\n"
        for (index, entry) in library.enumerated() where picks?.contains(index) ?? true {
            let recipe = Recipe(title: entry.title, servings: entry.servings ?? 2, ingredientsText: entry.ingredientsText ?? "", instructionsText: entry.instructionsText ?? "")
            let lines = recipe.ingredients
            let steps = recipe.steps
            guard !lines.isEmpty, !steps.isEmpty else { continue }
            try StepReferencesPrompt.prompt(for: recipe).write(to: out.appendingPathComponent("\(index).prompt.txt"), atomically: true, encoding: .utf8)

            let answerURL = out.appendingPathComponent("\(index).answer.txt")
            guard let pasted = try? String(contentsOf: answerURL, encoding: .utf8) else { continue }
            report += "\n=== [\(index)] \(recipe.title) (\(recipe.servings) Portionen)\n"
            for (lineIndex, line) in lines.enumerated() {
                report += "  Z\(lineIndex + 1): \(formatter.string(for: line))\n"
            }
            let reading: StepReferencesPrompt.Reading
            switch StepReferencesPrompt.read(pasted, for: recipe) {
            case .success(let value): reading = value
            case .failure(let failure):
                report += "  ABGELEHNT: \(failure.localizedDescription)\n"
                summary += "\(index)\t\(entry.pk ?? -1)\trefused\t\(failure)\t\t\t\t\t\t\(entry.title)\n"
                continue
            }
            // What the app would store, for writing straight into a store, and
            // one line of counts per recipe for the overview.
            if let json = StepReferences.encode(reading.references) {
                try json.write(to: out.appendingPathComponent("\(index).references.json"), atomically: true, encoding: .utf8)
            }
            let all = reading.references.steps.flatMap { $0 }
            var counts = [0, 0, 0, 0, 0, 0]
            for reference in all {
                switch (reference.kind, reference.line) {
                case (.amount, .some): counts[0] += 1
                case (.amount, .none): counts[1] += 1
                case (.mention, _): counts[2] += 1
                }
            }
            for warning in reading.warnings {
                switch warning {
                case .notInStep: counts[3] += 1
                case .unreadableAmount: counts[4] += 1
                case .overbooked: counts[5] += 1
                }
            }
            summary += "\(index)\t\(entry.pk ?? -1)\tok\t\t\(counts.map(String.init).joined(separator: "\t"))\t\(entry.title)\n"
            for (stepIndex, step) in steps.enumerated() {
                let references = reading.references.steps[stepIndex]
                    .map { "\($0.kind == .amount ? "menge" : "bezug")\($0.text.isEmpty ? "" : " „\($0.text)“") → \($0.line.map { "Z\($0)" } ?? "—")\($0.amount.map { " \($0)" } ?? "")" }
                    .joined(separator: "; ")
                report += "\n  S\(stepIndex + 1): \(step.text)\n    \(references.isEmpty ? "—" : references)\n"
            }
            report += "\n  Warnungen: \(reading.warnings.isEmpty ? "keine" : reading.warnings.map { "\($0)" }.joined(separator: "; "))\n"
            report += "  Hinweise: \(reading.notes.isEmpty ? "keine" : reading.notes.joined(separator: " | "))\n"
        }
        try report.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try summary.write(to: out.appendingPathComponent("summary.tsv"), atomically: true, encoding: .utf8)
    }
}
