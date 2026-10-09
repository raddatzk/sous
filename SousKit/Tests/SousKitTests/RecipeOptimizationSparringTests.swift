import Foundation
import Testing
@testable import SousKit

/// Not a regression test — a measuring bench for the optimization prompt
/// (v3). It reads an export, writes the prompt Sous copies for a sample of
/// its recipes, and reads back whatever answers were saved beside them: which
/// answers pass, which checks fire, which lines change and how.
///
///     SOUS_OPTIMIZE_LIBRARY=/path/Rezepte.sousrecipes SOUS_OPTIMIZE_OUT=/path/out \
///         swift test --filter RecipeOptimizationSparring
///
/// Copy the export out of ~/Downloads first; reading it there can hang on
/// the privacy prompt. The sample is the titles in `SOUS_OPTIMIZE_TITLES`
/// (separated by "|"), filled up to `SOUS_OPTIMIZE_COUNT` (default 20) with
/// recipes drawn by `SOUS_OPTIMIZE_SEED` (default 17).
@Suite(
    "Optimization sparring",
    .enabled(if: ProcessInfo.processInfo.environment["SOUS_OPTIMIZE_LIBRARY"] != nil)
)
struct RecipeOptimizationSparringTests {
    @Test("Prompts for a sample of the export, and the answers read back")
    func bench() throws {
        let env = ProcessInfo.processInfo.environment
        guard let libraryPath = env["SOUS_OPTIMIZE_LIBRARY"], let outPath = env["SOUS_OPTIMIZE_OUT"] else { return }
        let url = URL(fileURLWithPath: (libraryPath as NSString).expandingTildeInPath)
        let recipes = try RecipeImport.read(Data(contentsOf: url), named: url.lastPathComponent).recipes.map(\.recipe)
            .filter { !$0.ingredients.isEmpty && !$0.steps.isEmpty }
            .sorted { $0.title < $1.title }

        let wanted = (env["SOUS_OPTIMIZE_TITLES"] ?? "").split(separator: "|").map(String.init)
        var sample = recipes.filter { wanted.contains($0.title) }
        var generator = SeededGenerator(seed: UInt64(env["SOUS_OPTIMIZE_SEED"] ?? "") ?? 17)
        let count = Int(env["SOUS_OPTIMIZE_COUNT"] ?? "") ?? 20
        for recipe in recipes.shuffled(using: &generator) where sample.count < count && !sample.contains(where: { $0.id == recipe.id }) {
            sample.append(recipe)
        }

        let out = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report = ""
        var summary = "n\tstatus\tlines\tchanged\tticked\trefused\tnewSteps\tgroups\tclassified\twarnings\ttitle\n"
        var issueCounts: [String: Int] = [:]
        var changeCounts: [String: Int] = [:]
        for (index, recipe) in sample.enumerated() {
            let n = index + 1
            try RecipeOptimizationPrompt.prompt(for: recipe).write(to: out.appendingPathComponent("\(n).prompt.txt"), atomically: true, encoding: .utf8)
            guard let pasted = try? String(contentsOf: out.appendingPathComponent("\(n).answer.txt"), encoding: .utf8) else { continue }

            report += "\n=== [\(n)] \(recipe.title)\n"
            let optimization: RecipeOptimization
            switch RecipeOptimizationPrompt.read(pasted, for: recipe) {
            case .success(let value): optimization = value
            case .failure(let failure):
                report += "  REFUSED: \(failure.localizedDescription)\n"
                summary += "\(n)\trefused: \(failure)\t\t\t\t\t\t\t\t\t\(recipe.title)\n"
                continue
            }
            for line in optimization.lines {
                for issue in line.issues { issueCounts[issueName(issue), default: 0] += 1 }
                guard line.isChanged || !line.issues.isEmpty else { continue }
                if line.isChanged { for change in line.changes { changeCounts[change.rawValue, default: 0] += 1 } }
                let mark = line.isRefused ? "✗" : line.isPreTicked ? "☑" : line.isChanged ? "☐" : "·"
                report += "  \(mark) Z\(line.number): \(line.written)\n"
                if line.isChanged {
                    report += "      → \(line.rewritten.isEmpty ? "(entfällt)" : line.rewritten.joined(separator: " | "))"
                    report += "  [\(line.changes.map(\.rawValue).sorted().joined(separator: ","))]\n"
                }
                if let note = line.note { report += "      Notiz: \(note)\n" }
                if let weighing = line.weighing { report += "      gewogen: \(weighing.from.amount) \(weighing.from.unit.symbol) → \(weighing.grams) g\n" }
                for typo in line.typos { report += "      Tippfehler: \(typo.wrong) → \(typo.right)\(typo.declared ? "" : " (unerklärt)")\n" }
                for issue in line.issues { report += "      ! \(issue)\n" }
            }
            for step in optimization.newSteps {
                report += "  + Schritt vor \(step.before.map(String.init) ?? "Ende"): \(step.text)\n"
            }
            for group in optimization.groups {
                report += "  # Gruppe \(group.name): \(group.action.rawValue) — \(group.reason ?? "")\n"
                if let variant = group.variant { report += "      Variante: \(variant.title); fremde Mengen: \(variant.foreignAmounts)\n" }
            }
            for item in optimization.classifications {
                report += "  ? \(item.name): \(item.kind.rawValue) \(item.target ?? "–")\(item.proposal.map { " → \($0.label)" } ?? "")\n"
            }
            for note in optimization.notes { report += "  Hinweis: \(note)\n" }
            let applied = optimization.applied(optimization.defaultSelection)
            let warnings = applied.reading?.warnings ?? []
            for warning in warnings { report += "  Warnung: \(warning)\n" }
            if applied.reading == nil { report += "  REFERENCES UNREADABLE after applying\n" }
            report += "  --- neu:\n" + applied.recipe.ingredientsText.split(separator: "\n").map { "    \($0)\n" }.joined()

            let lines = optimization.lines
            summary += "\(n)\tok\t\(lines.count)\t\(lines.filter(\.isChanged).count)\t\(lines.filter(\.isPreTicked).count)\t"
                + "\(lines.filter { $0.isChanged && $0.isRefused }.count)\t\(optimization.newSteps.count)\t"
                + "\(optimization.groups.count)\t\(optimization.classifications.count)\t\(warnings.count)\t\(recipe.title)\n"
        }
        let totals = "issues: \(issueCounts.sorted { $0.key < $1.key })\nchanges: \(changeCounts.sorted { $0.key < $1.key })\n"
        try (summary + "\n" + totals).write(to: out.appendingPathComponent("summary.tsv"), atomically: true, encoding: .utf8)
        try report.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(summary + "\n" + totals)
    }

    private func issueName(_ issue: RecipeOptimization.Line.Issue) -> String {
        String(describing: issue).prefix { $0 != "(" }.description
    }
}

/// SplitMix64 — the same sample on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
