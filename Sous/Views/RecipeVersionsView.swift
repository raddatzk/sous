import SousKit
import SwiftUI

/// "Versionen": the recipe's earlier versions and its original, each to read,
/// to compare with another, and to go back to.
///
/// A version is kept whenever the content changes — an edit saved in the
/// editor, a chat model's rewrite, an optimization, a restore — so a slip
/// of the keyboard is as easy to take back as a rewrite nobody liked. The
/// recipe page itself shows only the current version; this is where the
/// others live, because they are looked at rarely.
struct RecipeVersionsView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    let recipeID: UUID

    private var recipe: Recipe? { library.recipes.first { $0.id == recipeID } }

    var body: some View {
        NavigationStack {
            Group {
                if let recipe {
                    list(recipe)
                } else {
                    ContentUnavailableView("Rezept nicht gefunden", systemImage: "questionmark.folder")
                }
            }
            .navigationTitle("Versionen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let recipe, let version = recipe.versions.first(where: { $0.id == id }) {
                    RecipeVersionPage(recipe: recipe, version: version) { dismiss() }
                }
            }
        }
        .sousSheetSizing(.page)
    }

    private func list(_ recipe: Recipe) -> some View {
        let versions = recipe.versions
        let earlier = versions.filter { if case .earlier = $0.kind { true } else { false } }
        let original = versions.first { $0.kind == .original }
        return Form {
            Section {
                row(versions[0], in: versions)
            } footer: {
                Text("Eine Version entsteht bei jeder Änderung des Inhalts: beim Speichern im Editor, bei einer KI-Änderung, beim Optimieren und beim Wiederherstellen. Sous behält die letzten \(RecipeOriginal.historyLimit).")
            }
            if !earlier.isEmpty {
                Section("Frühere Versionen") {
                    ForEach(earlier) { row($0, in: versions) }
                }
            }
            if let original {
                Section {
                    row(original, in: versions)
                } footer: {
                    Text("So kam das Rezept in die App.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ version: RecipeVersion, in versions: [RecipeVersion]) -> some View {
        NavigationLink(value: version.id) {
            VStack(alignment: .leading, spacing: 2) {
                Text(version.label(in: versions))
                if let detail = version.detail(in: versions) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One version: read as the recipe page would show it, or compared with
/// another version line by line, and brought back.
private struct RecipeVersionPage: View {
    @Environment(RecipeLibrary.self) private var library

    let recipe: Recipe
    let version: RecipeVersion
    /// Closes the versions sheet once a version is back.
    let onRestored: () -> Void

    @State private var comparedID: String?
    @State private var isConfirmingRestore = false

    private var versions: [RecipeVersion] { recipe.versions }

    var body: some View {
        Form {
            Section {
                Picker("Vergleichen mit", selection: $comparedID) {
                    Text("Nicht vergleichen").tag(String?.none)
                    ForEach(versions.filter { $0.id != version.id }) { other in
                        Text(other.label(in: versions)).tag(Optional(other.id))
                    }
                }
            }
            if let comparedID, let other = versions.first(where: { $0.id == comparedID }) {
                comparison(with: other)
            } else {
                content
            }
            if version.kind != .current {
                Section {
                    Button("Diese Version wiederherstellen", systemImage: "arrow.uturn.backward") {
                        isConfirmingRestore = true
                    }
                } footer: {
                    Text("Die aktuelle Fassung bleibt als frühere Version erhalten.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(version.label(in: versions))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            // The obvious question first: for the current version, what the
            // last change did; for any other, how it differs from now.
            guard comparedID == nil else { return }
            comparedID = version.kind == .current ? versions.dropFirst().first?.id : versions.first?.id
        }
        .sousConfirmation(
            "Diese Version wiederherstellen?",
            isPresented: $isConfirmingRestore,
            message: "Das Rezept steht dann wieder so da. Die aktuelle Fassung bleibt als frühere Version erhalten."
        ) {
            Button("Wiederherstellen") {
                Task {
                    if await library.restore(version, of: recipe) { onRestored() }
                }
            }
        }
    }

    // MARK: - Reading

    @ViewBuilder
    private var content: some View {
        let shown = version.applied(to: recipe)
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(shown.title).font(.headline)
                if let summary = shown.summary, !summary.isEmpty {
                    Text(summary).foregroundStyle(.secondary)
                }
                Text(shown.servings == 1 ? "1 Portion" : "\(shown.servings) Portionen")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        Section("Zutaten") { IngredientsPreview(recipe: shown) }
        Section("Zubereitung") { StepsPreview(recipe: shown) }
        if let notes = shown.notes, !notes.isEmpty {
            Section("Notizen") { Text(notes) }
        }
    }

    // MARK: - Comparing

    /// Always from the older version to the newer one, whichever was opened:
    /// "added" then means what came later, as one reads a history.
    @ViewBuilder
    private func comparison(with other: RecipeVersion) -> some View {
        let order = versions.map(\.id)
        let thisIndex = order.firstIndex(of: version.id) ?? 0
        let otherIndex = order.firstIndex(of: other.id) ?? 0
        // Lower index is newer.
        let (older, newer) = thisIndex > otherIndex ? (version, other) : (other, version)
        let difference = RecipeVersionDifference(from: older, to: newer)
        Section {
            Text("Von „\(older.label(in: versions))“ zu „\(newer.label(in: versions))“: grün kam dazu, rot fiel weg.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if difference.isEmpty {
            Section { Text("Kein Unterschied im Inhalt.").foregroundStyle(.secondary) }
        }
        if !difference.fields.isEmpty {
            Section("Angaben") {
                ForEach(difference.fields, id: \.name) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.name).font(.footnote).foregroundStyle(.secondary)
                        line(.removed(field.before))
                        line(.added(field.after))
                    }
                }
            }
        }
        if difference.ingredients.contains(where: \.isChange) {
            Section("Zutaten") { lines(difference.ingredients) }
        }
        if difference.steps.contains(where: \.isChange) {
            Section("Zubereitung") { lines(difference.steps) }
        }
    }

    private func lines(_ lines: [RecipeVersionDifference.Line]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, entry in
                line(entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func line(_ entry: RecipeVersionDifference.Line) -> some View {
        let (mark, text, color): (String, String, Color?) = switch entry {
        case .same(let text): (" ", text, nil)
        case .added(let text): ("+", text, .green)
        case .removed(let text): ("−", text, .red)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark)
                .font(.body.monospaced().weight(.semibold))
                .foregroundStyle(color ?? .secondary)
            Text(text)
                .foregroundStyle(color == nil ? Color.secondary : Color.primary)
                .strikethrough(color == .red, color: .red.opacity(0.6))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((color ?? .clear).opacity(0.12), in: .rect(cornerRadius: 6))
    }
}

private extension RecipeVersionDifference.Line {
    var isChange: Bool {
        if case .same = self { false } else { true }
    }
}

extension RecipeVersion {
    /// How the list names a version: "Aktuelle Version", "Vor „Vegan
    /// machen“", "Original".
    func label(in versions: [RecipeVersion]) -> String {
        switch kind {
        case .current: "Aktuelle Version"
        case .original: "Original"
        case .earlier:
            replacedBy.map { "Vor „\($0)“" } ?? "Frühere Version"
        }
    }

    /// The line under the label: when, and how much the next newer version
    /// changed — what the step from this one to the next did.
    func detail(in versions: [RecipeVersion]) -> String? {
        var parts: [String] = []
        if kind == .current, let last = versions.dropFirst().first?.replacedBy {
            parts.append("nach „\(last)“")
        }
        if let date {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if let index = versions.firstIndex(of: self), index > 0 {
            let newer = versions[index - 1]
            let difference = RecipeVersionDifference(from: self, to: newer)
            let ingredients = difference.ingredients.filter(\.isChange).count
            let steps = difference.steps.filter(\.isChange).count
            var changed: [String] = []
            if ingredients > 0 { changed.append(ingredients == 1 ? "1 Zutatenzeile" : "\(ingredients) Zutatenzeilen") }
            if steps > 0 { changed.append(steps == 1 ? "1 Schrittzeile" : "\(steps) Schrittzeilen") }
            if !difference.fields.isEmpty { changed.append(difference.fields.map(\.name).joined(separator: ", ")) }
            if !changed.isEmpty { parts.append("danach geändert: " + changed.joined(separator: ", ")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
