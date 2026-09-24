import SousKit
import SwiftUI

/// The household switch, hung on a section's navigation title, with the
/// active household's name beneath it once there is more than one.
///
/// On all three sections, because all three belong to a household: the plan
/// and the shopping list change with it just as the recipes do, and a switch
/// only on the recipes would send somebody back there to change the list.
///
/// A modifier rather than an `if` around the menu's content, because the
/// chevron is drawn for the modifier's presence rather than for what the
/// builder produces — so it is attached only once there is a household at
/// all. Before that, on a reinstall waiting for its first import, there is
/// nothing to switch between and nowhere a new household should go yet.
///
/// The Mac draws no window title, so this does nothing there; the same menu
/// sits in the menu bar instead (see `SousApp`).
struct HouseholdTitleMenu: ViewModifier {
    let switcher: HouseholdSwitcher?

    func body(content: Content) -> some View {
        if let switcher, !switcher.choices.isEmpty {
            content
                .toolbarTitleMenu { HouseholdMenuContent(switcher: switcher) }
                .modifier(Subtitle(text: switcher.subtitle))
        } else {
            content
        }
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
/// entries under the title on iOS and in the Mac's menu bar.
struct HouseholdMenuContent: View {
    let switcher: HouseholdSwitcher

    var body: some View {
        Picker("Haushalt", selection: selection) {
            ForEach(switcher.choices) { choice in
                Text(choice.name).tag(Optional(choice.id))
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
        let switching = "über den Titel"
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
