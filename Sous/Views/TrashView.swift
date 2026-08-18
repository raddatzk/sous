import SousKit
import SwiftUI

/// Recipes that were deleted, and the way back.
///
/// Deleting has always kept the recipe — the store only marks it — but until
/// now nothing showed it, which made a slip of the finger final.
///
/// It is the recipe list, with the same rows and the same tap: deciding
/// whether to keep something means looking at it, and a stripped-down list
/// would make the user restore a recipe just to find out what it was.
struct TrashView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var deleted: [Recipe] = []
    @State private var isConfirmingEmpty = false
    @State private var openedRecipe: Recipe?
    @State private var editing: Recipe?

    var body: some View {
        NavigationStack {
            List {
                ForEach(deleted) { recipe in
                    row(recipe)
                        .swipeActions {
                            Button("Endgültig löschen", systemImage: "trash", role: .destructive) {
                                Task {
                                    await library.erase(recipe)
                                    await load()
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") {
                                Task {
                                    await library.restore(recipe)
                                    await load()
                                }
                            }
                            .tint(.accentColor)
                        }
                }
            }
            .navigationTitle("Papierkorb")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .overlay {
                if deleted.isEmpty {
                    ContentUnavailableView(
                        "Papierkorb ist leer",
                        systemImage: "trash",
                        description: Text("Gelöschte Rezepte landen hier und lassen sich zurückholen.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Leeren", role: .destructive) { isConfirmingEmpty = true }
                        .disabled(deleted.isEmpty)
                }
            }
            // Emptying cannot be undone, so it asks — once, for all of them.
            .confirmationDialog(
                "\(deleted.count) Rezepte endgültig löschen?",
                isPresented: $isConfirmingEmpty,
                titleVisibility: .visible
            ) {
                Button("Papierkorb leeren", role: .destructive) {
                    Task {
                        await library.emptyTrash()
                        await load()
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Die Rezepte und ihre Bilder sind danach weg.")
            }
            .navigationDestination(item: $openedRecipe) { recipe in
                RecipeDetailView(recipe: recipe)
            }
            // A recipe opened from here asks the library to edit it. Take the
            // request over rather than letting it fall through to the list,
            // which cannot present anything while this sheet is up.
            .onChange(of: library.editing) { _, wanted in
                guard let wanted else { return }
                library.editing = nil
                editing = wanted
            }
            // A recipe restored from its own page leaves the trash behind it.
            .onChange(of: openedRecipe) { _, opened in
                if opened == nil { Task { await load() } }
            }
            .task { await load() }
            // The recipe list carries the same sheet, but it sits below this
            // one: a sheet can only be presented by what is on top, so the
            // trash presents the editor itself.
            .sheet(item: $editing) { recipe in
                RecipeEditorView(recipe: recipe) { edited in
                    await library.save(edited)
                    await load()
                    // Whatever page is open should show what was just saved.
                    if openedRecipe?.id == edited.id { openedRecipe = edited }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private func row(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RecipeRow(recipe: recipe)
            if let deletedAt = recipe.deletedAt {
                // Without the app's locale this reads "1 hour ago" in the
                // middle of a German sentence.
                Text("Gelöscht \(deletedAt.formatted(.relative(presentation: .named).locale(.sous)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { openedRecipe = recipe }
    }

    private func load() async {
        deleted = await library.deletedRecipes()
    }
}
