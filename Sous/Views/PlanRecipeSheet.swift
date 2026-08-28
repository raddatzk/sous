import SousKit
import SwiftUI

/// Puts a recipe on the meal plan — on a day, or into the undated pool.
struct PlanRecipeSheet: View {
    @Environment(MealPlanLibrary.self) private var plan
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe
    /// The serving count the reader had chosen, offered as the default.
    let servings: Int

    @State private var day = Date()
    @State private var slot: MealSlot = .dinner
    /// Planned, but not for any particular evening.
    @State private var withoutDay = false
    @State private var plannedServings: Int

    init(recipe: Recipe, servings: Int) {
        self.recipe = recipe
        self.servings = servings
        _plannedServings = State(initialValue: servings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Ohne festen Tag", isOn: $withoutDay.animation())
                } footer: {
                    if withoutDay {
                        Text("Das Gericht landet in der Sammlung und kann später auf einen Tag gelegt werden.")
                    }
                }

                if !withoutDay {
                    Section {
                        DatePicker("Tag", selection: $day, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    }

                    Section {
                        Picker("Mahlzeit", selection: $slot) {
                            ForEach(MealSlot.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Stepper(value: $plannedServings, in: Recipe.servingsRange) {
                        Label(Servings.text(plannedServings), systemImage: "person.2")
                    }
                } footer: {
                    if plannedServings != recipe.servings {
                        Text("Das Rezept ist für \(Servings.text(recipe.servings)) geschrieben; die Mengen werden umgerechnet.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(recipe.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(withoutDay ? "Vormerken" : "Einplanen") {
                        Task {
                            await plan.add(
                                recipe,
                                to: withoutDay ? nil : day,
                                slot: slot,
                                servings: plannedServings
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
        .sousSheetSizing(.form)
    }
}
