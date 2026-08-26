import SousKit
import SwiftUI

/// Naming a second version of a dish, and the group the two of them then
/// stand in.
///
/// Both names at once, because they are one thought: "this is another Chili,
/// and this one is the vegetarian one". Asking for them in two steps would
/// make the group feel like an administrative act performed before the
/// cooking, which is exactly what it is not — the group is born as a side
/// effect of there being two versions.
///
/// The group's field is only here the first time. Afterwards the dish already
/// has a name, and a third variant is not the moment to reopen the question.
struct AddVariantSheet: View {
    let recipe: Recipe
    /// Handed the new variant once it is saved, so the caller can show it.
    let onCreated: (Recipe) -> Void

    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var groupTitle = ""
    /// The group `recipe` is already in, if it is in one. Read from the
    /// library rather than from `recipe.variantGroupID` alone: a group whose
    /// second member is in the trash still exists and is still the one to
    /// join, even though the list has stopped drawing it as a group.
    @State private var existingGroup: VariantGroup?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name der Variante", text: $title)
                } header: {
                    Text("Variante")
                } footer: {
                    Text(
                        "Die Variante ist ein vollständiges Rezept: sie beginnt als Kopie und geht dann ihren eigenen Weg. Bilder kommen nicht mit."
                    )
                }

                if let existingGroup {
                    Section("Gruppe") {
                        LabeledContent("Gericht", value: existingGroup.title)
                    }
                } else {
                    Section {
                        TextField("Name des Gerichts", text: $groupTitle)
                    } header: {
                        Text("Gruppe")
                    } footer: {
                        Text("Beide Rezepte stehen danach als Varianten dieses Gerichts nebeneinander.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Variante")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") { create() }
                        .disabled(!canCreate || isSaving)
                }
            }
            .task {
                // Prefilled with the original's name in both fields: the
                // dish is called that, and the variant is called that until
                // the cook says what makes it different.
                if title.isEmpty { title = recipe.title }
                if groupTitle.isEmpty { groupTitle = recipe.title }
                if let id = recipe.variantGroupID {
                    existingGroup = await library.variantGroup(id: id)
                }
            }
        }
        .sousSheetSizing(.form)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (existingGroup != nil || !groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func create() {
        isSaving = true
        Task {
            let variant = await library.addVariant(
                of: recipe,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                groupTitle: groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            isSaving = false
            if let variant {
                onCreated(variant)
                dismiss()
            }
        }
    }
}
