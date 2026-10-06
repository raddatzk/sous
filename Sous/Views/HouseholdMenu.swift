import SousKit
import SwiftUI

/// The active household's name beneath a section's title, once there is more
/// than one to tell apart.
///
/// On all three sections, because all three belong to a household: the plan
/// and the shopping list change with it just as the recipes do. The switch
/// itself is only in the recipes' "Mehr" menu (and the Mac's menu bar, see
/// `SousApp`) — the name here says which household a screen is showing.
struct HouseholdSubtitle: ViewModifier {
    let switcher: HouseholdSwitcher?

    func body(content: Content) -> some View {
        content.modifier(Subtitle(text: switcher?.subtitle))
    }

    /// Only when there is one: an empty subtitle would still take its line.
    private struct Subtitle: ViewModifier {
        let text: String?

        func body(content: Content) -> some View {
            if let text {
                content.navigationSubtitle(text)
            } else {
                content
            }
        }
    }
}

/// The households to choose from, and the way to make another — the same
/// entries in the recipes' "Mehr" menu on iOS and in the Mac's menu bar.
struct HouseholdMenuContent: View {
    let switcher: HouseholdSwitcher

    var body: some View {
        Picker("Haushalt", selection: selection) {
            ForEach(switcher.choices) { choice in
                if choice.isShared {
                    Label(choice.name, systemImage: "person.2").tag(Optional(choice.id))
                } else {
                    Text(choice.name).tag(Optional(choice.id))
                }
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Neuer Haushalt …", systemImage: "plus") {
            switcher.isNamingNewHousehold = true
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { switcher.activeID },
            set: { id in Task { await switcher.switchTo(id) } }
        )
    }
}

/// Naming a new household, which becomes the one showing.
///
/// Only the name, and it is required: a household is made by a person on
/// purpose, and "Mein Haushalt" twice in the switch would tell nobody which
/// is which. Everything else — inviting, the calendar — belongs to the
/// household's own page once it exists.
struct NewHouseholdSheet: View {
    let switcher: HouseholdSwitcher

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name des Haushalts", text: $name, prompt: Text("z. B. WG oder Familie"))
                        .focused($isFocused)
                        .onSubmit(create)
                } footer: {
                    Text(footer)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Neuer Haushalt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen", action: create)
                        .disabled(!canCreate)
                }
            }
            .onAppear { isFocused = true }
        }
        .sousSheetSizing(.question)
    }

    private var footer: String {
        #if os(macOS)
        let switching = "im Menü „Haushalt“"
        #else
        let switching = "im Menü „Mehr“ der Rezepte"
        #endif
        return """
        Ein neuer Haushalt beginnt leer: eigene Rezepte, ein eigener Plan, \
        eine eigene Einkaufsliste. Zwischen deinen Haushalten wechselst du \
        \(switching).
        """
    }

    private var canCreate: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard canCreate else { return }
        isSaving = true
        Task {
            await switcher.create(named: name)
            dismiss()
        }
    }
}
